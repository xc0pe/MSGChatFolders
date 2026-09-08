//
//  MSGChatFolderTabView.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Horizontal scrollable tab bar. The 📂 button posts a notification
//  so the hooks layer can read visible cells and show a conversation picker.
//

#import "MSGChatFolderTabView.h"
#import "MSGChatFolderManager.h"

NSString *const MSGChatFoldersShowPickerNotification = @"MSGChatFoldersShowPicker";

static const CGFloat kTabHeight       = 36.0;
static const CGFloat kTabViewPadding  = 8.0;
static const CGFloat kTabSpacing      = 8.0;
static const CGFloat kTabHPadding     = 14.0;
static const CGFloat kTabCornerRadius = 18.0;
static const NSInteger kTagBase       = 7000;

@interface MSGChatFolderTabView ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@property (nonatomic, strong) UIButton *addButton;
@property (nonatomic, strong) UIButton *pickButton;
@end

@implementation MSGChatFolderTabView

+ (CGFloat)preferredHeight {
    return kTabHeight + (kTabViewPadding * 2);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        if (@available(iOS 13.0, *)) {
            self.backgroundColor = [UIColor systemBackgroundColor];
        } else {
            self.backgroundColor = [UIColor whiteColor];
        }

        // Native bottom hairline separator
        UIView *hairline = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - 0.5, frame.size.width, 0.5)];
        hairline.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        if (@available(iOS 13.0, *)) {
            hairline.backgroundColor = [UIColor separatorColor];
        } else {
            hairline.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        }
        [self addSubview:hairline];

        [self setupUI];
        _selectedFolderId = @"all";

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(reloadTabs)
                   name:MSGChatFoldersDataChangedNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.alwaysBounceHorizontal = YES;
    self.scrollView.contentInset = UIEdgeInsetsMake(0, kTabViewPadding, 0, kTabViewPadding);
    [self addSubview:self.scrollView];

    self.tabButtons = [NSMutableArray array];

    // "+" button (create folder)
    self.addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.addButton setTitle:@"＋" forState:UIControlStateNormal];
    self.addButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.addButton addTarget:self action:@selector(addButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.addButton.layer.cornerRadius = kTabCornerRadius;
    self.addButton.layer.borderWidth = 1.5;
    [self.scrollView addSubview:self.addButton];

    // "📂" button (pick conversation to assign)
    self.pickButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickButton setTitle:@"📂" forState:UIControlStateNormal];
    self.pickButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.pickButton addTarget:self action:@selector(pickButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.pickButton.layer.cornerRadius = kTabCornerRadius;
    self.pickButton.layer.borderWidth = 1.5;
    [self.scrollView addSubview:self.pickButton];
}

#pragma mark - Reload

