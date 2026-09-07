#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import "GABLog.h"
#import "GABBinaryRules.h"

// libroot - 动态加载 jbrootpath 函数（避免编译时链接依赖）
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
            if (GABJBRootPath) {
                GABLog(@"成功加载 libroot jbrootpath: %s", libPaths[i]);
                return;
            }
            dlclose(handle);
        }
    }
    GABLog(@"未找到 libroot jbrootpath，使用原始路径");
}

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABAppEnabledPrefix @"GABAppEnabled_"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABMasterSwitchKey @"GABMasterEnabled"

// 二进制规则文件路径，Filza 可直接替换
#define kGABRulesPath @"/Library/Application Support/GlobalAdBlocker/rules.bin"
#define kGABUserRulesPath @"/var/mobile/Documents/GlobalAdBlocker/rules.bin"

// 路径转换工具
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

// mmap 映射的规则上下文
static gab_rules_ctx_t g_rulesCtx;
static void *g_rulesMmapAddr = NULL;
static size_t g_rulesMmapSize = 0;
static int g_rulesMmapFd = -1;
static BOOL g_rulesMapped = NO;
static BOOL g_rulesMapFailed = NO;  // 映射失败标记，避免重复尝试

// 打开规则文件（优先用户空间，其次越狱空间用 jbrootpath 转换）
static int openRulesFile(const char **outPath) {
    // 用静态变量保存转换后的路径，避免临时对象被释放
    static NSString *resolvedJBPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resolvedJBPath = GABResolvePath(kGABRulesPath);
    });

    const char *paths[] = {
        [kGABUserRulesPath fileSystemRepresentation],
        [resolvedJBPath fileSystemRepresentation],
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

// mmap 映射规则文件
static BOOL mapRules(void) {
    if (g_rulesMapped) return YES;
    if (g_rulesMapFailed) return NO;  // 之前失败过，不再重试

    const char *path = NULL;
    int fd = openRulesFile(&path);
    if (fd < 0) {
        GABLog(@"规则文件不存在: %@", kGABRulesPath);
        g_rulesMapFailed = YES;
        return NO;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(gab_rules_header_t)) {
        GABLog(@"规则文件太小或无法 stat: %s", path);
        close(fd);
        g_rulesMapFailed = YES;
        return NO;
    }

    void *addr = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        GABLog(@"mmap 失败: %s (errno=%d)", path, errno);
        close(fd);
        g_rulesMapFailed = YES;
        return NO;
    }

    // 初始化上下文，校验文件头
    int ret = gab_rules_init(&g_rulesCtx, addr, st.st_size);
    if (ret != 0) {
        GABLog(@"规则文件校验失败: error=%d (magic=0x%08X version=%u)",
              ret, g_rulesCtx.header ? g_rulesCtx.header->magic : 0,
              g_rulesCtx.header ? g_rulesCtx.header->version : 0);
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
          path, st.st_size,
          g_rulesCtx.header->exact_count,
          g_rulesCtx.header->suffix_count);

    return YES;
}

// 解除映射（规则更新时调用）
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
    g_rulesMapFailed = NO;  // 重置失败标记，允许重新映射
}

// 域名拦截检查（懒加载 mmap）
static BOOL isDomainBlocked(NSString *host) {
    if (!host || host.length == 0) return NO;

    // 懒加载：第一次调用时才 mmap
    if (!g_rulesMapped) {
        if (!mapRules()) {
            return NO;  // 映射失败，不拦截
        }
    }

    // 转小写（规则文件中的域名已经是小写）
    NSString *lowerHost = [host lowercaseString];
    const char *hostCStr = [lowerHost UTF8String];
    size_t hostLen = strlen(hostCStr);

    return gab_rules_match(&g_rulesCtx, hostCStr, hostLen) ? YES : NO;
}

static BOOL isMasterEnabled(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    if (![defaults objectForKey:kGABMasterSwitchKey]) {
        return YES;
    }
    return [defaults boolForKey:kGABMasterSwitchKey];
}

static BOOL isAppEnabled(NSString *bundleId) {
    if (!bundleId) return NO;

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    NSString *key = [NSString stringWithFormat:@"%@%@", kGABAppEnabledPrefix, bundleId];

    if (![defaults objectForKey:key]) {
        return NO;
    }
    return [defaults boolForKey:key];
}

static NSString *currentAppBundleId(void) {
    return [[NSBundle mainBundle] bundleIdentifier];
}

// Darwin 通知回调：规则/设置变更时重新映射
static void settingsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    GABLog(@"收到设置变更通知，重新映射规则");
    unmapRules();
    // 不立即重新 map，等下次拦截请求时懒加载
    // 如果已经映射过（说明这个 app 开启了拦截），立即重新映射
    if (g_rulesMapped || g_rulesMapFailed) {
        mapRules();
    }
}

static void __attribute__((constructor)) initialize(void) {
    @autoreleasepool {
        GABLog(@"插件初始化(v3.0 mmap共享内存+二进制哈希表)");

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        settingsChangedCallback,
                                        (CFStringRef)kGABDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        GABLog(@"初始化完成, 当前 App: %@ (规则将在首次拦截请求时mmap懒加载)", currentAppBundleId());
    }
}

%hook NSURLSessionTask

- (void)resume {
    @try {
        if (!isMasterEnabled()) {
            %orig;
            return;
        }

        NSString *bundleId = currentAppBundleId();
        if (!isAppEnabled(bundleId)) {
            %orig;
            return;
        }

        NSURL *url = [self originalRequest] ? [[self originalRequest] URL] : [[self currentRequest] URL];
        if (!url) {
            %orig;
            return;
        }

        NSString *host = [url host];
        if (!host) {
            %orig;
            return;
        }

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
