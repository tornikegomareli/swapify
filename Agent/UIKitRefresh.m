#import "Agent.h"
#import <objc/message.h>
#import <objc/runtime.h>

// UIKit keeps nothing that could be evaluated again: a screen is what its view
// controller's loadView and viewDidLoad built, with the code of that moment. So after a
// reload, every view controller that the patch touches builds its view again:
//
//   - On screen, in place: the view is unloaded and loaded again through the view
//     controller's own loadView (a nib or storyboard too) and viewDidLoad. The new view
//     takes the old one's place, frame and the constraints that pinned it, and
//     viewWillAppear and viewDidAppear run again.
//   - Loaded but off screen, deeper in a navigation stack or another tab: the view is
//     unloaded, and UIKit loads it with the new code when it shows it again.
//   - In a push, pop or presentation: rebuilt when the transition completes.
//
// A view controller is touched when its class or a superclass is in the patch, or when
// a view in its tree is. The view controller object stays, so its properties, its place
// in the navigation stack and the app's data are kept. A class that implements
// `@objc func injected()` gets that call instead, as with InjectionIII. Views of patched
// classes get setNeedsLayout and setNeedsDisplay, and table and collection views whose
// data source or delegate is patched reload their data. See docs/architecture.md.

static NSSet<NSString *> *patched;  // class_getName of each class the last patch touched

void SWPUIKitSetPatchedClasses(NSSet<NSString *> *names) { patched = names; }

static BOOL touched(Class c) {
    for (; c; c = class_getSuperclass(c))
        if ([patched containsObject:@(class_getName(c))]) return YES;
    return NO;
}

// System containers own their children's views; rebuilding one would lose its stack.
static BOOL isContainer(UIViewController *vc) {
    return [vc isKindOfClass:UINavigationController.class] || [vc isKindOfClass:UITabBarController.class] ||
           [vc isKindOfClass:UISplitViewController.class] || [vc isKindOfClass:UIPageViewController.class];
}

static BOOL callInjected(id object) {
    SEL injected = NSSelectorFromString(@"injected");
    if (![object respondsToSelector:injected]) return NO;
    ((void (*)(id, SEL))objc_msgSend)(object, injected);
    return YES;
}

static void collectControllers(UIViewController *vc, NSMutableOrderedSet *controllers) {
    if (!vc || [controllers containsObject:vc]) return;
    [controllers addObject:vc];
    for (UIViewController *child in vc.childViewControllers) collectControllers(child, controllers);
    collectControllers(vc.presentedViewController, controllers);
}

static NSArray<UIWindow *> *windows(void) {
    NSMutableArray *result = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) [result addObjectsFromArray:((UIWindowScene *)scene).windows];
    return result;
}

static UIViewController *owner(UIView *view) {
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder)
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    return nil;
}

static void walkViews(UIView *view, void (^visit)(UIView *)) {
    visit(view);
    for (UIView *subview in view.subviews) walkViews(subview, visit);
}

// A constraint the app made, which pins the view. UIKit makes its own for autoresizing and
// for a container's layout (`UIView-Encapsulated-Layout-…`); those come back by themselves.
static BOOL pinsView(NSLayoutConstraint *c, UIView *view) {
    if (c.class != NSLayoutConstraint.class || [c.identifier hasPrefix:@"UIView-Encapsulated-Layout"] ||
        [c.identifier hasPrefix:@"_UI"])
        return NO;
    for (id item in @[ c.firstItem ?: NSNull.null, c.secondItem ?: NSNull.null ])
        if ([item isKindOfClass:UILayoutGuide.class] && ((UILayoutGuide *)item).owningView == view) return NO;
    return c.firstItem == view || c.secondItem == view;
}

// Child view controllers whose views leave with `vc`'s view. viewDidLoad adds them again.
static void releaseChildren(UIViewController *vc) {
    for (UIViewController *child in [vc.childViewControllers copy])
        if ([child.viewIfLoaded isDescendantOfView:vc.viewIfLoaded]) {
            [child willMoveToParentViewController:nil];
            [child removeFromParentViewController];
        }
}