- (void)reloadTabs {
    for (UIButton *btn in self.tabButtons) {
        [btn removeFromSuperview];
    }
    [self.tabButtons removeAllObjects];

    BOOL isDark = NO;
    if (@available(iOS 13.0, *)) {
        isDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    }

    UIColor *bgNormal     = isDark ? [UIColor colorWithWhite:0.2 alpha:1.0]
                                   : [UIColor colorWithWhite:0.92 alpha:1.0];
    UIColor *bgSelected   = isDark ? [UIColor colorWithRed:0.0 green:0.55 blue:1.0 alpha:1.0]
                                   : [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    UIColor *textNormal   = isDark ? [UIColor colorWithWhite:0.85 alpha:1.0]
                                   : [UIColor colorWithWhite:0.3 alpha:1.0];
    UIColor *textSelected = [UIColor whiteColor];

    // "All" button
    UIButton *allBtn = [self makeTabButtonWithTitle:@"All" tag:0];
    [self.tabButtons addObject:allBtn];
    [self.scrollView addSubview:allBtn];

    // Folder buttons
    NSArray<MSGChatFolder *> *folders = [[MSGChatFolderManager sharedManager] allFolders];
    for (NSUInteger i = 0; i < folders.count; i++) {
        MSGChatFolder *folder = folders[i];
        NSString *title = folder.name;
        NSUInteger count = folder.threadKeys.count;
        if (count > 0) {
            title = [NSString stringWithFormat:@"%@ (%lu)", folder.name, (unsigned long)count];
        }
        UIButton *btn = [self makeTabButtonWithTitle:title tag:(NSInteger)(i + 1)];
        btn.accessibilityIdentifier = folder.folderId;
        [self.tabButtons addObject:btn];
        [self.scrollView addSubview:btn];
    }

    // Layout
    CGFloat x = 0;
    for (UIButton *btn in self.tabButtons) {
        [btn sizeToFit];
        CGFloat w = btn.bounds.size.width + (kTabHPadding * 2);
        btn.frame = CGRectMake(x, kTabViewPadding, w, kTabHeight);
        x += w + kTabSpacing;

        BOOL isSelected = [self isButtonSelected:btn];
        btn.backgroundColor = isSelected ? bgSelected : bgNormal;
        [btn setTitleColor:isSelected ? textSelected : textNormal forState:UIControlStateNormal];
    }

    UIColor *borderColor = isDark ? [UIColor colorWithWhite:0.4 alpha:1.0]
                                  : [UIColor colorWithWhite:0.75 alpha:1.0];

    // "+" button
    self.addButton.frame = CGRectMake(x, kTabViewPadding, kTabHeight, kTabHeight);
    self.addButton.layer.borderColor = borderColor.CGColor;
    [self.addButton setTitleColor:textNormal forState:UIControlStateNormal];
    self.addButton.backgroundColor = [UIColor clearColor];
    x += kTabHeight + kTabSpacing;

    // "📂" button
    self.pickButton.frame = CGRectMake(x, kTabViewPadding, kTabHeight, kTabHeight);
    self.pickButton.layer.borderColor = borderColor.CGColor;
    self.pickButton.backgroundColor = [UIColor clearColor];
    x += kTabHeight + kTabSpacing;

    self.scrollView.contentSize = CGSizeMake(x, kTabHeight + (kTabViewPadding * 2));
    self.scrollView.frame = CGRectMake(0, 0, self.bounds.size.width,
                                       kTabHeight + (kTabViewPadding * 2));
}

- (UIButton *)makeTabButtonWithTitle:(NSString *)title tag:(NSInteger)tag {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    btn.layer.cornerRadius = kTabCornerRadius;
    btn.clipsToBounds = YES;
    btn.tag = kTagBase + tag;

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.contentInsets = NSDirectionalEdgeInsetsMake(0, kTabHPadding, 0, kTabHPadding);
        btn.configuration = config;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        btn.contentEdgeInsets = UIEdgeInsetsMake(0, kTabHPadding, 0, kTabHPadding);
#pragma clang diagnostic pop
    }

    [btn addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(tabLongPressed:)];
    longPress.minimumPressDuration = 0.5;
    [btn addGestureRecognizer:longPress];

    return btn;
}

- (BOOL)isButtonSelected:(UIButton *)btn {
    NSInteger idx = btn.tag - kTagBase;
    if (idx == 0) {
        return !self.selectedFolderId || [self.selectedFolderId isEqualToString:@"all"];
    }
    return [btn.accessibilityIdentifier isEqualToString:self.selectedFolderId];
}

#pragma mark - Actions

- (void)tabTapped:(UIButton *)sender {
    NSInteger idx = sender.tag - kTagBase;
    NSString *folderId = (idx == 0) ? @"all" : sender.accessibilityIdentifier;

    self.selectedFolderId = folderId;
    [[MSGChatFolderManager sharedManager] setSelectedFolderId:folderId];
    [self reloadTabs];

    if ([self.delegate respondsToSelector:@selector(folderTabView:didSelectFolderId:)]) {
        [self.delegate folderTabView:self didSelectFolderId:folderId];
    }
}

- (void)addButtonTapped {
    if ([self.delegate respondsToSelector:@selector(folderTabViewDidTapCreateFolder:)]) {
        [self.delegate folderTabViewDidTapCreateFolder:self];
    }
}

- (void)pickButtonTapped {
    NSLog(@"[MSGChatFolders] 📂 Pick button tapped — posting notification");
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MSGChatFoldersShowPickerNotification
                      object:nil];
}

- (void)tabLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *btn = (UIButton *)gesture.view;
    NSInteger idx = btn.tag - kTagBase;
    if (idx == 0) return;

    NSString *folderId = btn.accessibilityIdentifier;
    if (folderId && [self.delegate respondsToSelector:@selector(folderTabView:didLongPressFolderId:)]) {
        [self.delegate folderTabView:self didLongPressFolderId:folderId];
    }
}

#pragma mark - Trait Changes

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self reloadTabs];
        }
    }
}

@end
