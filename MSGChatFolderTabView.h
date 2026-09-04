//
//  MSGChatFolderTabView.h
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Horizontal scrollable tab bar showing folder names.
//  "All" is always first, "+" (create) button is always last.
//

#import <UIKit/UIKit.h>

@class MSGChatFolderTabView;

@protocol MSGChatFolderTabViewDelegate <NSObject>
- (void)folderTabView:(MSGChatFolderTabView *)tabView didSelectFolderId:(NSString *)folderId;
- (void)folderTabViewDidTapCreateFolder:(MSGChatFolderTabView *)tabView;
- (void)folderTabView:(MSGChatFolderTabView *)tabView didLongPressFolderId:(NSString *)folderId;
@end

@interface MSGChatFolderTabView : UIView

@property (nonatomic, weak) id<MSGChatFolderTabViewDelegate> delegate;
@property (nonatomic, copy) NSString *selectedFolderId;

/// Reload tabs from MSGChatFolderManager
- (void)reloadTabs;

/// Height of the tab bar (for layout calculations)
+ (CGFloat)preferredHeight;

@end
