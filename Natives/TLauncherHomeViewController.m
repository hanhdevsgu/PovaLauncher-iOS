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
@property(nonatomic) UIView *launchCard;
@property(nonatomic) NSLayoutConstraint *cardCenterYConstraint;

@property(nonatomic) UIImageView *avatarImageView;
@property(nonatomic) UITextField *usernameField;
@property(nonatomic) UIButton *accountListButton;

@property(nonatomic) UIStackView *idleVersionStack;
@property(nonatomic) UILabel *versionTitleLabel;
@property(nonatomic) UILabel *versionSubtitleLabel;

@property(nonatomic) UIStackView *progressStack;
@property(nonatomic) UIProgressView *downloadProgressView;
@property(nonatomic) UILabel *downloadStatusLabel;
@property(nonatomic) UIButton *detailsButton;

@property(nonatomic) UIButton *playButton;

@property(nonatomic) MinecraftResourceDownloadTask *downloadTask;
@property(nonatomic) UINavigationController *progressVC;
@property(nonatomic) BOOL isObservingProgress;
@property(nonatomic, assign) volatile BOOL cancelledJITWait;
@property(nonatomic) UIAlertController *jitWaitAlert;
@property(nonatomic) NSTimeInterval lastSpeedSampleTime;
@property(nonatomic) int64_t lastCompletedBytes;

@end

@implementation TLauncherHomeViewController

#pragma mark - Theme Palette

+ (UIColor *)bgObsidian { return [UIColor colorWithRed:0.059 green:0.078 blue:0.098 alpha:1.0]; }     // #0F1419
+ (UIColor *)surfaceSlate { return [UIColor colorWithRed:0.090 green:0.118 blue:0.149 alpha:1.0]; }   // #171E26
+ (UIColor *)cardInsetBg { return [UIColor colorWithRed:0.067 green:0.090 blue:0.114 alpha:1.0]; }    // #11171D
+ (UIColor *)borderHairline { return [UIColor colorWithRed:0.149 green:0.188 blue:0.239 alpha:1.0]; } // #26303D
+ (UIColor *)textPrimary { return [UIColor colorWithRed:0.945 green:0.961 blue:0.976 alpha:1.0]; }    // #F1F5F9
+ (UIColor *)textMuted { return [UIColor colorWithRed:0.541 green:0.588 blue:0.659 alpha:1.0]; }      // #8A96A8
+ (UIColor *)emeraldPrimary { return [UIColor colorWithRed:0.180 green:0.627 blue:0.263 alpha:1.0]; } // #2EA043
+ (UIColor *)emeraldBright { return [UIColor colorWithRed:0.247 green:0.725 blue:0.314 alpha:1.0]; }  // #3FB950

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopObservingDownloadProgress];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [TLauncherHomeViewController bgObsidian];

    // Ensure clean non-demo GameDir environment
    unsetenv("DEMO_LOCK");
    if (getenv("AME_HOME")) {
        NSString *defaultGameDir = [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("AME_HOME")];
        setenv("GAME_DIR", defaultGameDir.UTF8String, 1);
    }

    [self setupMinimalTLauncherLayout];
    [self restoreInitialOfflineAccount];
    [self refreshVersionSubtitle];

    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleKeyboardFrameNotification:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleKeyboardHideNotification:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // Background AltKit discovery for iOS <= 16.x AltStore/SideStore Wi-Fi JIT
    if (!isJITEnabled(false) && getEntitlementValue(@"get-task-allow")) {
        if (@available(iOS 17.0, *)) {
            // iOS 17+ JIT triggered on Play via StikJIT/SideStore/AltServer
        } else {
            [self tryAltKitEnableJITSilently];
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshVersionSubtitle];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([getPrefObject(@"control.control_safe_area") length] == 0) {
        setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(getDefaultSafeArea()));
    }
    [self refreshVersionSubtitle];
}

#pragma mark - Minimalist TLauncher UI (Center Stage + Keyboard Safe)

