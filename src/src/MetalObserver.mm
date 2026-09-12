// bg3-metalfx 阶段 B：只观测 Metal API 观测器。
//
// 原则（依 HANDOFF.md schema 2）：
// - 所有游戏调用原样转发；观测失败不得影响渲染。
// - 不假定固定私有 Metal 类名：通过自建 MTLDevice 实例动态发现具体实现类，
//   再对发现的类按 selector 安装 swizzle，保留原 IMP。
// - pipeline 创建时建立 function 名 → pipeline 映射；draw/dispatch 前按
//   stage/slot 保存绑定状态快照；早期未捕获的 pipeline 标 unknown，不猜标签。
// - shared buffer 快照注明 CPU 时点；private buffer 不读 contents。
// - 不 hook 游戏内部函数，不做 inline patch。
//
// 环境开关：BG3MF_OBSERVER=0 关闭；BG3MF_TRACE_ALL=1 时对所有 pipeline 做全量快照
// （默认只对已知目标函数全量快照，其余只记一行事件）。
//
// 已知未覆盖（v1）：sampler 绑定、间接 draw/dispatch、新 SDK 的更多创建变体、
// pipeline 创建异步变体。若游戏实际使用这些路径，相关事件会以 unknown 出现，
// 不得伪装成完整快照。

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

void bg3mf_trace_init(const char *path);
void bg3mf_trace_event(NSDictionary *obj);
extern void bg3mf_observer_log(const char *msg);
int bg3mf_tb_is_enabled(void);
void bg3mf_tb_note_depth_source(const void *tex);
int bg3mf_tb_try_record_taa(const void *color, const void *motion,
                            const void *output, const void *constBuf,
                            unsigned long bufOff);
void bg3mf_tb_encode_if_pending(const void *cb);
void bg3mf_tb_note_velocity(const void *tex);
void bg3mf_tb_note_fsr_pipeline(void);
int bg3mf_tb_try_record_easu(const void *input, const void *output,
                             const void *constBuf, unsigned long bufOff);
void bg3mf_tb_encode_easu_if_pending(const void *cb);
extern const char *bg3mf_self_path(void);         // LoadProbe 提供

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// function 指针 → 名字（NSString）
static NSMapTable *g_func_names;      // strong -> strong
// pipeline 指针 → 描述（如 "compute:FSR" / "render:VS+PS"）
static NSMapTable *g_pipeline_info;   // strong -> strong
// encoder 指针 → 状态对象
static NSMapTable *g_enc_state;       // strong -> strong（endEncoding 时释放）

static BOOL g_trace_all = NO;
static id<MTLDevice> g_device = nil;   // 安装时发现，用于抓取暂存纹理
static long g_dump_cap = 0;             // BG3MF_DUMP_FRAMES 总帧数上限（安全闹）
static _Atomic long g_dump_burst = 0;   // 哨兵触发的连发帧数
static _Atomic long g_dump_seq = 0;
static CFAbsoluteTime g_install_time = 0;
static long g_trace_seconds = 600;      // draw/dispatch 记录时间盒；0=不限
static double g_tb_min_vp = 1000.0;     // 主视口最小宽（FSR 低档内部渲染可到 1175；阴影视图 512、菜单占位 16）
const char *bg3mf_home(void);           // LoadProbe 提供
static char g_sentinel[PATH_MAX];
static char g_capture_dir[PATH_MAX];
static char g_runs_dir[PATH_MAX];

// 目标 stage 函数名（交接证据给出的准确 Metal function 名）
static NSSet *g_target_names;

static NSString *ptr_key(const void *p) {
    return [NSString stringWithFormat:@"%p", p];
}

// ---------------------------------------------------------------------------
// swizzle 基础设施
// ---------------------------------------------------------------------------
typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
} SwizzleRec;

static SwizzleRec g_swizzles[64];
static int g_swizzle_count = 0;

// 对已发现的具体类安装实例方法替换；重复安装/已替换时跳过。
// 关键：若 sel 在 cls 上是继承自父类的方法，则在 cls 上 class_addMethod 覆盖，
// 不修改父类方法（避免兄弟类被串改，曾导致 render encoder 调到 compute 实现而崩溃）。
static BOOL swizzle_install(Class cls, SEL sel, IMP replacement, IMP *orig_out) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (cur == replacement) return NO;  // 已安装
    for (int i = 0; i < g_swizzle_count; i++) {
        if (g_swizzles[i].cls == cls && g_swizzles[i].sel == sel) return NO;
    }
    if (g_swizzle_count >= 64) return NO;

    // 是否本类自有方法
    BOOL own = NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { own = YES; break; }
    }
    free(list);

    IMP orig;
    if (own) {
        orig = method_setImplementation(m, replacement);
    } else {
        // 继承方法：只在子类上覆盖，orig 为原继承 IMP。
        if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
            return NO;
        }
        orig = cur;
    }
    g_swizzles[g_swizzle_count++] = (SwizzleRec){cls, sel, orig};
    if (orig_out) *orig_out = orig;
    return YES;
}

// 原 IMP 存放
static IMP g_orig_newFunctionWithName;
static IMP g_orig_newComputePSO;
static IMP g_orig_newRenderPSO;
static IMP g_orig_newCommandQueue;
static IMP g_orig_commandBuffer;
static IMP g_orig_commandBufferUnretained;
static IMP g_orig_renderEncoder;
static IMP g_orig_computeEncoder;
static IMP g_orig_computeEncoderDispatch;
static IMP g_orig_cbCommit;
static IMP g_orig_encEnd_compute;
static IMP g_orig_encEnd_render;
static IMP g_orig_setComputePipelineState;
static IMP g_orig_cSetTexture;
static IMP g_orig_cSetTextures;
static IMP g_orig_cSetBuffer;
static IMP g_orig_cSetBuffers;
static IMP g_orig_cSetBufferOffset;
static IMP g_orig_cSetBytes;
static IMP g_orig_cDispatchTG;
static IMP g_orig_cDispatchThreads;
static IMP g_orig_setRenderPipelineState;
static IMP g_orig_rSetFragmentTexture;
static IMP g_orig_rSetVertexTexture;
static IMP g_orig_rSetFragmentTextures;
static IMP g_orig_rSetVertexTextures;
static IMP g_orig_rSetFragmentBuffer;
static IMP g_orig_rSetVertexBuffer;
static IMP g_orig_rSetFragmentBuffers;
static IMP g_orig_rSetVertexBuffers;
static IMP g_orig_rSetFragmentBufferOffset;
static IMP g_orig_rSetVertexBufferOffset;
static IMP g_orig_rSetFragmentBytes;
static IMP g_orig_rSetVertexBytes;
static IMP g_orig_rSetViewport;
static IMP g_orig_drawPrimitives;
static IMP g_orig_drawPrimitivesInstanced;
static IMP g_orig_drawIndexed;
static IMP g_orig_drawIndexedInstanced;

