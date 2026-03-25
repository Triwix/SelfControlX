//
//  SCBlockUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import "SCBlockUtilities.h"
#import "HostFileBlocker.h"
#import "PacketFilter.h"

static NSString* const kTrustedTimeSettingEnforced = @"TrustedTimeEnforced";
static NSString* const kTrustedBlockEndDateSetting = @"TrustedBlockEndDate";
static NSString* const kTrustedTimeLastFetchDateSetting = @"TrustedTimeLastFetchDate";
static NSString* const kTrustedTimeLastFetchUptimeSetting = @"TrustedTimeLastFetchUptime";
static NSString* const kBlockEndDateSetting = @"BlockEndDate";

static NSDate* SCNormalizedModernBlockEndDate(SCSettings* settings) {
    id rawValue = [settings valueForKey: kBlockEndDateSetting];
    if ([rawValue isKindOfClass: [NSDate class]]) {
        return (NSDate*)rawValue;
    }
    return [NSDate distantPast];
}

@implementation SCBlockUtilities

+ (BOOL)anyBlockIsRunning {
    BOOL blockIsRunning = [SCBlockUtilities modernBlockIsRunning] || [SCBlockUtilities legacyBlockIsRunning];

    return blockIsRunning;
}

+ (BOOL)modernBlockIsRunning {
    SCSettings* settings = [SCSettings sharedSettings];
    
    return [settings boolForKey: @"BlockIsRunning"];
}

+ (BOOL)modernBlockUsesTrustedTime {
    SCSettings* settings = [SCSettings sharedSettings];
    return [SCBlockUtilities modernBlockIsRunning] && [settings boolForKey: kTrustedTimeSettingEnforced];
}

+ (BOOL)legacyBlockIsRunning {
    // first see if there's a legacy settings file from v3.x
    // which could be in any user's home folder
    NSError* homeDirErr = nil;
    NSArray<NSURL *>* homeDirectoryURLs = [SCMiscUtilities allUserHomeDirectoryURLs: &homeDirErr];
    if (homeDirectoryURLs != nil) {
        for (NSURL* homeDirURL in homeDirectoryURLs) {
            NSString* relativeSettingsPath = [NSString stringWithFormat: @"/Library/Preferences/%@", SCSettings.settingsFileName];
            NSURL* settingsFileURL = [homeDirURL URLByAppendingPathComponent: relativeSettingsPath isDirectory: NO];
            
            if ([SCMigrationUtilities legacyBlockIsRunningInSettingsFile: settingsFileURL]) {
                return YES;
            }
        }
    }

    // nope? OK, how about a lock file from pre-3.0?
    if ([SCMigrationUtilities legacyLockFileExists]) {
        return YES;
    }
    
    // we don't check defaults anymore, though pre-3.0 blocks did
    // have data stored there. That should be covered by the lockfile anyway
    
    return NO;
}

// returns YES if the block should have expired active based on the specified end time (i.e. the end time is in the past), or NO otherwise
+ (BOOL)currentBlockIsExpired {
    // the block should be running if the end date hasn't arrived yet
    SCSettings* settings = [SCSettings sharedSettings];
    NSDate* blockEndDate = SCNormalizedModernBlockEndDate(settings);
    if ([blockEndDate timeIntervalSinceNow] > 0) {
        return NO;
    } else {
        return YES;
    }
}

+ (NSTimeInterval)currentBlockRemainingSecondsForDisplay {
    SCSettings* settings = [SCSettings sharedSettings];
    if ([SCBlockUtilities modernBlockUsesTrustedTime]) {
        NSDate* trustedEndDate = [settings valueForKey: kTrustedBlockEndDateSetting];
        NSDate* trustedTimeLastFetchDate = [settings valueForKey: kTrustedTimeLastFetchDateSetting];
        NSNumber* trustedTimeLastFetchUptime = [settings valueForKey: kTrustedTimeLastFetchUptimeSetting];
        if ([trustedEndDate isKindOfClass: [NSDate class]]
            && [trustedTimeLastFetchDate isKindOfClass: [NSDate class]]
            && [trustedTimeLastFetchUptime isKindOfClass: [NSNumber class]]) {
            NSTimeInterval uptimeDelta = [NSProcessInfo processInfo].systemUptime - trustedTimeLastFetchUptime.doubleValue;
            if (uptimeDelta < 0) {
                uptimeDelta = 0;
            }
            NSDate* estimatedTrustedNow = [trustedTimeLastFetchDate dateByAddingTimeInterval: uptimeDelta];
            return [trustedEndDate timeIntervalSinceDate: estimatedTrustedNow];
        }
    }
    
    return [SCNormalizedModernBlockEndDate(settings) timeIntervalSinceNow];
}

+ (BOOL)blockRulesFoundOnSystem {
    return [PacketFilter blockFoundInPF] || [HostFileBlocker blockFoundInHostsFile];
}

+ (void) removeBlockFromSettings {
    SCSettings* settings = [SCSettings sharedSettings];
    [settings setValue: @NO forKey: @"BlockIsRunning"];
    [settings setValue: nil forKey: @"BlockEndDate"];
    [settings setValue: nil forKey: @"ActiveBlocklist"];
    [settings setValue: nil forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: nil forKey: @"BlockBypassesEnabled"];
    [settings setValue: nil forKey: @"MaxBlockLengthMinutes"];
    [settings setValue: nil forKey: @"TrustedTimeSourceURLs"];
    [settings setValue: nil forKey: @"TrustedTimeConsensusRequiredCount"];
    [settings setValue: nil forKey: @"TrustedTimeConsensusMaxSkewSeconds"];
    [settings setValue: nil forKey: kTrustedTimeSettingEnforced];
    [settings setValue: nil forKey: kTrustedBlockEndDateSetting];
    [settings setValue: nil forKey: kTrustedTimeLastFetchDateSetting];
    [settings setValue: nil forKey: kTrustedTimeLastFetchUptimeSetting];
}

@end
