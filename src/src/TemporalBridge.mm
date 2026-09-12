// 阶段 E：TemporalBridge——用 MTLFXTemporalScaler 替换游戏 TAA。
//
// 接入点（由 MetalObserver 在对应 hook 处调用）：
// 1. 主视口 LinearizeDepth draw → bg3mf_tb_note_depth_source 缓存原始 device depth。
// 2. PPTAA_PS 的 draw → bg3mf_tb_try_record_taa 记录输入（颜色/速度/输出/jitter），
//    返回非 0 时调用方跳过原始 draw（抑制游戏 TAA）。
// 3. render encoder endEncoding(orig 之后) → bg3mf_tb_encode_if_pending：
//    深度转换（Depth32F_Stencil8 → R32Float）+ scaler encode 进游戏 command buffer。
//
// 运行时验证过的契约（见 HANDOFF 增补 5）：
// - 速度 = current-minus-previous 像素位移 → motionVectorScale=(-1,-1)
// - 深度 reversed-Z（远=0）→ depthReversed=YES；LinearizeDepth 输入为 Depth32F_Stencil8
// - 颜色 RG11B10Float 线性 HDR → preExposure=1.0
// - jitter 在 TemporalConstants(f:8) +0xd0，像素单位
//
// 环境开关：BG3MF_TEMPORAL=1 启用（默认关闭，观测器纯被动）。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <stdatomic.h>
#include <string.h>

void bg3mf_observer_log(const char *msg);  // LoadProbe 提供

static BOOL g_tb_enabled;
static BOOL g_tb_checked;
static BOOL g_fsrMode;                 // 检测到 compute:FSR pipeline → EASU 接管模式

// 每帧记录（游戏单渲染线程，按帧顺序到达）
static id<MTLTexture> g_depthSrc;      // 主视口 LinearizeDepth 的输入（device depth）
static id<MTLTexture> g_velocity;      // VelocityBufferCamera pass 输出（内部 res）
static id<MTLTexture> g_pendColor;
static id<MTLTexture> g_pendMotion;
static id<MTLTexture> g_pendOutput;
static float g_pendJitterX, g_pendJitterY;

// EASU 接管（FSR 模式）：input=低 res HDR，output=原生 res
static id<MTLTexture> g_easuIn;
static id<MTLTexture> g_easuOut;

// MetalFX 资源（按分辨率缓存）
static id<MTLDevice> g_dev;
static id<MTLFXTemporalScaler> g_scaler;
static NSUInteger g_scalerW, g_scalerH, g_scalerOW, g_scalerOH;
static BOOL g_needReset = YES;
static id<MTLTexture> g_depthR32;
static id<MTLComputePipelineState> g_depthCvt;
static _Atomic long g_tbFrames = 0;

static const char *kCvtSrc =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void cvt_depth(texture2d<float, access::read> src [[texture(0)]],\n"
    "                      texture2d<float, access::write> dst [[texture(1)]],\n"
    "                      uint2 gid [[thread_position_in_grid]]) {\n"
    "  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
    "  dst.write(float4(src.read(gid).x, 0.0, 0.0, 0.0), gid);\n"
    "}\n";

int bg3mf_tb_is_enabled(void) {
    if (!g_tb_checked) {
        const char *e = getenv("BG3MF_TEMPORAL");
        g_tb_enabled = e && strcmp(e, "1") == 0;
        g_tb_checked = YES;
        if (g_tb_enabled) bg3mf_observer_log("tb: temporal bridge ENABLED");
    }
    return g_tb_enabled;
}

void bg3mf_tb_note_depth_source(const void *tex) {
    if (!bg3mf_tb_is_enabled() || !tex) return;
    g_depthSrc = (__bridge id<MTLTexture>)tex;
}

void bg3mf_tb_note_velocity(const void *tex) {
    if (!bg3mf_tb_is_enabled() || !tex) return;
    g_velocity = (__bridge id<MTLTexture>)tex;
}

void bg3mf_tb_note_fsr_pipeline(void) {
    if (!bg3mf_tb_is_enabled() || g_fsrMode) return;
    g_fsrMode = YES;
    bg3mf_observer_log("tb: FSR pipeline detected -> EASU takeover mode");
}

// 返回非 0 = 已记录并可抑制原始 TAA draw。
int bg3mf_tb_try_record_taa(const void *color, const void *motion, const void *output,
                            const void *constBuf, unsigned long bufOff) {
    if (!bg3mf_tb_is_enabled()) return 0;
    if (g_fsrMode) return 0;  // FSR 模式走 EASU 接管，不抑制 TAA
    if (!color || !motion || !output || !g_depthSrc) return 0;
    id<MTLTexture> c = (__bridge id<MTLTexture>)color;
    id<MTLTexture> m = (__bridge id<MTLTexture>)motion;
    id<MTLTexture> o = (__bridge id<MTLTexture>)output;
    // 输入必须同尺寸（1:1 阶段）；输出必须能 shaderWrite。
    if (c.width != m.width || c.height != m.height) return 0;
    if (!(o.usage & MTLTextureUsageShaderWrite)) return 0;

    float jx = 0.0f, jy = 0.0f;
    if (constBuf) {
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)constBuf;
        if (b.storageMode != MTLStorageModePrivate &&
            b.length >= bufOff + 0xd0 + 8) {
            const float *j =
                (const float *)((const char *)b.contents + bufOff + 0xd0);
            jx = j[0];
            jy = j[1];
        }
    }
    g_pendColor = c;
    g_pendMotion = m;
    g_pendOutput = o;
    g_pendJitterX = jx;
    g_pendJitterY = jy;
    return 1;
}

