//
//  MSGChatFolderHooks.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Runtime method swizzling hooks for Messenger.
//  Injects the folder tab bar into the inbox, adds context menu actions,
//  and filters the conversation list based on the selected folder.
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

static const void *kFolderTabViewKey    = &kFolderTabViewKey;
static const void *kFolderInitializedKey = &kFolderInitializedKey;

// ═══════════════════════════════════════════════════════════
// MARK: - Original Method Pointers (IMPs)
// ═══════════════════════════════════════════════════════════

// MSGInboxViewController
static void (*orig_inboxViewDidAppear)(id self, SEL _cmd, BOOL animated);

// UICollectionView context menu
static id (*orig_contextMenuConfig)(id self, SEL _cmd, id collectionView, id indexPath, id point);

// ═══════════════════════════════════════════════════════════
// MARK: - Thread Key Extraction
// ═══════════════════════════════════════════════════════════

/// Attempts to extract a threadKey from a Messenger conversation cell/model.
/// Tries multiple strategies since class names can vary between versions.
static NSString *extractThreadKeyFromCell(UIView *cell) {
    if (!cell) return nil;

    // Strategy 1: Try common KVC property names on the cell itself
    NSArray *keyNames = @[
        @"threadKey", @"thread_key", @"threadFBID", @"threadId",
        @"conversationKey", @"conversationId", @"identifier",
        @"itemIdentifier", @"uniqueId"
    ];

    for (NSString *key in keyNames) {
        @try {
            id value = [cell valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
            if ([value isKindOfClass:[NSNumber class]]) {
                return [value stringValue];
            }
        } @catch (NSException *e) {
            // Key doesn't exist, continue
        }
    }

    // Strategy 2: Look for a "model", "viewModel", "data" property on the cell
    NSArray *modelKeys = @[@"model", @"viewModel", @"data", @"item",
                           @"threadSummary", @"conversation", @"thread"];

    for (NSString *modelKey in modelKeys) {
        @try {
            id model = [cell valueForKey:modelKey];
            if (!model) continue;

            // Try extracting thread key from the model
            for (NSString *key in keyNames) {
                @try {
                    id value = [model valueForKey:key];
                    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                        return value;
                    }
                    if ([value isKindOfClass:[NSNumber class]]) {
                        return [value stringValue];
                    }
                } @catch (NSException *e) {
                    // Key doesn't exist on model, continue
                }
            }
        } @catch (NSException *e) {
            // Model key doesn't exist, continue
        }
    }

    // Strategy 3: Traverse the responder chain looking for a thread key
    UIResponder *responder = cell;
    for (int depth = 0; depth < 10 && responder; depth++) {
        for (NSString *key in keyNames) {
            @try {
                id value = [(id)responder valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    return value;
                }
            } @catch (NSException *e) {}
        }
        responder = [responder nextResponder];
    }

    // Strategy 4: Use the cell's accessibilityIdentifier (Messenger sometimes sets this)
    if ([cell isKindOfClass:[UIView class]]) {
        NSString *accId = [(UIView *)cell accessibilityIdentifier];
        if (accId && accId.length > 5) {
            CFLOG(@"Using accessibilityIdentifier as threadKey: %@", accId);
            return accId;
        }
    }

    // Strategy 5: Scan all ivars of the cell class for string values containing "t_"
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([cell class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *ivarType = ivar_getTypeEncoding(ivars[i]);
        if (ivarType && ivarType[0] == '@') {  // Object type
            @try {
                id val = object_getIvar(cell, ivars[i]);
                if ([val isKindOfClass:[NSString class]]) {
                    NSString *str = (NSString *)val;
                    // Messenger thread keys often start with "t_" or are numeric
                    if ([str hasPrefix:@"t_"] || (str.length > 10 && [str longLongValue] > 0)) {
                        const char *name = ivar_getName(ivars[i]);
                        CFLOG(@"Found potential threadKey in ivar '%s': %@", name, str);
                        free(ivars);
                        return str;
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    if (ivars) free(ivars);

    CFLOG(@"WARNING: Could not extract threadKey from cell of class %@", NSStringFromClass([cell class]));
    return nil;
}

// ═══════════════════════════════════════════════════════════
// MARK: - UI Helper: Present "Add to Folder" Action Sheet
// ═══════════════════════════════════════════════════════════

static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey) {
    if (!threadKey || !presenter) return;

    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"📁 Add to Folder"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    // Current folder for this thread
    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];

    // List existing folders
    for (MSGChatFolder *folder in [mgr allFolders]) {
        NSString *title = folder.name;
        if ([folder.folderId isEqualToString:currentFolder.folderId]) {
            title = [NSString stringWithFormat:@"✓ %@", folder.name];
        }
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
            if ([folder.folderId isEqualToString:currentFolder.folderId]) {
                // Already in this folder — remove it
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
        }];
        [alert addAction:action];
    }

    // Separator (visual — just using a disabled action)
    if ([mgr allFolders].count > 0) {
        UIAlertAction *sep = [UIAlertAction actionWithTitle:@"──────────"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil];
        [sep setEnabled:NO];
        [alert addAction:sep];
    }

    // Create new folder
    UIAlertAction *createAction = [UIAlertAction
        actionWithTitle:@"➕ Create New Folder"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction * _Nonnull action) {
        UIAlertController *nameAlert = [UIAlertController
            alertControllerWithTitle:@"New Folder"
                             message:@"Enter a name for the new folder"
                      preferredStyle:UIAlertControllerStyleAlert];

        [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Folder name";
            tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }];

        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
            NSString *name = nameAlert.textFields.firstObject.text;
            if (name.length > 0) {
                MSGChatFolder *newFolder = [mgr createFolderWithName:name];
                [mgr addThreadKey:threadKey toFolderId:newFolder.folderId];
            }
        }]];

        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];

        [presenter presentViewController:nameAlert animated:YES completion:nil];
    }];
    [alert addAction:createAction];

    // Remove from folder (if currently in one)
    if (currentFolder) {
        UIAlertAction *removeAction = [UIAlertAction
            actionWithTitle:@"❌ Remove from Folder"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction * _Nonnull action) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
        }];
        [alert addAction:removeAction];
    }

    // Cancel
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad popover support
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(
            presenter.view.bounds.size.width / 2, presenter.view.bounds.size.height / 2, 0, 0);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - UI Helper: Folder Tab Delegate Handling