// ---------------------------------------------------------------------------
// Encoder 状态
// ---------------------------------------------------------------------------
@interface EncState : NSObject
@property(nonatomic, strong) NSString *kind;      // render/compute/unknown
@property(nonatomic, strong) NSString *pipeline;  // 描述字符串或 nil
@property(nonatomic, strong) NSMutableDictionary *textures;  // "stage:slot" -> info
@property(nonatomic, strong) NSMutableDictionary *buffers;   // "stage:slot" -> info
@property(nonatomic, strong) NSMutableDictionary *bytes;     // "stage:slot" -> NSData
@property(nonatomic, strong) NSDictionary *attachments;      // render pass 快照
@property(nonatomic, strong) NSMutableDictionary *texObjects; // "stage:slot" -> id<MTLTexture>（随 encoder 生命周期）
@property(nonatomic, strong) NSMutableDictionary *bufObjects; // "stage:slot" -> id<MTLBuffer>（同上）
@property(nonatomic, assign) void *cbPtr;                    // 所属 command buffer
@property(nonatomic, strong) id<MTLTexture> att0Tex;         // render attachment0 对象
@property(nonatomic, strong) id<MTLTexture> depthTex;        // render depth 附件对象
@property(nonatomic, strong) id<MTLTexture> dumpVelTex;      // 速度 pass 输出（draw 时确认）
@property(nonatomic, strong) id<MTLTexture> dumpColorTex;    // TAA 当前帧色（draw 时确认）
@property(nonatomic, strong) id<MTLTexture> dumpLinDepthSrc; // LinearizeDepth 输入（原始深度候选）
@property(nonatomic, assign) BOOL tbJobPending;    // TAA 已被 TemporalBridge 接管，enc end 时编码
@property(nonatomic, assign) BOOL tbEasuPending;   // EASU 已被接管，compute enc end 时编码
@property(nonatomic, assign) BOOL hasViewport;
@property(nonatomic, assign) MTLViewport viewport;
@end

@implementation EncState
@end

static EncState *enc_state(id enc, NSString *kind) {
    pthread_mutex_lock(&g_lock);
    EncState *st = [g_enc_state objectForKey:enc];
    if (!st) {
        st = [EncState new];
        st.kind = kind;
        st.textures = [NSMutableDictionary new];
        st.buffers = [NSMutableDictionary new];
        st.bytes = [NSMutableDictionary new];
        st.texObjects = [NSMutableDictionary new];
        st.bufObjects = [NSMutableDictionary new];
        [g_enc_state setObject:st forKey:enc];
    }
    pthread_mutex_unlock(&g_lock);
    return st;
}

// ---------------------------------------------------------------------------
// 快照
// ---------------------------------------------------------------------------
// 完整 hex 转储（NSData description 超 64 字节会省略中间，不可用）。
static NSString *hex_dump(const void *p, NSUInteger len) {
    NSUInteger n = MIN(len, (NSUInteger)256);
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    const unsigned char *b = (const unsigned char *)p;
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    if (len > n) [s appendFormat:@"..(%luB)", (unsigned long)len];
    return s;
}

static NSDictionary *texture_info(id<MTLTexture> t) {
    if (!t) return nil;
    return @{
        @"ptr" : ptr_key((__bridge const void *)t),
        @"w" : @(t.width), @"h" : @(t.height), @"d" : @(t.depth),
        @"fmt" : @(t.pixelFormat), @"usage" : @(t.usage),
        @"storage" : @(t.storageMode), @"type" : @(t.textureType),
        @"mips" : @(t.mipmapLevelCount), @"array" : @(t.arrayLength),
        @"samples" : @(t.sampleCount),
        @"hazard" : @((long)t.hazardTrackingMode),
    };
}

static NSDictionary *buffer_info(id<MTLBuffer> b, NSUInteger offset) {
    if (!b) return nil;
    NSMutableDictionary *d = [@{
        @"ptr" : ptr_key((__bridge const void *)b),
        @"off" : @(offset),
        @"len" : @(b.length),
        @"storage" : @(b.storageMode),
    } mutableCopy];
    // shared/managed buffer：CPU 快照（注明时点），限量 256 字节。
    if (b.storageMode != MTLStorageModePrivate && b.length > 0 &&
        offset < b.length) {
        NSUInteger n = MIN((NSUInteger)256, b.length - offset);
        d[@"cpuSnapshotHex"] = hex_dump((const char *)b.contents + offset, n);
        d[@"cpuSnapshotNote"] = @"draw-time CPU snapshot, may differ from GPU consume time";
    } else {
        d[@"contentsNote"] = @"private: contents not read";
    }
    return d;
}

static BOOL pipeline_is_interesting(NSString *info) {
    if (!info) return NO;
    if (g_trace_all) return YES;
    for (NSString *name in g_target_names) {
        if ([info rangeOfString:name].location != NSNotFound) return YES;
    }
    return NO;
}

static void snapshot_and_log(id enc, EncState *st, const char *ev,
                             NSDictionary *extra) {
    // 时间盒：超时后不再记录 draw/dispatch（防止长时间游玩产生巨量日志）。
    if (g_trace_seconds > 0 &&
        CFAbsoluteTimeGetCurrent() - g_install_time > (CFAbsoluteTime)g_trace_seconds) {
        return;
    }
    NSMutableDictionary *e = [@{
        @"ev" : @(ev),
        @"enc" : ptr_key((__bridge const void *)enc),
        @"thread" : @(pthread_mach_thread_np(pthread_self())),
    } mutableCopy];
    if (st.pipeline) e[@"pipeline"] = st.pipeline;

    BOOL full = pipeline_is_interesting(st.pipeline);
    // 默认只记录目标 pipeline 的 draw/dispatch；其余丢弃（否则游戏内
    // 每帧数千 draw 会造成 I/O 洪峰）。BG3MF_TRACE_ALL=1 时全量。
    if (!full) return;
    if (extra) [e addEntriesFromDictionary:extra];
    {
        pthread_mutex_lock(&g_lock);
        NSMutableDictionary *tex = [NSMutableDictionary new];
        for (NSString *k in st.textures) tex[k] = st.textures[k];
        NSMutableDictionary *buf = [NSMutableDictionary new];
        for (NSString *k in st.buffers) buf[k] = st.buffers[k];
        NSMutableDictionary *byt = [NSMutableDictionary new];
        for (NSString *k in st.bytes) {
            NSData *d = st.bytes[k];
            byt[k] = @{
                @"len" : @(d.length),
                @"hex" : hex_dump(d.bytes, d.length),
            };
        }
        pthread_mutex_unlock(&g_lock);
        e[@"textures"] = tex;
        e[@"buffers"] = buf;
        e[@"bytes"] = byt;
        if (st.attachments) e[@"attachments"] = st.attachments;
        if (st.hasViewport) {
            e[@"viewport"] = @[ @(st.viewport.originX), @(st.viewport.originY),
                                @(st.viewport.width), @(st.viewport.height) ];
        }
    }
    bg3mf_trace_event(e);
}

// ---------------------------------------------------------------------------
// Hooks：MTLLibrary / MTLDevice / MTLCommandQueue / MTLCommandBuffer
// ---------------------------------------------------------------------------
static id hook_newFunctionWithName(id self, SEL _cmd, NSString *name) {
    id r = ((id(*)(id, SEL, NSString *))g_orig_newFunctionWithName)(self, _cmd, name);
    if (r && name) {
        pthread_mutex_lock(&g_lock);
        [g_func_names setObject:name forKey:r];
        pthread_mutex_unlock(&g_lock);
        bg3mf_trace_event(@{@"ev" : @"function_create", @"ptr" : ptr_key((__bridge void *)r),
                            @"name" : name});
    }
    return r;
}

static NSString *lookup_func_name(id f) {
    if (!f) return nil;
    pthread_mutex_lock(&g_lock);
    NSString *n = [g_func_names objectForKey:f];
    pthread_mutex_unlock(&g_lock);
    return n;
}

