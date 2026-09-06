#import "GABAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "GABLog.h"

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABAppEnabledPrefix @"GABAppEnabled_"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSData *iconData;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
@end

@implementation GABAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"按 App 管理";
    GABLog(@"App列表页面加载");

    // 设置搜索框
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索 App";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;

    self.filteredApps = @[];
    [self loadApps];

    // 监听 App 安装/卸载：装新 App / 删 App 时自动重扫
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleAppsChanged)
               name:@"FBSceneManagerApplicationInstallNotification"
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleAppsChanged)
               name:@"FBSceneManagerApplicationUninstallNotification"
             object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleAppsChanged {
    GABLog(@"检测到 App 增删，自动重扫");
    [self loadApps];
}

- (void)loadApps {
    NSMutableArray *appList = [NSMutableArray array];
    NSInteger totalCount = 0;
    NSInteger systemAppCount = 0;
    NSInteger componentCount = 0;

    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) {
            GABLog(@"错误: LSApplicationWorkspace 类不存在");
            self.apps = @[];
            return;
        }

        LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
        NSArray *allApps = [workspace allApplications];
        totalCount = allApps.count;
        GABLog(@"获取到全部应用数量: %ld", (long)totalCount);

        for (LSApplicationProxy *app in allApps) {
            NSString *bundleId = nil;
            NSString *name = nil;
            NSURL *bundleURL = nil;
            NSData *iconData = nil;

            @try {
                bundleId = [app valueForKey:@"bundleIdentifier"];
                name = [app valueForKey:@"localizedName"];
                bundleURL = [app valueForKey:@"bundleURL"];
                iconData = [app valueForKey:@"iconData"];
            } @catch (NSException *e) {
                continue;
            }

            if (!bundleId || bundleId.length == 0) continue;
            if (!name || name.length == 0) continue;

            if (appList.count < 5 && totalCount > 0) {
                NSString *path = bundleURL ? [bundleURL path] : @"unknown";
                GABLog(@"App样本: name=%@ bundleId=%@ path=%@", name, bundleId, path);
            }

            // 砍掉系统 App：bundleId 以 com.apple. 开头的
            if ([bundleId hasPrefix:@"com.apple."]) {
                systemAppCount++;
                continue;
            }

            NSMutableDictionary *appInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                              name, @"name",
                                              bundleId, @"bundleId",
                                              nil];
            if (iconData) {
                appInfo[@"iconData"] = iconData;
            }
            [appList addObject:appInfo];
        }
    } @catch (NSException *e) {
        GABLog(@"获取 app 列表失败: %@", e);
    }

    GABLog(@"过滤结果: 全部%ld, 系统App%ld, 系统组件%ld, 最终%ld",
          (long)totalCount, (long)systemAppCount, (long)componentCount, (long)appList.count);

    [appList sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];

    self.apps = appList;
    self.filteredApps = appList;
    GABLog(@"App列表加载完成，共 %ld 个", (long)self.apps.count);

    // 刷新界面
    dispatch_async(dispatch_get_main_queue(), ^{
        _specifiers = nil;
        [self reloadSpecifiers];
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchText = searchController.searchBar.text;
    self.isSearching = searchText.length > 0;

    if (self.isSearching) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            NSString *name = [app[@"name"] lowercaseString];
            NSString *bundleId = [app[@"bundleId"] lowercaseString];
            return [name containsString:[searchText lowercaseString]] ||
                   [bundleId containsString:[searchText lowercaseString]];
        }];
        self.filteredApps = [self.apps filteredArrayUsingPredicate:predicate];
    } else {
        self.filteredApps = self.apps;
    }

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSArray *displayApps = self.isSearching ? self.filteredApps : self.apps;

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"说明" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];
        PSSpecifier *descSpec = [PSSpecifier preferenceSpecifierNamed:@"默认所有 App 均未开启，需手动开启才会拦截广告，可减小资源开销" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [descSpec setProperty:@"1" forKey:@"isStatic"];
        [specs addObject:descSpec];

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"操作" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        PSSpecifier *enableAllSpec = [PSSpecifier preferenceSpecifierNamed:@"全部启用" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [enableAllSpec setProperty:@"enableAllApps" forKey:@"action"];
        [specs addObject:enableAllSpec];

        PSSpecifier *disableAllSpec = [PSSpecifier preferenceSpecifierNamed:@"全部禁用" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [disableAllSpec setProperty:@"disableAllApps" forKey:@"action"];
        [specs addObject:disableAllSpec];

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"已安装应用（%ld 个）", (long)displayApps.count] target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        for (NSDictionary *app in displayApps) {
            NSString *name = app[@"name"];
            NSString *bundleId = app[@"bundleId"];

            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                                 target:self
                                                                    set:@selector(setAppEnabled:specifier:)
                                                                    get:@selector(getAppEnabled:)
                                                                detail:Nil
                                                                  cell:PSSwitchCell
                                                                  edit:Nil];
            [spec setProperty:bundleId forKey:@"bundleId"];
            [spec setProperty:bundleId forKey:@"key"];

            // 设置 App 图标
            NSData *iconData = app[@"iconData"];
            if (iconData) {
                UIImage *icon = [UIImage imageWithData:iconData];
                if (icon) {
                    [spec setProperty:icon forKey:@"icon"];
                }
            }

            [specs addObject:spec];
        }

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)setAppEnabled:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleId = [specifier propertyForKey:@"bundleId"];
    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    [defaults setObject:value forKey:key];
    [defaults synchronize];

    GABLog(@"设置 App 开关: %@ = %@", bundleId, value);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);
}

- (id)getAppEnabled:(PSSpecifier *)specifier {
    NSString *bundleId = [specifier propertyForKey:@"bundleId"];
    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    if (![defaults objectForKey:key]) {
        return @(NO);
    }
    return @([defaults boolForKey:key]);
}

- (void)enableAllApps {
    GABLog(@"点击全部启用按钮");
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    for (NSDictionary *app in self.apps) {
        NSString *bundleId = app[@"bundleId"];
        NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
        [defaults setObject:@(YES) forKey:key];
    }
    [defaults synchronize];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);
    _specifiers = nil;
    [self reloadSpecifiers];
    GABLog(@"全部启用完成，共 %ld 个 App", (long)self.apps.count);
}

- (void)disableAllApps {
    GABLog(@"点击全部禁用按钮");
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    for (NSDictionary *app in self.apps) {
        NSString *bundleId = app[@"bundleId"];
        NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
        [defaults setObject:@(NO) forKey:key];
    }
    [defaults synchronize];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);
    _specifiers = nil;
    [self reloadSpecifiers];
    GABLog(@"全部禁用完成，共 %ld 个 App", (long)self.apps.count);
}

@end
