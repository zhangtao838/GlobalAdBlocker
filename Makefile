TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalAdBlocker

GlobalAdBlocker_FILES = Tweak.xm
GlobalAdBlocker_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
GlobalAdBlocker_FRAMEWORKS = UIKit Foundation

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
