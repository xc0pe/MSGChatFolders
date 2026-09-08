//
//  MSGChatFolderHooks.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Runtime hooks for Messenger's native UITableView conversation list.
//  1. Long-press on any chat -> "📁 Add to Folder" in native context menu
//  2. Swipe-left on any chat -> "📁 Folder" swipe action button
//  3. Folder tab bar at the top -> Filter conversations by folder
//  4. "📂" button -> Conversation picker sheet from visible chat rows
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import "MSGChatFolderManager.h"
#import "MSGChatFolderTabView.h"

// ═══════════════════════════════════════════════════════════
// MARK: - Logging & Keys
// ═══════════════════════════════════════════════════════════

#define CFLOG(fmt, ...) NSLog(@"[MSGChatFolders] " fmt, ##__VA_ARGS__)

static const void *kFolderTabViewKey     = &kFolderTabViewKey;
static const void *kFolderInitializedKey = &kFolderInitializedKey;
static const void *kTableDelegateHookKey = &kTableDelegateHookKey;
static const void *kCellRowModelKey      = &kCellRowModelKey;
static const void *kCellThreadKeyKey     = &kCellThreadKeyKey;
static const void *kCellTitleKey         = &kCellTitleKey;

// ═══════════════════════════════════════════════════════════
// MARK: - Forward Declarations
// ═══════════════════════════════════════════════════════════

static NSString *extractThreadKeyFromObject(id obj);
static NSString *extractTitleFromCell(UIView *cell);
static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey, NSString *chatTitle);
static UIViewController *findTopViewController(void);
static UIWindow *findAppWindow(void);
static UITableView *findConversationTableView(void);
static void hookTableViewDelegate(id delegate);

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note);

// ═══════════════════════════════════════════════════════════
// MARK: - Original IMPs
// ═══════════════════════════════════════════════════════════

static void (*orig_inboxViewDidAppear)(id self, SEL _cmd, BOOL animated);
static void (*orig_threadListViewDidAppear)(id self, SEL _cmd, BOOL animated);

// UITableViewDelegate IMPs
static UIContextMenuConfiguration *(*orig_tableContextMenu)(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip, CGPoint point);
static UISwipeActionsConfiguration *(*orig_tableTrailingSwipe)(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);
static CGFloat (*orig_tableHeightForRow)(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);
static void (*orig_tableWillDisplayCell)(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip);

// MSGThreadRowCell IMPs
static void (*orig_setRowModel)(id self, SEL _cmd, id rowModel, id mailbox, id mediaManager, id threadPresenceObserver, BOOL isForPrototypeCell, BOOL forceRefresh, BOOL isBulkEditing, BOOL shouldAnnounceNewMessage);
static void (*orig_setModel)(id self, SEL _cmd, id model, BOOL isForPrototypeCell, BOOL forceRefresh, BOOL isBulkEditing, BOOL shouldAnnounceNewMessage);

// ═══════════════════════════════════════════════════════════
// MARK: - Window & View Controller Utilities
// ═══════════════════════════════════════════════════════════

static UIWindow *findAppWindow(void) {
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
            if (window) break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    if (!window && [UIApplication sharedApplication].windows.count > 0) {
        window = [UIApplication sharedApplication].windows.firstObject;
    }
    return window;
}

