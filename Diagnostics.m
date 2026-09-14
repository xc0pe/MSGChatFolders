#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>

// D2: observations only. No private getters, model writes, list mutations or networking.
static NSString * const Build = @"D2-20260914";
static NSMutableDictionary *Report;
static NSObject *ReportLock;
static NSMutableSet *InspectedClasses;
static NSMutableSet *InstalledHooks;
static NSMutableArray *HookChecks;
static UIButton *ProbeButton;
static BOOL Enabled;
static NSUInteger RowBatchesObserved;
static NSUInteger ScanCount;
static const NSUInteger MaxClasses = 80;

static NSString *ClassName(id obj) {
    return obj ? NSStringFromClass(object_getClass(obj)) : @"nil";
}

static NSString *ImageForIMP(IMP imp) {
    Dl_info info = {0};
    if (imp && dladdr((const void *)imp, &info) && info.dli_fname)
        return [@(info.dli_fname) lastPathComponent];
    return @"unknown";
}

static void Status(NSString *key, NSString *status) {
    @synchronized (ReportLock) { Report[@"hooks"][key] = status; }
}

static void Count(NSString *key) {
    @synchronized (ReportLock) {
        NSMutableDictionary *counts = Report[@"calls"];
        counts[key] = @([counts[key] unsignedLongLongValue] + 1);
    }
}

static void DescribeClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    @synchronized (ReportLock) {
        if ([InspectedClasses containsObject:name] || InspectedClasses.count >= MaxClasses) return;
        [InspectedClasses addObject:name];
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"superclass"] = class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"none";
        NSMutableArray *methods = [NSMutableArray array];
        unsigned int count = 0;
        Method *list = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < MIN(count, 240u); i++) {
            const char *encoding = method_getTypeEncoding(list[i]);
            [methods addObject:@{@"selector": NSStringFromSelector(method_getName(list[i])),
                                 @"encoding": encoding ? @(encoding) : @"unknown",
                                 @"implementation_image": ImageForIMP(method_getImplementation(list[i]))}];
        }
        free(list);
        entry[@"methods"] = methods;
        entry[@"methods_truncated"] = @(count > 240);
        NSMutableArray *ivars = [NSMutableArray array];
        Ivar *fields = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < MIN(count, 160u); i++) {
            const char *n = ivar_getName(fields[i]), *t = ivar_getTypeEncoding(fields[i]);
            [ivars addObject:@{@"name": n ? @(n) : @"unknown", @"type": t ? @(t) : @"unknown"}];
        }
        free(fields);
        entry[@"ivars_metadata_only"] = ivars;
        Report[@"classes"][name] = entry;
        Class parent = class_getSuperclass(cls);
        if (parent && parent != NSObject.class && parent != NSProxy.class) DescribeClass(parent);
    }
}

static void ObserveRows(id rows) {
    // Sample later updates too: D1 stopped at the first startup-only batch.
    if (RowBatchesObserved >= 256) return;
    RowBatchesObserved++;
    if (![rows isKindOfClass:[NSArray class]]) {
        @synchronized (ReportLock) { Report[@"row_argument_class"] = ClassName(rows); }
        DescribeClass(object_getClass(rows));
        return;
    }
    NSArray *items = rows;
    NSMutableSet *names = [NSMutableSet set];
    // No element getters or values are read. Class metadata only.
    for (NSUInteger i = 0; i < MIN(items.count, 128u); i++) {
        id item = items[i];
        [names addObject:ClassName(item)];
        DescribeClass(object_getClass(item));
    }
    @synchronized (ReportLock) {
        NSDictionary *batch = @{@"count": @(items.count), @"sample_classes": [[names allObjects] sortedArrayUsingSelector:@selector(compare:)], @"sampled_items": @(MIN(items.count, 128u))};
        Report[@"last_row_batch"] = batch;
        Report[@"row_batches_observed"] = @(RowBatchesObserved);
        Report[@"max_row_count"] = @(MAX([Report[@"max_row_count"] unsignedIntegerValue], items.count));
        NSMutableArray *history = Report[@"row_batch_history"];
        if (![history.lastObject isEqual:batch]) {
            if (history.count >= 20) [history removeObjectAtIndex:0];
            [history addObject:batch];
        }
    }
}

