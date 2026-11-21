#import "Agent.h"
#include <dlfcn.h>
#include <objc/runtime.h>

// SwiftUI does not know that a body was replaced. This repeats what
// SwiftUI.AppPreviewHost.invalidateEverything() does for previews, for every
// _UIHostingView in the app, but skips GraphHost.incrementPhase(): a new view
// phase resets all @State. Every symbol used here is exported from SwiftUI,
// SwiftUICore or AttributeGraph; the names were taken from the iOS 27.2
// simulator runtime.

#define SWIFTCALL __attribute__((swiftcall))
#define SWIFTSELF __attribute__((swift_context))  // lowers to LLVM swiftself (x20)
typedef void *(*SelfGetter)(void *self SWIFTSELF) SWIFTCALL;
typedef void (*SelfMethod)(void *self SWIFTSELF) SWIFTCALL;
typedef uint32_t (*EmptyTransaction)(void *transaction, void *self SWIFTSELF) SWIFTCALL;

static struct {
    SelfGetter hostingViewGraph;       // _UIHostingView.viewGraph.getter, returns +1
    SelfGetter graph;                  // GraphHost.graph.getter -> AGGraphRef
    EmptyTransaction emptyTransaction; // GraphHost.emptyTransaction(_:)
    SelfMethod flushTransactions;      // GraphHost.flushTransactions()
    void (*invalidateAllValues)(void *graph);
    void (*invalidateLazyContainers)(void);  // DebugReplaceableView.invalidateEverything()
    void (*release)(void *);
} API;

BOOL SWPSwiftUIRefreshAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        API.hostingViewGraph = dlsym(RTLD_DEFAULT, "$s7SwiftUI14_UIHostingViewC9viewGraphAA0dF0Cvg");
        API.graph = dlsym(RTLD_DEFAULT, "$s7SwiftUI9GraphHostC5graphSo10AGGraphRefavg");
        API.emptyTransaction = dlsym(RTLD_DEFAULT, "$s7SwiftUI9GraphHostC16emptyTransactionys6UInt32VAA0F0VF");
        API.flushTransactions = dlsym(RTLD_DEFAULT, "$s7SwiftUI9GraphHostC17flushTransactionsyyF");
        API.invalidateAllValues = dlsym(RTLD_DEFAULT, "AGGraphInvalidateAllValues");
        API.invalidateLazyContainers = dlsym(RTLD_DEFAULT, "$s7SwiftUI20DebugReplaceableViewV20invalidateEverythingyyFZ");
        API.release = dlsym(RTLD_DEFAULT, "swift_release");
    });
    return API.hostingViewGraph && API.graph && API.emptyTransaction && API.flushTransactions &&
           API.invalidateAllValues && API.invalidateLazyContainers && API.release;
}

static void collectHostingViews(UIView *view, NSMutableArray *hosts) {
    for (Class c = object_getClass(view); c; c = class_getSuperclass(c))
        if (strstr(class_getName(c), "_UIHostingView")) {
            [hosts addObject:view];
            break;
        }
    for (UIView *subview in view.subviews) collectHostingViews(subview, hosts);
}

NSDictionary *SWPSwiftUIRefresh(void) {
    if (!SWPSwiftUIRefreshAvailable())
        return @{@"ok" : @NO, @"error" : @"SwiftUI refresh symbols not found in this iOS version"};
    double start = SWPNowMs();
    NSMutableArray *hosts = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *window in ((UIWindowScene *)scene).windows) collectHostingViews(window, hosts);

    API.invalidateLazyContainers();
    for (UIView *view in hosts) {
        void *viewGraph = API.hostingViewGraph((__bridge void *)view);
        API.invalidateAllValues(API.graph(viewGraph));
        API.emptyTransaction(NULL, viewGraph);
        API.flushTransactions(viewGraph);
        API.release(viewGraph);
    }
    return @{@"ok" : @YES, @"hosts" : @(hosts.count), @"ms" : @(SWPNowMs() - start)};
}
