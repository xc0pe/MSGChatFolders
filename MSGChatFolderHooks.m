//
//  MSGChatFolderHooks.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Runtime method swizzling hooks for Messenger.
//  Injects the folder tab bar into the inbox.
//  The 📂 button reads visible cells and shows a conversation picker.
//
//  Uses objc/runtime.h directly (no Theos/Logos dependency).
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import "MSGChatFolderManager.h"
#import "MSGChatFolderTabView.h"

// ═══════════════════════════════════════════════════════════
// MARK: - Logging
// ═══════════════════════════════════════════════════════════

#define CFLOG(fmt, ...) NSLog(@"[MSGChatFolders] " fmt, ##__VA_ARGS__)

// ═══════════════════════════════════════════════════════════
// MARK: - Associated Object Keys
// ═══════════════════════════════════════════════════════════

static const void *kFolderTabViewKey     = &kFolderTabViewKey;
static const void *kFolderInitializedKey = &kFolderInitializedKey;
static const void *kCollectionViewRefKey = &kCollectionViewRefKey;

// ═══════════════════════════════════════════════════════════
// MARK: - Forward Declarations
// ═══════════════════════════════════════════════════════════

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note);
static NSString *extractThreadKeyFromCell(UIView *cell);
static NSString *extractDisplayNameFromCell(UIView *cell);
static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey);
static UIViewController *findTopViewController(void);

// ═══════════════════════════════════════════════════════════
// MARK: - Original Method Pointers (IMPs)
// ═══════════════════════════════════════════════════════════

static void (*orig_inboxViewDidAppear)(id self, SEL _cmd, BOOL animated);

// ═══════════════════════════════════════════════════════════
// MARK: - Top View Controller Utility
// ═══════════════════════════════════════════════════════════

static UIViewController *findTopViewController(void) {
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Display Name Extraction
// ═══════════════════════════════════════════════════════════

/// Tries to get a human-readable name from a conversation cell.
/// Uses accessibilityLabel first (most reliable), then searches for UILabels.
static NSString *extractDisplayNameFromCell(UIView *cell) {
    if (!cell) return nil;

    // Strategy 1: accessibilityLabel — apps MUST set this for accessibility
    NSString *accLabel = cell.accessibilityLabel;
    if (accLabel.length > 0) {
        // Trim to first line or first 50 chars
        NSRange newline = [accLabel rangeOfString:@"\n"];
        if (newline.location != NSNotFound && newline.location > 0) {
            return [accLabel substringToIndex:newline.location];
        }
        if (accLabel.length > 50) {
            return [accLabel substringToIndex:50];
        }
        return accLabel;
    }

    // Strategy 2: Look for the first large UILabel (likely the contact name)
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)v;
            if (label.text.length > 0) {
                [labels addObject:label];
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    // Sort by font size descending — the contact name is usually the largest label
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        return [@(b.font.pointSize) compare:@(a.font.pointSize)];
    }];

    if (labels.count > 0) {
        return labels.firstObject.text;
    }

    // Strategy 3: KVC on common properties
    NSArray *nameKeys = @[@"title", @"name", @"displayName", @"contactName"];
    for (NSString *key in nameKeys) {
        @try {
            id val = [cell valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [val length] > 0) return val;
        } @catch (NSException *e) {}
    }

    return nil;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Thread Key Extraction
// ═══════════════════════════════════════════════════════════