static BOOL Matches(Method method, char returnType, const char *arguments) {
    if (!method || method_getNumberOfArguments(method) != strlen(arguments) + 2) return NO;
    char type[256] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != returnType) return NO;
    for (NSUInteger i = 0; i < strlen(arguments); i++) {
        method_getArgumentType(method, (unsigned int)i + 2, type, sizeof(type));
        if (arguments[i] == 'B') {
            if (strcmp(type, @encode(BOOL)) != 0) return NO;
        } else if (type[0] != arguments[i]) return NO;
    }
    return YES;
}

static void Replace(Class cls, SEL selector, Method method, IMP replacement, NSString *key) {
    const char *types = method_getTypeEncoding(method);
    // An inherited method receives a local override; never modify its superclass.
    if (!class_addMethod(cls, selector, replacement, types)) {
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    }
    [InstalledHooks addObject:key];
    [HookChecks addObject:@{@"class": NSStringFromClass(cls), @"selector": NSStringFromSelector(selector),
                           @"imp": [NSValue valueWithPointer:(const void *)replacement], @"key": key}];
    Status(key, @"installed");
}

static void InstallVoid(Class cls, NSString *selectorName, BOOL takesBool) {
    if (!cls) return;
    SEL sel = NSSelectorFromString(selectorName);
    NSString *key = [NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), selectorName];
    if ([InstalledHooks containsObject:key]) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!Matches(method, 'v', takesBool ? "B" : "")) { Status(key, @"missing or signature mismatch; skipped"); return; }
    IMP original = method_getImplementation(method);
    @synchronized (ReportLock) { Report[@"original_implementation_images"][key] = ImageForIMP(original); }
    IMP replacement;
    if (takesBool) {
        replacement = imp_implementationWithBlock(^(id receiver, BOOL animated) {
            Count(key);
            ((void (*)(id, SEL, BOOL))original)(receiver, sel, animated);
        });
    } else {
        replacement = imp_implementationWithBlock(^(id receiver) {
            Count(key);
            ((void (*)(id, SEL))original)(receiver, sel);
        });
    }
    Replace(cls, sel, method, replacement, key);
}

static void InstallRows(Class cls) {
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"postProcessInboxRows:withConnection:fetchThreadRanges:dataUpdateBlock:completion:");
    NSString *key = [NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    if ([InstalledHooks containsObject:key]) return;
    Method method = class_getInstanceMethod(cls, sel);
    // Do not guess if any argument is scalar or this version has a different ABI.
    if (!Matches(method, 'v', "@@@@@")) { Status(key, @"missing or signature mismatch; skipped"); return; }
    IMP original = method_getImplementation(method);
    @synchronized (ReportLock) { Report[@"original_implementation_images"][key] = ImageForIMP(original); }
    IMP replacement = imp_implementationWithBlock(^(id receiver, id rows, id connection, id ranges, id update, id completion) {
        {
            Count(key);
            @synchronized (ReportLock) {
                ObserveRows(rows);
            }
        }
        ((void (*)(id, SEL, id, id, id, id, id))original)(receiver, sel, rows, connection, ranges, update, completion);
    });
    Replace(cls, sel, method, replacement, key);
}

static void InstallRowGetter(Class cls) {
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"inboxRows");
    NSString *key = [NSString stringWithFormat:@"%@.inboxRows", NSStringFromClass(cls)];
    if ([InstalledHooks containsObject:key]) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!Matches(method, '@', "")) { Status(key, @"missing or signature mismatch; skipped"); return; }
    IMP original = method_getImplementation(method);
    @synchronized (ReportLock) { Report[@"original_implementation_images"][key] = ImageForIMP(original); }
    IMP replacement = imp_implementationWithBlock(^id(id receiver) {
        id rows = ((id (*)(id, SEL))original)(receiver, sel);
        Count(key);
        @synchronized (ReportLock) { ObserveRows(rows); }
        return rows;
    });
    Replace(cls, sel, method, replacement, key);
}

static void InstallAdapterProbe(void) {
    Class cls = NSClassFromString(@"MSGInboxRowAdapter");
    if (!cls) return;
    DescribeClass(cls);
    NSString *key = @"MSGInboxRowAdapter.threadKey";
    if ([InstalledHooks containsObject:key]) return;
    SEL sel = NSSelectorFromString(@"threadKey");
    Method method = class_getInstanceMethod(cls, sel);
    if (!Matches(method, 'q', "")) { Status(key, @"missing or signature mismatch; skipped"); return; }
    IMP original = method_getImplementation(method);
    @synchronized (ReportLock) { Report[@"original_implementation_images"][key] = ImageForIMP(original); }
    IMP replacement = imp_implementationWithBlock(^long long(id receiver) {
        Count(key);
        // Return the original value without storing or exporting it.
        return ((long long (*)(id, SEL))original)(receiver, sel);
    });
    Replace(cls, sel, method, replacement, key);
}

