//
//  AppController.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/29/09.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "AppController.h"
#import "MASPreferencesWindowController.h"
#import "PreferencesGeneralViewController.h"
#import "PreferencesAdvancedViewController.h"
#import "SCTimeIntervalFormatter.h"
#import <LetsMove/PFMoveApplication.h>
#import "SCSettings.h"
#import <ServiceManagement/ServiceManagement.h>
#import "SCXPCClient.h"
#import "SCBlockFileReaderWriter.h"
#import "SCUIUtilities.h"
#import <TransformerKit/NSValueTransformer+TransformerKit.h>

@interface AppController () {}

@property (atomic, strong, readwrite) SCXPCClient* xpc;
@property (nonatomic, strong) NSTextField* mainDurationIntervalLabel;
@property (nonatomic, strong) NSTextField* mainDurationIntervalField;
@property (nonatomic, assign) BOOL mainInternetTimeLayoutConfigured;
@property (nonatomic, strong) NSTimer* internetTimeDisplayTimer;
@property (nonatomic, strong, nullable) NSDate* internetTimeBaseDate;
@property (nonatomic, assign) NSTimeInterval internetTimeBaseUptime;
@property (nonatomic, assign) BOOL internetTimeFetchInProgress;
@property (nonatomic, strong, nullable) NSDate* internetTimeLastFetchAttempt;
@property (nonatomic, strong, nullable) NSDate* internetTimeLastFetchSuccess;
@property (nonatomic, strong) NSView* inlineBlocklistContainer;
@property (nonatomic, strong) NSScrollView* inlineBlocklistScrollView;
@property (nonatomic, strong) NSTextView* inlineBlocklistTextView;
@property (nonatomic, strong) NSButton* inlineBlocklistApplyButton;
@property (nonatomic, strong) NSLayoutConstraint* inlineBlocklistHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint* blocklistButtonsTopConstraint;
@property (nonatomic, assign) BOOL inlineBlocklistExpanded;
@property (nonatomic, assign) NSRect collapsedInitialWindowFrame;
@property (nonatomic, strong) NSStatusItem* menuBarStatusItem;
@property (nonatomic, strong) NSMenu* menuBarMenu;
@property (nonatomic, strong) NSMenuItem* menuBarTimerMenuItem;
@property (nonatomic, strong) NSMenuItem* menuBarShowTimerMenuItem;
@property (nonatomic, strong) NSMenuItem* menuBarQuickBlockMenuItem;
@property (nonatomic, copy) NSArray<NSMenuItem*>* menuBarQuickDurationMenuItems;
@property (nonatomic, strong) NSTimer* menuBarRefreshTimer;
- (NSInteger)normalizedMaxBlockLengthMinutes;
- (NSInteger)normalizedDurationIntervalMinutesForMaxBlockLength:(NSInteger)maxBlockLength;
- (void)applyDurationPreferencesToMainSlider;
- (void)setupMainDurationIntervalControl;
- (IBAction)mainDurationIntervalChanged:(id)sender;
- (void)mainDurationIntervalEditingDidEnd:(NSNotification*)notification;
- (void)setupMainInternetTimeDisplay;
- (void)refreshInternetTimeSampleIfNeeded:(BOOL)force;
- (void)fetchConsensusInternetTimeWithCompletion:(void(^)(NSDate* _Nullable fetchedDate))completion;
- (NSArray<NSString*>*)normalizedTrustedTimeSourceURLs;
- (NSInteger)normalizedTrustedTimeConsensusRequiredCountForSourceCount:(NSUInteger)sourceCount;
- (NSTimeInterval)normalizedTrustedTimeConsensusMaxSkewSeconds;
- (NSDate* _Nullable)consensusTrustedDateFromSamples:(NSArray<NSDate*>*)samples requiredMatches:(NSInteger)requiredMatches maxSkewSeconds:(NSTimeInterval)maxSkewSeconds;
- (NSDate* _Nullable)estimatedDateFromTrustedFetchDate:(NSDate* _Nullable)trustedFetchDate fetchUptime:(NSNumber* _Nullable)fetchUptime;
- (void)updateMainInternetTimeDisplay;
- (NSDate*)estimatedTrustedInternetDate;
- (void)internetTimeDisplayTimerFired:(NSTimer*)timer;
- (void)setupInlineBlocklistEditor;
- (void)syncInlineBlocklistEditorFromCurrentSettings;
- (void)setInlineBlocklistExpanded:(BOOL)expanded animated:(BOOL)animated;
- (NSArray<NSString*>*)inlineBlocklistEntriesFromEditorText;
- (IBAction)applyInlineBlocklistChanges:(id)sender;
- (void)handleUserDefaultsChanged:(NSNotification*)notification;
- (void)configureMenuBarStatusItem;
- (void)tearDownMenuBarStatusItem;
- (void)refreshMenuBarStatusItem;
- (void)rebuildQuickBlockMenu;
- (NSArray<NSNumber*>*)menuBarQuickBlockDurationsMinutes;
- (NSString*)normalizedMenuBarIconText;
- (NSString*)menuBarActiveTimerString;
- (NSString*)menuBarDurationTitleForMinutes:(NSInteger)minutes;
- (void)menuBarRefreshTimerFired:(NSTimer*)timer;
- (void)ensureRegularActivationPolicy;
- (void)refreshActivationPolicyForVisibleWindows;
- (void)handleWindowVisibilityChanged:(NSNotification*)notification;
- (IBAction)openSelfControlX:(id)sender;
- (IBAction)quickBlockMenuSelection:(id)sender;

@end

@implementation AppController {
	NSWindowController* getStartedWindowController;
}

static NSInteger const kMaximumBlockLengthLimitMinutes = 10080; // 7 days
static NSString* const kMenuBarDefaultIconText = @"\u30c4";
static NSString* const kMenuBarIconTextDefaultsKey = @"MenuBarIconText";
static NSString* const kMenuBarEnabledDefaultsKey = @"EnableMenuBarIcon";
static NSString* const kMenuBarQuickDurationsDefaultsKey = @"MenuBarQuickBlockDurationsMinutes";
static NSString* const kTrustedTimeSourceURLsDefaultsKey = @"TrustedTimeSourceURLs";
static NSString* const kTrustedTimeConsensusRequiredCountDefaultsKey = @"TrustedTimeConsensusRequiredCount";
static NSString* const kTrustedTimeConsensusMaxSkewSecondsDefaultsKey = @"TrustedTimeConsensusMaxSkewSeconds";
static NSTimeInterval const kMainTrustedTimeRefreshIntervalSecs = 30.0;
static NSTimeInterval const kMainTrustedTimeRequestTimeoutSecs = 2.5;
static NSInteger const kMainTrustedTimeDefaultRequiredCount = 2;
static NSTimeInterval const kMainTrustedTimeDefaultMaxSkewSeconds = 10.0;
static NSTimeInterval const kMainTrustedTimeMinimumMaxSkewSeconds = 1.0;
static NSTimeInterval const kMainTrustedTimeMaximumMaxSkewSeconds = 300.0;
static CGFloat const kInlineBlocklistExpandedHeight = 240.0;
static CGFloat const kMainWindowFixedWidth = 620.0;
static CGFloat const kMainWindowFixedHeight = 188.0;
static NSString* const kSelfControlXWindowTitle = @"SelfControlX";

static NSOperatingSystemVersion SCOperatingSystemVersionFromString(NSString* versionString, NSOperatingSystemVersion fallbackVersion) {
    if (![versionString isKindOfClass: [NSString class]]) {
        return fallbackVersion;
    }
    
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern: @"^(\\d+)(?:\\.(\\d+))?(?:\\.(\\d+))?$"
                                                                           options: 0
                                                                             error: nil];
    NSTextCheckingResult* match = [regex firstMatchInString: versionString
                                                    options: 0
                                                      range: NSMakeRange(0, versionString.length)];
    if (match == nil || match.numberOfRanges < 2) {
        return fallbackVersion;
    }
    
    NSInteger major = [[versionString substringWithRange: [match rangeAtIndex: 1]] integerValue];
    NSInteger minor = 0;
    NSInteger patch = 0;
    if ([match rangeAtIndex: 2].location != NSNotFound) {
        minor = [[versionString substringWithRange: [match rangeAtIndex: 2]] integerValue];
    }
    if ([match rangeAtIndex: 3].location != NSNotFound) {
        patch = [[versionString substringWithRange: [match rangeAtIndex: 3]] integerValue];
    }
    
    if (major < 1) {
        return fallbackVersion;
    }
    
    return (NSOperatingSystemVersion){major, minor, patch};
}

static NSString* SCVersionStringFromOperatingSystemVersion(NSOperatingSystemVersion version) {
    if (version.patchVersion > 0) {
        return [NSString stringWithFormat: @"%ld.%ld.%ld",
                (long)version.majorVersion,
                (long)version.minorVersion,
                (long)version.patchVersion];
    }
    return [NSString stringWithFormat: @"%ld.%ld",
            (long)version.majorVersion,
            (long)version.minorVersion];
}

static NSDateFormatter* SCMainHTTPDateHeaderFormatter(void) {
    static NSDateFormatter* formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier: @"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation: @"GMT"];
        formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
    });
    return formatter;
}

static NSArray<NSString*>* SCMainDefaultTrustedTimeSourceURLs(void) {
    static NSArray<NSString*>* sourceURLs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sourceURLs = @[
            @"https://www.google.com",
            @"https://www.apple.com",
            @"https://www.microsoft.com",
            @"https://www.cloudflare.com",
            @"https://www.amazon.com",
            @"https://www.fastly.com"
        ];
    });
    return sourceURLs;
}

static NSArray<NSString*>* SCMainNormalizedTrustedTimeSourceURLsFromRawValue(id rawValue) {
    NSArray* candidateValues = nil;
    if ([rawValue isKindOfClass: [NSArray class]]) {
        candidateValues = (NSArray*)rawValue;
    } else if ([rawValue isKindOfClass: [NSString class]]) {
        NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString: @",;\n\r"];
        candidateValues = [(NSString*)rawValue componentsSeparatedByCharactersInSet: separators];
    }
    
    NSMutableArray<NSString*>* normalizedValues = [NSMutableArray array];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
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
        if (normalizedURL.length < 1 || [seen containsObject: normalizedURL]) {
            continue;
        }
        
        [seen addObject: normalizedURL];
        [normalizedValues addObject: normalizedURL];
    }
    
    if (normalizedValues.count < 1) {
        return SCMainDefaultTrustedTimeSourceURLs();
    }
    
    return normalizedValues;
}

@synthesize addingBlock;

- (AppController*) init {
	if(self = [super init]) {

		defaults_ = [NSUserDefaults standardUserDefaults];
		[defaults_ registerDefaults: SCConstants.defaultUserDefaults];

		self.addingBlock = false;

		// refreshUILock_ is a lock that prevents a race condition by making the refreshUserInterface
		// method alter the blockIsOn variable atomically (will no longer be necessary once we can
		// use properties).
		refreshUILock_ = [[NSLock alloc] init];
	}

	return self;
}

