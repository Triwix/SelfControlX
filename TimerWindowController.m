
//
//  TimerWindowController.m
//  SelfControl
//
//  Created by Charlie Stigler on 2/15/09.
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


#import "TimerWindowController.h"
#import "SCUIUtilities.h"

@interface TimerWindowController ()

@property(nonatomic, readonly) AppController* appController;
- (NSInteger)normalizedMaxBlockLengthMinutes;
- (NSInteger)normalizedDurationIntervalMinutesForMaxBlockLength:(NSInteger)maxBlockLength;
- (void)applyDurationPreferencesToExtendSlider;

@end

@implementation TimerWindowController

static NSInteger const kMaximumBlockLengthLimitMinutes = 10080; // 7 days

- (TimerWindowController*) init {
	if(self = [super init]) {
        settings_ = [SCSettings sharedSettings];
        
		// We need a block to prevent us from running multiple copies of the "Add to Block"
		// sheet.
		modifyBlockLock = [[NSLock alloc] init];
	
        numStrikes = 0;
	}

	return self;
}

- (void)awakeFromNib {
	[[self window] center];
	[[self window] makeKeyAndOrderFront: self];
    self.window.title = @"SelfControlX";

	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

	NSWindow* window = [self window];

	[window center];

	if([defaults boolForKey:@"TimerWindowFloats"])
		[window setLevel: NSFloatingWindowLevel];
	else
		[window setLevel: NSNormalWindowLevel];

	[window setHidesOnDeactivate: NO];

	[window makeKeyAndOrderFront: self];

    // make the kill-block button red so it's extra noticeable
    NSMutableAttributedString* killBlockMutableAttributedTitle = [killBlockButton_.attributedTitle mutableCopy];
    [killBlockMutableAttributedTitle addAttribute: NSForegroundColorAttributeName value: [NSColor systemRedColor] range: NSMakeRange(0, killBlockButton_.title.length)];
    [killBlockMutableAttributedTitle applyFontTraits: NSBoldFontMask range: NSMakeRange(0, killBlockButton_.title.length)];
    killBlockButton_.attributedTitle = killBlockMutableAttributedTitle;

	killBlockButton_.hidden = YES;
	addToBlockButton_.hidden = NO;
    extendBlockButton_.hidden = NO;
    legacyBlockWarningLabel_.hidden = YES;

    // set up extend block dialog
    [self applyDurationPreferencesToExtendSlider];
    [self updateExtendSliderDisplay: nil];

    if ([SCBlockUtilities modernBlockIsRunning]) {
        blockEndingDate_ = [settings_ valueForKey: @"BlockEndDate"];
    } else {
        // legacy block!
        blockEndingDate_ = [SCMigrationUtilities legacyBlockEndDate];
        
        // if it's a legacy block, we will disable some features
        // since it's too difficult to get these working across versions.
        // the user will just have to wait until their next block to do these things!
        if ([SCBlockUtilities legacyBlockIsRunning]) {
            addToBlockButton_.hidden = YES;
            extendBlockButton_.hidden = YES;
            legacyBlockWarningLabel_.hidden = NO;
        }
    }

    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 45];
	[self updateTimerDisplay: nil];

	timerUpdater_ = [NSTimer timerWithTimeInterval: 1.0
											target: self
										  selector: @selector(updateTimerDisplay:)
										  userInfo: nil
										   repeats: YES];

	//If the dialog isn't focused, instead of getting a NSTimer, we get null.
	//Scheduling the timer from the main thread seems to work.
	[self performSelectorOnMainThread: @selector(hackAroundMainThreadtimer:) withObject: timerUpdater_ waitUntilDone: YES];
    
    [NSTimer scheduledTimerWithTimeInterval: 1.0 repeats: NO block:^(NSTimer * _Nonnull timer) {
        [SCUIUtilities promptBrowserRestartIfNecessary];
    }];
}

- (void)blockEnded {
    [timerUpdater_ invalidate];
    timerUpdater_ = nil;

    [timerLabel_ setStringValue: NSLocalizedString(@"Block not active", @"block not active string")];
    [timerLabel_ setFont: [[NSFontManager sharedFontManager]
                           convertFont: [timerLabel_ font]
                           toSize: 37]
     ];

    [timerLabel_ sizeToFit];

    [self resetStrikes];
    
    [SCSentry addBreadcrumb: @"Block ended and timer window is closing" category: @"app"];
}


- (void)hackAroundMainThreadtimer:(NSTimer*)timer{
	[[NSRunLoop currentRunLoop] addTimer: timer forMode: NSDefaultRunLoopMode];
}

