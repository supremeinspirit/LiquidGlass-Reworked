#!/bin/sh
# build.sh <tag>: builds lgfix-<tag>.dylib (arm64e, signed) and runs the private self-test
set -e
cd /var/jb/var/mobile/LiquidAssLegacy/ios17
tag=$1
sed -i "s/^#define BUILD_TAG .*/#define BUILD_TAG \"$tag\"/" lgfix.m
clang -isysroot /var/jb/theos/sdks/iPhoneOS16.5.sdk -arch arm64e -fobjc-arc -dynamiclib -miphoneos-version-min=15.0 \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
  -o lgfix-$tag.dylib lgfix.m 2>&1 | grep -v "^ld: warning" || true
ldid -S lgfix-$tag.dylib
mkdir -p /var/jb/tmp/lgfixtest
cp host /var/jb/tmp/lgfixtest/host-$tag; cp lgfix-$tag.dylib /var/jb/tmp/lgfixtest/t-$tag.dylib
rm -f /var/jb/tmp/lgfixtest/self.txt
LGFIX_SELFTEST=1 /var/jb/tmp/lgfixtest/host-$tag /var/jb/tmp/lgfixtest/t-$tag.dylib lgfix_selftest /var/jb/tmp/lgfixtest/self.txt 1 || echo "SELFTEST EXIT $?"
cat /var/jb/tmp/lgfixtest/self.txt