static void InstallHooks(void) {
    InstallAdapterProbe();
    for (NSString *name in @[@"MSGThreadListViewController", @"MSGInboxFoldersViewController",
                             @"_TtC15LightSpeedInbox22MSGInboxViewController"]) {
        Class cls = NSClassFromString(name);
        if (!cls) { Status(name, @"class not loaded"); continue; }
        DescribeClass(cls);
        InstallVoid(cls, @"viewDidAppear:", YES);
        if ([name isEqualToString:@"MSGThreadListViewController"]) InstallRowGetter(cls);
    }
    Class source = NSClassFromString(@"MSGThreadListDataSource");
    if (source) {
        DescribeClass(source);
        InstallVoid(source, @"updateData", NO);
        InstallRows(source);
        InstallRowGetter(source);
    } else Status(@"MSGThreadListDataSource", @"class not loaded");
    for (NSString *name in @[@"MSGThreadListProvideContextMenuActionsInput", @"MSGThreadListProvideMoreActionsInput",
                             @"MSGThreadListLoggableRowAction", @"MSGThreadListActionGetAlertActionInput"])
        DescribeClass(NSClassFromString(name));
}

static UIWindow *ActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow && window.rootViewController && window.windowLevel == UIWindowLevelNormal) return window;
    }
    return nil;
}

static UIViewController *Presenter(UIWindow *window) {
    UIViewController *vc = window.rootViewController;
    for (NSUInteger i = 0; vc && i < 20; i++) {
        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
        else if ([vc isKindOfClass:UINavigationController.class]) vc = ((UINavigationController *)vc).visibleViewController;
        else if ([vc isKindOfClass:UITabBarController.class]) vc = ((UITabBarController *)vc).selectedViewController;
        else break;
    }
    return vc;
}

static void ScanUI(UIWindow *window) {
    if (!window || !Enabled) return;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    NSMutableArray *lists = [NSMutableArray array];
    NSMutableSet *controllers = [NSMutableSet set];
    NSUInteger visited = 0;
    for (NSUInteger cursor = 0; cursor < queue.count && visited < 1200; cursor++, visited++) {
        UIView *view = queue[cursor];
        if (view.hidden || view.alpha < 0.01) continue;
        for (UIResponder *r = view.nextResponder; r && ![r isKindOfClass:UIWindow.class]; r = r.nextResponder) {
            if ([r isKindOfClass:UIViewController.class]) { [controllers addObject:ClassName(r)]; break; }
        }
        id delegate = nil, source = nil;
        if ([view isKindOfClass:UITableView.class]) { delegate = ((UITableView *)view).delegate; source = ((UITableView *)view).dataSource; }
        else if ([view isKindOfClass:UICollectionView.class]) { delegate = ((UICollectionView *)view).delegate; source = ((UICollectionView *)view).dataSource; }
        if ((delegate || source) && lists.count < 30) {
            [lists addObject:@{@"view_class": ClassName(view), @"delegate_class": ClassName(delegate), @"data_source_class": ClassName(source)}];
            DescribeClass(object_getClass(delegate));
            DescribeClass(object_getClass(source));
        }
        if (queue.count < 2000) [queue addObjectsFromArray:view.subviews];
    }
    @synchronized (ReportLock) {
        Report[@"ui_scans"] = @(++ScanCount);
        NSMutableArray *samples = Report[@"ui_samples"];
        NSDictionary *sample = @{@"controllers": [[controllers allObjects] sortedArrayUsingSelector:@selector(compare:)], @"lists": lists,
                                  @"truncated": @(visited >= 1200)};
        if (![samples.lastObject isEqual:sample]) {
            if (samples.count >= 12) [samples removeObjectAtIndex:0];
            [samples addObject:sample];
        }
    }
}

