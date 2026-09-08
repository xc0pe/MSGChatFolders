//
//  MSGChatFolderHooks.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Universal hooks supporting BOTH UITableView and UICollectionView.
//  1. Long-press on any chat -> "📁 Add to Folder"
//  2. Swipe-left on any chat -> "📁 Folder" button
//  3. Top folder tab bar -> Locked smoothly below nav bar, no jumping
//  4. "📂" button -> Conversation picker (active users excluded by width >= 240pt)
//  5. In-chat safety guard -> NEVER filters or touches message bubbles, photos, or media
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import "MSGChatFolderManager.h"
#import "MSGChatFolderTabView.h"

#define CFLOG(fmt, ...) NSLog(@"[MSGChatFolders] " fmt, ##__VA_ARGS__)

static const void *kFolderTabViewKey       = &kFolderTabViewKey;
static const void *kDelegateHookedKey      = &kDelegateHookedKey;
static const void *kCellThreadKeyKey       = &kCellThreadKeyKey;
static const void *kCellTitleKey           = &kCellTitleKey;
static const void *kCellGestureAttachedKey = &kCellGestureAttachedKey;

// ═══════════════════════════════════════════════════════════
// MARK: - Forward Declarations
// ═══════════════════════════════════════════════════════════

static BOOL isInboxViewController(id controller);
static NSString *extractThreadKeyFromObject(id obj);
static NSString *extractTitleFromCell(UIView *cell);
static NSString *getBestIdentifierForCell(UIView *cell, NSString **outTitle);
static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey, NSString *chatTitle);
static UIViewController *findTopViewController(void);
static UIWindow *findAppWindow(void);
static void hookScrollDelegate(id delegate);
static void layoutFolderTabBarInVC(UIViewController *vc);

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note);
static void msgcf_folderTabDidLongPress(id self, SEL _cmd, NSNotification *note);

// ═══════════════════════════════════════════════════════════
// MARK: - Original Method Pointers
// ═══════════════════════════════════════════════════════════

static void (*orig_inboxViewDidAppear)(id self, SEL _cmd, BOOL animated);
static void (*orig_inboxViewDidLayoutSubviews)(id self, SEL _cmd);

// UITableView delegate IMPs
static UIContextMenuConfiguration *(*orig_tvContextMenu)(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip, CGPoint point);
static UISwipeActionsConfiguration *(*orig_tvTrailingSwipe)(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);
static CGFloat (*orig_tvHeightForRow)(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);
static void (*orig_tvWillDisplayCell)(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip);

// UICollectionView delegate IMPs
static UIContextMenuConfiguration *(*orig_cvContextMenu)(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *ip, CGPoint point);
static void (*orig_cvWillDisplayCell)(id self, SEL _cmd, UICollectionView *cv, UICollectionViewCell *cell, NSIndexPath *ip);

// ═══════════════════════════════════════════════════════════
// MARK: - Inbox Safety Guard
// ═══════════════════════════════════════════════════════════

