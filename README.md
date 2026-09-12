# BG3 MetalFX for macOS

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

Native [MetalFX Temporal](https://developer.apple.com/documentation/metalfx) upscaling for the macOS Steam release of *Baldur's Gate 3* (AppID 1086940). It replaces the FSR 1.0 spatial upscale with Apple's temporal reconstruction, using the game's current HDR color, motion vectors, depth and camera jitter.

Select **Options → Video → Upscaling Type → MetalFX**, and keep **Anti-Aliasing → TAA** enabled. The name and description are supplied by a localization mod with all 15 game languages. The injection uses a Steam launch option; it does not modify the game bundle or saves.

Current reference test: Apple M4 Pro, macOS 27, native arm64 Steam build **4.1.1.7398727**. Real save loading and 3D rendering were checked at Ultra Quality and Performance; all four internal render sizes were observed live. See [validation details](docs/VALIDATION.md) for coverage and limits.

<p align="center">
  <img src="docs/images/settings-metalfx-zh.png" alt="BG3 video settings showing MetalFX and its Chinese description" width="900">
  <br>
  <em>MetalFX in the game's own video settings, with the localized description.</em>
</p>

<p align="center">
  <img src="docs/images/ingame-metalfx-performance.png" alt="A real BG3 save rendered using MetalFX Temporal Performance mode" width="900">
  <br>
  <em>Performance mode in a real save: 1175 × 759 reconstructed to 3456 × 2234.</em>
</p>

> **Note:** The installer contains fixes only. You must own Baldur's Gate 3 on Steam; this repository does not include or distribute the game.

## Requirements

- Apple Silicon Mac (arm64), macOS 13 or later, with MetalFX Temporal support. Only the reference machine above has been tested.
- The native macOS Steam release of Baldur's Gate 3, build 4.1.1.7398727.
- Launch the game at least once to create its Steam and player profiles, then quit **both the game and Steam** before installing or uninstalling.
- Leave anti-aliasing set to **TAA**: the mod uses that render stage and its jitter. SMAA and Off do not activate this temporal path.

## One-click install

Download **`BG3-MetalFX-arm64.pkg`** from [GitHub Releases](https://github.com/noahhhi/BG3-MetalFX-macOS-support/releases/latest) and double-click it. The installer places the injector, launcher and uninstaller in `~/Library/Application Support/BG3MetalFX/`, installs `BG3MetalFX.pak` in the user Mods directory, registers the mod in existing player profiles, and updates only BG3's Steam launch option.

Start Steam again, launch the game as usual, and choose **MetalFX** with **TAA** enabled. When loading an existing save, the game may ask you to enable the newly added BG3MetalFX mod. The localization mod contains no gameplay changes.

The ZIP is a portable fallback: extract **`BG3-MetalFX-arm64.zip`**, then double-click **`Install BG3 MetalFX.command`** or run `bash install.sh` from the extracted folder. The same native installer handles both methods; users do not need Python, CMake or Xcode.

The installer preserves existing launch arguments and other mods. Invalid configuration files stop installation before changes are applied. A recovery backup is kept in `~/Library/Application Support/BG3MetalFX-backup/`. Keep that backup private; it contains your original configuration.

> [!IMPORTANT]
> The PKG is unsigned; its binaries are ad-hoc signed. If macOS blocks installation, allow it under **System Settings → Privacy & Security**. You do not need to disable Gatekeeper or reduce system security.

If the PKG reports an installation failure, this command creates `BG3MF-install-log.txt` on your Desktop. Review it before attaching it to a [GitHub issue](https://github.com/noahhhi/BG3-MetalFX-macOS-support/issues).

```sh
/usr/bin/grep -iE 'BG3 MetalFX|bg3mf|postinstall|error' /var/log/install.log | /usr/bin/tail -n 200 > "$HOME/Desktop/BG3MF-install-log.txt"
```

## Render scale per mode

| Upscaling Mode | Render scale per axis | Upscale factor | Observed input at 3456 × 2234 |
|---|---|---|---|
| Ultra Quality | ~67% | 1.5× | 2304 × 1489 |
| Quality | ~59% | 1.7× | 2032 × 1314 |
| Balanced | 50% | 2.0× | 1728 × 1117 |
| Performance | ~34% | 2.94× | 1175 × 759 |

These are the mod's chosen ratios, one tier lower than BG3's stock FSR 1.0 ratios. Actual dimensions are rounded by the game. If a video-setting change does not rebuild the render targets, restart the game.

With Upscaling Type set to **Off** and anti-aliasing set to **TAA**, the bridge supplies MetalFX temporal anti-aliasing at the current rendering resolution.

## How it works

- A small Steam wrapper adds the injector through `DYLD_INSERT_LIBRARIES`, preserving Steam's own overlay injection and existing launch arguments.
- At the TAA render stage, MetalFX reads the unfiltered current HDR color, motion vectors, device depth converted to R32Float, and jitter. The temporal scaler runs after that render encoder ends.
- At EASU, a compute kernel compresses the reconstructed HDR color into the game's existing intermediate texture. This executes inside the original compute encoder, before the unchanged RCAS sharpening/inverse-compression pass and later consumers. The stock TAA may remain for other consumers, but its filtered output is not fed into MetalFX.
- The FSR quality-ratio table is changed in process memory after checking its mapped address and original values. Nothing is patched on disk.
- A standard LSPK v18 mod contains two XML string overrides for each of the 15 languages, following [Larian's localization format](https://docs.baldursgate3.game/index.php?title=Adding_Localisation).

## Uninstall

Quit the game and Steam, then run `uninstall.sh` from the ZIP or the standalone Release asset:

```sh
bash ~/Downloads/uninstall.sh
```

It removes the injector and localization PAK, removes only BG3MetalFX's mod registrations, and restores the previous BG3 launch option when it still matches the installed value. Other games' launch options, other mods and later unrelated configuration changes are retained. If you edited BG3's launch option after installation, the uninstaller asks you to remove the wrapper first rather than overwriting your edits. Saves and the recovery backup are retained.

## Known limitations

- v1.0.0 had a black-screen defect and a localization-loading defect. Use v1.0.1 or later.
- This is an experimental hook for the specific native game build above. Other game builds, Intel/Rosetta, HDR output, split-screen, multiplayer and every possible scene/effect have not been validated.
- TAA must remain enabled. The mod does not add frame generation or an achievement-enabling patch. BG3's usual mod/profile rules apply.
- Temporal history resets on scaler size/format changes and GPU errors. There is no explicit game camera-cut/reset integration; transient trails or softening can occur around scene cuts or disocclusions.
- The reference game was capped at 10 FPS by its existing settings. The validation demonstrates rendering and dimensions, **not an uncapped FPS improvement** or a general image-quality comparison. A [capped GPU-load comparison](docs/VALIDATION.md#gpu-load-with-the-existing-10-fps-cap) found lower active-time occupancy than native TAA, but did not establish lower GPU power or heat.
- The Simplified Chinese interface was checked live; remaining translations are packaged and structurally checked, not individually tested in the game.

## Building from source

On Apple Silicon with CMake, Python 3 and Apple's command-line build tools:

```sh
cmake -S src -B src/build -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build src/build
bash scripts/build_pkg.sh
```

The build produces a PKG, a portable ZIP, `uninstall.sh` and `SHA256SUMS.txt` in `dist/`. Shader regression tests also require Apple's Metal compiler tools. See [validation details](docs/VALIDATION.md) for test commands.

## License and credits

This project is released under the [MIT License](LICENSE). *Baldur's Gate 3* is a game by Larian Studios; MetalFX is provided by Apple. The localization package writer follows the format documented by [Norbyte's LSLib](https://github.com/Norbyte/lslib). This is an unofficial compatibility tool and distributes no game assets.
