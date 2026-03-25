//
//  PreferencesGeneralViewController.h
//  SelfControl
//
//  Created by Charles Stigler on 9/27/14.
//
//

#import <Cocoa/Cocoa.h>
#import "MASPreferencesViewController.h"

@interface PreferencesGeneralViewController : NSViewController <MASPreferencesViewController, NSTextFieldDelegate>

@property IBOutlet NSPopUpButton* soundMenu;
@property IBOutlet NSTextField* maxBlockLengthField;
@property IBOutlet NSTextField* sliderIntervalField;
@property IBOutlet NSTextField* menuBarIconField;
@property IBOutlet NSTextField* quickBlockDurationsField;

- (IBAction)soundSelectionChanged:(id)sender;
- (IBAction)durationPreferenceChanged:(id)sender;
- (IBAction)menuBarPreferenceChanged:(id)sender;

@end
