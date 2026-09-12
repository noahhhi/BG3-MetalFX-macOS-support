// 阶段 E 端到端无 GUI 验证：模拟游戏的 LinearizeDepth + PPTAA 两个 pass，
// 注入带 TemporalBridge 的 dylib 后断言：
// 1. PPTAA 原始 draw 被抑制（输出不再是 PPTAA_PS 的常量色）；
// 2. MetalFX scaler 实际写入了输出（约等于输入颜色的 AA 结果）。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <cmath>

#ifndef SMOKE_METALLIB_PATH
#define SMOKE_METALLIB_PATH "smokeinputs.metallib"
#endif

#define W 640
#define H 360

static id<MTLTexture> mk_tex(id<MTLDevice> dev, MTLPixelFormat fmt, NSUInteger w,
                             NSUInteger h, MTLTextureUsage usage) {
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                           width:w height:h mipmapped:NO];
    td.usage = usage;
    return [dev newTextureWithDescriptor:td];
}

int main(void) {
    @autoreleasepool {
        const char *delay = getenv("SMOKE_START_DELAY_MS");
        if (delay) usleep((useconds_t)atol(delay) * 1000);

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib =
            [dev newLibraryWithURL:[NSURL fileURLWithPath:@(SMOKE_METALLIB_PATH)]
                             error:&err];
        if (!lib) { printf("no lib\n"); return 1; }

        BOOL fsr = getenv("SIM_FSR") != NULL;
        double scale = getenv("SIM_SCALE") ? atof(getenv("SIM_SCALE")) : 1.5;
        NSUInteger outW = (NSUInteger)(W*scale), outH = (NSUInteger)(H*scale);
        // --- 资源：模拟游戏的 TAA 输入集 ---
        id<MTLTexture> color = mk_tex(dev, MTLPixelFormatRG11B10Float, W, H,
                                      MTLTextureUsageShaderRead |
                                      MTLTextureUsageShaderWrite);
        id<MTLTexture> motion = mk_tex(dev, MTLPixelFormatRG16Float, W, H,
                                       MTLTextureUsageShaderRead |
                                       MTLTextureUsageRenderTarget);
        id<MTLTexture> depthDS = mk_tex(dev, MTLPixelFormatDepth32Float_Stencil8, W, H,
                                        MTLTextureUsageShaderRead |
                                        MTLTextureUsageRenderTarget);
        id<MTLTexture> linOut = mk_tex(dev, MTLPixelFormatR32Float, W, H,
                                       MTLTextureUsageRenderTarget);
        id<MTLTexture> taaOut = mk_tex(dev, MTLPixelFormatRG11B10Float, W, H,
                                       MTLTextureUsageShaderRead |
                                       MTLTextureUsageShaderWrite |
                                       MTLTextureUsageRenderTarget);

        // TemporalConstants：224B，jitter 在 +0xd0（像素单位）
        id<MTLBuffer> consts = [dev newBufferWithLength:224
                                                options:MTLResourceStorageModeShared];
        memset(consts.contents, 0, 224);
        float *jitter = (float *)((char *)consts.contents + 0xd0);
        jitter[0] = 0.25f;
        jitter[1] = -0.125f;

        // 填充输入颜色（渐变，CPU 直写 RG11B10Float 麻烦——用 blit 清零后
        // 让 MetalFX 的输入为非零即可：改用一个 render pass 画渐变太费，直接
        // 用 PPTAA 常量输入纹理方案：填半精度 0.5）
        {
            // RG11B10Float packed：0.5 的 fp11 是 exp=15,m=0 → 0x3C00? 用 pass 填充更稳。
            // 简单方案：VelocityBufferCamera_PS pipeline 画常量到 motion（=1.5,-2.5），
            // 颜色输入用一个常量填充 pass。
        }

        id<MTLFunction> linVS = [lib newFunctionWithName:@"LinearizeDepth_VS"];
        id<MTLFunction> linPS = [lib newFunctionWithName:@"LinearizeDepth_PS"];
        id<MTLFunction> taaVS = [lib newFunctionWithName:@"VelocityBufferCamera_VS"];
        id<MTLFunction> taaPS = [lib newFunctionWithName:@"PPTAA_PS"];
        id<MTLFunction> fillPS = [lib newFunctionWithName:@"VelocityBufferCamera_PS"];

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = linVS;
        pd.fragmentFunction = linPS;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        id<MTLRenderPipelineState> linPSO =
            [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!linPSO) { printf("lin pso fail\n"); return 1; }

        pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = taaVS;
        pd.fragmentFunction = taaPS;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG11B10Float;
        id<MTLRenderPipelineState> taaPSO =
            [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!taaPSO) { printf("taa pso fail\n"); return 1; }

        pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = taaVS;
        pd.fragmentFunction = fillPS;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
        id<MTLRenderPipelineState> fillPSO =
            [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!fillPSO) { printf("fill pso fail\n"); return 1; }

        id<MTLComputePipelineState> easuPSO = nil, rcasPSO = nil, consumePSO = nil;
        id<MTLTexture> easuOut = nil, fsrOut = nil, finalOut = nil;
        if (fsr || getenv("SIM_CREATE_FSR_ONLY")) {
            easuPSO = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"FSR"] error:&err];
            rcasPSO = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"FSR_RCAS"] error:&err];
            consumePSO = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"consume_fsr"] error:&err];
            finalOut = mk_tex(dev, MTLPixelFormatRG11B10Float, outW, outH, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
            easuOut = mk_tex(dev, MTLPixelFormatRG11B10Float, outW, outH, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
            fsrOut = mk_tex(dev, MTLPixelFormatRG11B10Float, outW, outH, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        }
        // Known nonzero input: green, distinct from both original shader sentinels.
        uint32_t green = (0x380u << 11);
        NSMutableData *pixels = [NSMutableData dataWithLength:W*H*4];
        for (unsigned i = 0; i < W*H; ++i) ((uint32_t*)pixels.mutableBytes)[i] = green;
        [color replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:W*4];
        id<MTLCommandQueue> q = [dev newCommandQueue];

        for (int f = 0; f < 8; f++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [q commandBuffer];

                // pass 0：填充 motion（VelocityBufferCamera pipeline，会命中哨兵逻辑，
                //          但 BG3MF_DUMP_FRAMES 未设默认 cap=0 不影响）
                {
                    MTLRenderPassDescriptor *rpd =
                        [MTLRenderPassDescriptor renderPassDescriptor];
                    rpd.colorAttachments[0].texture = motion;
                    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> re =
                        [cb renderCommandEncoderWithDescriptor:rpd];
                    [re setRenderPipelineState:fillPSO];
                    [re setViewport:(MTLViewport){0, 0, W, H, 0, 1}];
                    [re drawPrimitives:MTLPrimitiveTypeTriangle
                           vertexStart:0 vertexCount:3];
                    [re endEncoding];
                }

                // Initialize device depth on the GPU, never read undefined test input.
                {
                    MTLRenderPassDescriptor *dp = [MTLRenderPassDescriptor renderPassDescriptor];
                    dp.depthAttachment.texture = depthDS;
                    dp.depthAttachment.loadAction = MTLLoadActionClear;
                    dp.depthAttachment.storeAction = MTLStoreActionStore;
                    dp.depthAttachment.clearDepth = 0.5;
                    id<MTLRenderCommandEncoder> de = [cb renderCommandEncoderWithDescriptor:dp];
                    [de endEncoding];
                }
                // pass 1：LinearizeDepth（f:0 = 深度源）
                {
                    MTLRenderPassDescriptor *rpd =
                        [MTLRenderPassDescriptor renderPassDescriptor];
                    rpd.colorAttachments[0].texture = linOut;
                    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> re =
                        [cb renderCommandEncoderWithDescriptor:rpd];
                    [re setRenderPipelineState:linPSO];
                    [re setFragmentTexture:depthDS atIndex:0];
                    [re setViewport:(MTLViewport){0, 0, W, H, 0, 1}];
                    [re drawPrimitives:MTLPrimitiveTypeTriangle
                           vertexStart:0 vertexCount:3];
                    [re endEncoding];
                }

                // pass 2：PPTAA（f:0 色 f:2 速度 f:8 constants，输出 taaOut）
                {
                    MTLRenderPassDescriptor *rpd =
                        [MTLRenderPassDescriptor renderPassDescriptor];
                    rpd.colorAttachments[0].texture = taaOut;
                    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> re =
                        [cb renderCommandEncoderWithDescriptor:rpd];
                    [re setRenderPipelineState:taaPSO];
                    [re setFragmentTexture:color atIndex:0];
                    [re setFragmentTexture:motion atIndex:2];
                    [re setFragmentBuffer:consts offset:0 atIndex:8];
                    [re setViewport:(MTLViewport){0, 0, W, H, 0, 1}];
                    [re drawPrimitives:MTLPrimitiveTypeTriangle
                           vertexStart:0 vertexCount:3];
                    [re endEncoding];
                }

                if (fsr) {
                    id<MTLComputeCommandEncoder> ce = (f & 1)
                        ? [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial]
                        : [cb computeCommandEncoder];
                    [ce setComputePipelineState:easuPSO];
                    [ce setTexture:color atIndex:0];
                    [ce setTexture:easuOut atIndex:1];
                    [ce setBuffer:consts offset:0 atIndex:8];
                    [ce dispatchThreads:MTLSizeMake(outW,outH,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
                    [ce setComputePipelineState:rcasPSO];
                    [ce setTexture:easuOut atIndex:0];
                    [ce setTexture:fsrOut atIndex:2];
                    [ce dispatchThreadgroups:MTLSizeMake((outW+15)/16,(outH+15)/16,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
                    [ce setComputePipelineState:consumePSO];
                    [ce setTexture:fsrOut atIndex:0]; [ce setTexture:finalOut atIndex:2];
                    [ce dispatchThreads:MTLSizeMake(outW,outH,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
                    [ce endEncoding];
                }
                [cb commit];
                [cb waitUntilCompleted];
                if (cb.status != MTLCommandBufferStatusCompleted) {
                    printf("cb error frame %d: %s\n", f,
                           cb.error.localizedDescription.UTF8String);
                    return 1;
                }
            }
        }
        usleep(500 * 1000);

        id<MTLTexture> result = fsr ? finalOut : taaOut;
        NSUInteger rb = ((result.width * 4 + 255) / 256) * 256;
        id<MTLBuffer> readback = [dev newBufferWithLength:rb*result.height options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:result sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                  sourceSize:MTLSizeMake(result.width,result.height,1) toBuffer:readback destinationOffset:0
                  destinationBytesPerRow:rb destinationBytesPerImage:rb*result.height];
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        unsigned good = 0, total = 0;
        for (NSUInteger y=result.height/4; y<result.height*3/4; y+=8) {
            for (NSUInteger x=result.width/4; x<result.width*3/4; x+=8) {
                uint32_t px = *(uint32_t*)((char*)readback.contents+y*rb+x*4);
                unsigned r=px&2047, g=(px>>11)&2047, b=(px>>22)&1023;
                good += fsr ? (r < 0x100 && g >= 0x370 && g <= 0x390 && b < 0x80)
                            : (r == 0x340 && g == 0x380 && b == 0x1d0);
                total++;
            }
        }
        printf("%s pixels matching expected color: %u/%u\n", fsr ? "FSR" : "TAA", good, total);
        BOOL pass = good == total && total > 0;
        printf("BRIDGE_SIM_RESULT %s\n", pass ? "PASS" : "FAIL");
        return pass ? 0 : 1;
    }
}