/// Checks if the controller is strictly an inbox/conversation list controller.
/// Returns NO for any inside-chat screens (MSGMessageListViewController, media viewers, etc.)
static BOOL isInboxViewController(id controller) {
    if (!controller) return NO;
    NSString *cls = NSStringFromClass([controller class]);

    // Explicitly reject any inside-conversation view controllers
    if ([cls containsString:@"Message"] ||
        [cls containsString:@"Conversation"] ||
        [cls containsString:@"ThreadView"] ||
        [cls containsString:@"ChatView"] ||
        [cls containsString:@"MediaViewer"] ||
        [cls containsString:@"Photo"] ||
        [cls containsString:@"Story"]) {
        return NO;
    }

    // Explicitly accept inbox controllers
    if ([cls containsString:@"Inbox"] ||
        [cls containsString:@"ThreadList"] ||
        [cls containsString:@"LSTable"]) {
        return YES;
    }

    return NO;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Window & View Hierarchy
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

// ═══════════════════════════════════════════════════════════
// MARK: - Title & Identifier Extraction
// ═══════════════════════════════════════════════════════════

static NSString *extractTitleFromCell(UIView *cell) {
    if (!cell) return nil;

    NSString *cached = objc_getAssociatedObject(cell, kCellTitleKey);
    if (cached.length > 0) return cached;

    // Strategy 1: Messenger specific accessibilityIdentifier
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([v.accessibilityIdentifier isEqualToString:@"thread-row-title-label"] && [v isKindOfClass:[UILabel class]]) {
            NSString *t = [(UILabel *)v text];
            if (t.length > 0) {
                objc_setAssociatedObject(cell, kCellTitleKey, t, OBJC_ASSOCIATION_COPY_NONATOMIC);
                return t;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    // Strategy 2: Cell accessibilityLabel (before comma or newline)
    NSString *acc = cell.accessibilityLabel;
    if (acc.length > 0) {
        NSRange nl = [acc rangeOfString:@"\n"];
        if (nl.location != NSNotFound && nl.location > 0) acc = [acc substringToIndex:nl.location];
        NSRange comma = [acc rangeOfString:@","];
        if (comma.location != NSNotFound && comma.location > 0) acc = [acc substringToIndex:comma.location];
        if (acc.length > 0 && acc.length < 60) {
            objc_setAssociatedObject(cell, kCellTitleKey, acc, OBJC_ASSOCIATION_COPY_NONATOMIC);
            return acc;
        }
    }

    // Strategy 3: Largest UILabel in cell
    UILabel *largest = nil;
    CGFloat maxSize = 0;
    queue = [NSMutableArray arrayWithObject:cell];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            if (lbl.text.length > 0 && lbl.font.pointSize > maxSize) {
                maxSize = lbl.font.pointSize;
                largest = lbl;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    if (largest.text.length > 0) {
        objc_setAssociatedObject(cell, kCellTitleKey, largest.text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return largest.text;
    }

    return nil;
}

static NSString *extractThreadKeyFromObject(id obj) {
    if (!obj) return nil;

    NSString *cached = objc_getAssociatedObject(obj, kCellThreadKeyKey);
    if (cached.length > 0) return cached;

    NSArray *keys = @[
        @"threadKey", @"thread_key", @"threadFbId", @"threadFbid",
        @"threadPk", @"threadId", @"threadKeyNullable",
        @"threadKeyOrClientThreadPK", @"uniqueId", @"identifier", @"id"
    ];

    // Direct KVC
    for (NSString *k in keys) {
        @try {
            id val = [obj valueForKey:k];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) return (NSString *)val;
            if ([val isKindOfClass:[NSNumber class]] && [(NSNumber *)val longLongValue] != 0) return [val stringValue];
        } @catch (NSException *e) {}
    }

    // Sub-models
    NSArray *subKeys = @[@"inboxModel", @"rowModel", @"model", @"thread", @"threadSummary", @"item", @"data"];
    for (NSString *sk in subKeys) {
        @try {
            id sub = [obj valueForKey:sk];
            if (sub && sub != obj) {
                for (NSString *k in keys) {
                    @try {
                        id val = [sub valueForKey:k];
                        if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) return val;
                        if ([val isKindOfClass:[NSNumber class]] && [(NSNumber *)val longLongValue] != 0) return [val stringValue];
                    } @catch (NSException *e) {}
                }
            }
        } @catch (NSException *e) {}
    }

    // Ivars scan
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([obj class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!name || !type) continue;

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
            } else if (type[0] == 'q' || type[0] == 'Q') {
                NSString *inName = [NSString stringWithUTF8String:name];
                if ([inName rangeOfString:@"thread" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [inName rangeOfString:@"fbid" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [inName rangeOfString:@"key" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [inName rangeOfString:@"pk" options:NSCaseInsensitiveSearch].location != NSNotFound) {
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

static NSString *getBestIdentifierForCell(UIView *cell, NSString **outTitle) {
    NSString *title = extractTitleFromCell(cell);
    if (outTitle) *outTitle = title;

    NSString *key = extractThreadKeyFromObject(cell);
    if (key.length > 0) return key;

    // Fail-safe: Use sanitized contact name as stable identifier
    if (title.length > 0) {
        return [NSString stringWithFormat:@"chat_%@", title];
    }
    return nil;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Reload All Chat Views
// ═══════════════════════════════════════════════════════════

static void reloadAllChatViews(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = findAppWindow();
        if (!window) return;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window.rootViewController.view];
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:[UITableView class]]) {
                [(UITableView *)v reloadData];
            } else if ([v isKindOfClass:[UICollectionView class]]) {
                if (![v.superview isKindOfClass:[MSGChatFolderTabView class]]) {
                    [(UICollectionView *)v reloadData];
                }
            }
            [queue addObjectsFromArray:v.subviews];
        }
    });
}

// ═══════════════════════════════════════════════════════════
// MARK: - Folder Action Sheet & Menu
// ═══════════════════════════════════════════════════════════

static void presentFolderActionSheet(UIViewController *presenter, NSString *threadKey, NSString *chatTitle) {
    if (!threadKey || !presenter) return;

    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];

    NSString *sheetTitle = chatTitle.length > 0 ? [NSString stringWithFormat:@"📁 Folder: %@", chatTitle] : @"📁 Add to Folder";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:sheetTitle
                         message:currentFolder ? [NSString stringWithFormat:@"Currently in: %@", currentFolder.name] : @"Not in any folder"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (MSGChatFolder *folder in [mgr allFolders]) {
        NSString *itemTitle = folder.name;
        BOOL isCurrent = [folder.folderId isEqualToString:currentFolder.folderId];
        if (isCurrent) itemTitle = [NSString stringWithFormat:@"✓ %@", folder.name];

        UIAlertAction *act = [UIAlertAction
            actionWithTitle:itemTitle
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            if (isCurrent) {
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
            reloadAllChatViews();
        }];
        [alert addAction:act];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:@"➕ Create New Folder"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
        UIAlertController *nameAlert = [UIAlertController
            alertControllerWithTitle:@"New Folder"
                             message:@"Enter folder name"
                      preferredStyle:UIAlertControllerStyleAlert];
        [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Folder name (e.g. Work, Family)";
            tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }];
        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create & Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
            NSString *n = nameAlert.textFields.firstObject.text;
            if (n.length > 0) {
                MSGChatFolder *nf = [mgr createFolderWithName:n];
                [mgr addThreadKey:threadKey toFolderId:nf.folderId];
                reloadAllChatViews();
            }
        }]];
        [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:nameAlert animated:YES completion:nil];
    }]];

    if (currentFolder) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"❌ Remove from Folder"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *a) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
            reloadAllChatViews();
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