static id hook_newComputePSO(id self, SEL _cmd, id<MTLFunction> f, NSError **err) {
    id r = ((id(*)(id, SEL, id, NSError **))g_orig_newComputePSO)(self, _cmd, f, err);
    if (r) {
        NSString *name = lookup_func_name(f);
        NSString *info = name ? [@"compute:" stringByAppendingString:name]
                              : @"compute:unknown";
        pthread_mutex_lock(&g_lock);
        [g_pipeline_info setObject:info forKey:r];
        pthread_mutex_unlock(&g_lock);
        if ([info isEqualToString:@"compute:FSR"]) bg3mf_tb_note_fsr_pipeline();
        bg3mf_trace_event(@{@"ev" : @"pipeline_create", @"ptr" : ptr_key((__bridge void *)r),
                            @"info" : info});
    }
    return r;
}

static id hook_newRenderPSO(id self, SEL _cmd, MTLRenderPipelineDescriptor *desc,
                            NSError **err) {
    id r = ((id(*)(id, SEL, id, NSError **))g_orig_newRenderPSO)(self, _cmd, desc, err);
    if (r) {
        NSString *vs = lookup_func_name(desc.vertexFunction);
        NSString *ps = lookup_func_name(desc.fragmentFunction);
        NSString *info = [NSString stringWithFormat:@"render:%@+%@",
                          vs ?: @"unknown", ps ?: @"unknown"];
        pthread_mutex_lock(&g_lock);
        [g_pipeline_info setObject:info forKey:r];
        pthread_mutex_unlock(&g_lock);
        bg3mf_trace_event(@{@"ev" : @"pipeline_create", @"ptr" : ptr_key((__bridge void *)r),
                            @"info" : info});
    }
    return r;
}

static id hook_newCommandQueue(id self, SEL _cmd) {
    id r = ((id(*)(id, SEL))g_orig_newCommandQueue)(self, _cmd);
    if (r) bg3mf_trace_event(@{@"ev" : @"queue_create", @"ptr" : ptr_key((__bridge void *)r)});
    return r;
}

static id hook_commandBuffer(id self, SEL _cmd) {
    id r = ((id(*)(id, SEL))g_orig_commandBuffer)(self, _cmd);
    if (r && g_trace_all)
        bg3mf_trace_event(@{@"ev" : @"cb_create", @"ptr" : ptr_key((__bridge void *)r),
                            @"queue" : ptr_key((__bridge void *)self), @"retained" : @YES});
    return r;
}

static id hook_commandBufferUnretained(id self, SEL _cmd) {
    id r = ((id(*)(id, SEL))g_orig_commandBufferUnretained)(self, _cmd);
    if (r && g_trace_all)
        bg3mf_trace_event(@{@"ev" : @"cb_create", @"ptr" : ptr_key((__bridge void *)r),
                            @"queue" : ptr_key((__bridge void *)self), @"retained" : @NO});
    return r;
}

static void describe_render_attachments(MTLRenderPassDescriptor *d,
                                        NSMutableDictionary *e) {
    NSMutableArray *colors = [NSMutableArray new];
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i];
        if (!a.texture) continue;
        [colors addObject:@{
            @"slot" : @(i),
            @"tex" : texture_info(a.texture) ?: @{},
            @"load" : @(a.loadAction), @"store" : @(a.storeAction),
            @"resolve" : a.resolveTexture ? ptr_key((__bridge void *)a.resolveTexture)
                                          : @"none",
        }];
    }
    e[@"colorAttachments"] = colors;
    if (d.depthAttachment.texture) {
        e[@"depthAttachment"] = @{
            @"tex" : texture_info(d.depthAttachment.texture) ?: @{},
            @"load" : @(d.depthAttachment.loadAction),
            @"store" : @(d.depthAttachment.storeAction),
            @"clearDepth" : @(d.depthAttachment.clearDepth),
        };
    }
}

static id hook_renderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *desc) {
    // descriptor 会被引擎复用：此处深拷贝标量与引用信息。
    NSMutableDictionary *e = [@{
        @"ev" : @"encoder_begin", @"kind" : @"render",
        @"cb" : ptr_key((__bridge void *)self),
    } mutableCopy];
    id r = ((id(*)(id, SEL, MTLRenderPassDescriptor *))g_orig_renderEncoder)(
        self, _cmd, desc);
    if (r) {
        describe_render_attachments(desc, e);
        e[@"enc"] = ptr_key((__bridge void *)r);
        EncState *st = enc_state(r, @"render");
        st.cbPtr = (__bridge void *)self;
        st.att0Tex = desc.colorAttachments[0].texture;
        st.depthTex = desc.depthAttachment.texture;
        // 附件快照随状态保存，目标 draw 时随快照输出（默认模式不丢附件信息）。
        NSMutableDictionary *att = [e mutableCopy];
        [att removeObjectsForKeys:@[ @"ev", @"cb", @"enc" ]];
        st.attachments = att;
        if (g_trace_all) bg3mf_trace_event(e);
    }
    return r;
}

static id hook_computeEncoder(id self, SEL _cmd) {
    id r = ((id(*)(id, SEL))g_orig_computeEncoder)(self, _cmd);
    if (r) {
        enc_state(r, @"compute");
        if (g_trace_all)
            bg3mf_trace_event(@{@"ev" : @"encoder_begin", @"kind" : @"compute",
                                @"cb" : ptr_key((__bridge void *)self),
                                @"enc" : ptr_key((__bridge void *)r)});
    }
    return r;
}

static id hook_computeEncoderDispatch(id self, SEL _cmd, NSUInteger dt) {
    id r = ((id(*)(id, SEL, NSUInteger))g_orig_computeEncoderDispatch)(self, _cmd, dt);
    if (r) {
        enc_state(r, @"compute");
        if (g_trace_all)
            bg3mf_trace_event(@{@"ev" : @"encoder_begin", @"kind" : @"compute",
                                @"dispatchType" : @(dt),
                                @"cb" : ptr_key((__bridge void *)self),
                                @"enc" : ptr_key((__bridge void *)r)});
    }
    return r;
}

static void hook_cbCommit(id self, SEL _cmd) {
    if (g_trace_all) {
        bg3mf_trace_event(@{@"ev" : @"cb_commit", @"cb" : ptr_key((__bridge void *)self)});
        // 附加只读完成回调，不改变游戏行为。
        @try {
            [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                bg3mf_trace_event(@{
                    @"ev" : @"cb_completed", @"cb" : ptr_key((__bridge void *)cb),
                    @"status" : @(cb.status),
                });
            }];
        } @catch (...) {
        }
    }
    ((void(*)(id, SEL))g_orig_cbCommit)(self, _cmd);
}

// ---------------------------------------------------------------------------
// 阶段 D：合法间隙内的纹理抓取。
// 时机：游戏 render encoder 的 endEncoding（之后、commit 之前）在同一
// command buffer 追加一次 blit 拷贝（私有→shared），completed handler 落盘。
// 仅当本 encoder 出现过目标 draw（速度输出 / TAA 当前色）时触发；限量帧数。
// ---------------------------------------------------------------------------
static id<MTLTexture> bg3mf_staging(NSUInteger w, NSUInteger h, MTLPixelFormat fmt) {
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    return [g_device newTextureWithDescriptor:td];
}

