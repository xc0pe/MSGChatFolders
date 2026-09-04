//
//  MSGChatFolderTabView.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Horizontal scrollable tab bar. Adapts to Messenger's dark/light mode.
//  Each folder is a pill-shaped button. Selected folder is highlighted.
//

#import "MSGChatFolderTabView.h"
#import "MSGChatFolderManager.h"

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
@end

@implementation MSGChatFolderTabView

+ (CGFloat)preferredHeight {
    return kTabHeight + (kTabViewPadding * 2);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
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
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.alwaysBounceHorizontal = YES;
    self.scrollView.contentInset = UIEdgeInsetsMake(0, kTabViewPadding, 0, kTabViewPadding);
    [self addSubview:self.scrollView];

    self.tabButtons = [NSMutableArray array];

    // Create "+" button (always at the end)
    self.addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.addButton setTitle:@"＋" forState:UIControlStateNormal];
    self.addButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.addButton addTarget:self action:@selector(addButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.addButton.layer.cornerRadius = kTabCornerRadius;
    self.addButton.layer.borderWidth = 1.5;
    [self.scrollView addSubview:self.addButton];
}

#pragma mark - Reload

- (void)reloadTabs {
    // Remove old buttons
    for (UIButton *btn in self.tabButtons) {
        [btn removeFromSuperview];
    }
    [self.tabButtons removeAllObjects];

    // Detect dark mode
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
        // Store folderId via associated object-like approach: use layer.name
        btn.accessibilityIdentifier = folder.folderId;
        [self.tabButtons addObject:btn];
        [self.scrollView addSubview:btn];
    }

    // Layout all buttons
    CGFloat x = 0;
    for (UIButton *btn in self.tabButtons) {
        [btn sizeToFit];
        CGFloat w = btn.bounds.size.width + (kTabHPadding * 2);
        btn.frame = CGRectMake(x, kTabViewPadding, w, kTabHeight);
        x += w + kTabSpacing;

        // Apply style
        BOOL isSelected = [self isButtonSelected:btn];
        btn.backgroundColor = isSelected ? bgSelected : bgNormal;
        [btn setTitleColor:isSelected ? textSelected : textNormal forState:UIControlStateNormal];
    }

    // "+" button at the end
    self.addButton.frame = CGRectMake(x, kTabViewPadding, kTabHeight, kTabHeight);
    self.addButton.layer.borderColor = isDark ? [UIColor colorWithWhite:0.4 alpha:1.0].CGColor
                                              : [UIColor colorWithWhite:0.75 alpha:1.0].CGColor;
    [self.addButton setTitleColor:textNormal forState:UIControlStateNormal];
    self.addButton.backgroundColor = [UIColor clearColor];
    x += kTabHeight + kTabSpacing;

    self.scrollView.contentSize = CGSizeMake(x, kTabHeight + (kTabViewPadding * 2));
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

    // Long press for rename/delete
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
    NSString *folderId;

    if (idx == 0) {
        folderId = @"all";
    } else {
        folderId = sender.accessibilityIdentifier;
    }

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

- (void)tabLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *btn = (UIButton *)gesture.view;
    NSInteger idx = btn.tag - kTagBase;

    // Don't allow long-press on "All"
    if (idx == 0) return;

    NSString *folderId = btn.accessibilityIdentifier;
    if (folderId && [self.delegate respondsToSelector:@selector(folderTabView:didLongPressFolderId:)]) {
        [self.delegate folderTabView:self didLongPressFolderId:folderId];
    }
}

#pragma mark - Trait Changes (Dark/Light Mode)

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self reloadTabs];
        }
    }
}

@end
