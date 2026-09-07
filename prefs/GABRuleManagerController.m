#import "GABRuleManagerController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "GABLog.h"

// libroot - 动态加载 jbrootpath 函数
static NSString *(*GABJBRootPath)(NSString *) = NULL;
static BOOL GABJBRootPathLoaded = NO;

static void GABLoadJBRootPath(void) {
    if (GABJBRootPathLoaded) return;
    GABJBRootPathLoaded = YES;
    const char *libPaths[] = {
        "/usr/lib/libroot.dylib",
        "/var/jb/usr/lib/libroot.dylib",
        NULL
    };
    for (int i = 0; libPaths[i]; i++) {
        void *handle = dlopen(libPaths[i], RTLD_LAZY);
        if (handle) {
            GABJBRootPath = (NSString *(*)(NSString *))dlsym(handle, "jbrootpath");
            if (GABJBRootPath) return;
            dlclose(handle);
        }
    }
}

static NSString *GABResolvePath(NSString *path) {
    if (!path) return nil;
    if ([path hasPrefix:@"/var/mobile/"]) return path;
    GABLoadJBRootPath();
    if (GABJBRootPath) {
        @try {
            NSString *resolved = GABJBRootPath(path);
            if (resolved) return resolved;
        } @catch (NSException *e) {}
    }
    return path;
}

#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABHostsStart @"# === GlobalAdBlocker Start ==="
#define kGABHostsEnd @"# === GlobalAdBlocker End ==="
#define kGABDefaultRulesPath @"/Library/PreferenceBundles/GlobalAdBlockerPrefs.bundle/default_rules.txt"

@implementation GABRuleManagerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"规则管理";
    GABLog(@"规则管理页面加载(v4.0 hosts方案)");

    // 首次打开时，如果 hosts 里没有我们的标记，自动导入默认规则
    NSString *hostsPath = GABResolvePath(@"/etc/hosts");
    NSString *hostsContent = [NSString stringWithContentsOfFile:hostsPath encoding:NSUTF8StringEncoding error:nil];
    if (!hostsContent || ![hostsContent containsString:kGABHostsStart]) {
        GABLog(@"hosts 中无 GlobalAdBlocker 标记，尝试自动导入默认规则");
        NSString *defaultRulesPath = GABResolvePath(kGABDefaultRulesPath);
        if (![[NSFileManager defaultManager] fileExistsAtPath:defaultRulesPath]) {
            defaultRulesPath = [[NSBundle bundleForClass:[self class]] pathForResource:@"default_rules" ofType:@"json"];
        }
        GABLog(@"默认规则路径: %@ (存在: %@)", defaultRulesPath, defaultRulesPath ? @"是" : @"否");
        if (defaultRulesPath && [[NSFileManager defaultManager] fileExistsAtPath:defaultRulesPath]) {
            [self importRulesFromJSONFile:[NSURL fileURLWithPath:defaultRulesPath] silent:YES];
        }
    }

    [self loadRuleCounts];
}

#pragma mark - hosts 文件操作

- (NSString *)hostsPath {
    return GABResolvePath(@"/etc/hosts");
}

// 读取 hosts，返回标记之外的内容和标记内的域名集合
- (void)parseHosts:(NSString **)outCleanContent domains:(NSMutableSet **)outDomains {
    NSString *hostsPath = [self hostsPath];
    NSString *content = [NSString stringWithContentsOfFile:hostsPath encoding:NSUTF8StringEncoding error:nil];
    if (!content) content = @"";

    NSMutableArray *cleanLines = [NSMutableArray array];
    NSMutableSet *domains = [NSMutableSet set];
    BOOL inBlock = NO;
    NSArray *lines = [content componentsSeparatedByString:@"\n"];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed isEqualToString:kGABHostsStart]) {
            inBlock = YES;
            continue;
        }
        if ([trimmed isEqualToString:kGABHostsEnd]) {
            inBlock = NO;
            continue;
        }
        if (inBlock) {
            // 解析域名：127.0.0.1 domain.com 或 ::1 domain.com
            NSArray *parts = [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (parts.count >= 2) {
                NSString *domain = parts[1];
                if (domain.length > 0 && ![domain hasPrefix:@"#"]) {
                    [domains addObject:domain];
                }
            }
        } else {
            [cleanLines addObject:line];
        }
    }

    if (outCleanContent) *outCleanContent = [cleanLines componentsJoinedByString:@"\n"];
    if (outDomains) *outDomains = domains;
}