static UIViewController *findTopViewController(void) {
    UIWindow *window = findAppWindow();
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

/// Finds the primary conversation UITableView (the tallest UITableView on screen)
static UITableView *findConversationTableView(void) {
    UIWindow *window = findAppWindow();
    if (!window) return nil;

    UITableView *bestTV = nil;
    CGFloat bestHeight = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window.rootViewController.view];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([v isKindOfClass:[UITableView class]] && v.window) {
            UITableView *tv = (UITableView *)v;
            // Ignore tiny accessory tables
            if (tv.frame.size.height > bestHeight && tv.frame.size.height > 150) {
                bestHeight = tv.frame.size.height;
                bestTV = tv;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return bestTV;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Data Extraction: Thread Key & Title
// ═══════════════════════════════════════════════════════════

/// Extracts threadKey from ANY object (cell, model, dictionary, etc.)
static NSString *extractThreadKeyFromObject(id obj) {
    if (!obj) return nil;

    // Check if cell already has threadKey attached via associated object
    NSString *cached = objc_getAssociatedObject(obj, kCellThreadKeyKey);
    if (cached.length > 0) return cached;

    // Strategy 1: Direct KVC for known property names
    NSArray *keys = @[
        @"threadKey", @"thread_key", @"threadFbId", @"threadFbid",
        @"threadPk", @"threadId", @"threadKeyNullable",
        @"threadKeyOrClientThreadPK", @"uniqueId", @"identifier", @"id"
    ];
    for (NSString *key in keys) {
        @try {
            id val = [obj valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                return (NSString *)val;
            }
            if ([val isKindOfClass:[NSNumber class]]) {
                long long num = [(NSNumber *)val longLongValue];
                if (num != 0) return [val stringValue];
            }
        } @catch (NSException *e) {}
    }

    // Strategy 2: Check attached or child sub-models
    id rowModel = objc_getAssociatedObject(obj, kCellRowModelKey);
    if (rowModel && rowModel != obj) {
        NSString *found = extractThreadKeyFromObject(rowModel);
        if (found) return found;
    }

    NSArray *subModelKeys = @[@"inboxModel", @"rowModel", @"model", @"thread", @"threadSummary", @"item", @"data"];
    for (NSString *subKey in subModelKeys) {
        @try {
            id sub = [obj valueForKey:subKey];
            if (sub && sub != obj) {
                // Check if sub itself has a threadKey property
                for (NSString *key in keys) {
                    @try {
                        id val = [sub valueForKey:key];
                        if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) return val;
                        if ([val isKindOfClass:[NSNumber class]]) {
                            long long num = [(NSNumber *)val longLongValue];
                            if (num != 0) return [val stringValue];
                        }
                    } @catch (NSException *e) {}
                }
            }
        } @catch (NSException *e) {}
    }

    // Strategy 3: Scan all ivars of obj (including primitive long long 'q')
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([obj class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!name || !type) continue;

            // Object ivar (@)
            if (type[0] == '@') {
                @try {
                    id val = object_getIvar(obj, ivars[i]);
                    if ([val isKindOfClass:[NSString class]]) {
                        NSString *s = (NSString *)val;
                        if ([s hasPrefix:@"t_"] || (s.length >= 7 && s.length <= 25 && [s longLongValue] > 0)) {
                            free(ivars);
                            return s;
                        }
                    } else if ([val isKindOfClass:[NSNumber class]]) {
                        long long ll = [(NSNumber *)val longLongValue];
                        if (ll > 10000) {
                            free(ivars);
                            return [val stringValue];
                        }
                    }
                } @catch (NSException *e) {}
            }
            // Primitive long long ivar ('q' or 'Q')
            else if (type[0] == 'q' || type[0] == 'Q') {
                NSString *ivarName = [NSString stringWithUTF8String:name];
                if ([ivarName rangeOfString:@"thread" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [ivarName rangeOfString:@"fbid" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [ivarName rangeOfString:@"key" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [ivarName rangeOfString:@"pk" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    ptrdiff_t offset = ivar_getOffset(ivars[i]);
                    long long val = *(long long *)((char *)(__bridge void *)obj + offset);
                    if (val > 10000) {
                        free(ivars);
                        return [NSString stringWithFormat:@"%lld", val];
                    }
                }
            }
        }
        free(ivars);
    }

    return nil;
}

/// Extracts title (person/group name) from a conversation cell
static NSString *extractTitleFromCell(UIView *cell) {
    if (!cell) return nil;

    NSString *cached = objc_getAssociatedObject(cell, kCellTitleKey);
    if (cached.length > 0) return cached;

    // Strategy 1: Look for subview with accessibilityIdentifier @"thread-row-title-label"
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([v.accessibilityIdentifier isEqualToString:@"thread-row-title-label"] && [v isKindOfClass:[UILabel class]]) {
            NSString *text = [(UILabel *)v text];
            if (text.length > 0) {
                objc_setAssociatedObject(cell, kCellTitleKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
                return text;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    // Strategy 2: Look for accessibilityLabel on the cell itself
    NSString *acc = cell.accessibilityLabel;
    if (acc.length > 0) {
        NSRange nl = [acc rangeOfString:@"\n"];
        if (nl.location != NSNotFound && nl.location > 0) {
            acc = [acc substringToIndex:nl.location];
        }
        NSRange comma = [acc rangeOfString:@","];
        if (comma.location != NSNotFound && comma.location > 0) {
            acc = [acc substringToIndex:comma.location];
        }
        if (acc.length > 0) {
            objc_setAssociatedObject(cell, kCellTitleKey, acc, OBJC_ASSOCIATION_COPY_NONATOMIC);
            return acc;
        }
    }

    // Strategy 3: Find largest UILabel in the cell (the contact name is usually biggest)
    UILabel *largestLabel = nil;
    CGFloat largestSize = 0;
    queue = [NSMutableArray arrayWithObject:cell];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            if (lbl.text.length > 0 && lbl.font.pointSize > largestSize) {
                largestSize = lbl.font.pointSize;
                largestLabel = lbl;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    if (largestLabel.text.length > 0) {
        objc_setAssociatedObject(cell, kCellTitleKey, largestLabel.text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return largestLabel.text;
    }

    return nil;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Folder Action Sheet & Menu Builders
// ═══════════════════════════════════════════════════════════

static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey, NSString *chatTitle) {
    if (!threadKey || !presenter) return;

    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];

    NSString *title = chatTitle.length > 0 ? [NSString stringWithFormat:@"📁 Folder: %@", chatTitle] : @"📁 Add to Folder";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:currentFolder ? [NSString stringWithFormat:@"Current folder: %@", currentFolder.name] : @"Not in any folder"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    // List all folders
    for (MSGChatFolder *folder in [mgr allFolders]) {
        NSString *itemTitle = folder.name;
        BOOL isCurrent = [folder.folderId isEqualToString:currentFolder.folderId];
        if (isCurrent) {
            itemTitle = [NSString stringWithFormat:@"✓ %@", folder.name];
        }

        UIAlertAction *action = [UIAlertAction
            actionWithTitle:itemTitle
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            if (isCurrent) {
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
            UITableView *tv = findConversationTableView();
            [tv reloadData];
        }];
        [alert addAction:action];
    }

    // "➕ Create New Folder"
    [alert addAction:[UIAlertAction
        actionWithTitle:@"➕ Create New Folder"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIAlertController *nameAlert = [UIAlertController
            alertControllerWithTitle:@"New Folder"
                             message:@"Enter a name for the new folder"
                      preferredStyle:UIAlertControllerStyleAlert];
        [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Folder name (e.g. Work, Family)";
            tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }];
        [nameAlert addAction:[UIAlertAction
            actionWithTitle:@"Create & Add"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a2) {
            NSString *name = nameAlert.textFields.firstObject.text;
            if (name.length > 0) {
                MSGChatFolder *newFolder = [mgr createFolderWithName:name];
                [mgr addThreadKey:threadKey toFolderId:newFolder.folderId];
                UITableView *tv = findConversationTableView();
                [tv reloadData];
            }
        }]];
        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:nameAlert animated:YES completion:nil];
    }]];

    // "❌ Remove from Folder"
    if (currentFolder) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"❌ Remove from Folder"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *a) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
            UITableView *tv = findConversationTableView();
            [tv reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(
            presenter.view.bounds.size.width / 2, presenter.view.bounds.size.height / 2, 0, 0);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

/// Builds a UIMenu containing folder actions to insert into Messenger's long-press context menu
static UIMenu *buildFolderMenu(NSString *threadKey, NSString *chatTitle) {
    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    // Existing folders
    for (MSGChatFolder *folder in [mgr allFolders]) {
        NSString *title = folder.name;
        UIImage *image = nil;
        BOOL isCurrent = [folder.folderId isEqualToString:currentFolder.folderId];

        if (isCurrent) {
            title = [NSString stringWithFormat:@"✓ %@", folder.name];
            image = [UIImage systemImageNamed:@"folder.fill"];
        } else {
            image = [UIImage systemImageNamed:@"folder"];
        }

        UIAction *action = [UIAction actionWithTitle:title
                                               image:image
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            if (isCurrent) {
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableView *tv = findConversationTableView();
                [tv reloadData];
            });
        }];
        [actions addObject:action];
    }

    // New folder action
    UIAction *createAction = [UIAction actionWithTitle:@"New Folder..."
                                                 image:[UIImage systemImageNamed:@"folder.badge.plus"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
            [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create & Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
                NSString *name = nameAlert.textFields.firstObject.text;
                if (name.length > 0) {
                    MSGChatFolder *f = [mgr createFolderWithName:name];
                    [mgr addThreadKey:threadKey toFolderId:f.folderId];
                    UITableView *tv = findConversationTableView();
                    [tv reloadData];
                }
            }]];
            [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:nameAlert animated:YES completion:nil];
        });
    }];
    [actions addObject:createAction];

    // Remove from folder action
    if (currentFolder) {
        UIAction *removeAction = [UIAction actionWithTitle:@"Remove from Folder"
                                                     image:[UIImage systemImageNamed:@"folder.badge.minus"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction *a) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableView *tv = findConversationTableView();
                [tv reloadData];
            });
        }];
        removeAction.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:removeAction];
    }

    NSString *menuTitle = currentFolder ? [NSString stringWithFormat:@"Folder: %@", currentFolder.name] : @"Add to Folder";
    return [UIMenu menuWithTitle:menuTitle
                           image:[UIImage systemImageNamed:@"folder"]
                      identifier:@"com.msgchatfolders.menu"
                         options:0
                        children:actions];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hooked UITableViewDelegate Methods
