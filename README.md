# Liquid(Gl)ass-Reworked

A reworked build of **Liquid (Gl)ass** with a rootful iOS 13 port and a rootless patch package with fixes for iOS 15 to 17.




!Note! : The Patch requires you to have LiquidAss 0.1.1-2b installed, and as the name suggests, it will patch the instance with my fixes.
         The rootless download in the release is this patch; the rootful .deb in the same release is the whole tweak in one file (do not install that one over liquid glass - it is its own tweak).

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
| `LiquidGlassReworked_<version>_rootless-patch_iphoneos-arm64.deb` | rootless jailbreaks, iOS 15 and later | the Reworked fixes as a patch package (`com.supremeinspirit.liquidassreworked`) that is installed on top of the original `dylv.liquidass` 0.1.1-2b by dylv: install the original first, then this file. It only adds its own libraries and changes none of the original's files. arm64 |

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

The original tweak cannot be rebuilt for arm64e on the development phone, so the fixes are four extra libraries that load next to the unchanged original 0.1.1-2b (sources in `rootless-addon/`). Releases ship them as a patch package to install on top of the original; `rootless-full/build.sh` can still put them into one package together with the original's binaries. On every supported iOS version the keyboard keys get the same shape in every app (the key radius is taken from the settings file, also in sandboxed apps). On iOS 15 and 16 the Control Center fixes apply: an expanded module that is one big slider (WhitePointModule) is a pill as a whole instead of a pill slider on a squarer glass, no white fill on switched-on toggles, Now Playing glass. For iOS 17:

- volume HUD glass (the original hooks a class that no longer exists on iOS 17)
- Dynamic Island glass while the island is expanded, with its own settings page; the audio wave of the now-playing element is drawn without its black box, and a setting can leave out the black camera pill that otherwise shows in screenshots
- expanded Control Center modules that are one big slider no longer show two outlines
- home screen icons stay visible behind the cover sheet glass while unlocked (off by default, switch `icons-behind`)
- widgets on the widget page fill their slot when a grid tweak shrinks them
- widget backgrounds are removed reliably (the original's removal often did not start in the iOS 17 widget renderer)

On every iOS version: keyboard keys take the tweak's key radius and font reliably (the system's cache of drawn keys is emptied when those settings change; the original never empties it, so old and new key shapes got mixed). And in apps the floating tab bar no longer puts all titles on top of each other at its right end when the bar is laid out only once (App Store); the rootful port has the same fix in `Hooks/TabBar.x`.

New in test17 (rootless): liquid glass on the **text loupe** (the lens shown while the insertion point is dragged through text; a frosted pane that holds only the text being edited) and on **text bars** (the system's search fields and Safari's address bar), each with its own page in the settings (Surfaces → Text Loupe / Text Bars). Tested on iOS 17.3 only.

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
