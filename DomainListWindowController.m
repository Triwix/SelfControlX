
//
//  DomainListWindowController.m
//  SelfControl
//
//  Created by Charlie Stigler on 2/7/09.
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

#import "DomainListWindowController.h"
#import "AppController.h"

static NSString* const kBlocklistCustomPresetsDefaultsKey = @"BlocklistCustomPresets";
static NSString* const kBlocklistRemovedBuiltinPresetIDsDefaultsKey = @"BlocklistRemovedBuiltinPresetIDs";
static NSString* const kBuiltinPresetCommonDistractingID = @"builtin_common_distracting";
static NSString* const kBuiltinPresetNewsPublicationsID = @"builtin_news_publications";
static NSString* const kPresetImportTypeKey = @"type";
static NSString* const kPresetImportTypeBuiltin = @"builtin";
static NSString* const kPresetImportTypeCustom = @"custom";

@implementation DomainListWindowController

- (DomainListWindowController*)init {
	if(self = [super initWithWindowNibName:@"DomainList"]) {

		defaults_ = [NSUserDefaults standardUserDefaults];

        NSArray* curArray = [defaults_ arrayForKey: @"Blocklist"];
		if(curArray == nil)
			domainList_ = [NSMutableArray arrayWithCapacity: 10];
		else
			domainList_ = [curArray mutableCopy];

        [defaults_ setValue: domainList_ forKey: @"Blocklist"];
	}

	return self;
}

- (NSArray<NSString*>*)normalizedDomainEntriesFromArray:(NSArray*)rawDomains {
    NSMutableArray<NSString*>* normalizedDomains = [NSMutableArray array];
    NSMutableSet<NSString*>* seenDomains = [NSMutableSet set];
    for (id rawDomain in rawDomains ?: @[]) {
        if (![rawDomain isKindOfClass: [NSString class]]) {
            continue;
        }

        NSString* trimmedDomain = [(NSString*)rawDomain stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedDomain.length < 1) {
            continue;
        }

        NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: trimmedDomain];
        for (NSString* cleanedEntry in cleanedEntries) {
            NSString* normalizedEntry = [cleanedEntry stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (normalizedEntry.length < 1 || [seenDomains containsObject: normalizedEntry]) {
                continue;
            }

            [seenDomains addObject: normalizedEntry];
            [normalizedDomains addObject: normalizedEntry];
        }
    }

    return normalizedDomains;
}

- (NSArray<NSDictionary*>*)builtinPresetDefinitions {
    return @[
        @{
            @"id": kBuiltinPresetCommonDistractingID,
            @"title": NSLocalizedString(@"Common Distracting Sites", @"Built-in import preset title"),
            @"domains": [self normalizedDomainEntriesFromArray: [HostImporter commonDistractingWebsites]]
        },
        @{
            @"id": kBuiltinPresetNewsPublicationsID,
            @"title": NSLocalizedString(@"News & Publications", @"Built-in import preset title"),
            @"domains": [self normalizedDomainEntriesFromArray: [HostImporter newsAndPublications]]
        }
    ];
}

- (BOOL)presetNameConflictsWithBuiltinPresetName:(NSString*)presetName {
    NSString* normalizedName = [presetName stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalizedName.length < 1) {
        return NO;
    }

    for (NSDictionary* builtinPreset in [self builtinPresetDefinitions]) {
        NSString* builtinTitle = builtinPreset[@"title"];
        if ([builtinTitle isKindOfClass: [NSString class]]
            && [builtinTitle caseInsensitiveCompare: normalizedName] == NSOrderedSame) {
            return YES;
        }
    }

    return NO;
}

