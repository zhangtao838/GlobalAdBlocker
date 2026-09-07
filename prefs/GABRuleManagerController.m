#import "GABRuleManagerController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "GABLog.h"
#import "GABBinaryRules.h"

#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABRulesPath @"/Library/Application Support/GlobalAdBlocker/rules.bin"

@implementation GABRuleManagerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"规则管理";
    GABLog(@"规则管理页面加载(v3.0 二进制规则)");
    [self loadRuleCounts];
}

- (void)loadRuleCounts {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *rulesPath = nil;
    if ([fm fileExistsAtPath:kGABRulesPath]) {
        rulesPath = kGABRulesPath;
    } else {
        NSString *jbPath = [@"/var/jb" stringByAppendingString:kGABRulesPath];
        if ([fm fileExistsAtPath:jbPath]) {
            rulesPath = jbPath;
        }
    }

    GABLog(@"规则文件路径: %@ (存在: %@)", rulesPath ?: @"未找到", rulesPath ? @"是" : @"否");

    if (!rulesPath) {
        self.exactCount = 0;
        self.suffixCount = 0;
        GABLog(@"规则文件不存在");
        return;
    }

    // 从二进制文件头读取规则数量
    NSData *data = [NSData dataWithContentsOfFile:rulesPath];
    if (!data || data.length < sizeof(gab_rules_header_t)) {
        GABLog(@"规则文件太小或读取失败: %@", rulesPath);
        self.exactCount = 0;
        self.suffixCount = 0;
        return;
    }

    const gab_rules_header_t *header = (const gab_rules_header_t *)data.bytes;
    if (header->magic != GAB_RULES_MAGIC) {
        GABLog(@"规则文件魔数错误: 0x%08X (期望 0x%08X)", header->magic, GAB_RULES_MAGIC);
        self.exactCount = 0;
        self.suffixCount = 0;
        return;
    }

    self.exactCount = header->exact_count;
    self.suffixCount = header->suffix_count;
    GABLog(@"规则加载完成: 精确 %u, 后缀 %u (版本 %u)", header->exact_count, header->suffix_count, header->version);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // 当前规则
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"当前规则" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        PSSpecifier *exactSpec = [PSSpecifier preferenceSpecifierNamed:@"精确匹配" target:self set:Nil get:@selector(exactCountString) detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:exactSpec];

        PSSpecifier *suffixSpec = [PSSpecifier preferenceSpecifierNamed:@"后缀匹配" target:self set:Nil get:@selector(suffixCountString) detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:suffixSpec];

        // 规则文件位置
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"规则文件" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        PSSpecifier *pathSpec = [PSSpecifier preferenceSpecifierNamed:kGABRulesPath target:self set:Nil get:Nil detail:Nil cell:PSTitleValueCell edit:Nil];
        [specs addObject:pathSpec];

        PSSpecifier *pathHint = [PSSpecifier preferenceSpecifierNamed:@"说明" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil];
        [pathHint setProperty:@"可用 Filza 直接替换此二进制规则文件，或在下方导入 Loon 规则自动编译。替换后点击「重新加载规则」立即生效。" forKey:@"footerText"];
        [specs addObject:pathHint];

        // 操作
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"操作" target:self set:Nil get:Nil detail:Nil cell:PSGroupCell edit:Nil]];

        PSSpecifier *importSpec = [PSSpecifier preferenceSpecifierNamed:@"从文件导入（Loon 格式）" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [importSpec setProperty:@"importRules" forKey:@"action"];
        [specs addObject:importSpec];

        PSSpecifier *reloadSpec = [PSSpecifier preferenceSpecifierNamed:@"重新加载规则" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [reloadSpec setProperty:@"reloadRules" forKey:@"action"];
        [specs addObject:reloadSpec];

        PSSpecifier *clearSpec = [PSSpecifier preferenceSpecifierNamed:@"清空规则" target:self set:Nil get:Nil detail:Nil cell:PSButtonCell edit:Nil];
        [clearSpec setProperty:@"clearRules" forKey:@"action"];
        [specs addObject:clearSpec];

        _specifiers = specs;
    }
    return _specifiers;
}

- (NSString *)exactCountString {
    return [NSString stringWithFormat:@"%u 条", (unsigned)self.exactCount];
}

- (NSString *)suffixCountString {
    return [NSString stringWithFormat:@"%u 条", (unsigned)self.suffixCount];
}

- (void)reloadRules {
    GABLog(@"手动重新加载规则");
    [self loadRuleCounts];
    _specifiers = nil;
    [self reloadSpecifiers];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);

    [self showAlert:@"已重新加载" message:[NSString stringWithFormat:@"精确 %u 条，后缀 %u 条，所有 App 进程已立即重新映射", (unsigned)self.exactCount, (unsigned)self.suffixCount]];
}