- (void)updateTimerDisplay:(NSTimer*)timer {
	// update UI for the whole app, in case the block is done with
    [self.appController performSelectorOnMainThread:@selector(refreshUserInterface)
                                             withObject:nil
                                          waitUntilDone:NO];

    NSString* finishingString = NSLocalizedString(@"Finishing", @"String shown when waiting for finished block to clear");
    BOOL modernBlockRunning = [SCBlockUtilities modernBlockIsRunning];
    BOOL usingTrustedRemaining = modernBlockRunning && [SCBlockUtilities modernBlockUsesTrustedTime];
    NSTimeInterval remainingSeconds = modernBlockRunning
        ? [SCBlockUtilities currentBlockRemainingSecondsForDisplay]
        : [blockEndingDate_ timeIntervalSinceNow];
	int numSeconds = (int)remainingSeconds;
	int numHours;
	int numMinutes;

    // if we're already showing "Finishing", but the block timer isn't clearing,
    // keep track of that, so we can take drastic measures if necessary.
	if(numSeconds < 0 && [timerLabel_.stringValue isEqualToString: finishingString]) {
		[[NSApp dockTile] setBadgeLabel: nil];
        
        // In strict trusted-time mode, negative remaining time can be expected while offline.
        // Don't surface manual block removal UI in that state.
        if (usingTrustedRemaining) {
            return;
        }

		// This increments the strike counter.  After four strikes of the timer being
		// at or less than 0 seconds, SelfControl will assume something's wrong and enable
		// manual block removal
		numStrikes++;

		if(numStrikes >= 7) {
			// OK, this is taking longer than it should. Enable manual block removal.
            if (numStrikes == 7) {
                NSLog(@"WARNING: Block should have ended! Probable failure to remove.");
                NSError* err = [SCErr errorWithCode: 105];
                [SCSentry captureError: err];
            }

			addToBlockButton_.hidden = YES;
            extendBlockButton_.hidden = YES;
            legacyBlockWarningLabel_.hidden = YES;
			killBlockButton_.hidden = NO;
		}

		return;
	}

	numHours = (numSeconds / 3600);
	numSeconds %= 3600;
	numMinutes = (numSeconds / 60);
	numSeconds %= 60;

    NSString* timeString;
    if (numHours > 0 || numMinutes > 0 || numSeconds > 0) {
        timeString = [NSString stringWithFormat: @"%0.2d:%0.2d:%0.2d",
                      numHours,
                      numMinutes,
                      numSeconds];
    } else {
        // It usually takes 5-15 seconds after a block finishes for it to turn off
        // so show "Finishing" instead of "00:00:00" to avoid user worry and confusion!
        timeString = finishingString;
    }

	[timerLabel_ setStringValue: timeString];
	[timerLabel_ setFont: [[NSFontManager sharedFontManager]
						   convertFont: [timerLabel_ font]
						   toSize: 42]
	 ];

	[timerLabel_ sizeToFit];
	[timerLabel_ setFrame:NSRectFromCGRect(CGRectMake(0, timerLabel_.frame.origin.y, self.window.frame.size.width, timerLabel_.frame.size.height))];
	[self resetStrikes];
    
	if([[NSUserDefaults standardUserDefaults] boolForKey: @"BadgeApplicationIcon"] && numSeconds > 0) {
		// We want to round up the minutes--standard when we aren't displaying seconds.
		if(numSeconds > 0 && numMinutes != 59) {
			numMinutes++;
		}

		NSString* badgeString = [NSString stringWithFormat: @"%0.2d:%0.2d",
								 numHours,
								 numMinutes];
		[[NSApp dockTile] setBadgeLabel: badgeString];
	} else {
		// If we aren't using badging, set the badge string to be
		// empty to remove any badge if there is one.
		[[NSApp dockTile] setBadgeLabel: nil];
	}
    
    // make sure add to list is disabled if it's an allowlist block
    // don't worry about it for a legacy block! the buttons are disabled anyway so it doesn't matter
    if ([SCBlockUtilities modernBlockIsRunning]) {
        addToBlockButton_.enabled = ![settings_ boolForKey: @"ActiveBlockAsWhitelist"];
    }
}

- (BOOL)windowShouldClose:(id)sender {
    (void)sender;
    // Closing the timer window should only hide it; AppController handles
    // explicit teardown when the block ends or app terminates.
    return YES;
}

- (IBAction) addToBlock:(id)sender {
	// Check if there's already a thread trying to modify the block.  If so, don't make
	// another.
	if(![modifyBlockLock tryLock]) {
		return;
	}

    [self.window beginSheet: addSheet_ completionHandler:^(NSModalResponse returnCode) {
        [self->addSheet_ orderOut: self];
    }];

	[modifyBlockLock unlock];
}

