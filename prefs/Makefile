TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GlobalAdBlockerPrefs

GlobalAdBlockerPrefs_FILES = GABRootListController.m GABAppListController.m GABRuleManagerController.m
GlobalAdBlockerPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
GlobalAdBlockerPrefs_INSTALL_PATH = /Library/PreferenceBundles
GlobalAdBlockerPrefs_FRAMEWORKS = UIKit
GlobalAdBlockerPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk
