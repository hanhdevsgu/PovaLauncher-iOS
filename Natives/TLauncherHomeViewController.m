#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/time.h>

#import "TLauncherHomeViewController.h"
#import "ALTServerConnection.h"
#import "authenticator/BaseAuthenticator.h"
#import "customcontrols/CustomControlsUtils.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

static void *PovaProgressObserverContext = &PovaProgressObserverContext;
static NSString * const PovaTargetVersion = @"1.12.2";

@interface TLauncherHomeViewController () <UITextFieldDelegate, UIDocumentPickerDelegate, UIPopoverPresentationControllerDelegate>

@property(nonatomic) UIView *headerView;
@property(nonatomic) UIView *versionBadgeView;
@property(nonatomic) UILabel *versionBadgeLabel;
@property(nonatomic) UILabel *statusPillLabel;
@property(nonatomic) UILabel *rendererValueLabel;
@property(nonatomic) UILabel *ramValueLabel;
@property(nonatomic) UILabel *jitValueLabel;
@property(nonatomic) UIButton *controlsResetButton;

@property(nonatomic) UIView *dockView;
@property(nonatomic) UIImageView *avatarImageView;
@property(nonatomic) UITextField *usernameField;
@property(nonatomic) UIButton *accountListButton;
@property(nonatomic) UILabel *versionTitleLabel;
@property(nonatomic) UILabel *uuidPreviewLabel;
@property(nonatomic) UIProgressView *downloadProgressView;
@property(nonatomic) UILabel *downloadStatusLabel;
@property(nonatomic) UIButton *detailsButton;
@property(nonatomic) UIButton *playButton;

@property(nonatomic) MinecraftResourceDownloadTask *downloadTask;
@property(nonatomic) UINavigationController *progressVC;
@property(nonatomic) BOOL isObservingProgress;
@property(nonatomic) UIAlertController *jitWaitAlert;
@property(nonatomic) NSTimeInterval lastSpeedSampleTime;
@property(nonatomic) int64_t lastCompletedBytes;

@end

@implementation TLauncherHomeViewController

#pragma mark - Theme Palette & Scale

+ (UIColor *)bgObsidian { return [UIColor colorWithRed:0.059 green:0.078 blue:0.098 alpha:1.0]; }     // #0F1419
+ (UIColor *)surfaceSlate { return [UIColor colorWithRed:0.090 green:0.118 blue:0.149 alpha:1.0]; }   // #171E26
+ (UIColor *)cardInsetBg { return [UIColor colorWithRed:0.067 green:0.090 blue:0.114 alpha:1.0]; }    // #11171D
+ (UIColor *)borderHairline { return [UIColor colorWithRed:0.149 green:0.188 blue:0.239 alpha:1.0]; } // #26303D
+ (UIColor *)textPrimary { return [UIColor colorWithRed:0.945 green:0.961 blue:0.976 alpha:1.0]; }    // #F1F5F9
+ (UIColor *)textMuted { return [UIColor colorWithRed:0.541 green:0.588 blue:0.659 alpha:1.0]; }      // #8A96A8
+ (UIColor *)emeraldPrimary { return [UIColor colorWithRed:0.180 green:0.627 blue:0.263 alpha:1.0]; } // #2EA043
+ (UIColor *)emeraldBright { return [UIColor colorWithRed:0.247 green:0.725 blue:0.314 alpha:1.0]; }  // #3FB950
+ (UIColor *)amberAccent { return [UIColor colorWithRed:0.824 green:0.600 blue:0.133 alpha:1.0]; }    // #D29922

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)dealloc {
    [self stopObservingDownloadProgress];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [TLauncherHomeViewController bgObsidian];

    // Ensure non-demo GameDir environment
    unsetenv("DEMO_LOCK");
    if (getenv("AME_HOME")) {
        NSString *defaultGameDir = [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("AME_HOME")];
        setenv("GAME_DIR", defaultGameDir.UTF8String, 1);
    }

    [self setupLayout];
    [self restoreInitialOfflineAccount];
    [self refreshDashboardState];
    [self updateUUIDPreview];

    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDashboardState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([getPrefObject(@"control.control_safe_area") length] == 0) {
        setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(getDefaultSafeArea()));
    }
    [self refreshDashboardState];
}

#pragma mark - UI Construction