- (void)setupMinimalTLauncherLayout {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // 1. Clean Top Bar (44pt tall)
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
    brandTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    brandTitle.textColor = [TLauncherHomeViewController textPrimary];

    UIView *versionBadge = [UIView new];
    versionBadge.translatesAutoresizingMaskIntoConstraints = NO;
    versionBadge.backgroundColor = [[TLauncherHomeViewController emeraldPrimary] colorWithAlphaComponent:0.18];
    versionBadge.layer.cornerRadius = 6;
    versionBadge.layer.borderWidth = 1;
    versionBadge.layer.borderColor = [[TLauncherHomeViewController emeraldBright] colorWithAlphaComponent:0.4].CGColor;

    UILabel *versionBadgeLabel = [UILabel new];
    versionBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionBadgeLabel.text = @"1.12.2";
    versionBadgeLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    versionBadgeLabel.textColor = [TLauncherHomeViewController emeraldBright];
    [versionBadge addSubview:versionBadgeLabel];
    [NSLayoutConstraint activateConstraints:@[
        [versionBadgeLabel.topAnchor constraintEqualToAnchor:versionBadge.topAnchor constant:2],
        [versionBadgeLabel.bottomAnchor constraintEqualToAnchor:versionBadge.bottomAnchor constant:-2],
        [versionBadgeLabel.leadingAnchor constraintEqualToAnchor:versionBadge.leadingAnchor constant:7],
        [versionBadgeLabel.trailingAnchor constraintEqualToAnchor:versionBadge.trailingAnchor constant:-7],
    ]];

    UIButton *btnControls = [self makeToolbarButtonWithTitle:@"Điều khiển" icon:@"gamecontroller.fill" action:@selector(actionOpenControls)];
    UILongPressGestureRecognizer *resetHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(actionHoldResetControls:)];
    [btnControls addGestureRecognizer:resetHold];

    UIButton *btnInstallJar = [self makeToolbarButtonWithTitle:@"Cài .jar" icon:@"shippingbox.fill" action:@selector(actionOpenJarInstaller)];
    UIButton *btnSettings = [self makeToolbarButtonWithTitle:@"Cài đặt" icon:@"gearshape.fill" action:@selector(actionOpenSettings)];
    UIButton *btnLogs = [self makeToolbarButtonWithTitle:@"Nhật ký" icon:@"doc.text.fill" action:@selector(actionOpenLogs)];

    UIStackView *toolbarStack = [[UIStackView alloc] initWithArrangedSubviews:@[btnControls, btnInstallJar, btnSettings, btnLogs]];
    toolbarStack.translatesAutoresizingMaskIntoConstraints = NO;
    toolbarStack.axis = UILayoutConstraintAxisHorizontal;
    toolbarStack.spacing = 6;

    [self.headerView addSubview:brandIcon];
    [self.headerView addSubview:brandTitle];
    [self.headerView addSubview:versionBadge];
    [self.headerView addSubview:toolbarStack];

    // 2. Stage Guide (Space below header)
    UILayoutGuide *stageGuide = [UILayoutGuide new];
    [self.view addLayoutGuide:stageGuide];

    // 3. Single Clean Centered TLauncher Card
    self.launchCard = [UIView new];
    self.launchCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchCard.backgroundColor = [TLauncherHomeViewController surfaceSlate];
    self.launchCard.layer.cornerRadius = 14;
    self.launchCard.layer.borderWidth = 1;
    self.launchCard.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    [self.view addSubview:self.launchCard];

    // Row 1: Offline Username Box
    UIView *accountContainer = [UIView new];
    accountContainer.translatesAutoresizingMaskIntoConstraints = NO;
    accountContainer.backgroundColor = [TLauncherHomeViewController bgObsidian];
    accountContainer.layer.cornerRadius = 10;
    accountContainer.layer.borderWidth = 1;
    accountContainer.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    [self.launchCard addSubview:accountContainer];

    self.avatarImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"DefaultAccount"]];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.magnificationFilter = kCAFilterNearest;
    self.avatarImageView.layer.minificationFilter = kCAFilterNearest;
    self.avatarImageView.layer.cornerRadius = 5;
    self.avatarImageView.clipsToBounds = YES;

    self.usernameField = [UITextField new];
    self.usernameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameField.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.usernameField.textColor = [TLauncherHomeViewController textPrimary];
    self.usernameField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Nhập tên nhân vật (3-16 ký tự)"
            attributes:@{NSForegroundColorAttributeName: [TLauncherHomeViewController textMuted]}];
    self.usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.usernameField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.usernameField.returnKeyType = UIReturnKeyDone;
    self.usernameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.usernameField.delegate = self;

    self.accountListButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.accountListButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    [self.accountListButton setImage:[UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:chevCfg] forState:UIControlStateNormal];
    self.accountListButton.tintColor = [TLauncherHomeViewController textMuted];
    [self.accountListButton addTarget:self action:@selector(actionPickSavedOfflineAccount:) forControlEvents:UIControlEventTouchUpInside];

    [accountContainer addSubview:self.avatarImageView];
    [accountContainer addSubview:self.usernameField];
    [accountContainer addSubview:self.accountListButton];

    // Row 2 Left: Version Info OR Progress Bar
    self.versionTitleLabel = [UILabel new];
    self.versionTitleLabel.text = @"Release 1.12.2";
    self.versionTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    self.versionTitleLabel.textColor = [TLauncherHomeViewController textPrimary];

    self.versionSubtitleLabel = [UILabel new];
    self.versionSubtitleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.versionSubtitleLabel.textColor = [TLauncherHomeViewController textMuted];
    self.versionSubtitleLabel.text = @"Offline • Sẵn sàng vào server PC";

    self.idleVersionStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.versionTitleLabel, self.versionSubtitleLabel]];
    self.idleVersionStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.idleVersionStack.axis = UILayoutConstraintAxisVertical;
    self.idleVersionStack.spacing = 2;
    [self.launchCard addSubview:self.idleVersionStack];

    self.downloadStatusLabel = [UILabel new];
    self.downloadStatusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.downloadStatusLabel.textColor = [TLauncherHomeViewController emeraldBright];

    self.detailsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.detailsButton setTitle:@"Chi tiết" forState:UIControlStateNormal];
    [self.detailsButton setTitleColor:[TLauncherHomeViewController emeraldBright] forState:UIControlStateNormal];
    self.detailsButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [self.detailsButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.detailsButton addTarget:self action:@selector(actionShowDownloadDetails:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *progTopRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.downloadStatusLabel, self.detailsButton]];
    progTopRow.axis = UILayoutConstraintAxisHorizontal;
    progTopRow.spacing = 6;
    progTopRow.alignment = UIStackViewAlignmentCenter;

    self.downloadProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.downloadProgressView.progressTintColor = [TLauncherHomeViewController emeraldBright];
    self.downloadProgressView.trackTintColor = [TLauncherHomeViewController borderHairline];

    self.progressStack = [[UIStackView alloc] initWithArrangedSubviews:@[progTopRow, self.downloadProgressView]];
    self.progressStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressStack.axis = UILayoutConstraintAxisVertical;
    self.progressStack.spacing = 6;
    self.progressStack.hidden = YES;
    [self.launchCard addSubview:self.progressStack];

    // Row 2 Right: Emerald Play Button
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
    [self.launchCard addSubview:self.playButton];

    self.cardCenterYConstraint = [self.launchCard.centerYAnchor constraintEqualToAnchor:stageGuide.centerYAnchor constant:0];

    NSLayoutConstraint *preferredWidth = [self.launchCard.widthAnchor constraintEqualToConstant:440];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        // Header bar
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:44],

        [headerDivider.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [headerDivider.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor],
        [headerDivider.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [headerDivider.heightAnchor constraintEqualToConstant:1],

        [brandIcon.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [brandIcon.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [brandIcon.widthAnchor constraintEqualToConstant:24],
        [brandIcon.heightAnchor constraintEqualToConstant:24],

        [brandTitle.leadingAnchor constraintEqualToAnchor:brandIcon.trailingAnchor constant:8],
        [brandTitle.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],

        [versionBadge.leadingAnchor constraintEqualToAnchor:brandTitle.trailingAnchor constant:7],
        [versionBadge.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],

        [toolbarStack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [toolbarStack.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [toolbarStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:versionBadge.trailingAnchor constant:8],

        // Stage guide
        [stageGuide.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [stageGuide.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [stageGuide.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stageGuide.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],

        // Centered Launch Card
        [self.launchCard.centerXAnchor constraintEqualToAnchor:stageGuide.centerXAnchor],
        self.cardCenterYConstraint,
        preferredWidth,
        [self.launchCard.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [self.launchCard.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],

        // Username row inside card
        [accountContainer.topAnchor constraintEqualToAnchor:self.launchCard.topAnchor constant:14],
        [accountContainer.leadingAnchor constraintEqualToAnchor:self.launchCard.leadingAnchor constant:14],
        [accountContainer.trailingAnchor constraintEqualToAnchor:self.launchCard.trailingAnchor constant:-14],
        [accountContainer.heightAnchor constraintEqualToConstant:46],

        [self.avatarImageView.leadingAnchor constraintEqualToAnchor:accountContainer.leadingAnchor constant:9],
        [self.avatarImageView.centerYAnchor constraintEqualToAnchor:accountContainer.centerYAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:28],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:28],

        [self.usernameField.leadingAnchor constraintEqualToAnchor:self.avatarImageView.trailingAnchor constant:10],
        [self.usernameField.centerYAnchor constraintEqualToAnchor:accountContainer.centerYAnchor],
        [self.usernameField.trailingAnchor constraintEqualToAnchor:self.accountListButton.leadingAnchor constant:-6],

        [self.accountListButton.trailingAnchor constraintEqualToAnchor:accountContainer.trailingAnchor constant:-6],
        [self.accountListButton.centerYAnchor constraintEqualToAnchor:accountContainer.centerYAnchor],
        [self.accountListButton.widthAnchor constraintEqualToConstant:32],
        [self.accountListButton.heightAnchor constraintEqualToConstant:32],

        // Play button bottom-right inside card
        [self.playButton.topAnchor constraintEqualToAnchor:accountContainer.bottomAnchor constant:12],
        [self.playButton.trailingAnchor constraintEqualToAnchor:self.launchCard.trailingAnchor constant:-14],
        [self.playButton.bottomAnchor constraintEqualToAnchor:self.launchCard.bottomAnchor constant:-14],
        [self.playButton.widthAnchor constraintEqualToConstant:164],
        [self.playButton.heightAnchor constraintEqualToConstant:42],

        // Left version/progress stacks aligned beside Play button
        [self.idleVersionStack.leadingAnchor constraintEqualToAnchor:self.launchCard.leadingAnchor constant:16],
        [self.idleVersionStack.trailingAnchor constraintEqualToAnchor:self.playButton.leadingAnchor constant:-12],
        [self.idleVersionStack.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],

        [self.progressStack.leadingAnchor constraintEqualToAnchor:self.launchCard.leadingAnchor constant:14],
        [self.progressStack.trailingAnchor constraintEqualToAnchor:self.playButton.leadingAnchor constant:-12],
        [self.progressStack.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
    ]];
}

- (UIButton *)makeToolbarButtonWithTitle:(NSString *)title icon:(NSString *)symbolName action:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [TLauncherHomeViewController cardInsetBg];
    button.layer.cornerRadius = 7;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [TLauncherHomeViewController borderHairline].CGColor;
    button.tintColor = [TLauncherHomeViewController textPrimary];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[TLauncherHomeViewController textPrimary] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:11.5 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg] forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(5, 9, 5, 9);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Keyboard Avoidance (Landscape iPhone)

- (void)handleKeyboardFrameNotification:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    CGRect kbEndScreen = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInView = [self.view convertRect:kbEndScreen fromView:nil];
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];

    CGFloat viewHeight = self.view.bounds.size.height;
    CGFloat kbTopY = CGRectGetMinY(kbInView);

    if (kbTopY >= viewHeight - 10.0) {
        [self animateCardVerticalOffset:0.0 duration:duration curve:curve];
        return;
    }

    [self.view layoutIfNeeded];
    CGFloat headerBottom = CGRectGetMaxY(self.headerView.frame);
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;
    CGFloat stageNaturalCenterY = (headerBottom + (viewHeight - safeBottom)) * 0.5;
    CGFloat cardHeight = self.launchCard.bounds.size.height;

    // Keep at least the Username row (top 68pt of launchCard) completely clear above the keyboard
    CGFloat maxAllowedCardBottom = kbTopY - 8.0;
    CGFloat desiredCenterY = maxAllowedCardBottom - (cardHeight * 0.5);
    CGFloat minCenterForHeader = headerBottom + 6.0 + (cardHeight * 0.5);

    // If screen is extra short (e.g., 320pt SE landscape), pin card top right under header so Username box never leaves screen
    CGFloat finalCenterY;
    if (desiredCenterY < minCenterForHeader) {
        finalCenterY = minCenterForHeader;
    } else {
        finalCenterY = MIN(stageNaturalCenterY, desiredCenterY);
    }
    CGFloat offset = finalCenterY - stageNaturalCenterY;
    [self animateCardVerticalOffset:MIN(0.0, offset) duration:duration curve:curve];
}

- (void)handleKeyboardHideNotification:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [self animateCardVerticalOffset:0.0 duration:duration curve:curve];
}

- (void)animateCardVerticalOffset:(CGFloat)offset duration:(NSTimeInterval)duration curve:(NSInteger)curve {
    self.cardCenterYConstraint.constant = offset;
    UIViewAnimationOptions options = (UIViewAnimationOptions)((curve << 16) | UIViewAnimationOptionBeginFromCurrentState);
    [UIView animateWithDuration:(duration > 0 ? duration : 0.25)
                          delay:0
                        options:options
                     animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

#pragma mark - Offline Accounts & Version Status

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

- (void)refreshVersionSubtitle {
    [PLProfiles updateCurrent];
    NSString *gameDir = getenv("GAME_DIR") ? @(getenv("GAME_DIR")) : @"";
    NSString *jarPath = [NSString stringWithFormat:@"%@/versions/%@/%@.jar", gameDir, PovaTargetVersion, PovaTargetVersion];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", gameDir, PovaTargetVersion, PovaTargetVersion];
    BOOL installed = [NSFileManager.defaultManager fileExistsAtPath:jarPath] && [NSFileManager.defaultManager fileExistsAtPath:jsonPath];
    self.versionSubtitleLabel.text = installed
        ? @"Offline • Đã sẵn sàng (Server PC: Multiplayer)"
        : @"Offline • Sẽ tự tải 1.12.2 khi bấm CHƠI GAME";
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Header & Account Actions

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

- (void)actionHoldResetControls:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Điều khiển Pojav Android"
                                                                   message:@"Khôi phục bộ 16 nút mặc định chuẩn PojavLauncher Android?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Khôi phục mặc định" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        if (getenv("AME_HOME")) {
            NSString *defaultCtrlPath = [NSString stringWithFormat:@"%s/controlmap/default.json", getenv("AME_HOME")];
            [NSFileManager.defaultManager removeItemAtPath:defaultCtrlPath error:nil];
            generateAndSaveDefaultControl();
            setPrefObject(@"control.default_ctrl", @"default.json");
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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

- (void)actionPickSavedOfflineAccount:(UIButton *)sender {
    [self dismissKeyboard];
    NSArray<NSString *> *accounts = [self savedOfflineUsernames];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Tài khoản Offline đã lưu"
                                                                   message:(accounts.count == 0 ? @"Chưa có tài khoản đã lưu. Hãy nhập tên và bấm CHƠI GAME." : nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in accounts) {
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [BaseAuthenticator loadSavedName:name];
            setPrefObject(@"internal.selected_account", name);
            self.usernameField.text = name;
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
        showDialog(@"Tên không hợp lệ", @"Tên nhân vật Offline phải dài 3–16 ký tự (chỉ gồm chữ A–Z, số 0–9 và dấu gạch dưới _).");
        [self.usernameField becomeFirstResponder];
        return;
    }

    LocalAuthenticator *auth = [[LocalAuthenticator alloc] initWithInput:trimmed];
    [auth loginWithCallback:^(id status, BOOL success) {
        if (!success) {
            NSString *msg = [status isKindOfClass:NSError.class] ? [(NSError *)status localizedDescription] : @"Không thể lưu tài khoản offline.";
            showDialog(@"Lỗi đăng nhập", msg);
            return;
        }

        setPrefObject(@"internal.selected_account", trimmed);
        self.usernameField.text = trimmed;
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
            [weakSelf refreshVersionSubtitle];
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

    self.idleVersionStack.hidden = active;
    self.progressStack.hidden = !active;
    if (active) {
        self.downloadStatusLabel.text = @"Đang kiểm tra / tải 1.12.2...";
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
        [self refreshVersionSubtitle];

        if (metadata) {
            UIWindow *targetWindow = self.view.window ?: UIWindow.mainWindow;
            [self runAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(targetWindow, metadata);
            }];
        }
    });
}

#pragma mark - JIT Handling (StikJIT / SideStore / AltKit / Cancel-Safe)

- (void)tryAltKitEnableJITSilently {
    [ALTServerManager.sharedManager startDiscovering];
    [ALTServerManager.sharedManager autoconnectWithCompletionHandler:^(ALTServerConnection *connection, NSError *error) {
        if (error || !connection) {
            return;
        }
        [connection enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError *enableErr) {
            [connection disconnect];
            if (success) {
                [ALTServerManager.sharedManager stopDiscovering];
            }
        }];
    }];
}

- (NSURL *)jitHelperURLForDevice {
    if (getEntitlementValue(@"jb.pmap_cs.custom_trust")) {
        return [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
    }
    if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            if (scriptData) {
                scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
            }
        }
        return [NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]];
}

- (void)presentJITPromptAlert {
    if (self.cancelledJITWait || isJITEnabled(false)) {
        return;
    }

    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    NSString *message = hasTrollStoreJIT
        ? @"Hãy bật URL Scheme trong cài đặt TrollStore cho PovaLauncher để cấp quyền JIT tự động."
        : @"iOS chặn Java chạy Minecraft nếu chưa cấp quyền JIT (Just-In-Time).\n\n"
          @"Cách bật nhanh:\n"
          @"1. Mở StikJIT / StikDebug (hoặc SideStore / AltServer trên PC) rồi cấp JIT cho PovaLauncher.\n"
          @"2. Quay lại app này, game sẽ tự động mở.\n\n"
          @"(Nếu cài Sideloadly thường chưa gắn PC/StikJIT, bấm Hủy để chuẩn bị JIT trước.)";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cần bật JIT để chạy Java"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Mở StikJIT / Hỗ trợ JIT" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIApplication.sharedApplication openURL:[weakSelf jitHelperURLForDevice] options:@{} completionHandler:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf presentJITPromptAlert];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Thử AltServer Wi-Fi" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf tryAltKitEnableJITSilently];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf presentJITPromptAlert];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        weakSelf.cancelledJITWait = YES;
        weakSelf.jitWaitAlert = nil;
        [ALTServerManager.sharedManager stopDiscovering];
    }]];

    self.jitWaitAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runAfterJITEnabled:(void(^)(void))handler {
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    }

    if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"[PovaLauncher] Debug skipped waiting for JIT.");
        handler();
        return;
    }

    self.cancelledJITWait = NO;
    NSURL *helperURL = [self jitHelperURLForDevice];
    [UIApplication.sharedApplication openURL:helperURL options:@{} completionHandler:nil];
    [self tryAltKitEnableJITSilently];
    [self presentJITPromptAlert];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false) && !weakSelf.cancelledJITWait) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [ALTServerManager.sharedManager stopDiscovering];
            if (weakSelf.cancelledJITWait) {
                return;
            }
            UIAlertController *currentAlert = weakSelf.jitWaitAlert;
            weakSelf.jitWaitAlert = nil;
            if (currentAlert && currentAlert.presentingViewController) {
                [currentAlert dismissViewControllerAnimated:YES completion:handler];
            } else {
                handler();
            }
        });
    });
}

#pragma mark - UIPopoverPresentationControllerDelegate

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

@end