// 返回非 0 = 已记录并可抑制 EASU dispatch。
int bg3mf_tb_try_record_easu(const void *input, const void *output,
                             const void *constBuf, unsigned long bufOff) {
    if (!bg3mf_tb_is_enabled() || !g_fsrMode) return 0;
    if (!input || !output || !g_velocity || !g_depthSrc) return 0;
    id<MTLTexture> in = (__bridge id<MTLTexture>)input;
    id<MTLTexture> out = (__bridge id<MTLTexture>)output;
    // 速度/深度必须与 EASU 输入同尺寸（同为内部渲染 res）；输出必须可写。
    if (g_velocity.width != in.width || g_velocity.height != in.height) return 0;
    if (g_depthSrc.width != in.width || g_depthSrc.height != in.height) return 0;
    if (!(out.usage & MTLTextureUsageShaderWrite)) return 0;

    float jx = 0.0f, jy = 0.0f;
    if (constBuf) {
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)constBuf;
        if (b.storageMode != MTLStorageModePrivate &&
            b.length >= bufOff + 0xd0 + 8) {
            const float *j =
                (const float *)((const char *)b.contents + bufOff + 0xd0);
            jx = j[0];
            jy = j[1];
        }
    }
    g_easuIn = in;
    g_easuOut = out;
    g_pendJitterX = jx;
    g_pendJitterY = jy;
    return 1;
}

static BOOL tb_ensure_scaler(NSUInteger w, NSUInteger h, NSUInteger ow,
                             NSUInteger oh, MTLPixelFormat cfmt,
                             MTLPixelFormat mfmt, MTLPixelFormat ofmt) {
    if (g_scaler && g_scalerW == w && g_scalerH == h &&
        g_scalerOW == ow && g_scalerOH == oh)
        return YES;
    MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
    d.colorTextureFormat = cfmt;
    d.depthTextureFormat = MTLPixelFormatR32Float;
    d.motionTextureFormat = mfmt;
    d.outputTextureFormat = ofmt;
    d.inputWidth = w;
    d.inputHeight = h;
    d.outputWidth = ow;
    d.outputHeight = oh;
    if (![MTLFXTemporalScalerDescriptor supportsDevice:g_dev]) {
        bg3mf_observer_log("tb: device not supported");
        return NO;
    }
    g_scaler = [d newTemporalScalerWithDevice:g_dev];
    if (!g_scaler) {
        bg3mf_observer_log("tb: scaler create failed");
        return NO;
    }
    g_scalerW = w;
    g_scalerH = h;
    g_scalerOW = ow;
    g_scalerOH = oh;
    g_needReset = YES;
    bg3mf_observer_log("tb: scaler created");
    return YES;
}

static BOOL tb_ensure_depth_cvt(NSUInteger w, NSUInteger h) {
    if (!g_depthCvt) {
        NSError *err = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(kCvtSrc)
                                                 options:nil
                                                   error:&err];
        if (!lib) {
            bg3mf_observer_log("tb: cvt shader compile failed");
            return NO;
        }
        g_depthCvt = [g_dev newComputePipelineStateWithFunction:
                             [lib newFunctionWithName:@"cvt_depth"]
                                                          error:&err];
        if (!g_depthCvt) {
            bg3mf_observer_log("tb: cvt pipeline failed");
            return NO;
        }
    }
    if (!g_depthR32 || g_depthR32.width != w || g_depthR32.height != h) {
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                               width:w
                                                              height:h
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        g_depthR32 = [g_dev newTextureWithDescriptor:td];
        if (!g_depthR32) {
            bg3mf_observer_log("tb: depthR32 alloc failed");
            return NO;
        }
    }
    return YES;
}

