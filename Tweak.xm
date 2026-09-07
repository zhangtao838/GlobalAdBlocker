#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import "GABLog.h"
#import "GABBinaryRules.h"

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABAppEnabledPrefix @"GABAppEnabled_"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABMasterSwitchKey @"GABMasterEnabled"

#define kGABRulesPath @"/Library/Application Support/GlobalAdBlocker/rules.bin"

static gab_rules_ctx_t g_rulesCtx;
static void *g_rulesMmapAddr = NULL;
static size_t g_rulesMmapSize = 0;
static int g_rulesMmapFd = -1;
static BOOL g_rulesMapped = NO;
static BOOL g_rulesMapFailed = NO;

static int openRulesFile(const char **outPath) {
    const char *paths[] = {
        [kGABRulesPath fileSystemRepresentation],
        [[@"/var/jb" stringByAppendingString:kGABRulesPath] fileSystemRepresentation],
        NULL
    };
    for (int i = 0; paths[i] != NULL; i++) {
        int fd = open(paths[i], O_RDONLY);
        if (fd >= 0) {
            if (outPath) *outPath = paths[i];
            return fd;
        }
    }
    return -1;
}

static BOOL mapRules(void) {
    if (g_rulesMapped) return YES;
    if (g_rulesMapFailed) return NO;

    const char *path = NULL;
    int fd = openRulesFile(&path);
    if (fd < 0) {
        GABLog(@"规则文件不存在: %@", kGABRulesPath);
        g_rulesMapFailed = YES;
        return NO;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(gab_rules_header_t)) {
        GABLog(@"规则文件太小或无法 stat");
        close(fd);
        g_rulesMapFailed = YES;
        return NO;
    }

    void *addr = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        GABLog(@"mmap 失败 (errno=%d)", errno);
        close(fd);
        g_rulesMapFailed = YES;
        return NO;
    }

    int ret = gab_rules_init(&g_rulesCtx, addr, st.st_size);
    if (ret != 0) {
        GABLog(@"规则文件校验失败: error=%d", ret);
        munmap(addr, st.st_size);
        close(fd);
        g_rulesMapFailed = YES;
        return NO;
    }

    g_rulesMmapAddr = addr;
    g_rulesMmapSize = st.st_size;
    g_rulesMmapFd = fd;
    g_rulesMapped = YES;

    GABLog(@"规则 mmap 成功: %s (%zu bytes, 精确 %u 条, 后缀 %u 条)",
          path, st.st_size, g_rulesCtx.header->exact_count, g_rulesCtx.header->suffix_count);
    return YES;
}

static void unmapRules(void) {
    if (g_rulesMmapAddr && g_rulesMmapSize > 0) {
        munmap(g_rulesMmapAddr, g_rulesMmapSize);
        g_rulesMmapAddr = NULL;
        g_rulesMmapSize = 0;
    }
    if (g_rulesMmapFd >= 0) {
        close(g_rulesMmapFd);
        g_rulesMmapFd = -1;
    }
    memset(&g_rulesCtx, 0, sizeof(g_rulesCtx));
    g_rulesMapped = NO;
    g_rulesMapFailed = NO;
}

static BOOL isDomainBlocked(NSString *host) {
    if (!host || host.length == 0) return NO;
    if (!g_rulesMapped) {
        if (!mapRules()) return NO;
    }
    NSString *lowerHost = [host lowercaseString];
    const char *hostCStr = [lowerHost UTF8String];
    size_t hostLen = strlen(hostCStr);
    return gab_rules_match(&g_rulesCtx, hostCStr, hostLen) ? YES : NO;
}

static BOOL isMasterEnabled(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    if (![defaults objectForKey:kGABMasterSwitchKey]) return YES;
    return [defaults boolForKey:kGABMasterSwitchKey];
}

static BOOL isAppEnabled(NSString *bundleId) {
    if (!bundleId) return NO;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];
    if (![defaults objectForKey:key]) return NO;
    return [defaults boolForKey:key];
}

static NSString *currentAppBundleId(void) {
    return [[NSBundle mainBundle] bundleIdentifier];
}

static void settingsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    GABLog(@"收到设置变更通知，重新映射规则");
    unmapRules();
    if (g_rulesMapped || g_rulesMapFailed) {
        mapRules();
    }
}

static void __attribute__((constructor)) initialize(void) {
    @autoreleasepool {
        GABLog(@"插件初始化(v3.0 mmap共享内存+二进制哈希表)");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, settingsChangedCallback,
                                        (CFStringRef)kGABDarwinNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        GABLog(@"初始化完成, 当前 App: %@ (规则将在首次拦截请求时mmap懒加载)", currentAppBundleId());
    }
}

%hook NSURLSessionTask

- (void)resume {
    @try {
        if (!isMasterEnabled()) { %orig; return; }
        NSString *bundleId = currentAppBundleId();
        if (!isAppEnabled(bundleId)) { %orig; return; }
        NSURL *url = [self originalRequest] ? [[self originalRequest] URL] : [[self currentRequest] URL];
        if (!url) { %orig; return; }
        NSString *host = [url host];
        if (!host) { %orig; return; }
        if (isDomainBlocked(host)) {
            GABLog(@"拦截广告: %@ (App: %@)", host, bundleId);
            [self cancel];
            return;
        }
    } @catch (NSException *e) {
        GABLog(@"resume hook 异常: %@", e);
    }
    %orig;
}

%end
