# Liquid(Gl)ass-Reworked: rootless add-on

An add-on for the **stock** `dylv.liquidass 0.1.1b` (rootless). It does not replace the original tweak, it is loaded next to it.

- `lgfix.m` → `LiquidAssFix.dylib`, loaded into SpringBoard
- `lgprefsfix.m` → `LiquidAssFixPrefs.dylib`, loaded into Settings (adds a "Dynamic Island" page to the Liquid (Gl)ass settings)

Both are written "runtime style" (no `@""` literals, no `@implementation`) because they were built with clang on the phone itself, where compiled Objective-C classes crash on arm64e.

## Build (on device)

`build.sh <tag>` builds `lgfix-<tag>.dylib` (arm64e, ad-hoc signed) and runs a self-test in a private host process outside SpringBoard. The paths in the script are the ones used on the development phone; adjust them. `lgprefsfix.m` is built with the same clang command line.

## Switches

Create an empty file in `/var/jb/usr/lib/LiquidAssFix/` to turn a part off (takes effect at the next respring):

| File | Effect |
| --- | --- |
| `disabled` | the whole add-on does nothing |
| `no-prefs-page` | no "Dynamic Island" settings page |
| `no-icons-behind` | home screen icons are not kept visible behind the cover sheet glass |
| `no-widget-fill` | widgets on the widget page are not scaled to fill their slot |
| `no-hud-scale` | volume HUD keeps the capture scale derived from Global.Quality |
| `keep-track` | volume HUD keeps the slider's dark track |
| `no-widget-background` | widgets on the widget page keep their own background |
| `keep-dark-tints` | the one-time change of the dark-mode tints to clear is not applied |

Opt-in (create the file to turn it on):

| File | Effect |
| --- | --- |
| `clear-widget-page-material` | hides the material behind the widget page's list. Off by default: the one time it ran, `backboardd` was killed for exceeding its memory limit a few seconds later (cause not established) |

## One-time preference defaults

At the first SpringBoard start after installing, on every iOS version, the add-on writes these into the Liquid (Gl)ass preferences, only for keys that are not set yet:

- `DarkTintColor` = clear for Widgets, ContextMenu, Alerts, Banner, Spotlight, Passcode and Keyboard (the original tints these 12-50 % black in dark mode)
- the list of widgets whose own background is removed gets `com.apple.stocks.widget` added

Both can be changed afterwards in the Liquid (Gl)ass settings; they are not applied a second time.