- (IBAction)updateTimeSliderDisplay:(id)sender {
    [self applyDurationPreferencesToMainSlider];
    NSInteger numMinutes = blockDurationSlider_.durationValueMinutes;
    [self setDefaultsBlockDurationOnMainThread: @(numMinutes)];

    blockSliderTimeDisplayLabel_.stringValue = blockDurationSlider_.durationDescription;

	[submitButton_ setEnabled: (numMinutes > 0) && ([[defaults_ arrayForKey: @"Blocklist"] count] > 0)];
}

- (IBAction)addBlock:(id)sender {
    if ([SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is on so the Start button should be disabled.
        NSError* err = [SCErr errorWithCode: 104];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
		return;
	}
	if (([[defaults_ arrayForKey: @"Blocklist"] count] == 0) && ![defaults_ boolForKey: @"BlockAsWhitelist"]) {
		// Since the Start button should be disabled when the blocklist has no entries (and it's not an allowlist)
		// this should definitely not be happening.  Exit.

        NSError* err = [SCErr errorWithCode: 100];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
		NSAlert* networkUnavailableAlert = [[NSAlert alloc] init];
		[networkUnavailableAlert setMessageText: NSLocalizedString(@"No network connection detected", "No network connection detected message")];
		[networkUnavailableAlert setInformativeText:NSLocalizedString(@"A block cannot be started without a working network connection.  You can override this setting in Preferences.", @"Message when network connection is unavailable")];
		[networkUnavailableAlert addButtonWithTitle: NSLocalizedString(@"OK", "OK button")];
        [networkUnavailableAlert runModal];
		return;
	}

    // cancel if we pop up a warning about the super long block, and the user decides to cancel
    if (![self showLongBlockWarningsIfNecessary]) {
        return;
    }

	[timerWindowController_ resetStrikes];

	[NSThread detachNewThreadSelector: @selector(installBlock) toTarget: self withObject: nil];
}

// returns YES if we should continue with the block, NO if we should cancel it
- (BOOL)showLongBlockWarningsIfNecessary {
    // all UI stuff MUST be done on the main thread
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [self showLongBlockWarningsIfNecessary];
        });
        return retVal;
    }
    
    NSString* LONG_BLOCK_SUPPRESSION_KEY = @"SuppressLongBlockWarning";
    int LONG_BLOCK_THRESHOLD_MINS = 2880; // 2 days
    int FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS = 480; // 8 hours

    BOOL isFirstBlock = ![defaults_ boolForKey: @"FirstBlockStarted"];
    int blockDuration = [[self->defaults_ valueForKey: @"BlockDuration"] intValue];

    BOOL showLongBlockWarning = blockDuration >= LONG_BLOCK_THRESHOLD_MINS || (isFirstBlock && blockDuration >= FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS);
    if (!showLongBlockWarning) return YES;

    // if they don't want warnings, they don't get warnings. their funeral 💀
    if ([self->defaults_ boolForKey: LONG_BLOCK_SUPPRESSION_KEY]) {
        return YES;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"That's a long block!", "Long block warning title");
    alert.informativeText = [NSString stringWithFormat: NSLocalizedString(@"Remember that once you start the block, you can't turn it back off until the timer expires in %@ - even if you accidentally blocked a site you need. Consider starting a shorter block first, to test your list and make sure everything's working properly.", @"Long block warning message"), [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: blockDuration]];
    [alert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Button to cancel a long block")];
    [alert addButtonWithTitle: NSLocalizedString(@"Start Block Anyway", "Button to start a long block despite warnings")];
    alert.showsSuppressionButton = YES;

    NSModalResponse modalResponse = [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn) {
        // no more warnings, they say
        [self->defaults_ setBool: YES forKey: LONG_BLOCK_SUPPRESSION_KEY];
    }
    if (modalResponse == NSAlertFirstButtonReturn) {
        return NO;
    }
    
    return YES;
}


- (void)refreshUserInterface {
    // UI updates are for the main thread only!
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshUserInterface];
        });
        return;
    }

	if(![refreshUILock_ tryLock]) {
		// already refreshing the UI, no need to wait and do it again
		return;
	}

	BOOL blockWasOn = blockIsOn;
	blockIsOn = [SCUIUtilities blockIsRunning];

	if(blockIsOn) { // block is on
		if(!blockWasOn) { // if we just switched states to on...
			[self closeTimerWindow];
			[self showTimerWindow];
			[initialWindow_ close];
			[self closeDomainList];
            
            // apparently, a block is running, so make sure FirstBlockStarted is true
            [defaults_ setBool: YES forKey: @"FirstBlockStarted"];
		}
	} else { // block is off
		if(blockWasOn) { // if we just switched states to off...
			[timerWindowController_ blockEnded];

			// Makes sure the domain list will refresh when it comes back
			[self closeDomainList];
            
            // make sure the dock badge is cleared
            [[NSApp dockTile] setBadgeLabel: nil];

            // send a notification letting the user know the block ended
            // TODO: make this sent from a background process so it shows if app is closed
            // (but we can't send it from the selfcontrold process, because it's running as root)
            NSUserNotificationCenter* userNoteCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
            NSUserNotification* endedNote = [NSUserNotification new];
            endedNote.title = @"Your SelfControl block has ended!";
            endedNote.informativeText = @"All sites are now accessible.";
            [userNoteCenter deliverNotification: endedNote];

			[self closeTimerWindow];
		}

		[self updateTimeSliderDisplay: blockDurationSlider_];

		if([defaults_ integerForKey: @"BlockDuration"] != 0 &&
           ([[defaults_ arrayForKey: @"Blocklist"] count] != 0 || [defaults_ boolForKey: @"BlockAsWhitelist"]) &&
           !self.addingBlock) {
			[submitButton_ setEnabled: YES];
		} else {
			[submitButton_ setEnabled: NO];
		}

		// If we're adding a block, we want buttons disabled.
        if(!self.addingBlock) {
			[blockDurationSlider_ setEnabled: YES];
			[editBlocklistButton_ setEnabled: YES];
            [self.mainDurationIntervalField setEnabled: YES];
			[submitButton_ setTitle: NSLocalizedString(@"Start Block", @"Start button")];
		} else {
			[blockDurationSlider_ setEnabled: NO];
			// Keep blocklist editing accessible in case start fails and UI is awaiting daemon response.
			[editBlocklistButton_ setEnabled: YES];
            [self.mainDurationIntervalField setEnabled: NO];
			[submitButton_ setTitle: NSLocalizedString(@"Starting Block", @"Starting Block button")];
		}

		// if block's off, and we haven't shown it yet, show the first-time modal
		if (![defaults_ boolForKey: @"GetStartedShown"]) {
			[defaults_ setBool: YES forKey: @"GetStartedShown"];
			[self showGetStartedWindow: self];
		}
	}

    // finally: if the helper tool marked that it detected tampering, make sure
    // we follow through and set the cheater wallpaper (helper tool can't do it itself)
    if ([settings_ boolForKey: @"TamperingDetected"]) {
        NSURL* cheaterBackgroundURL = [[NSBundle mainBundle] URLForResource: @"cheater-background" withExtension: @"png"];
            NSArray<NSScreen *>* screens = [NSScreen screens];
        for (NSScreen* screen in screens) {
            NSError* err;
            [[NSWorkspace sharedWorkspace] setDesktopImageURL: cheaterBackgroundURL
                                                    forScreen: screen
                                                      options: @{}
                                                        error: &err];
        }
        [settings_ setValue: @NO forKey: @"TamperingDetected"];
    }
    
    // Display "blocklist" or "allowlist" as appropriate
    NSString* listType = [defaults_ boolForKey: @"BlockAsWhitelist"] ? @"Allowlist" : @"Blocklist";
    NSString* editListString = NSLocalizedString(([NSString stringWithFormat: @"Edit %@", listType]), @"Edit list button / menu item");
    NSString* hideListString = NSLocalizedString(@"Hide Blocklist", @"Hide inline blocklist editor button / menu item");
    if (self.inlineBlocklistExpanded) {
        editBlocklistButton_.title = hideListString;
        editBlocklistMenuItem_.title = hideListString;
    } else {
        editBlocklistButton_.title = editListString;
        editBlocklistMenuItem_.title = editListString;
    }
    [self syncInlineBlocklistEditorFromCurrentSettings];
    [self updateMainInternetTimeDisplay];
    [self refreshMenuBarStatusItem];

	[refreshUILock_ unlock];
}

- (void)handleConfigurationChangedNotification {
    [SCSentry addBreadcrumb: @"Received configuration changed notification" category: @"app"];
    // if our configuration changed, we should assume the settings may have changed
    [[SCSettings sharedSettings] reloadSettings];
    
    // clean out empty strings from the defaults blocklist (they can end up there occasionally due to UI glitches etc)
    // note we don't screw with the actively running blocklist - that should've been cleaned before it started anyway
    NSArray<NSString*>* cleanedBlocklist = [SCMiscUtilities cleanBlocklist: [defaults_ arrayForKey: @"Blocklist"]];
    [defaults_ setObject: cleanedBlocklist forKey: @"Blocklist"];

    // update our blocklist teaser string
    [self updateMainInternetTimeDisplay];
    
    // let the domain list know!
    if (domainListWindowController_ != nil) {
        domainListWindowController_.readOnly = [SCUIUtilities blockIsRunning];
        [domainListWindowController_ refreshDomainList];
    }
    [self syncInlineBlocklistEditorFromCurrentSettings];
    
    // let the timer window know!
    if (timerWindowController_ != nil) {
        [timerWindowController_ performSelectorOnMainThread: @selector(configurationChanged)
                                                 withObject: nil
                                              waitUntilDone: NO];
    }
    
    // and our interface may need to change to match!
    [self refreshUserInterface];
    [self refreshMenuBarStatusItem];
}

- (void)handleUserDefaultsChanged:(NSNotification*)notification {
    (void)notification;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleUserDefaultsChanged: nil];
        });
        return;
    }
    
    [self configureMenuBarStatusItem];
    [self refreshMenuBarStatusItem];
    [self updateMainInternetTimeDisplay];
    [self syncInlineBlocklistEditorFromCurrentSettings];
}

- (void)showTimerWindow {
    [self ensureRegularActivationPolicy];
	if(timerWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"TimerWindow" owner: self topLevelObjects: nil];
	} else {
		[[timerWindowController_ window] makeKeyAndOrderFront: self];
		[[timerWindowController_ window] center];
	}
    [[timerWindowController_ window] setTitle: kSelfControlXWindowTitle];
}

- (void)closeTimerWindow {
    // Use teardown only when a block ends or the app is terminating.
	[timerWindowController_ close];
	timerWindowController_ = nil;
}