static NSString *extractThreadKeyFromCell(UIView *cell) {
    if (!cell) return nil;

    // Strategy 1: KVC property names
    NSArray *keyNames = @[
        @"threadKey", @"thread_key", @"threadFBID", @"threadId",
        @"conversationKey", @"conversationId", @"identifier",
        @"itemIdentifier", @"uniqueId"
    ];

    for (NSString *key in keyNames) {
        @try {
            id value = [cell valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                CFLOG(@"threadKey via KVC '%@': %@", key, value);
                return value;
            }
            if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
        } @catch (NSException *e) {}
    }

    // Strategy 2: model/viewModel property
    NSArray *modelKeys = @[@"model", @"viewModel", @"data", @"item",
                           @"threadSummary", @"conversation", @"thread"];
    for (NSString *modelKey in modelKeys) {
        @try {
            id model = [cell valueForKey:modelKey];
            if (!model) continue;
            for (NSString *key in keyNames) {
                @try {
                    id value = [model valueForKey:key];
                    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                        CFLOG(@"threadKey via model '%@.%@': %@", modelKey, key, value);
                        return value;
                    }
                } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
    }

    // Strategy 3: Responder chain
    UIResponder *responder = cell;
    for (int d = 0; d < 10 && responder; d++) {
        for (NSString *key in keyNames) {
            @try {
                id value = [(id)responder valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
            } @catch (NSException *e) {}
        }
        responder = [responder nextResponder];
    }

    // Strategy 4: accessibilityIdentifier
    if ([cell isKindOfClass:[UIView class]]) {
        NSString *accId = [(UIView *)cell accessibilityIdentifier];
        if (accId && accId.length > 5) return accId;
    }

    // Strategy 5: Scan ivars for t_ strings
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([cell class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *ivarType = ivar_getTypeEncoding(ivars[i]);
        if (ivarType && ivarType[0] == '@') {
            @try {
                id val = object_getIvar(cell, ivars[i]);
                if ([val isKindOfClass:[NSString class]]) {
                    NSString *str = (NSString *)val;
                    if ([str hasPrefix:@"t_"] || (str.length > 10 && [str longLongValue] > 0)) {
                        free(ivars);
                        return str;
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    if (ivars) free(ivars);

    // Strategy 6: Scan model ivars
    NSArray *modelIvarNames = @[@"_model", @"_viewModel", @"_data", @"_item", @"_thread"];
    Ivar *cellIvars = class_copyIvarList([cell class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(cellIvars[i])];
        for (NSString *modelName in modelIvarNames) {
            if ([ivarName isEqualToString:modelName]) {
                @try {
                    id model = object_getIvar(cell, cellIvars[i]);
                    if (!model) continue;
                    unsigned int mCount = 0;
                    Ivar *mIvars = class_copyIvarList([model class], &mCount);
                    for (unsigned int j = 0; j < mCount; j++) {
                        const char *mType = ivar_getTypeEncoding(mIvars[j]);
                        if (mType && mType[0] == '@') {
                            id mVal = object_getIvar(model, mIvars[j]);
                            if ([mVal isKindOfClass:[NSString class]]) {
                                NSString *mStr = (NSString *)mVal;
                                if ([mStr hasPrefix:@"t_"] || (mStr.length > 10 && [mStr longLongValue] > 0)) {
                                    free(mIvars);
                                    free(cellIvars);
                                    return mStr;
                                }
                            }
                        }
                    }
                    if (mIvars) free(mIvars);
                } @catch (NSException *e) {}
            }
        }
    }
    if (cellIvars) free(cellIvars);

    CFLOG(@"WARNING: no threadKey from cell %@", NSStringFromClass([cell class]));
    return nil;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Folder Action Sheet
// ═══════════════════════════════════════════════════════════

static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey) {
    if (!threadKey || !presenter) return;

    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"📁 Add to Folder"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];

    for (MSGChatFolder *folder in [mgr allFolders]) {
        NSString *title = folder.name;
        if ([folder.folderId isEqualToString:currentFolder.folderId]) {
            title = [NSString stringWithFormat:@"✓ %@", folder.name];
        }
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *a) {
            if ([folder.folderId isEqualToString:currentFolder.folderId]) {
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
        }];
        [alert addAction:action];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:@"➕ Create New Folder"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIAlertController *nameAlert = [UIAlertController
            alertControllerWithTitle:@"New Folder"
                             message:@"Enter a name"
                      preferredStyle:UIAlertControllerStyleAlert];
        [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Folder name";
            tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }];
        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a2) {
            NSString *name = nameAlert.textFields.firstObject.text;
            if (name.length > 0) {
                MSGChatFolder *f = [mgr createFolderWithName:name];
                [mgr addThreadKey:threadKey toFolderId:f.folderId];
            }
        }]];
        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
        [presenter presentViewController:nameAlert animated:YES completion:nil];
    }]];

    if (currentFolder) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"❌ Remove from Folder"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *a) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(
            presenter.view.bounds.size.width / 2,
            presenter.view.bounds.size.height / 2, 0, 0);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Conversation Picker (📂 button handler)