- (void)clearRules {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空规则"
                                                                     message:@"确定删除所有规则吗？删除后将不会拦截任何广告，可重新导入 Loon 规则。"
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:kGABRulesPath error:nil];
        [fm removeItemAtPath:[@"/var/jb" stringByAppendingString:kGABRulesPath] error:nil];

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              (CFStringRef)kGABDarwinNotification,
                                              NULL, NULL, true);
        [self loadRuleCounts];
        _specifiers = nil;
        [self reloadSpecifiers];
        GABLog(@"已清空规则");
        [self showAlert:@"已清空" message:@"规则已清空，可导入 Loon 规则重新添加"];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
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
    [self importRulesFromFile:urls[0]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    GABLog(@"用户取消了文件选择");
}

#pragma mark - Loon 规则解析 + 二进制编译

// FNV-1a 哈希（与 C 端一致）
static uint32_t gab_hash_c(const char *str, size_t len) {
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        hash ^= (uint8_t)str[i];
        hash *= 16777619u;
    }
    return hash;
}

static uint32_t next_power_of_2(uint32_t n) {
    if (n == 0) return 1;
    n--;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
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
        [self showAlert:@"导入失败" message:@"无法读取文件内容"];
        return;
    }

    GABLog(@"文件内容长度: %lu", (unsigned long)content.length);

    // 解析 Loon 规则
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
        [self showAlert:@"导入失败" message:@"未找到有效规则，请确认是 Loon 格式（DOMAIN 或 DOMAIN-SUFFIX 开头）"];
        return;
    }

    // 编译成二进制格式
    NSData *binaryData = [self compileBinaryRulesWithExact:exactDomains suffix:suffixDomains];
    if (!binaryData) {
        [self showAlert:@"导入失败" message:@"规则编译失败"];
        return;
    }

    GABLog(@"二进制规则编译完成: %lu bytes", (unsigned long)binaryData.length);

    // 保存到文件
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *savePath = kGABRulesPath;
    [fm createDirectoryAtPath:[savePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL saved = [binaryData writeToFile:savePath atomically:YES];
    GABLog(@"保存到 %@: %@", savePath, saved ? @"成功" : @"失败");

    if (!saved) {
        NSString *jbSavePath = [@"/var/jb" stringByAppendingString:savePath];
        [fm createDirectoryAtPath:[jbSavePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        saved = [binaryData writeToFile:jbSavePath atomically:YES];
        GABLog(@"保存到 %@: %@", jbSavePath, saved ? @"成功" : @"失败");
    }

    if (!saved) {
        [self showAlert:@"导入失败" message:@"无法保存规则文件，请检查权限"];
        return;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (CFStringRef)kGABDarwinNotification,
                                          NULL, NULL, true);

    [self loadRuleCounts];
    _specifiers = nil;
    [self reloadSpecifiers];

    GABLog(@"导入成功");
    [self showAlert:@"导入成功"
             message:[NSString stringWithFormat:@"共导入 %lu 条规则（精确 %lu 条，后缀 %lu 条），已编译为二进制格式并立即生效。\n规则文件: %@",
                      (unsigned long)(exactDomains.count + suffixDomains.count),
                      (unsigned long)exactDomains.count,
                      (unsigned long)suffixDomains.count,
                      savePath]];
}

// 编译规则为二进制格式
- (NSData *)compileBinaryRulesWithExact:(NSSet *)exactSet suffix:(NSSet *)suffixSet {
    NSArray *exactDomains = [[exactSet allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSArray *suffixDomains = [[suffixSet allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    uint32_t exactCount = (uint32_t)exactDomains.count;
    uint32_t suffixCount = (uint32_t)suffixDomains.count;

    // 1. 构建字符串池（偏移0保留给空槽标记）
    NSMutableData *stringPool = [NSMutableData dataWithBytes:"\x00" length:1];
    NSMutableDictionary *domainOffsets = [NSMutableDictionary dictionary];

    for (NSString *domain in exactDomains) {
        if (domainOffsets[domain]) continue;
        NSData *domainData = [domain dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t nullByte = 0;
        [stringPool appendData:domainData];
        [stringPool appendBytes:&nullByte length:1];
        domainOffsets[domain] = @(stringPool.length - domainData.length - 1);
    }
    for (NSString *domain in suffixDomains) {
        if (domainOffsets[domain]) continue;
        NSData *domainData = [domain dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t nullByte = 0;
        [stringPool appendData:domainData];
        [stringPool appendBytes:&nullByte length:1];
        domainOffsets[domain] = @(stringPool.length - domainData.length - 1);
    }

    uint32_t stringPoolSize = (uint32_t)stringPool.length;

    // 2. 构建精确匹配哈希表（开放寻址法）
    uint32_t exactHashSize = (exactCount > 0) ? next_power_of_2(exactCount * 2) : 1;
    NSMutableData *exactTable = [NSMutableData dataWithLength:exactHashSize * sizeof(gab_exact_entry_t)];
    gab_exact_entry_t *exactEntries = (gab_exact_entry_t *)exactTable.mutableBytes;

    for (NSString *domain in exactDomains) {
        const char *domainCStr = [domain UTF8String];
        size_t domainLen = strlen(domainCStr);
        uint32_t hash = gab_hash_c(domainCStr, domainLen);
        uint32_t mask = exactHashSize - 1;
        uint32_t idx = hash & mask;
        uint32_t strOffset = [domainOffsets[domain] unsignedIntValue];

        while (exactEntries[idx].str_offset != 0) {
            idx = (idx + 1) & mask;
        }
        exactEntries[idx].hash = hash;
        exactEntries[idx].str_offset = strOffset;
    }

    // 3. 构建后缀匹配数组（按最后一个字节分桶）
    NSMutableArray *buckets = [NSMutableArray arrayWithCapacity:GAB_BUCKET_COUNT];
    for (int i = 0; i < GAB_BUCKET_COUNT; i++) {
        [buckets addObject:[NSMutableArray array]];
    }

    for (NSString *domain in suffixDomains) {
        const char *domainCStr = [domain UTF8String];
        size_t domainLen = strlen(domainCStr);
        uint8_t lastByte = (uint8_t)domainCStr[domainLen - 1];
        [buckets[lastByte] addObject:domain];
    }

    // 每个桶内排序
    for (int i = 0; i < GAB_BUCKET_COUNT; i++) {
        buckets[i] = [buckets[i] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }

    // 计算桶偏移
    uint32_t bucketOffsets[GAB_BUCKET_COUNT];
    uint32_t bucketCounts[GAB_BUCKET_COUNT];
    uint32_t currentOffset = 0;
    for (int i = 0; i < GAB_BUCKET_COUNT; i++) {
        bucketOffsets[i] = currentOffset;
        bucketCounts[i] = (uint32_t)[buckets[i] count];
        currentOffset += bucketCounts[i];
    }

    // 构建后缀数组
    NSMutableData *suffixArray = [NSMutableData dataWithLength:suffixCount * sizeof(gab_suffix_entry_t)];
    gab_suffix_entry_t *suffixEntries = (gab_suffix_entry_t *)suffixArray.mutableBytes;
    uint32_t suffixIdx = 0;
    for (int i = 0; i < GAB_BUCKET_COUNT; i++) {
        for (NSString *domain in buckets[i]) {
            const char *domainCStr = [domain UTF8String];
            suffixEntries[suffixIdx].length = (uint16_t)strlen(domainCStr);
            suffixEntries[suffixIdx].str_offset = [domainOffsets[domain] unsignedIntValue];
            suffixIdx++;
        }
    }

    // 4. 计算各部分偏移
    uint32_t headerSize = (uint32_t)sizeof(gab_rules_header_t);
    uint32_t exactHashOffset = headerSize;
    uint32_t suffixArrayOffset = exactHashOffset + exactHashSize * (uint32_t)sizeof(gab_exact_entry_t);
    uint32_t stringPoolOffset = suffixArrayOffset + suffixCount * (uint32_t)sizeof(gab_suffix_entry_t);

    // 对齐到4字节
    if (stringPoolOffset % 4 != 0) {
        stringPoolOffset += 4 - (stringPoolOffset % 4);
    }

    uint32_t totalSize = stringPoolOffset + stringPoolSize;

    GABLog(@"二进制编译: header=%u exactTable=%u(%u槽) suffixArray=%u stringPool=%u total=%u",
          headerSize, exactHashSize * (uint32_t)sizeof(gab_exact_entry_t), exactHashSize,
          suffixCount * (uint32_t)sizeof(gab_suffix_entry_t), stringPoolSize, totalSize);

    // 5. 组装二进制文件
    NSMutableData *binary = [NSMutableData dataWithCapacity:totalSize];

    // 文件头
    gab_rules_header_t header;
    memset(&header, 0, sizeof(header));
    header.magic = GAB_RULES_MAGIC;
    header.version = GAB_RULES_VERSION;
    header.exact_count = exactCount;
    header.suffix_count = suffixCount;
    header.exact_hash_size = exactHashSize;
    header.exact_hash_offset = exactHashOffset;
    header.suffix_array_offset = suffixArrayOffset;
    header.string_pool_offset = stringPoolOffset;
    header.string_pool_size = stringPoolSize;
    memcpy(header.bucket_offsets, bucketOffsets, sizeof(bucketOffsets));
    memcpy(header.bucket_counts, bucketCounts, sizeof(bucketCounts));
    [binary appendBytes:&header length:sizeof(header)];

    // 精确匹配哈希表
    [binary appendData:exactTable];

    // 后缀匹配数组
    [binary appendData:suffixArray];

    // 对齐填充
    while (binary.length < stringPoolOffset) {
        uint8_t zero = 0;
        [binary appendBytes:&zero length:1];
    }

    // 字符串池
    [binary appendData:stringPool];

    return binary;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
