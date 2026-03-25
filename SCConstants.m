//
//  SCConstants.m
//  SelfControl
//
//  Created by Charlie Stigler on 3/31/19.
//

#import "SCConstants.h"
#import "SCMiscUtilities.h"

OSStatus const AUTH_CANCELLED_STATUS = -60006;

@implementation SCConstants

+  (NSArray<NSString*>*)systemSoundNames {
    static NSArray<NSString*>* soundsArr = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        soundsArr = @[@"Basso",
                      @"Blow",
                      @"Bottle",
                      @"Frog",
                      @"Funk",
                      @"Glass",
                      @"Hero",
                      @"Morse",
                      @"Ping",
                      @"Pop",
                      @"Purr",
                      @"Sosumi",
                      @"Submarine",
                      @"Tink"];
    });
    
    return soundsArr;
}

+ (NSDictionary<NSString*, id>*)defaultUserDefaults {
    static NSDictionary<NSString*, id>* defaultDefaultsDict = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultDefaultsDict = @{
            @"Blocklist": @[],
            @"BlocklistCustomPresets": @[],
            @"BlocklistRemovedBuiltinPresetIDs": @[],
            @"BlockAsWhitelist": @NO,
            @"HighlightInvalidHosts": @YES,
            @"VerifyInternetConnection": @YES,
            @"TimerWindowFloats": @NO,
            @"BadgeApplicationIcon": @YES,
            @"BlockDuration": @1,
            @"MaxBlockLength": @1440,
            @"BlockDurationSliderIntervalMinutes": @1,
            @"BlockBypassesEnabled": @YES,
            @"TrustedTimeSourceURLs": @[
                @"https://www.google.com",
                @"https://www.apple.com",
                @"https://www.microsoft.com",
                @"https://www.cloudflare.com",
                @"https://www.amazon.com",
                @"https://www.fastly.com"
            ],
            @"TrustedTimeConsensusRequiredCount": @2,
            @"TrustedTimeConsensusMaxSkewSeconds": @10,
            @"EnableMenuBarIcon": @NO,
            @"MenuBarIconText": @"\u30c4",
            @"MenuBarQuickBlockDurationsMinutes": @"30,60,120,180,240",
            @"WhitelistAlertSuppress": @NO,
            @"GetStartedShown": @NO,
            @"EvaluateCommonSubdomains": @YES,
            @"IncludeLinkedDomains": @YES,
            @"BlockSoundShouldPlay": @NO,
            @"BlockSound": @5,
            @"ClearCaches": @YES,
            @"AllowLocalNetworks": @YES,
            // If the user has checked "send crash reports to third-party developers",
            // default telemetry on; otherwise keep it off until they opt in.
            @"EnableErrorReporting": @([SCMiscUtilities systemThirdPartyCrashReportingEnabled]),
            @"ErrorReportingPromptDismissed": @NO,
            @"SuppressLongBlockWarning": @NO,
            @"SuppressRestartFirefoxWarning": @NO,
            @"FirstBlockStarted": @NO,
            
            @"V4MigrationComplete": @NO
        };
    });
    
    return defaultDefaultsDict;
}

@end
