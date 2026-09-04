//
//  MSGChatFolderManager.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Implementation of folder storage, persistence, and query logic.
//  All data is stored in NSUserDefaults under the "MSGChatFolders" suite.
//

#import "MSGChatFolderManager.h"

NSString *const MSGChatFoldersDataChangedNotification = @"MSGChatFoldersDataChangedNotification";

static NSString *const kSuiteName       = @"com.msgchatfolders.data";
static NSString *const kFoldersKey      = @"MSGChatFolders_folders";
static NSString *const kSelectedKey     = @"MSGChatFolders_selectedFolderId";

#pragma mark - MSGChatFolder

@implementation MSGChatFolder

+ (instancetype)folderWithName:(NSString *)name {
    MSGChatFolder *folder = [[MSGChatFolder alloc] init];
    folder.folderId = [[NSUUID UUID] UUIDString];
    folder.name = name;
    folder.threadKeys = [NSMutableOrderedSet orderedSet];
    return folder;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _folderId = [coder decodeObjectForKey:@"folderId"];
        _name = [coder decodeObjectForKey:@"name"];
        NSArray *keys = [coder decodeObjectForKey:@"threadKeys"];
        _threadKeys = keys ? [NSMutableOrderedSet orderedSetWithArray:keys]
                          : [NSMutableOrderedSet orderedSet];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_folderId forKey:@"folderId"];
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeObject:[_threadKeys array] forKey:@"threadKeys"];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<MSGChatFolder: %@ (%lu threads)>",
            self.name, (unsigned long)self.threadKeys.count];
}

@end

#pragma mark - MSGChatFolderManager

@interface MSGChatFolderManager ()
@property (nonatomic, strong) NSMutableArray<MSGChatFolder *> *folders;
@property (nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation MSGChatFolderManager

+ (instancetype)sharedManager {
    static MSGChatFolderManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MSGChatFolderManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        [self loadFolders];

        // Default: show all
        NSString *saved = [_defaults objectForKey:kSelectedKey];
        _selectedFolderId = saved ?: @"all";
    }
    return self;
}

#pragma mark - Persistence

- (void)loadFolders {
    NSData *data = [self.defaults objectForKey:kFoldersKey];
    if (data) {
        NSSet *allowed = [NSSet setWithObjects:
            [NSArray class], [MSGChatFolder class], [NSString class],
            [NSMutableOrderedSet class], [NSOrderedSet class], nil];
        NSError *error = nil;
        NSArray *decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed
                                                              fromData:data
                                                                 error:&error];
        if (decoded && !error) {
            self.folders = [decoded mutableCopy];
        } else {
            NSLog(@"[MSGChatFolders] Failed to decode folders: %@", error);
            self.folders = [NSMutableArray array];
        }
    } else {
        self.folders = [NSMutableArray array];
    }
}

- (void)saveFolders {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.folders
                                         requiringSecureCoding:NO
                                                        error:&error];
    if (data && !error) {
        [self.defaults setObject:data forKey:kFoldersKey];
        [self.defaults synchronize];
    } else {
        NSLog(@"[MSGChatFolders] Failed to encode folders: %@", error);
    }
}

- (void)notifyChange {
    [self saveFolders];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MSGChatFoldersDataChangedNotification
                          object:nil];
    });
}

#pragma mark - Folder CRUD

- (NSArray<MSGChatFolder *> *)allFolders {
    return [self.folders copy];
}

- (MSGChatFolder *)createFolderWithName:(NSString *)name {
    MSGChatFolder *folder = [MSGChatFolder folderWithName:name];
    [self.folders addObject:folder];
    [self notifyChange];
    NSLog(@"[MSGChatFolders] Created folder: %@", folder);
    return folder;
}

- (void)deleteFolderWithId:(NSString *)folderId {
    NSUInteger idx = [self indexOfFolderWithId:folderId];
    if (idx != NSNotFound) {
        NSLog(@"[MSGChatFolders] Deleted folder: %@", self.folders[idx].name);
        [self.folders removeObjectAtIndex:idx];

        // If we were viewing the deleted folder, reset to "all"
        if ([self.selectedFolderId isEqualToString:folderId]) {
            self.selectedFolderId = @"all";
        }
        [self notifyChange];
    }
}