static void bg3mf_dump_tex(id<MTLCommandBuffer> cb, id<MTLTexture> src,
                           const char *kindname) {
    id<MTLTexture> staging = bg3mf_staging(src.width, src.height, src.pixelFormat);
    if (!staging) {
        bg3mf_observer_log("dump: staging alloc failed");
        return;
    }
    @try {
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:src
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(src.width, src.height, 1)
                      toTexture:staging
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
        [be endEncoding];
    } @catch (NSException *ex) {
        bg3mf_observer_log("dump: blit failed");
        return;
    }
    long seq = atomic_fetch_add(&g_dump_seq, 1);
    NSUInteger w = src.width, h = src.height;
    MTLPixelFormat fmt = src.pixelFormat;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        @autoreleasepool {
            // bytesPerRow 对齐 256
            NSUInteger bpp = (fmt == MTLPixelFormatRG16Float) ? 4
                           : (fmt == MTLPixelFormatR32Float) ? 4
                           : (fmt == MTLPixelFormatRG11B10Float) ? 4
                           : (fmt == MTLPixelFormatDepth32Float_Stencil8) ? 8
                           : 4;
            NSUInteger row = (w * bpp + 255) & ~(NSUInteger)255;
            NSMutableData *data = [NSMutableData dataWithLength:row * h];
            [staging getBytes:data.mutableBytes bytesPerRow:row
                   fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
            char path[1024];
            snprintf(path, sizeof(path),
                     "%s/f%03ld_%s_%lux%lu_fmt%d.raw",
                     g_capture_dir,
                     seq, kindname, (unsigned long)w, (unsigned long)h, (int)fmt);
            [[NSFileManager defaultManager] createDirectoryAtPath:
                 [NSString stringWithUTF8String:g_capture_dir]
                withIntermediateDirectories:YES attributes:nil error:nil];
            [data writeToFile:[NSString stringWithUTF8String:path] atomically:NO];
            char meta[1024];
            snprintf(meta, sizeof(meta),
                     "%s/f%03ld_%s.meta",
                     g_capture_dir, seq, kindname);
            NSString *m = [NSString stringWithFormat:
                @"{\"seq\":%ld,\"kind\":\"%s\",\"w\":%lu,\"h\":%lu,\"fmt\":%d,\"rowBytes\":%lu,\"cbStatus\":%d}",
                seq, kindname, (unsigned long)w, (unsigned long)h, (int)fmt,
                (unsigned long)row, (int)done.status];
            [m writeToFile:[NSString stringWithUTF8String:meta]
                atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    }];
}

static void bg3mf_maybe_dump(EncState *st) {
    if (!g_device) return;
    if (atomic_load(&g_dump_seq) >= g_dump_cap * 3) return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)st.cbPtr;
    if (!cb) {
        bg3mf_observer_log("dump: no cb");
        return;
    }
    if (st.dumpVelTex) {
        bg3mf_observer_log("dump: velocity+depth blit");
        bg3mf_dump_tex(cb, st.dumpVelTex, "velocity");
        if (st.depthTex) bg3mf_dump_tex(cb, st.depthTex, "depth");
        st.dumpVelTex = nil;
        atomic_fetch_sub(&g_dump_burst, 1);
    }
    if (st.dumpColorTex) {
        bg3mf_observer_log("dump: taacolor blit");
        bg3mf_dump_tex(cb, st.dumpColorTex, "taacolor");
        st.dumpColorTex = nil;
    }
    if (st.dumpLinDepthSrc) {
        bg3mf_observer_log("dump: lindepth-src blit");
        bg3mf_dump_tex(cb, st.dumpLinDepthSrc, "lindepthsrc");
        st.dumpLinDepthSrc = nil;
    }
}

static void enc_end_common(id self) {
    if (g_trace_all)
        bg3mf_trace_event(@{@"ev" : @"encoder_end", @"enc" : ptr_key((__bridge void *)self)});
    pthread_mutex_lock(&g_lock);
    [g_enc_state removeObjectForKey:self];
    pthread_mutex_unlock(&g_lock);
}

// compute/render encoder 的 endEncoding 分开 hook，各自 orig，互不串扰。
static void hook_encEnd_compute(id self, SEL _cmd) {
    EncState *st = nil;
    pthread_mutex_lock(&g_lock);
    st = [g_enc_state objectForKey:self];
    pthread_mutex_unlock(&g_lock);
    BOOL wantEasu = st && st.tbEasuPending;
    enc_end_common(self);
    ((void(*)(id, SEL))g_orig_encEnd_compute)(self, _cmd);
    // orig 之后 encoder 已关闭，MetalFX 可以在同一 cb 上编码。
    if (wantEasu) {
        bg3mf_tb_encode_easu_if_pending(st.cbPtr);
    }
}
static void hook_encEnd_render(id self, SEL _cmd) {
    EncState *st = nil;
    pthread_mutex_lock(&g_lock);
    st = [g_enc_state objectForKey:self];
    pthread_mutex_unlock(&g_lock);
    BOOL wantDump = st && (st.dumpVelTex || st.dumpColorTex || st.dumpLinDepthSrc);
    BOOL wantTB = st && st.tbJobPending;
    enc_end_common(self);
    ((void(*)(id, SEL))g_orig_encEnd_render)(self, _cmd);
    // 必须在 orig endEncoding 之后：encoder 已关闭，才能在同 command buffer 上
    // 创建 blit/compute encoder 追加工作。
    if (wantDump) {
        bg3mf_observer_log("dump: enc_end with pending targets");
        bg3mf_maybe_dump(st);
    }
    if (wantTB) {
        bg3mf_tb_encode_if_pending(st.cbPtr);
    }
}

// ---------------------------------------------------------------------------
// Hooks：compute encoder 状态与 dispatch
// ---------------------------------------------------------------------------
static void hook_setComputePipelineState(id self, SEL _cmd, id pso) {
    pthread_mutex_lock(&g_lock);
    NSString *info = [g_pipeline_info objectForKey:pso];
    pthread_mutex_unlock(&g_lock);
    EncState *st = enc_state(self, @"compute");
    st.pipeline = info ?: @"compute:unknown-pipeline";
    ((void(*)(id, SEL, id))g_orig_setComputePipelineState)(self, _cmd, pso);
}

