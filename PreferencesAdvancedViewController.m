//
//  PreferencesAdvancedViewController.m
//  SelfControl
//
//  Created by Charles Stigler on 9/27/14.
//
//

#import "PreferencesAdvancedViewController.h"
#import "SCConstants.h"
#import "SCUIUtilities.h"

static NSString* const kTrustedTimeSourceURLsDefaultsKey = @"TrustedTimeSourceURLs";
static NSString* const kTrustedTimeConsensusRequiredCountDefaultsKey = @"TrustedTimeConsensusRequiredCount";
static NSString* const kTrustedTimeConsensusMaxSkewSecondsDefaultsKey = @"TrustedTimeConsensusMaxSkewSeconds";
static NSInteger const kTrustedTimeDefaultRequiredCount = 2;
static NSTimeInterval const kTrustedTimeDefaultMaxSkewSeconds = 10.0;
static NSTimeInterval const kTrustedTimeMinimumMaxSkewSeconds = 1.0;
static NSTimeInterval const kTrustedTimeMaximumMaxSkewSeconds = 300.0;

@interface PreferencesAdvancedViewController () <NSTextFieldDelegate, NSTextViewDelegate>

@property (nonatomic, weak) IBOutlet NSScrollView* trustedTimeSourcesScrollView;
@property (nonatomic, strong) NSTextView* trustedTimeSourcesTextView;
@property (nonatomic, weak) IBOutlet NSTextField* trustedTimeConsensusCountField;
@property (nonatomic, weak) IBOutlet NSTextField* trustedTimeConsensusSkewField;
@property (nonatomic, weak) IBOutlet NSTextField* trustedTimeSourceNoticeLabel;
@property (nonatomic, weak) IBOutlet NSTextField* trustedTimeRecommendedRangesLabel;
@property (nonatomic, weak) IBOutlet NSTextField* advancedSettingsLockNoticeLabel;

@end

@implementation PreferencesAdvancedViewController

- (instancetype)init {
    return [super initWithNibName: @"PreferencesAdvancedViewController" bundle: nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults: SCConstants.defaultUserDefaults];
    [self ensureTrustedTimeSourcesTextView];

    if (self.trustedTimeSourceNoticeLabel != nil && self.trustedTimeSourceNoticeLabel.stringValue.length < 1) {
        self.trustedTimeSourceNoticeLabel.stringValue = @"Trusted time source: HTTPS Date consensus (editable list below)";
    }

    if (self.trustedTimeRecommendedRangesLabel != nil && self.trustedTimeRecommendedRangesLabel.stringValue.length < 1) {
        self.trustedTimeRecommendedRangesLabel.stringValue = @"Recommended: servers needed 2-4, max skew 3-30 seconds (default 2 and 10).";
    }
    
    if (self.advancedSettingsLockNoticeLabel != nil) {
        self.advancedSettingsLockNoticeLabel.stringValue = @"";
        self.advancedSettingsLockNoticeLabel.hidden = YES;
    }

    [self normalizeTrustedTimeDefaults];
    [self refreshTrustedTimeSectionValuesFromDefaults];
    [self refreshAdvancedControlLockState];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(onConfigurationChanged:)
                                                 name: @"SCConfigurationChangedNotification"
                                               object: nil];
    [[NSDistributedNotificationCenter defaultCenter] addObserver: self
                                                        selector: @selector(onConfigurationChanged:)
                                                            name: @"SCConfigurationChangedNotification"
                                                          object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];
}

- (void)ensureTrustedTimeSourcesTextView {
    if (self.trustedTimeSourcesTextView != nil) {
        return;
    }
    
    if (self.trustedTimeSourcesScrollView == nil) {
        return;
    }
    
    NSTextView* textView = nil;
    if ([self.trustedTimeSourcesScrollView.documentView isKindOfClass: [NSTextView class]]) {
        textView = (NSTextView*)self.trustedTimeSourcesScrollView.documentView;
    } else {
        NSSize contentSize = self.trustedTimeSourcesScrollView.contentSize;
        textView = [[NSTextView alloc] initWithFrame: NSMakeRect(0.0, 0.0, contentSize.width, contentSize.height)];
        textView.minSize = NSMakeSize(0.0, 0.0);
        textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        textView.verticallyResizable = YES;
        textView.horizontallyResizable = NO;
        textView.richText = NO;
        textView.importsGraphics = NO;
        textView.automaticQuoteSubstitutionEnabled = NO;
        textView.automaticDashSubstitutionEnabled = NO;
        textView.automaticDataDetectionEnabled = NO;
        textView.font = [NSFont userFixedPitchFontOfSize: 11.0] ?: [NSFont systemFontOfSize: 11.0];
        textView.textContainer.widthTracksTextView = YES;
        textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        self.trustedTimeSourcesScrollView.documentView = textView;
    }
    
    textView.delegate = self;
    self.trustedTimeSourcesTextView = textView;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver: self];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshAdvancedControlLockState];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self fitPreferencesWindowToConfiguredViewIfNeeded];
    });
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self fitPreferencesWindowToConfiguredViewIfNeeded];
}