static UIMenu *buildFolderMenu(NSString *threadKey, NSString *chatTitle) {
    MSGChatFolderManager *mgr = [MSGChatFolderManager sharedManager];
    MSGChatFolder *currentFolder = [mgr folderForThreadKey:threadKey];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

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

        UIAction *action = [UIAction actionWithTitle:title image:image identifier:nil handler:^(__kindof UIAction *a) {
            if (isCurrent) {
                [mgr removeThreadKey:threadKey fromFolderId:folder.folderId];
            } else {
                [mgr addThreadKey:threadKey toFolderId:folder.folderId];
            }
            reloadAllChatViews();
        }];
        [actions addObject:action];
    }

    UIAction *createAction = [UIAction actionWithTitle:@"New Folder..." image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(__kindof UIAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *topVC = findTopViewController();
            if (!topVC) return;
            UIAlertController *nameAlert = [UIAlertController
                alertControllerWithTitle:@"New Folder" message:@"Enter folder name" preferredStyle:UIAlertControllerStyleAlert];
            [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                tf.placeholder = @"Folder name";
                tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
            }];
            [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create & Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
                NSString *n = nameAlert.textFields.firstObject.text;
                if (n.length > 0) {
                    MSGChatFolder *f = [mgr createFolderWithName:n];
                    [mgr addThreadKey:threadKey toFolderId:f.folderId];
                    reloadAllChatViews();
                }
            }]];
            [nameAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:nameAlert animated:YES completion:nil];
        });
    }];
    [actions addObject:createAction];

    if (currentFolder) {
        UIAction *remAction = [UIAction actionWithTitle:@"Remove from Folder" image:[UIImage systemImageNamed:@"folder.badge.minus"] identifier:nil handler:^(__kindof UIAction *a) {
            [mgr removeThreadKeyFromAllFolders:threadKey];
            reloadAllChatViews();
        }];
        remAction.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:remAction];
    }

    NSString *menuTitle = currentFolder ? [NSString stringWithFormat:@"Folder: %@", currentFolder.name] : @"Add to Folder";
    return [UIMenu menuWithTitle:menuTitle image:[UIImage systemImageNamed:@"folder"] identifier:@"com.msgchatfolders.menu" options:0 children:actions];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Direct Cell Long-Press Fallback Gesture
// ═══════════════════════════════════════════════════════════

static void handleCellLongPressGesture(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIView *cell = gesture.view;
    NSString *title = nil;
    NSString *threadKey = getBestIdentifierForCell(cell, &title);
    if (!threadKey) return;

    UIViewController *topVC = findTopViewController();
    if (topVC) {
        presentFolderActionSheet(topVC, threadKey, title);
    }
}

static void attachGestureToCellIfNeeded(UIView *cell) {
    if (!cell) return;
    // Strictly conversation rows (width >= 240)
    if (cell.bounds.size.width < 240) return;

    NSNumber *attached = objc_getAssociatedObject(cell, kCellGestureAttachedKey);
    if ([attached boolValue]) return;
    objc_setAssociatedObject(cell, kCellGestureAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:cell action:@selector(msgcf_handleLongPress:)];
    lp.minimumPressDuration = 0.45;

    class_addMethod([cell class], NSSelectorFromString(@"msgcf_handleLongPress:"),
                    (IMP)handleCellLongPressGesture, "v@:@");
    [cell addGestureRecognizer:lp];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Hooked Table & Collection View Delegate Methods
// ═══════════════════════════════════════════════════════════

static UIContextMenuConfiguration *hooked_tvContextMenu(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath, CGPoint point) {
    // Safety guard: only execute in inbox!
    if (!isInboxViewController(self)) {
        return orig_tvContextMenu ? orig_tvContextMenu(self, _cmd, tableView, indexPath, point) : nil;
    }

    UIContextMenuConfiguration *orig = orig_tvContextMenu ? orig_tvContextMenu(self, _cmd, tableView, indexPath, point) : nil;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *title = nil;
    NSString *threadKey = getBestIdentifierForCell(cell, &title);
    if (!threadKey) return orig;

    UIMenu *folderMenu = buildFolderMenu(threadKey, title);

    if (orig) {
        UIContextMenuActionProvider origProvider = nil;
        @try { origProvider = [orig valueForKey:@"_actionProvider"]; } @catch (NSException *e) {}
        UIContextMenuContentPreviewProvider origPreview = nil;
        @try { origPreview = [orig valueForKey:@"_previewProvider"]; } @catch (NSException *e) {}

        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:origPreview
                                                        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            UIMenu *m = origProvider ? origProvider(suggested) : nil;
            if (m) {
                NSMutableArray *c = [m.children mutableCopy];
                UIMenu *sec = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[folderMenu]];
                [c addObject:sec];
                return [m menuByReplacingChildren:c];
            }
            return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
        }];
    }
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
    }];
}

static UIContextMenuConfiguration *hooked_cvContextMenu(id self, SEL _cmd, UICollectionView *collectionView, NSIndexPath *indexPath, CGPoint point) {
    // Safety guard: only execute in inbox!
    if (!isInboxViewController(self)) {
        return orig_cvContextMenu ? orig_cvContextMenu(self, _cmd, collectionView, indexPath, point) : nil;
    }

    UIContextMenuConfiguration *orig = orig_cvContextMenu ? orig_cvContextMenu(self, _cmd, collectionView, indexPath, point) : nil;

    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    if (cell && cell.bounds.size.width < 240) return orig;

    NSString *title = nil;
    NSString *threadKey = getBestIdentifierForCell(cell, &title);
    if (!threadKey) return orig;

    UIMenu *folderMenu = buildFolderMenu(threadKey, title);

    if (orig) {
        UIContextMenuActionProvider origProvider = nil;
        @try { origProvider = [orig valueForKey:@"_actionProvider"]; } @catch (NSException *e) {}
        UIContextMenuContentPreviewProvider origPreview = nil;
        @try { origPreview = [orig valueForKey:@"_previewProvider"]; } @catch (NSException *e) {}

        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:origPreview
                                                        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            UIMenu *m = origProvider ? origProvider(suggested) : nil;
            if (m) {
                NSMutableArray *c = [m.children mutableCopy];
                UIMenu *sec = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[folderMenu]];
                [c addObject:sec];
                return [m menuByReplacingChildren:c];
            }
            return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
        }];
    }
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [UIMenu menuWithTitle:@"" children:@[folderMenu]];
    }];
}

static UISwipeActionsConfiguration *hooked_tvTrailingSwipe(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (!isInboxViewController(self)) {
        return orig_tvTrailingSwipe ? orig_tvTrailingSwipe(self, _cmd, tableView, indexPath) : nil;
    }

    UISwipeActionsConfiguration *orig = orig_tvTrailingSwipe ? orig_tvTrailingSwipe(self, _cmd, tableView, indexPath) : nil;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *title = nil;
    NSString *threadKey = getBestIdentifierForCell(cell, &title);
    if (!threadKey) return orig;

    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"📁 Folder" handler:^(UIContextualAction *a, __kindof UIView *v, void (^completion)(BOOL)) {
        UIViewController *top = findTopViewController();
        if (top) presentFolderActionSheet(top, threadKey, title);
        completion(YES);
    }];
    action.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    action.image = [UIImage systemImageNamed:@"folder"];

    NSMutableArray *acts = [NSMutableArray array];
    if (orig.actions) [acts addObjectsFromArray:orig.actions];
    [acts addObject:action];

    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:acts];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}

static CGFloat hooked_tvHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    // Safety guard: if not in inbox, always return original height!
    if (!isInboxViewController(self)) {
        return orig_tvHeightForRow ? orig_tvHeightForRow(self, _cmd, tableView, indexPath) : UITableViewAutomaticDimension;
    }

    NSString *selFolder = [MSGChatFolderManager sharedManager].selectedFolderId;
    if (!selFolder || [selFolder isEqualToString:@"all"]) {
        return orig_tvHeightForRow ? orig_tvHeightForRow(self, _cmd, tableView, indexPath) : UITableViewAutomaticDimension;
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *threadKey = getBestIdentifierForCell(cell, NULL);
    if (threadKey) {
        MSGChatFolder *f = [[MSGChatFolderManager sharedManager] folderForThreadKey:threadKey];
        if ([f.folderId isEqualToString:selFolder]) {
            return orig_tvHeightForRow ? orig_tvHeightForRow(self, _cmd, tableView, indexPath) : UITableViewAutomaticDimension;
        } else {
            return 0.001f;
        }
    }
    return orig_tvHeightForRow ? orig_tvHeightForRow(self, _cmd, tableView, indexPath) : UITableViewAutomaticDimension;
}

static void hooked_tvWillDisplayCell(id self, SEL _cmd, UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (orig_tvWillDisplayCell) orig_tvWillDisplayCell(self, _cmd, tableView, cell, indexPath);

    // Safety guard: if inside a conversation (messages/photos), NEVER hide cells!
    if (!isInboxViewController(self)) {
        cell.hidden = NO;
        return;
    }

    attachGestureToCellIfNeeded(cell);

    NSString *selFolder = [MSGChatFolderManager sharedManager].selectedFolderId;
    if (selFolder && ![selFolder isEqualToString:@"all"]) {
        NSString *threadKey = getBestIdentifierForCell(cell, NULL);
        if (threadKey) {
            MSGChatFolder *f = [[MSGChatFolderManager sharedManager] folderForThreadKey:threadKey];
            if (![f.folderId isEqualToString:selFolder]) {
                cell.hidden = YES;
                cell.clipsToBounds = YES;
                return;
            }
        }
    }
    cell.hidden = NO;
}

