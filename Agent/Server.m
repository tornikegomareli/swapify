#import "Agent.h"
#include <arpa/inet.h>
#include <pthread.h>
#include <sys/socket.h>
#include <time.h>

// Wire protocol: one command per line on 127.0.0.1:$SWAPIFY_PORT, one JSON
// object per line back. See docs/protocol.md.

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
        };
    if ([line hasPrefix:@"load "]) return SWPPatcherLoad([line substringFromIndex:5]);
    if ([line isEqualToString:@"refresh"]) return onMain(^{ return SWPSwiftUIRefresh(); });
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
            NSString *reply = json(handle(@(line)));
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
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(port)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (port <= 0 || bind(fd, (void *)&address, sizeof address) || listen(fd, 4)) {
        SWP_LOG("cannot listen on port %d (set SWAPIFY_PORT)\n", port);
        return NULL;
    }
    SWP_LOG("listening on 127.0.0.1:%d\n", port);
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
