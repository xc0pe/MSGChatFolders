//
//  MSGChatFolders_main.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Entry point. This constructor runs automatically when the dylib is
//  loaded into Messenger's process by dyld.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MSGChatFolderManager.h"
#import "MSGChatFolderTabView.h"

// Declared in MSGChatFolderHooks.m
extern void MSGChatFolders_RegisterHooks(void);

// ═══════════════════════════════════════════════════════════
// MARK: - Forward Declarations
// ═══════════════════════════════════════════════════════════

static UIViewController *MSGChatFolders_topViewController(void);
static void MSGChatFolders_reloadCollectionViews(UIView *view);

// ═══════════════════════════════════════════════════════════
// MARK: - Utilities
// ═══════════════════════════════════════════════════════════

/// Finds the key window using the modern API.
static UIWindow *MSGChatFolders_keyWindow(void) {
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) {
                        window = w;
                        break;
                    }
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) {
        window = [UIApplication sharedApplication].keyWindow;
    }
#pragma clang diagnostic pop
    return window;
}

/// Finds the topmost presented view controller.
static UIViewController *MSGChatFolders_topViewController(void) {
    UIWindow *window = MSGChatFolders_keyWindow();
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

/// Recursively finds and reloads all table views and collection views in the hierarchy.
static void MSGChatFolders_reloadAllViews(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) {
        [(UITableView *)view reloadData];
    }
    if ([view isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)view reloadData];
    }
    for (UIView *sub in view.subviews) {
        MSGChatFolders_reloadAllViews(sub);
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Notification-Based Tab View Delegate Bridge
// ═══════════════════════════════════════════════════════════

// We override the MSGChatFolderTabView's action methods to post notifications
// instead of using the delegate protocol directly. This is simpler since we're
// injecting methods into classes we don't own.

static void patchTabViewActions(void) {
    // Override tabTapped: to also post a notification
    Class tabViewClass = [MSGChatFolderTabView class];

    SEL tabTappedSel = NSSelectorFromString(@"tabTapped:");
    Method tabTappedMethod = class_getInstanceMethod(tabViewClass, tabTappedSel);

    if (tabTappedMethod) {
        typedef void (*TabTappedIMP)(id, SEL, id);
        TabTappedIMP origTabTapped = (TabTappedIMP)method_getImplementation(tabTappedMethod);

        IMP newIMP = imp_implementationWithBlock(^(MSGChatFolderTabView *blockSelf, UIButton *sender) {
            // Call original
            origTabTapped(blockSelf, tabTappedSel, sender);

            // Post notification with folder ID
            NSString *folderId = [MSGChatFolderManager sharedManager].selectedFolderId;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"MSGChatFolders_FolderSelected"
                              object:nil
                            userInfo:@{@"folderId": folderId ?: @"all"}];
        });

        method_setImplementation(tabTappedMethod, newIMP);
    }

    // Override addButtonTapped to post a notification
    SEL addSel = NSSelectorFromString(@"addButtonTapped");
    Method addBtnMethod = class_getInstanceMethod(tabViewClass, addSel);

    if (addBtnMethod) {
        IMP newIMP = imp_implementationWithBlock(^(MSGChatFolderTabView *blockSelf) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"MSGChatFolders_CreateFolder"
                              object:nil
                            userInfo:nil];
        });

        method_setImplementation(addBtnMethod, newIMP);
    }

    // Override tabLongPressed: to post a notification
    SEL longPressSel = NSSelectorFromString(@"tabLongPressed:");
    Method longPressMethod = class_getInstanceMethod(tabViewClass, longPressSel);

    if (longPressMethod) {
        IMP newIMP = imp_implementationWithBlock(^(MSGChatFolderTabView *blockSelf, UILongPressGestureRecognizer *gesture) {
            if (gesture.state != UIGestureRecognizerStateBegan) return;

            UIButton *btn = (UIButton *)gesture.view;
            NSInteger idx = btn.tag - 7000;  // kTagBase
            if (idx == 0) return;  // "All" tab

            NSString *folderId = btn.accessibilityIdentifier;
            if (folderId) {
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"MSGChatFolders_FolderLongPress"
                                  object:nil
                                userInfo:@{@"folderId": folderId}];
            }
        });

        method_setImplementation(longPressMethod, newIMP);
    }

    NSLog(@"[MSGChatFolders] Tab view action patches applied.");
}

// ═══════════════════════════════════════════════════════════
// MARK: - Setup Notification Observers on Inbox VC
// ═══════════════════════════════════════════════════════════

static void setupInboxNotificationObservers(void) {
    // Register for folder selection changes globally
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"MSGChatFolders_FolderSelected"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSString *folderId = note.userInfo[@"folderId"];
        NSLog(@"[MSGChatFolders] Folder selected: %@", folderId);

        UIWindow *window = MSGChatFolders_keyWindow();
        if (window) {
            UIViewController *rootVC = window.rootViewController;
            MSGChatFolders_reloadAllViews(rootVC.view);
        }
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"MSGChatFolders_CreateFolder"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        UIViewController *topVC = MSGChatFolders_topViewController();
        if (topVC) {
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

            [topVC presentViewController:nameAlert animated:YES completion:nil];
        }
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"MSGChatFolders_FolderLongPress"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSString *folderId = note.userInfo[@"folderId"];
        UIViewController *topVC = MSGChatFolders_topViewController();
        if (topVC && folderId) {
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
                [topVC presentViewController:renameAlert animated:YES completion:nil];
            }]];

            [alert addAction:[UIAlertAction
                actionWithTitle:@"🗑 Delete Folder"
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
                [topVC presentViewController:confirm animated:YES completion:nil];
            }]];

            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];

            if (alert.popoverPresentationController) {
                alert.popoverPresentationController.sourceView = topVC.view;
                alert.popoverPresentationController.sourceRect = CGRectMake(
                    topVC.view.bounds.size.width / 2, 60, 0, 0);
            }

            [topVC presentViewController:alert animated:YES completion:nil];
        }
    }];

    NSLog(@"[MSGChatFolders] Notification observers registered.");
}

// ═══════════════════════════════════════════════════════════
// MARK: - Constructor (dylib entry point)
// ═══════════════════════════════════════════════════════════

__attribute__((constructor))
static void MSGChatFolders_init(void) {
    NSLog(@"[MSGChatFolders] ══════════════════════════════════════");
    NSLog(@"[MSGChatFolders]  MSGChatFolders v1.0.0 loaded!");
    NSLog(@"[MSGChatFolders]  Target: com.facebook.Messenger v576");
    NSLog(@"[MSGChatFolders] ══════════════════════════════════════");

    // Initialize the folder manager (loads saved data)
    [MSGChatFolderManager sharedManager];

    // Delay hook registration until after UIKit is ready
    // This ensures all Messenger classes are loaded
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSLog(@"[MSGChatFolders] Registering hooks (delayed)...");

        // Register all method swizzles
        MSGChatFolders_RegisterHooks();

        // Patch tab view actions to use notifications
        patchTabViewActions();

        // Set up notification observers for tab interactions
        setupInboxNotificationObservers();

        NSLog(@"[MSGChatFolders] Initialization complete.");
    });
}
