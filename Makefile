# legacy port: rootful, iOS 13, built on-device (no xcrun/rsync/lzma there)
export TARGET 			:= iphone:clang:16.5:13.0
export ARCHS 			:= arm64
export USE_DEPS 		:= 1
export FINALPACKAGE 	:= 1
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION := gzip
export PATH := $(CURDIR)/tools:$(PATH)
export LG_DEPS_DIR := $(CURDIR)/../deps

INSTALL_TARGET_PROCESSES = backboardd SpringBoard chronod WidgetRenderer-Default WidgetRenderer-CarPlay assistivetouchd
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = liquidass

liquidass_FILES     = Tweak.x \
                      $(wildcard Hooks/*.x) \
                      $(wildcard LiquidAssPrefs/LGPrefsLiquid*.m) \
                      $(wildcard Shared/*.[xm])
liquidass_CFLAGS    = -fobjc-arc
liquidass_USE_MODULES = 0
liquidass_FRAMEWORKS = UIKit QuartzCore CoreText CoreGraphics CoreMotion
# the pinned logos does not emit the substrate autolink directive
liquidass_LDFLAGS += -framework CydiaSubstrate
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
liquidass_LIBRARIES += roothide
endif


include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += LiquidAssBackboardd LiquidAssRWB LiquidAssPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# sources checked out under a restrictive umask would ship unreadable plists
after-stage::
	chmod -R a+rX,go-w $(THEOS_STAGING_DIR)
