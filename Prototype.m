#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "Filter.h"

@interface NSObject (MCFAdapterInitialization)
- (instancetype)initWithListModel:(id)model;
@end

// F1: one-account prototype. Filter model rows, never cell visibility or row heights.
static NSMutableArray<NSMutableDictionary *> *Folders;
static NSString *Selected;
static __weak UIViewController *Inbox;
static __weak id Source;
static NSArray<NSDictionary *> *Chats;
static NSMutableDictionary *Status;
static UIButton *Launcher;
static BOOL InboxVisible;
static BOOL Ready;
static NSMapTable *DecodedRows;
static NSString * const StoreKey = @"MSGChatFolders.F1.singleAccount";

static BOOL Signature(Method m, char ret, const char *args) {
    if (!m || method_getNumberOfArguments(m) != strlen(args)+2) return NO;
    char t[128] = {0}; method_getReturnType(m,t,sizeof(t));
    if (t[0] != ret) return NO;
    for (NSUInteger i=0;i<strlen(args);i++) {
        method_getArgumentType(m,(unsigned int)i+2,t,sizeof(t));
        if (t[0]!=args[i]) return NO;
    }
    return YES;
}
static id Get(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel=NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    Method m=class_getInstanceMethod(object_getClass(obj),sel);
    if (!Signature(m,'@',"")) return nil;
    return ((id(*)(id,SEL))method_getImplementation(m))(obj,sel);
}
static id ObjectField(id obj, const char *name) {
    if (!obj) return nil;
    Ivar field=class_getInstanceVariable(object_getClass(obj),name);
    const char *type=field ? ivar_getTypeEncoding(field) : NULL;
    return type && type[0]=='@' ? object_getIvar(obj,field) : nil;
}
static NSMutableDictionary *Folder(NSString *key) {
    for (NSMutableDictionary *f in Folders) if ([f[@"id"] isEqual:key]) return f;
    return nil;
}
static void Save(void) { [NSUserDefaults.standardUserDefaults setObject:Folders forKey:StoreKey]; }
static void Load(void) {
    Folders=[NSMutableArray array];
    id saved=[NSUserDefaults.standardUserDefaults objectForKey:StoreKey];
    if (![saved isKindOfClass:NSArray.class]) return;
    for (id f in saved) {
        if (![f isKindOfClass:NSDictionary.class] || ![f[@"id"] isKindOfClass:NSString.class] ||
            ![f[@"name"] isKindOfClass:NSString.class] || ![f[@"members"] isKindOfClass:NSArray.class]) continue;
        NSMutableArray *members=[NSMutableArray array];
        for (id key in f[@"members"]) if ([key isKindOfClass:NSString.class]) [members addObject:key];
        [Folders addObject:[@{@"id":f[@"id"],@"name":f[@"name"],@"members":members} mutableCopy]];
    }
}

static NSDictionary *Decode(id row) {
    NSDictionary *cached=[DecodedRows objectForKey:row];
    if (cached) return cached;
    @try {
        id model=Get(row,@"inboxModel");
        if (!model) return nil;
        Status[@"last_inbox_model_class"]=NSStringFromClass(object_getClass(model));
        id adapter=model;
        Class raw=NSClassFromString(@"MBQThreadListModel"), adapterClass=NSClassFromString(@"MSGInboxRowAdapter");
        if (raw && [model isKindOfClass:raw] && adapterClass) {
            SEL init=NSSelectorFromString(@"initWithListModel:");
            if (!Signature(class_getInstanceMethod(adapterClass,init),'@',"@")) return nil;
            adapter=[[adapterClass alloc] initWithListModel:model];
        }
        if (!adapter) return nil;
        SEL sel=NSSelectorFromString(@"threadKey");
        if (![adapter respondsToSelector:sel]) return nil;
        Method m=class_getInstanceMethod(object_getClass(adapter),sel);
        if (!Signature(m,'q',"")) return nil;
        long long key=((long long(*)(id,SEL))method_getImplementation(m))(adapter,sel);
        if (!key) return nil;
        id title=Get(adapter,@"threadName");
        if (![title isKindOfClass:NSString.class] || ![title length]) return nil;
        NSDictionary *entry=@{@"key":[NSString stringWithFormat:@"%lld",key],@"title":title};
        [DecodedRows setObject:entry forKey:row];
        return entry;
    } @catch (NSException *exception) { Status[@"decode_exception"]=@YES; return nil; }
}