static void hooked_cvWillDisplayCell(id self, SEL _cmd, UICollectionView *collectionView, UICollectionViewCell *cell, NSIndexPath *indexPath) {
    if (orig_cvWillDisplayCell) orig_cvWillDisplayCell(self, _cmd, collectionView, cell, indexPath);

    // Safety guard: if inside a conversation (messages/photos), NEVER hide cells!
    if (!isInboxViewController(self)) {
        cell.hidden = NO;
        return;
    }

    attachGestureToCellIfNeeded(cell);

    if (cell.bounds.size.width >= 240) {
        NSString *selFolder = [MSGChatFolderManager sharedManager].selectedFolderId;
        if (selFolder && ![selFolder isEqualToString:@"all"]) {
            NSString *threadKey = getBestIdentifierForCell(cell, NULL);
            if (threadKey) {
                MSGChatFolder *f = [[MSGChatFolderManager sharedManager] folderForThreadKey:threadKey];
                if (![f.folderId isEqualToString:selFolder]) {
                    cell.hidden = YES;
                    cell.clipsToBounds = YES;
                    return;
                }
            }
        }
        cell.hidden = NO;
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Delegate Hooking
// ═══════════════════════════════════════════════════════════

static void hookScrollDelegate(id delegate) {
    if (!delegate) return;
    Class cls = [delegate class];

    NSNumber *hooked = objc_getAssociatedObject(cls, kDelegateHookedKey);
    if ([hooked boolValue]) return;
    objc_setAssociatedObject(cls, kDelegateHookedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // UITableView hooks
    SEL tvCtxSel = @selector(tableView:contextMenuConfigurationForRowAtIndexPath:point:);
    Method m = class_getInstanceMethod(cls, tvCtxSel);
    if (m) {
        orig_tvContextMenu = (UIContextMenuConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *, CGPoint))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tvContextMenu);
    } else {
        class_addMethod(cls, tvCtxSel, (IMP)hooked_tvContextMenu, "@:@@{CGPoint=dd}");
    }

    SEL swipeSel = @selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:);
    m = class_getInstanceMethod(cls, swipeSel);
    if (m) {
        orig_tvTrailingSwipe = (UISwipeActionsConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tvTrailingSwipe);
    } else {
        class_addMethod(cls, swipeSel, (IMP)hooked_tvTrailingSwipe, "@:@@");
    }

    SEL heightSel = @selector(tableView:heightForRowAtIndexPath:);
    m = class_getInstanceMethod(cls, heightSel);
    if (m) {
        orig_tvHeightForRow = (CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tvHeightForRow);
    } else {
        class_addMethod(cls, heightSel, (IMP)hooked_tvHeightForRow, "d@:@@");
    }

    SEL willDispTVSel = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
    m = class_getInstanceMethod(cls, willDispTVSel);
    if (m) {
        orig_tvWillDisplayCell = (void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_tvWillDisplayCell);
    } else {
        class_addMethod(cls, willDispTVSel, (IMP)hooked_tvWillDisplayCell, "v@:@@@");
    }

    // UICollectionView hooks
    SEL cvCtxSel = @selector(collectionView:contextMenuConfigurationForItemAtIndexPath:point:);
    m = class_getInstanceMethod(cls, cvCtxSel);
    if (m) {
        orig_cvContextMenu = (UIContextMenuConfiguration *(*)(id, SEL, UICollectionView *, NSIndexPath *, CGPoint))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_cvContextMenu);
    } else {
        class_addMethod(cls, cvCtxSel, (IMP)hooked_cvContextMenu, "@:@@{CGPoint=dd}");
    }

    SEL willDispCVSel = @selector(collectionView:willDisplayCell:forItemAtIndexPath:);
    m = class_getInstanceMethod(cls, willDispCVSel);
    if (m) {
        orig_cvWillDisplayCell = (void (*)(id, SEL, UICollectionView *, UICollectionViewCell *, NSIndexPath *))method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_cvWillDisplayCell);
    } else {
        class_addMethod(cls, willDispCVSel, (IMP)hooked_cvWillDisplayCell, "v@:@@@");
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Conversation Picker (📂 Button)
// ═══════════════════════════════════════════════════════════

static void MSGChatFolders_showConversationPicker(void) {
    CFLOG(@"Opening conversation picker...");

    UIWindow *window = findAppWindow();
    if (!window) return;

    NSMutableArray<UIView *> *allVisibleCells = [NSMutableArray array];

    // Search ALL scroll views in window
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window.rootViewController.view];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([v isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)v;
            hookScrollDelegate(tv.delegate);
            for (UITableViewCell *c in tv.visibleCells) {
                // Must be full-width conversation row (>= 240pt)
                if (c.bounds.size.width >= 240 && c.bounds.size.height >= 40) {
                    [allVisibleCells addObject:c];
                }
            }
        } else if ([v isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)v;
            if (![cv.superview isKindOfClass:[MSGChatFolderTabView class]]) {
                hookScrollDelegate(cv.delegate);
                for (UICollectionViewCell *c in cv.visibleCells) {
                    // Must be full-width conversation row (>= 240pt)
                    if (c.bounds.size.width >= 240 && c.bounds.size.height >= 40) {
                        [allVisibleCells addObject:c];
                    }
                }
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    NSMutableArray<NSDictionary *> *conversations = [NSMutableArray array];
    for (UIView *cell in allVisibleCells) {
        NSString *title = nil;
        NSString *identifier = getBestIdentifierForCell(cell, &title);

        if (title.length > 0 || identifier.length > 0) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"title"] = title.length > 0 ? title : [NSString stringWithFormat:@"Conversation %@", identifier ?: @""];
            info[@"id"] = identifier ?: title;

            MSGChatFolder *folder = [[MSGChatFolderManager sharedManager] folderForThreadKey:info[@"id"]];
            if (folder) info[@"folder"] = folder.name;

            [conversations addObject:info];
        }
    }

    UIViewController *topVC = findTopViewController();
    if (!topVC) return;

    if (conversations.count == 0) {
        UIAlertController *empty = [UIAlertController
            alertControllerWithTitle:@"No Conversations Found"
                             message:@"Please scroll down your chats list slightly and tap 📂 again."
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
        NSString *display = info[@"title"];
        NSString *cid = info[@"id"];
        NSString *folder = info[@"folder"];

        if (folder) display = [NSString stringWithFormat:@"%@ [📁 %@]", display, folder];

        UIAlertAction *act = [UIAlertAction actionWithTitle:display style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            presentFolderActionSheet(topVC, cid, info[@"title"]);
        }];
        [picker addAction:act];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (picker.popoverPresentationController) {
        picker.popoverPresentationController.sourceView = topVC.view;
        picker.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2, 60, 0, 0);
    }

    [topVC presentViewController:picker animated:YES completion:nil];
}