// ═══════════════════════════════════════════════════════════

/// Shows rename/delete options when long-pressing a folder tab
static void handleFolderTabLongPress(UIViewController *presenter, NSString *folderId) {
    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *folder = nil;
    for (MSGChatFolder *f in [mgr allFolders]) {
        if ([f.folderId isEqualToString:folderId]) {
            folder = f;
            break;
        }
    }
    if (!folder) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:folder.name
                         message:[NSString stringWithFormat:@"%lu conversations",
                                  (unsigned long)folder.threadKeys.count]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    // Rename
    [alert addAction:[UIAlertAction actionWithTitle:@"✏️ Rename"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIAlertController *renameAlert = [UIAlertController
            alertControllerWithTitle:@"Rename Folder"
                             message:nil
                      preferredStyle:UIAlertControllerStyleAlert];

        [renameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = folder.name;
            tf.placeholder = @"New name";
            tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }];

        [renameAlert addAction:[UIAlertAction actionWithTitle:@"Save"
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *a2) {
            NSString *newName = renameAlert.textFields.firstObject.text;
            if (newName.length > 0) {
                [mgr renameFolderWithId:folderId toName:newName];
            }
        }]];

        [renameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];

        [presenter presentViewController:renameAlert animated:YES completion:nil];
    }]];

    // Delete
    [alert addAction:[UIAlertAction
        actionWithTitle:@"🗑 Delete Folder"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *a) {
        UIAlertController *confirmAlert = [UIAlertController
            alertControllerWithTitle:@"Delete Folder?"
                             message:[NSString stringWithFormat:
                                @"Are you sure you want to delete \"%@\"? "
                                "Conversations won't be deleted, just unassigned from this folder.",
                                folder.name]
                      preferredStyle:UIAlertControllerStyleAlert];

        [confirmAlert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                        style:UIAlertActionStyleDestructive
                                                      handler:^(UIAlertAction *a2) {
            [mgr deleteFolderWithId:folderId];
        }]];

        [confirmAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];

        [presenter presentViewController:confirmAlert animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(
            presenter.view.bounds.size.width / 2, 60, 0, 0);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook 1: Inject Folder Tab Bar into Inbox
// ═══════════════════════════════════════════════════════════

/// Replacement for MSGInboxViewController's viewDidAppear:
/// Injects the folder tab bar if not already present.
static void hooked_inboxViewDidAppear(id self, SEL _cmd, BOOL animated) {
    // Call original
    orig_inboxViewDidAppear(self, _cmd, animated);

    // Only inject once
    NSNumber *initialized = objc_getAssociatedObject(self, kFolderInitializedKey);
    if ([initialized boolValue]) {
        // Tab already injected — just reload it
        MSGChatFolderTabView *tabView = objc_getAssociatedObject(self, kFolderTabViewKey);
        [tabView reloadTabs];
        return;
    }
    objc_setAssociatedObject(self, kFolderInitializedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CFLOG(@"Injecting folder tab bar into %@", NSStringFromClass([self class]));

    UIViewController *vc = (UIViewController *)self;

    // Find the collection view or table view in the hierarchy
    UIScrollView *mainScrollView = nil;
    for (UIView *subview in vc.view.subviews) {
        if ([subview isKindOfClass:[UICollectionView class]] ||
            [subview isKindOfClass:[UITableView class]] ||
            [subview isKindOfClass:[UIScrollView class]]) {
            mainScrollView = (UIScrollView *)subview;
            break;
        }
    }

    // If not found at top level, search deeper (one level)
    if (!mainScrollView) {
        for (UIView *subview in vc.view.subviews) {
            for (UIView *child in subview.subviews) {
                if ([child isKindOfClass:[UICollectionView class]] ||
                    [child isKindOfClass:[UITableView class]]) {
                    mainScrollView = (UIScrollView *)child;
                    break;
                }
            }
            if (mainScrollView) break;
        }
    }

    CGFloat tabHeight = [MSGChatFolderTabView preferredHeight];

    // Create the tab view
    MSGChatFolderTabView *tabView = [[MSGChatFolderTabView alloc]
        initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width, tabHeight)];
    tabView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tabView.selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;

    // Store reference
    objc_setAssociatedObject(self, kFolderTabViewKey, tabView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Create a delegate shim using a block-based approach (objc_setAssociatedObject)
    // We'll handle delegate calls by checking in the tab view's action methods

    if (mainScrollView) {
        // Insert as a header view above the scroll view
        // Adjust the scroll view's frame to make room
        CGRect scrollFrame = mainScrollView.frame;
        CGFloat originalY = scrollFrame.origin.y;

        tabView.frame = CGRectMake(0, originalY, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];

        scrollFrame.origin.y += tabHeight;
        scrollFrame.size.height -= tabHeight;
        mainScrollView.frame = scrollFrame;

        CFLOG(@"Tab bar injected. ScrollView class: %@, new Y: %.0f",
              NSStringFromClass([mainScrollView class]), scrollFrame.origin.y);
    } else {
        // Fallback: just add it to the top of the view
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = vc.view.safeAreaInsets.top;
        }
        tabView.frame = CGRectMake(0, safeTop, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];
        CFLOG(@"Tab bar injected (fallback, no scroll view found)");
    }

    [tabView reloadTabs];

    // Set up a notification-based callback for folder selection and creation
    // The tab view will post notifications, and we handle them here
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook 2: UICollectionView Context Menu
// ═══════════════════════════════════════════════════════════

/// We swizzle UICollectionViewDelegate's contextMenuConfigurationForItemAt
/// to inject our "Add to Folder" action into the preview's action list.
/// This is a broad hook — we check if we're in a Messenger inbox context first.
static id hooked_contextMenuConfig(id self, SEL _cmd, id collectionView, id indexPath, id point) {
    id original = orig_contextMenuConfig(self, _cmd, collectionView, indexPath, point);

    // Only modify if we're in the inbox context
    UIResponder *responder = (UIResponder *)self;
    BOOL isInbox = NO;
    for (int i = 0; i < 10 && responder; i++) {
        NSString *className = NSStringFromClass([responder class]);
        if ([className containsString:@"Inbox"] ||
            [className containsString:@"ThreadList"] ||
            [className containsString:@"ConversationList"] ||
            [className containsString:@"CommunityList"]) {
            isInbox = YES;
            break;
        }
        responder = [responder nextResponder];
    }

    if (!isInbox) return original;

    // Try to extract thread key from the cell at this index path
    UICollectionView *cv = (UICollectionView *)collectionView;
    NSIndexPath *ip = (NSIndexPath *)indexPath;
    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
    NSString *threadKey = extractThreadKeyFromCell(cell);

    if (!threadKey) {
        CFLOG(@"Context menu: could not extract threadKey for indexPath %@", ip);
        return original;
    }

    CFLOG(@"Context menu: threadKey=%@ at indexPath=%@", threadKey, ip);

    // We can't easily modify a UIContextMenuConfiguration's action provider after creation.
    // Instead, we'll add a separate long-press gesture recognizer in the viewDidAppear hook.
    // But if `original` is nil, we create our own.
    // For now, we rely on the separate long-press approach (see below).

    return original;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook 3: Long Press on Conversation Cell
// ═══════════════════════════════════════════════════════════

/// We add an additional UILongPressGestureRecognizer to the collection view
/// that detects long-presses on conversation cells and shows our folder menu
/// AFTER the system context menu is dismissed (or alongside it).
///
/// This approach is used because Messenger's context menu system varies between
/// versions, but long-press gestures always work.
static void addFolderLongPressToCollectionView(UICollectionView *cv, UIViewController *vc) {
    // Check if we already added our gesture
    for (UIGestureRecognizer *gr in cv.gestureRecognizers) {
        if (gr.name && [gr.name isEqualToString:@"MSGChatFoldersLongPress"]) {
            return;  // Already added
        }
    }

    // We'll use a 3D Touch / long press with a longer duration so it doesn't
    // conflict with Messenger's own context menu
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:vc action:NSSelectorFromString(@"msgcf_handleFolderLongPress:")];
    longPress.minimumPressDuration = 1.0;  // Slightly longer than default to not conflict
    longPress.name = @"MSGChatFoldersLongPress";

    // Don't interfere with existing gesture recognizers
    longPress.cancelsTouchesInView = NO;
    longPress.delaysTouchesBegan = NO;

    [cv addGestureRecognizer:longPress];
    CFLOG(@"Added folder long-press gesture to collection view");
}

/// Handler for our custom long-press gesture recognizer.
/// This method is added to the view controller class at runtime.
static void msgcf_handleFolderLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    UICollectionView *cv = (UICollectionView *)gesture.view;
    if (![cv isKindOfClass:[UICollectionView class]]) return;

    CGPoint point = [gesture locationInView:cv];
    NSIndexPath *indexPath = [cv indexPathForItemAtPoint:point];
    if (!indexPath) return;

    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
    NSString *threadKey = extractThreadKeyFromCell(cell);

    if (threadKey) {
        UIViewController *vc = (UIViewController *)self;
        presentFolderActionSheet(vc, threadKey);
    } else {
        CFLOG(@"Long press: could not extract threadKey at %@", indexPath);
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Reconnaissance (Class Discovery)
// ═══════════════════════════════════════════════════════════

/// Logs the view hierarchy of the inbox for debugging.
/// This helps identify the exact class names in case hooks need updating.
static void logViewHierarchy(UIView *view, int depth) {
    if (depth > 6) return;  // Don't go too deep

    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];

    CFLOG(@"%@%@ frame=%@ tag=%ld",
          indent, NSStringFromClass([view class]),
          NSStringFromCGRect(view.frame), (long)view.tag);

    for (UIView *sub in view.subviews) {
        logViewHierarchy(sub, depth + 1);
    }
}

/// Logs all loaded classes that match Messenger naming patterns.
/// Run once at startup for reconnaissance.
static void logMessengerClasses(void) {
    CFLOG(@"=== MESSENGER CLASS RECONNAISSANCE ===");

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    NSMutableArray *relevantClasses = [NSMutableArray array];
    NSArray *patterns = @[
        @"MSGInbox", @"MSGThread", @"MSGConversation", @"MSGChat",
        @"LSThread", @"LSInbox", @"LSChat", @"LSConversation",
        @"FBMThread", @"FBMInbox", @"FBMConversation",
        @"CommunityList", @"ThreadList"
    ];

    for (unsigned int i = 0; i < classCount; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        for (NSString *pattern in patterns) {
            if ([name containsString:pattern]) {
                [relevantClasses addObject:name];
                break;
            }
        }
    }
    free(classes);

    // Sort and log
    [relevantClasses sortUsingSelector:@selector(compare:)];
    for (NSString *cls in relevantClasses) {
        CFLOG(@"  Found class: %@", cls);
    }
    CFLOG(@"=== END RECONNAISSANCE (%lu classes found) ===",
          (unsigned long)relevantClasses.count);
}

// ═══════════════════════════════════════════════════════════
// MARK: - Swizzle Utility
// ═══════════════════════════════════════════════════════════

/// Safely swizzles an instance method, storing the original IMP.
/// Returns YES if swizzling succeeded.
static BOOL swizzleMethod(Class cls, SEL originalSel, IMP replacementIMP, IMP *outOriginalIMP) {
    if (!cls) {
        CFLOG(@"Swizzle failed: class is nil for %@", NSStringFromSelector(originalSel));
        return NO;
    }

    Method method = class_getInstanceMethod(cls, originalSel);
    if (!method) {
        CFLOG(@"Swizzle failed: method %@ not found on %@",
              NSStringFromSelector(originalSel), NSStringFromClass(cls));
        return NO;
    }

    // Get the original IMP
    IMP origIMP = method_getImplementation(method);
    if (outOriginalIMP) {
        *outOriginalIMP = origIMP;
    }

    // Try to add the method first (in case it's inherited)
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, originalSel, replacementIMP, types)) {
        // Method was added (was inherited), now get the super's version
        // The original IMP we captured above is correct
        CFLOG(@"Added method %@ to %@ (was inherited)", NSStringFromSelector(originalSel), NSStringFromClass(cls));
    } else {
        // Method exists on this class, replace it directly
        method_setImplementation(method, replacementIMP);
    }

    CFLOG(@"Swizzled %@ on %@", NSStringFromSelector(originalSel), NSStringFromClass(cls));
    return YES;
}

/// Adds a new method to a class at runtime.
static BOOL addMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls) return NO;
    BOOL result = class_addMethod(cls, sel, imp, types);
    if (result) {
        CFLOG(@"Added method %@ to %@", NSStringFromSelector(sel), NSStringFromClass(cls));
    }
    return result;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook Registration