- (IBAction)openPreferences:(id)sender {
    [SCSentry addBreadcrumb: @"Opening preferences window" category: @"app"];
    [self ensureRegularActivationPolicy];
	if (preferencesWindowController_ == nil) {
		NSViewController* generalViewController = [[PreferencesGeneralViewController alloc] init];
		NSViewController* advancedViewController = [[PreferencesAdvancedViewController alloc] init];
		NSString* title = NSLocalizedString(@"Preferences", @"Common title for Preferences window");

		preferencesWindowController_ = [[MASPreferencesWindowController alloc] initWithViewControllers: @[generalViewController, advancedViewController] title: title];
	}
	[preferencesWindowController_ showWindow: nil];
    NSWindow* preferencesWindow = preferencesWindowController_.window;
    [preferencesWindow setStyleMask: (preferencesWindow.styleMask & ~NSWindowStyleMaskResizable)];
    [preferencesWindow setShowsResizeIndicator: NO];
    [[preferencesWindow standardWindowButton: NSWindowZoomButton] setEnabled: NO];
}

- (IBAction)showGetStartedWindow:(id)sender {
    [SCSentry addBreadcrumb: @"Showing \"Get Started\" window" category: @"app"];
    [self ensureRegularActivationPolicy];
	if (!getStartedWindowController) {
		getStartedWindowController = [[NSWindowController alloc] initWithWindowNibName: @"FirstTime"];
	}
    getStartedWindowController.window.title = @"Welcome to SelfControlX";
	[getStartedWindowController.window center];
	[getStartedWindowController.window makeKeyAndOrderFront: nil];
	[getStartedWindowController showWindow: nil];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // For test runs, we don't want to pop up the dialog to move to the Applications folder, as it breaks the tests
    if (NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] == nil) {
        PFMoveToApplicationsFolderIfNecessary();
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[NSApplication sharedApplication].delegate = self;
    
    [SCSentry startSentry: @"org.eyebeam.SelfControlX"];

    settings_ = [SCSettings sharedSettings];
    // go copy over any preferences from legacy setting locations
    // (we won't clear any old data yet - we leave that to the daemon)
    if ([SCMigrationUtilities legacySettingsFoundForCurrentUser]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults];
    }

    // start up our daemon XPC
    self.xpc = [SCXPCClient new];
    [self.xpc connectToHelperTool];
    
    // if we don't have a connection within 0.5 seconds,
    // OR we get back a connection with an old daemon version
    // AND we're running a modern block (which should have a daemon running it)
    // something's wrong with our app-daemon connection. This probably means one of two things:
    //   1. The daemon got unloaded somehow and failed to restart. This is a big problem because the block won't come off.
    //   2. The daemon doesn't want to talk to us anymore, potentially because we've changed our signing certificate. This is a
    //      smaller problem, but still not great because the app can't communicate anything to the daemon.
    //   3. There's a daemon but it's an old version, and should be replaced.
    // in any case, let's go try to reinstall the daemon
    // (we debounce this call so it happens only once, after the connection has been invalidated for an extended period)
    if ([SCBlockUtilities modernBlockIsRunning]) {
        [NSTimer scheduledTimerWithTimeInterval: 0.5 repeats: NO block:^(NSTimer * _Nonnull timer) {
            [self.xpc getVersion:^(NSString * _Nonnull daemonVersion, NSError * _Nonnull error) {
                if (error == nil) {
                    if ([SELFCONTROL_VERSION_STRING compare: daemonVersion options: NSNumericSearch] == NSOrderedDescending) {
                        NSLog(@"Daemon version of %@ is out of date (current version is %@).", daemonVersion, SELFCONTROL_VERSION_STRING);
                        [SCSentry addBreadcrumb: @"Detected out-of-date daemon" category: @"app"];
                        [self reinstallDaemon];
                    } else {
                        [SCSentry addBreadcrumb: @"Detected up-to-date daemon" category:@"app"];
                        NSLog(@"Daemon version of %@ is up-to-date!", daemonVersion);
                    }
                } else {
                    NSLog(@"ERROR: Fetching daemon version failed with error %@", error);
                    [self reinstallDaemon];
                }
            }];
        }];
    }

    // Register observers on both distributed and normal notification centers
	// to receive notifications from the helper tool and the other parts of the
	// main SelfControl app.  Note that they are divided thusly because distributed
	// notifications are very expensive and should be minimized.
	[[NSDistributedNotificationCenter defaultCenter] addObserver: self
														selector: @selector(handleConfigurationChangedNotification)
															name: @"SCConfigurationChangedNotification"
														  object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];
	[[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(handleConfigurationChangedNotification)
												 name: @"SCConfigurationChangedNotification"
											   object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleUserDefaultsChanged:)
                                                 name: NSUserDefaultsDidChangeNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleWindowVisibilityChanged:)
                                                 name: NSWindowDidBecomeMainNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleWindowVisibilityChanged:)
                                                 name: NSWindowDidResignMainNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleWindowVisibilityChanged:)
                                                 name: NSWindowWillCloseNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleWindowVisibilityChanged:)
                                                 name: NSWindowDidMiniaturizeNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleWindowVisibilityChanged:)
                                                 name: NSWindowDidDeminiaturizeNotification
                                               object: nil];

	[initialWindow_ center];
    [initialWindow_ setTitle: kSelfControlXWindowTitle];
    [initialWindow_ setStyleMask: (initialWindow_.styleMask & ~NSWindowStyleMaskResizable)];
    NSSize fixedContentSize = NSMakeSize(kMainWindowFixedWidth, kMainWindowFixedHeight);
    [initialWindow_ setContentSize: fixedContentSize];
    [initialWindow_ setContentMinSize: fixedContentSize];
    [initialWindow_ setContentMaxSize: fixedContentSize];
    self.collapsedInitialWindowFrame = [initialWindow_ frame];

	// We'll set blockIsOn to whatever is NOT right, so that in refreshUserInterface
	// it'll fix it and properly refresh the user interface.
	blockIsOn = ![SCUIUtilities blockIsRunning];

	// Change block duration slider for hidden user defaults settings
    [blockDurationSlider_ bindDurationToObject: [NSUserDefaultsController sharedUserDefaultsController]
                                       keyPath: @"values.BlockDuration"];
    [self setupMainDurationIntervalControl];
    [self setupMainInternetTimeDisplay];
    [self setupInlineBlocklistEditor];
    if (editBlocklistButton_ != nil) {
        editBlocklistButton_.target = self;
        editBlocklistButton_.action = @selector(showDomainList:);
    }
    [self applyDurationPreferencesToMainSlider];
    [self updateMainInternetTimeDisplay];
    [self refreshInternetTimeSampleIfNeeded: YES];

    if (self.internetTimeDisplayTimer == nil) {
        self.internetTimeDisplayTimer = [NSTimer scheduledTimerWithTimeInterval: 1.0
                                                                          target: self
                                                                        selector: @selector(internetTimeDisplayTimerFired:)
                                                                        userInfo: nil
                                                                         repeats: YES];
    }

	[self refreshUserInterface];
    [self configureMenuBarStatusItem];
    [self refreshMenuBarStatusItem];
    [self refreshActivationPolicyForVisibleWindows];
    
    NSOperatingSystemVersion fallbackMinVersion = (NSOperatingSystemVersion){10,13,0};
    NSString* minRequiredVersionRaw = [NSBundle.mainBundle objectForInfoDictionaryKey: @"LSMinimumSystemVersion"];
    NSOperatingSystemVersion minRequiredVersion = SCOperatingSystemVersionFromString(minRequiredVersionRaw, fallbackMinVersion);
    NSString* minRequiredVersionString = SCVersionStringFromOperatingSystemVersion(minRequiredVersion);
	if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: minRequiredVersion]) {
		NSLog(@"ERROR: Unsupported version for SelfControl");
        [SCSentry captureMessage: @"Unsupported operating system version"];
		NSAlert* unsupportedVersionAlert = [[NSAlert alloc] init];
		[unsupportedVersionAlert setMessageText: NSLocalizedString(@"Unsupported version", nil)];
        [unsupportedVersionAlert setInformativeText: [NSString stringWithFormat: NSLocalizedString(@"This version of SelfControl only supports macOS version %@ or higher. To download a version for older operating systems, please go to www.selfcontrolapp.com", nil), minRequiredVersionString]];
		[unsupportedVersionAlert addButtonWithTitle: NSLocalizedString(@"OK", nil)];
		[unsupportedVersionAlert runModal];
	}
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [settings_ synchronizeSettings];
}

- (void)reinstallDaemon {
    NSLog(@"Attempting to reinstall daemon...");
    [SCSentry addBreadcrumb: @"Reinstalling daemon" category:@"app"];
    [self.xpc installDaemon:^(NSError * _Nonnull error) {
        if (error == nil) {
            NSLog(@"Reinstalled daemon successfully!");
            [SCSentry addBreadcrumb: @"Daemon reinstalled successfully" category:@"app"];
            
            NSLog(@"Retrying helper tool connection...");
            [self.xpc performSelectorOnMainThread: @selector(connectToHelperTool) withObject: nil waitUntilDone: YES];
        } else {
            if (![SCMiscUtilities errorIsAuthCanceled: error]) {
                NSLog(@"ERROR: Reinstalling daemon failed with error %@", error);
                [SCUIUtilities presentError: error];
            }
        }
    }];
}

- (IBAction)showDomainList:(id)sender {
    [SCSentry addBreadcrumb: @"Showing domain list" category:@"app"];
    [self ensureRegularActivationPolicy];
    (void)sender;
    if (self.inlineBlocklistExpanded) {
        [self setInlineBlocklistExpanded: NO animated: NO];
    }
    if(domainListWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"DomainList" owner: self topLevelObjects: nil];
    }
    domainListWindowController_.readOnly = [SCUIUtilities blockIsRunning];
    [domainListWindowController_ showWindow: self];
}

- (void)closeDomainList {
    if (self.inlineBlocklistExpanded) {
        [self setInlineBlocklistExpanded: NO animated: NO];
    }
    if (domainListWindowController_ != nil) {
        [domainListWindowController_ close];
        domainListWindowController_ = nil;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed: (NSApplication*) theApplication {
    (void)theApplication;
    // Keep the app alive so menu bar controls remain available until an explicit quit.
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)sender;
    if (hasVisibleWindows) {
        return NO;
    }

    [self ensureRegularActivationPolicy];
    [NSApp activateIgnoringOtherApps: YES];
    if ([SCUIUtilities blockIsRunning]) {
        [self showTimerWindow];
    } else {
        [initialWindow_ makeKeyAndOrderFront: self];
    }

    return YES;
}

- (void)ensureRegularActivationPolicy {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureRegularActivationPolicy];
        });
        return;
    }
    if ([NSApp activationPolicy] != NSApplicationActivationPolicyRegular) {
        [NSApp setActivationPolicy: NSApplicationActivationPolicyRegular];
    }
}

- (void)refreshActivationPolicyForVisibleWindows {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshActivationPolicyForVisibleWindows];
        });
        return;
    }

    BOOL hasVisibleWindow = NO;
    for (NSWindow* window in NSApp.windows) {
        if (window.isVisible) {
            hasVisibleWindow = YES;
            break;
        }
    }

    NSApplicationActivationPolicy desiredPolicy = hasVisibleWindow
        ? NSApplicationActivationPolicyRegular
        : NSApplicationActivationPolicyAccessory;
    if ([NSApp activationPolicy] != desiredPolicy) {
        [NSApp setActivationPolicy: desiredPolicy];
    }
}

