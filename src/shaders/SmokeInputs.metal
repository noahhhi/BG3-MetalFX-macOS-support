// bg3-metalfx 阶段 C：合成输入生成 kernel。
// pattern 是解析已知的确定性函数，便于 CPU 端校验 Temporal 输出。
#include <metal_stdlib>
using namespace metal;

static float3 pattern(int2 p) {
    float fx = (float)p.x / 1280.0f;
    float fy = (float)p.y / 720.0f;
    float checker = (((p.x / 32) + (p.y / 32)) & 1) ? 0.9f : 0.1f;
    return float3(fx, fy, checker);
}

kernel void fill_color(texture2d<float, access::write> out [[texture(0)]],
                       constant int2 &offset [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint2 dims = uint2(out.get_width(), out.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) return;
    int2 p = int2(gid) + offset;
    out.write(float4(pattern(p), 1.0), gid);
}

kernel void fill_depth(texture2d<float, access::write> out [[texture(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint2 dims = uint2(out.get_width(), out.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) return;
    out.write(0.5, gid);
}

kernel void fill_motion(texture2d<float, access::write> out [[texture(0)]],
                        constant float2 &motion [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint2 dims = uint2(out.get_width(), out.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) return;
    out.write(float4(motion, 0.0, 0.0), gid);
}

// RenderDumpSim 用：与游戏同名的目标函数，验证观测器名字识别与抓取链路。
struct SimVSOut { float4 pos [[position]]; };
vertex SimVSOut VelocityBufferCamera_VS(uint vid [[vertex_id]]) {
    SimVSOut o;
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    o.pos = float4(p, 0.0, 1.0);
    return o;
}
fragment float2 VelocityBufferCamera_PS(SimVSOut in [[stage_in]]) {
    return float2(1.5, -2.5);
}
fragment float4 PPTAA_PS(SimVSOut in [[stage_in]]) {
    return float4(0.25, 0.5, 0.75, 1.0);
}
vertex SimVSOut LinearizeDepth_VS(uint vid [[vertex_id]]) {
    SimVSOut o;
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    o.pos = float4(p, 0.0, 1.0);
    return o;
}
fragment float4 LinearizeDepth_PS(SimVSOut in [[stage_in]]) {
    return float4(0.01, 0.0, 0.0, 1.0);
}