- (NSArray<NSString*>*)normalizedTrustedTimeSourceURLsFromRawValue:(id)rawValue {
    NSArray* candidateValues = nil;
    if ([rawValue isKindOfClass: [NSArray class]]) {
        candidateValues = (NSArray*)rawValue;
    } else if ([rawValue isKindOfClass: [NSString class]]) {
        NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString: @",;\n\r"];
        candidateValues = [(NSString*)rawValue componentsSeparatedByCharactersInSet: separators];
    }

    NSMutableArray<NSString*>* normalizedValues = [NSMutableArray array];
    NSMutableSet<NSString*>* seenValues = [NSMutableSet set];
    for (id value in candidateValues ?: @[]) {
        if (![value isKindOfClass: [NSString class]]) {
            continue;
        }

        NSString* trimmed = [(NSString*)value stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length < 1) {
            continue;
        }

        NSURLComponents* components = [NSURLComponents componentsWithString: trimmed];
        if (components == nil || ![components.scheme.lowercaseString isEqualToString: @"https"] || components.host.length < 1) {
            continue;
        }

        NSString* normalizedURL = components.URL.absoluteString;
        if (normalizedURL.length < 1 || [seenValues containsObject: normalizedURL]) {
            continue;
        }

        [seenValues addObject: normalizedURL];
        [normalizedValues addObject: normalizedURL];
    }

    if (normalizedValues.count < 1) {
        return SCConstants.defaultUserDefaults[kTrustedTimeSourceURLsDefaultsKey];
    }

    return normalizedValues;
}

- (NSInteger)normalizedTrustedTimeConsensusRequiredCountForSourceCount:(NSUInteger)sourceCount {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSInteger requiredCount = [defaults integerForKey: kTrustedTimeConsensusRequiredCountDefaultsKey];
    if (requiredCount < 1) {
        requiredCount = kTrustedTimeDefaultRequiredCount;
    }

    NSInteger maxAllowed = (NSInteger)MAX(sourceCount, 1);
    requiredCount = MIN(MAX(requiredCount, 1), maxAllowed);
    [defaults setInteger: requiredCount forKey: kTrustedTimeConsensusRequiredCountDefaultsKey];
    return requiredCount;
}

- (NSTimeInterval)normalizedTrustedTimeConsensusMaxSkewSeconds {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSTimeInterval maxSkewSeconds = [[defaults objectForKey: kTrustedTimeConsensusMaxSkewSecondsDefaultsKey] doubleValue];
    if (maxSkewSeconds <= 0) {
        maxSkewSeconds = kTrustedTimeDefaultMaxSkewSeconds;
    }

    maxSkewSeconds = MIN(MAX(maxSkewSeconds, kTrustedTimeMinimumMaxSkewSeconds), kTrustedTimeMaximumMaxSkewSeconds);
    [defaults setObject: @(maxSkewSeconds) forKey: kTrustedTimeConsensusMaxSkewSecondsDefaultsKey];
    return maxSkewSeconds;
}

- (void)normalizeTrustedTimeDefaults {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString*>* sourceURLs = [self normalizedTrustedTimeSourceURLsFromRawValue: [defaults objectForKey: kTrustedTimeSourceURLsDefaultsKey]];
    [defaults setObject: sourceURLs forKey: kTrustedTimeSourceURLsDefaultsKey];
    [self normalizedTrustedTimeConsensusRequiredCountForSourceCount: sourceURLs.count];
    [self normalizedTrustedTimeConsensusMaxSkewSeconds];
}

- (void)refreshTrustedTimeSectionValuesFromDefaults {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString*>* sourceURLs = [self normalizedTrustedTimeSourceURLsFromRawValue: [defaults objectForKey: kTrustedTimeSourceURLsDefaultsKey]];

    if (self.trustedTimeSourcesTextView != nil) {
        self.trustedTimeSourcesTextView.string = [sourceURLs componentsJoinedByString: @"\n"];
    }

    NSInteger requiredCount = [self normalizedTrustedTimeConsensusRequiredCountForSourceCount: sourceURLs.count];
    if (self.trustedTimeConsensusCountField != nil) {
        self.trustedTimeConsensusCountField.integerValue = requiredCount;
    }

    NSTimeInterval maxSkewSeconds = [self normalizedTrustedTimeConsensusMaxSkewSeconds];
    if (self.trustedTimeConsensusSkewField != nil) {
        self.trustedTimeConsensusSkewField.stringValue = [NSString stringWithFormat: @"%.0f", maxSkewSeconds];
    }
}