// ═══════════════════════════════════════════════════════════

/// Context Menu (Long Press): Adds "📁 Add to Folder" to Messenger's native menu
static UIContextMenuConfiguration *hooked_tableContextMenu(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath, CGPoint point) {
    UIContextMenuConfiguration *original = nil;
    if (orig_tableContextMenu) {
        original = orig_tableContextMenu(self, _cmd, tableView, indexPath, point);
    }

    // Get the cell at this indexPath
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *threadKey = extractThreadKeyFromObject(cell);

    // Fallback: Check _inboxRows array on the delegate (MSGThreadListViewController)
    if (!threadKey && [self respondsToSelector:@selector(valueForKey:)]) {
        @try {
            NSArray *rows = [self valueForKey:@"_inboxRows"];
            if (rows && indexPath.row < (NSInteger)rows.count) {
                threadKey = extractThreadKeyFromObject(rows[indexPath.row]);
            }
        } @catch (NSException *e) {}
    }

    NSString *title = extractTitleFromCell(cell);
    CFLOG(@"ContextMenu at row %ld: threadKey=%@, title='%@'", (long)indexPath.row, threadKey, title);

    if (!threadKey) return original;

    UIMenu *folderMenu = buildFolderMenu(threadKey, title);

    if (original) {
        // Extract original providers
        UIContextMenuActionProvider origActionProvider = nil;
        Ivar actionIvar = class_getInstanceVariable([UIContextMenuConfiguration class], "_actionProvider");
        if (actionIvar) {
            origActionProvider = (__bridge UIContextMenuActionProvider)((__bridge void *)object_getIvar(original, actionIvar));
        }
        if (!origActionProvider) {
            @try { origActionProvider = [original valueForKey:@"_actionProvider"]; } @catch (NSException *e) {}
        }

        UIContextMenuContentPreviewProvider origPreview = nil;
        Ivar previewIvar = class_getInstanceVariable([UIContextMenuConfiguration class], "_previewProvider");
        if (previewIvar) {
            origPreview = (__bridge UIContextMenuContentPreviewProvider)((__bridge void *)object_getIvar(original, previewIvar));
        }

        UIContextMenuActionProvider wrappedProvider = ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            UIMenu *origMenu = origActionProvider ? origActionProvider(suggested) : nil;
            if (origMenu) {
                NSMutableArray *children = [origMenu.children mutableCopy];
                UIMenu *section = [UIMenu menuWithTitle:@""
                                                  image:nil
                                             identifier:@"com.msgchatfolders.section"
                                                options:UIMenuOptionsDisplayInline
                                               children:@[folderMenu]];
                [children addObject:section];
                return [origMenu menuByReplacingChildren:children];
            }
            return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
        };

        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:origPreview
                                                        actionProvider:wrappedProvider];
    } else {
        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:nil
                                                        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
        }];
    }
}

