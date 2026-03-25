//
//  SCSentry.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/15/21.
//

#import "SCSentry.h"
#import "SCSettings.h"

#ifndef TESTING
#import <Sentry/Sentry.h>
#endif

@interface SCSentry ()

+ (NSString*)configuredDSN;
+ (BOOL)errorReportingEnabled;
+ (BOOL)showErrorReportingPromptIfNeeded;
+ (void)updateDefaultsContext;

@end

@implementation SCSentry

+ (void)startSentry:(NSString*)componentId {
#ifndef TESTING
    NSString* dsn = [self configuredDSN];
    if (dsn.length < 1) {
        NSLog(@"Sentry DSN missing; telemetry disabled for %@", componentId);
        return;
    }
    
    [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
        options.dsn = dsn;
        options.releaseName = [NSString stringWithFormat: @"%@%@", componentId, SELFCONTROL_VERSION_STRING];
        options.enableAutoSessionTracking = NO;
        
        // Make sure no data leaves the device if error reporting isn't enabled.
        options.beforeSend = ^SentryEvent * _Nullable(SentryEvent * _Nonnull event) {
            if ([SCSentry errorReportingEnabled]) {
                return event;
            } else {
                return NULL;
            }
        };
    }];
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setTagValue: [[NSLocale currentLocale] localeIdentifier] forKey: @"localeId"];
    }];
#endif
}

+ (void)addBreadcrumb:(NSString*)message category:(NSString*)category {
#ifndef TESTING
    SentryBreadcrumb* crumb = [[SentryBreadcrumb alloc] init];
    crumb.level = kSentryLevelInfo;
    crumb.category = category;
    crumb.message = message;
    [SentrySDK addBreadcrumb: crumb];
#endif
}

+ (void)captureError:(NSError*)error {
    if (![SCSentry errorReportingEnabled]) {
        // If we're root (CLI/daemon), we can't show prompts.
        if (!geteuid()) {
            return;
        }
        
        // Prompt to enable error reporting if possible.
        BOOL enabledReports = [SCSentry showErrorReportingPromptIfNeeded];
        if (!enabledReports) {
            return;
        }
    }
    
    NSLog(@"Reporting error %@ to Sentry...", error);
    [[SCSettings sharedSettings] updateSentryContext];
    [SCSentry updateDefaultsContext];
#ifndef TESTING
    [SentrySDK captureError: error];
#endif
}

+ (void)captureMessage:(NSString*)message withScopeBlock:(nullable void (^)(SentryScope * _Nonnull))block {
    if (![SCSentry errorReportingEnabled]) {
        // If we're root (CLI/daemon), we can't show prompts.
        if (!geteuid()) {
            return;
        }
        
        // Prompt to enable error reporting if possible.
        BOOL enabledReports = [SCSentry showErrorReportingPromptIfNeeded];
        if (!enabledReports) {
            return;
        }
    }
    
    NSLog(@"Reporting message %@ to Sentry...", message);
    [[SCSettings sharedSettings] updateSentryContext];
    [SCSentry updateDefaultsContext];
#ifndef TESTING
    if (block != nil) {
        [SentrySDK captureMessage: message withScopeBlock: block];
    } else {
        [SentrySDK captureMessage: message];
    }
#endif
}

+ (void)captureMessage:(NSString*)message {
    [SCSentry captureMessage: message withScopeBlock: nil];
}

+ (NSString*)configuredDSN {
    id dsnValue = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"SentryDSN"];
    if (![dsnValue isKindOfClass: [NSString class]]) {
        return @"";
    }
    
    NSString* dsn = [(NSString*)dsnValue stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (dsn.length < 1) {
        return @"";
    }
    
    if ([dsn rangeOfString: @"://"].location != NSNotFound) {
        return dsn;
    }
    
    // Support plist-safe DSN format without scheme to avoid Info.plist preprocessing issues.
    return [NSString stringWithFormat: @"https://%@", dsn];
}

+ (BOOL)errorReportingEnabled {
#ifdef TESTING
    // Don't report to Sentry while unit-testing.
    if ([[NSUserDefaults standardUserDefaults] boolForKey: @"isTest"]) {
        return YES;
    }
#endif
    if (geteuid() != 0) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        return [defaults boolForKey: @"EnableErrorReporting"];
    } else {
        // Since we're root, read the copied preference from SCSettings.
        return [[SCSettings sharedSettings] boolForKey: @"EnableErrorReporting"];
    }
}

// Returns YES if we turned on error reporting based on the prompt return.
+ (BOOL)showErrorReportingPromptIfNeeded {
    // No need to prompt if we're root, already enabled, or previously dismissed.
    if (!geteuid()) return NO;
    if ([SCSentry errorReportingEnabled]) return NO;
    
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey: @"ErrorReportingPromptDismissed"]) {
        return NO;
    }
    
    // UI work must be on the main thread.
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [SCSentry showErrorReportingPromptIfNeeded];
        });
        return retVal;
    }
    
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText: NSLocalizedString(@"Enable automatic error reporting", "Title of error reporting prompt")];
    [alert setInformativeText: NSLocalizedString(@"SelfControl can automatically send bug reports to help us improve the software. All data is anonymized, your blocklist is never shared, and no identifying information is sent.", @"Message explaining error reporting")];
    [alert addButtonWithTitle: NSLocalizedString(@"Enable Error Reporting", @"Button to enable error reporting")];
    [alert addButtonWithTitle: NSLocalizedString(@"Don't Send Reports", "Button to decline error reporting")];
    
    NSModalResponse modalResponse = [alert runModal];
    if (modalResponse == NSAlertFirstButtonReturn) {
        [defaults setBool: YES forKey: @"EnableErrorReporting"];
        [defaults setBool: YES forKey: @"ErrorReportingPromptDismissed"];
        return YES;
    } else if (modalResponse == NSAlertSecondButtonReturn) {
        [defaults setBool: NO forKey: @"EnableErrorReporting"];
        [defaults setBool: YES forKey: @"ErrorReportingPromptDismissed"];
    }
    
    return NO;
}

+ (void)updateDefaultsContext {
    // If we're root, we can't read user defaults meaningfully.
    if (!geteuid()) {
        return;
    }
    
    NSString* defaultsDomain = NSBundle.mainBundle.bundleIdentifier ?: @"org.eyebeam.SelfControlX";
    NSDictionary* persistentDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName: defaultsDomain];
    NSMutableDictionary* defaultsDict = [persistentDefaults mutableCopy];
    if (defaultsDict == nil) {
        defaultsDict = [NSMutableDictionary dictionary];
    }
    
    // Remove PII-heavy values and keep only useful metadata.
    id blocklist = defaultsDict[@"Blocklist"];
    NSUInteger blocklistLength = (blocklist == nil) ? 0 : ((NSArray*)blocklist).count;
    [defaultsDict setObject: @(blocklistLength) forKey: @"BlocklistLength"];
    [defaultsDict removeObjectForKey: @"Blocklist"];
    [defaultsDict removeObjectForKey: @"SULastCheckTime"];
    [defaultsDict removeObjectForKey: @"SULastProfileSubmissionDate"];
    
#ifndef TESTING
    [SentrySDK configureScope:^(SentryScope * _Nonnull scope) {
        [scope setContextValue: defaultsDict forKey: @"NSUserDefaults"];
    }];
#endif
}

@end
