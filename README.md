# Liquid(Gl)ass-Reworked

A reworked build of **Liquid (Gl)ass** with a rootful iOS 13 port and a full rootless package with fixes for iOS 17.

## Credits

All credit for Liquid (Gl)ass goes to the original developers:

- **dylv** and the contributors of [winaviation-tweaks/liquidass](https://github.com/winaviation-tweaks/liquidass), the original tweak this is based on
- **OwnGoal Studio** for Remove Widget Background (see [NOTICES.md](NOTICES.md))

This repository is a fork. It is not affiliated with or endorsed by the original developers. Please report problems with these builds here, not upstream.

The original tweak is licensed under [CC BY-NC 4.0](LICENSE) (https://creativecommons.org/licenses/by-nc/4.0/); so is everything added here. Changes were made to the original, see below.

## What is in a release

| File | For | What it is |
| --- | --- | --- |
| `LiquidGlassReworked_<version>_rootful-ios13_iphoneos-arm.deb` | rootful jailbreaks, iOS 13 | the whole tweak (package `dylv.liquidass`), ported to iOS 13, arm64 |
| `LiquidGlassReworked_<version>_rootless_iphoneos-arm64.deb` | rootless jailbreaks, iOS 15 and later | the whole tweak (package `dylv.liquidass`): the original 0.1.1-2b binaries plus the Reworked fixes in one package. Upgrades an installed original in place and replaces the former add-on package `com.supremeinspirit.liquidassreworked`. The fixes only load on arm64e devices (A12 and newer) |

## Tested on

Only these devices. Everything else is untested.

| Variant | Device | iOS | Jailbreak | Status |
| --- | --- | --- | --- | --- |
| rootful iOS 13 port | iPhone X (iPhone10,6) | 13.3 (17C54) | unc0ver, rootful, Substitute | tested on device |
| rootless | iPhone 15 Pro Max (iPhone16,2) | 17.3 (21D50) | Dopamine 3.0.10, rootless, ElleKit 1.2 | tested on device |
| rootless | iPhone 12 (iPhone13,2) | 15.2.1 (19C63) | Dopamine 3.0.9, rootless, ElleKit 1.2 | tested on device (Control Center fixes; the other fixes are iOS 17 only) |

See the release notes for which exact build was tested.

## Changes to the original

### Rootful iOS 13 port (branch `reworked`, top-level sources)

The original needs iOS 14. Changes for iOS 13.3:

- backboardd renderer adapted to iOS 13.3 QuartzCore
- `Shared/LGLegacyCompat`: replacements for APIs that do not exist on iOS 13 (button menus, color well, SF Symbol fallbacks, ...)
- lock screen clock, Control Center, volume HUD, context menu and settings pane adapted to iOS 13 view hierarchies
- builds on-device (`build.sh`, `tools/rsync`), arm64 only

Not available on iOS 13: App Library, iOS 14 widgets, widget background removal, Spotlight and search pill.

### Rootless package ([rootless-addon/](rootless-addon/), [rootless-full/](rootless-full/))

The original tweak cannot be rebuilt for arm64e on the development phone, so the rootless package contains the unchanged binaries of the original 0.1.1-2b release plus two extra libraries with the fixes (sources in `rootless-addon/`); `rootless-full/build.sh` puts them together. For iOS 17:

- volume HUD glass (the original hooks a class that no longer exists on iOS 17)
- Dynamic Island glass while the island is expanded, with its own settings page
- expanded Control Center modules that are one big slider no longer show two outlines
- home screen icons stay visible behind the cover sheet glass while unlocked
- widgets on the widget page fill their slot when a grid tweak shrinks them

---

# Original README



# Liquid (Gl)ass
This tweak is incomplete, issues WILL happen.

Nightly builds that contains the bleeding edge changes are available [here](https://github.com/winaviation-tweaks/liquidass/releases/tag/nightly)

## Localization

Usage: tools/localizations.rb COMMAND [PATH]

  validate                 see if stuff are correct
  clean                    remove unused english keys and translated keys
  sync                     add missing locale keys using english values
  export-template [PATH]   export active english strings to PATH, or stdout

## donation
i only accept crypto for now, wallet addreses:
```
BTC: bc1qlv830emqsffqslns2e3kglkgcdnlag0nfnyj4k
ETH: 0x6245EF47c749D1b5c2830b145cB943a8aD826bea 
LTC: ltc1q7j6vlgvymxdtwm46u0n22h7m4890cexfp22vfm 
DOGE: D76nuR1HWSymSLhFYYhkfpc4JHg1HjvgWD 
SOL: F1rH3PSMHFHXbGLGQiWXGLRaahfYoVULUwhsvrewM37W
TRX: TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX 
USDC (Polygon): 0x6245EF47c749D1b5c2830b145cB943a8aD826bea 
USDT (Tron/trc-20): TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX 
```
contact me if you dont see your desired cryptocurrency

### contributions to this tweak are welcomed
