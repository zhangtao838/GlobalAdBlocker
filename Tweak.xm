#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "GABLog.h"

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABMasterSwitchKey @"GABMasterEnabled"

// 设置变更回调：刷新 DNS 缓存
static void settingsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    GABLog(@"收到设置变更通知，刷新 DNS 缓存");
    system("killall -HUP mDNSResponder 2>/dev/null");
    system("killall mDNSResponderHelper 2>/dev/null");
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