static NSArray *Process(NSArray *rows) {
    NSMutableArray *chats=[NSMutableArray array];
    NSMutableSet *seen=[NSMutableSet set];
    NSUInteger unresolved=0, conversations=0;
    Class rowClass=NSClassFromString(@"MSGInboxRowInboxModel");
    for (id row in rows) {
        if (!rowClass || ![row isKindOfClass:rowClass]) continue;
        conversations++;
        NSDictionary *entry=Decode(row);
        if (!entry) { unresolved++; continue; }
        if (![seen containsObject:entry[@"key"]]) { [chats addObject:entry]; [seen addObject:entry[@"key"]]; }
    }
    Chats=chats;
    Ready=conversations>0 && unresolved==0;
    Status[@"raw_rows"]=@(rows.count);
    Status[@"conversation_rows"]=@(conversations);
    Status[@"decoded_chats"]=@(chats.count);
    Status[@"unresolved_rows"]=@(unresolved);
    if (!Ready || !Selected || !Folder(Selected)) {
        if (unresolved) Selected=nil; // Never show a misleading partially decoded folder.
        Status[@"filter_active"]=@NO;
        return rows;
    }
    NSSet *members=[NSSet setWithArray:Folder(Selected)[@"members"]];
    BOOL valid=NO;
    NSArray *filtered=MCFSelectRows(rows,members,^BOOL(id row){ return [row isKindOfClass:rowClass]; },
                                  ^NSString *(id row){ return Decode(row)[@"key"]; },&valid);
    if (!valid) { Selected=nil; Status[@"filter_active"]=@NO; return rows; }
    Status[@"filter_active"]=@YES;
    Status[@"filtered_rows"]=@(filtered.count);
    return filtered;
}

static void Refresh(void) {
    UIViewController *vc=Inbox;
    SEL sel=NSSelectorFromString(@"reloadData");
    Method m=vc ? class_getInstanceMethod(object_getClass(vc),sel) : NULL;
    if (Signature(m,'v',"")) ((void(*)(id,SEL))method_getImplementation(m))(vc,sel);
    else { Selected=nil; Status[@"reload_missing"]=@YES; }
}

@interface MCFFoldersController : UITableViewController
@property(nonatomic,copy) NSString *editingFolder;
@property(nonatomic,strong) NSArray<NSDictionary *> *availableChats;
@end
@interface MCFLauncher : NSObject
+ (void)show;
@end

@implementation MCFFoldersController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=self.editingFolder ? Folder(self.editingFolder)[@"name"] : @"Chat folders · F1";
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.availableChats=[Chats copy] ?: @[];
    if (!self.editingFolder) {
        self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
        self.navigationItem.rightBarButtonItems=@[
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(create)],
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share)]];
    }
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return self.editingFolder ? self.availableChats.count : Folders.count+1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return self.editingFolder ? @"Tap chats to toggle membership" : @"Choose a folder · ⓘ to assign chats"; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (self.editingFolder) return @"Only conversations loaded by Messenger are shown. Scroll the All list to load older chats, then reopen this picker.";
    if (!Ready) return @"Waiting for supported conversation models. Use Share to export status if your chats are already visible.";
    return @"Folders are stored on this installation for your single Messenger account. Swipe a folder to delete it.";
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:@"row"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
    cell.accessoryType=UITableViewCellAccessoryNone; cell.detailTextLabel.text=nil;
    if (self.editingFolder) {
        NSDictionary *chat=self.availableChats[ip.row];
        cell.textLabel.text=chat[@"title"];
        if ([Folder(self.editingFolder)[@"members"] containsObject:chat[@"key"]]) cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.imageView.image=[UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
    } else if (ip.row==0) {
        cell.textLabel.text=@"All chats"; cell.imageView.image=[UIImage systemImageNamed:@"tray.full"];
        if (!Selected) cell.accessoryType=UITableViewCellAccessoryCheckmark;
    } else {
        NSDictionary *f=Folders[ip.row-1]; cell.textLabel.text=f[@"name"];
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%lu assigned%@",(unsigned long)[f[@"members"] count],[Selected isEqual:f[@"id"]] ? @" · selected" : @""];
        cell.accessoryType=UITableViewCellAccessoryDetailButton;
        cell.imageView.image=[UIImage systemImageNamed:@"folder"];
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.editingFolder) {
        NSMutableArray *members=Folder(self.editingFolder)[@"members"];
        NSString *key=self.availableChats[ip.row][@"key"];
        if ([members containsObject:key]) [members removeObject:key]; else [members addObject:key];
        Save(); [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone]; return;
    }
    if (ip.row>0 && !Ready) return;
    Selected=ip.row==0 ? nil : Folders[ip.row-1][@"id"];
    [self close];
}
- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    if (!Ready || ip.row==0) return;
    MCFFoldersController *picker=[[MCFFoldersController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.editingFolder=Folders[ip.row-1][@"id"];
    [self.navigationController pushViewController:picker animated:YES];
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return !self.editingFolder && ip.row>0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style!=UITableViewCellEditingStyleDelete) return;
    if ([Selected isEqual:Folders[ip.row-1][@"id"]]) Selected=nil;
    [Folders removeObjectAtIndex:ip.row-1]; Save(); [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}
- (void)create {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"New folder" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder=@"Folder name"; tf.autocapitalizationType=UITextAutocapitalizationTypeWords; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSString *name=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        [Folders addObject:[@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"members":[NSMutableArray array]} mutableCopy]];
        Save(); [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:^{ Refresh(); Launcher.hidden=!InboxVisible; }]; }
