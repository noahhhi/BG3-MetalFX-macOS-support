# BG3 MetalFX for macOS

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

Native [MetalFX Temporal](https://developer.apple.com/metal/MetalFX/) upscaling for the macOS Steam release of *Baldur's Gate 3* (AppID 1086940), added to the game's own video options. The built-in AMD FSR 1.0 upscaler on macOS is a spatial (single-frame) upscaler; this package replaces it with Apple's temporal upscaler, which reconstructs near-native image quality from a lower-resolution render by accumulating information across multiple frames.

The upscaler appears in-game as **Options → Video → Upscaling Type → MetalFX**, with the label and description localized for every language the game ships (all 15). No game files are modified; everything is done through a Steam launch option and a standard BG3 localization mod.

Reference test: Apple Silicon Mac (M4 Pro) running macOS 27, Steam release of Baldur's Gate 3 (patch 8, v4.1.1.7398727). Main-menu and in-game rendering, camera motion, and save compatibility are covered by local testing.

> **Note:** The installer contains fixes only. You must own Baldur's Gate 3 on Steam; this repository does not include or distribute the game.

## Render scale per mode

When MetalFX is selected, each Upscaling Mode renders internally at the following scale of your display resolution (one tier lower than the corresponding FSR 1.0 mode, per Apple's temporal-scaling characteristics):

| 升频模式 / Upscaling Mode | Render scale | Upscale factor |
|---|---|---|
| 极高品质 / Ultra Quality | 67% | 1.5x |
| 品质 / Quality | 59% | 1.7x |
| 平衡 / Balanced | 50% | 2.0x |
| 性能 / Performance | 34% | 2.94x |

With Upscaling Type set to **Off**, MetalFX Temporal still replaces the game's TAA at native resolution for higher-quality anti-aliasing.

## Requirements

- macOS 13 or later on Apple Silicon (arm64)
- Baldur's Gate 3 installed via Steam

## One-click install

Download `BG3-MetalFX-arm64.pkg` from [GitHub Releases](https://github.com/noahhhi/BG3-MetalFX-macOS-support/releases) and double-click it. The package installs the injector and Steam wrapper into `~/Library/Application Support/BG3MetalFX`, installs the localization mod into the game's `Mods` folder, registers it in `modsettings.lsx`, and sets the Steam launch option. If Steam was running, restart it, then launch the game from Steam as usual and pick **MetalFX** under Options → Video → Upscaling Type.

A portable fallback is provided as `BG3-MetalFX-arm64.zip`: extract it and run `bash install.sh`.

> [!IMPORTANT]
> The PKG is currently unsigned because no Developer ID Installer identity is available. If Gatekeeper blocks it, right-click the package and choose **Open**, or allow it under **System Settings → Privacy & Security**. Do not disable Gatekeeper.

If the PKG reports that installation failed, run the following command in Terminal. It creates `BG3MF-install-log.txt` on your Desktop; attach that file when opening a [GitHub issue](https://github.com/noahhhi/BG3-MetalFX-macOS-support/issues).

```sh
/usr/bin/grep -iE 'BG3 MetalFX|bg3mf|postinstall|error' /var/log/install.log | /usr/bin/tail -n 200 > "$HOME/Desktop/BG3MF-install-log.txt"
```

## How it works

- A small Steam launch-option wrapper prepends `DYLD_INSERT_LIBRARIES` when the game starts, loading the injector (a ~200 KB dylib). Steam, the game binary, and saves are untouched.
- The injector observes the game's Metal command stream. When the FSR 1.0 chain is active, the spatial EASU upscale dispatch is replaced by an `MTLFXTemporalScaler` encode using the game's own HDR color, per-pixel motion vectors, reversed-Z depth, and camera jitter, written into the same output texture; the stock RCAS sharpening pass still runs afterwards. When upscaling is off, the game's TAA draw is replaced the same way at native resolution.
- The FSR 1.0 quality-ratio table is patched **in memory only** to the render scales listed above; no game data on disk is changed.
- The "MetalFX" label and its Apple-style description come from a standard BG3 localization mod that overrides two existing strings in every shipped language.

## Uninstall

Run `uninstall.sh` (also installed to `~/Library/Application Support/BG3MetalFX/`), or download the standalone Release asset:

```sh
bash ~/Downloads/uninstall.sh
```

This removes the Steam launch option, the localization mod and its `modsettings.lsx` registration, and the injector directory. Save files are left untouched.

## Known limitations

- The game must render at your display resolution (fullscreen or borderless at native size); changing the display resolution requires a game restart.
- Camera cuts and scene transitions reuse MetalFX's built-in history reset heuristics; a one-frame softening may be visible.
- BG3 treats any registered mod as a modded profile (standard mod warning; achievements behavior follows the game's own mod rules).
- Frame generation is not included; this package provides temporal upscaling and anti-aliasing only.

## Building from source

```sh
cmake -S src -B src/build -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build src/build
scripts/build_pkg.sh   # assembles dist/BG3-MetalFX-arm64.pkg
```

## License and credits

This project is released under the [MIT License](LICENSE). *Baldur's Gate 3* is a game by Larian Studios; MetalFX is provided by Apple. This is an unofficial compatibility tool and distributes no game assets.
