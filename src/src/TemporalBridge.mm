// MetalFX runs immediately after PPTAA's render encoder, using raw current HDR.
// EASU then copies/compresses the upscaled HDR inside the game's compute encoder.
// Stock RCAS (including inverse compression) and subsequent consumers keep their order.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <atomic>
#include <cmath>

void bg3mf_observer_log(const char *);
extern void bg3mf_dump_easu_textures(id, id, id);
static BOOL checked, enabled;
static id<MTLTexture> depthSource, velocity, pendingColor, pendingMotion;
static id<MTLTexture> depthR32, scaledHDR;
static id<MTLComputePipelineState> depthPipeline, compressPipeline;
static id<MTLDevice> device;
static id<MTLFXTemporalScaler> scaler;
static NSUInteger iw, ih, ow, oh, fsrOW, fsrOH, readyIW, readyIH;
static MTLPixelFormat colorFormat, motionFormat, outputFormat;
static float jitterX, jitterY;
static BOOL ready;
static std::atomic<bool> needReset{true};
static long frames;

static NSString *const kernels = @R"METAL(
#include <metal_stdlib>
using namespace metal;
kernel void bg3mf_depth(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 p [[thread_position_in_grid]]) {
    if (p.x < dst.get_width() && p.y < dst.get_height()) dst.write(src.read(p).x, p);
}
kernel void bg3mf_compress(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 p [[thread_position_in_grid]]) {
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    float3 c = max(src.read(p).rgb, 0.0f);
    dst.write(float4(c / (1.0f + max(c.r, max(c.g, c.b))), 1.0f), p);
}
)METAL";

int bg3mf_tb_is_enabled(void) {
    if (!checked) {
        const char *v = getenv("BG3MF_TEMPORAL");
        enabled = v && strcmp(v, "1") == 0;
        checked = YES;
        if (enabled) bg3mf_observer_log("tb: temporal bridge ENABLED (raw HDR -> MetalFX -> FSR compress -> stock RCAS)");
    }
    return enabled;
}
void bg3mf_tb_note_depth_source(const void *tex) {
    if (bg3mf_tb_is_enabled()) depthSource = (__bridge id<MTLTexture>)tex;
}
void bg3mf_tb_note_velocity(const void *tex) {
    if (!bg3mf_tb_is_enabled()) return;
    velocity = (__bridge id<MTLTexture>)tex;
    ready = NO;
}

static id<MTLTexture> texture(MTLPixelFormat fmt, NSUInteger w, NSUInteger h, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = usage;
    return [device newTextureWithDescriptor:d];
}
static BOOL prepare(id<MTLTexture> c, id<MTLTexture> m, id<MTLTexture> o, NSUInteger w, NSUInteger h) {
    if (device && device != c.device) {
        scaler = nil; depthPipeline = nil; compressPipeline = nil; depthR32 = nil; scaledHDR = nil;
    }
    device = c.device;
    if (![MTLFXTemporalScalerDescriptor supportsDevice:device]) return NO;
    if (!depthPipeline) {
        NSError *e = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:kernels options:nil error:&e];
        depthPipeline = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bg3mf_depth"] error:&e];
        compressPipeline = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bg3mf_compress"] error:&e];
        if (!depthPipeline || !compressPipeline) { bg3mf_observer_log("tb: bridge kernels unavailable; using stock rendering"); return NO; }
    }
    if (!scaler || iw != c.width || ih != c.height || ow != w || oh != h ||
        colorFormat != c.pixelFormat || motionFormat != m.pixelFormat || outputFormat != o.pixelFormat) {
        MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
        d.inputWidth = c.width; d.inputHeight = c.height; d.outputWidth = w; d.outputHeight = h;
        d.colorTextureFormat = c.pixelFormat; d.motionTextureFormat = m.pixelFormat;
        d.depthTextureFormat = MTLPixelFormatR32Float; d.outputTextureFormat = o.pixelFormat;
        id<MTLFXTemporalScaler> s = [d newTemporalScalerWithDevice:device];
        if (!s) { bg3mf_observer_log("tb: scaler unavailable; using stock rendering"); return NO; }
        scaler = s; iw = c.width; ih = c.height; ow = w; oh = h;
        colorFormat = c.pixelFormat; motionFormat = m.pixelFormat; outputFormat = o.pixelFormat;
        depthR32 = texture(MTLPixelFormatR32Float, iw, ih, scaler.depthTextureUsage | MTLTextureUsageShaderWrite);
        scaledHDR = texture(outputFormat, ow, oh, scaler.outputTextureUsage | MTLTextureUsageShaderRead);
        needReset = true;
        char msg[200]; snprintf(msg, sizeof(msg), "tb: scaler %lux%lu->%lux%lu formats=%lu/%lu/%lu", iw,ih,ow,oh,colorFormat,motionFormat,outputFormat);
        bg3mf_observer_log(msg);
    }
    return depthR32 && scaledHDR &&
        (c.usage & scaler.colorTextureUsage) == scaler.colorTextureUsage &&
        (m.usage & scaler.motionTextureUsage) == scaler.motionTextureUsage;
}

