#import "Agent.h"
#include <dlfcn.h>

// UI inspection through the public accessibility API. SwiftUI hosting views
// expose their elements as accessibility containers, but SwiftUI builds them
// only while accessibility is on.

BOOL SWPEnableAccessibility(void) {
    static BOOL enabled;
    if (enabled) return NO;
    enabled = YES;
    void (*setEnabled)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    if (!setEnabled) {
        dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        setEnabled = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    }
    if (setEnabled) setEnabled(1);
    else SWP_LOG("_AXSApplicationAccessibilitySetEnabled not found\n");
    return YES;
}

static NSArray<UIWindow *> *visibleWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive)
            for (UIWindow *window in ((UIWindowScene *)scene).windows)
                if (!window.hidden && window.alpha > 0) [windows addObject:window];
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return [@(a.windowLevel) compare:@(b.windowLevel)];
    }];
    return windows;
}

static NSArray *accessibilityChildren(id node) {
    NSArray *children = [node accessibilityElements];
    if (children.count) return children;
    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0) {
        NSMutableArray *list = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            id child = [node accessibilityElementAtIndex:i];
            if (child) [list addObject:child];
        }
        return list;
    }
    return [node isKindOfClass:UIView.class] ? ((UIView *)node).subviews : @[];
}

// An element with no place on screen has the frame CGRectNull, whose origin is
// infinite, and JSON has no such number.
static BOOL hasFrame(id element) {
    CGRect frame = [element accessibilityFrame];
    return isfinite(frame.origin.x) && isfinite(frame.origin.y);
}

static void collectElements(id node, NSMutableArray *elements, int depth) {
    if (depth > 80) return;
    if ([node isKindOfClass:UIView.class] && ((UIView *)node).hidden) return;
    if ([node isAccessibilityElement] && hasFrame(node)) [elements addObject:node];
    for (id child in accessibilityChildren(node)) collectElements(child, elements, depth + 1);
}

static NSArray *visibleElements(void) {
    NSMutableArray *elements = [NSMutableArray array];
    for (UIWindow *window in visibleWindows()) collectElements(window, elements, 0);
    return elements;
}

static NSDictionary *describe(id element) {
    UIAccessibilityTraits traits = [element accessibilityTraits];
    NSMutableArray *names = [NSMutableArray array];
    if (traits & UIAccessibilityTraitButton) [names addObject:@"button"];
    if (traits & UIAccessibilityTraitLink) [names addObject:@"link"];
    if (traits & UIAccessibilityTraitHeader) [names addObject:@"header"];
    if (traits & UIAccessibilityTraitSelected) [names addObject:@"selected"];
    if (traits & UIAccessibilityTraitStaticText) [names addObject:@"text"];
    if (traits & UIAccessibilityTraitImage) [names addObject:@"image"];
    if (traits & UIAccessibilityTraitAdjustable) [names addObject:@"adjustable"];
    if (traits & UIAccessibilityTraitNotEnabled) [names addObject:@"disabled"];
    CGRect frame = [element accessibilityFrame];
    return @{
        @"label" : [element accessibilityLabel] ?: @"",
        @"value" : [element accessibilityValue] ?: @"",
        @"identifier" : [element respondsToSelector:@selector(accessibilityIdentifier)]
            ? ([element accessibilityIdentifier] ?: @"") : @"",
        @"traits" : names,
        @"frame" : @[ @(round(frame.origin.x)), @(round(frame.origin.y)),
                      @(round(frame.size.width)), @(round(frame.size.height)) ],
    };
}

NSDictionary *SWPDescribeUI(void) {
    NSMutableArray *list = [NSMutableArray array];
    for (id element in visibleElements()) [list addObject:describe(element)];
    // Tree order can lag behind the screen, so sort top to bottom, left to right.
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSArray *fa = a[@"frame"], *fb = b[@"frame"];
        NSComparisonResult byY = [fa[1] compare:fb[1]];
        return byY != NSOrderedSame ? byY : [fa[0] compare:fb[0]];
    }];
    return @{@"ok" : @YES, @"elements" : list};
}

// Activates the element whose label or identifier equals `query`, else the
// first element whose label contains it.
// The view under an accessibility element: UIKit describes a table cell with a proxy
// element, which is not the cell, so the window is hit-tested at the element's center.
static UIView *viewUnder(id element) {
    if ([element isKindOfClass:UIView.class]) return element;
    CGRect frame = [element accessibilityFrame];
    CGPoint center = CGPointMake(frame.origin.x + frame.size.width / 2, frame.origin.y + frame.size.height / 2);
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows.reverseObjectEnumerator) {
            if (window.hidden) continue;
            CGPoint point = [window convertPoint:center fromCoordinateSpace:window.screen.coordinateSpace];
            UIView *hit = [window hitTest:point withEvent:nil];
            if (hit) return hit;
        }
    }
    return nil;
}