// Builds `vc`'s view again in place. Returns NO if the view has no place to go back to.
static BOOL rebuild(UIViewController *vc) {
    UIView *old = vc.viewIfLoaded, *parent = old.superview;
    if (!old || !parent) return NO;
    NSUInteger index = [parent.subviews indexOfObject:old];
    // Constraints outside the view that pin it, and its own size constraints.
    NSMutableArray<NSLayoutConstraint *> *pins = [NSMutableArray array];
    for (UIView *v = parent; v; v = v.superview)
        for (NSLayoutConstraint *c in v.constraints)
            if (pinsView(c, old)) [pins addObject:c];
    for (NSLayoutConstraint *c in old.constraints)
        if (c.secondItem == nil && pinsView(c, old)) [pins addObject:c];
    releaseChildren(vc);
    CGRect frame = old.frame;
    UIViewAutoresizing mask = old.autoresizingMask;
    BOOL autoresizing = old.translatesAutoresizingMaskIntoConstraints;

    vc.view = nil;
    [vc loadViewIfNeeded];
    UIView *fresh = vc.view;
    fresh.translatesAutoresizingMaskIntoConstraints = autoresizing;
    fresh.autoresizingMask = mask;
    fresh.frame = frame;
    [parent insertSubview:fresh atIndex:MIN(index, parent.subviews.count)];
    [old removeFromSuperview];
    for (NSLayoutConstraint *c in pins) {
        id first = c.firstItem == old ? fresh : c.firstItem, second = c.secondItem == old ? fresh : c.secondItem;
        @try {
            NSLayoutConstraint *copy = [NSLayoutConstraint constraintWithItem:first attribute:c.firstAttribute
                                                                    relatedBy:c.relation toItem:second
                                                                    attribute:c.secondAttribute
                                                                   multiplier:c.multiplier constant:c.constant];
            copy.priority = c.priority;
            copy.identifier = c.identifier;
            copy.active = YES;
        } @catch (NSException *exception) {
            SWP_LOG("could not pin a rebuilt view again: %s\n", exception.reason.UTF8String);
        }
    }
    [vc viewWillAppear:NO];
    [fresh layoutIfNeeded];
    [vc viewDidAppear:NO];
    return YES;
}

NSDictionary *SWPUIKitRefresh(void) {
    double start = SWPNowMs();
    __block int rebuilt = 0, unloaded = 0, deferred = 0, injected = 0, redrawn = 0, reloaded = 0;
    if (patched.count == 0) return @{@"ok" : @YES, @"rebuilt" : @0, @"ms" : @(SWPNowMs() - start)};

    NSMutableOrderedSet<UIViewController *> *controllers = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in windows()) collectControllers(window.rootViewController, controllers);

    // Touched view controllers: by class, or by a patched view on screen, owned by them.
    NSMutableOrderedSet<UIViewController *> *targets = [NSMutableOrderedSet orderedSet];
    for (UIViewController *vc in controllers)
        if (touched(object_getClass(vc))) [targets addObject:vc];
    for (UIWindow *window in windows())
        walkViews(window, ^(UIView *view) {
            if (!touched(object_getClass(view))) return;
            if (callInjected(view)) injected++;
            UIViewController *vc = owner(view);
            if (vc) [targets addObject:vc];
        });

    for (UIViewController *vc in targets) {
        if (isContainer(vc)) continue;
        BOOL inside = NO;  // a touched parent builds its children again
        for (UIViewController *p = vc.parentViewController; p && !inside; p = p.parentViewController)
            inside = [targets containsObject:p] && !isContainer(p);
        if (inside) continue;
        if (callInjected(vc)) {
            injected++;
        } else if (vc.transitionCoordinator) {
            // Mid push, pop or presentation the view is between places: rebuild it once there.
            [vc.transitionCoordinator animateAlongsideTransition:nil completion:^(id context) {
                if (vc.viewIfLoaded.window) rebuild(vc);
            }];
            deferred++;
        } else if (vc.viewIfLoaded.window) {
            if (rebuild(vc)) rebuilt++;
        } else if (vc.isViewLoaded && !vc.view.superview) {
            releaseChildren(vc);
            vc.view = nil;  // UIKit loads it with the new code when it shows it again
            unloaded++;
        }
    }

    // Views of patched classes lay out and draw again, and patched data sources reload.
    for (UIWindow *window in windows())
        walkViews(window, ^(UIView *view) {
            if (touched(object_getClass(view))) {
                [view setNeedsLayout];
                [view setNeedsDisplay];
                redrawn++;
            }
            id source = nil, delegate = nil;
            if ([view isKindOfClass:UITableView.class]) source = ((UITableView *)view).dataSource, delegate = ((UITableView *)view).delegate;
            if ([view isKindOfClass:UICollectionView.class]) source = ((UICollectionView *)view).dataSource, delegate = ((UICollectionView *)view).delegate;
            if ((source && touched(object_getClass(source))) || (delegate && touched(object_getClass(delegate)))) {
                [(id)view reloadData];
                reloaded++;
            }
        });
    return @{@"ok" : @YES, @"rebuilt" : @(rebuilt), @"unloaded" : @(unloaded), @"deferred" : @(deferred), @"injected" : @(injected),
             @"redrawn" : @(redrawn), @"reloadedData" : @(reloaded), @"ms" : @(SWPNowMs() - start)};
}