void bg3mf_tb_encode_easu_if_pending(const void *cbPtr) {
    if (!g_easuIn) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbPtr;
    @try {
        id<MTLTexture> input = g_easuIn, output = g_easuOut;
        g_easuIn = nil;
        g_easuOut = nil;
        g_dev = input.device;
        NSUInteger w = input.width, h = input.height;
        if (!tb_ensure_scaler(w, h, output.width, output.height,
                              input.pixelFormat, g_velocity.pixelFormat,
                              output.pixelFormat) ||
            !tb_ensure_depth_cvt(w, h))
            return;

        // 1. 深度转换：Depth32F_Stencil8 → R32Float（内部 res 尺寸）。
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:g_depthCvt];
        [ce setTexture:g_depthSrc atIndex:0];
        [ce setTexture:g_depthR32 atIndex:1];
        MTLSize tg = MTLSizeMake(16, 16, 1);
        MTLSize grid = MTLSizeMake((w + 15) / 16, (h + 15) / 16, 1);
        [ce dispatchThreadgroups:grid threadsPerThreadgroup:tg];
        [ce endEncoding];

        // 2. MetalFX Temporal：低 res → 原生 res。
        g_scaler.colorTexture = input;
        g_scaler.depthTexture = g_depthR32;
        g_scaler.motionTexture = g_velocity;
        g_scaler.outputTexture = output;
        g_scaler.inputContentWidth = w;
        g_scaler.inputContentHeight = h;
        g_scaler.jitterOffsetX = g_pendJitterX;
        g_scaler.jitterOffsetY = g_pendJitterY;
        g_scaler.motionVectorScaleX = -1.0f;
        g_scaler.motionVectorScaleY = -1.0f;
        g_scaler.preExposure = 1.0f;
        g_scaler.depthReversed = YES;
        g_scaler.reset = g_needReset;
        [g_scaler encodeToCommandBuffer:cb];
        g_needReset = NO;

        long n = atomic_fetch_add(&g_tbFrames, 1);
        if (n < 5 || n % 300 == 0) {
            char msg[192];
            snprintf(msg, sizeof(msg),
                     "tb: easu frame %ld %lux%lu->%lux%lu jitter=(%.4f,%.4f)",
                     n, (unsigned long)w, (unsigned long)h,
                     (unsigned long)output.width, (unsigned long)output.height,
                     g_pendJitterX, g_pendJitterY);
            bg3mf_observer_log(msg);
        }
    } @catch (NSException *e) {
        char msg[256];
        snprintf(msg, sizeof(msg), "tb: easu encode exception: %s",
                 e.reason.UTF8String);
        bg3mf_observer_log(msg);
    }
}

void bg3mf_tb_encode_if_pending(const void *cbPtr) {
    if (!g_pendColor) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbPtr;
    @try {
        id<MTLTexture> color = g_pendColor, motion = g_pendMotion, output = g_pendOutput;
        g_pendColor = nil;
        g_pendMotion = nil;
        g_pendOutput = nil;
        g_dev = color.device;
        NSUInteger w = color.width, h = color.height;
        if (!tb_ensure_scaler(w, h, output.width, output.height,
                              color.pixelFormat, motion.pixelFormat,
                              output.pixelFormat) ||
            !tb_ensure_depth_cvt(w, h))
            return;

        // 1. 深度转换：Depth32F_Stencil8 → R32Float（同 cb，compute 紧接在已结束的
        //    render encoder 之后是合法的）。
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:g_depthCvt];
        [ce setTexture:g_depthSrc atIndex:0];
        [ce setTexture:g_depthR32 atIndex:1];
        MTLSize tg = MTLSizeMake(16, 16, 1);
        MTLSize grid =
            MTLSizeMake((w + 15) / 16, (h + 15) / 16, 1);
        [ce dispatchThreadgroups:grid threadsPerThreadgroup:tg];
        [ce endEncoding];

        // 2. MetalFX Temporal
        g_scaler.colorTexture = color;
        g_scaler.depthTexture = g_depthR32;
        g_scaler.motionTexture = motion;
        g_scaler.outputTexture = output;
        g_scaler.inputContentWidth = w;
        g_scaler.inputContentHeight = h;
        g_scaler.jitterOffsetX = g_pendJitterX;
        g_scaler.jitterOffsetY = g_pendJitterY;
        g_scaler.motionVectorScaleX = -1.0f;
        g_scaler.motionVectorScaleY = -1.0f;
        g_scaler.preExposure = 1.0f;
        g_scaler.depthReversed = YES;
        g_scaler.reset = g_needReset;
        [g_scaler encodeToCommandBuffer:cb];
        g_needReset = NO;

        long n = atomic_fetch_add(&g_tbFrames, 1);
        if (n < 5 || n % 300 == 0) {
            char msg[160];
            snprintf(msg, sizeof(msg),
                     "tb: encoded frame %ld jitter=(%.4f,%.4f)", n,
                     g_pendJitterX, g_pendJitterY);
            bg3mf_observer_log(msg);
        }
    } @catch (NSException *e) {
        char msg[256];
        snprintf(msg, sizeof(msg), "tb: encode exception: %s",
                 e.reason.UTF8String);
        bg3mf_observer_log(msg);
    }
}
