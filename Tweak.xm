#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import "GABLog.h"

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABMasterSwitchKey @"GABMasterEnabled"

// iOS SDK 26.5 上 system 被标记为不可用，用 dlsym 动态加载
static int (*GABSystem)(const char *) = NULL;

static void GABRunCommand(const char *cmd) {
    if (!GABSystem) {
        GABSystem = (int (*)(const char *))dlsym(RTLD_DEFAULT, "system");
    }
    if (GABSystem) {
        GABSystem(cmd);
    }
}

// 设置变更回调：刷新 DNS 缓存
static void settingsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    GABLog(@"收到设置变更通知，刷新 DNS 缓存");
    GABRunCommand("killall -HUP mDNSResponder 2>/dev/null");
    GABRunCommand("killall mDNSResponderHelper 2>/dev/null");
}

static void __attribute__((constructor)) initialize(void) {
    @autoreleasepool {
        GABLog(@"GlobalAdBlocker v4.0 初始化 (hosts方案)");

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        settingsChangedCallback,
                                        (CFStringRef)kGABDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        GABLog(@"初始化完成, 当前 App: %@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}
