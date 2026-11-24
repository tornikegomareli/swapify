#import "Agent.h"
#include <arpa/inet.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>

// Wire protocol: one command per line on 127.0.0.1:$SWAPIFY_PORT (on a device,
// every interface), one JSON object per line back. See docs/protocol.md.

double SWPNowMs(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1e3 + now.tv_nsec / 1e6;
}

static NSString *json(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : @"{\"ok\":false,\"error\":\"reply is not JSON\"}";
}

// device: P_TRACED, so the CLI can show that no debugger is attached.
static BOOL traced(void) {
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    return sysctl(mib, 4, &info, &size, NULL, 0) == 0 && (info.kp_proc.p_flag & P_TRACED);
}

// device: `put <name> <size>` followed by <size> raw bytes stores a file in the app's tmp/, because
// the app cannot read the Mac's files. `load` then takes the returned path.
static NSDictionary *receiveFile(FILE *io, NSString *arguments) {
    NSArray<NSString *> *parts = [arguments componentsSeparatedByString:@" "];
    long long size = parts.count == 2 ? parts[1].longLongValue : 0;
    if (size <= 0 || size > (64 << 20)) return @{@"ok" : @NO, @"error" : @"usage: put <name> <size>"};
    double start = SWPNowMs();
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
    if (fread(data.mutableBytes, 1, (size_t)size, io) != (size_t)size)
        return @{@"ok" : @NO, @"error" : @"connection closed before all bytes arrived"};
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:parts[0].lastPathComponent];
    if (![data writeToFile:path atomically:YES]) return @{@"ok" : @NO, @"error" : @"cannot write the file"};
    return @{@"ok" : @YES, @"path" : path, @"bytes" : @(size), @"ms" : @(SWPNowMs() - start)};
}

static NSDictionary *onMain(NSDictionary * (^block)(void)) {
    __block NSDictionary *result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

static NSDictionary *handle(NSString *line) {
    if ([line isEqualToString:@"ping"])
        return @{
            @"ok" : @YES, @"protocol" : @SWP_PROTOCOL_VERSION, @"generation" : @(SWPPatcherGeneration()),
            @"bundleID" : NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"swiftUIRefresh" : @(SWPSwiftUIRefreshAvailable()),
            @"device" : @((BOOL)!TARGET_OS_SIMULATOR), @"traced" : @(traced()),  // device: no debugger check
        };
    if ([line hasPrefix:@"load "]) return SWPPatcherLoad([line substringFromIndex:5]);
    if ([line isEqualToString:@"refresh"]) return onMain(^{ return SWPSwiftUIRefresh(); });
    // device: with no path the PNG comes back in the reply, because the app cannot write Mac paths.
    if ([line isEqualToString:@"snapshot"]) return onMain(^{ return SWPSnapshot(nil, 1); });
    if ([line hasPrefix:@"snapshot "]) {
        NSString *path = [line substringFromIndex:9];
        return onMain(^{ return SWPSnapshot(path, 1); });
    }
    if ([line isEqualToString:@"ui"] || [line hasPrefix:@"tap "]) {
        if ([onMain(^{ return @{@"enabled" : @(SWPEnableAccessibility())}; })[@"enabled"] boolValue])
            usleep(500 * 1000);  // SwiftUI builds its accessibility tree on the next update
        if ([line isEqualToString:@"ui"]) return onMain(^{ return SWPDescribeUI(); });
        NSString *query = [line substringFromIndex:4];
        return onMain(^{ return SWPTap(query); });
    }
    return @{@"ok" : @NO, @"error" : [@"unknown command: " stringByAppendingString:line]};
}

static void serve(int client) {
    FILE *io = fdopen(client, "r+");
    char line[PATH_MAX + 64];
    while (fgets(line, sizeof line, io)) {
        line[strcspn(line, "\r\n")] = 0;
        @autoreleasepool {
            NSString *command = @(line);
            NSString *reply = json([command hasPrefix:@"put "] ? receiveFile(io, [command substringFromIndex:4])
                                                                : handle(command));
            SWP_LOG("%s -> %.240s\n", line, reply.UTF8String);
            fprintf(io, "%s\n", reply.UTF8String);
            fflush(io);
        }
    }
    fclose(io);
}

static void *listenLoop(void *unused) {
    const char *value = getenv("SWAPIFY_PORT");
    int port = value ? atoi(value) : 0;
    int yes = 1;
#if TARGET_OS_SIMULATOR
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(port)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const char *where = "127.0.0.1";
#else
    // device: the Mac connects over the CoreDevice tunnel or Wi-Fi, so listen on every interface,
    // IPv6 and IPv4.
    int fd = socket(AF_INET6, SOCK_STREAM, 0), no = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof no);
    struct sockaddr_in6 address = {.sin6_len = sizeof address, .sin6_family = AF_INET6, .sin6_port = htons(port),
                                   .sin6_addr = IN6ADDR_ANY_INIT};
    const char *where = "[::]";
#endif
    if (port <= 0 || bind(fd, (void *)&address, sizeof address) || listen(fd, 4)) {
        SWP_LOG("cannot listen on port %d (set SWAPIFY_PORT)\n", port);
        return NULL;
    }
    SWP_LOG("listening on %s:%d\n", where, port);
    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client >= 0) serve(client);
    }
}

__attribute__((constructor)) static void start(void) {
    SWPPatcherStart();
    pthread_t thread;
    pthread_create(&thread, NULL, listenLoop, NULL);
    pthread_detach(thread);
}
