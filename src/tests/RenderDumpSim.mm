// 模拟游戏渲染模式：render pass + 目标名字 pipeline + draw，验证抓取链路。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <unistd.h>

#ifndef SMOKE_METALLIB_PATH
#define SMOKE_METALLIB_PATH "smokeinputs.metallib"
#endif

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
        id<MTLFunction> vs = [lib newFunctionWithName:@"VelocityBufferCamera_VS"];
        id<MTLFunction> ps = [lib newFunctionWithName:@"VelocityBufferCamera_PS"];
        if (!vs || !ps) { printf("no functions\n"); return 1; }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vs;
        pd.fragmentFunction = ps;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        id<MTLRenderPipelineState> pso =
            [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) { printf("pso fail: %s\n", err.localizedDescription.UTF8String); return 1; }

        // 速度目标 + 深度附件（模拟游戏的 velocity pass）
        MTLTextureDescriptor *vtd =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                               width:640 height:360 mipmapped:NO];
        vtd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> vel = [dev newTextureWithDescriptor:vtd];
        MTLTextureDescriptor *dtd =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                               width:640 height:360 mipmapped:NO];
        dtd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:dtd];

        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = vel;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.depthAttachment.texture = depth;
        rpd.depthAttachment.loadAction = MTLLoadActionClear;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;

        for (int f = 0; f < 5; f++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> re =
                    [cb renderCommandEncoderWithDescriptor:rpd];
                [re setRenderPipelineState:pso];
                [re drawPrimitives:MTLPrimitiveTypeTriangle
                       vertexStart:0
                       vertexCount:3];
                [re endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                if (cb.status != MTLCommandBufferStatusCompleted) {
                    printf("cb error frame %d\n", f);
                    return 1;
                }
            }
        }
        // 等 completed handler 落盘
        usleep(1500 * 1000);
        printf("RENDER_SIM_DONE\n");
        return 0;
    }
}