- (void)handleWindowVisibilityChanged:(NSNotification*)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshActivationPolicyForVisibleWindows];
    });
}

- (void)addToBlockList:(NSString*)host lock:(NSLock*)lock {
    NSLog(@"addToBlocklist: %@", host);
    // Note we RETRIEVE the latest list from settings (ActiveBlocklist), but we SET the new list in defaults
    // since the helper daemon should be the only one changing ActiveBlocklist
    NSMutableArray* list = [[settings_ valueForKey: @"ActiveBlocklist"] mutableCopy];
    NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: host];
    
    if (cleanedEntries.count == 0) return;
    
    for (NSUInteger i = 0; i < cleanedEntries.count; i++) {
        NSString* entry = cleanedEntries[i];
        // don't add duplicate entries
        if (![list containsObject: entry]) {
            [list addObject: entry];
        }
    }
       
	[defaults_ setValue: list forKey: @"Blocklist"];

	if(![SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is not on.
		// so the Start button should be disabled.
		// Maybe the UI didn't get properly refreshed, so try refreshing it again
		// before we return.
		[self refreshUserInterface];

        NSError* err = [SCErr errorWithCode: 102];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
		NSAlert* networkUnavailableAlert = [[NSAlert alloc] init];
		[networkUnavailableAlert setMessageText: NSLocalizedString(@"No network connection detected", "No network connection detected message")];
		[networkUnavailableAlert setInformativeText:NSLocalizedString(@"A block cannot be started without a working network connection.  You can override this setting in Preferences.", @"Message when network connection is unavailable")];
		[networkUnavailableAlert addButtonWithTitle: NSLocalizedString(@"OK", "OK button")];
        [networkUnavailableAlert runModal];
		return;
	}

    [NSThread detachNewThreadSelector: @selector(updateActiveBlocklist:) toTarget: self withObject: lock];
}

- (void)extendBlockTime:(NSInteger)minutesToAdd lock:(NSLock*)lock {
    // sanity check: extending a block for 0 minutes is useless; 24 hour should be impossible
    NSInteger maxBlockLength = [self normalizedMaxBlockLengthMinutes];
    if(minutesToAdd < 1) return;
    if (minutesToAdd > maxBlockLength) {
        minutesToAdd = maxBlockLength;
    }
    
    // ensure block health before we try to change it
    if(![SCUIUtilities blockIsRunning]) {
        // This method shouldn't be getting called, a block is not on.
        // so the Start button should be disabled.
        // Maybe the UI didn't get properly refreshed, so try refreshing it again
        // before we return.
        [self refreshUserInterface];
        
        NSError* err = [SCErr errorWithCode: 103];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
        
        return;
    }
  
    [self updateBlockEndDate: lock minutesToAdd: minutesToAdd];
//    [NSThread detachNewThreadSelector: @selector(extendBlockDuration:)
//                             toTarget: self
//                           withObject: @{
//                                         @"lock": lock,
//                                         @"minutesToAdd": @(minutesToAdd)
//                                                                                                    }];
}

- (void)manuallyClearBlockWithCompletion:(void(^)(NSError* error))completion {
    [SCSentry addBreadcrumb: @"App requested manual block clear" category:@"app"];
    
    // ensure settings are flushed before requesting daemon-side clear
    [settings_ synchronizeSettings];
    [defaults_ synchronize];
    
    [self.xpc refreshConnectionAndRun:^{
        NSLog(@"Refreshed connection for manual block clear");
        [self.xpc forceClearBlock:^(NSError * _Nonnull error) {
            // reload settings state after daemon-side block removal attempt
            [self->settings_ synchronizeSettingsWithCompletion:^(NSError * _Nullable syncError) {
                NSError* completionError = (error != nil) ? error : syncError;
                if (completion != nil) {
                    completion(completionError);
                }
            }];
        }];
    }];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self
													name: @"SCConfigurationChangedNotification"
												  object: nil];
    [[NSNotificationCenter defaultCenter] removeObserver: self
                                                    name: NSControlTextDidEndEditingNotification
                                                  object: self.mainDurationIntervalField];
    [[NSNotificationCenter defaultCenter] removeObserver: self
                                                    name: NSUserDefaultsDidChangeNotification
                                                  object: nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver: self
															   name: @"SCConfigurationChangedNotification"
															 object: nil];
    if (self.internetTimeDisplayTimer != nil) {
        [self.internetTimeDisplayTimer invalidate];
        self.internetTimeDisplayTimer = nil;
    }
    [self tearDownMenuBarStatusItem];
}

- (id)initialWindow {
	return initialWindow_;
}

- (id)domainListWindowController {
	return domainListWindowController_;
}

- (void)setDomainListWindowController:(id)newController {
	domainListWindowController_ = newController;
}

- (void)installBlock {
    [SCSentry addBreadcrumb: @"App running installBlock method" category:@"app"];
	@autoreleasepool {
        // Ensure blocklist UI state is finalized on the main thread before we start the block.
        void (^prepareBlocklistState)(void) = ^{
            if (self->domainListWindowController_ != nil) {
                [self->domainListWindowController_ refreshDomainList];
            }
            if (self.inlineBlocklistExpanded) {
                [self applyInlineBlocklistChanges: nil];
            }
        };
        if ([NSThread isMainThread]) {
            prepareBlocklistState();
        } else {
            dispatch_sync(dispatch_get_main_queue(), prepareBlocklistState);
        }
		self.addingBlock = true;
		[self refreshUserInterface];

        [self.xpc installDaemon:^(NSError * _Nonnull error) {
            if (error != nil) {
                [SCUIUtilities presentError: error];
                self.addingBlock = false;
                [self refreshUserInterface];
                return;
            } else {
                [SCSentry addBreadcrumb: @"Daemon installed successfully (en route to installing block)" category:@"app"];
                // helper tool installed successfully, let's prepare to start the block!
                // for legacy reasons, BlockDuration is in minutes, so convert it to seconds before passing it through]
                // sanity check duration (must be above zero)
                NSTimeInterval blockDurationSecs = MAX([[self->defaults_ valueForKey: @"BlockDuration"] intValue] * 60, 0);
                NSDate* newBlockEndDate = [NSDate dateWithTimeIntervalSinceNow: blockDurationSecs];
                NSArray<NSString*>* trustedTimeSourceURLs = [self normalizedTrustedTimeSourceURLs];
                NSInteger trustedTimeConsensusRequiredCount = [self normalizedTrustedTimeConsensusRequiredCountForSourceCount: trustedTimeSourceURLs.count];
                NSTimeInterval trustedTimeConsensusMaxSkewSeconds = [self normalizedTrustedTimeConsensusMaxSkewSeconds];
                
                // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
                [self->settings_ synchronizeSettings];
                [self->defaults_ synchronize];

                // ok, the new helper tool is installed! refresh the connection, then it's time to start the block
                [self.xpc refreshConnectionAndRun:^{
                    NSLog(@"Refreshed connection and ready to start block!");
                [self.xpc startBlockWithControllingUID: getuid()
                                                 blocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                                               isAllowlist: [self->defaults_ boolForKey: @"BlockAsWhitelist"]
                                                   endDate: newBlockEndDate
                                             blockSettings: @{
                                                                @"ClearCaches": [self->defaults_ valueForKey: @"ClearCaches"],
                                                                @"AllowLocalNetworks": [self->defaults_ valueForKey: @"AllowLocalNetworks"],
                                                                @"EvaluateCommonSubdomains": [self->defaults_ valueForKey: @"EvaluateCommonSubdomains"],
                                                                @"IncludeLinkedDomains": [self->defaults_ valueForKey: @"IncludeLinkedDomains"],
                                                                @"BlockSoundShouldPlay": [self->defaults_ valueForKey: @"BlockSoundShouldPlay"],
                                                                @"BlockSound": [self->defaults_ valueForKey: @"BlockSound"],
                                                                @"BlockBypassesEnabled": @([self->defaults_ boolForKey: @"BlockBypassesEnabled"]),
                                                                @"TrustedTimeSourceURLs": trustedTimeSourceURLs,
                                                                @"TrustedTimeConsensusRequiredCount": @(trustedTimeConsensusRequiredCount),
                                                                @"TrustedTimeConsensusMaxSkewSeconds": @(trustedTimeConsensusMaxSkewSeconds),
                                                                @"MaxBlockLengthMinutes": @([self normalizedMaxBlockLengthMinutes]),
                                                                @"RequestedDurationSeconds": @(blockDurationSecs)
                                                            }
                                                     reply:^(NSError * _Nonnull error) {
                        if (error != nil) {
                            [SCUIUtilities presentError: error];
                        } else {
                            [SCSentry addBreadcrumb: @"Block started successfully" category:@"app"];
                        }
                        
                        // get the new settings
                        [self->settings_ synchronizeSettingsWithCompletion:^(NSError * _Nullable error) {
                            self.addingBlock = false;
                            [self refreshUserInterface];
                        }];
                    }];
                }];
            }
        }];
	}
}

- (void)updateActiveBlocklist:(NSLock*)lockToUse {
	if(![lockToUse tryLock]) {
		return;
	}
    
    [SCSentry addBreadcrumb: @"App running updateActiveBlocklist method" category:@"app"];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        NSLog(@"Refreshed connection updating active blocklist!");
        [self.xpc updateBlocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                            reply:^(NSError * _Nonnull error) {
            [self->timerWindowController_ performSelectorOnMainThread:@selector(closeAddSheet:) withObject: self waitUntilDone: YES];
            
            if (error != nil) {
                [SCUIUtilities presentError: error];
            } else {
                [SCSentry addBreadcrumb: @"Blocklist updated successfully" category:@"app"];
            }
            
            [lockToUse unlock];
        }];
    }];
}

// it really sucks, but we can't change any values that are KVO-bound to the UI unless they're on the main thread
// to make that easier, here is a helper that always does it on the main thread
- (void)setDefaultsBlockDurationOnMainThread:(NSNumber*)newBlockDuration {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread: @selector(setDefaultsBlockDurationOnMainThread:) withObject:newBlockDuration waitUntilDone: YES];
    }

    [defaults_ setInteger: [newBlockDuration intValue] forKey: @"BlockDuration"];
}

- (NSInteger)normalizedMaxBlockLengthMinutes {
    NSInteger maxBlockLength = [defaults_ integerForKey: @"MaxBlockLength"];
    maxBlockLength = MIN(MAX(maxBlockLength, 1), kMaximumBlockLengthLimitMinutes);
    [defaults_ setInteger: maxBlockLength forKey: @"MaxBlockLength"];
    return maxBlockLength;
}