// Keep the low-resolution stock TAA valid for unrelated consumers (return 0),
// but never feed its filtered color into MetalFX. Upscaling Off stays native.
// *scheduled tells the observer to encode MetalFX even when the stock draw is retained.
int bg3mf_tb_record_taa(const void *color, const void *motion, const void *output,
                        const void *buffer, unsigned long offset, int *scheduled) {
    *scheduled = 0;
    if (!bg3mf_tb_is_enabled() || !color || !motion || !output || !depthSource) return 0;
    id<MTLTexture> c = (__bridge id<MTLTexture>)color;
    id<MTLTexture> m = (__bridge id<MTLTexture>)motion;
    id<MTLTexture> o = (__bridge id<MTLTexture>)output;
    if (c.width != m.width || c.height != m.height || c.width != depthSource.width || c.height != depthSource.height) return 0;
    NSUInteger w = c.width, h = c.height;
    // Learn the game's actual output size at EASU, no screen/native-size assumption.
    // A first FSR frame or resize uses the intact stock FSR chain until sizes match.
    BOOL upscale = fsrOW > c.width && fsrOH > c.height;
    // Upscaling Off must retain the actual native game AA, not a hidden MetalFX path.
    if (!upscale) { ready=NO; needReset=true; return 0; }
    w = fsrOW; h = fsrOH;
    @try {
        if (!prepare(c,m,o,w,h)) return 0;
        jitterX = jitterY = 0;
        if (buffer) {
            id<MTLBuffer> b = (__bridge id<MTLBuffer>)buffer;
            if (b.storageMode != MTLStorageModePrivate && offset <= b.length && b.length-offset >= 0xd8) {
                const float *j = (const float *)((const char *)b.contents+offset+0xd0);
                if (std::isfinite(j[0]) && std::isfinite(j[1])) { jitterX=j[0]; jitterY=j[1]; }
            }
        }
        pendingColor=c; pendingMotion=m;
        *scheduled=1;
        return 0;
    } @catch (NSException *e) {
        bg3mf_observer_log("tb: preparation failed; using stock rendering"); return 0;
    }
}

void bg3mf_tb_encode_if_pending(const void *cbPtr) {
    if (!pendingColor || !cbPtr) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbPtr;
    id<MTLTexture> c=pendingColor, m=pendingMotion;
    pendingColor=nil; pendingMotion=nil;
    @try {
        id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
        [ce setComputePipelineState:depthPipeline]; [ce setTexture:depthSource atIndex:0]; [ce setTexture:depthR32 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake((iw+15)/16,(ih+15)/16,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
        [ce endEncoding];
        scaler.colorTexture=c; scaler.motionTexture=m; scaler.depthTexture=depthR32; scaler.outputTexture=scaledHDR;
        scaler.inputContentWidth=iw; scaler.inputContentHeight=ih;
        scaler.jitterOffsetX=jitterX; scaler.jitterOffsetY=jitterY;
        scaler.motionVectorScaleX=-1; scaler.motionVectorScaleY=-1;
        scaler.depthReversed=YES; scaler.preExposure=1; scaler.reset=needReset.exchange(false);
        [scaler encodeToCommandBuffer:cb];
        ready=YES; readyIW=iw; readyIH=ih;
        bg3mf_dump_easu_textures(c,scaledHDR,cb);
        long n=frames++;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status == MTLCommandBufferStatusError) {
                needReset=true;
                bg3mf_observer_log(done.error.localizedDescription.UTF8String);
            } else if (n < 3 || n % 300 == 0) {
                char msg[200]; snprintf(msg,sizeof(msg),"tb: GPU completed frame %ld duration_ms=%.3f",n,(done.GPUEndTime-done.GPUStartTime)*1000);
                bg3mf_observer_log(msg);
            }
        }];
        if (n < 3 || n % 300 == 0) {
            char msg[200]; snprintf(msg,sizeof(msg),"tb: raw HDR frame %ld %lux%lu->%lux%lu jitter=(%.4f,%.4f)",n,iw,ih,ow,oh,jitterX,jitterY);
            bg3mf_observer_log(msg);
        }
    } @catch (NSException *e) { ready=NO; needReset=true; bg3mf_observer_log(e.reason.UTF8String); }
}

// Runs IN the existing compute encoder, before RCAS and any later dispatches.
// The observer restores the game's pipeline and bindings after this replacement.
int bg3mf_tb_replace_easu(const void *encPtr, const void *input, const void *output) {
    if (!bg3mf_tb_is_enabled() || !encPtr || !input || !output) return 0;
    id<MTLTexture> in=(__bridge id<MTLTexture>)input, out=(__bridge id<MTLTexture>)output;
    if (out.width <= in.width || out.height <= in.height) return 0;
    fsrOW=out.width; fsrOH=out.height;
    if (!ready || !compressPipeline || readyIW != in.width || readyIH != in.height || scaledHDR.width != out.width || scaledHDR.height != out.height || !(out.usage & MTLTextureUsageShaderWrite)) return 0;
    ready=NO;
    id<MTLComputeCommandEncoder> ce=(__bridge id<MTLComputeCommandEncoder>)encPtr;
    [ce setComputePipelineState:compressPipeline];
    [ce setTexture:scaledHDR atIndex:0]; [ce setTexture:out atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake((out.width+15)/16,(out.height+15)/16,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
    return 1;
}
