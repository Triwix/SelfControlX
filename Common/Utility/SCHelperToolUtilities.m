//
//  SCHelperToolUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import "SCHelperToolUtilities.h"
#import "BlockManager.h"
#import "HostFileBlockerSet.h"
#import <ServiceManagement/ServiceManagement.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

@implementation SCHelperToolUtilities

+ (BOOL)updateImmutableFlagForPath:(NSString*)path immutable:(BOOL)immutable {
    struct stat fileStat;
    if (lstat(path.fileSystemRepresentation, &fileStat) != 0) {
        // The file may not exist in this environment; skip quietly.
        return NO;
    }
    
    const uint32_t immutableMask = (uint32_t)UF_IMMUTABLE;
    uint32_t desiredFlags;
    if (immutable) {
        desiredFlags = fileStat.st_flags | immutableMask;
    } else {
        desiredFlags = fileStat.st_flags & (~immutableMask);
    }
    
    if (desiredFlags == fileStat.st_flags) {
        return YES;
    }
    
    if (chflags(path.fileSystemRepresentation, desiredFlags) != 0) {
        NSLog(@"WARNING: Failed to %@ immutable flag for %@ (%s)",
              immutable ? @"set" : @"clear",
              path,
              strerror(errno));
        return NO;
    }
    
    return YES;
}

+ (void)setHostsFilesImmutable {
    if (geteuid() != 0) {
        return;
    }
    
    HostFileBlockerSet* blockerSet = [[HostFileBlockerSet alloc] init];
    for (HostFileBlocker* blocker in blockerSet.blockers) {
        [self updateImmutableFlagForPath: blocker.hostFilePath immutable: YES];
    }
}

+ (void)clearHostsFilesImmutable {
    if (geteuid() != 0) {
        return;
    }
    
    HostFileBlockerSet* blockerSet = [[HostFileBlockerSet alloc] init];
    for (HostFileBlocker* blocker in blockerSet.blockers) {
        [self updateImmutableFlagForPath: blocker.hostFilePath immutable: NO];
    }
}

+ (void)installBlockRulesFromSettings {
    SCSettings* settings = [SCSettings sharedSettings];
    BOOL shouldEvaluateCommonSubdomains = [settings boolForKey: @"EvaluateCommonSubdomains"];
    BOOL allowLocalNetworks = [settings boolForKey: @"AllowLocalNetworks"];
    BOOL includeLinkedDomains = [settings boolForKey: @"IncludeLinkedDomains"];

    // get value for ActiveBlockAsWhitelist
    BOOL blockAsAllowlist = [settings boolForKey: @"ActiveBlockAsWhitelist"];
    BOOL blockBypassesEnabled = [settings boolForKey: @"BlockBypassesEnabled"];
    if (!blockAsAllowlist && blockBypassesEnabled) {
        [SCHelperToolUtilities clearHostsFilesImmutable];
    }

    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist: blockAsAllowlist allowLocal: allowLocalNetworks includeCommonSubdomains: shouldEvaluateCommonSubdomains includeLinkedDomains: includeLinkedDomains];

    NSLog(@"About to run BlockManager commands");
    
    [blockManager prepareToAddBlock];
    [blockManager addBlockEntriesFromStrings: [settings valueForKey: @"ActiveBlocklist"]];
    [blockManager finalizeBlock];
    if (!blockAsAllowlist && blockBypassesEnabled) {
        [SCHelperToolUtilities setHostsFilesImmutable];
    }

}

+ (void)unloadDaemonJob {
    NSLog(@"Unloading SelfControl daemon...");
    [SCSentry addBreadcrumb: @"Daemon about to unload" category: @"daemon"];
    SCSettings* settings = [SCSettings sharedSettings];

    // we're about to unload the launchd job
    // this will kill this process, so we have to make sure
    // all settings are synced before we unload
    NSError* syncErr = [settings syncSettingsAndWait: 5.0];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ before unloading daemon job", syncErr);
        [SCSentry captureError: syncErr];
    }
    
    // uh-oh, looks like it's 5 seconds later and the sync hasn't completed yet. Bad news.
    NSArray<NSString*>* daemonLabelsToRemove = @[
        @"org.eyebeam.selfcontrolxxd",
        @"org.eyebeam.selfcontrolxd",
        @"org.eyebeam.selfcontrold"
    ];
    for (NSString* daemonLabel in daemonLabelsToRemove) {
        CFErrorRef cfError = NULL;
        // this should block until the process is dead, so we should never get to the other side if it's successful
        SILENCE_OSX10_10_DEPRECATION(
        SMJobRemove(kSMDomainSystemLaunchd, (__bridge CFStringRef)daemonLabel, NULL, YES, &cfError);
                                     );
        if (cfError) {
            NSLog(@"Failed to remove selfcontrold daemon (%@) with error %@", daemonLabel, cfError);
            CFRelease(cfError);
        }
    }
}