/// Swipe Action (Swipe Left): Adds "📁 Folder" button
static UISwipeActionsConfiguration *hooked_tableTrailingSwipe(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UISwipeActionsConfiguration *original = nil;
    if (orig_tableTrailingSwipe) {
        original = orig_tableTrailingSwipe(self, _cmd, tableView, indexPath);
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *threadKey = extractThreadKeyFromObject(cell);
    if (!threadKey && [self respondsToSelector:@selector(valueForKey:)]) {
        @try {
            NSArray *rows = [self valueForKey:@"_inboxRows"];
            if (rows && indexPath.row < (NSInteger)rows.count) {
                threadKey = extractThreadKeyFromObject(rows[indexPath.row]);
            }
        } @catch (NSException *e) {}
    }

    if (!threadKey) return original;

    NSString *title = extractTitleFromCell(cell);

    UIContextualAction *folderAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"📁 Folder"
                          handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        UIViewController *topVC = findTopViewController();
        if (topVC) {
            presentFolderActionSheet(topVC, threadKey, title);
        }
        completionHandler(YES);
    }];
    folderAction.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    folderAction.image = [UIImage systemImageNamed:@"folder"];

    NSMutableArray *actions = [NSMutableArray array];
    if (original.actions) {
        [actions addObjectsFromArray:original.actions];
    }
    [actions addObject:folderAction];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:actions];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

