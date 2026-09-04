//
//  MSGChatFolderManager.h
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Manages folder creation, deletion, renaming, and
//  thread↔folder assignments. Persists to NSUserDefaults.
//

#import <Foundation/Foundation.h>

// Posted whenever folder data changes (created, deleted, renamed, thread assigned/removed)
extern NSString *const MSGChatFoldersDataChangedNotification;

@interface MSGChatFolder : NSObject <NSCoding>
@property (nonatomic, copy) NSString *folderId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *threadKeys;
+ (instancetype)folderWithName:(NSString *)name;
@end

@interface MSGChatFolderManager : NSObject

+ (instancetype)sharedManager;

// ── Folder CRUD ──
- (NSArray<MSGChatFolder *> *)allFolders;
- (MSGChatFolder *)createFolderWithName:(NSString *)name;
- (void)deleteFolderWithId:(NSString *)folderId;
- (void)renameFolderWithId:(NSString *)folderId toName:(NSString *)name;
- (void)moveFolderAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;

// ── Thread assignment ──
- (void)addThreadKey:(NSString *)threadKey toFolderId:(NSString *)folderId;
- (void)removeThreadKey:(NSString *)threadKey fromFolderId:(NSString *)folderId;
- (void)removeThreadKeyFromAllFolders:(NSString *)threadKey;

// ── Queries ──
- (MSGChatFolder *)folderForThreadKey:(NSString *)threadKey;
- (NSString *)folderIdForThreadKey:(NSString *)threadKey;
- (BOOL)threadKey:(NSString *)threadKey belongsToFolderId:(NSString *)folderId;
- (NSSet<NSString *> *)threadKeysForFolderId:(NSString *)folderId;

// ── Active filter ──
@property (nonatomic, copy) NSString *selectedFolderId; // nil or "all" = show everything
- (BOOL)shouldShowThreadKey:(NSString *)threadKey;

@end