- (IBAction) extendBlockTime:(id)sender {
    // Check if there's already a thread trying to modify the block.  If so, don't make
    // another.
    if(![modifyBlockLock tryLock]) {
        return;
    }
    
    [self applyDurationPreferencesToExtendSlider];
    [self updateExtendSliderDisplay: nil];
    
    [self.window beginSheet: extendBlockTimeSheet_ completionHandler:^(NSModalResponse returnCode) {
        [self->extendBlockTimeSheet_ orderOut: self];
    }];
    
    [modifyBlockLock unlock];
}
- (IBAction)updateExtendSliderDisplay:(id)sender {
    [self applyDurationPreferencesToExtendSlider];
    NSInteger normalizedDuration = extendDurationSlider_.durationValueMinutes;
    extendDurationSlider_.integerValue = normalizedDuration;

    extendDurationLabel_.stringValue = extendDurationSlider_.durationDescription;
}

- (IBAction) closeAddSheet:(id)sender {
	[NSApp endSheet: addSheet_];
}
- (IBAction) closeExtendSheet:(id)sender {
    [NSApp endSheet: extendBlockTimeSheet_];
}

- (IBAction) performAddSite:(id)sender {
	NSString* addToBlockTextFieldContents = [addToBlockTextField_ stringValue];
	[self.appController addToBlockList: addToBlockTextFieldContents lock: modifyBlockLock];
    addToBlockTextField_.stringValue = @""; // clear text field for next time
	[NSApp endSheet: addSheet_];
}

- (IBAction) performExtendBlock:(id)sender {
    NSInteger extendBlockMinutes = extendDurationSlider_.durationValueMinutes;
        
    [self.appController extendBlockTime: extendBlockMinutes lock: modifyBlockLock];
    [NSApp endSheet: extendBlockTimeSheet_];
}

- (void)configurationChanged {
    if ([SCBlockUtilities modernBlockIsRunning]) {
        blockEndingDate_ = [settings_ valueForKey: @"BlockEndDate"];
    } else {
        // legacy block!
        blockEndingDate_ = [SCMigrationUtilities legacyBlockEndDate];
    }
    
    // update the blocklist teaser in case that changed
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 45];
    [self applyDurationPreferencesToExtendSlider];
    [self updateTimerDisplay: nil];
}

- (void)didEndSheet:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	[sheet orderOut:self];
}

// see updateTimerDisplay: for an explanation
- (void)resetStrikes {
	numStrikes = 0;
}

- (NSInteger)normalizedMaxBlockLengthMinutes {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSInteger maxBlockLength = [defaults integerForKey: @"MaxBlockLength"];
    maxBlockLength = MIN(MAX(maxBlockLength, 1), kMaximumBlockLengthLimitMinutes);
    [defaults setInteger: maxBlockLength forKey: @"MaxBlockLength"];
    return maxBlockLength;
}

- (NSInteger)normalizedDurationIntervalMinutesForMaxBlockLength:(NSInteger)maxBlockLength {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSInteger durationInterval = [defaults integerForKey: @"BlockDurationSliderIntervalMinutes"];
    durationInterval = MIN(MAX(durationInterval, 1), maxBlockLength);
    [defaults setInteger: durationInterval forKey: @"BlockDurationSliderIntervalMinutes"];
    return durationInterval;
}

- (void)applyDurationPreferencesToExtendSlider {
    NSInteger maxBlockLength = [self normalizedMaxBlockLengthMinutes];
    NSInteger durationInterval = [self normalizedDurationIntervalMinutesForMaxBlockLength: maxBlockLength];
    
    extendDurationSlider_.maxDuration = maxBlockLength;
    extendDurationSlider_.durationIntervalMinutes = durationInterval;
}

- (IBAction)killBlock:(id)sender {
    __weak typeof(self) weakSelf = self;
    [self.appController manuallyClearBlockWithCompletion:^(NSError * _Nullable error) {
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                if (![SCMiscUtilities errorIsAuthCanceled: error]) {
                    [SCUIUtilities presentError: error];
                }
                return;
            }
            
            // reload settings so the timer window knows the block is done
            [[SCSettings sharedSettings] reloadSettings];
            
            // update the UI _before_ we run the alert,
            // so the main window doesn't steal the focus from the alert
            // (and after we've synced settings so we know things have changed)
            [strongSelf.appController refreshUserInterface];
            
            // send some debug info to Sentry to help us track this issue
            [SCSentry captureMessage: @"User manually cleared SelfControl block from the timer window"];
            
            if ([SCBlockUtilities anyBlockIsRunning]) {
                // ruh roh! the block wasn't cleared successfully, since it's still running
                NSError* err = [SCErr errorWithCode: 401];
                [SCSentry captureError: err];
                [SCUIUtilities presentError: err];
            } else {
                NSAlert* alert = [[NSAlert alloc] init];
                [alert setMessageText: @"Success!"];
                [alert setInformativeText:@"The block was cleared successfully. If you're still having issues, please check out the SelfControl FAQ on GitHub."];
                [alert addButtonWithTitle: @"OK"];
                [alert runModal];
            }
        });
    }];
}

- (void)dealloc {
	[timerUpdater_ invalidate];
}

#pragma mark - Properties

- (AppController *)appController
{
    AppController* controller = (AppController *)[NSApp delegate];
    return controller;
}

@end
