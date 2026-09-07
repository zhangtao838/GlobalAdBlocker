TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GlobalAdBlockerPrefs

GlobalAdBlockerPrefs_FILES = GABRootListController.m GABAppListController.m GABRuleManagerController.m AltList.x ATLApplicationListControllerBase.m ATLApplicationListMultiSelectionController.m ATLApplicationListSelectionController.m ATLApplicationListSubcontroller.m ATLApplicationListSubcontrollerController.m ATLApplicationSection.m ATLApplicationSelectionCell.m ATLApplicationSubtitleCell.m ATLApplicationSubtitleSwitchCell.m LSApplicationProxy+AltList.m PSSpecifier+AltList.m
GlobalAdBlockerPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-tautological-pointer-compare
GlobalAdBlockerPrefs_INSTALL_PATH = /Library/PreferenceBundles
GlobalAdBlockerPrefs_FRAMEWORKS = UIKit MobileCoreServices
GlobalAdBlockerPrefs_PRIVATE_FRAMEWORKS = Preferences
GlobalAdBlockerPrefs_LIBRARIES = root

include $(THEOS_MAKE_PATH)/bundle.mk