// ═══════════════════════════════════════════════════════════

void MSGChatFolders_RegisterHooks(void) {
    CFLOG(@"Registering hooks...");

    // Run reconnaissance to discover available classes
    logMessengerClasses();

    // ── Hook 1: Inbox View Controller ──

    // Try multiple possible class names for the inbox VC
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
        if (inboxClass) {
            CFLOG(@"Found inbox class: %@", name);
            break;
        }
    }

    if (inboxClass) {
        // Hook viewDidAppear:
        swizzleMethod(inboxClass,
                      @selector(viewDidAppear:),
                      (IMP)hooked_inboxViewDidAppear,
                      (IMP *)&orig_inboxViewDidAppear);

        // Add our long-press handler method to the class
        addMethod(inboxClass,
                  NSSelectorFromString(@"msgcf_handleFolderLongPress:"),
                  (IMP)msgcf_handleFolderLongPress,
                  "v@:@");

        // Add folder tab delegate methods
        addMethod(inboxClass,
                  NSSelectorFromString(@"msgcf_folderTabDidSelect:"),
                  (IMP)msgcf_folderTabDidSelect,
                  "v@:@");

        addMethod(inboxClass,
                  NSSelectorFromString(@"msgcf_folderTabDidCreate:"),
                  (IMP)msgcf_folderTabDidCreate,
                  "v@:@");

        addMethod(inboxClass,
                  NSSelectorFromString(@"msgcf_folderTabDidLongPress:"),
                  (IMP)msgcf_folderTabDidLongPress,
                  "v@:@");
    } else {
        CFLOG(@"WARNING: No inbox view controller class found! Tab bar will not be injected.");
        CFLOG(@"Check the reconnaissance log above for available classes.");
    }

    CFLOG(@"Hook registration complete.");
}