// ═══════════════════════════════════════════════════════════

/// Called when the user taps 📂. Reads visible cells from the collection view
/// and shows a picker list of conversations to assign to a folder.
static void MSGChatFolders_showConversationPicker(void) {
    CFLOG(@"Showing conversation picker...");

    // Find the collection view by searching the view hierarchy
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    if (!window) return;

    // BFS to find collection views
    UICollectionView *cv = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window.rootViewController.view];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UICollectionView class]] && v.window) {
            UICollectionView *candidate = (UICollectionView *)v;
            // Pick the largest collection view (most likely the conversation list)
            if (!cv || (candidate.visibleCells.count > cv.visibleCells.count)) {
                cv = candidate;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    if (!cv) {
        CFLOG(@"No collection view found!");
        return;
    }

    CFLOG(@"Found CV with %lu visible cells (class: %@)",
          (unsigned long)cv.visibleCells.count,
          NSStringFromClass([cv class]));

    // Read visible cells and extract names + thread keys
    NSMutableArray<NSDictionary *> *conversations = [NSMutableArray array];

    for (UICollectionViewCell *cell in cv.visibleCells) {
        NSString *name = extractDisplayNameFromCell(cell);
        NSString *threadKey = extractThreadKeyFromCell(cell);

        // Log cell info for debugging
        CFLOG(@"Cell: class=%@, name=%@, threadKey=%@",
              NSStringFromClass([cell class]), name ?: @"(nil)", threadKey ?: @"(nil)");

        if (name || threadKey) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"name"] = name ?: [NSString stringWithFormat:@"Conversation %@",
                                     threadKey ?: @"(unknown)"];
            if (threadKey) info[@"threadKey"] = threadKey;

            // Check current folder
            MSGChatFolder *folder = [[MSGChatFolderManager sharedManager]
                                     folderForThreadKey:threadKey];
            if (folder) {
                info[@"folder"] = folder.name;
            }

            [conversations addObject:info];
        }
    }

    // Present the picker
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;

    if (conversations.count == 0) {
        UIAlertController *empty = [UIAlertController
            alertControllerWithTitle:@"No Conversations Found"
                             message:@"Could not read any conversations from the current view. "
                                      "Try scrolling to load conversations first."
                      preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [topVC presentViewController:empty animated:YES completion:nil];
        return;
    }

    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:@"📂 Pick a Conversation"
                         message:@"Select a conversation to assign to a folder"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *info in conversations) {
        NSString *name = info[@"name"];
        NSString *threadKey = info[@"threadKey"];
        NSString *currentFolder = info[@"folder"];

        NSString *title = name;
        if (currentFolder) {
            title = [NSString stringWithFormat:@"%@ [📁 %@]", name, currentFolder];
        }

        UIAlertAction *action = [UIAlertAction
            actionWithTitle:title
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            if (threadKey) {
                presentFolderActionSheet(topVC, threadKey);
            } else {
                UIAlertController *err = [UIAlertController
                    alertControllerWithTitle:@"Cannot Assign"
                                     message:@"Could not identify this conversation's thread key."
                              preferredStyle:UIAlertControllerStyleAlert];
                [err addAction:[UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
                [topVC presentViewController:err animated:YES completion:nil];
            }
        }];
        [picker addAction:action];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];

    if (picker.popoverPresentationController) {
        picker.popoverPresentationController.sourceView = topVC.view;
        picker.popoverPresentationController.sourceRect = CGRectMake(
            topVC.view.bounds.size.width / 2, 60, 0, 0);
    }

    [topVC presentViewController:picker animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Folder Tab Long Press Handling
// ═══════════════════════════════════════════════════════════

static void handleFolderTabLongPress(UIViewController *presenter, NSString *folderId) {
    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *folder = nil;
    for (MSGChatFolder *f in [mgr allFolders]) {
        if ([f.folderId isEqualToString:folderId]) { folder = f; break; }
    }
    if (!folder) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:folder.name
                         message:[NSString stringWithFormat:@"%lu conversations",
                                  (unsigned long)folder.threadKeys.count]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"✏️ Rename"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIAlertController *rename = [UIAlertController
            alertControllerWithTitle:@"Rename Folder" message:nil
                      preferredStyle:UIAlertControllerStyleAlert];
        [rename addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = folder.name;
        }];
        [rename addAction:[UIAlertAction actionWithTitle:@"Save"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a2) {
            NSString *n = rename.textFields.firstObject.text;
            if (n.length > 0) [mgr renameFolderWithId:folderId toName:n];
        }]];
        [rename addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:rename animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"🗑 Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        UIAlertController *confirm = [UIAlertController
            alertControllerWithTitle:@"Delete Folder?"
                             message:[NSString stringWithFormat:
                                @"Delete \"%@\"? Conversations won't be deleted.", folder.name]
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction *a2) {
            [mgr deleteFolderWithId:folderId];
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                    style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:confirm animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(
            presenter.view.bounds.size.width / 2, 60, 0, 0);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook: Inject Folder Tab Bar
// ═══════════════════════════════════════════════════════════

static void hooked_inboxViewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_inboxViewDidAppear(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;

    NSNumber *initialized = objc_getAssociatedObject(self, kFolderInitializedKey);
    if ([initialized boolValue]) {
        MSGChatFolderTabView *tabView = objc_getAssociatedObject(self, kFolderTabViewKey);
        [tabView reloadTabs];
        return;
    }
    objc_setAssociatedObject(self, kFolderInitializedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CFLOG(@"Injecting folder tab bar into %@", NSStringFromClass([self class]));

    // Find the collection view
    UICollectionView *mainCV = nil;

    // Search up to 5 levels deep
    NSMutableArray *searchQueue = [vc.view.subviews mutableCopy];
    int depth = 0;
    while (searchQueue.count > 0 && depth < 5 && !mainCV) {
        NSMutableArray *nextLevel = [NSMutableArray array];
        for (UIView *v in searchQueue) {
            if ([v isKindOfClass:[UICollectionView class]]) {
                mainCV = (UICollectionView *)v;
                break;
            }
            [nextLevel addObjectsFromArray:v.subviews];
        }
        if (!mainCV) searchQueue = nextLevel;
        depth++;
    }

    // Create tab bar
    CGFloat tabHeight = [MSGChatFolderTabView preferredHeight];
    MSGChatFolderTabView *tabView = [[MSGChatFolderTabView alloc]
        initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width, tabHeight)];
    tabView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tabView.selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;

    objc_setAssociatedObject(self, kFolderTabViewKey, tabView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (mainCV) {
        objc_setAssociatedObject(self, kCollectionViewRefKey, mainCV, OBJC_ASSOCIATION_ASSIGN);

        CGRect scrollFrame = mainCV.frame;
        CGFloat originalY = scrollFrame.origin.y;

        tabView.frame = CGRectMake(0, originalY, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];

        scrollFrame.origin.y += tabHeight;
        scrollFrame.size.height -= tabHeight;
        mainCV.frame = scrollFrame;

        CFLOG(@"Tab bar injected. CV: %@, delegate: %@",
              NSStringFromClass([mainCV class]),
              NSStringFromClass([mainCV.delegate class]));
    } else {
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = vc.view.safeAreaInsets.top;
        }
        tabView.frame = CGRectMake(0, safeTop, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];
        CFLOG(@"Tab bar injected (fallback, no CV found)");
    }

    [tabView reloadTabs];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Class Reconnaissance
// ═══════════════════════════════════════════════════════════

static void logMessengerClasses(void) {
    CFLOG(@"=== CLASS RECONNAISSANCE ===");

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    NSMutableArray *relevant = [NSMutableArray array];
    NSArray *patterns = @[
        @"MSGInbox", @"MSGThread", @"MSGConversation", @"MSGChat",
        @"LSThread", @"LSInbox", @"LSChat", @"LSConversation",
        @"FBMThread", @"FBMInbox", @"FBMConversation",
        @"CommunityList", @"ThreadList"
    ];

    for (unsigned int i = 0; i < classCount; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        for (NSString *p in patterns) {
            if ([name containsString:p]) { [relevant addObject:name]; break; }
        }
    }
    free(classes);

    [relevant sortUsingSelector:@selector(compare:)];
    for (NSString *cls in relevant) { CFLOG(@"  %@", cls); }
    CFLOG(@"=== END (%lu classes) ===", (unsigned long)relevant.count);
}

// ═══════════════════════════════════════════════════════════
// MARK: - Swizzle Utility
// ═══════════════════════════════════════════════════════════

static BOOL swizzleMethod(Class cls, SEL sel, IMP newIMP, IMP *outOrig) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newIMP);
    CFLOG(@"Swizzled %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
    return YES;
}

static BOOL addMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls) return NO;
    return class_addMethod(cls, sel, imp, types);
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook Registration
// ═══════════════════════════════════════════════════════════

void MSGChatFolders_RegisterHooks(void) {
    CFLOG(@"Registering hooks...");
    logMessengerClasses();

    NSArray *inboxClassNames = @[
        @"MSGInboxViewController",
        @"MSGCommunityListViewController",
        @"MSGThreadListViewController",
        @"LSInboxViewController",
        @"FBMThreadListViewController",
        @"MSGMailboxViewController"
    ];

    Class inboxClass = nil;
    for (NSString *name in inboxClassNames) {
        inboxClass = NSClassFromString(name);
        if (inboxClass) { CFLOG(@"Found inbox class: %@", name); break; }
    }

    if (inboxClass) {
        swizzleMethod(inboxClass, @selector(viewDidAppear:),
                      (IMP)hooked_inboxViewDidAppear, (IMP *)&orig_inboxViewDidAppear);

        addMethod(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidSelect:"),
                  (IMP)msgcf_folderTabDidSelect, "v@:@");
        addMethod(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidCreate:"),
                  (IMP)msgcf_folderTabDidCreate, "v@:@");
        addMethod(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidLongPress:"),
                  (IMP)msgcf_folderTabDidLongPress, "v@:@");
    } else {
        CFLOG(@"WARNING: No inbox class found! Check reconnaissance above.");
    }

    // Register 📂 picker notification
    [[NSNotificationCenter defaultCenter]
        addObserverForName:MSGChatFoldersShowPickerNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        MSGChatFolders_showConversationPicker();
    }];

    CFLOG(@"Hook registration complete.");
}

// ═══════════════════════════════════════════════════════════
// MARK: - Tab View Delegate Shim
// ═══════════════════════════════════════════════════════════

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;
    [[MSGChatFolderManager sharedManager] setSelectedFolderId:folderId];
    UIViewController *vc = (UIViewController *)self;
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)sub reloadData];
            break;
        }
    }
}

static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note) {
    UIViewController *vc = (UIViewController *)self;
    UIAlertController *nameAlert = [UIAlertController
        alertControllerWithTitle:@"New Folder" message:@"Enter a name"
                  preferredStyle:UIAlertControllerStyleAlert];
    [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
        NSString *name = nameAlert.textFields.firstObject.text;
        if (name.length > 0) [[MSGChatFolderManager sharedManager] createFolderWithName:name];
    }]];
    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:nameAlert animated:YES completion:nil];
}

static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;
    handleFolderTabLongPress((UIViewController *)self, folderId);
}
