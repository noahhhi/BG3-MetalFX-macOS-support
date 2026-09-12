// bg3-metalfx 阶段 C：MetalFX Temporal 独立 smoke test。
// 目的：验证本机 MTLFXTemporalScaler 的设备支持、创建、连续帧编码、
//       GPU 完成与输出有效性；建立 jitter/运动方向/reset 的实测参数约定。
// 范围：这只是 API 与参数约定验证，不是游戏接入。
// 输入为解析已知的合成 pattern，输出回读后做数值校验（NaN、动态范围、
// 与解析上采样的平均绝对误差）。

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <math.h>
#include <stdio.h>

#ifndef SMOKE_METALLIB_PATH
#define SMOKE_METALLIB_PATH "smokeinputs.metallib"
#endif

static const NSUInteger kInW = 1280, kInH = 720;
static const NSUInteger kOutW = 2560, kOutH = 1440;

static int g_failures = 0;
static void check(const char *name, int ok) {
    printf("SMOKE_CHECK name=%s result=%s\n", name, ok ? "pass" : "FAIL");
    if (!ok) g_failures++;
}
static void note(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("SMOKE_NOTE ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}

static float halton(uint32_t index, uint32_t base) {
    float f = 1.0f, r = 0.0f;
    while (index > 0) {
        f /= (float)base;
        r += f * (float)(index % base);
        index /= base;
    }
    return r;
}

// 与 SmokeInputs.metal 中 pattern 一致。
static void pattern_at(int x, int y, float *r, float *g, float *b) {
    *r = (float)x / 1280.0f;
    *g = (float)y / 720.0f;
    *b = (((x / 32) + (y / 32)) & 1) ? 0.9f : 0.1f;
}

typedef struct {
    double meanAbsErr;
    double mean;
    double maxAbs;
    unsigned nanCount;
    unsigned samples;
} Stats;

static Stats analyze(const _Float16 *buf, NSUInteger w, NSUInteger h,
                     int offsetX, int offsetY) {
    Stats s = {0, 0, 0, 0, 0};
    // 抽样校验：每 16 像素取一点。
    for (NSUInteger y = 8; y < h; y += 16) {
        for (NSUInteger x = 8; x < w; x += 16) {
            size_t i = (size_t)y * w * 4 + (size_t)x * 4;
            float v[3];
            for (int c = 0; c < 3; c++) {
                v[c] = (float)buf[i + c];
                if (isnan(v[c]) || isinf(v[c])) s.nanCount++;
            }
            float er, eg, eb;
            pattern_at((int)(x / 2) + offsetX, (int)(y / 2) + offsetY,
                       &er, &eg, &eb);
            double err = (fabs(v[0] - er) + fabs(v[1] - eg) + fabs(v[2] - eb)) / 3.0;
            s.meanAbsErr += err;
            double m = (v[0] + v[1] + v[2]) / 3.0;
            s.mean += m;
            if (fabs(m) > s.maxAbs) s.maxAbs = fabs(m);
            s.samples++;
        }
    }
    s.meanAbsErr /= s.samples;
    s.mean /= s.samples;
    return s;
}

int main(void) {
    @autoreleasepool {
        // 观测器联调：给注入的观测器留出安装时间。
        const char *delay = getenv("SMOKE_START_DELAY_MS");
        if (delay) usleep((useconds_t)atol(delay) * 1000);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        check("device", device != nil);
        if (!device) return 1;
        note("deviceName=%s", device.name.UTF8String);

        BOOL supported = [MTLFXTemporalScalerDescriptor supportsDevice:device];
        check("supportsDevice", supported);
        if (!supported) return 1;
        NSError *err = nil;
        id<MTLLibrary> lib =
            [device newLibraryWithURL:[NSURL fileURLWithPath:@(SMOKE_METALLIB_PATH)]
                                error:&err];
        check("metallib", lib != nil);
        if (!lib) {
            note("metallib error=%s", err.localizedDescription.UTF8String);
            return 1;
        }
        id<MTLFunction> fnColor = [lib newFunctionWithName:@"fill_color"];
        id<MTLFunction> fnDepth = [lib newFunctionWithName:@"fill_depth"];
        id<MTLFunction> fnMotion = [lib newFunctionWithName:@"fill_motion"];
        check("functions", fnColor && fnDepth && fnMotion);
        id<MTLComputePipelineState> psColor =
            [device newComputePipelineStateWithFunction:fnColor error:&err];
        id<MTLComputePipelineState> psDepth =
            [device newComputePipelineStateWithFunction:fnDepth error:&err];
        id<MTLComputePipelineState> psMotion =
            [device newComputePipelineStateWithFunction:fnMotion error:&err];
        check("pipelines", psColor && psDepth && psMotion);

        MTLFXTemporalScalerDescriptor *desc = [MTLFXTemporalScalerDescriptor new];
        desc.inputWidth = kInW;
        desc.inputHeight = kInH;
        desc.outputWidth = kOutW;
        desc.outputHeight = kOutH;
        desc.colorTextureFormat = MTLPixelFormatRGBA16Float;
        desc.depthTextureFormat = MTLPixelFormatR32Float;
        desc.motionTextureFormat = MTLPixelFormatRG16Float;
        desc.outputTextureFormat = MTLPixelFormatRGBA16Float;
        desc.autoExposureEnabled = NO;
        id<MTLFXTemporalScaler> scaler = [desc newTemporalScalerWithDevice:device];
        check("createScaler", scaler != nil);
        if (!scaler) return 1;
        scaler.depthReversed = YES;
        note("usage color=%lu depth=%lu motion=%lu output=%lu",
             (unsigned long)scaler.colorTextureUsage,
             (unsigned long)scaler.depthTextureUsage,
             (unsigned long)scaler.motionTextureUsage,
             (unsigned long)scaler.outputTextureUsage);
        note("inputContentSize %lux%lu", (unsigned long)scaler.inputContentWidth,
             (unsigned long)scaler.inputContentHeight);

        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                               width:kInW
                                                              height:kInH
                                                           mipmapped:NO];
        td.usage = scaler.colorTextureUsage | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texColor = [device newTextureWithDescriptor:td];

        td.pixelFormat = MTLPixelFormatR32Float;
        td.usage = scaler.depthTextureUsage | MTLTextureUsageShaderWrite;
        id<MTLTexture> texDepth = [device newTextureWithDescriptor:td];

        td.pixelFormat = MTLPixelFormatRG16Float;
        td.usage = scaler.motionTextureUsage | MTLTextureUsageShaderWrite;
        id<MTLTexture> texMotion = [device newTextureWithDescriptor:td];

        td.pixelFormat = MTLPixelFormatRGBA16Float;
        td.width = kOutW;
        td.height = kOutH;
        td.usage = scaler.outputTextureUsage;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texOut = [device newTextureWithDescriptor:td];

        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> texStage = [device newTextureWithDescriptor:td];
        check("textures", texColor && texDepth && texMotion && texOut && texStage);

        id<MTLCommandQueue> queue = [device newCommandQueue];

        // scenario: 0=静止 1=平移 2=平移+中途reset
        const char *names[3] = {"stationary", "translate", "translate_reset"};
        int scenarioOk[3] = {0, 0, 0};

        for (int sc = 0; sc < 3; sc++) {
            const int frames = 60;
            const float dx = (sc == 0) ? 0.0f : 2.0f;
            const float dy = (sc == 0) ? 0.0f : 1.0f;
            int error = 0;

            for (int t = 0; t < frames && !error; t++) {
                @autoreleasepool {
                    int offsetX = (int)lroundf(dx * t);
                    int offsetY = (int)lroundf(dy * t);
                    // 内容本帧相对上帧移动 (dx,dy)：current 像素 u 的内容上一帧在
                    // u-(dx,dy)。MetalFX 约定 previous-minus-current。
                    float mv[2] = {-dx, -dy};

                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                    MTLSize grid = MTLSizeMake(kInW, kInH, 1);
                    MTLSize tg = MTLSizeMake(16, 16, 1);
                    [ce setComputePipelineState:psColor];
                    int32_t off[2] = {offsetX, offsetY};
                    [ce setBytes:off length:sizeof(off) atIndex:0];
                    [ce setTexture:texColor atIndex:0];
                    [ce dispatchThreads:grid threadsPerThreadgroup:tg];
                    [ce setComputePipelineState:psDepth];
                    [ce setTexture:texDepth atIndex:0];
                    [ce dispatchThreads:grid threadsPerThreadgroup:tg];
                    [ce setComputePipelineState:psMotion];
                    [ce setBytes:mv length:sizeof(mv) atIndex:0];
                    [ce setTexture:texMotion atIndex:0];
                    [ce dispatchThreads:grid threadsPerThreadgroup:tg];
                    [ce endEncoding];

                    scaler.colorTexture = texColor;
                    scaler.depthTexture = texDepth;
                    scaler.motionTexture = texMotion;
                    scaler.outputTexture = texOut;
                    scaler.jitterOffsetX = halton((uint32_t)(t % 8) + 1, 2) - 0.5f;
                    scaler.jitterOffsetY = halton((uint32_t)(t % 8) + 1, 3) - 0.5f;
                    scaler.motionVectorScaleX = 1.0f;
                    scaler.motionVectorScaleY = 1.0f;
                    scaler.preExposure = 1.0f;
                    scaler.reset = (t == 0) || (sc == 2 && t == 30);
                    [scaler encodeToCommandBuffer:cb];

                    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                    [be copyFromTexture:texOut
                            sourceSlice:0
                            sourceLevel:0
                           sourceOrigin:MTLOriginMake(0, 0, 0)
                             sourceSize:MTLSizeMake(kOutW, kOutH, 1)
                              toTexture:texStage
                       destinationSlice:0
                       destinationLevel:0
                      destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [be endEncoding];

                    [cb commit];
                    [cb waitUntilCompleted];
                    if (cb.status != MTLCommandBufferStatusCompleted) {
                        note("scenario=%s frame=%d commandBuffer error=%s", names[sc], t,
                             cb.error ? cb.error.localizedDescription.UTF8String : "(nil)");
                        error = 1;
                    }
                }
            }

            if (!error) {
                size_t rowBytes = (size_t)kOutW * 4 * sizeof(_Float16);
                _Float16 *buf = (_Float16 *)malloc(rowBytes * kOutH);
                check("readbackAlloc", buf != NULL);
                [texStage getBytes:buf
                       bytesPerRow:rowBytes
                        fromRegion:MTLRegionMake2D(0, 0, kOutW, kOutH)
                       mipmapLevel:0];
                int offsetX = (int)lroundf(dx * (frames - 1));
                int offsetY = (int)lroundf(dy * (frames - 1));
                Stats s = analyze(buf, kOutW, kOutH, offsetX, offsetY);
                free(buf);
                note("scenario=%s meanAbsErr=%.4f mean=%.4f maxAbs=%.4f nan=%u samples=%u",
                     names[sc], s.meanAbsErr, s.mean, s.maxAbs, s.nanCount, s.samples);
                scenarioOk[sc] = (s.nanCount == 0) && s.mean > 0.2 && s.mean < 0.8 &&
                                 s.maxAbs <= 1.5 && s.meanAbsErr < 0.15;
            }
            check(names[sc], !error && scenarioOk[sc]);
        }

        printf("SMOKE_RESULT %s\n", g_failures == 0 ? "PASS" : "FAIL");
        return g_failures == 0 ? 0 : 1;
    }
}