+ (void)clearCachesIfRequested {
    SCSettings* settings = [SCSettings sharedSettings];
    if(![settings boolForKey: @"ClearCaches"]) {
        return;
    }
    
    NSError* err = [SCHelperToolUtilities clearBrowserCaches];
    if (err) {
        NSLog(@"WARNING: Error clearing browser caches: %@", err);
        [SCSentry captureError: err];
    }

    [SCHelperToolUtilities clearOSDNSCache];
}

+ (NSError*)clearBrowserCaches {
    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSError* homeDirErr = nil;
    NSArray<NSURL *>* homeDirectoryURLs = [SCMiscUtilities allUserHomeDirectoryURLs: &homeDirErr];
    if (homeDirectoryURLs == nil) return homeDirErr;
    
    NSArray<NSString*>* cacheDirPathComponents = @[
        // chrome
        @"/Library/Caches/Google/Chrome/Default",
        @"/Library/Caches/Google/Chrome/com.google.Chrome",
        
        // firefox
        @"/Library/Caches/Firefox/Profiles",
        
        // safari
        @"/Library/Caches/com.apple.Safari",
        @"/Library/Containers/com.apple.Safari/Data/Library/Caches" // this one seems to fail due to permissions issues, but not sure how to fix
    ];
    
    
    NSMutableArray<NSURL*>* cacheDirURLs = [NSMutableArray arrayWithCapacity: cacheDirPathComponents.count * homeDirectoryURLs.count];
    for (NSURL* homeDirURL in homeDirectoryURLs) {
        for (NSString* cacheDirPathComponent in cacheDirPathComponents) {
            [cacheDirURLs addObject: [homeDirURL URLByAppendingPathComponent: cacheDirPathComponent isDirectory: YES]];
        }
    }
    
    for (NSURL* cacheDirURL in cacheDirURLs) {
        NSLog(@"Clearing browser cache folder %@", cacheDirURL);
        // removeItemAtURL will return errors if the file doesn't exist
        // so we don't track the errors - best effort is OK
        [fileManager removeItemAtURL: cacheDirURL error: nil];
    }
    
    return nil;
}

+ (void)clearOSDNSCache {
    // no error checks - if it works it works!
    NSTask* flushDsCacheUtil = [[NSTask alloc] init];
    [flushDsCacheUtil setLaunchPath: @"/usr/bin/dscacheutil"];
    [flushDsCacheUtil setArguments: @[@"-flushcache"]];
    [flushDsCacheUtil launch];
    [flushDsCacheUtil waitUntilExit];
    
    NSTask* killResponder = [[NSTask alloc] init];
    [killResponder setLaunchPath: @"/usr/bin/killall"];
    [killResponder setArguments: @[@"-HUP", @"mDNSResponder"]];
    [killResponder launch];
    [killResponder waitUntilExit];
    
    NSTask* killResponderHelper = [[NSTask alloc] init];
    [killResponderHelper setLaunchPath: @"/usr/bin/killall"];
    [killResponderHelper setArguments: @[@"mDNSResponderHelper"]];
    [killResponderHelper launch];
    [killResponderHelper waitUntilExit];
    
    NSLog(@"Cleared OS DNS caches");
}

+ (void)playBlockEndSound {
    SCSettings* settings = [SCSettings sharedSettings];
    if([settings boolForKey: @"BlockSoundShouldPlay"]) {
        // Map the tags used in interface builder to the sound
        NSArray* systemSoundNames = SCConstants.systemSoundNames;
        NSSound* alertSound = [NSSound soundNamed: systemSoundNames[(NSUInteger)[[settings valueForKey: @"BlockSound"] intValue]]];
        if(!alertSound)
            NSLog(@"WARNING: Alert sound not found.");
        else {
            [alertSound play];
        }
    }
}

+ (void)removeBlock {
    [SCBlockUtilities removeBlockFromSettings];
    [SCHelperToolUtilities clearHostsFilesImmutable];
    [[BlockManager new] clearBlock];
    
    [SCHelperToolUtilities clearCachesIfRequested];

    // play a sound letting
    [SCHelperToolUtilities playBlockEndSound];
        
    // always synchronize settings ASAP after removing a block to let everybody else know
    // and wait until they're synced before we send the configuration change notification
    // so the app has no chance of reading the data before we update it
    NSError* syncErr = [[SCSettings sharedSettings] syncSettingsAndWait: 5.0];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after removing block", syncErr);
        [SCSentry captureError: syncErr];
    }

    // let the main app know things have changed so it can update the UI!
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    NSLog(@"INFO: Block cleared.");
}

+ (void)sendConfigurationChangedNotification {
    // if you don't include the NSNotificationPostToAllSessions option,
    // it will not deliver when run by launchd (root) to the main app being run by the user
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
                                                                   object: nil
                                                                 userInfo: nil
                                                                  options: NSNotificationDeliverImmediately | NSNotificationPostToAllSessions];
}

@end