/// Row Height: Collapses rows that do not belong to the selected folder
static CGFloat hooked_tableHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSString *selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;

    // "All" tab -> normal height
    if (!selectedFolderId || [selectedFolderId isEqualToString:@"all"]) {
        if (orig_tableHeightForRow) {
            return orig_tableHeightForRow(self, _cmd, tableView, indexPath);
        }
        return UITableViewAutomaticDimension;
    }

    // Specific folder is active
    NSString *threadKey = nil;
    @try {
        NSArray *rows = [self valueForKey:@"_inboxRows"];
        if (rows && indexPath.row < (NSInteger)rows.count) {
            threadKey = extractThreadKeyFromObject(rows[indexPath.row]);
        }
    } @catch (NSException *e) {}

    if (!threadKey) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell) threadKey = extractThreadKeyFromObject(cell);
    }

    if (threadKey) {
        MSGChatFolder *folder = [[MSGChatFolderManager sharedManager] folderForThreadKey:threadKey];
        if ([folder.folderId isEqualToString:selectedFolderId]) {
            if (orig_tableHeightForRow) {
                return orig_tableHeightForRow(self, _cmd, tableView, indexPath);
            }
            return UITableViewAutomaticDimension;
        } else {
            // Not in this folder -> collapse row completely!
            return 0.001f;
        }
    }

    if (orig_tableHeightForRow) {
        return orig_tableHeightForRow(self, _cmd, tableView, indexPath);
    }
    return UITableViewAutomaticDimension;
}

