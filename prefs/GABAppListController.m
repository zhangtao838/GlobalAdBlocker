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
    GABLog(@"App列表页面加载(AltList v3.0)");
}

- (void)setApplicationEnabled:(NSNumber *)enabledNum specifier:(PSSpecifier *)specifier {
    [super setApplicationEnabled:enabledNum specifier:specifier];
    NSString *bundleId = [specifier propertyForKey:@"applicationIdentifier"];
    if (!bundleId || bundleId.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    [defaults setObject:enabledNum forKey:key];
    [defaults synchronize];
    GABLog(@"设置 App 开关: %@ = %@", bundleId, enabledNum);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (CFStringRef)kGABDarwinNotification, NULL, NULL, true);
}

- (id)readApplicationEnabled:(PSSpecifier *)specifier {
    NSString *bundleId = [specifier propertyForKey:@"applicationIdentifier"];
    if (!bundleId || bundleId.length == 0) return [super readApplicationEnabled:specifier];
    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    if (![defaults objectForKey:key]) return @(NO);
    return @([defaults boolForKey:key]);
}

@end