- (NSArray<NSDictionary*>*)normalizedCustomPresets {
    NSMutableArray<NSDictionary*>* normalizedPresets = [NSMutableArray array];
    NSMutableSet<NSString*>* seenPresetNames = [NSMutableSet set];
    id rawPresetValue = [defaults_ objectForKey: kBlocklistCustomPresetsDefaultsKey];
    if (![rawPresetValue isKindOfClass: [NSArray class]]) {
        return normalizedPresets;
    }

    for (id rawPreset in (NSArray*)rawPresetValue) {
        if (![rawPreset isKindOfClass: [NSDictionary class]]) {
            continue;
        }

        NSString* rawName = ((NSDictionary*)rawPreset)[@"name"];
        NSString* presetName = [rawName isKindOfClass: [NSString class]]
            ? [rawName stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]]
            : @"";
        if (presetName.length < 1 || [self presetNameConflictsWithBuiltinPresetName: presetName]) {
            continue;
        }

        NSString* lowercaseName = presetName.lowercaseString;
        if ([seenPresetNames containsObject: lowercaseName]) {
            continue;
        }

        NSArray<NSString*>* domains = [self normalizedDomainEntriesFromArray: ((NSDictionary*)rawPreset)[@"domains"]];
        if (domains.count < 1) {
            continue;
        }

        [seenPresetNames addObject: lowercaseName];
        [normalizedPresets addObject: @{
            @"name": presetName,
            @"domains": domains
        }];
    }

    return normalizedPresets;
}

- (void)persistCustomPresets:(NSArray<NSDictionary*>*)presets {
    [defaults_ setObject: presets ?: @[] forKey: kBlocklistCustomPresetsDefaultsKey];
}

- (NSArray<NSString*>*)normalizedRemovedBuiltinPresetIDs {
    NSMutableArray<NSString*>* normalizedRemovedIDs = [NSMutableArray array];
    NSMutableSet<NSString*>* seenRemovedIDs = [NSMutableSet set];
    NSMutableSet<NSString*>* validBuiltinIDs = [NSMutableSet set];
    for (NSDictionary* builtinPreset in [self builtinPresetDefinitions]) {
        NSString* builtinID = builtinPreset[@"id"];
        if ([builtinID isKindOfClass: [NSString class]]) {
            [validBuiltinIDs addObject: builtinID];
        }
    }

    id rawRemovedIDs = [defaults_ objectForKey: kBlocklistRemovedBuiltinPresetIDsDefaultsKey];
    if (![rawRemovedIDs isKindOfClass: [NSArray class]]) {
        return normalizedRemovedIDs;
    }

    for (id rawID in (NSArray*)rawRemovedIDs) {
        if (![rawID isKindOfClass: [NSString class]]) {
            continue;
        }

        NSString* builtinID = (NSString*)rawID;
        if (builtinID.length < 1
            || ![validBuiltinIDs containsObject: builtinID]
            || [seenRemovedIDs containsObject: builtinID]) {
            continue;
        }

        [seenRemovedIDs addObject: builtinID];
        [normalizedRemovedIDs addObject: builtinID];
    }

    return normalizedRemovedIDs;
}

- (void)persistRemovedBuiltinPresetIDs:(NSArray<NSString*>*)removedIDs {
    [defaults_ setObject: removedIDs ?: @[] forKey: kBlocklistRemovedBuiltinPresetIDsDefaultsKey];
}

- (NSInteger)customPresetIndexNamed:(NSString*)presetName presets:(NSArray<NSDictionary*>*)presets {
    NSString* normalizedName = [presetName stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalizedName.length < 1) {
        return NSNotFound;
    }

    for (NSUInteger i = 0; i < presets.count; i++) {
        NSString* existingName = presets[i][@"name"];
        if ([existingName isKindOfClass: [NSString class]]
            && [existingName caseInsensitiveCompare: normalizedName] == NSOrderedSame) {
            return (NSInteger)i;
        }
    }

    return NSNotFound;
}