static NSString *ReportText(void) {
    @synchronized (ReportLock) {
        NSMutableDictionary *integrity = [NSMutableDictionary dictionary];
        for (NSDictionary *check in HookChecks) {
            Method method = class_getInstanceMethod(NSClassFromString(check[@"class"]), NSSelectorFromString(check[@"selector"]));
            IMP installed = (IMP)[check[@"imp"] pointerValue];
            integrity[check[@"key"]] = method && method_getImplementation(method) == installed
                ? @"probe is current implementation" : @"implementation changed; may be wrapped or replaced";
        }
        Report[@"hook_integrity"] = integrity;
        NSData *data = [NSJSONSerialization dataWithJSONObject:Report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"Unable to serialize diagnostic report.";
    }
}

@interface MCFDReportController : UIViewController
@end
@implementation MCFDReportController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Folders diagnostics · D2";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [[UITextView alloc] initWithFrame:CGRectZero];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    text.text = ReportText();
    [self.view addSubview:text];
    [NSLayoutConstraint activateConstraints:@[[text.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [text.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [text.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [text.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12]]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share)];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)share {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"MSGChatFolders-D2.json"]];
    NSError *error = nil;
    if (![ReportText() writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not create report" message:@"Close this screen and try again." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@interface MCFDLauncher : NSObject
+ (void)show;
@end
@implementation MCFDLauncher
+ (void)show {
    UIWindow *window = ActiveWindow();
    UIViewController *vc = Presenter(window);
    if (!vc || [vc isKindOfClass:MCFDReportController.class]) return;
    ScanUI(window);
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[MCFDReportController new]];
    [vc presentViewController:nav animated:YES completion:nil];
}
@end

static void Tick(void) {
    if (!Enabled || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIWindow *window = ActiveWindow();
    if (!window) return;
    if (!ProbeButton) {
        ProbeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [ProbeButton setTitle:@"Folders · D2" forState:UIControlStateNormal];
        [ProbeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        ProbeButton.backgroundColor = UIColor.systemIndigoColor;
        ProbeButton.layer.cornerRadius = 17;
        ProbeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        ProbeButton.accessibilityLabel = @"Open folder diagnostics. Plugin loaded, build D2.";
        [ProbeButton addTarget:MCFDLauncher.class action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
    }
    if (ProbeButton.superview != window) [window addSubview:ProbeButton];
    ProbeButton.frame = CGRectMake(MAX(8, window.bounds.size.width - window.safeAreaInsets.right - 126),
                                   window.safeAreaInsets.top + 52, 118, 34);
    [window bringSubviewToFront:ProbeButton];
    if (![Presenter(window) isKindOfClass:MCFDReportController.class]) ScanUI(window);
}

__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        ReportLock = [NSObject new];
        InspectedClasses = [NSMutableSet set];
        InstalledHooks = [NSMutableSet set];
        HookChecks = [NSMutableArray array];
        Report = [@{@"build": Build, @"purpose": @"Runtime metadata only; no folder filtering enabled",
                    @"privacy": @"No chat text, titles, account/thread identifiers, ivar values, or object descriptions collected",
                    @"hooks": [NSMutableDictionary dictionary], @"calls": [NSMutableDictionary dictionary],
                    @"classes": [NSMutableDictionary dictionary], @"ui_samples": [NSMutableArray array],
                    @"row_batch_history": [NSMutableArray array],
                    @"original_implementation_images": [NSMutableDictionary dictionary]} mutableCopy];
        NSLog(@"[MSGChatFoldersDiagnostics] %@ constructor reached", Build);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
            Report[@"messenger_version"] = version;
            Report[@"ios_version"] = UIDevice.currentDevice.systemVersion;
            NSMutableArray *addons = [NSMutableArray array];
            for (uint32_t i = 0; i < _dyld_image_count(); i++) {
                const char *path = _dyld_get_image_name(i);
                if (!path) continue;
                NSString *image = [@(path) lastPathComponent];
                if ([image isEqualToString:@"MSGPlusX.dylib"] || [image isEqualToString:@"MSGChatFolders.dylib"] ||
                    [image isEqualToString:@"CydiaSubstrate"] || [image isEqualToString:@"MSGChatFoldersDiagnostics.dylib"])
                    [addons addObject:image];
            }
            Report[@"loaded_relevant_images"] = addons;
            Enabled = [version isEqualToString:@"571.0.0"];
            // UI can still explain a version mismatch without installing hooks.
            if (Enabled) InstallHooks();
            else Status(@"version_guard", @"Unsupported app version; hooks skipped");
            Enabled = YES;
            Tick();
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([version isEqualToString:@"571.0.0"]) InstallHooks();
                Tick();
            }];
            [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) { Tick(); }];
            // Retry once for delayed class registration; the constructor remains independent of hooks.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if ([version isEqualToString:@"571.0.0"]) InstallHooks();
            });
        });
    }
}