/// Cell Display: Hides collapsed cells
static void hooked_tableWillDisplayCell(id self, SEL _cmd, UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (orig_tableWillDisplayCell) {
        orig_tableWillDisplayCell(self, _cmd, tableView, cell, indexPath);
    }

    NSString *selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;
    if (selectedFolderId && ![selectedFolderId isEqualToString:@"all"]) {
        NSString *threadKey = extractThreadKeyFromObject(cell);
        if (!threadKey && [self respondsToSelector:@selector(valueForKey:)]) {
            @try {
                NSArray *rows = [self valueForKey:@"_inboxRows"];
                if (rows && indexPath.row < (NSInteger)rows.count) {
                    threadKey = extractThreadKeyFromObject(rows[indexPath.row]);
                }
            } @catch (NSException *e) {}
        }

        if (threadKey) {
            MSGChatFolder *folder = [[MSGChatFolderManager sharedManager] folderForThreadKey:threadKey];
            if (![folder.folderId isEqualToString:selectedFolderId]) {
                cell.hidden = YES;
                cell.clipsToBounds = YES;
                return;
            }
        }
    }
    cell.hidden = NO;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hooked MSGThreadRowCell Methods
// ═══════════════════════════════════════════════════════════

static void hooked_setRowModel(id self, SEL _cmd, id rowModel, id mailbox, id mediaManager, id threadPresenceObserver, BOOL isForPrototypeCell, BOOL forceRefresh, BOOL isBulkEditing, BOOL shouldAnnounceNewMessage) {
    if (orig_setRowModel) {
        orig_setRowModel(self, _cmd, rowModel, mailbox, mediaManager, threadPresenceObserver, isForPrototypeCell, forceRefresh, isBulkEditing, shouldAnnounceNewMessage);
    }

    if (rowModel && self) {
        objc_setAssociatedObject(self, kCellRowModelKey, rowModel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *tk = extractThreadKeyFromObject(rowModel);
        if (tk) {
            objc_setAssociatedObject(self, kCellThreadKeyKey, tk, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
}

static void hooked_setModel(id self, SEL _cmd, id model, BOOL isForPrototypeCell, BOOL forceRefresh, BOOL isBulkEditing, BOOL shouldAnnounceNewMessage) {
    if (orig_setModel) {
        orig_setModel(self, _cmd, model, isForPrototypeCell, forceRefresh, isBulkEditing, shouldAnnounceNewMessage);
    }

    if (model && self) {
        objc_setAssociatedObject(self, kCellRowModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *tk = extractThreadKeyFromObject(model);
        if (tk) {
            objc_setAssociatedObject(self, kCellThreadKeyKey, tk, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Dynamic Delegate Hooking
// ═══════════════════════════════════════════════════════════

static void hookTableViewDelegate(id delegate) {
    if (!delegate) return;
    Class cls = [delegate class];

    NSNumber *hooked = objc_getAssociatedObject(cls, kTableDelegateHookKey);
    if ([hooked boolValue]) return;
    objc_setAssociatedObject(cls, kTableDelegateHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CFLOG(@"Hooking UITableViewDelegate on %@", NSStringFromClass(cls));

    // 1. Context Menu Configuration
    SEL ctxSel = @selector(tableView:contextMenuConfigurationForRowAtIndexPath:point:);
    Method m = class_getInstanceMethod(cls, ctxSel);
    if (m) {
        orig_tableContextMenu = (UIContextMenuConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *, CGPoint))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tableContextMenu);
        CFLOG(@"✅ Hooked tableView:contextMenuConfigurationForRowAtIndexPath:point:");
    } else {
        class_addMethod(cls, ctxSel, (IMP)hooked_tableContextMenu, "@:@@{CGPoint=dd}");
        CFLOG(@"✅ Added tableView:contextMenuConfigurationForRowAtIndexPath:point:");
    }

    // 2. Trailing Swipe Actions
    SEL swipeSel = @selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:);
    m = class_getInstanceMethod(cls, swipeSel);
    if (m) {
        orig_tableTrailingSwipe = (UISwipeActionsConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tableTrailingSwipe);
        CFLOG(@"✅ Hooked tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:");
    } else {
        class_addMethod(cls, swipeSel, (IMP)hooked_tableTrailingSwipe, "@:@@");
        CFLOG(@"✅ Added tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:");
    }

    // 3. Height for row (for folder filtering)
    SEL heightSel = @selector(tableView:heightForRowAtIndexPath:);
    m = class_getInstanceMethod(cls, heightSel);
    if (m) {
        orig_tableHeightForRow = (CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tableHeightForRow);
        CFLOG(@"✅ Hooked tableView:heightForRowAtIndexPath:");
    } else {
        class_addMethod(cls, heightSel, (IMP)hooked_tableHeightForRow, "d@:@@");
        CFLOG(@"✅ Added tableView:heightForRowAtIndexPath:");
    }

    // 4. Will display cell
    SEL willDisplaySel = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
    m = class_getInstanceMethod(cls, willDisplaySel);
    if (m) {
        orig_tableWillDisplayCell = (void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tableWillDisplayCell);
        CFLOG(@"✅ Hooked tableView:willDisplayCell:forRowAtIndexPath:");
    } else {
        class_addMethod(cls, willDisplaySel, (IMP)hooked_tableWillDisplayCell, "v@:@@@");
        CFLOG(@"✅ Added tableView:willDisplayCell:forRowAtIndexPath:");
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Conversation Picker (📂 Button)
// ═══════════════════════════════════════════════════════════

static void MSGChatFolders_showConversationPicker(void) {
    CFLOG(@"Opening conversation picker from UITableView...");

    UITableView *tableView = findConversationTableView();
    if (!tableView) {
        CFLOG(@"No conversation UITableView found!");
        UIViewController *topVC = findTopViewController();
        UIAlertController *err = [UIAlertController
            alertControllerWithTitle:@"No Conversations Table Found"
                             message:@"Could not find the conversation list. Make sure you are on the Chats tab."
                      preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [topVC presentViewController:err animated:YES completion:nil];
        return;
    }

    // Ensure delegate is hooked
    hookTableViewDelegate(tableView.delegate);

    NSMutableArray<NSDictionary *> *conversations = [NSMutableArray array];
    NSArray *rows = nil;
    if ([tableView.delegate respondsToSelector:@selector(valueForKey:)]) {
        @try { rows = [(id)tableView.delegate valueForKey:@"_inboxRows"]; } @catch (NSException *e) {}
    }

    // Read visible cells from the REAL conversation table
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell.frame.size.height < 30) continue;

        NSString *title = extractTitleFromCell(cell);
        NSString *threadKey = extractThreadKeyFromObject(cell);

        if (!threadKey && rows) {
            NSIndexPath *ip = [tableView indexPathForCell:cell];
            if (ip && ip.row < (NSInteger)rows.count) {
                threadKey = extractThreadKeyFromObject(rows[ip.row]);
            }
        }

        if (title.length > 0 || threadKey.length > 0) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"title"] = title.length > 0 ? title : [NSString stringWithFormat:@"Chat %@", threadKey ?: @""];
            if (threadKey) info[@"threadKey"] = threadKey;

            MSGChatFolder *folder = [[MSGChatFolderManager sharedManager] folderForThreadKey:threadKey];
            if (folder) info[@"folder"] = folder.name;

            [conversations addObject:info];
        }
    }

    UIViewController *topVC = findTopViewController();
    if (!topVC) return;

    if (conversations.count == 0) {
        UIAlertController *empty = [UIAlertController
            alertControllerWithTitle:@"No Conversations Found"
                             message:@"Please scroll your chats once and try tapping 📂 again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [topVC presentViewController:empty animated:YES completion:nil];
        return;
    }

    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:@"📂 Pick a Conversation"
                         message:@"Select a conversation to assign to a folder"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *info in conversations) {
        NSString *title = info[@"title"];
        NSString *threadKey = info[@"threadKey"];
        NSString *folderName = info[@"folder"];

        NSString *display = title;
        if (folderName) {
            display = [NSString stringWithFormat:@"%@ [📁 %@]", title, folderName];
        }

        UIAlertAction *action = [UIAlertAction
            actionWithTitle:display
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            if (threadKey) {
                presentFolderActionSheet(topVC, threadKey, title);
            } else {
                UIAlertController *err = [UIAlertController
                    alertControllerWithTitle:@"Thread Key Missing"
                                     message:[NSString stringWithFormat:@"Could not determine the internal ID for '%@'.", title]
                              preferredStyle:UIAlertControllerStyleAlert];
                [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [topVC presentViewController:err animated:YES completion:nil];
            }
        }];
        [picker addAction:action];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (picker.popoverPresentationController) {
        picker.popoverPresentationController.sourceView = topVC.view;
        picker.popoverPresentationController.sourceRect = CGRectMake(
            topVC.view.bounds.size.width / 2, 60, 0, 0);
    }

    [topVC presentViewController:picker animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Folder Tab Bar Injection & View Handling
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
                         message:[NSString stringWithFormat:@"%lu conversations", (unsigned long)folder.threadKeys.count]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"✏️ Rename Folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIAlertController *rename = [UIAlertController
            alertControllerWithTitle:@"Rename Folder" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [rename addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = folder.name;
        }];
        [rename addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
            NSString *n = rename.textFields.firstObject.text;
            if (n.length > 0) {
                [mgr renameFolderWithId:folderId toName:n];
                UITableView *tv = findConversationTableView();
                [tv reloadData];
            }
        }]];
        [rename addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:rename animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"🗑 Delete Folder" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        UIAlertController *confirm = [UIAlertController
            alertControllerWithTitle:@"Delete Folder?"
                             message:[NSString stringWithFormat:@"Delete \"%@\"? Conversations will not be deleted.", folder.name]
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a2) {
            [mgr deleteFolderWithId:folderId];
            UITableView *tv = findConversationTableView();
            [tv reloadData];
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:confirm animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void injectFolderTabBarIntoVC(UIViewController *vc) {
    if (!vc || !vc.view) return;

    NSNumber *initialized = objc_getAssociatedObject(vc, kFolderInitializedKey);
    if ([initialized boolValue]) {
        MSGChatFolderTabView *tabView = objc_getAssociatedObject(vc, kFolderTabViewKey);
        [tabView reloadTabs];
        return;
    }
    objc_setAssociatedObject(vc, kFolderInitializedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CFLOG(@"Injecting folder tab bar into %@", NSStringFromClass([vc class]));

    CGFloat tabHeight = [MSGChatFolderTabView preferredHeight];
    MSGChatFolderTabView *tabView = [[MSGChatFolderTabView alloc]
        initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width, tabHeight)];
    tabView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tabView.selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;

    objc_setAssociatedObject(vc, kFolderTabViewKey, tabView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Look for UITableView or UICollectionView to position above
    UIView *targetScroll = nil;
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UITableView class]] || [sub isKindOfClass:[UICollectionView class]]) {
            targetScroll = sub;
            break;
        }
    }

    if (targetScroll) {
        CGRect sf = targetScroll.frame;
        tabView.frame = CGRectMake(0, sf.origin.y, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];

        sf.origin.y += tabHeight;
        sf.size.height -= tabHeight;
        targetScroll.frame = sf;
    } else {
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = vc.view.safeAreaInsets.top;
        }
        tabView.frame = CGRectMake(0, safeTop, vc.view.bounds.size.width, tabHeight);
        [vc.view addSubview:tabView];
    }

    [tabView reloadTabs];

    // Find table view and hook its delegate
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableView *tv = findConversationTableView();
        if (tv) {
            hookTableViewDelegate(tv.delegate);
        }
    });
}

static void hooked_inboxViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_inboxViewDidAppear) orig_inboxViewDidAppear(self, _cmd, animated);
    injectFolderTabBarIntoVC((UIViewController *)self);
}

static void hooked_threadListViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_threadListViewDidAppear) orig_threadListViewDidAppear(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;
    UITableView *tv = nil;
    if ([vc respondsToSelector:@selector(tableView)]) {
        @try { tv = [vc valueForKey:@"tableView"]; } @catch (NSException *e) {}
    }
    if (!tv && [vc.view isKindOfClass:[UITableView class]]) {
        tv = (UITableView *)vc.view;
    }
    if (tv) {
        hookTableViewDelegate(tv.delegate ?: self);
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Tab View Delegate Notification Callbacks
// ═══════════════════════════════════════════════════════════

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;
    [[MSGChatFolderManager sharedManager] setSelectedFolderId:folderId];

    UITableView *tv = findConversationTableView();
    if (tv) {
        [tv reloadData];
        CFLOG(@"Filter changed to folder: %@, reloaded table", folderId);
    }
}

static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note) {
    UIViewController *vc = (UIViewController *)self;
    UIAlertController *nameAlert = [UIAlertController
        alertControllerWithTitle:@"New Folder"
                         message:@"Enter a name for the folder"
                  preferredStyle:UIAlertControllerStyleAlert];
    [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name (e.g. Work, Uni, Friends)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = nameAlert.textFields.firstObject.text;
        if (name.length > 0) {
            [[MSGChatFolderManager sharedManager] createFolderWithName:name];
            UITableView *tv = findConversationTableView();
            [tv reloadData];
        }
    }]];
    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:nameAlert animated:YES completion:nil];
}

