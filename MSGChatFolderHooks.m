//
//  MSGChatFolderHooks.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Runtime method swizzling hooks for Messenger.
//  Injects the folder tab bar into the inbox and adds "Add to Folder"
//  directly into Messenger's native long-press context menu.
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

static const void *kFolderTabViewKey         = &kFolderTabViewKey;
static const void *kFolderInitializedKey     = &kFolderInitializedKey;
static const void *kContextMenuHookedKey     = &kContextMenuHookedKey;
static const void *kCollectionViewRefKey     = &kCollectionViewRefKey;
static const void *kAssignTapGestureKey      = &kAssignTapGestureKey;
static const void *kAssignOverlayKey         = &kAssignOverlayKey;
static const void *kInboxVCRefKey            = &kInboxVCRefKey;

// ═══════════════════════════════════════════════════════════
// MARK: - Forward Declarations
// ═══════════════════════════════════════════════════════════

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note);
static NSString *extractThreadKeyFromCell(UIView *cell);
static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey);
static UIViewController *findTopViewController(void);

// ═══════════════════════════════════════════════════════════
// MARK: - Original Method Pointers (IMPs)
// ═══════════════════════════════════════════════════════════

// MSGInboxViewController viewDidAppear:
static void (*orig_inboxViewDidAppear)(id self, SEL _cmd, BOOL animated);