- (void)renameFolderWithId:(NSString *)folderId toName:(NSString *)name {
    MSGChatFolder *folder = [self folderWithId:folderId];
    if (folder) {
        folder.name = name;
        [self notifyChange];
    }
}

- (void)moveFolderAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    if (fromIndex < self.folders.count && toIndex < self.folders.count) {
        MSGChatFolder *folder = self.folders[fromIndex];
        [self.folders removeObjectAtIndex:fromIndex];
        [self.folders insertObject:folder atIndex:toIndex];
        [self notifyChange];
    }
}

#pragma mark - Thread Assignment

- (void)addThreadKey:(NSString *)threadKey toFolderId:(NSString *)folderId {
    if (!threadKey || !folderId) return;

    // Remove from any existing folder first (one folder per conversation)
    [self removeThreadKeyFromAllFolders:threadKey];

    MSGChatFolder *folder = [self folderWithId:folderId];
    if (folder) {
        [folder.threadKeys addObject:threadKey];
        NSLog(@"[MSGChatFolders] Added thread %@ to folder %@", threadKey, folder.name);
        [self notifyChange];
    }
}

- (void)removeThreadKey:(NSString *)threadKey fromFolderId:(NSString *)folderId {
    if (!threadKey || !folderId) return;
    MSGChatFolder *folder = [self folderWithId:folderId];
    if (folder) {
        [folder.threadKeys removeObject:threadKey];
        [self notifyChange];
    }
}

- (void)removeThreadKeyFromAllFolders:(NSString *)threadKey {
    if (!threadKey) return;
    BOOL changed = NO;
    for (MSGChatFolder *folder in self.folders) {
        if ([folder.threadKeys containsObject:threadKey]) {
            [folder.threadKeys removeObject:threadKey];
            changed = YES;
        }
    }
    if (changed) {
        [self notifyChange];
    }
}

#pragma mark - Queries

- (MSGChatFolder *)folderForThreadKey:(NSString *)threadKey {
    if (!threadKey) return nil;
    for (MSGChatFolder *folder in self.folders) {
        if ([folder.threadKeys containsObject:threadKey]) {
            return folder;
        }
    }
    return nil;
}

- (NSString *)folderIdForThreadKey:(NSString *)threadKey {
    return [self folderForThreadKey:threadKey].folderId;
}

- (BOOL)threadKey:(NSString *)threadKey belongsToFolderId:(NSString *)folderId {
    MSGChatFolder *folder = [self folderWithId:folderId];
    return folder && [folder.threadKeys containsObject:threadKey];
}

- (NSSet<NSString *> *)threadKeysForFolderId:(NSString *)folderId {
    MSGChatFolder *folder = [self folderWithId:folderId];
    return folder ? [folder.threadKeys set] : [NSSet set];
}

#pragma mark - Active Filter

- (void)setSelectedFolderId:(NSString *)selectedFolderId {
    _selectedFolderId = [selectedFolderId copy] ?: @"all";
    [self.defaults setObject:_selectedFolderId forKey:kSelectedKey];
    [self.defaults synchronize];
}

- (BOOL)shouldShowThreadKey:(NSString *)threadKey {
    // "all" or nil => show everything
    if (!self.selectedFolderId || [self.selectedFolderId isEqualToString:@"all"]) {
        return YES;
    }
    return [self threadKey:threadKey belongsToFolderId:self.selectedFolderId];
}

#pragma mark - Helpers

- (MSGChatFolder *)folderWithId:(NSString *)folderId {
    for (MSGChatFolder *folder in self.folders) {
        if ([folder.folderId isEqualToString:folderId]) {
            return folder;
        }
    }
    return nil;
}

- (NSUInteger)indexOfFolderWithId:(NSString *)folderId {
    for (NSUInteger i = 0; i < self.folders.count; i++) {
        if ([self.folders[i].folderId isEqualToString:folderId]) {
            return i;
        }
    }
    return NSNotFound;
}

@end