- (void)share {
    NSData *data=[NSJSONSerialization dataWithJSONObject:Status options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"MSGChatFolders-F1.json"]];
    if (![data writeToURL:url atomically:YES]) return;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@implementation MCFLauncher
+ (void)show {
    UIViewController *vc=Inbox;
    if (!vc || vc.presentedViewController) return;
    Launcher.hidden=YES;
    MCFFoldersController *folders=[[MCFFoldersController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:folders];
    nav.modalPresentationStyle=UIModalPresentationFullScreen;
    [vc presentViewController:nav animated:YES completion:nil];
}
@end

static void Attach(UIViewController *vc) {
    id source=ObjectField(vc,"_dataSource");
    if (Source!=source) { Source=source; Chats=@[]; Ready=NO; Selected=nil; }
    Inbox=vc; InboxVisible=YES;
    // The hooked getter records the unfiltered rows itself. Do not process its
    // possibly filtered return value a second time or the picker loses chats.
    (void)Get(source,@"inboxRows");
    UIWindow *window=vc.view.window;
    if (!window) return;
    if (!Launcher) {
        Launcher=[UIButton buttonWithType:UIButtonTypeSystem];
        [Launcher setTitle:@"Folders · F1" forState:UIControlStateNormal];
        [Launcher setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        Launcher.backgroundColor=UIColor.systemIndigoColor; Launcher.layer.cornerRadius=17;
        Launcher.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [Launcher addTarget:MCFLauncher.class action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
    }
    [window addSubview:Launcher]; Launcher.hidden=NO;
    Launcher.frame=CGRectMake(MAX(8,window.bounds.size.width-126),window.safeAreaInsets.top+52,118,34);
}

static void Install(void) {
    Class cls=NSClassFromString(@"MSGThreadListViewController"), source=NSClassFromString(@"MSGThreadListDataSource");
    if (!cls || !source) { Status[@"hooks"]=@"Target classes unavailable"; return; }
    SEL getter=NSSelectorFromString(@"inboxRows"); Method gm=class_getInstanceMethod(source,getter);
    SEL appear=@selector(viewDidAppear:), disappear=@selector(viewWillDisappear:);
    Method am=class_getInstanceMethod(cls,appear), dm=class_getInstanceMethod(cls,disappear);
    if (!Signature(gm,'@',"") || !Signature(am,'v',"B") || !Signature(dm,'v',"B")) { Status[@"hooks"]=@"Signature mismatch"; return; }
    IMP oldGetter=method_getImplementation(gm), oldAppear=method_getImplementation(am), oldDisappear=method_getImplementation(dm);
    IMP newGetter=imp_implementationWithBlock(^id(id receiver){
        id rows=((id(*)(id,SEL))oldGetter)(receiver,getter);
        if (NSThread.isMainThread && receiver==Source && [rows isKindOfClass:NSArray.class]) return Process(rows);
        return rows;
    });
    IMP newAppear=imp_implementationWithBlock(^(UIViewController *vc,BOOL animated){
        ((void(*)(id,SEL,BOOL))oldAppear)(vc,appear,animated); Attach(vc);
    });
    IMP newDisappear=imp_implementationWithBlock(^(UIViewController *vc,BOOL animated){
        if (vc==Inbox) { InboxVisible=NO; Launcher.hidden=YES; }
        ((void(*)(id,SEL,BOOL))oldDisappear)(vc,disappear,animated);
    });
    if (!class_addMethod(source,getter,newGetter,method_getTypeEncoding(gm))) method_setImplementation(gm,newGetter);
    if (!class_addMethod(cls,appear,newAppear,method_getTypeEncoding(am))) method_setImplementation(am,newAppear);
    if (!class_addMethod(cls,disappear,newDisappear,method_getTypeEncoding(dm))) method_setImplementation(dm,newDisappear);
    Status[@"hooks"]=@"installed";
}
__attribute__((constructor)) static void Start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"571.0.0"]) return;
        Load(); Chats=@[];
        DecodedRows=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
        Status=[@{@"build":@"F1-20260914",@"privacy":@"Counts, class names and status only; no chat names or identifiers"} mutableCopy];
        Install();
    });
}