// ═══════════════════════════════════════════════════════════
// MARK: - Rock-Solid Tab Bar Layout (No Jumping)
// ═══════════════════════════════════════════════════════════

static void layoutFolderTabBarInVC(UIViewController *vc) {
    if (!vc || !vc.view) return;

    // Only inject on the top-most inbox view controller
    if (![vc isKindOfClass:NSClassFromString(@"MSGInboxViewController")]) {
        return;
    }

    MSGChatFolderTabView *tabView = objc_getAssociatedObject(vc, kFolderTabViewKey);
    CGFloat tabHeight = [MSGChatFolderTabView preferredHeight];

    CGFloat safeTop = 0;
    if (vc.navigationController && vc.navigationController.navigationBar && !vc.navigationController.navigationBarHidden) {
        CGRect nbFrame = [vc.view convertRect:vc.navigationController.navigationBar.bounds fromView:vc.navigationController.navigationBar];
        safeTop = CGRectGetMaxY(nbFrame);
    }
    if (safeTop <= 0 && @available(iOS 11.0, *)) {
        safeTop = vc.view.safeAreaInsets.top;
    }
    if (safeTop <= 0) {
        safeTop = 94.0; // Modern safe default below status + nav bar
    }

    if (!tabView) {
        tabView = [[MSGChatFolderTabView alloc]
            initWithFrame:CGRectMake(0, safeTop, vc.view.bounds.size.width, tabHeight)];
        tabView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        tabView.selectedFolderId = [MSGChatFolderManager sharedManager].selectedFolderId;

        objc_setAssociatedObject(vc, kFolderTabViewKey, tabView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [vc.view addSubview:tabView];
        [tabView reloadTabs];
    }

    // Lock frame directly below the navigation bar
    CGRect expectedFrame = CGRectMake(0, safeTop, vc.view.bounds.size.width, tabHeight);
    if (!CGRectEqualToRect(tabView.frame, expectedFrame)) {
        tabView.frame = expectedFrame;
    }
    [vc.view bringSubviewToFront:tabView];

    // Ensure content scrolls behind the bar without being clipped (scans nested views)
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:vc.view];
    while (queue.count > 0) {
        UIView *sub = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (sub == tabView) continue;

        if ([sub isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)sub;
            UIEdgeInsets insets = sv.contentInset;
            if (insets.top < tabHeight) {
                insets.top = tabHeight;
                sv.contentInset = insets;
                sv.scrollIndicatorInsets = insets;
            }
            if ([sub isKindOfClass:[UITableView class]]) {
                hookScrollDelegate([(UITableView *)sub delegate]);
            } else if ([sub isKindOfClass:[UICollectionView class]]) {
                hookScrollDelegate([(UICollectionView *)sub delegate]);
            }
        } else {
            [queue addObjectsFromArray:sub.subviews];
        }
    }
}