static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;
    handleFolderTabLongPress((UIViewController *)self, folderId);
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hook Registration Entry
// ═══════════════════════════════════════════════════════════

static BOOL swizzle(Class cls, SEL sel, IMP newIMP, IMP *outOrig) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newIMP);
    CFLOG(@"Swizzled %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
    return YES;
}

static void addMethodIfMissing(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls) return;
    class_addMethod(cls, sel, imp, types);
}

void MSGChatFolders_RegisterHooks(void) {
    CFLOG(@"Registering MSGChatFolders hooks...");

    // 1. Hook MSGThreadRowCell model setters to capture threadKey
    Class cellClass = NSClassFromString(@"MSGThreadRowCell");
    if (cellClass) {
        SEL setRowModelSel = @selector(setRowModel:mailbox:mediaManager:threadPresenceObserver:isForPrototypeCell:forceRefresh:isBulkEditing:shouldAnnounceNewMessage:);
        swizzle(cellClass, setRowModelSel, (IMP)hooked_setRowModel, (IMP *)&orig_setRowModel);

        SEL setModelSel = @selector(setModel:isForPrototypeCell:forceRefresh:isBulkEditing:shouldAnnounceNewMessage:);
        swizzle(cellClass, setModelSel, (IMP)hooked_setModel, (IMP *)&orig_setModel);
        CFLOG(@"Hooked MSGThreadRowCell model setters");
    }

    // 2. Hook MSGThreadListViewController viewDidAppear and its delegate methods
    Class threadListClass = NSClassFromString(@"MSGThreadListViewController");
    if (threadListClass) {
        swizzle(threadListClass, @selector(viewDidAppear:), (IMP)hooked_threadListViewDidAppear, (IMP *)&orig_threadListViewDidAppear);
        hookTableViewDelegate((id)threadListClass);
    }

    // 3. Hook LSTableViewController (superclass)
    Class lsTableClass = NSClassFromString(@"LSTableViewController");
    if (lsTableClass) {
        hookTableViewDelegate((id)lsTableClass);
    }

    // 4. Hook MSGInboxViewController (parent container)
    Class inboxClass = NSClassFromString(@"MSGInboxViewController");
    if (inboxClass) {
        swizzle(inboxClass, @selector(viewDidAppear:), (IMP)hooked_inboxViewDidAppear, (IMP *)&orig_inboxViewDidAppear);

        addMethodIfMissing(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidSelect:"), (IMP)msgcf_folderTabDidSelect, "v@:@");
        addMethodIfMissing(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidCreate:"), (IMP)msgcf_folderTabDidCreate, "v@:@");
        addMethodIfMissing(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidLongPress:"), (IMP)msgcf_folderTabDidLongPress, "v@:@");
    }

    // 5. Register 📂 conversation picker notification observer
    [[NSNotificationCenter defaultCenter]
        addObserverForName:MSGChatFoldersShowPickerNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        MSGChatFolders_showConversationPicker();
    }];

    CFLOG(@"MSGChatFolders hooks successfully registered!");
}
