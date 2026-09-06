#import "GABRuleManagerController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "GABLog.h"

#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
// prefs 进程在 user 空间（嫁接后），bundle 目录可见
#define kGABCustomRulesPath @"/Library/Application Support/GlobalAdBlocker/custom_rules.json"
#define kGABDefaultRulesPath @"/Library/PreferenceBundles/GlobalAdBlockerPrefs.bundle/default_rules.json"

@implementation GABRuleManagerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"规则管理";
    GABLog(@"规则管理页面加载");
    [self loadRuleCounts];
}

- (void)loadRuleCounts {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *rulesPath = nil;

    // 检查 PreferenceBundle 目录
    NSString *bundleDir = @"/Library/PreferenceBundles/GlobalAdBlockerPrefs.bundle";
    BOOL dirExists = [fm fileExistsAtPath:bundleDir];
    GABLog(@"PreferenceBundle 目录 %@ : %@", bundleDir, dirExists ? @"存在" : @"不存在");
    if (dirExists) {
        NSArray *dirFiles = [fm contentsOfDirectoryAtPath:bundleDir error:nil];
        GABLog(@"PreferenceBundle 内容: %@", dirFiles);
    }

    NSString *jbBundleDir = @"/var/jb/Library/PreferenceBundles/GlobalAdBlockerPrefs.bundle";
    BOOL jbDirExists = [fm fileExistsAtPath:jbBundleDir];
    GABLog(@"PreferenceBundle(RootHide) 目录 %@ : %@", jbBundleDir, jbDirExists ? @"存在" : @"不存在");
    if (jbDirExists) {
        NSArray *dirFiles = [fm contentsOfDirectoryAtPath:jbBundleDir error:nil];
        GABLog(@"PreferenceBundle(RootHide) 内容: %@", dirFiles);
    }

    // 检查所有可能的路径
    NSArray *possiblePaths = @[
        kGABCustomRulesPath,
        [@"/var/jb" stringByAppendingString:kGABCustomRulesPath],
        kGABDefaultRulesPath,
        [@"/var/jb" stringByAppendingString:kGABDefaultRulesPath],
    ];

    for (NSString *path in possiblePaths) {
        BOOL exists = [fm fileExistsAtPath:path];
        GABLog(@"检查路径 %@ : %@", path, exists ? @"存在" : @"不存在");
        if (exists && !rulesPath) {
            rulesPath = path;
        }
    }

    GABLog(@"最终使用规则文件路径: %@", rulesPath);

    if (!rulesPath) {
        self.exactCount = 0;
        self.suffixCount = 0;
        GABLog(@"未找到规则文件");
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:rulesPath];
    if (!data) {
        GABLog(@"读取规则文件失败");
        self.exactCount = 0;
        self.suffixCount = 0;
        return;
    }

    NSError *error = nil;
    NSDictionary *rules = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!rules || error) {
        GABLog(@"解析规则失败: %@", error);
        self.exactCount = 0;
        self.suffixCount = 0;
        return;
    }

    self.exactCount = [rules[@"exact"] count];
    self.suffixCount = [rules[@"suffix"] count];
    GABLog(@"规则加载完成: 精确 %ld, 后缀 %ld", (long)self.exactCount, (long)self.suffixCount);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *group1 = [PSSpecifier preferenceSpecifierNamed:@"当前规则" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [specs addObject:group1];

        PSSpecifier *typeSpec = [PSSpecifier preferenceSpecifierNamed:@"规则来源" target:self set:Nil get:@selector(ruleSource) detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:typeSpec];

        PSSpecifier *exactSpec = [PSSpecifier preferenceSpecifierNamed:@"精确匹配" target:self set:Nil get:@selector(exactCountString) detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:exactSpec];

        PSSpecifier *suffixSpec = [PSSpecifier preferenceSpecifierNamed:@"后缀匹配" target:self set:Nil get:@selector(suffixCountString) detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:suffixSpec];

        PSSpecifier *group2 = [PSSpecifier preferenceSpecifierNamed:@"导入规则" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [specs addObject:group2];

        PSSpecifier *importSpec = [PSSpecifier preferenceSpecifierNamed:@"从文件导入（Loon 格式）" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [importSpec setProperty:@"importRules" forKey:@"action"];
        [specs addObject:importSpec];

        PSSpecifier *resetSpec = [PSSpecifier preferenceSpecifierNamed:@"恢复默认规则" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [resetSpec setProperty:@"resetRules" forKey:@"action"];
        [specs addObject:resetSpec];

        // 一键刷新：重读规则 + 重扫 App 列表
        PSSpecifier *refreshSpec = [PSSpecifier preferenceSpecifierNamed:@"刷新（重读规则 + 重扫 App）"
                                                                  target:self
                                                                     set:Nil
                                                                     get:Nil
                                                                  detail:Nil
                                                                    cell:PSButtonCell
                                                                    edit:Nil];
        [refreshSpec setProperty:@"refreshAll" forKey:@"action"];
        [specs addObject:refreshSpec];

        // 用 footerText 显示说明，避免文字被截断
        PSSpecifier *group3 = [PSSpecifier preferenceSpecifierNamed:@"说明" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [group3 setProperty:@"支持 Loon 导出的 .list / .conf 格式，自动识别 DOMAIN 和 DOMAIN-SUFFIX 规则。导入后所有 App 进程自动重载规则，立即生效。日志文件: /tmp/globaladblocker.log" forKey:@"footerText"];
        [specs addObject:group3];

        _specifiers = specs;
    }
    return _specifiers;
}

- (NSString *)ruleSource {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kGABCustomRulesPath]) return @"自定义（已导入）";
    NSString *jbPath = [@"/var/jb" stringByAppendingString:kGABCustomRulesPath];
    if ([fm fileExistsAtPath:jbPath]) return @"自定义（已导入）";
    return @"内置默认";
}

- (NSString *)exactCountString {
    return [NSString stringWithFormat:@"%ld 条", (long)self.exactCount];
}

- (NSString *)suffixCountString {
    return [NSString stringWithFormat:@"%ld 条", (long)self.suffixCount];
}

- (void)importRules {
    GABLog(@"点击导入规则按钮");

    UIDocumentPickerViewController *picker = nil;
    @try {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.text", @"public.data", @"com.apple.property-list"] inMode:UIDocumentPickerModeImport];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
    } @catch (NSException *e) {
        GABLog(@"创建 DocumentPicker 失败: %@", e);
        [self showAlert:@"导入失败" message:@"无法创建文件选择器，请检查系统版本"];
        return;
    }

    if (!picker) {
        GABLog(@"DocumentPicker 创建失败，返回 nil");
        [self showAlert:@"导入失败" message:@"无法创建文件选择器"];
        return;
    }

    GABLog(@"DocumentPicker 创建成功，开始 present");

    @try {
        [self presentViewController:picker animated:YES completion:^{
            GABLog(@"DocumentPicker present 完成");
        }];
    } @catch (NSException *e) {
        GABLog(@"present DocumentPicker 失败: %@", e);
        [self showAlert:@"导入失败" message:[NSString stringWithFormat:@"无法打开文件选择器: %@", e]];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    GABLog(@"documentPicker 回调，URL 数量: %lu", (unsigned long)urls.count);
    if (urls.count == 0) {
        GABLog(@"没有选择文件");
        return;
    }
    [self importRulesFromFile:urls[0]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    GABLog(@"用户取消了文件选择");
}

- (void)importRulesFromFile:(NSURL *)fileURL {
    GABLog(@"开始导入文件: %@", fileURL);

    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:&error];
    if (!content) {
        GABLog(@"UTF8 读取失败: %@，尝试 ASCII", error);
        content = [NSString stringWithContentsOfURL:fileURL encoding:NSASCIIStringEncoding error:nil];
    }

    if (!content) {
        GABLog(@"无法读取文件内容");
        [self showAlert:@"导入失败" message:@"无法读取文件内容"];
        return;
    }

    GABLog(@"文件内容长度: %lu", (unsigned long)content.length);

    NSMutableSet *exactDomains = [NSMutableSet set];
    NSMutableSet *suffixDomains = [NSMutableSet set];

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

        if ([ruleType isEqualToString:@"DOMAIN"]) {
            [exactDomains addObject:domain];
        } else if ([ruleType isEqualToString:@"DOMAIN-SUFFIX"] || [ruleType isEqualToString:@"DOMAIN-KEYWORD"]) {
            [suffixDomains addObject:domain];
        }
    }

    GABLog(@"解析完成: 精确 %lu, 后缀 %lu", (unsigned long)exactDomains.count, (unsigned long)suffixDomains.count);

    if (exactDomains.count == 0 && suffixDomains.count == 0) {
        GABLog(@"未找到有效规则");
        [self showAlert:@"导入失败" message:@"未找到有效规则，请确认是 Loon 格式（DOMAIN 或 DOMAIN-SUFFIX 开头）"];
        return;
    }

    NSDictionary *rules = @{@"exact": [exactDomains allObjects], @"suffix": [suffixDomains allObjects]};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    if (!jsonData) {
        GABLog(@"规则数据序列化失败");
        [self showAlert:@"导入失败" message:@"规则数据序列化失败"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *savePath = kGABCustomRulesPath;
    [fm createDirectoryAtPath:[savePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL saved = [jsonData writeToFile:savePath atomically:YES];
    GABLog(@"保存到 %@: %@", savePath, saved ? @"成功" : @"失败");

    if (!saved) {
        NSString *jbSavePath = [@"/var/jb" stringByAppendingString:savePath];
        [fm createDirectoryAtPath:[jbSavePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        saved = [jsonData writeToFile:jbSavePath atomically:YES];
        GABLog(@"保存到 %@: %@", jbSavePath, saved ? @"成功" : @"失败");
    }

    if (!saved) {
        GABLog(@"保存规则文件失败");
        [self showAlert:@"导入失败" message:@"无法保存规则文件，请检查权限"];
        return;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);

    [self loadRuleCounts];
    [self reloadSpecifiers];

    GABLog(@"导入成功");
    [self showAlert:@"导入成功"
             message:[NSString stringWithFormat:@"共导入 %ld 条规则（精确 %ld 条，后缀 %ld 条），已立即生效",
                      (long)(exactDomains.count + suffixDomains.count),
                      (long)exactDomains.count,
                      (long)suffixDomains.count]];
}

- (void)refreshAll {
    GABLog(@"一键刷新：重读规则");
    // 触发 darwin 通知，tweak 收到后会重新读规则文件和设置
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                      (CFStringRef)kGABDarwinNotification,
                                      NULL, NULL, true);
    [self loadRuleCounts];
    [self reloadSpecifiers];
    GABLog(@"刷新完成");
    [self showAlert:@"已刷新" message:@"规则已重载，下次点击会读最新内容"];
}

- (void)resetRules {
    GABLog(@"点击恢复默认规则");

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认规则"
                                                                     message:@"确定删除自定义规则，恢复内置默认规则吗？"
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:kGABCustomRulesPath error:nil];
        [fm removeItemAtPath:[@"/var/jb" stringByAppendingString:kGABCustomRulesPath] error:nil];

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              (CFStringRef)kGABDarwinNotification,
                                              NULL, NULL, true);
        [self loadRuleCounts];
        [self reloadSpecifiers];
        GABLog(@"已恢复默认规则");
        [self showAlert:@"已恢复" message:@"已恢复内置默认规则"];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