- (NSInteger)normalizedDurationIntervalMinutesForMaxBlockLength:(NSInteger)maxBlockLength {
    NSInteger durationInterval = [defaults_ integerForKey: @"BlockDurationSliderIntervalMinutes"];
    durationInterval = MIN(MAX(durationInterval, 1), maxBlockLength);
    [defaults_ setInteger: durationInterval forKey: @"BlockDurationSliderIntervalMinutes"];
    return durationInterval;
}

- (void)applyDurationPreferencesToMainSlider {
    NSInteger maxBlockLength = [self normalizedMaxBlockLengthMinutes];
    NSInteger durationInterval = [self normalizedDurationIntervalMinutesForMaxBlockLength: maxBlockLength];
    
    blockDurationSlider_.maxDuration = maxBlockLength;
    blockDurationSlider_.durationIntervalMinutes = durationInterval;

    NSInteger currentBlockDuration = [defaults_ integerForKey: @"BlockDuration"];
    NSInteger normalizedBlockDuration = [blockDurationSlider_ sanitizedDurationMinutesForValue: currentBlockDuration];
    if (self.mainDurationIntervalField != nil && self.mainDurationIntervalField.integerValue != durationInterval) {
        [self.mainDurationIntervalField setIntegerValue: durationInterval];
    }
    if (normalizedBlockDuration != currentBlockDuration) {
        [self setDefaultsBlockDurationOnMainThread: @(normalizedBlockDuration)];
    } else if (normalizedBlockDuration != blockDurationSlider_.durationValueMinutes) {
        blockDurationSlider_.integerValue = normalizedBlockDuration;
    }
}

- (void)setupMainDurationIntervalControl {
    if (self.mainDurationIntervalField != nil || initialWindow_ == nil || blockSliderTimeDisplayLabel_ == nil) {
        return;
    }
    
    NSView* contentView = [initialWindow_ contentView];
    if (contentView == nil) {
        return;
    }
    
    NSTextField* intervalLabel = [[NSTextField alloc] initWithFrame: NSZeroRect];
    intervalLabel.translatesAutoresizingMaskIntoConstraints = NO;
    intervalLabel.editable = NO;
    intervalLabel.selectable = NO;
    intervalLabel.bezeled = NO;
    intervalLabel.bordered = NO;
    intervalLabel.drawsBackground = NO;
    intervalLabel.alignment = NSTextAlignmentRight;
    intervalLabel.font = [NSFont systemFontOfSize: [NSFont systemFontSize]];
    intervalLabel.stringValue = NSLocalizedString(@"Step (min):", @"Label for slider interval control on main window");
    
    NSTextField* intervalField = [[NSTextField alloc] initWithFrame: NSZeroRect];
    intervalField.translatesAutoresizingMaskIntoConstraints = NO;
    intervalField.editable = YES;
    intervalField.selectable = YES;
    intervalField.bezeled = YES;
    intervalField.bordered = YES;
    intervalField.drawsBackground = YES;
    intervalField.alignment = NSTextAlignmentRight;
    intervalField.target = self;
    intervalField.action = @selector(mainDurationIntervalChanged:);
    if ([intervalField.cell isKindOfClass: [NSTextFieldCell class]]) {
        [(NSTextFieldCell*)intervalField.cell setSendsActionOnEndEditing: YES];
    }
    
    [contentView addSubview: intervalLabel];
    [contentView addSubview: intervalField];
    
    [NSLayoutConstraint activateConstraints: @[
        [intervalField.widthAnchor constraintEqualToConstant: 56.0],
        [intervalField.heightAnchor constraintEqualToConstant: 22.0],
        [intervalField.trailingAnchor constraintEqualToAnchor: contentView.trailingAnchor constant: -20.0],
        [intervalField.centerYAnchor constraintEqualToAnchor: blockSliderTimeDisplayLabel_.centerYAnchor],
        [intervalLabel.trailingAnchor constraintEqualToAnchor: intervalField.leadingAnchor constant: -6.0],
        [intervalLabel.centerYAnchor constraintEqualToAnchor: intervalField.centerYAnchor]
    ]];
    
    self.mainDurationIntervalLabel = intervalLabel;
    self.mainDurationIntervalField = intervalField;
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(mainDurationIntervalEditingDidEnd:)
                                                 name: NSControlTextDidEndEditingNotification
                                               object: intervalField];
}

- (IBAction)mainDurationIntervalChanged:(id)sender {
    NSInteger maxBlockLength = [self normalizedMaxBlockLengthMinutes];
    NSInteger durationInterval = [self.mainDurationIntervalField integerValue];
    durationInterval = MIN(MAX(durationInterval, 1), maxBlockLength);
    [defaults_ setInteger: durationInterval forKey: @"BlockDurationSliderIntervalMinutes"];
    
    [self applyDurationPreferencesToMainSlider];
    [self updateTimeSliderDisplay: blockDurationSlider_];
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
}

- (void)mainDurationIntervalEditingDidEnd:(NSNotification*)notification {
    [self mainDurationIntervalChanged: notification.object];
}

- (void)setupMainInternetTimeDisplay {
    if (self.mainInternetTimeLayoutConfigured || initialWindow_ == nil || blocklistTeaserLabel_ == nil || editBlocklistButton_ == nil) {
        return;
    }
    
    NSView* contentView = [initialWindow_ contentView];
    if (contentView == nil) {
        return;
    }
    
    NSColor* primaryColor = [NSColor respondsToSelector: @selector(labelColor)] ? [NSColor labelColor] : [NSColor controlTextColor];
    
    blocklistTeaserLabel_.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
    blocklistTeaserLabel_.textColor = primaryColor;
    blocklistTeaserLabel_.lineBreakMode = NSLineBreakByTruncatingTail;
    
    NSButton* settingsButton = nil;
    for (NSView* subview in contentView.subviews) {
        if ([subview isKindOfClass: [NSButton class]]) {
            NSButton* button = (NSButton*)subview;
            if (button.action == @selector(openPreferences:)) {
                settingsButton = button;
                break;
            }
        }
    }
    if (settingsButton != nil) {
        [NSLayoutConstraint activateConstraints: @[
            [settingsButton.centerYAnchor constraintEqualToAnchor: editBlocklistButton_.centerYAnchor]
        ]];
    }

    // Replace main-window bottom-row constraints so the internet time label sits at the midline
    // and the blocklist button stays at the bottom-left without being overlapped.
    NSMutableArray<NSLayoutConstraint*>* replacedConstraints = [NSMutableArray array];
    for (NSLayoutConstraint* constraint in contentView.constraints) {
        id firstItem = constraint.firstItem;
        id secondItem = constraint.secondItem;
        BOOL touchesEditButton = (firstItem == editBlocklistButton_ || secondItem == editBlocklistButton_);
        BOOL touchesTimeLabel = (firstItem == blocklistTeaserLabel_ || secondItem == blocklistTeaserLabel_);
        BOOL touchesSettingsButton = (settingsButton != nil && (firstItem == settingsButton || secondItem == settingsButton));
        if (touchesEditButton || touchesTimeLabel) {
            [replacedConstraints addObject: constraint];
            continue;
        }
        if (touchesSettingsButton) {
            BOOL verticalConstraint =
                (constraint.firstAttribute == NSLayoutAttributeBottom
                 || constraint.firstAttribute == NSLayoutAttributeTop
                 || constraint.firstAttribute == NSLayoutAttributeCenterY
                 || constraint.secondAttribute == NSLayoutAttributeBottom
                 || constraint.secondAttribute == NSLayoutAttributeTop
                 || constraint.secondAttribute == NSLayoutAttributeCenterY);
            if (verticalConstraint) {
                [replacedConstraints addObject: constraint];
            }
        }
    }
    [NSLayoutConstraint deactivateConstraints: replacedConstraints];

    [blocklistTeaserLabel_ setContentCompressionResistancePriority: NSLayoutPriorityDefaultLow
                                                     forOrientation: NSLayoutConstraintOrientationHorizontal];
    NSMutableArray<NSLayoutConstraint*>* replacementConstraints = [NSMutableArray arrayWithArray: @[
        [editBlocklistButton_.leadingAnchor constraintEqualToAnchor: contentView.leadingAnchor constant: 19.0],
        [editBlocklistButton_.topAnchor constraintEqualToAnchor: blockDurationSlider_.bottomAnchor constant: 10.0],
        [editBlocklistButton_.bottomAnchor constraintEqualToAnchor: contentView.bottomAnchor constant: -12.0],
        [blocklistTeaserLabel_.centerXAnchor constraintEqualToAnchor: contentView.centerXAnchor],
        [blocklistTeaserLabel_.centerYAnchor constraintEqualToAnchor: editBlocklistButton_.centerYAnchor],
        [blocklistTeaserLabel_.leadingAnchor constraintGreaterThanOrEqualToAnchor: editBlocklistButton_.trailingAnchor constant: 10.0]
    ]];
    if (settingsButton != nil) {
        [replacementConstraints addObjectsFromArray: @[
            [settingsButton.trailingAnchor constraintEqualToAnchor: contentView.trailingAnchor constant: -20.0],
            [settingsButton.centerYAnchor constraintEqualToAnchor: editBlocklistButton_.centerYAnchor],
            [blocklistTeaserLabel_.trailingAnchor constraintLessThanOrEqualToAnchor: settingsButton.leadingAnchor constant: -10.0]
        ]];
    } else {
        [replacementConstraints addObject: [blocklistTeaserLabel_.trailingAnchor constraintLessThanOrEqualToAnchor: contentView.trailingAnchor constant: -20.0]];
    }
    if (submitButton_ != nil && blockSliderTimeDisplayLabel_ != nil) {
        [replacementConstraints addObject: [blockSliderTimeDisplayLabel_.topAnchor constraintEqualToAnchor: submitButton_.bottomAnchor constant: 6.0]];
    }
    [NSLayoutConstraint activateConstraints: replacementConstraints];

    // Ensure buttons stay above the label in z-order so click handling is reliable.
    [contentView addSubview: editBlocklistButton_ positioned: NSWindowAbove relativeTo: nil];
    if (settingsButton != nil) {
        [contentView addSubview: settingsButton positioned: NSWindowAbove relativeTo: nil];
    }
    self.mainInternetTimeLayoutConfigured = YES;
}

- (void)refreshInternetTimeSampleIfNeeded:(BOOL)force {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshInternetTimeSampleIfNeeded: force];
        });
        return;
    }
    
    if (self.internetTimeFetchInProgress) {
        return;
    }
    
    NSDate* now = [NSDate date];
    if (!force && self.internetTimeLastFetchAttempt != nil) {
        if ([now timeIntervalSinceDate: self.internetTimeLastFetchAttempt] < kMainTrustedTimeRefreshIntervalSecs) {
            return;
        }
    }
    
    self.internetTimeFetchInProgress = YES;
    self.internetTimeLastFetchAttempt = now;
    __weak typeof(self) weakSelf = self;
    [self fetchConsensusInternetTimeWithCompletion:^(NSDate * _Nullable fetchedDate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            
            strongSelf.internetTimeFetchInProgress = NO;
            if (fetchedDate != nil) {
                strongSelf.internetTimeBaseDate = fetchedDate;
                strongSelf.internetTimeBaseUptime = [NSProcessInfo processInfo].systemUptime;
                strongSelf.internetTimeLastFetchSuccess = [NSDate date];
            }
            [strongSelf updateMainInternetTimeDisplay];
        });
    }];
}