static void hook_cSetTexture(id self, SEL _cmd, id<MTLTexture> t, NSUInteger idx) {
    EncState *st = enc_state(self, @"compute");
    NSString *key = [NSString stringWithFormat:@"c:%lu", (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    if (t) {
        st.textures[key] = texture_info(t);
        st.texObjects[key] = t;
    } else {
        [st.textures removeObjectForKey:key];
        [st.texObjects removeObjectForKey:key];
    }
    pthread_mutex_unlock(&g_lock);
    ((void(*)(id, SEL, id, NSUInteger))g_orig_cSetTexture)(self, _cmd, t, idx);
}

static void hook_cSetBuffer(id self, SEL _cmd, id<MTLBuffer> b, NSUInteger off,
                            NSUInteger idx) {
    EncState *st = enc_state(self, @"compute");
    NSString *key = [NSString stringWithFormat:@"c:%lu", (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    if (b) {
        st.buffers[key] = buffer_info(b, off);
        st.bufObjects[key] = b;
    } else {
        [st.buffers removeObjectForKey:key];
        [st.bufObjects removeObjectForKey:key];
    }
    pthread_mutex_unlock(&g_lock);
    ((void(*)(id, SEL, id, NSUInteger, NSUInteger))g_orig_cSetBuffer)(self, _cmd, b, off, idx);
}

static void hook_cSetBytes(id self, SEL _cmd, const void *p, NSUInteger len,
                           NSUInteger idx) {
    EncState *st = enc_state(self, @"compute");
    NSString *key = [NSString stringWithFormat:@"c:%lu", (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    if (p && len > 0) st.bytes[key] = [NSData dataWithBytes:p length:len];
    else [st.bytes removeObjectForKey:key];
    pthread_mutex_unlock(&g_lock);
    ((void(*)(id, SEL, const void *, NSUInteger, NSUInteger))g_orig_cSetBytes)(
        self, _cmd, p, len, idx);
}

// range 变体：游戏实际大量使用这些 API 绑定纹理/常量。
static void hook_cSetTextures(id self, SEL _cmd, const __unsafe_unretained id<MTLTexture> *texs,
                              NSRange range) {
    EncState *st = enc_state(self, @"compute");
    pthread_mutex_lock(&g_lock);
    for (NSUInteger i = 0; i < range.length; i++) {
        NSString *key = [NSString stringWithFormat:@"c:%lu",
                         (unsigned long)(range.location + i)];
        id<MTLTexture> t = texs ? texs[i] : nil;
        if (t) {
            st.textures[key] = texture_info(t);
            st.texObjects[key] = t;
        } else {
            [st.textures removeObjectForKey:key];
            [st.texObjects removeObjectForKey:key];
        }
    }
    pthread_mutex_unlock(&g_lock);
    ((void(*)(id, SEL, const __unsafe_unretained id<MTLTexture> *, NSRange))
         g_orig_cSetTextures)(self, _cmd, texs, range);
}

static void hook_cSetBuffers(id self, SEL _cmd, const __unsafe_unretained id<MTLBuffer> *bufs,
                             const NSUInteger *offs, NSRange range) {
    EncState *st = enc_state(self, @"compute");
    pthread_mutex_lock(&g_lock);
    for (NSUInteger i = 0; i < range.length; i++) {
        NSString *key = [NSString stringWithFormat:@"c:%lu",
                         (unsigned long)(range.location + i)];
        id<MTLBuffer> b = bufs ? bufs[i] : nil;
        NSUInteger off = offs ? offs[i] : 0;
        if (b) {
            st.buffers[key] = buffer_info(b, off);
            st.bufObjects[key] = b;
        } else {
            [st.buffers removeObjectForKey:key];
            [st.bufObjects removeObjectForKey:key];
        }
    }
    pthread_mutex_unlock(&g_lock);
    ((void(*)(id, SEL, const __unsafe_unretained id<MTLBuffer> *, const NSUInteger *,
              NSRange))g_orig_cSetBuffers)(self, _cmd, bufs, offs, range);
}

static void hook_cSetBufferOffset(id self, SEL _cmd, NSUInteger off, NSUInteger idx) {
    EncState *st = enc_state(self, @"compute");
    NSString *key = [NSString stringWithFormat:@"c:%lu", (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    NSMutableDictionary *info = [st.buffers[key] mutableCopy];
    if (info) {
        info[@"off"] = @(off);
        info[@"offUpdated"] = @YES;
        st.buffers[key] = info;
    }
    pthread_mutex_unlock(&g_lock);
    ((void(*)(id, SEL, NSUInteger, NSUInteger))g_orig_cSetBufferOffset)(
        self, _cmd, off, idx);
}

// EASU 抑制检查：compute:FSR 的 dispatch 被 TemporalBridge 接管时返回 YES。
static BOOL easu_try_suppress(EncState *st) {
    if (!st.pipeline || ![st.pipeline isEqualToString:@"compute:FSR"]) return NO;
    if (!bg3mf_tb_is_enabled()) return NO;
    id<MTLBuffer> cb8 = st.bufObjects[@"c:8"];
    unsigned long off8 = 0;
    NSDictionary *info8 = st.buffers[@"c:8"];
    if (info8 && info8[@"off"]) off8 = [info8[@"off"] unsignedLongValue];
    BOOL ok = bg3mf_tb_try_record_easu(
        (__bridge void *)st.texObjects[@"c:0"],
        (__bridge void *)st.texObjects[@"c:1"],
        (__bridge void *)cb8, off8) != 0;
    if (ok) st.tbEasuPending = YES;
    return ok;
}

static void hook_cDispatchTG(id self, SEL _cmd, MTLSize tg, MTLSize tptg) {
    EncState *st = enc_state(self, @"compute");
    BOOL suppress = easu_try_suppress(st);
    snapshot_and_log(self, st, "dispatch", @{
        @"threadgroups" : @[ @(tg.width), @(tg.height), @(tg.depth) ],
        @"threadsPerTG" : @[ @(tptg.width), @(tptg.height), @(tptg.depth) ],
    });
    if (suppress) return;
    ((void(*)(id, SEL, MTLSize, MTLSize))g_orig_cDispatchTG)(self, _cmd, tg, tptg);
}

static void hook_cDispatchThreads(id self, SEL _cmd, MTLSize threads, MTLSize tptg) {
    EncState *st = enc_state(self, @"compute");
    BOOL suppress = easu_try_suppress(st);
    snapshot_and_log(self, st, "dispatchThreads", @{
        @"threads" : @[ @(threads.width), @(threads.height), @(threads.depth) ],
        @"threadsPerTG" : @[ @(tptg.width), @(tptg.height), @(tptg.depth) ],
    });
    if (suppress) return;
    ((void(*)(id, SEL, MTLSize, MTLSize))g_orig_cDispatchThreads)(self, _cmd, threads, tptg);
}

// ---------------------------------------------------------------------------
// Hooks：render encoder 状态与 draw
// ---------------------------------------------------------------------------
static void hook_setRenderPipelineState(id self, SEL _cmd, id pso) {
    pthread_mutex_lock(&g_lock);
    NSString *info = [g_pipeline_info objectForKey:pso];
    pthread_mutex_unlock(&g_lock);
    EncState *st = enc_state(self, @"render");
    st.pipeline = info ?: @"render:unknown-pipeline";
    ((void(*)(id, SEL, id))g_orig_setRenderPipelineState)(self, _cmd, pso);
}

static void r_set_tex(EncState *st, const char *stage, NSUInteger idx, id<MTLTexture> t) {
    NSString *key = [NSString stringWithFormat:@"%s:%lu", stage, (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    if (t) {
        st.textures[key] = texture_info(t);
        st.texObjects[key] = t;
    } else {
        [st.textures removeObjectForKey:key];
        [st.texObjects removeObjectForKey:key];
    }
    pthread_mutex_unlock(&g_lock);
}

static void r_set_buf(EncState *st, const char *stage, NSUInteger idx, id<MTLBuffer> b,
                      NSUInteger off) {
    NSString *key = [NSString stringWithFormat:@"%s:%lu", stage, (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    if (b) {
        st.buffers[key] = buffer_info(b, off);
        st.bufObjects[key] = b;
    } else {
        [st.buffers removeObjectForKey:key];
        [st.bufObjects removeObjectForKey:key];
    }
    pthread_mutex_unlock(&g_lock);
}

static void r_set_bytes(EncState *st, const char *stage, NSUInteger idx, const void *p,
                        NSUInteger len) {
    NSString *key = [NSString stringWithFormat:@"%s:%lu", stage, (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    if (p && len > 0) st.bytes[key] = [NSData dataWithBytes:p length:len];
    else [st.bytes removeObjectForKey:key];
    pthread_mutex_unlock(&g_lock);
}

static void hook_rSetFragmentTexture(id self, SEL _cmd, id<MTLTexture> t, NSUInteger idx) {
    r_set_tex(enc_state(self, @"render"), "f", idx, t);
    ((void(*)(id, SEL, id, NSUInteger))g_orig_rSetFragmentTexture)(self, _cmd, t, idx);
}
static void hook_rSetVertexTexture(id self, SEL _cmd, id<MTLTexture> t, NSUInteger idx) {
    r_set_tex(enc_state(self, @"render"), "v", idx, t);
    ((void(*)(id, SEL, id, NSUInteger))g_orig_rSetVertexTexture)(self, _cmd, t, idx);
}
static void hook_rSetFragmentBuffer(id self, SEL _cmd, id<MTLBuffer> b, NSUInteger off,
                                    NSUInteger idx) {
    r_set_buf(enc_state(self, @"render"), "f", idx, b, off);
    ((void(*)(id, SEL, id, NSUInteger, NSUInteger))g_orig_rSetFragmentBuffer)(
        self, _cmd, b, off, idx);
}
static void hook_rSetVertexBuffer(id self, SEL _cmd, id<MTLBuffer> b, NSUInteger off,
                                  NSUInteger idx) {
    r_set_buf(enc_state(self, @"render"), "v", idx, b, off);
    ((void(*)(id, SEL, id, NSUInteger, NSUInteger))g_orig_rSetVertexBuffer)(
        self, _cmd, b, off, idx);
}
static void hook_rSetFragmentBytes(id self, SEL _cmd, const void *p, NSUInteger len,
                                   NSUInteger idx) {
    r_set_bytes(enc_state(self, @"render"), "f", idx, p, len);
    ((void(*)(id, SEL, const void *, NSUInteger, NSUInteger))g_orig_rSetFragmentBytes)(
        self, _cmd, p, len, idx);
}
static void hook_rSetVertexBytes(id self, SEL _cmd, const void *p, NSUInteger len,
                                 NSUInteger idx) {
    r_set_bytes(enc_state(self, @"render"), "v", idx, p, len);
    ((void(*)(id, SEL, const void *, NSUInteger, NSUInteger))g_orig_rSetVertexBytes)(
        self, _cmd, p, len, idx);
}
static void hook_rSetViewport(id self, SEL _cmd, MTLViewport vp) {
    EncState *st = enc_state(self, @"render");
    st.viewport = vp;
    st.hasViewport = YES;
    ((void(*)(id, SEL, MTLViewport))g_orig_rSetViewport)(self, _cmd, vp);
}

// ---- render range 变体 ----
static void r_set_tex_range(id self, const char *stage,
                            const __unsafe_unretained id<MTLTexture> *texs,
                            NSRange range) {
    EncState *st = enc_state(self, @"render");
    pthread_mutex_lock(&g_lock);
    for (NSUInteger i = 0; i < range.length; i++) {
        NSString *key = [NSString stringWithFormat:@"%s:%lu", stage,
                         (unsigned long)(range.location + i)];
        id<MTLTexture> t = texs ? texs[i] : nil;
        if (t) {
            st.textures[key] = texture_info(t);
            st.texObjects[key] = t;
        } else {
            [st.textures removeObjectForKey:key];
            [st.texObjects removeObjectForKey:key];
        }
    }
    pthread_mutex_unlock(&g_lock);
}

static void r_set_buf_range(id self, const char *stage,
                            const __unsafe_unretained id<MTLBuffer> *bufs,
                            const NSUInteger *offs, NSRange range) {
    EncState *st = enc_state(self, @"render");
    pthread_mutex_lock(&g_lock);
    for (NSUInteger i = 0; i < range.length; i++) {
        NSString *key = [NSString stringWithFormat:@"%s:%lu", stage,
                         (unsigned long)(range.location + i)];
        id<MTLBuffer> b = bufs ? bufs[i] : nil;
        NSUInteger off = offs ? offs[i] : 0;
        if (b) {
            st.buffers[key] = buffer_info(b, off);
            st.bufObjects[key] = b;
        } else {
            [st.buffers removeObjectForKey:key];
            [st.bufObjects removeObjectForKey:key];
        }
    }
    pthread_mutex_unlock(&g_lock);
}

static void r_buf_offset(id self, const char *stage, NSUInteger off, NSUInteger idx) {
    EncState *st = enc_state(self, @"render");
    NSString *key = [NSString stringWithFormat:@"%s:%lu", stage, (unsigned long)idx];
    pthread_mutex_lock(&g_lock);
    NSMutableDictionary *info = [st.buffers[key] mutableCopy];
    if (info) {
        info[@"off"] = @(off);
        info[@"offUpdated"] = @YES;
        st.buffers[key] = info;
    }
    pthread_mutex_unlock(&g_lock);
}

static void hook_rSetFragmentTextures(id self, SEL _cmd,
                                      const __unsafe_unretained id<MTLTexture> *texs,
                                      NSRange range) {
    r_set_tex_range(self, "f", texs, range);
    ((void(*)(id, SEL, const __unsafe_unretained id<MTLTexture> *, NSRange))
         g_orig_rSetFragmentTextures)(self, _cmd, texs, range);
}
static void hook_rSetVertexTextures(id self, SEL _cmd,
                                    const __unsafe_unretained id<MTLTexture> *texs,
                                    NSRange range) {
    r_set_tex_range(self, "v", texs, range);
    ((void(*)(id, SEL, const __unsafe_unretained id<MTLTexture> *, NSRange))
         g_orig_rSetVertexTextures)(self, _cmd, texs, range);
}
static void hook_rSetFragmentBuffers(id self, SEL _cmd,
                                     const __unsafe_unretained id<MTLBuffer> *bufs,
                                     const NSUInteger *offs, NSRange range) {
    r_set_buf_range(self, "f", bufs, offs, range);
    ((void(*)(id, SEL, const __unsafe_unretained id<MTLBuffer> *, const NSUInteger *,
              NSRange))g_orig_rSetFragmentBuffers)(self, _cmd, bufs, offs, range);
}
static void hook_rSetVertexBuffers(id self, SEL _cmd,
                                   const __unsafe_unretained id<MTLBuffer> *bufs,
                                   const NSUInteger *offs, NSRange range) {
    r_set_buf_range(self, "v", bufs, offs, range);
    ((void(*)(id, SEL, const __unsafe_unretained id<MTLBuffer> *, const NSUInteger *,
              NSRange))g_orig_rSetVertexBuffers)(self, _cmd, bufs, offs, range);
}
static void hook_rSetFragmentBufferOffset(id self, SEL _cmd, NSUInteger off,
                                          NSUInteger idx) {
    r_buf_offset(self, "f", off, idx);
    ((void(*)(id, SEL, NSUInteger, NSUInteger))g_orig_rSetFragmentBufferOffset)(
        self, _cmd, off, idx);
}
static void hook_rSetVertexBufferOffset(id self, SEL _cmd, NSUInteger off,
                                        NSUInteger idx) {
    r_buf_offset(self, "v", off, idx);
    ((void(*)(id, SEL, NSUInteger, NSUInteger))g_orig_rSetVertexBufferOffset)(
        self, _cmd, off, idx);
}

// 返回 YES = 该 draw 已被 TemporalBridge 接管，调用方必须跳过原始 draw。
static BOOL log_draw(id self, const char *what, NSDictionary *args) {
    EncState *st = enc_state(self, @"render");
    BOOL suppress = NO;
    // 阶段 D：速度 pass 的 draw 处检查哨兵文件，触发一次 3 帧连发抓取。
    if (st.pipeline && [st.pipeline containsString:@"VelocityBufferCamera_PS"]) {
        if (atomic_load(&g_dump_burst) == 0 &&
            atomic_load(&g_dump_seq) < g_dump_cap * 3 &&
                        access(g_sentinel, F_OK) == 0) {
                        unlink(g_sentinel);
            atomic_store(&g_dump_burst, 3);
            bg3mf_observer_log("dump burst armed (3 frames)");
        }
        if (atomic_load(&g_dump_burst) > 0) {
            st.dumpVelTex = st.att0Tex;
            bg3mf_observer_log(st.dumpVelTex ? "dump: vel marked"
                                             : "dump: vel att0 nil");
        }
        bg3mf_tb_note_velocity((__bridge void *)st.att0Tex);
        bg3mf_tb_note_velocity((__bridge void *)st.att0Tex);
    } else if (st.pipeline && [st.pipeline containsString:@"PPTAA_PS"]) {
        if (atomic_load(&g_dump_burst) > 0) st.dumpColorTex = st.texObjects[@"f:0"];
        // 阶段 E：接管 TAA——记录输入并抑制原始 draw，encoder 结束时改由 MetalFX 写入。
        if (bg3mf_tb_is_enabled() && st.hasViewport &&
            st.viewport.width > g_tb_min_vp) {
            id<MTLBuffer> cb8 = st.bufObjects[@"f:8"];
            unsigned long off8 = 0;
            NSDictionary *info8 = st.buffers[@"f:8"];
            if (info8 && info8[@"off"]) off8 = [info8[@"off"] unsignedLongValue];
            suppress = bg3mf_tb_try_record_taa(
                (__bridge void *)st.texObjects[@"f:0"],
                (__bridge void *)st.texObjects[@"f:2"],
                (__bridge void *)st.att0Tex,
                (__bridge void *)cb8, off8) != 0;
            if (suppress) st.tbJobPending = YES;
        }
    } else if (st.pipeline && [st.pipeline containsString:@"LinearizeDepth"] &&
               st.hasViewport && st.viewport.width > g_tb_min_vp) {
        // 主视口的 LinearizeDepth 输入 = 原始 device depth（证据 id 0x22f3e110）
        if (atomic_load(&g_dump_burst) > 0)
            st.dumpLinDepthSrc = st.texObjects[@"f:0"];
        bg3mf_tb_note_depth_source((__bridge void *)st.texObjects[@"f:0"]);
    }
    NSMutableDictionary *extra = [NSMutableDictionary dictionaryWithDictionary:args];
    extra[@"draw"] = @(what);
    if (suppress) extra[@"suppressed"] = @YES;
    snapshot_and_log(self, st, "draw", extra);
    return suppress;
}

static void hook_drawPrimitives(id self, SEL _cmd, NSUInteger prim, NSUInteger vs,
                                NSUInteger vc) {
    BOOL suppress = log_draw(self, "primitives",
             @{@"prim" : @(prim), @"vertexStart" : @(vs), @"vertexCount" : @(vc)});
    if (suppress) return;
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))g_orig_drawPrimitives)(
        self, _cmd, prim, vs, vc);
}
static void hook_drawPrimitivesInstanced(id self, SEL _cmd, NSUInteger prim,
                                         NSUInteger vs, NSUInteger vc, NSUInteger ic) {
    BOOL suppress = log_draw(self, "primitivesInstanced",
             @{@"prim" : @(prim), @"vertexStart" : @(vs), @"vertexCount" : @(vc),
               @"instanceCount" : @(ic)});
    if (suppress) return;
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger))
         g_orig_drawPrimitivesInstanced)(self, _cmd, prim, vs, vc, ic);
}
static void hook_drawIndexed(id self, SEL _cmd, NSUInteger prim, NSUInteger ic,
                             NSUInteger it, id<MTLBuffer> ib, NSUInteger ibo) {
    BOOL suppress = log_draw(self, "indexed",
             @{@"prim" : @(prim), @"indexCount" : @(ic), @"indexType" : @(it),
               @"indexBuffer" : ptr_key((__bridge void *)ib),
               @"indexBufferOffset" : @(ibo)});
    if (suppress) return;
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger))
         g_orig_drawIndexed)(self, _cmd, prim, ic, it, ib, ibo);
}
static void hook_drawIndexedInstanced(id self, SEL _cmd, NSUInteger prim, NSUInteger ic,
                                      NSUInteger it, id<MTLBuffer> ib, NSUInteger ibo,
                                      NSUInteger inst) {
    BOOL suppress = log_draw(self, "indexedInstanced",
             @{@"prim" : @(prim), @"indexCount" : @(ic), @"indexType" : @(it),
               @"indexBuffer" : ptr_key((__bridge void *)ib),
               @"indexBufferOffset" : @(ibo), @"instanceCount" : @(inst)});
    if (suppress) return;
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger))
         g_orig_drawIndexedInstanced)(self, _cmd, prim, ic, it, ib, ibo, inst);
}

// ---------------------------------------------------------------------------
// 安装：动态发现具体类
// ---------------------------------------------------------------------------

static void obs_logf(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    bg3mf_observer_log(buf);
}

void bg3mf_observer_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      @autoreleasepool {
        if (getenv("BG3MF_OBSERVER") && strcmp(getenv("BG3MF_OBSERVER"), "0") == 0) {
            obs_logf("observer disabled by env");
            return;
        }
        g_trace_all = getenv("BG3MF_TRACE_ALL") != NULL;
        {
            const char *df = getenv("BG3MF_DUMP_FRAMES");
            if (df) g_dump_cap = atol(df);
            const char *ts = getenv("BG3MF_TRACE_SECONDS");
            if (ts) g_trace_seconds = atol(ts);
            const char *mv = getenv("BG3MF_TB_MIN_VP");
            if (mv) g_tb_min_vp = atof(mv);
        }
        g_install_time = CFAbsoluteTimeGetCurrent();
        g_target_names = [NSSet setWithArray:@[
            @"PPTAA_PS", @"FSR", @"FSR_SLOW", @"FSR_RCAS", @"FSR_RCAS_SLOW",
            @"FSR_Tonemap", @"LinearizeDepth", @"VelocityBufferCamera_VS",
            @"VelocityBufferCamera_PS"
        ]];
        g_func_names = [[NSMapTable alloc]
            initWithKeyOptions:NSPointerFunctionsStrongMemory
                  valueOptions:NSPointerFunctionsStrongMemory
                      capacity:4096];
        g_pipeline_info = [[NSMapTable alloc]
            initWithKeyOptions:NSPointerFunctionsStrongMemory
                  valueOptions:NSPointerFunctionsStrongMemory
                      capacity:4096];
        g_enc_state = [[NSMapTable alloc]
            initWithKeyOptions:NSPointerFunctionsStrongMemory
                  valueOptions:NSPointerFunctionsStrongMemory
                      capacity:256];

        snprintf(g_runs_dir, sizeof(g_runs_dir), "%s/runs", bg3mf_home());
        snprintf(g_sentinel, sizeof(g_sentinel), "%s/DUMP_NOW", g_runs_dir);
        snprintf(g_capture_dir, sizeof(g_capture_dir), "%s/capture", g_runs_dir);
        // trace 默认关闭（发布版静默）；BG3MF_TRACE=1 显式开启（开发用）。
        if (getenv("BG3MF_TRACE")) {
            const char *log_dir = getenv("BG3MF_TRACE_DIR");
            char trace_path[1024];
            snprintf(trace_path, sizeof(trace_path),
                     "%s/trace_%d.jsonl",
                     log_dir ? log_dir : g_runs_dir,
                     getpid());
            bg3mf_trace_init(trace_path);
        }

        // 通过自建实例动态发现具体实现类；不假定私有类名。
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            obs_logf("observer: no default device");
            return;
        }
        g_device = dev;
        Class deviceCls = object_getClass(dev);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        Class queueCls = object_getClass(q);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        Class cbCls = object_getClass(cb);
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        Class compEncCls = object_getClass(ce);
        [ce endEncoding];

        // render encoder 类：构造一个最小 render pass。
        MTLTextureDescriptor *rtd =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:16
                                                              height:16
                                                           mipmapped:NO];
        id<MTLTexture> rt = [dev newTextureWithDescriptor:rtd];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = rt;
        rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLCommandBuffer> cb2 = [q commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb2 renderCommandEncoderWithDescriptor:rpd];
        Class rendEncCls = object_getClass(re);
        [re endEncoding];

        id<MTLLibrary> lib = [dev newDefaultLibrary];
        if (!lib) {
            // 无默认库（如命令行宿主）：尝试 dylib 旁随的 smokeinputs.metallib。
            const char *self = bg3mf_self_path();
            if (self && self[0]) {
                NSString *dir = [[NSString stringWithUTF8String:self]
                    stringByDeletingLastPathComponent];
                NSString *p =
                    [dir stringByAppendingPathComponent:@"smokeinputs.metallib"];
                lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:p] error:nil];
            }
        }
        Class libCls = lib ? object_getClass(lib) : Nil;

        obs_logf("classes: device=%s queue=%s cb=%s compEnc=%s rendEnc=%s lib=%s",
                 class_getName(deviceCls), class_getName(queueCls),
                 class_getName(cbCls), class_getName(compEncCls),
                 class_getName(rendEncCls), libCls ? class_getName(libCls) : "nil");

        int ok = 0, fail = 0;