// 写入 hosts：干净内容 + 标记 + 域名
- (BOOL)writeHostsWithDomains:(NSSet *)domains cleanContent:(NSString *)cleanContent {
    NSMutableString *newContent = [NSMutableString stringWithString:cleanContent];
    if (![newContent hasSuffix:@"\n"]) [newContent appendString:@"\n"];
    [newContent appendString:kGABHostsStart];
    [newContent appendString:@"\n"];
    [newContent appendString:@"# GlobalAdBlocker 广告拦截规则 (共 "];
    [newContent appendFormat:@"%lu", (unsigned long)domains.count];
    [newContent appendString:@" 条域名)\n"];
    for (NSString *domain in [domains allObjects]) {
        [newContent appendFormat:@"127.0.0.1 %@\n", domain];
        [newContent appendFormat:@"::1 %@\n", domain];
    }
    [newContent appendString:kGABHostsEnd];
    [newContent appendString:@"\n"];

    NSError *error = nil;
    BOOL success = [newContent writeToFile:[self hostsPath] atomically:YES encoding:NSUTF8StringEncoding error:&error];
    GABLog(@"写入 hosts: %@ (%lu 条域名) %@", success ? @"成功" : @"失败", (unsigned long)domains.count, error ?: @"");
    return success;
}

// 刷新 DNS 缓存
- (void)flushDNSCache {
    // 用 system 调用 killall，越狱环境下可用
    system("killall -HUP mDNSResponder 2>/dev/null");
    system("killall mDNSResponderHelper 2>/dev/null");
    GABLog(@"已刷新 DNS 缓存");
}

#pragma mark - 规则统计

- (void)loadRuleCounts {
    NSString *cleanContent = nil;
    NSMutableSet *domains = nil;
    [self parseHosts:&cleanContent domains:&domains];

    self.exactCount = domains.count;
    self.suffixCount = 0; // hosts 方案不区分精确/后缀，统一统计
    GABLog(@"规则统计: hosts 中共 %lu 条拦截域名", (unsigned long)domains.count);
}

#pragma mark - Specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"当前规则" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        PSSpecifier *exactSpec = [PSSpecifier preferenceSpecifierNamed:@"拦截域名" target:self set:Nil get:@selector(exactCountString) detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:exactSpec];

        PSSpecifier *pathHint = [PSSpecifier preferenceSpecifierNamed:@"说明" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [pathHint setProperty:@"通过修改系统 hosts 文件拦截广告域名，所有 App 生效（包括 WebView 广告）。导入 Loon 格式规则自动生成 hosts，无需注销立即生效。" forKey:@"footerText"];
        [specs addObject:pathHint];

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"操作" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        PSSpecifier *importSpec = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [importSpec setProperty:@"从文件导入（Loon 格式）" forKey:@"buttonTitle"];
        [importSpec setProperty:@"importRulesTapped" forKey:@"buttonAction"];
        [specs addObject:importSpec];

        PSSpecifier *reloadSpec = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [reloadSpec setProperty:@"重新加载规则" forKey:@"buttonTitle"];
        [reloadSpec setProperty:@"reloadRulesTapped" forKey:@"buttonAction"];
        [specs addObject:reloadSpec];

        PSSpecifier *clearSpec = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [clearSpec setProperty:@"清空规则" forKey:@"buttonTitle"];
        [clearSpec setProperty:@"clearRulesTapped" forKey:@"buttonAction"];
        [specs addObject:clearSpec];

        _specifiers = specs;
    }
    return _specifiers;
}

- (NSString *)exactCountString {
    return [NSString stringWithFormat:@"%lu 条", (unsigned long)self.exactCount];
}

- (NSString *)suffixCountString {
    return [NSString stringWithFormat:@"%lu 条", (unsigned long)self.suffixCount];
}

#pragma mark - 按钮操作

- (void)reloadRules:(PSSpecifier *)specifier {
    GABLog(@"手动重新加载规则");
    [self flushDNSCache];
    [self loadRuleCounts];
    _specifiers = nil;
    [self reloadSpecifiers];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);

    [self showAlert:@"已重新加载" message:[NSString stringWithFormat:@"共 %lu 条拦截域名，DNS 缓存已刷新", (unsigned long)self.exactCount]];
}

