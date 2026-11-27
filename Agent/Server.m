#import "Agent.h"
#include <arpa/inet.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>

// Wire protocol: one command per line on 127.0.0.1:$SWAPIFY_PORT, one JSON
// object per line back. See docs/protocol.md. On a device the agent listens on
// every interface, and each connection must first send `auth $SWAPIFY_TOKEN`.

double SWPNowMs(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1e3 + now.tv_nsec / 1e6;
}

static NSString *json(NSDictionary *object) {
    // dataWithJSONObject: raises on an object that is not valid JSON instead of returning nil.
    NSData *data = [NSJSONSerialization isValidJSONObject:object]
        ? [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] : nil;
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
            @"swiftUIRefresh" : @((BOOL)(!SWPSwiftUILoaded() || SWPSwiftUIRefreshAvailable())),
            @"device" : @((BOOL)!TARGET_OS_SIMULATOR), @"traced" : @(traced()),  // device: no debugger check
        };
    if ([line hasPrefix:@"load "]) return SWPPatcherLoad([line substringFromIndex:5], nil);
    if ([line hasPrefix:@"load-side "]) {  // load-side <$s…Mn,…> <path>: the path may contain spaces
        NSString *rest = [line substringFromIndex:10];
        NSRange space = [rest rangeOfString:@" "];
        if (space.location == NSNotFound) return @{@"ok" : @NO, @"error" : @"usage: load-side <types> <path>"};
        NSArray *types = [[rest substringToIndex:space.location] componentsSeparatedByString:@","];
        return SWPPatcherLoad([rest substringFromIndex:space.location + 1], [NSSet setWithArray:types]);
    }
    if ([line isEqualToString:@"refresh"])
        return onMain(^{
            NSMutableDictionary *reply = [SWPSwiftUIRefresh() mutableCopy];
            NSDictionary *uikit = SWPUIKitRefresh();
            reply[@"uikit"] = uikit;
            reply[@"ms"] = @([reply[@"ms"] doubleValue] + [uikit[@"ms"] doubleValue]);
            return reply;
        });
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

#if !TARGET_OS_SIMULATOR
// device: SWAPIFY_TOKEN from the launch. Without it a device agent does not listen.
static char *token;

// The first line, read byte by byte so nothing after it is consumed, within 2 s in
// total. A client that sends nothing, or sends slowly, cannot hold the accept loop.
static BOOL readFirstLine(int fd, char *line, size_t size) {
    double deadline = SWPNowMs() + 2000;
    size_t length = 0;
    while (length + 1 < size) {
        int left = (int)(deadline - SWPNowMs());
        struct pollfd ready = {.fd = fd, .events = POLLIN};
        char byte;
        if (left <= 0 || poll(&ready, 1, left) != 1 || read(fd, &byte, 1) != 1) return NO;
        if (byte == '\n') break;
        line[length++] = byte;
    }
    line[length] = 0;
    return YES;
}

// Compares in time that depends only on the expected token's length.
static BOOL isToken(const char *given) {
    size_t length = strcspn(given, "\r"), expected = strlen(token);
    unsigned char difference = length != expected;
    for (size_t i = 0; i < expected; i++)
        difference |= (unsigned char)(i < length ? given[i] : 0) ^ (unsigned char)token[i];
    return difference == 0;
}

// device: a connection must start with `auth <token>`.
static BOOL authorize(int client) {
    char line[256];
    BOOL ok = readFirstLine(client, line, sizeof line) && strncmp(line, "auth ", 5) == 0 && isToken(line + 5);
    const char *reply = ok ? "{\"ok\":true}\n" : "{\"ok\":false,\"error\":\"not authorized\"}\n";
    write(client, reply, strlen(reply));
    if (!ok) SWP_LOG("refused a connection without the session token\n");
    return ok;
}
#endif

static void serve(int client) {
#if !TARGET_OS_SIMULATOR
    if (!authorize(client)) {
        close(client);
        return;
    }
#endif
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
    const char *portValue = getenv("SWAPIFY_PORT");
    int port = portValue ? atoi(portValue) : 0;
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
    const char *value = getenv("SWAPIFY_TOKEN");
    if (!value || !*value) {
        SWP_LOG("no SWAPIFY_TOKEN, so not listening\n");
        return NULL;
    }
    token = strdup(value);
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
#if !TARGET_OS_SIMULATOR
    // device: keep the screen on while the swapify-launched app runs. A dark screen
    // suspends the app, so reloads would fail after the Auto-Lock delay. Locking the
    // phone by hand still works.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        UIApplication.sharedApplication.idleTimerDisabled = YES;
    }];
#endif
}