- (void)fetchConsensusInternetTimeWithCompletion:(void(^)(NSDate* _Nullable fetchedDate))completion {
    NSArray<NSString*>* sourceURLs = [self normalizedTrustedTimeSourceURLs];
    if (sourceURLs.count < 1) {
        if (completion != nil) completion(nil);
        return;
    }
    NSInteger requiredMatches = [self normalizedTrustedTimeConsensusRequiredCountForSourceCount: sourceURLs.count];
    NSTimeInterval maxSkewSeconds = [self normalizedTrustedTimeConsensusMaxSkewSeconds];
    
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = kMainTrustedTimeRequestTimeoutSecs;
    config.timeoutIntervalForResource = kMainTrustedTimeRequestTimeoutSecs;
    NSURLSession* session = [NSURLSession sessionWithConfiguration: config];
    dispatch_group_t requestGroup = dispatch_group_create();
    dispatch_queue_t syncQueue = dispatch_queue_create("org.eyebeam.SelfControlX.mainTrustedTime", DISPATCH_QUEUE_SERIAL);
    NSMutableArray<NSDate*>* sourceDates = [NSMutableArray arrayWithCapacity: sourceURLs.count];
    
    for (NSString* sourceURL in sourceURLs) {
        NSURL* url = [NSURL URLWithString: sourceURL];
        if (url == nil) {
            continue;
        }
        
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url
                                                               cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval: kMainTrustedTimeRequestTimeoutSecs];
        request.HTTPMethod = @"HEAD";
        
        dispatch_group_enter(requestGroup);
        [[session dataTaskWithRequest: request
                    completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            (void)data;
            NSDate* parsedDate = nil;
            if (error == nil && [response isKindOfClass: [NSHTTPURLResponse class]]) {
                NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
                if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 400) {
                    NSDictionary* headers = httpResponse.allHeaderFields;
                    NSString* dateHeader = nil;
                    for (id key in headers) {
                        if ([key isKindOfClass: [NSString class]] && [(NSString*)key caseInsensitiveCompare: @"Date"] == NSOrderedSame) {
                            id value = headers[key];
                            if ([value isKindOfClass: [NSString class]]) {
                                dateHeader = (NSString*)value;
                            }
                            break;
                        }
                    }
                    
                    if (dateHeader != nil) {
                        NSDateFormatter* formatter = SCMainHTTPDateHeaderFormatter();
                        @synchronized (formatter) {
                            parsedDate = [formatter dateFromString: dateHeader];
                        }
                    }
                }
            }
            
            if (parsedDate != nil) {
                dispatch_sync(syncQueue, ^{
                    [sourceDates addObject: parsedDate];
                });
            }
            dispatch_group_leave(requestGroup);
        }] resume];
    }
    
    dispatch_group_notify(requestGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [session finishTasksAndInvalidate];
        
        __block NSArray<NSDate*>* collectedDates = @[];
        dispatch_sync(syncQueue, ^{
            collectedDates = [sourceDates copy];
        });
        
        NSDate* consensusDate = [self consensusTrustedDateFromSamples: collectedDates
                                                      requiredMatches: requiredMatches
                                                       maxSkewSeconds: maxSkewSeconds];
        
        if (completion != nil) {
            completion(consensusDate);
        }
    });
}

- (NSArray<NSString*>*)normalizedTrustedTimeSourceURLs {
    NSArray<NSString*>* normalizedURLs = SCMainNormalizedTrustedTimeSourceURLsFromRawValue([defaults_ objectForKey: kTrustedTimeSourceURLsDefaultsKey]);
    [defaults_ setObject: normalizedURLs forKey: kTrustedTimeSourceURLsDefaultsKey];
    return normalizedURLs;
}

- (NSInteger)normalizedTrustedTimeConsensusRequiredCountForSourceCount:(NSUInteger)sourceCount {
    NSInteger requiredMatches = [defaults_ integerForKey: kTrustedTimeConsensusRequiredCountDefaultsKey];
    if (requiredMatches < 1) {
        requiredMatches = kMainTrustedTimeDefaultRequiredCount;
    }
    
    NSInteger maxAllowed = (NSInteger)MAX(sourceCount, 1);
    requiredMatches = MIN(MAX(requiredMatches, 1), maxAllowed);
    [defaults_ setInteger: requiredMatches forKey: kTrustedTimeConsensusRequiredCountDefaultsKey];
    return requiredMatches;
}

- (NSTimeInterval)normalizedTrustedTimeConsensusMaxSkewSeconds {
    NSTimeInterval maxSkewSeconds = [[defaults_ objectForKey: kTrustedTimeConsensusMaxSkewSecondsDefaultsKey] doubleValue];
    if (maxSkewSeconds <= 0) {
        maxSkewSeconds = kMainTrustedTimeDefaultMaxSkewSeconds;
    }
    
    maxSkewSeconds = MIN(MAX(maxSkewSeconds, kMainTrustedTimeMinimumMaxSkewSeconds), kMainTrustedTimeMaximumMaxSkewSeconds);
    [defaults_ setObject: @(maxSkewSeconds) forKey: kTrustedTimeConsensusMaxSkewSecondsDefaultsKey];
    return maxSkewSeconds;
}

- (NSDate* _Nullable)consensusTrustedDateFromSamples:(NSArray<NSDate*>*)samples requiredMatches:(NSInteger)requiredMatches maxSkewSeconds:(NSTimeInterval)maxSkewSeconds {
    if (samples.count < 1) {
        return nil;
    }
    
    NSArray<NSDate*>* sortedDates = [samples sortedArrayUsingComparator:^NSComparisonResult(NSDate * _Nonnull first, NSDate * _Nonnull second) {
        return [first compare: second];
    }];
    
    NSInteger clampedRequiredMatches = MIN(MAX(requiredMatches, 1), (NSInteger)sortedDates.count);
    NSTimeInterval clampedMaxSkew = MIN(MAX(maxSkewSeconds, kMainTrustedTimeMinimumMaxSkewSeconds), kMainTrustedTimeMaximumMaxSkewSeconds);
    
    NSInteger left = 0;
    NSInteger bestLeft = 0;
    NSInteger bestWindowSize = 0;
    for (NSInteger right = 0; right < (NSInteger)sortedDates.count; right++) {
        while (left <= right) {
            NSUInteger rightIndex = (NSUInteger)right;
            NSUInteger leftIndex = (NSUInteger)left;
            if ([sortedDates[rightIndex] timeIntervalSinceDate: sortedDates[leftIndex]] <= clampedMaxSkew) {
                break;
            }
            left++;
        }
        
        NSInteger currentWindowSize = right - left + 1;
        if (currentWindowSize > bestWindowSize) {
            bestWindowSize = currentWindowSize;
            bestLeft = left;
        }
    }
    
    if (bestWindowSize < clampedRequiredMatches) {
        return nil;
    }
    
    NSArray<NSDate*>* winningCluster = [sortedDates subarrayWithRange: NSMakeRange((NSUInteger)bestLeft, (NSUInteger)bestWindowSize)];
    NSUInteger midpoint = winningCluster.count / 2;
    if ((winningCluster.count % 2) == 1) {
        return winningCluster[midpoint];
    }
    
    NSDate* lower = winningCluster[midpoint - 1];
    NSDate* upper = winningCluster[midpoint];
    NSTimeInterval averageTimestamp = (lower.timeIntervalSince1970 + upper.timeIntervalSince1970) / 2.0;
    return [NSDate dateWithTimeIntervalSince1970: averageTimestamp];
}

- (NSDate* _Nullable)estimatedDateFromTrustedFetchDate:(NSDate* _Nullable)trustedFetchDate fetchUptime:(NSNumber* _Nullable)fetchUptime {
    if (![trustedFetchDate isKindOfClass: [NSDate class]] || ![fetchUptime isKindOfClass: [NSNumber class]]) {
        return nil;
    }
    
    if ([trustedFetchDate isEqualToDate: [NSDate distantPast]]) {
        return nil;
    }
    
    NSTimeInterval uptimeDelta = [NSProcessInfo processInfo].systemUptime - fetchUptime.doubleValue;
    if (uptimeDelta < 0) {
        uptimeDelta = 0;
    }
    
    return [trustedFetchDate dateByAddingTimeInterval: uptimeDelta];
}

- (NSDate*)estimatedTrustedInternetDate {
    NSDate* appSampleEstimate = [self estimatedDateFromTrustedFetchDate: self.internetTimeBaseDate
                                                            fetchUptime: @(self.internetTimeBaseUptime)];
    if (appSampleEstimate != nil) {
        return appSampleEstimate;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    NSDate* trustedFetchDate = [settings valueForKey: @"TrustedTimeLastFetchDate"];
    NSNumber* trustedFetchUptime = [settings valueForKey: @"TrustedTimeLastFetchUptime"];
    return [self estimatedDateFromTrustedFetchDate: trustedFetchDate fetchUptime: trustedFetchUptime];
}

- (void)updateMainInternetTimeDisplay {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateMainInternetTimeDisplay];
        });
        return;
    }
    if (!self.mainInternetTimeLayoutConfigured) {
        [self setupMainInternetTimeDisplay];
    }
    
    NSDate* trustedDate = [self estimatedTrustedInternetDate];
    static NSDateFormatter* formatter = nil;
    if (formatter == nil) {
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterLongStyle;
        formatter.timeStyle = NSDateFormatterLongStyle;
    }
    
    if (trustedDate != nil) {
        blocklistTeaserLabel_.stringValue = [NSString stringWithFormat: @"Internet time: %@", [formatter stringFromDate: trustedDate]];
    } else {
        if (self.internetTimeFetchInProgress) {
            blocklistTeaserLabel_.stringValue = @"Internet time: fetching trusted sample...";
        } else {
            blocklistTeaserLabel_.stringValue = @"Internet time: unavailable (no trusted sample yet)";
        }
    }
}

- (void)internetTimeDisplayTimerFired:(NSTimer*)timer {
    (void)timer;
    [self refreshInternetTimeSampleIfNeeded: NO];
    [self updateMainInternetTimeDisplay];
}

