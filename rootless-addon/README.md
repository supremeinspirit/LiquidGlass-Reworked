# Liquid(Gl)ass-Reworked: rootless fixes

Three libraries that are loaded next to the unchanged binaries of the original `dylv.liquidass 0.1.1-2b` (rootless). They ship inside the full rootless package (see [../rootless-full/](../rootless-full/)); up to release 1.0 they were a separate add-on package, `com.supremeinspirit.liquidassreworked`, which the full package replaces.

- `lgfix.m` → `LiquidAssFix.dylib`, loaded into SpringBoard
- `lgprefsfix.m` → `LiquidAssFixPrefs.dylib`, loaded into Settings (adds a "Dynamic Island" page to the Liquid (Gl)ass settings)
- `lgrwbfix.m` → `LiquidAssFixRenderer.dylib`, loaded into the widget renderer processes (it does nothing in `chronod`). On iOS 17 the original's widget background removal often never started there, because the sandboxed renderer got no settings for the tweak; this library hands the settings file's values to the process before the original reads them. It also keeps the original's removal away from widgets the system already draws without background (the widget page), which otherwise lost their content.

All three are written "runtime style" (no `@""` literals, no `@implementation`) because they were built with clang on the phone itself, where compiled Objective-C classes crash on arm64e.

## Build (on device)

`build.sh <tag>` builds `lgfix-<tag>.dylib` (arm64e, ad-hoc signed) and runs a self-test in a private host process outside SpringBoard. The paths in the script are the ones used on the development phone; adjust them. `lgprefsfix.m` is built with the same clang command line; `lgrwbfix.m` too, with only `-framework Foundation -framework CoreFoundation` (self-test symbol `lgrwbfix_selftest`).

## Switches

Create an empty file in `/var/jb/usr/lib/LiquidAssFix/` to turn a part off (takes effect at the next respring):

| File | Effect |
| --- | --- |
| `disabled` | none of the Reworked fixes do anything |
| `no-prefs-page` | no "Dynamic Island" settings page |
| `icons-behind` | **switches on** (off by default): home screen icons are kept visible behind the cover sheet glass, iOS 17. `no-icons-behind` still switches it off |
| `no-widget-fill` | widgets on the widget page are not scaled to fill their slot |
| `no-hud-scale` | volume HUD keeps the capture scale derived from Global.Quality |
| `keep-track` | volume HUD keeps the slider's dark track |
| `no-widget-background` | widgets on the widget page keep their own background |
| `no-renderer-fix` | the widget renderer library does nothing (takes effect when the widget renderer next starts) |
| `keep-dark-tints` | the one-time change of the dark-mode tints to clear is not applied |
| `keep-keyboard-cache` | the system's cache of drawn keyboard keys is not emptied when the keyboard settings (key radius, custom font, on/off) change |
| `keep-toggle-white` | switched-on Control Center toggle modules keep their white fill |
| `no-cc-slider` | iOS 15/16: none of the Control Center fixes are applied |
| `no-media-glass` | iOS 15/16: the backdrop over the Now Playing module's glass is kept |
| `keep-media-style` | iOS 17: the Now Playing module keeps its own (dark, clearer) glass variant instead of the one the other modules use |

Opt-in (create the file to turn it on):

| File | Effect |
| --- | --- |
| `debug-log` | repeating log lines are written to the fix log too (off by default; the log is cut back when it grows past 64 KB) |
| `clear-widget-page-material` | hides the material behind the widget page's list (with an empty layer mask). Off by default: the soft shadow it gives the widget page is part of the look, and an earlier build that hid it through its alpha had `backboardd` killed for exceeding its memory limit a few seconds later (cause not established) |

## One-time preference defaults

At the first SpringBoard start after installing, on every iOS version, the fixes write these into the Liquid (Gl)ass preferences, only for keys that are not set yet:

- `DarkTintColor` = clear for Widgets, ContextMenu, Alerts, Banner, Spotlight, Passcode and Keyboard (the original tints these 12-50 % black in dark mode)
- the list of widgets whose own background is removed gets `com.apple.stocks.widget` and `com.apple.Batteries.BatteriesAvocadoWidgetExtension` added

These can be changed afterwards in the Liquid (Gl)ass settings; they are not applied a second time.

## No refraction at all (only blur and tint)

The original tweak writes `/var/mobile/Library/Accessibility/liquidass-gaussian-identity-state.bin` while it installs its `backboardd` hooks and removes it afterwards. If `backboardd` dies in that moment the file stays, and from then on the renderer skips all its hooks: every surface is only blurred, nothing refracts. Moving the file away and restarting `backboardd` brought the refraction back on both test phones (iOS 17.3 and iOS 15.2.1). If the file comes back, the hook installation really crashes on that system.
