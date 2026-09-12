# v1.0.2 validation / 验证记录

## English

Tested on **2026-09-13**, Apple M4 Pro, 48 GiB, macOS 27.0 (26A428), native arm64 Steam BG3 **4.1.1.7398727**.

### High-preset performance

Same Nautiloid save and fixed camera at the membrane door. **3456 × 2234 output, High preset, AC power connected**, battery charging. The 10 FPS cap was unchecked; the existing 120 Hz display and triple-buffered VSync were retained. The native TAA control retained the High preset's existing FidelityFX sharpening; MetalFX disabled that separate control and forced upscaling sharpness to zero. The preset was checked in the game before and after sampling.

| Mode | FPS | vs. native TAA | Mean GPU power | Mean GPU temperature | Retained time |
|---|---:|---:|---:|---:|---:|
| Native TAA | 23.6 | — | 30.8 W | 84.1 °C | 57.97 s |
| MetalFX Ultra Quality | 32.4 | +37% | 27.8 W | 80.9 °C | 59.12 s |
| MetalFX Quality | 37.0 | +56% | 27.3 W | 80.9 °C | 59.80 s |
| MetalFX Balanced | 42.3 | +79% | 26.4 W | 80.3 °C | 57.99 s |
| MetalFX Performance | 53.1 | +125% | 24.8 W | 78.8 °C | 59.01 s |

One sequential run per mode, in table order: 30 s warmup, then a requested 60 s measurement. Only complete Metal intervals inside that window were retained. FPS is presented frames divided by retained duration, from macOS `metalperftrace`. Foreground PID monitoring passed in every run. GPU active ratio averaged 100% and GPU clock averaged 1578 MHz in all five runs; `macmon` provided 54–55 GPU samples per window. Whole-GPU power/temperature while charging are contextual observations, not a matched-FPS cooling or battery-life test. No background-limited 30 FPS run is included.

The native control had no MetalFX-marked frames. All four MetalFX runs had Temporal markers and expected live input dimensions. The bridge's sampled frame counter independently agreed with presentation FPS (32.33 / 36.97 / 42.26 / 53.09). Metal's per-present MetalFX attribution counted fewer frames than the bridge, so those markers establish presence, not complete frame coverage. There were zero reported skipped frames. Aggregate intervals cannot establish a 1% low. These results are specific to one scene, not a whole-game benchmark.

Summaries: [benchmark-v1.0.2.json](benchmark-v1.0.2.json). Screenshots: [High preset](images/high-preset.png), [native TAA](images/native-taa-high.png), [MetalFX Performance](images/ingame-metalfx-performance.png).

### Settings and regression checks

- TAA and zero upscaling sharpness are forced on startup and MetalFX tier changes. Both controls were visibly gray on initial entry, mode changes and reopening settings. Dragging sharpness and clicking the locked AA selector could not change them. Upscaling Off restored editable AA. The earlier live policy check also verified that enabling MetalFX from SMAA forced TAA.
- The game TAA stage and jitter remain available. MetalFX consumes the unfiltered current frame, not the TAA-filtered output. Upscaling Off now uses original game AA, without hidden native-resolution MetalFX. Returning to upscaling resets temporal history.
- Ten build-specific in-memory patches check all original instructions before writing. Initialization, mode-change callbacks and reset paths use the game's control-disabled notifications. The disk executable is not patched.
- Simplified Chinese labels/help now use **上采样**. The zero-sharpness explanation and locked controls were inspected live. Traditional Chinese equivalents were packaged and structurally checked, but not inspected in that game language.
- Four FSR-chain regressions passed **2040/2040**, **2652/2652**, **3600/3600**, **7906/7906** expected-color pixels. The native-AA control with unused FSR pipeline objects passed **920/920**. Synthetic correctness is separate from real-save performance.
- The installer now emits compact/self-closing LSX attributes. Expanded empty attributes left the localization disabled in the upgrade check; compact serialization loaded MetalFX and corrected Chinese labels on cold startup without a save-load enable step.
- Installer fixture tests passed roundtrips, repeated installation, argument preservation, old-wrapper migration, rejection of malformed inputs and protection of later user edits.

### Limits

**Visible brightness/color differences from native TAA remain in this scene.** Image-quality parity is not established; no general quality improvement is claimed. Camera movement, combat, all scenes, other devices/builds, HDR output and multiplayer are not covered. Explicit camera-cut history reset and frame generation are not implemented.

Runtime binaries are ad-hoc signed; the PKG is unsigned. Package payloads and checksums are checked, and the package's exact install payload is exercised as the logged-in non-root user. The macOS Installer authorization GUI/root-to-user dispatcher is not exercised. Historical evidence remains in [v1.0.1 validation](VALIDATION-v1.0.1.md); its capped GPU-load figures and older native-resolution MetalFX behavior do not describe this update.

## 简体中文

测试日期 **2026-09-13**，设备为 Apple M4 Pro、48 GiB 内存、macOS 27.0 (26A428)，原生 arm64 Steam BG3 **4.1.1.7398727**。