static void hooked_inboxViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_inboxViewDidAppear) orig_inboxViewDidAppear(self, _cmd, animated);
    layoutFolderTabBarInVC((UIViewController *)self);
}

static void hooked_inboxViewDidLayoutSubviews(id self, SEL _cmd) {
    if (orig_inboxViewDidLayoutSubviews) orig_inboxViewDidLayoutSubviews(self, _cmd);
    layoutFolderTabBarInVC((UIViewController *)self);
}

// ═══════════════════════════════════════════════════════════
// MARK: - Notifications from Tab Bar
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
        [rename addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = folder.name; }];
        [rename addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
            NSString *n = rename.textFields.firstObject.text;
            if (n.length > 0) {
                [mgr renameFolderWithId:folderId toName:n];
                reloadAllChatViews();
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
            reloadAllChatViews();
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:confirm animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void msgcf_folderTabDidSelect(id self, SEL _cmd, NSNotification *note) {
    NSString *folderId = note.userInfo[@"folderId"];
    if (!folderId) return;
    [[MSGChatFolderManager sharedManager] setSelectedFolderId:folderId];
    reloadAllChatViews();
}

static void msgcf_folderTabDidCreate(id self, SEL _cmd, NSNotification *note) {
    UIViewController *vc = (UIViewController *)self;
    UIAlertController *nameAlert = [UIAlertController
        alertControllerWithTitle:@"New Folder" message:@"Enter folder name" preferredStyle:UIAlertControllerStyleAlert];
    [nameAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Folder name (e.g. Work, Uni, Family)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [nameAlert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = nameAlert.textFields.firstObject.text;
        if (name.length > 0) {
            [[MSGChatFolderManager sharedManager] createFolderWithName:name];
            reloadAllChatViews();
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
// MARK: - Registration
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
    CFLOG(@"Registering universal MSGChatFolders hooks...");

    // Hook MSGInboxViewController (Single owner of the folder tab bar)
    Class inboxClass = NSClassFromString(@"MSGInboxViewController");
    if (inboxClass) {
        swizzle(inboxClass, @selector(viewDidAppear:), (IMP)hooked_inboxViewDidAppear, (IMP *)&orig_inboxViewDidAppear);
        swizzle(inboxClass, @selector(viewDidLayoutSubviews), (IMP)hooked_inboxViewDidLayoutSubviews, (IMP *)&orig_inboxViewDidLayoutSubviews);

        addMethodIfMissing(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidSelect:"), (IMP)msgcf_folderTabDidSelect, "v@:@");
        addMethodIfMissing(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidCreate:"), (IMP)msgcf_folderTabDidCreate, "v@:@");
        addMethodIfMissing(inboxClass, NSSelectorFromString(@"msgcf_folderTabDidLongPress:"), (IMP)msgcf_folderTabDidLongPress, "v@:@");
        hookScrollDelegate((id)inboxClass);
    }

    // Hook MSGThreadListViewController
    Class threadListClass = NSClassFromString(@"MSGThreadListViewController");
    if (threadListClass) {
        hookScrollDelegate((id)threadListClass);
    }

    // Hook LSTableViewController
    Class lsTableClass = NSClassFromString(@"LSTableViewController");
    if (lsTableClass) {
        hookScrollDelegate((id)lsTableClass);
    }

    // Register 📂 picker notification
    [[NSNotificationCenter defaultCenter]
        addObserverForName:MSGChatFoldersShowPickerNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        MSGChatFolders_showConversationPicker();
    }];

    CFLOG(@"MSGChatFolders hooks registered successfully!");
}
