#import <Foundation/Foundation.h>

static inline void GABLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *entry = [NSString stringWithFormat:@"[%@][%@] %@\n",
                       [fmt stringFromDate:[NSDate date]], bundleId, line];

    NSString *logPath = @"/tmp/globaladblocker.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:logPath
                                                contents:nil
                                              attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [fh seekToEndOfFile];
    [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];

    NSLog(@"[GlobalAdBlocker] %@", line);
}