### 高画质性能

同一鹦鹉螺存档、膜门前固定视角。**3456 × 2234 输出、高画质、连接电源**，电池正在充电。10 FPS 上限未勾选，保留原有 120 Hz 显示器与三倍缓冲垂直同步。原生 TAA 对照保留高预设原有的 FidelityFX 锐化；MetalFX 禁用该独立控件，并强制上采样锐度为零。采样前后均在游戏内核对高画质。

| 模式 | FPS | 相对原生 TAA | 平均 GPU 功耗 | 平均 GPU 温度 | 保留时长 |
|---|---:|---:|---:|---:|---:|
| 原生 TAA | 23.6 | — | 30.8 W | 84.1 °C | 57.97 s |
| MetalFX 极高品质 | 32.4 | +37% | 27.8 W | 80.9 °C | 59.12 s |
| MetalFX 品质 | 37.0 | +56% | 27.3 W | 80.9 °C | 59.80 s |
| MetalFX 平衡 | 42.3 | +79% | 26.4 W | 80.3 °C | 57.99 s |
| MetalFX 性能 | 53.1 | +125% | 24.8 W | 78.8 °C | 59.01 s |

按表格顺序，每档一次：预热 30 秒，再采样 60 秒，仅保留完全落在窗口内的 Metal 统计区间。FPS 由 macOS `metalperftrace` 记录的呈现帧数除以保留时长计算。每组前台 PID 检查均通过，GPU 平均占用率均为 100%，平均频率均为 1578 MHz；`macmon` 每个窗口取得 54–55 个 GPU 样本。整颗 GPU 的功耗／温度是充电状态下的观测值，并非相同帧率下的散热或续航对照。未采用任何后台限帧 30 FPS 数据。

原生对照无 MetalFX 帧标记。四档 MetalFX 均有 Temporal 标记和预期实机输入尺寸，桥接器抽样帧计数也独立吻合呈现帧率（32.33 / 36.97 / 42.26 / 53.09）。Metal 对呈现帧的 MetalFX 归属计数低于桥接器计数，因此仅用于确认存在 MetalFX，不作为逐帧覆盖率证明。系统报告的跳帧数均为零，聚合区间无法计算 1% low。这是单场景结果，不能代表全游戏性能。

汇总数据：[benchmark-v1.0.2.json](benchmark-v1.0.2.json)。截图：[高画质](images/high-preset.png)、[原生 TAA](images/native-taa-high.png)、[MetalFX 性能档](images/ingame-metalfx-performance.png)。

### 设置与回归检查

- 启动和切换 MetalFX 档位时强制 TAA 与零上采样锐度。首次进入设置、切换档位、重新打开设置时均确认两个控件灰显；拖动锐度、点击锁定的抗锯齿菜单均不能修改。关闭上采样后抗锯齿恢复可编辑，此前实机策略验证也确认从 SMAA 开启 MetalFX 会强制切回 TAA。
- 保留游戏 TAA 阶段与相机抖动，MetalFX 读取当前帧滤波前的输入，不读取 TAA 滤波后的输出。关闭上采样现在恢复原生游戏抗锯齿，不再隐式运行原生分辨率 MetalFX；重新开启时重置时域历史。
- 十处针对特定版本的进程内补丁在写入前检查全部原指令。初始化、模式切换回调与重置路径使用游戏原有控件禁用通知，不修改磁盘上的游戏可执行文件。
- 简体中文标签与说明统一使用**上采样**，已实机检查零锐度说明和灰显控件。繁体中文对应文本已打包并完成结构检查，未切换游戏语言实测。
- 四档 FSR 链路回归分别为 **2040/2040、2652/2652、3600/3600、7906/7906** 像素符合预期；已创建但未使用 FSR 管线对象的原生抗锯齿对照为 **920/920**。合成正确性测试与真实存档性能证据分开。
- 安装器改为输出自闭合 LSX 属性。升级检查中，展开的空属性使本地化处于禁用状态；改用自闭合格式后，冷启动直接加载 MetalFX 与校正后的中文，无需在存档提示中启用。
- 安装器隔离测试通过安装卸载、重复安装、启动参数保留、旧包装器迁移、拒绝损坏输入及保护用户后续修改等用例。

### 限制

**该场景仍可见与原生 TAA 的亮度／色彩差异。** 尚未建立画质一致性，不宣称普遍画质提升。镜头运动、战斗、全部场景、其他设备／版本、HDR 输出和多人模式不在本次覆盖内，显式镜头切换历史重置与帧生成尚未实现。

二进制使用 ad-hoc 签名，PKG 未签名。包内文件和校验值经过检查，并以当前登录的非 root 用户执行包内原样安装载荷；未实测 macOS Installer 授权界面／root 转用户分支。历史证据保存在 [v1.0.1 验证记录](VALIDATION-v1.0.1.md)，旧版限帧 GPU 数据和原生分辨率 MetalFX 行为不适用于本次更新。