- (void)setupLayout {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // 1. Top Header Bar
    self.headerView = [UIView new];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.backgroundColor = [TLauncherHomeViewController surfaceSlate];
    [self.view addSubview:self.headerView];

    UIView *headerDivider = [UIView new];
    headerDivider.translatesAutoresizingMaskIntoConstraints = NO;
    headerDivider.backgroundColor = [TLauncherHomeViewController borderHairline];
    [self.headerView addSubview:headerDivider];

    UIImageView *brandIcon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"DefaultProfile"]];
    brandIcon.translatesAutoresizingMaskIntoConstraints = NO;
    brandIcon.contentMode = UIViewContentModeScaleAspectFit;
    brandIcon.layer.magnificationFilter = kCAFilterNearest;
    brandIcon.layer.minificationFilter = kCAFilterNearest;
    brandIcon.layer.cornerRadius = 5;
    brandIcon.clipsToBounds = YES;

    UILabel *brandTitle = [UILabel new];
    brandTitle.translatesAutoresizingMaskIntoConstraints = NO;
    brandTitle.text = @"POVALAUNCHER";
    brandTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
    brandTitle.textColor = [TLauncherHomeViewController textPrimary];

    self.versionBadgeView = [UIView new];
    self.versionBadgeView.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionBadgeView.backgroundColor = [[TLauncherHomeViewController emeraldPrimary] colorWithAlphaComponent:0.18];
    self.versionBadgeView.layer.cornerRadius = 6;
    self.versionBadgeView.layer.borderWidth = 1;
    self.versionBadgeView.layer.borderColor = [[TLauncherHomeViewController emeraldBright] colorWithAlphaComponent:0.45].CGColor;

    self.versionBadgeLabel = [UILabel new];
    self.versionBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionBadgeLabel.text = @"1.12.2";
    self.versionBadgeLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    self.versionBadgeLabel.textColor = [TLauncherHomeViewController emeraldBright];
    [self.versionBadgeView addSubview:self.versionBadgeLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.versionBadgeLabel.topAnchor constraintEqualToAnchor:self.versionBadgeView.topAnchor constant:3],
        [self.versionBadgeLabel.bottomAnchor constraintEqualToAnchor:self.versionBadgeView.bottomAnchor constant:-3],
        [self.versionBadgeLabel.leadingAnchor constraintEqualToAnchor:self.versionBadgeView.leadingAnchor constant:7],
        [self.versionBadgeLabel.trailingAnchor constraintEqualToAnchor:self.versionBadgeView.trailingAnchor constant:-7],
    ]];

    UIButton *btnControls = [self makeToolbarButtonWithTitle:@"Điều khiển" icon:@"gamecontroller.fill" action:@selector(actionOpenControls)];
    UIButton *btnInstallJar = [self makeToolbarButtonWithTitle:@"Cài .jar" icon:@"shippingbox.fill" action:@selector(actionOpenJarInstaller)];
    UIButton *btnSettings = [self makeToolbarButtonWithTitle:@"Cài đặt" icon:@"gearshape.fill" action:@selector(actionOpenSettings)];
    UIButton *btnLogs = [self makeToolbarButtonWithTitle:@"Nhật ký" icon:@"doc.text.fill" action:@selector(actionOpenLogs)];

    UIStackView *toolbarStack = [[UIStackView alloc] initWithArrangedSubviews:@[btnControls, btnInstallJar, btnSettings, btnLogs]];
    toolbarStack.translatesAutoresizingMaskIntoConstraints = NO;
    toolbarStack.axis = UILayoutConstraintAxisHorizontal;
    toolbarStack.spacing = 8;

    [self.headerView addSubview:brandIcon];
    [self.headerView addSubview:brandTitle];
    [self.headerView addSubview:self.versionBadgeView];
    [self.headerView addSubview:toolbarStack];

    // 2. Bottom TLauncher Dock
    self.dockView = [UIView new];
    self.dockView.translatesAutoresizingMaskIntoConstraints = NO;
    self.dockView.backgroundColor = [TLauncherHomeViewController surfaceSlate];
    [self.view addSubview:self.dockView];

    UIView *dockDivider = [UIView new];
    dockDivider.translatesAutoresizingMaskIntoConstraints = NO;
    dockDivider.backgroundColor = [TLauncherHomeViewController borderHairline];
    [self.dockView addSubview:dockDivider];

    // Account Box
    UIView *accountContainer = [UIView new];
    accountContainer.translatesAutoresizingMaskIntoConstraints = NO;
    accountContainer.backgroundColor = [TLauncherHomeViewController bgObsidian];
    accountContainer.layer.cornerRadius = 10;
    accountContainer.layer.borderWidth = 1;
    accountContainer.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    [self.dockView addSubview:accountContainer];

    self.avatarImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"DefaultAccount"]];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.magnificationFilter = kCAFilterNearest;
    self.avatarImageView.layer.minificationFilter = kCAFilterNearest;
    self.avatarImageView.layer.cornerRadius = 5;
    self.avatarImageView.clipsToBounds = YES;

    self.usernameField = [UITextField new];
    self.usernameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameField.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.usernameField.textColor = [TLauncherHomeViewController textPrimary];
    self.usernameField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Tên Offline (3-16 ký tự)"
            attributes:@{NSForegroundColorAttributeName: [TLauncherHomeViewController textMuted]}];
    self.usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.usernameField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.usernameField.returnKeyType = UIReturnKeyDone;
    self.usernameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.usernameField.delegate = self;
    [self.usernameField addTarget:self action:@selector(usernameTextChanged:) forControlEvents:UIControlEventEditingChanged];

    self.accountListButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.accountListButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    [self.accountListButton setImage:[UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:chevCfg] forState:UIControlStateNormal];
    self.accountListButton.tintColor = [TLauncherHomeViewController textMuted];
    [self.accountListButton addTarget:self action:@selector(actionPickSavedOfflineAccount:) forControlEvents:UIControlEventTouchUpInside];

    [accountContainer addSubview:self.avatarImageView];
    [accountContainer addSubview:self.usernameField];
    [accountContainer addSubview:self.accountListButton];

    // Fixed Version & Progress Center Block
    UIView *versionContainer = [UIView new];
    versionContainer.translatesAutoresizingMaskIntoConstraints = NO;
    versionContainer.backgroundColor = [TLauncherHomeViewController bgObsidian];
    versionContainer.layer.cornerRadius = 10;
    versionContainer.layer.borderWidth = 1;
    versionContainer.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    [self.dockView addSubview:versionContainer];

    self.versionTitleLabel = [UILabel new];
    self.versionTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionTitleLabel.text = @"Release 1.12.2 (Cố định)";
    self.versionTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    self.versionTitleLabel.textColor = [TLauncherHomeViewController textPrimary];

    self.uuidPreviewLabel = [UILabel new];
    self.uuidPreviewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.uuidPreviewLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.uuidPreviewLabel.textColor = [TLauncherHomeViewController textMuted];
    self.uuidPreviewLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    self.downloadProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.downloadProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadProgressView.progressTintColor = [TLauncherHomeViewController emeraldBright];
    self.downloadProgressView.trackTintColor = [TLauncherHomeViewController borderHairline];
    self.downloadProgressView.hidden = YES;

    self.downloadStatusLabel = [UILabel new];
    self.downloadStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadStatusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.downloadStatusLabel.textColor = [TLauncherHomeViewController emeraldBright];
    self.downloadStatusLabel.hidden = YES;

    self.detailsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.detailsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailsButton setTitle:@"Chi tiết" forState:UIControlStateNormal];
    self.detailsButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.detailsButton setTitleColor:[TLauncherHomeViewController emeraldBright] forState:UIControlStateNormal];
    self.detailsButton.hidden = YES;
    [self.detailsButton addTarget:self action:@selector(actionShowDownloadDetails:) forControlEvents:UIControlEventTouchUpInside];

    [versionContainer addSubview:self.versionTitleLabel];
    [versionContainer addSubview:self.uuidPreviewLabel];
    [versionContainer addSubview:self.downloadProgressView];
    [versionContainer addSubview:self.downloadStatusLabel];
    [versionContainer addSubview:self.detailsButton];

    // Emerald Play Button
    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton.backgroundColor = [TLauncherHomeViewController emeraldPrimary];
    self.playButton.layer.cornerRadius = 10;
    [self.playButton setTitle:@"CHƠI GAME" forState:UIControlStateNormal];
    [self.playButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.playButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    UIImageSymbolConfiguration *playCfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIFontWeightBold];
    [self.playButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:playCfg] forState:UIControlStateNormal];
    self.playButton.tintColor = UIColor.whiteColor;
    self.playButton.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 6);
    [self.playButton addTarget:self action:@selector(actionPlayPressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.dockView addSubview:self.playButton];

    // 3. Scrollable Center Dashboard
    UIScrollView *centerScroll = [UIScrollView new];
    centerScroll.translatesAutoresizingMaskIntoConstraints = NO;
    centerScroll.showsVerticalScrollIndicator = NO;
    centerScroll.alwaysBounceVertical = NO;
    [self.view addSubview:centerScroll];

    UIView *leftCard = [self buildEngineStatusCard];
    UIView *rightCard = [self buildMultiplayerGuideCard];

    UIStackView *cardsRow = [[UIStackView alloc] initWithArrangedSubviews:@[leftCard, rightCard]];
    cardsRow.translatesAutoresizingMaskIntoConstraints = NO;
    cardsRow.axis = UILayoutConstraintAxisHorizontal;
    cardsRow.spacing = 12;
    cardsRow.alignment = UIStackViewAlignmentFill;
    cardsRow.distribution = UIStackViewDistributionFill;
    [centerScroll addSubview:cardsRow];

    [NSLayoutConstraint activateConstraints:@[
        // Header bar pinned top
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:50],

        [headerDivider.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [headerDivider.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor],
        [headerDivider.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [headerDivider.heightAnchor constraintEqualToConstant:1],

        [brandIcon.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [brandIcon.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [brandIcon.widthAnchor constraintEqualToConstant:26],
        [brandIcon.heightAnchor constraintEqualToConstant:26],

        [brandTitle.leadingAnchor constraintEqualToAnchor:brandIcon.trailingAnchor constant:8],
        [brandTitle.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],

        [self.versionBadgeView.leadingAnchor constraintEqualToAnchor:brandTitle.trailingAnchor constant:8],
        [self.versionBadgeView.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],

        [toolbarStack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [toolbarStack.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [toolbarStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.versionBadgeView.trailingAnchor constant:10],

        // Dock pinned bottom
        [self.dockView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.dockView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.dockView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [dockDivider.topAnchor constraintEqualToAnchor:self.dockView.topAnchor],
        [dockDivider.leadingAnchor constraintEqualToAnchor:self.dockView.leadingAnchor],
        [dockDivider.trailingAnchor constraintEqualToAnchor:self.dockView.trailingAnchor],
        [dockDivider.heightAnchor constraintEqualToConstant:1],

        [accountContainer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [accountContainer.topAnchor constraintEqualToAnchor:self.dockView.topAnchor constant:10],
        [accountContainer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [accountContainer.heightAnchor constraintEqualToConstant:44],
        [accountContainer.widthAnchor constraintGreaterThanOrEqualToConstant:200],
        [accountContainer.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:0.35],

        [self.avatarImageView.leadingAnchor constraintEqualToAnchor:accountContainer.leadingAnchor constant:8],
        [self.avatarImageView.centerYAnchor constraintEqualToAnchor:accountContainer.centerYAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:28],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:28],

        [self.usernameField.leadingAnchor constraintEqualToAnchor:self.avatarImageView.trailingAnchor constant:8],
        [self.usernameField.centerYAnchor constraintEqualToAnchor:accountContainer.centerYAnchor],
        [self.usernameField.trailingAnchor constraintEqualToAnchor:self.accountListButton.leadingAnchor constant:-4],

        [self.accountListButton.trailingAnchor constraintEqualToAnchor:accountContainer.trailingAnchor constant:-6],
        [self.accountListButton.centerYAnchor constraintEqualToAnchor:accountContainer.centerYAnchor],
        [self.accountListButton.widthAnchor constraintEqualToConstant:30],
        [self.accountListButton.heightAnchor constraintEqualToConstant:30],

        [self.playButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.playButton.topAnchor constraintEqualToAnchor:self.dockView.topAnchor constant:10],
        [self.playButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [self.playButton.widthAnchor constraintEqualToConstant:168],

        [versionContainer.leadingAnchor constraintEqualToAnchor:accountContainer.trailingAnchor constant:10],
        [versionContainer.trailingAnchor constraintEqualToAnchor:self.playButton.leadingAnchor constant:-10],
        [versionContainer.topAnchor constraintEqualToAnchor:self.dockView.topAnchor constant:10],
        [versionContainer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],

        [self.versionTitleLabel.leadingAnchor constraintEqualToAnchor:versionContainer.leadingAnchor constant:12],
        [self.versionTitleLabel.topAnchor constraintEqualToAnchor:versionContainer.topAnchor constant:6],
        [self.versionTitleLabel.trailingAnchor constraintEqualToAnchor:self.detailsButton.leadingAnchor constant:-6],

        [self.uuidPreviewLabel.leadingAnchor constraintEqualToAnchor:versionContainer.leadingAnchor constant:12],
        [self.uuidPreviewLabel.trailingAnchor constraintEqualToAnchor:versionContainer.trailingAnchor constant:-12],
        [self.uuidPreviewLabel.bottomAnchor constraintEqualToAnchor:versionContainer.bottomAnchor constant:-6],

        [self.downloadStatusLabel.leadingAnchor constraintEqualToAnchor:versionContainer.leadingAnchor constant:12],
        [self.downloadStatusLabel.topAnchor constraintEqualToAnchor:versionContainer.topAnchor constant:6],
        [self.downloadStatusLabel.trailingAnchor constraintEqualToAnchor:self.detailsButton.leadingAnchor constant:-6],

        [self.downloadProgressView.leadingAnchor constraintEqualToAnchor:versionContainer.leadingAnchor constant:12],
        [self.downloadProgressView.trailingAnchor constraintEqualToAnchor:versionContainer.trailingAnchor constant:-12],
        [self.downloadProgressView.bottomAnchor constraintEqualToAnchor:versionContainer.bottomAnchor constant:-10],

        [self.detailsButton.trailingAnchor constraintEqualToAnchor:versionContainer.trailingAnchor constant:-10],
        [self.detailsButton.topAnchor constraintEqualToAnchor:versionContainer.topAnchor constant:4],
        [self.detailsButton.widthAnchor constraintGreaterThanOrEqualToConstant:52],

        // Scrollable center grid
        [centerScroll.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [centerScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [centerScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [centerScroll.bottomAnchor constraintEqualToAnchor:self.dockView.topAnchor],

        [cardsRow.topAnchor constraintEqualToAnchor:centerScroll.contentLayoutGuide.topAnchor constant:12],
        [cardsRow.bottomAnchor constraintEqualToAnchor:centerScroll.contentLayoutGuide.bottomAnchor constant:-12],
        [cardsRow.leadingAnchor constraintEqualToAnchor:centerScroll.contentLayoutGuide.leadingAnchor constant:12],
        [cardsRow.trailingAnchor constraintEqualToAnchor:centerScroll.contentLayoutGuide.trailingAnchor constant:-12],
        [cardsRow.widthAnchor constraintEqualToAnchor:centerScroll.frameLayoutGuide.widthAnchor constant:-24],
        [leftCard.widthAnchor constraintEqualToAnchor:rightCard.widthAnchor multiplier:1.28],
    ]];
}

- (UIView *)buildEngineStatusCard {
    UIView *card = [self makeCardView];

    UILabel *cardTitle = [UILabel new];
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    cardTitle.text = @"Minecraft Java Edition 1.12.2";
    cardTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    cardTitle.textColor = [TLauncherHomeViewController textPrimary];

    self.statusPillLabel = [UILabel new];
    self.statusPillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPillLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    self.statusPillLabel.textAlignment = NSTextAlignmentCenter;
    self.statusPillLabel.layer.cornerRadius = 6;
    self.statusPillLabel.clipsToBounds = YES;

    UILabel *rendererTitle = [self makeMutedLabel:@"ĐỒ HỌA"];
    self.rendererValueLabel = [self makeMetricValueLabel:@"GL4ES 1.1.4"];
    UIView *rendererTile = [self makeMetricTileWithTitleLabel:rendererTitle valueLabel:self.rendererValueLabel];

    UILabel *ramTitle = [self makeMutedLabel:@"RAM JVM (CHẠM ĐỂ CHỈNH)"];
    self.ramValueLabel = [self makeMetricValueLabel:@"Tự động"];
    UIView *ramTile = [self makeMetricTileWithTitleLabel:ramTitle valueLabel:self.ramValueLabel];
    ramTile.userInteractionEnabled = YES;
    [ramTile addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(actionQuickPickRAM)]];

    UILabel *jitTitle = [self makeMutedLabel:@"TRẠNG THÁI JIT"];
    self.jitValueLabel = [self makeMetricValueLabel:@"Đang kiểm tra"];
    UIView *jitTile = [self makeMetricTileWithTitleLabel:jitTitle valueLabel:self.jitValueLabel];

    UILabel *layoutTitle = [self makeMutedLabel:@"BỐ CỤC PHÍM"];
    UILabel *layoutValue = [self makeMetricValueLabel:@"Pojav Android (16 nút)"];
    UIView *layoutTile = [self makeMetricTileWithTitleLabel:layoutTitle valueLabel:layoutValue];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[rendererTile, ramTile]];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.spacing = 8;
    row1.distribution = UIStackViewDistributionFillEqually;

    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[jitTile, layoutTile]];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.spacing = 8;
    row2.distribution = UIStackViewDistributionFillEqually;

    UIStackView *metricsStack = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    metricsStack.translatesAutoresizingMaskIntoConstraints = NO;
    metricsStack.axis = UILayoutConstraintAxisVertical;
    metricsStack.spacing = 8;

    self.controlsResetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.controlsResetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.controlsResetButton setTitle:@"Khôi phục 16 phím Pojav Android mặc định" forState:UIControlStateNormal];
    [self.controlsResetButton setTitleColor:[TLauncherHomeViewController textPrimary] forState:UIControlStateNormal];
    self.controlsResetButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.controlsResetButton.backgroundColor = [TLauncherHomeViewController cardInsetBg];
    self.controlsResetButton.layer.cornerRadius = 8;
    self.controlsResetButton.layer.borderWidth = 1;
    self.controlsResetButton.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    self.controlsResetButton.contentEdgeInsets = UIEdgeInsetsMake(7, 10, 7, 10);
    [self.controlsResetButton addTarget:self action:@selector(actionResetAndroidControls) forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:cardTitle];
    [card addSubview:self.statusPillLabel];
    [card addSubview:metricsStack];
    [card addSubview:self.controlsResetButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],

        [self.statusPillLabel.centerYAnchor constraintEqualToAnchor:cardTitle.centerYAnchor],
        [self.statusPillLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.statusPillLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:cardTitle.trailingAnchor constant:8],
        [self.statusPillLabel.heightAnchor constraintEqualToConstant:22],
        [self.statusPillLabel.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [metricsStack.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [metricsStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [metricsStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [self.controlsResetButton.topAnchor constraintEqualToAnchor:metricsStack.bottomAnchor constant:12],
        [self.controlsResetButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.controlsResetButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    return card;
}

- (UIView *)buildMultiplayerGuideCard {
    UIView *card = [self makeCardView];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Kết nối Server PC (Netty 340)";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = [TLauncherHomeViewController textPrimary];

    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = @"Chơi chung Server Java 1.12.2 bằng tên Offline — không cần tài khoản Microsoft.";
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    sub.textColor = [TLauncherHomeViewController textMuted];
    sub.numberOfLines = 0;

    UIView *step1 = [self makeStepRowWithNumber:@"1" text:@"Nhập Tên Offline (3–16 ký tự) vào ô bên dưới."];
    UIView *step2 = [self makeStepRowWithNumber:@"2" text:@"Bấm CHƠI GAME (lần đầu tự tải bản gốc 1.12.2)."];
    UIView *step3 = [self makeStepRowWithNumber:@"3" text:@"Vào Multiplayer → Direct Connect / Add Server → nhập IP:Port Server PC."];

    UIStackView *steps = [[UIStackView alloc] initWithArrangedSubviews:@[step1, step2, step3]];
    steps.translatesAutoresizingMaskIntoConstraints = NO;
    steps.axis = UILayoutConstraintAxisVertical;
    steps.spacing = 8;

    [card addSubview:title];
    [card addSubview:sub];
    [card addSubview:steps];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [sub.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [steps.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:12],
        [steps.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [steps.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [steps.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    return card;
}

- (UIButton *)makeToolbarButtonWithTitle:(NSString *)title icon:(NSString *)symbolName action:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [TLauncherHomeViewController cardInsetBg];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    button.tintColor = [TLauncherHomeViewController textPrimary];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[TLauncherHomeViewController textPrimary] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIFontWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg] forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)makeCardView {
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [TLauncherHomeViewController surfaceSlate];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    return card;
}

- (UILabel *)makeMutedLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    label.textColor = [TLauncherHomeViewController textMuted];
    return label;
}

- (UILabel *)makeMetricValueLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [TLauncherHomeViewController textPrimary];
    return label;
}

- (UIView *)makeMetricTileWithTitleLabel:(UILabel *)titleLabel valueLabel:(UILabel *)valueLabel {
    UIView *tile = [UIView new];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = [TLauncherHomeViewController cardInsetBg];
    tile.layer.cornerRadius = 8;
    tile.layer.borderWidth = 1;
    tile.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    [tile addSubview:titleLabel];
    [tile addSubview:valueLabel];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:tile.topAnchor constant:8],
        [titleLabel.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:10],
        [titleLabel.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-10],
        [valueLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],
        [valueLabel.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:10],
        [valueLabel.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-10],
        [valueLabel.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-8],
    ]];
    return tile;
}

- (UIView *)makeStepRowWithNumber:(NSString *)num text:(NSString *)text {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *badge = [UILabel new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = num;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    badge.textColor = [TLauncherHomeViewController emeraldBright];
    badge.backgroundColor = [[TLauncherHomeViewController emeraldPrimary] colorWithAlphaComponent:0.16];
    badge.layer.cornerRadius = 6;
    badge.clipsToBounds = YES;

    UILabel *desc = [UILabel new];
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    desc.text = text;
    desc.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    desc.textColor = [TLauncherHomeViewController textPrimary];
    desc.numberOfLines = 0;

    [row addSubview:badge];
    [row addSubview:desc];
    [NSLayoutConstraint activateConstraints:@[
        [badge.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [badge.topAnchor constraintEqualToAnchor:row.topAnchor constant:1],
        [badge.widthAnchor constraintEqualToConstant:22],
        [badge.heightAnchor constraintEqualToConstant:22],

        [desc.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:8],
        [desc.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [desc.topAnchor constraintEqualToAnchor:row.topAnchor],
        [desc.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];
    return row;
}

#pragma mark - Offline Accounts & Dashboard State

+ (NSString *)offlineUUIDForUsername:(NSString *)username {
    if (username.length == 0) {
        return @"";
    }
    NSString *source = [@"OfflinePlayer:" stringByAppendingString:username];
    const char *utf8 = source.UTF8String;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(utf8, (CC_LONG)strlen(utf8), digest);
#pragma clang diagnostic pop
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            digest[6], digest[7],
            digest[8], digest[9],
            digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]];
}

+ (BOOL)isValidOfflineUsername:(NSString *)username {
    if (username.length < 3 || username.length > 16) {
        return NO;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9_]{3,16}$" options:0 error:nil];
    return [regex firstMatchInString:username options:0 range:NSMakeRange(0, username.length)] != nil;
}

- (void)restoreInitialOfflineAccount {
    NSString *savedSelected = getPrefObject(@"internal.selected_account");
    if (savedSelected.length > 0 && ![savedSelected hasPrefix:@"Demo."]) {
        id loaded = [BaseAuthenticator loadSavedName:savedSelected];
        if (loaded && BaseAuthenticator.current.authData[@"xboxGamertag"] == nil) {
            self.usernameField.text = savedSelected;
            return;
        }
    }
    NSArray<NSString *> *offlineAccounts = [self savedOfflineUsernames];
    if (offlineAccounts.count > 0) {
        NSString *first = offlineAccounts.firstObject;
        [BaseAuthenticator loadSavedName:first];
        setPrefObject(@"internal.selected_account", first);
        self.usernameField.text = first;
    } else {
        self.usernameField.text = @"Player";
    }
}

- (NSArray<NSString *> *)savedOfflineUsernames {
    if (!getenv("AME_HOME")) {
        return @[];
    }
    NSString *accountsDir = [NSString stringWithFormat:@"%s/accounts", getenv("AME_HOME")];
    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:accountsDir error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) {
            continue;
        }
        NSDictionary *dict = parseJSONFromFile([accountsDir stringByAppendingPathComponent:file]);
        NSString *username = dict[@"username"];
        if (username.length > 0 && ![username hasPrefix:@"Demo."] && dict[@"xboxGamertag"] == nil) {
            [names addObject:username];
        }
    }
    [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return names;
}

- (void)usernameTextChanged:(UITextField *)sender {
    [self updateUUIDPreview];
}

- (void)updateUUIDPreview {
    NSString *trimmed = [self.usernameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if ([TLauncherHomeViewController isValidOfflineUsername:trimmed]) {
        self.uuidPreviewLabel.text = [NSString stringWithFormat:@"Offline UUID: %@", [TLauncherHomeViewController offlineUUIDForUsername:trimmed]];
        self.uuidPreviewLabel.textColor = [TLauncherHomeViewController textMuted];
    } else {
        self.uuidPreviewLabel.text = @"Tên hợp lệ: 3–16 ký tự (A-Z, 0-9, _)";
        self.uuidPreviewLabel.textColor = [TLauncherHomeViewController amberAccent];
    }
}

- (void)refreshDashboardState {
    // Ensure fixed 1.12.2 profile stays selected
    [PLProfiles updateCurrent];

    // Check local 1.12.2 jar presence
    NSString *gameDir = getenv("GAME_DIR") ? @(getenv("GAME_DIR")) : @"";
    NSString *jarPath = [NSString stringWithFormat:@"%@/versions/%@/%@.jar", gameDir, PovaTargetVersion, PovaTargetVersion];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", gameDir, PovaTargetVersion, PovaTargetVersion];
    BOOL installed = [NSFileManager.defaultManager fileExistsAtPath:jarPath] && [NSFileManager.defaultManager fileExistsAtPath:jsonPath];
    if (installed) {
        self.statusPillLabel.text = @"  ĐÃ SẴN SÀNG  ";
        self.statusPillLabel.backgroundColor = [[TLauncherHomeViewController emeraldPrimary] colorWithAlphaComponent:0.20];
        self.statusPillLabel.textColor = [TLauncherHomeViewController emeraldBright];
    } else {
        self.statusPillLabel.text = @"  SẼ TẢI 1.12.2  ";
        self.statusPillLabel.backgroundColor = [[TLauncherHomeViewController amberAccent] colorWithAlphaComponent:0.20];
        self.statusPillLabel.textColor = [TLauncherHomeViewController amberAccent];
    }

    // Renderer
    NSString *renderer = getPrefObject(@"video.renderer") ?: @"libgl4es_114.dylib";
    if ([renderer isEqualToString:@ RENDERER_NAME_GL4ES] || [renderer isEqualToString:@"auto"]) {
        self.rendererValueLabel.text = @"GL4ES 1.1.4 (Tối ưu 1.12.2)";
    } else {
        self.rendererValueLabel.text = renderer;
    }

    // RAM
    if (getPrefBool(@"java.auto_ram")) {
        self.ramValueLabel.text = @"Tự động";
    } else {
        NSInteger mb = getPrefInt(@"java.allocated_memory");
        self.ramValueLabel.text = [NSString stringWithFormat:@"%ld MB", (long)mb];
    }

    // JIT
    BOOL jit = isJITEnabled(false);
    self.jitValueLabel.text = jit ? @"Đã bật JIT" : @"Chờ bật khi vào game";
    self.jitValueLabel.textColor = jit ? [TLauncherHomeViewController emeraldBright] : [TLauncherHomeViewController textPrimary];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Header & Quick Actions

- (void)actionOpenControls {
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name) {
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^NSString *() {
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)actionResetAndroidControls {
    if (!getenv("AME_HOME")) {
        return;
    }
    NSString *defaultCtrlPath = [NSString stringWithFormat:@"%s/controlmap/default.json", getenv("AME_HOME")];
    [NSFileManager.defaultManager removeItemAtPath:defaultCtrlPath error:nil];
    generateAndSaveDefaultControl();
    setPrefObject(@"control.default_ctrl", @"default.json");
    [self.controlsResetButton setTitle:@"Đã khôi phục 16 phím Pojav Android ✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.controlsResetButton setTitle:@"Khôi phục 16 phím Pojav Android mặc định" forState:UIControlStateNormal];
    });
}

- (void)actionOpenJarInstaller {
    UTType *jarByExt = [UTType typeWithFilenameExtension:@"jar"];
    UTType *jarByMime = [UTType typeWithMIMEType:@"application/java-archive"];
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (jarByExt) [types addObject:jarByExt];
    if (jarByMime && ![types containsObject:jarByMime]) [types addObject:jarByMime];
    if (types.count == 0) [types addObject:UTTypeItem];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = url.path;
    [vc setHitEnterAfterWindowShown:NO];
    if (!vc.requiredJavaVersion) {
        return;
    }
    [self runAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)actionOpenSettings {
    LauncherPreferencesViewController *prefsVC = [[LauncherPreferencesViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:prefsVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)actionOpenLogs {
    if (!getenv("AME_HOME")) {
        return;
    }
    NSString *currLog = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("AME_HOME")];
    NSString *oldLog = [NSString stringWithFormat:@"%s/latestlog.old.txt", getenv("AME_HOME")];
    NSString *targetPath = [NSFileManager.defaultManager fileExistsAtPath:currLog] ? currLog : oldLog;

    if (![NSFileManager.defaultManager fileExistsAtPath:targetPath]) {
        showDialog(@"Nhật ký", @"Chưa có tệp nhật ký nào được ghi.");
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:targetPath];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = self.headerView;
    activityVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMaxX(self.headerView.bounds) - 60, CGRectGetMaxY(self.headerView.bounds), 1, 1);
    [self presentViewController:activityVC animated:YES completion:nil];
}

- (void)actionQuickPickRAM {
    NSUInteger maxMB = (NSUInteger)((NSProcessInfo.processInfo.physicalMemory / 1048576.0) * 0.85);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Chọn mức RAM JVM"
                                                                   message:[NSString stringWithFormat:@"Thiết bị hỗ trợ tối đa ~%lu MB", (unsigned long)maxMB]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tự động (Auto RAM)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        setPrefBool(@"java.auto_ram", YES);
        [self refreshDashboardState];
    }]];
    NSArray<NSNumber *> *presets = @[@(512), @(768), @(1024), @(1536), @(2048)];
    for (NSNumber *preset in presets) {
        if (preset.unsignedIntegerValue <= maxMB) {
            [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%d MB", preset.intValue]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull action) {
                setPrefBool(@"java.auto_ram", NO);
                setPrefInt(@"java.allocated_memory", preset.integerValue);
                [self refreshDashboardState];
            }]];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.ramValueLabel;
    sheet.popoverPresentationController.sourceRect = self.ramValueLabel.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)actionPickSavedOfflineAccount:(UIButton *)sender {
    [self dismissKeyboard];
    NSArray<NSString *> *accounts = [self savedOfflineUsernames];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Tài khoản Offline đã lưu"
                                                                   message:(accounts.count == 0 ? @"Chưa có tài khoản offline nào. Hãy nhập tên và bấm CHƠI GAME." : nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in accounts) {
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [BaseAuthenticator loadSavedName:name];
            setPrefObject(@"internal.selected_account", name);
            self.usernameField.text = name;
            [self updateUUIDPreview];
        }]];
    }
    NSString *currentName = [self.usernameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (currentName.length > 0 && [accounts containsObject:currentName]) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Xóa \"%@\"", currentName]
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            NSString *accFile = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("AME_HOME"), currentName];
            [NSFileManager.defaultManager removeItemAtPath:accFile error:nil];
            if ([BaseAuthenticator.current.authData[@"username"] isEqualToString:currentName]) {
                BaseAuthenticator.current = nil;
                setPrefObject(@"internal.selected_account", @"");
            }
            self.usernameField.text = @"";
            [self updateUUIDPreview];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Play & Download 1.12.2 Flow

- (void)actionPlayPressed:(UIButton *)sender {
    [self dismissKeyboard];

    NSString *rawName = self.usernameField.text ?: @"";
    NSString *trimmed = [rawName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![TLauncherHomeViewController isValidOfflineUsername:trimmed]) {
        showDialog(@"Tên không hợp lệ", @"Vui lòng nhập Tên nhân vật Offline dài 3–16 ký tự (chỉ gồm chữ cái A–Z, số 0–9 và dấu gạch dưới _).");
        [self.usernameField becomeFirstResponder];
        return;
    }

    LocalAuthenticator *auth = [[LocalAuthenticator alloc] initWithInput:trimmed];
    [auth loginWithCallback:^(id status, BOOL success) {
        if (!success) {
            NSString *msg = [status isKindOfClass:NSError.class] ? [(NSError *)status localizedDescription] : @"Không thể tạo tài khoản offline.";
            showDialog(@"Lỗi đăng nhập", msg);
            return;
        }

        setPrefObject(@"internal.selected_account", trimmed);
        self.usernameField.text = trimmed;
        [self updateUUIDPreview];

        [self startDownloadAndLaunch1122];
    }];
}

- (void)startDownloadAndLaunch1122 {
    if (self.downloadTask != nil) {
        return;
    }

    [self setDownloadUIActive:YES];
    self.lastSpeedSampleTime = 0;
    self.lastCompletedBytes = 0;

    NSDictionary *versionObject = @{
        @"id": PovaTargetVersion,
        @"type": @"release",
        @"url": @"https://piston-meta.mojang.com/v1/packages/832d95b9f40699d4961394dcf6cf549e65f15dc5/1.12.2.json",
        @"sha1": @"832d95b9f40699d4961394dcf6cf549e65f15dc5"
    };

    self.downloadTask = [MinecraftResourceDownloadTask new];
    __weak typeof(self) weakSelf = self;
    self.downloadTask.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf stopObservingDownloadProgress];
            [weakSelf.progressVC dismissViewControllerAnimated:NO completion:nil];
            weakSelf.progressVC = nil;
            weakSelf.downloadTask = nil;
            [weakSelf setDownloadUIActive:NO];
            [weakSelf refreshDashboardState];
        });
    };

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [weakSelf.downloadTask downloadVersion:versionObject];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf.downloadTask || !weakSelf.downloadTask.progress) {
                return;
            }
            weakSelf.downloadProgressView.observedProgress = weakSelf.downloadTask.progress;
            [weakSelf.downloadTask.progress addObserver:weakSelf
                                             forKeyPath:@"fractionCompleted"
                                                options:NSKeyValueObservingOptionInitial
                                                context:PovaProgressObserverContext];
            weakSelf.isObservingProgress = YES;
        });
    });
}