// A table or collection view cell does not activate: UIKit selects its row through the
// table, as a person's tap does.
static BOOL selectCell(id element) {
    for (UIView *view = viewUnder(element); view; view = view.superview) {
        UIView *list = view.superview;
        while (list && ![list isKindOfClass:UITableView.class] && ![list isKindOfClass:UICollectionView.class])
            list = list.superview;
        if ([view isKindOfClass:UITableViewCell.class] && [list isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)list;
            NSIndexPath *path = [table indexPathForCell:(UITableViewCell *)view];
            id<UITableViewDelegate> delegate = table.delegate;
            if (path && [delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)])
                path = [delegate tableView:table willSelectRowAtIndexPath:path];
            if (!path) return NO;
            [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
            if ([delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
                [delegate tableView:table didSelectRowAtIndexPath:path];
            return YES;
        }
        if ([view isKindOfClass:UICollectionViewCell.class] && [list isKindOfClass:UICollectionView.class]) {
            UICollectionView *collection = (UICollectionView *)list;
            NSIndexPath *path = [collection indexPathForCell:(UICollectionViewCell *)view];
            id<UICollectionViewDelegate> delegate = collection.delegate;
            if (!path || ([delegate respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)] &&
                          ![delegate collectionView:collection shouldSelectItemAtIndexPath:path]))
                return NO;
            [collection selectItemAtIndexPath:path animated:NO scrollPosition:UICollectionViewScrollPositionNone];
            if ([delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)])
                [delegate collectionView:collection didSelectItemAtIndexPath:path];
            return YES;
        }
    }
    return NO;
}

// A control that does not activate for accessibility, such as a navigation bar's back
// button, gets the events a finger's tap would send.
static BOOL sendTap(id element) {
    for (UIView *view = viewUnder(element); view; view = view.superview) {
        if (![view isKindOfClass:UIControl.class]) continue;
        UIControl *control = (UIControl *)view;
        if (!control.enabled) return NO;
        BOOL primary = (control.allControlEvents & UIControlEventPrimaryActionTriggered) != 0;
        [control sendActionsForControlEvents:primary ? UIControlEventPrimaryActionTriggered : UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}

NSDictionary *SWPTap(NSString *query) {
    NSArray *elements = visibleElements();
    id target = nil;
    for (id element in elements) {
        NSString *identifier = [element respondsToSelector:@selector(accessibilityIdentifier)]
            ? [element accessibilityIdentifier] : nil;
        if ([[element accessibilityLabel] isEqualToString:query] || [identifier isEqualToString:query]) {
            target = element;
            break;
        }
    }
    if (!target)
        for (id element in elements)
            if ([[element accessibilityLabel] containsString:query]) {
                target = element;
                break;
            }
    if (!target) return @{@"ok" : @NO, @"error" : @"no visible element with that label or identifier"};
    BOOL activated = [target accessibilityActivate] || selectCell(target) || sendTap(target);
    return @{@"ok" : @(activated), @"element" : describe(target)};
}

// Renders the app's windows into a PNG. afterScreenUpdates:YES applies pending
// changes first, so callers need no delay after a refresh.
NSDictionary *SWPSnapshot(NSString *path, CGFloat scale) {
    double start = SWPNowMs();
    NSArray<UIWindow *> *windows = visibleWindows();
    if (!windows.count) {  // device: say why; on a phone the screen can go dark under the app
        NSMutableArray *states = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            [states addObject:@(scene.activationState)];
        return @{@"ok" : @NO, @"error" : @"no visible window", @"sceneStates" : states,
                 @"applicationState" : @(UIApplication.sharedApplication.applicationState)};
    }
    CGRect bounds = windows.firstObject.screen.bounds;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:bounds format:format];
    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.systemBackgroundColor setFill];
        [context fillRect:bounds];
        for (UIWindow *window in windows)
            [window drawViewHierarchyInRect:window.frame afterScreenUpdates:YES];
    }];
    NSArray *size = @[ @(bounds.size.width * scale), @(bounds.size.height * scale) ];
    if (!path)  // device: no path, so the PNG goes back in the reply
        return @{@"ok" : @YES, @"png" : [png base64EncodedStringWithOptions:0], @"ms" : @(SWPNowMs() - start),
                 @"size" : size};
    if (![png writeToFile:path atomically:YES]) return @{@"ok" : @NO, @"error" : @"cannot write the PNG file"};
    return @{@"ok" : @YES, @"path" : path, @"ms" : @(SWPNowMs() - start), @"size" : size};
}
