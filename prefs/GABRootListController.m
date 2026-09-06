#import "GABRootListController.h"
#import "GABAppListController.h"
#import "GABRuleManagerController.h"
#import <notify.h>
#import "GABLog.h"

@implementation GABRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
    GABLog(@"主页面显示");
}

- (void)openAppList {
    GABLog(@"打开 App 列表");
    GABAppListController *vc = [[GABAppListController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openRuleManager {
    GABLog(@"打开规则管理");
    GABRuleManagerController *vc = [[GABRuleManagerController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