- (void)clearRules:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空规则"
                                                                     message:@"确定删除所有广告拦截规则吗？删除后将不会拦截任何广告。"
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *cleanContent = nil;
        NSMutableSet *domains = nil;
        [self parseHosts:&cleanContent domains:&domains];
        [self writeHostsWithDomains:[NSSet set] cleanContent:cleanContent];
        [self flushDNSCache];

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              (CFStringRef)kGABDarwinNotification,
                                              NULL, NULL, true);
        [self loadRuleCounts];
        _specifiers = nil;
        [self reloadSpecifiers];
        GABLog(@"已清空规则");
        [self showAlert:@"已清空" message:@"所有广告拦截规则已删除，DNS 缓存已刷新"];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importRules:(PSSpecifier *)specifier {
    GABLog(@"点击导入规则按钮");

    UIDocumentPickerViewController *picker = nil;
    @try {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.text", @"public.json", @"public.data"] inMode:UIDocumentPickerModeImport];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
    } @catch (NSException *e) {
        GABLog(@"创建文件选择器失败: %@", e);
    }

    if (!picker) {
        [self showAlert:@"导入失败" message:@"无法创建文件选择器"];
        return;
    }

    @try {
        [self presentViewController:picker animated:YES completion:nil];
    } @catch (NSException *e) {
        [self showAlert:@"导入失败" message:[NSString stringWithFormat:@"无法打开文件选择器: %@", e]];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    [self importRulesFromJSONFile:urls[0] silent:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    GABLog(@"用户取消了文件选择");
}

#pragma mark - Loon 规则解析 + hosts 生成

- (void)importRulesFromJSONFile:(NSURL *)fileURL silent:(BOOL)silent {
    GABLog(@"开始导入文件: %@ (silent=%d)", fileURL, silent);

    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:&error];
    if (!content) {
        GABLog(@"UTF8 读取失败: %@，尝试 ASCII", error);
        content = [NSString stringWithContentsOfURL:fileURL encoding:NSASCIIStringEncoding error:nil];
    }

    if (!content) {
        if (!silent) [self showAlert:@"导入失败" message:@"无法读取文件内容"];
        return;
    }

    GABLog(@"文件内容长度: %lu", (unsigned long)content.length);

    // 解析 Loon 规则（支持 DOMAIN 和 DOMAIN-SUFFIX，都加入 hosts）
    NSMutableSet *domains = [NSMutableSet set];
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    GABLog(@"文件行数: %lu", (unsigned long)lines.count);

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSArray *parts = [trimmed componentsSeparatedByString:@","];
        if (parts.count < 2) continue;

        NSString *ruleType = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *domain = [[parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        if (domain.length == 0) continue;

        if ([ruleType isEqualToString:@"DOMAIN"] ||
            [ruleType isEqualToString:@"DOMAIN-SUFFIX"] ||
            [ruleType isEqualToString:@"HOST"] ||
            [ruleType isEqualToString:@"HOST-SUFFIX"]) {
            [domains addObject:domain];
        }
    }

    GABLog(@"解析完成: 共 %lu 条域名", (unsigned long)domains.count);

    if (domains.count == 0) {
        if (!silent) [self showAlert:@"导入失败" message:@"未找到有效的域名规则（支持 DOMAIN、DOMAIN-SUFFIX、HOST、HOST-SUFFIX）"];
        return;
    }

    // 读取现有 hosts，保留干净内容，替换我们的标记块
    NSString *cleanContent = nil;
    NSMutableSet *existingDomains = nil;
    [self parseHosts:&cleanContent domains:&existingDomains];

    // 合并现有域名和新域名（如果是导入新规则，替换而不是合并）
    // 这里选择替换：导入新规则时完全替换旧规则
    BOOL success = [self writeHostsWithDomains:domains cleanContent:cleanContent];
    if (!success) {
        if (!silent) [self showAlert:@"导入失败" message:@"无法写入 /etc/hosts 文件，请检查权限"];
        return;
    }

    [self flushDNSCache];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);

    [self loadRuleCounts];
    _specifiers = nil;
    [self reloadSpecifiers];

    GABLog(@"导入成功: %lu 条域名", (unsigned long)domains.count);
    if (!silent) {
        [self showAlert:@"导入成功"
                 message:[NSString stringWithFormat:@"共导入 %lu 条域名规则，已写入系统 hosts 文件并刷新 DNS 缓存，所有 App 立即生效。",
                          (unsigned long)domains.count]];
    }
}

#pragma mark - 自定义按钮 cell

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    NSArray *specs = [self specifiers];
    if (indexPath.row >= (NSInteger)specs.count) return cell;
    PSSpecifier *specifier = specs[indexPath.row];
    NSString *buttonAction = [specifier propertyForKey:@"buttonAction"];
    NSString *buttonTitle = [specifier propertyForKey:@"buttonTitle"];

    if (buttonAction && buttonTitle) {
        for (UIView *subview in cell.contentView.subviews) {
            [subview removeFromSuperview];
        }

        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(15, 8, cell.contentView.bounds.size.width - 30, 36);
        button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [button setTitle:buttonTitle forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:17];
        button.backgroundColor = [UIColor colorWithRed:0.12 green:0.56 blue:1.0 alpha:1.0];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.layer.cornerRadius = 8;
        button.clipsToBounds = YES;

        objc_setAssociatedObject(button, "buttonAction", buttonAction, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [button addTarget:self action:@selector(handleButtonTap:) forControlEvents:UIControlEventTouchUpInside];

        [cell.contentView addSubview:button];
        cell.backgroundColor = [UIColor clearColor];
    }

    return cell;
}

- (void)handleButtonTap:(UIButton *)sender {
    NSString *actionName = objc_getAssociatedObject(sender, "buttonAction");
    GABLog(@"按钮点击: %@", actionName);

    if (!actionName) return;

    SEL action = NSSelectorFromString(actionName);
    if ([self respondsToSelector:action]) {
        sender.highlighted = NO;
        [self performSelector:action withObject:nil afterDelay:0.0];
    } else {
        GABLog(@"按钮方法不存在: %@", actionName);
    }
}

- (void)importRulesTapped {
    GABLog(@"导入规则按钮被点击");
    [self importRules:nil];
}

- (void)reloadRulesTapped {
    GABLog(@"重新加载按钮被点击");
    [self reloadRules:nil];
}

- (void)clearRulesTapped {
    GABLog(@"清空规则按钮被点击");
    [self clearRules:nil];
}

#pragma mark - 工具

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