- (void)persistTrustedTimeSourcesFromEditorText {
    if (self.trustedTimeSourcesTextView == nil) {
        return;
    }

    NSArray<NSString*>* sourceURLs = [self normalizedTrustedTimeSourceURLsFromRawValue: self.trustedTimeSourcesTextView.string];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: sourceURLs forKey: kTrustedTimeSourceURLsDefaultsKey];
    [self normalizedTrustedTimeConsensusRequiredCountForSourceCount: sourceURLs.count];
}

- (void)postConfigurationChangedNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
}

- (void)trustedTimeFieldsDidChange {
    [self persistTrustedTimeSourcesFromEditorText];
    [self normalizeTrustedTimeDefaults];
    [self refreshTrustedTimeSectionValuesFromDefaults];
    [self postConfigurationChangedNotification];
}

- (void)fitPreferencesWindowToConfiguredViewIfNeeded {
    if (self.view == nil) {
        return;
    }

    NSWindow* window = self.view.window;
    if (window == nil) {
        return;
    }

    NSSize targetSize = self.view.frame.size;
    if (targetSize.width < 1.0 || targetSize.height < 1.0) {
        return;
    }

    [window setContentMinSize: targetSize];
    [window setContentMaxSize: targetSize];
    [window setShowsResizeIndicator: NO];
    [[window standardWindowButton: NSWindowZoomButton] setEnabled: NO];

    NSRect desiredFrame = [window frameRectForContentRect: NSMakeRect(0.0, 0.0, targetSize.width, targetSize.height)];
    NSRect currentFrame = window.frame;
    desiredFrame.origin.x = currentFrame.origin.x;
    desiredFrame.origin.y = NSMaxY(currentFrame) - NSHeight(desiredFrame);
    [window setFrame: desiredFrame display: YES animate: NO];
}

- (void)setAdvancedControlsEnabled:(BOOL)enabled forView:(NSView*)view {
    if ([view isKindOfClass: [NSButton class]]) {
        ((NSButton*)view).enabled = enabled;
    } else if ([view isKindOfClass: [NSPopUpButton class]]) {
        ((NSPopUpButton*)view).enabled = enabled;
    } else if ([view isKindOfClass: [NSSlider class]]) {
        ((NSSlider*)view).enabled = enabled;
    } else if ([view isKindOfClass: [NSTextField class]]) {
        NSTextField* textField = (NSTextField*)view;
        BOOL isInteractive = textField.editable || textField.action != NULL;
        if (isInteractive) {
            textField.enabled = enabled;
            textField.editable = enabled;
            textField.selectable = enabled;
        }
    }

    for (NSView* subview in view.subviews) {
        [self setAdvancedControlsEnabled: enabled forView: subview];
    }
}

- (void)refreshAdvancedControlLockState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAdvancedControlLockState];
        });
        return;
    }
    if (self.view == nil) {
        return;
    }

    BOOL controlsEnabled = ![SCUIUtilities blockIsRunning];
    [self setAdvancedControlsEnabled: controlsEnabled forView: self.view];

    if (self.trustedTimeSourcesTextView != nil) {
        self.trustedTimeSourcesTextView.editable = controlsEnabled;
        self.trustedTimeSourcesTextView.selectable = controlsEnabled;
        if (self.trustedTimeSourcesTextView.enclosingScrollView != nil) {
            self.trustedTimeSourcesTextView.enclosingScrollView.alphaValue = controlsEnabled ? 1.0 : 0.75;
        }
    }

    if (self.advancedSettingsLockNoticeLabel != nil) {
        self.advancedSettingsLockNoticeLabel.hidden = YES;
    }
}

- (void)onConfigurationChanged:(NSNotification*)notification {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf onConfigurationChanged: notification];
        });
        return;
    }

    (void)notification;
    [self refreshAdvancedControlLockState];
}

- (IBAction)trustedTimeConsensusFieldChanged:(id)sender {
    (void)sender;
    [self trustedTimeFieldsDidChange];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.trustedTimeConsensusCountField || obj.object == self.trustedTimeConsensusSkewField) {
        [self trustedTimeFieldsDidChange];
    }
}

- (void)textDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.trustedTimeSourcesTextView) {
        [self trustedTimeFieldsDidChange];
    }
}

#pragma mark MASPreferencesViewController

- (NSString*)identifier {
    return @"AdvancedPreferences";
}

- (NSImage *)toolbarItemImage {
    return [NSImage imageNamed: NSImageNameAdvanced];
}

- (NSString *)toolbarItemLabel {
    return NSLocalizedString(@"Advanced", @"Toolbar item name for the Advanced preference pane");
}

- (BOOL)hasResizableWidth {
    return NO;
}

- (BOOL)hasResizableHeight {
    return NO;
}

@end
