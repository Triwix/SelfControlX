//
//  PreferencesGeneralViewController.m
//  SelfControl
//
//  Created by Charles Stigler on 9/27/14.
//
//

#import "PreferencesGeneralViewController.h"
#import "SCUIUtilities.h"

@interface PreferencesGeneralViewController ()

- (void)normalizeDurationPreferences;
- (void)normalizeMenuBarPreferences;
- (void)configureEditableFields;

@end

@implementation PreferencesGeneralViewController

static NSInteger const kMaximumBlockLengthLimitMinutes = 10080; // 7 days

- (instancetype)init {
    return [super initWithNibName: @"PreferencesGeneralViewController" bundle: nil];
}

- (void)viewDidLoad  {
    [super viewDidLoad];
    
    // set the valid sounds in the Block Sound menu
    [self.soundMenu removeAllItems];
    [self.soundMenu addItemsWithTitles: SCConstants.systemSoundNames];
    
    [self configureEditableFields];
    [self normalizeDurationPreferences];
    [self normalizeMenuBarPreferences];
}

- (void)configureEditableFields {
    NSArray<NSTextField*>* editableFields = @[
        self.maxBlockLengthField,
        self.sliderIntervalField,
        self.menuBarIconField,
        self.quickBlockDurationsField
    ];
    
    for (NSTextField* field in editableFields) {
        field.editable = YES;
        field.selectable = YES;
        field.bezeled = YES;
        field.bordered = YES;
        field.drawsBackground = YES;
        field.delegate = self;
        if ([field.cell isKindOfClass: [NSTextFieldCell class]]) {
            [(NSTextFieldCell*)field.cell setSendsActionOnEndEditing: YES];
        }
    }
}

- (void)normalizeDurationPreferences {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    
    NSInteger maxBlockLength = [defaults integerForKey: @"MaxBlockLength"];
    maxBlockLength = MIN(MAX(maxBlockLength, 1), kMaximumBlockLengthLimitMinutes);
    [defaults setInteger: maxBlockLength forKey: @"MaxBlockLength"];
    [self.maxBlockLengthField setIntegerValue: maxBlockLength];
    
    NSInteger sliderIntervalMinutes = [defaults integerForKey: @"BlockDurationSliderIntervalMinutes"];
    sliderIntervalMinutes = MIN(MAX(sliderIntervalMinutes, 1), maxBlockLength);
    [defaults setInteger: sliderIntervalMinutes forKey: @"BlockDurationSliderIntervalMinutes"];
    [self.sliderIntervalField setIntegerValue: sliderIntervalMinutes];
}

- (void)normalizeMenuBarPreferences {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    
    NSString* menuBarIconText = [[defaults stringForKey: @"MenuBarIconText"] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (menuBarIconText.length < 1) {
        menuBarIconText = @"\u30c4";
    }
    [defaults setObject: menuBarIconText forKey: @"MenuBarIconText"];
    self.menuBarIconField.stringValue = menuBarIconText;
    
    NSString* quickDurations = [[defaults stringForKey: @"MenuBarQuickBlockDurationsMinutes"] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (quickDurations.length < 1) {
        quickDurations = @"30,60,120,180,240";
    }
    [defaults setObject: quickDurations forKey: @"MenuBarQuickBlockDurationsMinutes"];
    self.quickBlockDurationsField.stringValue = quickDurations;
}

- (IBAction)soundSelectionChanged:(NSPopUpButton*)sender {
	// Map the tags used in interface builder to the sound
    NSArray<NSString*>* systemSoundNames = SCConstants.systemSoundNames;
	
    NSString* selectedSoundName = sender.titleOfSelectedItem;
    NSUInteger blockSoundIndex = [systemSoundNames indexOfObject: selectedSoundName];
    if (blockSoundIndex == NSNotFound) {
        NSLog(@"WARNING: User selected unknown alert sound %@.", selectedSoundName);
        NSError* err = [SCErr errorWithCode: 310];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
        return;
    }

	// now play the sound to preview it for the user
	NSSound* alertSound = [NSSound soundNamed: systemSoundNames[blockSoundIndex]];
	if(!alertSound) {
		NSLog(@"WARNING: Alert sound not found.");
		NSError* err = [SCErr errorWithCode: 107];
		[SCSentry captureError: err];
		[SCUIUtilities presentError: err];
	} else {
		[alertSound play];
	}
}

- (IBAction)durationPreferenceChanged:(id)sender {
    (void)sender;
    [self normalizeDurationPreferences];
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
}

- (IBAction)menuBarPreferenceChanged:(id)sender {
    (void)sender;
    [self normalizeMenuBarPreferences];
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.maxBlockLengthField || obj.object == self.sliderIntervalField) {
        [self durationPreferenceChanged: obj.object];
    } else if (obj.object == self.menuBarIconField || obj.object == self.quickBlockDurationsField) {
        [self menuBarPreferenceChanged: obj.object];
    }
}

#pragma mark MASPreferencesViewController

- (NSString*)identifier {
	return @"GeneralPreferences";
}
- (NSImage *)toolbarItemImage {
	return [NSImage imageNamed: NSImageNamePreferencesGeneral];
}

- (NSString *)toolbarItemLabel {
	return NSLocalizedString(@"General", @"Toolbar item name for the General preference pane");
}

- (BOOL)hasResizableWidth {
    return NO;
}

- (BOOL)hasResizableHeight {
    return NO;
}

@end