- (void)stopObservingDownloadProgress {
    if (self.isObservingProgress && self.downloadTask.progress) {
        @try {
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted" context:PovaProgressObserverContext];
        } @catch (NSException *ignored) {}
    }
    self.isObservingProgress = NO;
    self.downloadProgressView.observedProgress = nil;
}

- (void)setDownloadUIActive:(BOOL)active {
    self.playButton.enabled = !active;
    self.playButton.alpha = active ? 0.55 : 1.0;
    self.usernameField.enabled = !active;
    self.accountListButton.enabled = !active;

    self.versionTitleLabel.hidden = active;
    self.uuidPreviewLabel.hidden = active;
    self.downloadProgressView.hidden = !active;
    self.downloadStatusLabel.hidden = !active;
    self.detailsButton.hidden = !active;
    if (active) {
        self.downloadStatusLabel.text = @"Đang chuẩn bị Minecraft 1.12.2...";
    }
    UIApplication.sharedApplication.idleTimerDisabled = active;
}

- (void)actionShowDownloadDetails:(UIButton *)sender {
    if (!self.downloadTask) {
        return;
    }
    if (!self.progressVC) {
        UIViewController *vc = [[DownloadProgressViewController alloc] initWithTask:self.downloadTask];
        self.progressVC = [[UINavigationController alloc] initWithRootViewController:vc];
        self.progressVC.modalPresentationStyle = UIModalPresentationPopover;
    } else if (self.progressVC.presentingViewController != nil) {
        return;
    }
    self.progressVC.popoverPresentationController.delegate = self;
    self.progressVC.popoverPresentationController.sourceView = sender;
    self.progressVC.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:self.progressVC animated:YES completion:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != PovaProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (!self.downloadTask) {
        return;
    }

    NSProgress *totalProg = self.downloadTask.progress;
    NSProgress *textProg = self.downloadTask.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSTimeInterval now = tv.tv_sec + tv.tv_usec / 1000000.0;
    int64_t completedBytes = (int64_t)(totalProg.totalUnitCount * totalProg.fractionCompleted);
    textProg.completedUnitCount = completedBytes;

    if (now - self.lastSpeedSampleTime >= 1.0) {
        NSTimeInterval dt = MAX(0.1, now - self.lastSpeedSampleTime);
        int64_t throughput = (int64_t)((completedBytes - self.lastCompletedBytes) / dt);
        if (throughput > 0) {
            textProg.throughput = @(throughput);
            textProg.estimatedTimeRemaining = @((double)(textProg.totalUnitCount - completedBytes) / (double)throughput);
        }
        self.lastCompletedBytes = completedBytes;
        self.lastSpeedSampleTime = now;
    }

    NSString *desc = textProg.localizedAdditionalDescription ?: @"Đang tải tài nguyên 1.12.2...";
    BOOL finished = textProg.finished || (totalProg.totalUnitCount > 0 && totalProg.completedUnitCount >= totalProg.totalUnitCount && totalProg.fractionCompleted >= 1.0);

    dispatch_async(dispatch_get_main_queue(), ^{
        self.downloadStatusLabel.text = desc;
        if (!finished) {
            return;
        }

        NSDictionary *metadata = self.downloadTask.metadata;
        [self stopObservingDownloadProgress];
        [self.progressVC dismissViewControllerAnimated:NO completion:nil];
        self.progressVC = nil;
        self.downloadTask = nil;
        [self setDownloadUIActive:NO];
        [self refreshDashboardState];

        if (metadata) {
            UIWindow *targetWindow = self.view.window ?: UIWindow.mainWindow;
            [self runAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(targetWindow, metadata);
            }];
        }
    });
}

#pragma mark - JIT Check

- (void)runAfterJITEnabled:(void(^)(void))handler {
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    }

    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"[PovaLauncher] Debug skipped waiting for JIT.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            if (scriptData) {
                scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
            }
        }
        NSString *stikURL = [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:stikURL] options:@{} completionHandler:nil];
    } else {
        NSString *sideURL = [NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:sideURL] options:@{} completionHandler:nil];
    }

    self.jitWaitAlert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
                                                              message:(hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil))
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:self.jitWaitAlert animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.jitWaitAlert dismissViewControllerAnimated:YES completion:handler];
            weakSelf.jitWaitAlert = nil;
        });
    });
}

#pragma mark - UIPopoverPresentationControllerDelegate

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

@end