// ═══════════════════════════════════════════════════════════
// MARK: - Tab View Delegate Shim (Added to Inbox VC)
// ═══════════════════════════════════════════════════════════

/// These functions are added as methods to the inbox VC class at runtime.
/// They bridge the MSGChatFolderTabView delegate protocol.

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;

    [[MSGChatFolderManager sharedManager] setSelectedFolderId:folderId];

    // Force the collection view to reload
    UIViewController *vc = (UIViewController *)self;
    for (UIView *subview in vc.view.subviews) {
        if ([subview isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)subview;
            [cv reloadData];
            CFLOG(@"Reloaded collection view for folder: %@", folderId);
            break;
        }
    }
}

static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note) {
    UIViewController *vc = (UIViewController *)self;

    UIAlertController *nameAlert = [UIAlertController
        alertControllerWithTitle:@"New Folder"
                         message:@"Enter a name for the new folder"
                  preferredStyle:UIAlertControllerStyleAlert];

    [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
        NSString *name = nameAlert.textFields.firstObject.text;
        if (name.length > 0) {
            [[MSGChatFolderManager sharedManager] createFolderWithName:name];
        }
    }]];

    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

    [vc presentViewController:nameAlert animated:YES completion:nil];
}

static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;
    handleFolderTabLongPress((UIViewController *)self, folderId);
}