#define SW(cls, sel, hook, store)                                        \
    do {                                                                 \
        if (swizzle_install(cls, sel, (IMP)(hook), (IMP *)(store))) ok++; \
        else {                                                           \
            fail++;                                                      \
            obs_logf("swizzle miss: %s %s", class_getName(cls), #sel);   \
        }                                                                \
    } while (0)

        if (libCls) {
            SW(libCls, @selector(newFunctionWithName:), hook_newFunctionWithName,
               &g_orig_newFunctionWithName);
        }
        SW(deviceCls, @selector(newComputePipelineStateWithFunction:error:),
           hook_newComputePSO, &g_orig_newComputePSO);
        SW(deviceCls, @selector(newRenderPipelineStateWithDescriptor:error:),
           hook_newRenderPSO, &g_orig_newRenderPSO);
        SW(deviceCls, @selector(newCommandQueue), hook_newCommandQueue,
           &g_orig_newCommandQueue);
        SW(queueCls, @selector(commandBuffer), hook_commandBuffer,
           &g_orig_commandBuffer);
        SW(queueCls, @selector(commandBufferWithUnretainedReferences),
           hook_commandBufferUnretained, &g_orig_commandBufferUnretained);
        SW(cbCls, @selector(renderCommandEncoderWithDescriptor:), hook_renderEncoder,
           &g_orig_renderEncoder);
        SW(cbCls, @selector(computeCommandEncoder), hook_computeEncoder,
           &g_orig_computeEncoder);
        SW(cbCls, @selector(computeCommandEncoderWithDispatchType:),
           hook_computeEncoderDispatch, &g_orig_computeEncoderDispatch);
        SW(cbCls, @selector(commit), hook_cbCommit, &g_orig_cbCommit);

        SEL endSel = @selector(endEncoding);
        SW(compEncCls, endSel, hook_encEnd_compute, &g_orig_encEnd_compute);
        SW(rendEncCls, endSel, hook_encEnd_render, &g_orig_encEnd_render);

        SW(compEncCls, @selector(setComputePipelineState:),
           hook_setComputePipelineState, &g_orig_setComputePipelineState);
        SW(compEncCls, @selector(setTexture:atIndex:), hook_cSetTexture,
           &g_orig_cSetTexture);
        SW(compEncCls, @selector(setTextures:withRange:), hook_cSetTextures,
           &g_orig_cSetTextures);
        SW(compEncCls, @selector(setBuffer:offset:atIndex:), hook_cSetBuffer,
           &g_orig_cSetBuffer);
        SW(compEncCls, @selector(setBuffers:offsets:withRange:), hook_cSetBuffers,
           &g_orig_cSetBuffers);
        SW(compEncCls, @selector(setBufferOffset:atIndex:), hook_cSetBufferOffset,
           &g_orig_cSetBufferOffset);
        SW(compEncCls, @selector(setBytes:length:atIndex:), hook_cSetBytes,
           &g_orig_cSetBytes);
        SW(compEncCls, @selector(dispatchThreadgroups:threadsPerThreadgroup:),
           hook_cDispatchTG, &g_orig_cDispatchTG);
        SW(compEncCls, @selector(dispatchThreads:threadsPerThreadgroup:),
           hook_cDispatchThreads, &g_orig_cDispatchThreads);

        SW(rendEncCls, @selector(setRenderPipelineState:),
           hook_setRenderPipelineState, &g_orig_setRenderPipelineState);
        SW(rendEncCls, @selector(setFragmentTexture:atIndex:),
           hook_rSetFragmentTexture, &g_orig_rSetFragmentTexture);
        SW(rendEncCls, @selector(setVertexTexture:atIndex:), hook_rSetVertexTexture,
           &g_orig_rSetVertexTexture);
        SW(rendEncCls, @selector(setFragmentTextures:withRange:),
           hook_rSetFragmentTextures, &g_orig_rSetFragmentTextures);
        SW(rendEncCls, @selector(setVertexTextures:withRange:),
           hook_rSetVertexTextures, &g_orig_rSetVertexTextures);
        SW(rendEncCls, @selector(setFragmentBuffer:offset:atIndex:),
           hook_rSetFragmentBuffer, &g_orig_rSetFragmentBuffer);
        SW(rendEncCls, @selector(setVertexBuffer:offset:atIndex:),
           hook_rSetVertexBuffer, &g_orig_rSetVertexBuffer);
        SW(rendEncCls, @selector(setFragmentBuffers:offsets:withRange:),
           hook_rSetFragmentBuffers, &g_orig_rSetFragmentBuffers);
        SW(rendEncCls, @selector(setVertexBuffers:offsets:withRange:),
           hook_rSetVertexBuffers, &g_orig_rSetVertexBuffers);
        SW(rendEncCls, @selector(setFragmentBufferOffset:atIndex:),
           hook_rSetFragmentBufferOffset, &g_orig_rSetFragmentBufferOffset);
        SW(rendEncCls, @selector(setVertexBufferOffset:atIndex:),
           hook_rSetVertexBufferOffset, &g_orig_rSetVertexBufferOffset);
        SW(rendEncCls, @selector(setFragmentBytes:length:atIndex:),
           hook_rSetFragmentBytes, &g_orig_rSetFragmentBytes);
        SW(rendEncCls, @selector(setVertexBytes:length:atIndex:),
           hook_rSetVertexBytes, &g_orig_rSetVertexBytes);
        SW(rendEncCls, @selector(setViewport:), hook_rSetViewport,
           &g_orig_rSetViewport);
        SW(rendEncCls, @selector(drawPrimitives:vertexStart:vertexCount:),
           hook_drawPrimitives, &g_orig_drawPrimitives);
        SW(rendEncCls,
           @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:),
           hook_drawPrimitivesInstanced, &g_orig_drawPrimitivesInstanced);
        SW(rendEncCls,
           @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:
                     indexBufferOffset:),
           hook_drawIndexed, &g_orig_drawIndexed);
        SW(rendEncCls,
           @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:
                     indexBufferOffset:instanceCount:),
           hook_drawIndexedInstanced, &g_orig_drawIndexedInstanced);
#undef SW

        obs_logf("observer installed: ok=%d miss=%d", ok, fail);
        bg3mf_trace_event(@{@"ev" : @"observer_installed", @"ok" : @(ok),
                            @"miss" : @(fail), @"traceAll" : @(g_trace_all)});
      }
    });
}
