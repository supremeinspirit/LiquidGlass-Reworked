#!/bin/sh
# build.sh <original.deb> <fixes.deb> <out.deb>: builds the full rootless package
# original.deb: dylv.liquidass_0.1.1-2b_iphoneos-arm64.deb from the winaviation-tweaks/liquidass release 0.1.1-2b (used unchanged)
# fixes.deb: a package with LiquidAssFix / LiquidAssFixPrefs / LiquidAssFixRenderer / LiquidAssFixApps (dylib + plist) built from
#            ../rootless-addon; only these eight files are taken from it
set -e
umask 022
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
dl=var/jb/Library/MobileSubstrate/DynamicLibraries
dpkg-deb -R "$1" "$work/root"
dpkg-deb -x "$2" "$work/fixes"
for f in LiquidAssFix.dylib LiquidAssFix.plist LiquidAssFixPrefs.dylib LiquidAssFixPrefs.plist LiquidAssFixRenderer.dylib LiquidAssFixRenderer.plist LiquidAssFixApps.dylib LiquidAssFixApps.plist; do
  cp -p "$work/fixes/$dl/$f" "$work/root/$dl/$f"
done
cp "$here/control" "$work/root/DEBIAN/control"
dpkg-deb -Zgzip --root-owner-group -b "$work/root" "$3"
rm -rf "$work"
