# BG3 MetalFX（macOS 版）

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

为 macOS Steam 版《博德之门 3》（AppID 1086940）在游戏内视频选项中原生加入 [MetalFX Temporal](https://developer.apple.com/cn/metal/MetalFX/) 时域超分。Mac 版自带的 AMD FSR 1.0 只是空间（单帧）升采样；本包将其替换为 Apple 的时域超分——通过跨多帧累积信息，从较低分辨率的渲染中重建接近原生品质的画面。

升频选项出现在游戏内 **选项 → 视频 → 升频类型 → MetalFX**，名称与描述按游戏自带的全部 15 种语言本地化。不修改任何游戏文件：全部通过 Steam 启动选项与标准 BG3 本地化 mod 实现。

参考测试环境：Apple Silicon（M4 Pro）macOS 27，Steam 版《博德之门 3》（Patch 8，v4.1.1.7398727）。主菜单与游戏内渲染、镜头运动与存档兼容性均已通过本机测试。

> **注意：** 安装包只包含修复组件。您必须已在 Steam 购买《博德之门 3》；本仓库不包含也不分发游戏本体。

## 各档位渲染比例

选择 MetalFX 后，各升频模式的内部渲染比例如下（较 FSR 1.0 同档位各降一级，契合 Apple 时域超分特性）：

| 升频模式 | 渲染比例 | 放大倍率 |
|---|---|---|
| 极高品质 | 67% | 1.5x |
| 品质 | 59% | 1.7x |
| 平衡 | 50% | 2.0x |
| 性能 | 34% | 2.94x |

升频类型选择 **关** 时，MetalFX Temporal 仍会以原生分辨率替换游戏 TAA，获得更高质量的抗锯齿。

## 环境要求

- Apple Silicon（arm64）Mac，macOS 13 或更高版本
- 已通过 Steam 安装《博德之门 3》

## 一键安装

从 [GitHub Releases](https://github.com/noahhhi/BG3-MetalFX-macOS-support/releases) 下载 `BG3-MetalFX-arm64.pkg` 并双击。安装包会把注入器与 Steam 启动包装器装入 `~/Library/Application Support/BG3MetalFX`，把本地化 mod 装入游戏的 `Mods` 目录并注册到 `modsettings.lsx`，同时配置好 Steam 启动选项。若 Steam 正在运行请重启，之后照常从 Steam 启动游戏，在 选项 → 视频 → 升频类型 中选择 **MetalFX**。

另提供便携版 `BG3-MetalFX-arm64.zip`：解压后运行 `bash install.sh`。

> [!IMPORTANT]
> PKG 当前未签名（没有可用的 Developer ID Installer 证书）。若被 Gatekeeper 拦截，右键点击安装包选择**打开**，或在 **系统设置 → 隐私与安全性** 中允许。无需关闭 Gatekeeper。

若 PKG 报告安装失败，请在终端执行以下命令，它会在桌面生成 `BG3MF-install-log.txt`，提交 [GitHub issue](https://github.com/noahhhi/BG3-MetalFX-macOS-support/issues) 时附上该文件：

```sh
/usr/bin/grep -iE 'BG3 MetalFX|bg3mf|postinstall|error' /var/log/install.log | /usr/bin/tail -n 200 > "$HOME/Desktop/BG3MF-install-log.txt"
```

## 工作原理

- 一个 Steam 启动选项包装器在游戏启动时前置 `DYLD_INSERT_LIBRARIES`，加载注入器（约 200 KB 的 dylib）。Steam、游戏二进制与存档均不受影响。
- 注入器观测游戏的 Metal 命令流。FSR 1.0 链激活时，空间升采样 EASU dispatch 被替换为 `MTLFXTemporalScaler` 编码——使用游戏自己的 HDR 颜色、逐像素运动矢量、reversed-Z 深度与相机 jitter，写入同一输出纹理；原 RCAS 锐化 pass 仍在其后运行。升频关闭时，游戏 TAA draw 以原生分辨率同样替换。
- FSR 1.0 画质档位比例表仅**在内存中**改写为上表所列渲染比例，磁盘上的游戏数据不变。
- "MetalFX"名称与 Apple 风格描述来自一个标准 BG3 本地化 mod，覆盖游戏全部已发行语言中的两条既有字符串。

## 卸载

运行 `uninstall.sh`（已安装到 `~/Library/Application Support/BG3MetalFX/`），或下载 Release 中的独立文件：

```sh
bash ~/Downloads/uninstall.sh
```

将移除 Steam 启动选项、本地化 mod 及其 `modsettings.lsx` 注册项、注入器目录。存档不受影响。

## 已知限制

- 游戏需以显示器原生分辨率渲染（全屏或无边框）；更改显示器分辨率后需重启游戏。
- 镜头切换与场景切换沿用 MetalFX 内建的历史重置启发式，偶有一帧柔化。
- BG3 会把任何已注册 mod 视为 modded 档案（标准的 mod 提示；成就行为遵循游戏自身的 mod 规则）。
- 不含帧生成；本包仅提供时域超分与抗锯齿。

## 从源码构建

```sh
cmake -S src -B src/build -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build src/build
scripts/build_pkg.sh   # 产出 dist/BG3-MetalFX-arm64.pkg
```

## 许可与致谢

本项目以 [MIT License](LICENSE) 发布。《博德之门 3》由 Larian Studios 开发；MetalFX 由 Apple 提供。本工具为非官方兼容工具，不分发任何游戏资产。