- (void)setupInlineBlocklistEditor {
    if (self.inlineBlocklistContainer != nil || initialWindow_ == nil || editBlocklistButton_ == nil) {
        return;
    }
    
    NSView* contentView = [initialWindow_ contentView];
    if (contentView == nil) {
        return;
    }
    
    NSView* container = [[NSView alloc] initWithFrame: NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    container.wantsLayer = YES;
    container.layer.borderWidth = 1.0;
    container.layer.cornerRadius = 6.0;
    NSColor* borderColor = [NSColor gridColor];
    if (@available(macOS 10.14, *)) {
        borderColor = [NSColor separatorColor];
    }
    container.layer.borderColor = borderColor.CGColor;
    
    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame: NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;
    
    NSTextView* textView = [[NSTextView alloc] initWithFrame: NSZeroRect];
    textView.minSize = NSMakeSize(0.0, 0.0);
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.richText = NO;
    textView.importsGraphics = NO;
    textView.allowsImageEditing = NO;
    textView.font = [NSFont userFixedPitchFontOfSize: 12.0] ?: [NSFont systemFontOfSize: 12.0];
    textView.automaticQuoteSubstitutionEnabled = NO;
    textView.automaticDashSubstitutionEnabled = NO;
    textView.automaticDataDetectionEnabled = NO;
    textView.string = @"";
    textView.textContainer.widthTracksTextView = YES;
    textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    scrollView.documentView = textView;
    
    NSButton* applyButton = [[NSButton alloc] initWithFrame: NSZeroRect];
    applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    applyButton.bezelStyle = NSBezelStyleRounded;
    applyButton.title = NSLocalizedString(@"Apply Blocklist", @"Apply inline blocklist changes button");
    applyButton.target = self;
    applyButton.action = @selector(applyInlineBlocklistChanges:);
    
    [container addSubview: scrollView];
    [container addSubview: applyButton];
    [contentView addSubview: container];
    
    NSLayoutConstraint* heightConstraint = [container.heightAnchor constraintEqualToConstant: 0.0];
    [NSLayoutConstraint activateConstraints: @[
        [container.leadingAnchor constraintEqualToAnchor: contentView.leadingAnchor constant: 19.0],
        [container.trailingAnchor constraintEqualToAnchor: contentView.trailingAnchor constant: -19.0],
        [container.topAnchor constraintEqualToAnchor: editBlocklistButton_.bottomAnchor constant: 8.0],
        heightConstraint,
        [scrollView.leadingAnchor constraintEqualToAnchor: container.leadingAnchor constant: 8.0],
        [scrollView.trailingAnchor constraintEqualToAnchor: container.trailingAnchor constant: -8.0],
        [scrollView.topAnchor constraintEqualToAnchor: container.topAnchor constant: 8.0],
        [scrollView.bottomAnchor constraintEqualToAnchor: applyButton.topAnchor constant: -8.0],
        [applyButton.trailingAnchor constraintEqualToAnchor: container.trailingAnchor constant: -8.0],
        [applyButton.bottomAnchor constraintEqualToAnchor: container.bottomAnchor constant: -8.0],
        [applyButton.heightAnchor constraintEqualToConstant: 30.0]
    ]];
    
    self.inlineBlocklistContainer = container;
    self.inlineBlocklistScrollView = scrollView;
    self.inlineBlocklistTextView = textView;
    self.inlineBlocklistApplyButton = applyButton;
    self.inlineBlocklistHeightConstraint = heightConstraint;
    self.inlineBlocklistExpanded = NO;
    [self syncInlineBlocklistEditorFromCurrentSettings];
}

- (void)syncInlineBlocklistEditorFromCurrentSettings {
    if (self.inlineBlocklistTextView == nil) {
        return;
    }
    
    NSArray<NSString*>* blocklist = [SCMiscUtilities cleanBlocklist: [defaults_ arrayForKey: @"Blocklist"]];
    NSString* blocklistString = [blocklist componentsJoinedByString: @"\n"];
    
    NSResponder* firstResponder = initialWindow_.firstResponder;
    BOOL userIsEditingInlineText = self.inlineBlocklistExpanded
        && [firstResponder isKindOfClass: [NSTextView class]]
        && (firstResponder == self.inlineBlocklistTextView);
    if (!userIsEditingInlineText && ![self.inlineBlocklistTextView.string isEqualToString: blocklistString]) {
        self.inlineBlocklistTextView.string = blocklistString;
    }
    
    BOOL blockActiveOrStarting = [SCUIUtilities blockIsRunning] || self.addingBlock;
    self.inlineBlocklistTextView.editable = !blockActiveOrStarting;
    self.inlineBlocklistApplyButton.enabled = !blockActiveOrStarting;
}

- (void)setInlineBlocklistExpanded:(BOOL)expanded animated:(BOOL)animated {
    [self setupInlineBlocklistEditor];
    if (self.inlineBlocklistHeightConstraint == nil || initialWindow_ == nil) {
        return;
    }
    
    CGFloat targetHeight = expanded ? kInlineBlocklistExpandedHeight : 0.0;
    CGFloat currentHeight = self.inlineBlocklistHeightConstraint.constant;
    CGFloat deltaHeight = targetHeight - currentHeight;
    
    if (fabs(deltaHeight) < 0.5) {
        self.inlineBlocklistExpanded = expanded;
        if (!expanded) {
            self.inlineBlocklistContainer.hidden = YES;
        } else {
            self.inlineBlocklistContainer.hidden = NO;
            [self syncInlineBlocklistEditorFromCurrentSettings];
        }
        return;
    }
    
    if (expanded) {
        self.inlineBlocklistContainer.hidden = NO;
        self.collapsedInitialWindowFrame = initialWindow_.frame;
        [self syncInlineBlocklistEditorFromCurrentSettings];
    }
    
    self.inlineBlocklistHeightConstraint.constant = targetHeight;
    
    NSRect nextFrame = initialWindow_.frame;
    nextFrame.size.height += deltaHeight;
    nextFrame.origin.y -= deltaHeight;
    [initialWindow_ setFrame: nextFrame display: YES animate: animated];
    
    self.inlineBlocklistExpanded = expanded;
    if (!expanded) {
        self.inlineBlocklistContainer.hidden = YES;
    }
}

- (NSArray<NSString*>*)inlineBlocklistEntriesFromEditorText {
    if (self.inlineBlocklistTextView == nil) {
        return @[];
    }
    
    NSString* rawText = self.inlineBlocklistTextView.string ?: @"";
    NSArray<NSString*>* rawLines = [rawText componentsSeparatedByCharactersInSet: [NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString*>* cleanedEntries = [NSMutableArray array];
    NSMutableSet<NSString*>* seenEntries = [NSMutableSet set];
    
    for (NSString* rawLine in rawLines) {
        NSArray<NSString*>* parsedEntries = [SCMiscUtilities cleanBlocklistEntry: rawLine];
        for (NSString* parsedEntry in parsedEntries) {
            NSString* cleanedEntry = [parsedEntry stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cleanedEntry.length > 0 && ![seenEntries containsObject: cleanedEntry]) {
                [seenEntries addObject: cleanedEntry];
                [cleanedEntries addObject: cleanedEntry];
            }
        }
    }
    
    return cleanedEntries;
}

- (IBAction)applyInlineBlocklistChanges:(id)sender {
    (void)sender;
    if (self.inlineBlocklistTextView == nil) {
        return;
    }
    
    if ([SCUIUtilities blockIsRunning] || self.addingBlock) {
        [self syncInlineBlocklistEditorFromCurrentSettings];
        return;
    }
    
    NSArray<NSString*>* cleanedBlocklist = [self inlineBlocklistEntriesFromEditorText];
    [defaults_ setObject: cleanedBlocklist forKey: @"Blocklist"];
    [defaults_ synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
    [self refreshUserInterface];
}

- (void)configureMenuBarStatusItem {
    if (![defaults_ boolForKey: kMenuBarEnabledDefaultsKey]) {
        [self tearDownMenuBarStatusItem];
        return;
    }
    
    if (self.menuBarStatusItem == nil) {
        self.menuBarStatusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];
        self.menuBarMenu = [[NSMenu alloc] initWithTitle: @"SelfControlX"];
        
        self.menuBarTimerMenuItem = [[NSMenuItem alloc] initWithTitle: @"" action: nil keyEquivalent: @""];
        self.menuBarTimerMenuItem.enabled = NO;
        [self.menuBarMenu addItem: self.menuBarTimerMenuItem];

        self.menuBarShowTimerMenuItem = [[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Show Active Timer", @"Menu bar action to reopen active block timer window")
                                                                    action: @selector(openSelfControlX:)
                                                             keyEquivalent: @""];
        self.menuBarShowTimerMenuItem.target = self;
        self.menuBarShowTimerMenuItem.enabled = YES;
        [self.menuBarMenu addItem: self.menuBarShowTimerMenuItem];
        
        self.menuBarQuickBlockMenuItem = [[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Quick Block", @"Quick block submenu title for menu bar")
                                                                     action: nil
                                                              keyEquivalent: @""];
        self.menuBarQuickBlockMenuItem.enabled = NO;
        [self.menuBarMenu addItem: self.menuBarQuickBlockMenuItem];
        
        self.menuBarStatusItem.menu = self.menuBarMenu;
        
        [self rebuildQuickBlockMenu];
    }
    
    if (self.menuBarRefreshTimer == nil) {
        self.menuBarRefreshTimer = [NSTimer scheduledTimerWithTimeInterval: 1.0
                                                                     target: self
                                                                   selector: @selector(menuBarRefreshTimerFired:)
                                                                   userInfo: nil
                                                                    repeats: YES];
    }
    
    [self rebuildQuickBlockMenu];
    self.menuBarStatusItem.button.title = [self normalizedMenuBarIconText];
}

- (void)tearDownMenuBarStatusItem {
    if (self.menuBarRefreshTimer != nil) {
        [self.menuBarRefreshTimer invalidate];
        self.menuBarRefreshTimer = nil;
    }
    
    if (self.menuBarStatusItem != nil) {
        [[NSStatusBar systemStatusBar] removeStatusItem: self.menuBarStatusItem];
        self.menuBarStatusItem = nil;
    }
    
    self.menuBarMenu = nil;
    self.menuBarTimerMenuItem = nil;
    self.menuBarShowTimerMenuItem = nil;
    self.menuBarQuickBlockMenuItem = nil;
    self.menuBarQuickDurationMenuItems = nil;
}

- (void)menuBarRefreshTimerFired:(NSTimer*)timer {
    (void)timer;
    [self refreshMenuBarStatusItem];
}

- (void)refreshMenuBarStatusItem {
    if (self.menuBarStatusItem == nil) {
        return;
    }
    
    self.menuBarStatusItem.button.title = [self normalizedMenuBarIconText];
    self.menuBarTimerMenuItem.title = [self menuBarActiveTimerString];
    
    BOOL blockIsActive = [SCUIUtilities blockIsRunning];
    self.menuBarShowTimerMenuItem.enabled = YES;
    self.menuBarShowTimerMenuItem.title = blockIsActive
        ? NSLocalizedString(@"Show Active Timer", @"Menu bar action when a block is active")
        : NSLocalizedString(@"Open SelfControlX", @"Menu bar action when no block is active");
    self.menuBarQuickBlockMenuItem.title = blockIsActive
        ? NSLocalizedString(@"Add Time", @"Menu bar quick block title when block is active")
        : NSLocalizedString(@"Quick Block", @"Menu bar quick block title when no block is active");
}

- (NSString*)menuBarDurationTitleForMinutes:(NSInteger)minutes {
    if (minutes % 60 == 0) {
        NSInteger hours = minutes / 60;
        if (hours == 1) {
            return NSLocalizedString(@"1 hr", @"One hour duration label");
        }
        return [NSString stringWithFormat: NSLocalizedString(@"%ld hr", @"Duration label in whole hours"), (long)hours];
    }
    
    return [NSString stringWithFormat: NSLocalizedString(@"%ld min", @"Duration label in minutes"), (long)minutes];
}

- (IBAction)openSelfControlX:(id)sender {
    (void)sender;
    [self ensureRegularActivationPolicy];
    [NSApp activateIgnoringOtherApps: YES];
    if ([SCUIUtilities blockIsRunning]) {
        [self showTimerWindow];
    } else {
        [initialWindow_ makeKeyAndOrderFront: self];
    }
}

- (void)rebuildQuickBlockMenu {
    if (self.menuBarQuickBlockMenuItem == nil || self.menuBarMenu == nil) {
        return;
    }

    for (NSMenuItem* existingItem in self.menuBarQuickDurationMenuItems ?: @[]) {
        [self.menuBarMenu removeItem: existingItem];
    }

    NSMutableArray<NSMenuItem*>* quickDurationItems = [NSMutableArray array];
    NSInteger insertIndex = [self.menuBarMenu indexOfItem: self.menuBarQuickBlockMenuItem] + 1;
    for (NSNumber* durationMinutes in [self menuBarQuickBlockDurationsMinutes]) {
        NSInteger minutes = durationMinutes.integerValue;
        NSMenuItem* quickDurationItem = [[NSMenuItem alloc] initWithTitle: [self menuBarDurationTitleForMinutes: minutes]
                                                                    action: @selector(quickBlockMenuSelection:)
                                                             keyEquivalent: @""];
        quickDurationItem.target = self;
        quickDurationItem.tag = (NSInteger)minutes;
        [self.menuBarMenu insertItem: quickDurationItem atIndex: insertIndex];
        insertIndex += 1;
        [quickDurationItems addObject: quickDurationItem];
    }

    self.menuBarQuickDurationMenuItems = [quickDurationItems copy];
}

- (NSArray<NSNumber*>*)menuBarQuickBlockDurationsMinutes {
    NSString* rawDurations = [defaults_ stringForKey: kMenuBarQuickDurationsDefaultsKey];
    if (rawDurations == nil) {
        rawDurations = @"";
    }
    
    NSInteger maxBlockLength = [defaults_ integerForKey: @"MaxBlockLength"];
    maxBlockLength = MIN(MAX(maxBlockLength, 1), kMaximumBlockLengthLimitMinutes);
    NSCharacterSet* separatorSet = [NSCharacterSet characterSetWithCharactersInString: @",; \t\n"];
    
    NSMutableArray<NSNumber*>* durations = [NSMutableArray array];
    NSMutableSet<NSNumber*>* seenValues = [NSMutableSet set];
    NSArray<NSString*>* components = [rawDurations componentsSeparatedByCharactersInSet: separatorSet];
    for (NSString* component in components) {
        if (component.length < 1) {
            continue;
        }
        
        NSInteger parsedValue = [component integerValue];
        if (parsedValue < 1) {
            continue;
        }
        
        parsedValue = MIN(parsedValue, maxBlockLength);
        NSNumber* durationNumber = @(parsedValue);
        if (![seenValues containsObject: durationNumber]) {
            [seenValues addObject: durationNumber];
            [durations addObject: durationNumber];
        }
    }
    
    if (durations.count == 0) {
        return @[@30, @60, @120, @180, @240];
    }
    
    return durations;
}

- (NSString*)normalizedMenuBarIconText {
    NSString* iconText = [defaults_ stringForKey: kMenuBarIconTextDefaultsKey];
    if (iconText == nil) {
        return kMenuBarDefaultIconText;
    }
    
    NSString* trimmedText = [iconText stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedText.length < 1) {
        return kMenuBarDefaultIconText;
    }
    
    return trimmedText;
}

- (NSString*)menuBarActiveTimerString {
    if (![SCUIUtilities blockIsRunning]) {
        return NSLocalizedString(@"Active Timer: none", @"Menu bar timer line when no active block");
    }
    
    if (![SCBlockUtilities modernBlockIsRunning]) {
        return NSLocalizedString(@"Active Timer: running", @"Menu bar timer line for legacy active block");
    }
    
    NSTimeInterval remainingSeconds = [SCBlockUtilities currentBlockRemainingSecondsForDisplay];
    if (remainingSeconds <= 0) {
        return NSLocalizedString(@"Active Timer: Finishing", @"Menu bar timer line while finishing block");
    }
    
    NSInteger roundedSeconds = (NSInteger)(remainingSeconds + 0.999);
    NSInteger hours = roundedSeconds / 3600;
    NSInteger minutes = (roundedSeconds % 3600) / 60;
    NSInteger seconds = roundedSeconds % 60;
    
    return [NSString stringWithFormat: NSLocalizedString(@"Active Timer: %02ld:%02ld:%02ld", @"Menu bar active timer row"),
            (long)hours,
            (long)minutes,
            (long)seconds];
}

- (IBAction)quickBlockMenuSelection:(id)sender {
    if (![sender isKindOfClass: [NSMenuItem class]]) {
        return;
    }
    
    NSInteger minutes = ((NSMenuItem*)sender).tag;
    if (minutes < 1 || self.addingBlock) {
        return;
    }
    
    if ([SCUIUtilities blockIsRunning]) {
        [self extendBlockTime: minutes lock: [NSLock new]];
        return;
    }
    
    NSInteger normalizedDuration = [blockDurationSlider_ sanitizedDurationMinutesForValue: minutes];
    [self setDefaultsBlockDurationOnMainThread: @(normalizedDuration)];
    [self updateTimeSliderDisplay: blockDurationSlider_];
    [self addBlock: sender];
}

- (void)updateBlockEndDate:(NSLock*)lockToUse minutesToAdd:(NSInteger)minutesToAdd {
    if(![lockToUse tryLock]) {
        return;
    }
    [SCSentry addBreadcrumb: @"App running updateBlockEndDate method" category:@"app"];

    minutesToAdd = MAX(minutesToAdd, 0); // make sure there's no funny business with negative minutes
    id oldBlockEndDateRawValue = [settings_ valueForKey: @"BlockEndDate"];
    if (![oldBlockEndDateRawValue isKindOfClass: [NSDate class]]) {
        [lockToUse unlock];
        [SCUIUtilities presentError: [SCErr errorWithCode: 307]];
        return;
    }
    NSDate* oldBlockEndDate = (NSDate*)oldBlockEndDateRawValue;
    NSDate* newBlockEndDate = [oldBlockEndDate dateByAddingTimeInterval: (minutesToAdd * 60)];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        // Before we try to extend the block, make sure the block time didn't run out (or is about to run out) in the meantime.
        // In trusted-time mode, defer this to daemon-side validation so strict offline-hold blocks can still be extended.
        if (![SCBlockUtilities modernBlockUsesTrustedTime] && [SCBlockUtilities currentBlockRemainingSecondsForDisplay] < 1) {
            // we're done, or will be by the time we get to it! so just let it expire. they can restart it.
            [lockToUse unlock];
            return;
        }

        NSLog(@"Refreshed connection updating active block end date!");
        [self.xpc updateBlockEndDate: newBlockEndDate
                               reply:^(NSError * _Nonnull error) {
            [self->timerWindowController_ performSelectorOnMainThread:@selector(closeExtendSheet:) withObject: self waitUntilDone: YES];

            if (error != nil) {
                [SCUIUtilities presentError: error];
            } else {
                [SCSentry addBreadcrumb: @"App extended block duration successfully" category:@"app"];
            }
            
            [lockToUse unlock];
        }];
    }];
}

- (IBAction)save:(id)sender {
	NSSavePanel *sp;
	long runResult;

	/* create or get the shared instance of NSSavePanel */
	sp = [NSSavePanel savePanel];
	sp.allowedFileTypes = @[@"selfcontrol"];

	/* display the NSSavePanel */
	runResult = [sp runModal];

	/* if successful, save file under designated name */
	if (runResult == NSModalResponseOK) {
        NSError* err;
        [SCBlockFileReaderWriter writeBlocklistToFileURL: sp.URL
                                   blockInfo: @{
                                       @"Blocklist": [defaults_ arrayForKey: @"Blocklist"],
                                       @"BlockAsWhitelist": [defaults_ objectForKey: @"BlockAsWhitelist"]
                                       
                                   }
                                   error: &err];

        if (err != nil) {
            NSError* displayErr = [SCErr errorWithCode: 101 subDescription: err.localizedDescription];
            [SCSentry captureError: displayErr];
            NSBeep();
            [SCUIUtilities presentError: displayErr];
			return;
        } else {
            [SCSentry addBreadcrumb: @"Saved blocklist to file" category:@"app"];
        }
	}
}

- (BOOL)openSavedBlockFileAtURL:(NSURL*)fileURL {
    NSDictionary* settingsFromFile = [SCBlockFileReaderWriter readBlocklistFromFile: fileURL];
    
    if (settingsFromFile != nil) {
        [defaults_ setObject: settingsFromFile[@"Blocklist"] forKey: @"Blocklist"];
        [defaults_ setObject: settingsFromFile[@"BlockAsWhitelist"] forKey: @"BlockAsWhitelist"];
        [SCSentry addBreadcrumb: @"Opened blocklist from file" category:@"app"];
    } else {
        NSLog(@"WARNING: Could not read a valid blocklist from file - ignoring.");
        return NO;
    }

    // send a notification so the domain list (etc) updates
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
    
    [self refreshUserInterface];
    return YES;
}

- (IBAction)open:(id)sender {
	NSOpenPanel* oPanel = [NSOpenPanel openPanel];
	oPanel.allowedFileTypes = @[@"selfcontrol"];
	oPanel.allowsMultipleSelection = NO;

	long result = [oPanel runModal];
	if (result == NSModalResponseOK) {
		if([oPanel.URLs count] > 0) {
            [self openSavedBlockFileAtURL: oPanel.URLs[0]];
		}
	}
}

- (BOOL)application:(NSApplication*)theApplication openFile:(NSString*)filename {
    return [self openSavedBlockFileAtURL: [NSURL fileURLWithPath: filename]];
}

- (IBAction)openFAQ:(id)sender {
    [SCSentry addBreadcrumb: @"Opened SelfControl FAQ" category:@"app"];
	NSURL *url=[NSURL URLWithString: @"https://github.com/SelfControlApp/selfcontrol/wiki/FAQ#q-selfcontrols-timer-is-at-0000-and-i-cant-start-a-new-block-and-im-freaking-out"];
	[[NSWorkspace sharedWorkspace] openURL: url];
}

- (IBAction)openSupportHub:(id)sender {
    [SCSentry addBreadcrumb: @"Opened SelfControl Support Hub" category:@"app"];
    NSURL *url=[NSURL URLWithString: @"https://selfcontrolapp.com/support"];
    [[NSWorkspace sharedWorkspace] openURL: url];
}


@end
