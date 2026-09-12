#!/usr/bin/env python3
"""bg3-metalfx 阶段 D：抓取帧离线分析。

读取 runs/capture/ 的速度/深度/颜色 raw dump，验证：
1. 速度纹理（RG16Float）数值范围与方向——与 TemporalConstants 里的相机位移对比。
2. 深度（Depth32Float_Stencil8 或 R32Float）分布——近大远小还是反之（reversed-Z）。
3. TAA 当前帧色（RG11B10Float）基本统计（非 NaN、范围）。

约定候选（来自逆向证据）：
- 速度为 current-minus-previous 像素位移（未除分辨率）；MetalFX 需要 previous-minus-current，
  即 motionVectorScale=(-1,-1)（前提：同尺寸同坐标系）。
- 相机右转（E 键绕轨道）：场景内容在屏幕上向左移动 → 背景的 current-minus-previous 速度应为 -x。
"""
import json, struct, sys, os, math, glob
import numpy as np

CAP = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Application Support/BG3MetalFX/runs/capture")

def half_to_float(arr_u16):
    return arr_u16.view(np.float16).astype(np.float32)

def load_raw(path, w, h, fmt, rowbytes):
    data = np.fromfile(path, dtype=np.uint8)
    need = rowbytes * h
    if len(data) < need:
        raise ValueError(f"short file {len(data)} < {need}")
    data = data[:need].reshape(h, rowbytes)
    if fmt == 65:   # RG16Float
        px = rowbytes // 4
        v = data[:, :w*4].copy().view(np.uint16).reshape(h, w, 2)
        return half_to_float(v)
    if fmt == 55:   # R32Float
        v = data[:, :w*4].copy().view(np.float32).reshape(h, w)
        return v
    if fmt == 260:  # Depth32Float_Stencil8：深度在前 4 字节
        v = data[:, :w*8].copy().view(np.uint32).reshape(h, w, 2)
        d = v[..., 0].view(np.float32)
        return d
    if fmt == 92:   # RG11B10Float packed
        v = data[:, :w*4].copy().view(np.uint32).reshape(h, w)
        r = (v & 0x7FF).astype(np.float32)
        g = ((v >> 11) & 0x7FF).astype(np.float32)
        b = ((v >> 22) & 0x3FF).astype(np.float32)
        def fp11(x, bits):
            # 无符号 fp11/fp10：5 阶码 + 6/5 尾数
            mbits = 6 if bits == 11 else 5
            mmask = (1 << mbits) - 1
            e = (x.astype(np.int32) >> mbits) & 0x1F
            m = (x.astype(np.int32) & mmask).astype(np.float32)
            out = np.where(e == 0, m / (1 << mbits) * 2**-14,
                           (1 + m / (1 << mbits)) * 2.0**(e - 15))
            return out
        return np.stack([fp11(r, 11), fp11(g, 11), fp11(b, 10)], axis=-1)
    raise ValueError(f"unhandled fmt {fmt}")

def main():
    metas = sorted(glob.glob(os.path.join(CAP, "*.meta")))
    print(f"meta files: {len(metas)}")
    frames = {}
    for mp in metas:
        m = json.load(open(mp))
        frames.setdefault(m["seq"] // 10, [])  # 粗略分组
        kind = m["kind"]
        raw = os.path.join(CAP, f"f{m['seq']:03d}_{kind}_{m['w']}x{m['h']}_fmt{m['fmt']}.raw")
        if not os.path.exists(raw):
            print(f"  missing raw for {mp}")
            continue
        arr = load_raw(raw, m["w"], m["h"], m["fmt"], m["rowBytes"])
        print(f"== f{m['seq']:03d} {kind} {m['w']}x{m['h']} fmt={m['fmt']} cbStatus={m['cbStatus']}")
        if kind == "velocity":
            vx, vy = arr[..., 0], arr[..., 1]
            finite = np.isfinite(vx) & np.isfinite(vy)
            mag = np.hypot(vx, vy)
            mask = finite & (mag > 0.05) & (mag < 500)
            print(f"   finite={finite.mean()*100:.1f}% nonzero={mask.mean()*100:.2f}%")
            if mask.sum() > 100:
                print(f"   vx mean={vx[mask].mean():.3f} median={np.median(vx[mask]):.3f} "
                      f"p5={np.percentile(vx[mask],5):.3f} p95={np.percentile(vx[mask],95):.3f}")
                print(f"   vy mean={vy[mask].mean():.3f} median={np.median(vy[mask]):.3f} "
                      f"p5={np.percentile(vy[mask],5):.3f} p95={np.percentile(vy[mask],95):.3f}")
                print(f"   |v| median={np.median(mag[mask]):.3f} p95={np.percentile(mag[mask],95):.3f} max={mag[finite].max():.1f}")
        elif kind == "depth":
            finite = np.isfinite(arr)
            v = arr[finite]
            print(f"   finite={finite.mean()*100:.1f}% min={v.min():.4f} max={v.max():.4f} "
                  f"mean={v.mean():.4f} zeros={100*(v==0).mean():.2f}% ones={100*(v==1).mean():.2f}%")
            # 中央 vs 边缘粗略分布
            hh, ww = arr.shape
            c = arr[hh//3:2*hh//3, ww//3:2*ww//3]
            print(f"   center mean={np.nanmean(c):.4f}")
        elif kind == "taacolor":
            finite = np.isfinite(arr).all(axis=-1)
            print(f"   finite={finite.mean()*100:.1f}% "
                  f"r mean={arr[...,0][finite].mean():.4f} max={arr[...,0][finite].max():.3f}")

if __name__ == "__main__":
    main()
