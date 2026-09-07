#import "GABAppListController.h"
#import "GABLog.h"
#import <notify.h>

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABAppEnabledPrefix @"GABAppEnabled_"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"

@implementation GABAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"按 App 管理";
    GABLog(@"App列表页面加载(AltList v3.3)");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    @try {
        NSArray *apps = [self valueForKey:@"applications"];
        GABLog(@"App列表显示，应用数量: %lu", (unsigned long)apps.count);
    } @catch (NSException *e) {
        GABLog(@"获取应用数量失败: %@", e);
    }
}

#pragma mark - 开关状态读写（兼容现有存储格式）

- (void)setApplicationEnabled:(NSNumber *)enabledNum specifier:(PSSpecifier *)specifier {
    [super setApplicationEnabled:enabledNum specifier:specifier];

    NSString *bundleId = [specifier propertyForKey:@"applicationIdentifier"];
    if (!bundleId || bundleId.length == 0) {
        GABLog(@"setApplicationEnabled: 无 bundleId");
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    [defaults setObject:enabledNum forKey:key];
    [defaults synchronize];

    GABLog(@"设置 App 开关: key=%@ value=%@ (suite=%@)", key, enabledNum, kGABDefaultsDomain);

    // 验证保存是否成功
    NSNumber *saved = [defaults objectForKey:key];
    GABLog(@"验证保存: %@ = %@", key, saved);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);
}

- (id)readApplicationEnabled:(PSSpecifier *)specifier {
    NSString *bundleId = [specifier propertyForKey:@"applicationIdentifier"];
    if (!bundleId || bundleId.length == 0) {
        return [super readApplicationEnabled:specifier];
    }

    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    if (![defaults objectForKey:key]) {
        return @(NO); // 默认关闭
    }
    return @([defaults boolForKey:key]);
}

@end