- (void)rebuildImportMenu {
    if (importMenu_ == nil) {
        return;
    }

    // Pull-down menus use the first item as an inert placeholder.
    while (importMenu_.numberOfItems > 1) {
        [importMenu_ removeItemAtIndex: 1];
    }

    NSArray<NSDictionary*>* builtinPresets = [self builtinPresetDefinitions];
    NSSet<NSString*>* removedBuiltinIDs = [NSSet setWithArray: [self normalizedRemovedBuiltinPresetIDs]];
    NSArray<NSDictionary*>* customPresets = [self normalizedCustomPresets];

    for (NSDictionary* builtinPreset in builtinPresets) {
        NSString* builtinID = builtinPreset[@"id"];
        NSString* builtinTitle = builtinPreset[@"title"];
        NSArray<NSString*>* domains = builtinPreset[@"domains"];
        if (builtinID.length < 1 || builtinTitle.length < 1 || domains.count < 1 || [removedBuiltinIDs containsObject: builtinID]) {
            continue;
        }

        NSMenuItem* importItem = [[NSMenuItem alloc] initWithTitle: builtinTitle
                                                             action: @selector(importPresetFromMenu:)
                                                      keyEquivalent: @""];
        importItem.target = self;
        importItem.representedObject = @{
            kPresetImportTypeKey: kPresetImportTypeBuiltin,
            @"id": builtinID,
            @"domains": domains
        };
        [importMenu_ addItem: importItem];
    }

    for (NSDictionary* customPreset in customPresets) {
        NSString* presetName = customPreset[@"name"];
        NSArray<NSString*>* domains = customPreset[@"domains"];
        if (presetName.length < 1 || domains.count < 1) {
            continue;
        }

        NSMenuItem* importItem = [[NSMenuItem alloc] initWithTitle: presetName
                                                             action: @selector(importPresetFromMenu:)
                                                      keyEquivalent: @""];
        importItem.target = self;
        importItem.representedObject = @{
            kPresetImportTypeKey: kPresetImportTypeCustom,
            @"name": presetName,
            @"domains": domains
        };
        [importMenu_ addItem: importItem];
    }

    [importMenu_ addItem: [NSMenuItem separatorItem]];

    NSMenuItem* savePresetItem = [[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Save Current Blocklist as Preset…", @"Import menu action to save the current list as a reusable preset")
                                                             action: @selector(saveCurrentBlocklistAsPreset:)
                                                      keyEquivalent: @""];
    savePresetItem.target = self;
    savePresetItem.enabled = !self.readOnly;
    [importMenu_ addItem: savePresetItem];

    NSMenuItem* removePresetRootItem = [[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Remove Preset", @"Import menu entry for removing saved presets")
                                                                   action: nil
                                                            keyEquivalent: @""];
    NSMenu* removePresetSubmenu = [[NSMenu alloc] initWithTitle: removePresetRootItem.title];

    for (NSDictionary* builtinPreset in builtinPresets) {
        NSString* builtinID = builtinPreset[@"id"];
        NSString* builtinTitle = builtinPreset[@"title"];
        if (builtinID.length < 1 || builtinTitle.length < 1 || [removedBuiltinIDs containsObject: builtinID]) {
            continue;
        }

        NSMenuItem* removeItem = [[NSMenuItem alloc] initWithTitle: builtinTitle
                                                             action: @selector(removePresetFromMenu:)
                                                      keyEquivalent: @""];
        removeItem.target = self;
        removeItem.representedObject = @{
            kPresetImportTypeKey: kPresetImportTypeBuiltin,
            @"id": builtinID
        };
        [removePresetSubmenu addItem: removeItem];
    }

    for (NSDictionary* customPreset in customPresets) {
        NSString* presetName = customPreset[@"name"];
        if (presetName.length < 1) {
            continue;
        }

        NSMenuItem* removeItem = [[NSMenuItem alloc] initWithTitle: presetName
                                                             action: @selector(removePresetFromMenu:)
                                                      keyEquivalent: @""];
        removeItem.target = self;
        removeItem.representedObject = @{
            kPresetImportTypeKey: kPresetImportTypeCustom,
            @"name": presetName
        };
        [removePresetSubmenu addItem: removeItem];
    }

    if (removePresetSubmenu.numberOfItems > 0) {
        removePresetRootItem.submenu = removePresetSubmenu;
        removePresetRootItem.enabled = !self.readOnly;
    } else {
        removePresetRootItem.enabled = NO;
    }
    [importMenu_ addItem: removePresetRootItem];

    NSMenuItem* resetDefaultsItem = [[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Reset Default Presets", @"Import menu action that restores built-in presets")
                                                                action: @selector(resetDefaultPresets:)
                                                         keyEquivalent: @""];
    resetDefaultsItem.target = self;
    resetDefaultsItem.enabled = !self.readOnly && removedBuiltinIDs.count > 0;
    [importMenu_ addItem: resetDefaultsItem];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == importMenu_) {
        [self rebuildImportMenu];
    }
}

- (void)awakeFromNib  {
    NSInteger indexToSelect = [defaults_ boolForKey: @"BlockAsWhitelist"] ? 1 : 0;
    [allowlistRadioMatrix_ selectCellAtRow: indexToSelect column: 0];

    if (importMenu_ != nil) {
        importMenu_.delegate = self;
        [self rebuildImportMenu];
    }

    [self updateWindowTitle];
}

- (void)refreshDomainList {
    // end any current editing to trigger saving blocklist
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshDomainList];
        });
        return;
    }
    
    [[self window] makeFirstResponder: self];
    domainList_ = [[defaults_ arrayForKey: @"Blocklist"] mutableCopy];
    [domainListTableView_ reloadData];
}

