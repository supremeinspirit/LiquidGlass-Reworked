#!/bin/sh
# build.sh <original.deb> <fixes.deb> <out.deb>: builds the full rootless package
# original.deb: dylv.liquidass_0.1.1b_iphoneos-arm64.deb from the winaviation-tweaks/liquidass release 0.1.1b
# fixes.deb: a package with LiquidAssFix / LiquidAssFixPrefs (dylib + plist) from ../rootless-addon
set -e
umask 022
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
dpkg-deb -R "$1" "$work/root"
dpkg-deb -x "$2" "$work/root"
cp "$here/control" "$work/root/DEBIAN/control"
dpkg-deb -Zgzip --root-owner-group -b "$work/root" "$3"
rm -rf "$work"