// Dynamic hooks (set at runtime when we discover the delegate class)
static UIContextMenuConfiguration *(*orig_contextMenuForItemAtIndex)(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *ip, CGPoint point);
static UIContextMenuConfiguration *(*orig_contextMenuForItemsAtIndices)(id self, SEL _cmd, UICollectionView *cv, NSArray *indexPaths, CGPoint point);
static void (*orig_didSelectItemAtIndex)(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *ip);
static const void *kDidSelectHookedKey = &kDidSelectHookedKey;

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
                CFLOG(@"Found threadKey via KVC '%@': %@", key, value);
                return value;
            }
            if ([value isKindOfClass:[NSNumber class]]) {
                return [value stringValue];
            }
        } @catch (NSException *e) {}
    }

    // Strategy 2: Look for a "model", "viewModel", "data" property on the cell
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
                        CFLOG(@"Found threadKey via model '%@.%@': %@", modelKey, key, value);
                        return value;
                    }
                    if ([value isKindOfClass:[NSNumber class]]) {
                        return [value stringValue];
                    }
                } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
    }

    // Strategy 3: Traverse the responder chain
    UIResponder *responder = cell;
    for (int depth = 0; depth < 10 && responder; depth++) {
        for (NSString *key in keyNames) {
            @try {
                id value = [(id)responder valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    CFLOG(@"Found threadKey via responder chain (depth %d): %@", depth, value);
                    return value;
                }
            } @catch (NSException *e) {}
        }
        responder = [responder nextResponder];
    }

    // Strategy 4: Use accessibilityIdentifier
    if ([cell isKindOfClass:[UIView class]]) {
        NSString *accId = [(UIView *)cell accessibilityIdentifier];
        if (accId && accId.length > 5) {
            CFLOG(@"Using accessibilityIdentifier as threadKey: %@", accId);
            return accId;
        }
    }

    // Strategy 5: Scan all ivars for string values containing "t_" (Messenger thread key prefix)
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

    // Strategy 6: Scan ivars of model objects attached to the cell
    NSArray *modelIvarNames = @[@"_model", @"_viewModel", @"_data", @"_item", @"_thread"];
    Ivar *cellIvars = class_copyIvarList([cell class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(cellIvars[i])];
        for (NSString *modelName in modelIvarNames) {
            if ([ivarName isEqualToString:modelName]) {
                @try {
                    id model = object_getIvar(cell, cellIvars[i]);
                    if (!model) continue;
                    // Scan this model's ivars too
                    unsigned int mIvarCount = 0;
                    Ivar *mIvars = class_copyIvarList([model class], &mIvarCount);
                    for (unsigned int j = 0; j < mIvarCount; j++) {
                        const char *mType = ivar_getTypeEncoding(mIvars[j]);
                        if (mType && mType[0] == '@') {
                            id mVal = object_getIvar(model, mIvars[j]);
                            if ([mVal isKindOfClass:[NSString class]]) {
                                NSString *mStr = (NSString *)mVal;
                                if ([mStr hasPrefix:@"t_"] || (mStr.length > 10 && [mStr longLongValue] > 0)) {
                                    CFLOG(@"Found threadKey in model ivar '%s.%s': %@",
                                          ivar_getName(cellIvars[i]), ivar_getName(mIvars[j]), mStr);
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

    CFLOG(@"WARNING: Could not extract threadKey from cell of class %@", NSStringFromClass([cell class]));
    // Log the cell's class hierarchy for debugging
    Class cls = [cell class];
    while (cls) {
        CFLOG(@"  Class hierarchy: %@", NSStringFromClass(cls));
        cls = [cls superclass];
        if (cls == [UIView class] || cls == [NSObject class]) break;
    }

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

    // Create new folder
    [alert addAction:[UIAlertAction
        actionWithTitle:@"➕ Create New Folder"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
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
                                                    handler:^(UIAlertAction *a2) {
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
            presenter.view.bounds.size.width / 2, presenter.view.bounds.size.height / 2, 0, 0);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Build Folder UIMenu (for context menu injection)
// ═══════════════════════════════════════════════════════════

/// Creates a UIMenu containing folder actions for a given threadKey.
/// This is added directly into Messenger's native context menu.
static UIMenu *buildFolderMenu(NSString *threadKey) {
    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    // Existing folders
    for (MSGChatFolder *folder in [mgr allFolders]) {
        NSString *title = folder.name;
        UIImage *image = nil;

        if ([folder.folderId isEqualToString:currentFolder.folderId]) {
            title = [NSString stringWithFormat:@"✓ %@", folder.name];
            image = [UIImage systemImageNamed:@"folder.fill"];
        } else {
            image = [UIImage systemImageNamed:@"folder"];
        }

        UIAction *action = [UIAction actionWithTitle:title
                                               image:image
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            if ([folder.folderId isEqualToString:currentFolder.folderId]) {
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
        }];
        [actions addObject:action];
    }

    // Create new folder
    UIAction *createAction = [UIAction actionWithTitle:@"New Folder..."
                                                 image:[UIImage systemImageNamed:@"folder.badge.plus"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *a) {
        // Delay slightly so the context menu dismisses first
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *topVC = findTopViewController();
            if (!topVC) return;

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
                                                        handler:^(UIAlertAction *a2) {
                NSString *name = nameAlert.textFields.firstObject.text;
                if (name.length > 0) {
                    MSGChatFolder *newFolder = [mgr createFolderWithName:name];
                    [mgr addThreadKey:threadKey toFolderId:newFolder.folderId];
                }
            }]];

            [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];

            [topVC presentViewController:nameAlert animated:YES completion:nil];
        });
    }];
    [actions addObject:createAction];

    // Remove from folder (if in one)
    if (currentFolder) {
        UIAction *removeAction = [UIAction actionWithTitle:@"Remove from Folder"
                                                     image:[UIImage systemImageNamed:@"folder.badge.minus"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction *a) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
        }];
        removeAction.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:removeAction];
    }

    UIMenu *folderMenu = [UIMenu menuWithTitle:@"Add to Folder"
                                         image:[UIImage systemImageNamed:@"folder"]
                                    identifier:@"com.msgchatfolders.menu"
                                       options:0
                                      children:actions];
    return folderMenu;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Context Menu Hook (injected into Messenger's delegate)
// ═══════════════════════════════════════════════════════════

/// Hooked version of collectionView:contextMenuConfigurationForItemAtIndexPath:point:
/// Wraps Messenger's original context menu to add our folder action.
static UIContextMenuConfiguration *hooked_contextMenuForItemAtIndex(
    id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath, CGPoint point)
{
    // Call Messenger's original implementation
    UIContextMenuConfiguration *original = orig_contextMenuForItemAtIndex(self, _cmd, cv, indexPath, point);

    if (!original) {
        CFLOG(@"Context menu: original returned nil for indexPath %@", indexPath);
        return original;
    }

    // Get the cell and extract thread key
    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
    NSString *threadKey = extractThreadKeyFromCell(cell);

    if (!threadKey) {
        CFLOG(@"Context menu: no threadKey found at indexPath %@, returning original", indexPath);
        return original;
    }

    CFLOG(@"Context menu: injecting folder action for threadKey=%@", threadKey);

    // Extract the original preview and action providers via runtime introspection
    UIContextMenuContentPreviewProvider origPreview = nil;
    UIContextMenuActionProvider origActionProvider = nil;

    // Try to access the stored blocks from the original configuration
    Ivar previewIvar = class_getInstanceVariable([UIContextMenuConfiguration class], "_previewProvider");
    Ivar actionIvar = class_getInstanceVariable([UIContextMenuConfiguration class], "_actionProvider");

    if (previewIvar) {
        origPreview = (__bridge UIContextMenuContentPreviewProvider)
            ((__bridge void *)object_getIvar(original, previewIvar));
    }
    if (actionIvar) {
        origActionProvider = (__bridge UIContextMenuActionProvider)
            ((__bridge void *)object_getIvar(original, actionIvar));
    }

    // If we couldn't extract the action provider, try KVC as fallback
    if (!origActionProvider) {
        @try {
            origActionProvider = [original valueForKey:@"_actionProvider"];
        } @catch (NSException *e) {
            CFLOG(@"Context menu: could not extract action provider: %@", e);
        }
    }

    // Build our replacement action provider that includes the original + our folder action
    UIContextMenuActionProvider wrappedActionProvider = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *originalMenu = nil;

        if (origActionProvider) {
            originalMenu = origActionProvider(suggestedActions);
        }

        // Build our folder submenu
        UIMenu *folderMenu = buildFolderMenu(threadKey);

        if (originalMenu) {
            // Wrap folder menu as an inline section to separate it visually
            UIMenu *folderSection = [UIMenu menuWithTitle:@""
                                                    image:nil
                                               identifier:@"com.msgchatfolders.section"
                                                  options:UIMenuOptionsDisplayInline
                                                 children:@[folderMenu]];

            NSMutableArray *allChildren = [originalMenu.children mutableCopy];
            [allChildren addObject:folderSection];
            return [originalMenu menuByReplacingChildren:allChildren];
        } else {
            // No original menu — just show ours (shouldn't happen normally)
            return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
        }
    };

    // Create new configuration preserving the original preview
    UIContextMenuConfiguration *newConfig = [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:origPreview
                     actionProvider:wrappedActionProvider];

    return newConfig;
}

/// Hooked version for iOS 16+ multi-item context menu
static UIContextMenuConfiguration *hooked_contextMenuForItemsAtIndices(
    id self, SEL _cmd, UICollectionView *cv, NSArray *indexPaths, CGPoint point)
{
    UIContextMenuConfiguration *original = orig_contextMenuForItemsAtIndices(self, _cmd, cv, indexPaths, point);

    if (!original || indexPaths.count == 0) return original;

    NSIndexPath *indexPath = indexPaths.firstObject;
    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
    NSString *threadKey = extractThreadKeyFromCell(cell);

    if (!threadKey) return original;

    CFLOG(@"Context menu (multi): injecting folder action for threadKey=%@", threadKey);

    // Same wrapping logic as above
    UIContextMenuActionProvider origActionProvider = nil;
    UIContextMenuContentPreviewProvider origPreview = nil;

    Ivar previewIvar = class_getInstanceVariable([UIContextMenuConfiguration class], "_previewProvider");
    Ivar actionIvar = class_getInstanceVariable([UIContextMenuConfiguration class], "_actionProvider");

    if (previewIvar) {
        origPreview = (__bridge UIContextMenuContentPreviewProvider)
            ((__bridge void *)object_getIvar(original, previewIvar));
    }
    if (actionIvar) {
        origActionProvider = (__bridge UIContextMenuActionProvider)
            ((__bridge void *)object_getIvar(original, actionIvar));
    }

    if (!origActionProvider) {
        @try {
            origActionProvider = [original valueForKey:@"_actionProvider"];
        } @catch (NSException *e) {}
    }

    UIContextMenuActionProvider wrappedProvider = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *originalMenu = origActionProvider ? origActionProvider(suggestedActions) : nil;
        UIMenu *folderMenu = buildFolderMenu(threadKey);
        UIMenu *folderSection = [UIMenu menuWithTitle:@""
                                                image:nil
                                           identifier:@"com.msgchatfolders.section"
                                              options:UIMenuOptionsDisplayInline
                                             children:@[folderMenu]];

        if (originalMenu) {
            NSMutableArray *allChildren = [originalMenu.children mutableCopy];
            [allChildren addObject:folderSection];
            return [originalMenu menuByReplacingChildren:allChildren];
        }
        return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
    };

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:origPreview
                                                    actionProvider:wrappedProvider];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hooked didSelectItemAtIndexPath (Assign Mode)
// ═══════════════════════════════════════════════════════════

/// When assign mode is ON, tapping a conversation shows the folder sheet
/// instead of opening the chat. When OFF, normal Messenger behavior.
static void hooked_didSelectItemAtIndex(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    if (MSGChatFolders_assignModeActive) {
        CFLOG(@"Assign mode: intercepted tap at indexPath %@", indexPath);

        UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
        NSString *threadKey = extractThreadKeyFromCell(cell);

        if (threadKey) {
            UIViewController *topVC = findTopViewController();
            if (topVC) {
                presentFolderActionSheet(topVC, threadKey);
            }
        } else {
            CFLOG(@"Assign mode: could not extract threadKey at %@", indexPath);
            // Still show an alert so user knows it was intercepted
            UIViewController *topVC = findTopViewController();
            if (topVC) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Could not identify conversation"
                                     message:@"Thread key extraction failed. Check logs for details."
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                         style:UIAlertActionStyleDefault
                                                       handler:nil]];
                [topVC presentViewController:alert animated:YES completion:nil];
            }
        }

        // Deselect the cell (don't navigate)
        [cv deselectItemAtIndexPath:indexPath animated:YES];
        return;  // Don't call original — prevent opening the chat
    }

    // Assign mode OFF — call original Messenger behavior
    if (orig_didSelectItemAtIndex) {
        orig_didSelectItemAtIndex(self, _cmd, cv, indexPath);
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Dynamic Delegate Hook Registration
// ═══════════════════════════════════════════════════════════

/// Dynamically hooks the delegate methods on whatever class is serving
/// as the collection view's delegate. Called once after we find the collection view.
static void hookDelegateOnCollectionView(UICollectionView *cv) {
    id delegate = cv.delegate;
    if (!delegate) {
        CFLOG(@"Context menu hook: collection view has no delegate");
        return;
    }

    Class delegateClass = [delegate class];
    NSString *delegateClassName = NSStringFromClass(delegateClass);

    // Check if already hooked
    NSNumber *alreadyHooked = objc_getAssociatedObject(delegateClass, kContextMenuHookedKey);
    if ([alreadyHooked boolValue]) {
        CFLOG(@"Context menu: already hooked on %@", delegateClassName);
        return;
    }

    CFLOG(@"Context menu: attempting to hook delegate class: %@", delegateClassName);

    // Try iOS 13+ single-item method
    SEL singleSel = @selector(collectionView:contextMenuConfigurationForItemAtIndexPath:point:);
    if ([delegate respondsToSelector:singleSel]) {
        Method method = class_getInstanceMethod(delegateClass, singleSel);
        if (method) {
            orig_contextMenuForItemAtIndex = (UIContextMenuConfiguration *(*)(id, SEL, UICollectionView *, NSIndexPath *, CGPoint))
                method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_contextMenuForItemAtIndex);
            CFLOG(@"✅ Hooked contextMenuConfigurationForItemAtIndexPath: on %@", delegateClassName);
            objc_setAssociatedObject(delegateClass, kContextMenuHookedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    // Try iOS 16+ multi-item method
    SEL multiSel = @selector(collectionView:contextMenuConfigurationForItemsAtIndexPaths:point:);
    if ([delegate respondsToSelector:multiSel]) {
        Method method = class_getInstanceMethod(delegateClass, multiSel);
        if (method) {
            orig_contextMenuForItemsAtIndices = (UIContextMenuConfiguration *(*)(id, SEL, UICollectionView *, NSArray *, CGPoint))
                method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_contextMenuForItemsAtIndices);
            CFLOG(@"✅ Hooked contextMenuConfigurationForItemsAtIndexPaths: on %@", delegateClassName);
            objc_setAssociatedObject(delegateClass, kContextMenuHookedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    if (![alreadyHooked boolValue] &&
        ![delegate respondsToSelector:singleSel] &&
        ![delegate respondsToSelector:multiSel]) {
        CFLOG(@"⚠️ Delegate %@ does not implement any context menu methods!", delegateClassName);
        CFLOG(@"  Will search for UIContextMenuInteraction on the collection view instead...");

        // Fallback: Check if the collection view has a UIContextMenuInteraction
        for (id<UIInteraction> interaction in cv.interactions) {
            if ([interaction isKindOfClass:[UIContextMenuInteraction class]]) {
                UIContextMenuInteraction *ctxInteraction = (UIContextMenuInteraction *)interaction;
                id ctxDelegate = ctxInteraction.delegate;
                if (ctxDelegate) {
                    Class ctxDelegateClass = [ctxDelegate class];
                    CFLOG(@"Found UIContextMenuInteraction delegate: %@", NSStringFromClass(ctxDelegateClass));

                    // Hook contextMenuInteraction:configurationForMenuAtLocation:
                    SEL ctxSel = @selector(contextMenuInteraction:configurationForMenuAtLocation:);
                    if ([ctxDelegate respondsToSelector:ctxSel]) {
                        CFLOG(@"  Delegate responds to contextMenuInteraction:configurationForMenuAtLocation:");
                        // Store for future implementation if needed
                    }
                }
            }
        }
    }

    // ── Hook didSelectItemAtIndexPath (for assign mode) ──
    // This is the PRIMARY hook for folder assignment.
    // When assign mode is ON, tapping a conversation shows the folder sheet
    // instead of opening the chat.
    NSNumber *selectHooked = objc_getAssociatedObject(delegateClass, kDidSelectHookedKey);
    if (![selectHooked boolValue]) {
        SEL didSelectSel = @selector(collectionView:didSelectItemAtIndexPath:);
        if ([delegate respondsToSelector:didSelectSel]) {
            Method method = class_getInstanceMethod(delegateClass, didSelectSel);
            if (method) {
                orig_didSelectItemAtIndex = (void (*)(id, SEL, UICollectionView *, NSIndexPath *))
                    method_getImplementation(method);
                method_setImplementation(method, (IMP)hooked_didSelectItemAtIndex);
                objc_setAssociatedObject(delegateClass, kDidSelectHookedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                CFLOG(@"✅ Hooked collectionView:didSelectItemAtIndexPath: on %@", delegateClassName);
                CFLOG(@"   📂 Tap the 📂 button in the folder tab bar to enter assign mode");
            }
        } else {
            CFLOG(@"⚠️ Delegate %@ does not implement didSelectItemAtIndexPath!", delegateClassName);
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Assign Mode Overlay (Tap Interception)
// ═══════════════════════════════════════════════════════════

/// A clear overlay placed on top of the collection view during assign mode.
/// It captures taps (to show folder assignment) but passes through scroll gestures.
@interface MSGChatFolderAssignOverlay : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UICollectionView *targetCollectionView;
@end

@implementation MSGChatFolderAssignOverlay

- (instancetype)initWithFrame:(CGRect)frame collectionView:(UICollectionView *)cv {
    self = [super initWithFrame:frame];
    if (self) {
        self.targetCollectionView = cv;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.01]; // Nearly invisible
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // Tap gesture — this is what intercepts conversation taps
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleAssignTap:)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];

        // Pan gesture — forward scrolling to the collection view beneath
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)handleAssignTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;

    UICollectionView *cv = self.targetCollectionView;
    if (!cv) return;

    // Convert tap point to collection view coordinates
    CGPoint point = [gesture locationInView:cv];
    NSIndexPath *indexPath = [cv indexPathForItemAtPoint:point];

    if (!indexPath) {
        NSLog(@"[MSGChatFolders] Assign tap: no cell at tapped point");
        return;
    }

    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
    if (!cell) return;

    NSString *threadKey = extractThreadKeyFromCell(cell);
    NSLog(@"[MSGChatFolders] Assign tap: indexPath=%@, threadKey=%@", indexPath, threadKey);

    if (threadKey) {
        UIViewController *topVC = findTopViewController();
        if (topVC) {
            presentFolderActionSheet(topVC, threadKey);
        }
    } else {
        UIViewController *topVC = findTopViewController();
        if (topVC) {
            // Log cell class info for debugging
            NSLog(@"[MSGChatFolders] Cell class: %@", NSStringFromClass([cell class]));
            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList([cell class], &ivarCount);
            for (unsigned int i = 0; i < ivarCount; i++) {
                NSLog(@"[MSGChatFolders]   ivar: %s (%s)",
                      ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]));
            }
            if (ivars) free(ivars);

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Could not identify conversation"
                                 message:@"The thread key could not be extracted from this cell. "
                                          "Please check the device logs for [MSGChatFolders] entries."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
            [topVC presentViewController:alert animated:YES completion:nil];
        }
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    // Forward scroll to the collection view beneath
    UICollectionView *cv = self.targetCollectionView;
    if (!cv) return;

    CGPoint translation = [gesture translationInView:self];
    CGPoint contentOffset = cv.contentOffset;
    contentOffset.y -= translation.y;

    // Clamp to content bounds
    CGFloat maxOffset = cv.contentSize.height - cv.bounds.size.height + cv.contentInset.bottom;
    CGFloat minOffset = -cv.contentInset.top;
    contentOffset.y = MAX(minOffset, MIN(maxOffset, contentOffset.y));

    cv.contentOffset = contentOffset;
    [gesture setTranslation:CGPointZero inView:self];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

@end

// ── Assign mode toggle handler ──

static void MSGChatFolders_handleAssignModeChanged(NSNotification *note) {
    BOOL active = [note.userInfo[@"active"] boolValue];
    NSLog(@"[MSGChatFolders] Assign mode notification: %@", active ? @"ON" : @"OFF");

    // Find the stored collection view and inbox VC
    // We search through all windows to find our tab view and its sibling collection view
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

    // Find our tab view in the view hierarchy
    UIView *rootView = window.rootViewController.view;
    MSGChatFolderTabView *tabView = nil;
    UICollectionView *cv = nil;

    // BFS search for tab view and collection view
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([v isKindOfClass:[MSGChatFolderTabView class]]) {
            tabView = (MSGChatFolderTabView *)v;
        }
        // Look for collection views that are siblings of the tab view
        if ([v isKindOfClass:[UICollectionView class]] && !cv) {
            cv = (UICollectionView *)v;
        }

        [queue addObjectsFromArray:v.subviews];
    }

    if (!cv) {
        NSLog(@"[MSGChatFolders] Assign mode: no collection view found!");
        return;
    }

    static const NSInteger kOverlayTag = 98765;

    if (active) {
        // Check if overlay already exists
        UIView *existing = [cv.superview viewWithTag:kOverlayTag];
        if (existing) {
            NSLog(@"[MSGChatFolders] Assign overlay already exists");
            return;
        }

        // Create overlay on top of the collection view
        MSGChatFolderAssignOverlay *overlay = [[MSGChatFolderAssignOverlay alloc]
            initWithFrame:cv.frame collectionView:cv];
        overlay.tag = kOverlayTag;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cv.superview insertSubview:overlay aboveSubview:cv];

        NSLog(@"[MSGChatFolders] ✅ Assign overlay added on top of collection view");
    } else {
        // Remove overlay
        UIView *overlay = [cv.superview viewWithTag:kOverlayTag];
        if (overlay) {
            [overlay removeFromSuperview];
            NSLog(@"[MSGChatFolders] ✅ Assign overlay removed");
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Folder Tab Delegate Handling
// ═══════════════════════════════════════════════════════════

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

    [alert addAction:[UIAlertAction actionWithTitle:@"🗑 Delete Folder"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        UIAlertController *confirm = [UIAlertController
            alertControllerWithTitle:@"Delete Folder?"
                             message:[NSString stringWithFormat:
                                @"Delete \"%@\"? Conversations won't be deleted.",
                                folder.name]
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a2) {
            [mgr deleteFolderWithId:folderId];
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
        [presenter presentViewController:confirm animated:YES completion:nil];
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

static void hooked_inboxViewDidAppear(id self, SEL _cmd, BOOL animated) {
    // Call original
    orig_inboxViewDidAppear(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;

    // Only inject once per VC instance
    NSNumber *initialized = objc_getAssociatedObject(self, kFolderInitializedKey);
    if ([initialized boolValue]) {
        MSGChatFolderTabView *tabView = objc_getAssociatedObject(self, kFolderTabViewKey);
        [tabView reloadTabs];
        return;
    }
    objc_setAssociatedObject(self, kFolderInitializedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CFLOG(@"Injecting folder tab bar into %@", NSStringFromClass([self class]));

    // Find the collection view (conversation list)
    UICollectionView *mainCV = nil;

    // Search direct subviews first
    for (UIView *subview in vc.view.subviews) {
        if ([subview isKindOfClass:[UICollectionView class]]) {
            mainCV = (UICollectionView *)subview;
            break;
        }
    }

    // Search one level deeper if not found
    if (!mainCV) {
        for (UIView *subview in vc.view.subviews) {
            for (UIView *child in subview.subviews) {
                if ([child isKindOfClass:[UICollectionView class]]) {
                    mainCV = (UICollectionView *)child;
                    break;
                }
            }
            if (mainCV) break;
        }
    }

    // Search even deeper (up to 4 levels)
    if (!mainCV) {
        NSMutableArray *queue = [vc.view.subviews mutableCopy];
        int depth = 0;
        while (queue.count > 0 && depth < 4 && !mainCV) {
            NSMutableArray *nextLevel = [NSMutableArray array];
            for (UIView *v in queue) {
                if ([v isKindOfClass:[UICollectionView class]]) {
                    mainCV = (UICollectionView *)v;
                    break;
                }
                [nextLevel addObjectsFromArray:v.subviews];
            }
            queue = nextLevel;
            depth++;
        }
    }

    // Create and inject the folder tab bar
    CGFloat tabHeight = [MSGChatFolderTabView preferredHeight];
    MSGChatFolderTabView *tabView = [[MSGChatFolderTabView alloc]
        initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width, tabHeight)];
    tabView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tabView.selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;

    objc_setAssociatedObject(self, kFolderTabViewKey, tabView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (mainCV) {
        // Store collection view reference
        objc_setAssociatedObject(self, kCollectionViewRefKey, mainCV, OBJC_ASSOCIATION_ASSIGN);

        // Insert tab bar above the collection view
        CGRect scrollFrame = mainCV.frame;
        CGFloat originalY = scrollFrame.origin.y;

        tabView.frame = CGRectMake(0, originalY, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];

        scrollFrame.origin.y += tabHeight;
        scrollFrame.size.height -= tabHeight;
        mainCV.frame = scrollFrame;

        CFLOG(@"Tab bar injected. CV class: %@, delegate: %@",
              NSStringFromClass([mainCV class]),
              NSStringFromClass([mainCV.delegate class]));

        // ── Hook the context menu on this collection view's delegate ──
        hookDelegateOnCollectionView(mainCV);

    } else {
        // Fallback: add at the top
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = vc.view.safeAreaInsets.top;
        }
        tabView.frame = CGRectMake(0, safeTop, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];
        CFLOG(@"Tab bar injected (fallback, no collection view found)");
    }

    [tabView reloadTabs];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Class Reconnaissance
// ═══════════════════════════════════════════════════════════

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

    IMP origIMP = method_getImplementation(method);
    if (outOriginalIMP) {
        *outOriginalIMP = origIMP;
    }

    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, originalSel, replacementIMP, types)) {
        CFLOG(@"Added method %@ to %@ (was inherited)", NSStringFromSelector(originalSel), NSStringFromClass(cls));
    } else {
        method_setImplementation(method, replacementIMP);
    }

    CFLOG(@"Swizzled %@ on %@", NSStringFromSelector(originalSel), NSStringFromClass(cls));
    return YES;
}

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

    // Run reconnaissance
    logMessengerClasses();

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
        swizzleMethod(inboxClass,
                      @selector(viewDidAppear:),
                      (IMP)hooked_inboxViewDidAppear,
                      (IMP *)&orig_inboxViewDidAppear);

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
        CFLOG(@"WARNING: No inbox view controller class found!");
        CFLOG(@"Check the reconnaissance log above for available classes.");
    }

    // Register assign mode overlay handler
    [[NSNotificationCenter defaultCenter]
        addObserverForName:MSGChatFoldersAssignModeChangedNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        MSGChatFolders_handleAssignModeChanged(note);
    }];
    CFLOG(@"Registered assign mode notification observer");

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
    UICollectionView *cv = objc_getAssociatedObject(self, kCollectionViewRefKey);
    if (cv) {
        [cv reloadData];
        CFLOG(@"Reloaded collection view for folder: %@", folderId);
    } else {
        // Search for any collection view in the VC
        for (UIView *sub in vc.view.subviews) {
            if ([sub isKindOfClass:[UICollectionView class]]) {
                [(UICollectionView *)sub reloadData];
                break;
            }
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