- (void)showWindow:(id)sender {
	[[self window] makeKeyAndOrderFront: self];

    [self rebuildImportMenu];

	if ([domainList_ count] == 0 && !self.readOnly) {
		[self addDomain: self];
	}

    [self updateWindowTitle];
}

- (IBAction)addDomain:(id)sender
{
	[domainList_ addObject:@""];
    [defaults_ setValue: domainList_ forKey: @"Blocklist"];
	[domainListTableView_ reloadData];
	NSIndexSet* rowIndex = [NSIndexSet indexSetWithIndex: [domainList_ count] - 1];
	[domainListTableView_ selectRowIndexes: rowIndex
					  byExtendingSelection: NO];
	[domainListTableView_ editColumn: 0 row:((NSInteger)[domainList_ count] - 1)
						   withEvent:nil
							  select:YES];
}

- (IBAction)removeDomain:(id)sender
{
	NSIndexSet* selected = [domainListTableView_ selectedRowIndexes];
	[domainListTableView_ abortEditing];

	// This isn't the most efficient way to do this, but the code is much cleaner
	// than other methods and the domain blocklist will probably never be large
	// enough for it to be an issue.
	NSUInteger index = [selected firstIndex];
	NSUInteger shift = 0;
	while (index != NSNotFound) {
		if ((index - shift) >= [domainList_ count])
			break;
		[domainList_ removeObjectAtIndex: index - shift];
		shift++;
		index = [selected indexGreaterThanIndex: index];
	}

    [defaults_ setValue: domainList_ forKey: @"Blocklist"];
	[domainListTableView_ reloadData];

	[[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
														object: self];
}

- (NSUInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
	return [domainList_ count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if (rowIndex < 0 || (NSUInteger)rowIndex + 1 > [domainList_ count]) return nil;
	return domainList_[(NSUInteger)rowIndex];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    return !self.readOnly;
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
	NSInteger editedRow = [domainListTableView_ editedRow];
	NSString* editedString = [[[[note userInfo] objectForKey: @"NSFieldEditor"] textStorage] string];
	editedString = [editedString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // sometimes we get an edited row index that's out-of-bounds for weird reasons,
    // e.g. if we're editing an empty row and then start a block, the data will get reloaded
    // and the row will not exist by the time this method gets called. We can ignore in that case
	if (editedRow >= 0 && editedRow < domainListTableView_.numberOfRows && !editedString.length) {
		NSIndexSet* indexSet = [NSIndexSet indexSetWithIndex: (NSUInteger)editedRow];
		[domainListTableView_ beginUpdates];
		[domainListTableView_ removeRowsAtIndexes: indexSet withAnimation: NSTableViewAnimationSlideUp];
		[domainList_ removeObjectAtIndex: (NSUInteger)editedRow];
        [defaults_ setValue: domainList_ forKey: @"Blocklist"];
		[domainListTableView_ reloadData];
		[domainListTableView_ endUpdates];
        [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
        object: self];
		return;
	}
}

- (void)tableView:(NSTableView *)aTableView
   setObjectValue:(NSString*)newString
   forTableColumn:(NSTableColumn *)aTableColumn
			  row:(NSInteger)rowIndex {
	if (rowIndex < 0 || (NSUInteger)rowIndex + 1 > [domainList_ count]) {
		return;
	}
    NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: newString];
    
    for (NSUInteger i = 0; i < cleanedEntries.count; i++) {
        NSString* entry = cleanedEntries[i];
        if (i == 0) {
            domainList_[(NSUInteger)rowIndex] = entry;
        } else {
            [domainList_ insertObject: entry atIndex: (NSUInteger)rowIndex + i];
        }
    }
    
    [defaults_ setValue: domainList_ forKey: @"Blocklist"];
    [domainListTableView_ reloadData];
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
    object: self];
}

- (void)tableView:(NSTableView *)tableView
  willDisplayCell:(id)cell
   forTableColumn:(NSTableColumn *)tableColumn
			  row:(int)row {
	// this method is really inefficient. rewrite/optimize later.

	// Initialize the cell's text color to black
	[cell setTextColor: NSColor.textColor];
	NSString* str = [[cell title] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if([str isEqual: @""]) return;
	if([defaults_ boolForKey: @"HighlightInvalidHosts"]) {
		// Validate the value as either an IP or a hostname.  In case of failure,
		// we'll make its text color red.

		int maskLength = -1;
		int portNum = -1;

		NSArray* splitString = [str componentsSeparatedByString: @"/"];

		str = [splitString[0] lowercaseString];

		NSString* stringToSearchForPort = str;

		if([splitString count] >= 2) {
			maskLength = [splitString[1] intValue];
			// If the int value is 0, we couldn't find a valid integer representation
			// in the split off string
			if(maskLength == 0)
				maskLength = -1;

			stringToSearchForPort = splitString[1];
		}

		splitString = [stringToSearchForPort componentsSeparatedByString: @":"];

		if(stringToSearchForPort == str) {
			str = splitString[0];
		}

		if([splitString count] >= 2) {
			portNum = [splitString[1] intValue];
			// If the int value is 0, we couldn't find a valid integer representation
			// in the split off string
			if(portNum == 0)
				portNum = -1;
		}

		BOOL isIP;

		NSString* ipValidationRegex = @"^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$";
		NSPredicate *ipRegexTester = [NSPredicate
									  predicateWithFormat:@"SELF MATCHES %@",
									  ipValidationRegex];
		isIP = [ipRegexTester evaluateWithObject: str];

		if(!isIP) {
			NSString* hostnameValidationRegex = @"^([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,6}$";
			NSPredicate *hostnameRegexTester = [NSPredicate
												predicateWithFormat:@"SELF MATCHES %@",
												hostnameValidationRegex
												];

			if(![hostnameRegexTester evaluateWithObject: str] && ![str isEqualToString: @"*"] && ![str isEqualToString: @""]) {
				[cell setTextColor: NSColor.redColor];
				return;
			}
		}

		// We shouldn't have a mask length if it's not an IP, fail
		if(!isIP && maskLength != -1) {
			[cell setTextColor: NSColor.redColor];
			return;
		}

		if(([str isEqualToString: @"*"] || [str isEqualToString: @""]) && portNum == -1) {
			[cell setTextColor: NSColor.redColor];
			return;
		}

		[cell setTextColor: NSColor.textColor];
	}
}

- (IBAction)allowlistOptionChanged:(NSMatrix*)sender {
    switch (sender.selectedRow) {
        case 0:
            [defaults_ setBool: NO forKey: @"BlockAsWhitelist"];
            break;
        case 1:
            [self showAllowlistWarning];
            [defaults_ setBool: YES forKey: @"BlockAsWhitelist"];
            break;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
                                                        object: self];
    
    // update UI to reflect appropriate list type
    AppController* controller = (AppController *)[NSApp delegate];
    [controller refreshUserInterface];
    [self updateWindowTitle];
}

- (void)showAllowlistWarning {
    if(![defaults_ boolForKey: @"WhitelistAlertSuppress"]) {        
        NSAlert* alert = [NSAlert new];
        alert.messageText = NSLocalizedString(@"Are you sure you want an allowlist block?", @"Allowlist block confirmation prompt");
        [alert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
        alert.informativeText = NSLocalizedString(@"An allowlist block means that everything on the internet BESIDES your specified list will be blocked.  This includes the web, email, SSH, and anything else your computer accesses via the internet.  This can cause unexpected behavior. If a web site requires resources such as images or scripts from a site that is not on your allowlist, the site may not work properly.", @"allowlist block explanation");
        alert.showsSuppressionButton = YES;

        [alert runModal];

        if (alert.suppressionButton.state == NSOnState) {
            [defaults_ setBool: YES forKey: @"WhitelistAlertSuppress"];
        }
    }
}

- (void)updateWindowTitle {
    NSString* listType = [defaults_ boolForKey: @"BlockAsWhitelist"] ? @"Allowlist" : @"Blocklist";
    self.window.title = NSLocalizedString(([NSString stringWithFormat: @"Domain %@", listType]), @"Domain list window title");
}

- (void)addHostArray:(NSArray*)arr {
	for(NSUInteger i = 0; i < [arr count]; i++) {
		// Check for dupes
		if(![domainList_ containsObject: arr[i]])
			[domainList_ addObject: arr[i]];
	}
	[defaults_ setValue: domainList_ forKey: @"Blocklist"];
	[domainListTableView_ reloadData];
	[[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
															object: self];
}

- (IBAction)importPresetFromMenu:(id)sender {
    if (self.readOnly || ![sender isKindOfClass: [NSMenuItem class]]) {
        return;
    }

    NSDictionary* representedObject = ((NSMenuItem*)sender).representedObject;
    if (![representedObject isKindOfClass: [NSDictionary class]]) {
        return;
    }

    NSArray<NSString*>* domains = [self normalizedDomainEntriesFromArray: representedObject[@"domains"]];
    if (domains.count < 1) {
        return;
    }

    [self addHostArray: domains];
}

- (IBAction)saveCurrentBlocklistAsPreset:(id)sender {
    (void)sender;
    if (self.readOnly) {
        return;
    }

    NSArray<NSString*>* domains = [self normalizedDomainEntriesFromArray: domainList_];
    if (domains.count < 1) {
        NSAlert* emptyListAlert = [NSAlert new];
        emptyListAlert.messageText = NSLocalizedString(@"Can't Save Preset", @"Save preset failure title for empty blocklist");
        emptyListAlert.informativeText = NSLocalizedString(@"Add at least one domain before saving a preset.", @"Save preset failure explanation for empty blocklist");
        [emptyListAlert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
        [emptyListAlert runModal];
        return;
    }

    NSAlert* namePromptAlert = [NSAlert new];
    namePromptAlert.messageText = NSLocalizedString(@"Save Blocklist Preset", @"Save preset title");
    namePromptAlert.informativeText = NSLocalizedString(@"Enter a name for this preset.", @"Save preset prompt message");
    [namePromptAlert addButtonWithTitle: NSLocalizedString(@"Save", @"Save button title")];
    [namePromptAlert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Cancel button title")];

    NSTextField* nameField = [[NSTextField alloc] initWithFrame: NSMakeRect(0.0, 0.0, 280.0, 24.0)];
    nameField.placeholderString = NSLocalizedString(@"Preset Name", @"Placeholder for preset name text field");
    namePromptAlert.accessoryView = nameField;

    if ([namePromptAlert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    NSString* presetName = [nameField.stringValue stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (presetName.length < 1) {
        NSAlert* invalidNameAlert = [NSAlert new];
        invalidNameAlert.messageText = NSLocalizedString(@"Invalid Preset Name", @"Preset name validation error title");
        invalidNameAlert.informativeText = NSLocalizedString(@"Preset name cannot be empty.", @"Preset name validation error for empty names");
        [invalidNameAlert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
        [invalidNameAlert runModal];
        return;
    }

    if ([self presetNameConflictsWithBuiltinPresetName: presetName]) {
        NSAlert* conflictAlert = [NSAlert new];
        conflictAlert.messageText = NSLocalizedString(@"Preset Name Unavailable", @"Preset name validation error title");
        conflictAlert.informativeText = NSLocalizedString(@"That name is reserved by a default preset. Choose a different name.", @"Preset name conflict message for built-in presets");
        [conflictAlert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
        [conflictAlert runModal];
        return;
    }

    NSMutableArray<NSDictionary*>* customPresets = [[self normalizedCustomPresets] mutableCopy];
    NSInteger existingPresetIndex = [self customPresetIndexNamed: presetName presets: customPresets];
    NSDictionary* updatedPreset = @{
        @"name": presetName,
        @"domains": domains
    };

    if (existingPresetIndex != NSNotFound) {
        NSAlert* overwriteAlert = [NSAlert new];
        overwriteAlert.messageText = NSLocalizedString(@"Overwrite Preset?", @"Overwrite existing preset confirmation title");
        overwriteAlert.informativeText = [NSString stringWithFormat: NSLocalizedString(@"A preset named \"%@\" already exists. Do you want to overwrite it?", @"Overwrite preset confirmation message"), presetName];
        [overwriteAlert addButtonWithTitle: NSLocalizedString(@"Overwrite", @"Button title to overwrite an existing preset")];
        [overwriteAlert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Cancel button title")];
        if ([overwriteAlert runModal] != NSAlertFirstButtonReturn) {
            return;
        }

        customPresets[(NSUInteger)existingPresetIndex] = updatedPreset;
    } else {
        [customPresets addObject: updatedPreset];
    }

    [self persistCustomPresets: customPresets];
    [self rebuildImportMenu];
}

- (IBAction)removePresetFromMenu:(id)sender {
    if (self.readOnly || ![sender isKindOfClass: [NSMenuItem class]]) {
        return;
    }

    NSMenuItem* selectedItem = (NSMenuItem*)sender;
    NSDictionary* representedObject = selectedItem.representedObject;
    if (![representedObject isKindOfClass: [NSDictionary class]]) {
        return;
    }

    NSAlert* removeAlert = [NSAlert new];
    removeAlert.messageText = NSLocalizedString(@"Remove Preset?", @"Remove preset confirmation title");
    removeAlert.informativeText = [NSString stringWithFormat: NSLocalizedString(@"Are you sure you want to remove \"%@\"?", @"Remove preset confirmation message"), selectedItem.title];
    [removeAlert addButtonWithTitle: NSLocalizedString(@"Remove", @"Button title to remove a preset")];
    [removeAlert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Cancel button title")];
    if ([removeAlert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    NSString* presetType = representedObject[kPresetImportTypeKey];
    if ([presetType isEqualToString: kPresetImportTypeBuiltin]) {
        NSString* builtinID = representedObject[@"id"];
        if (![builtinID isKindOfClass: [NSString class]] || builtinID.length < 1) {
            return;
        }

        NSMutableArray<NSString*>* removedBuiltinIDs = [[self normalizedRemovedBuiltinPresetIDs] mutableCopy];
        if (![removedBuiltinIDs containsObject: builtinID]) {
            [removedBuiltinIDs addObject: builtinID];
            [self persistRemovedBuiltinPresetIDs: removedBuiltinIDs];
        }
    } else if ([presetType isEqualToString: kPresetImportTypeCustom]) {
        NSString* presetName = representedObject[@"name"];
        if (![presetName isKindOfClass: [NSString class]] || presetName.length < 1) {
            return;
        }

        NSMutableArray<NSDictionary*>* customPresets = [[self normalizedCustomPresets] mutableCopy];
        NSInteger presetIndex = [self customPresetIndexNamed: presetName presets: customPresets];
        if (presetIndex != NSNotFound) {
            [customPresets removeObjectAtIndex: (NSUInteger)presetIndex];
            [self persistCustomPresets: customPresets];
        }
    }

    [self rebuildImportMenu];
}

- (IBAction)resetDefaultPresets:(id)sender {
    (void)sender;
    if (self.readOnly) {
        return;
    }

    NSAlert* resetAlert = [NSAlert new];
    resetAlert.messageText = NSLocalizedString(@"Reset Default Presets?", @"Reset default presets confirmation title");
    resetAlert.informativeText = NSLocalizedString(@"This will restore all built-in presets to the Import menu. Your custom presets will not be changed.", @"Reset default presets confirmation message");
    [resetAlert addButtonWithTitle: NSLocalizedString(@"Reset", @"Button title to confirm reset of default presets")];
    [resetAlert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Cancel button title")];
    if ([resetAlert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    [self persistRemovedBuiltinPresetIDs: @[]];
    [self rebuildImportMenu];
}

- (IBAction)importCommonDistractingWebsites:(id)sender {
	[self addHostArray: [HostImporter commonDistractingWebsites]];
}
- (IBAction)importNewsAndPublications:(id)sender {
	[self addHostArray: [HostImporter newsAndPublications]];
}
- (IBAction)importIncomingMailServersFromThunderbird:(id)sender {
	[self addHostArray: [HostImporter incomingMailHostnamesFromThunderbird]];
}
- (IBAction)importOutgoingMailServersFromThunderbird:(id)sender {
	[self addHostArray: [HostImporter outgoingMailHostnamesFromThunderbird]];
}
- (IBAction)importIncomingMailServersFromMail:(id)sender {
	[self addHostArray: [HostImporter incomingMailHostnamesFromMail]];
}
- (IBAction)importOutgoingMailServersFromMail:(id)sender {
	[self addHostArray: [HostImporter outgoingMailHostnamesFromMail]];
}
- (IBAction)importIncomingMailServersFromMailMate:(id)sender {
	[self addHostArray: [HostImporter incomingMailHostnamesFromMailMate]];
}
- (IBAction)importOutgoingMailServersFromMailMate:(id)sender {
	[self addHostArray: [HostImporter outgoingMailHostnamesFromMailMate]];
}

@end
