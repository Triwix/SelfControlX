//
//  SCDaemonBlockMethods.m
//  org.eyebeam.selfcontrolxxd
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCDaemonBlockMethods.h"
#import "SCSettings.h"
#import "SCHelperToolUtilities.h"
#import "PacketFilter.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"

NSTimeInterval METHOD_LOCK_TIMEOUT = 5.0;
NSTimeInterval CHECKUP_LOCK_TIMEOUT = 0.5; // use a shorter lock timeout for checkups, because we'd prefer not to have tons pile up
NSTimeInterval TRUSTED_TIME_REFRESH_INTERVAL_SECS = 30.0;
NSTimeInterval TRUSTED_TIME_REQUEST_TIMEOUT_SECS = 2.5;
NSTimeInterval TRUSTED_TIME_FAILURE_LOG_THROTTLE_SECS = 60.0;
NSTimeInterval HOSTS_MUTATION_REAPPLY_THROTTLE_SECS = 2.0;
static BOOL TRUSTED_TIME_REFRESH_IN_FLIGHT = NO;

static NSString* const kTrustedTimeSettingEnforced = @"TrustedTimeEnforced";
static NSString* const kTrustedBlockEndDateSetting = @"TrustedBlockEndDate";
static NSString* const kTrustedTimeLastFetchDateSetting = @"TrustedTimeLastFetchDate";
static NSString* const kTrustedTimeLastFetchUptimeSetting = @"TrustedTimeLastFetchUptime";
static NSString* const kTrustedTimeSourceURLsSetting = @"TrustedTimeSourceURLs";
static NSString* const kTrustedTimeConsensusRequiredCountSetting = @"TrustedTimeConsensusRequiredCount";
static NSString* const kTrustedTimeConsensusMaxSkewSecondsSetting = @"TrustedTimeConsensusMaxSkewSeconds";
static NSString* const kBlockBypassesEnabledSetting = @"BlockBypassesEnabled";
static NSString* const kMaxBlockLengthMinutesSetting = @"MaxBlockLengthMinutes";

static NSInteger const kDefaultMaxBlockLengthMinutes = 1440;
static NSInteger const kMaximumBlockLengthLimitMinutes = 10080; // 7 days
static NSInteger const kTrustedTimeDefaultRequiredCount = 2;
static NSTimeInterval const kTrustedTimeDefaultMaxSkewSeconds = 10.0;
static NSTimeInterval const kTrustedTimeMinimumMaxSkewSeconds = 1.0;
static NSTimeInterval const kTrustedTimeMaximumMaxSkewSeconds = 300.0;

static NSDateFormatter* HTTPDateHeaderFormatter(void) {
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

static NSArray<NSString*>* DefaultTrustedTimeSourceURLs(void) {
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

@implementation SCDaemonBlockMethods

+ (NSLock*)daemonMethodLock {
    static NSLock* lock = nil;
    if (lock == nil) {
        lock = [[NSLock alloc] init];
    }
    return lock;
}

+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply timeout:(NSTimeInterval)timeout {
    // only run one request at a time, so we avoid weird situations like trying to run a checkup while we're starting a block
    if (![self.daemonMethodLock lockBeforeDate: [NSDate dateWithTimeIntervalSinceNow: timeout]]) {
        // if we couldn't get a lock within 10 seconds, something is weird
        // but we probably shouldn't still run, because that's just unexpected at that point
        // don't capture this error on Sentry because it's very usual for checkups to timeout
        NSError* err = [SCErr errorWithCode: 300];
        NSLog(@"ERROR: Timed out acquiring request lock (after %f seconds)", timeout);

        if (reply != nil) {
            reply(err);
        }
        return NO;
    }
    return YES;
}
+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply {
    return [self lockOrTimeout: reply timeout: METHOD_LOCK_TIMEOUT];
}

+ (NSArray<NSString*>*)normalizedTrustedTimeSourceURLsFromRawValue:(id)rawValue {
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
        return DefaultTrustedTimeSourceURLs();
    }
    
    return normalizedValues;
}

+ (NSInteger)normalizedTrustedTimeConsensusRequiredCountFromRawValue:(id)rawValue sourceCount:(NSUInteger)sourceCount {
    NSInteger requiredCount = [rawValue integerValue];
    if (requiredCount < 1) {
        requiredCount = kTrustedTimeDefaultRequiredCount;
    }
    
    NSInteger maxAllowed = (NSInteger)MAX(sourceCount, 1);
    return MIN(MAX(requiredCount, 1), maxAllowed);
}

+ (NSTimeInterval)normalizedTrustedTimeConsensusMaxSkewSecondsFromRawValue:(id)rawValue {
    NSTimeInterval maxSkewSeconds = [rawValue doubleValue];
    if (maxSkewSeconds <= 0) {
        maxSkewSeconds = kTrustedTimeDefaultMaxSkewSeconds;
    }
    
    return MIN(MAX(maxSkewSeconds, kTrustedTimeMinimumMaxSkewSeconds), kTrustedTimeMaximumMaxSkewSeconds);
}

+ (NSDate* _Nullable)consensusTrustedDateFromSamples:(NSArray<NSDate*>*)samples
                                      requiredMatches:(NSInteger)requiredMatches
                                       maxSkewSeconds:(NSTimeInterval)maxSkewSeconds {
    if (samples.count < 1) {
        return nil;
    }
    
    NSArray<NSDate*>* sortedDates = [samples sortedArrayUsingComparator:^NSComparisonResult(NSDate * _Nonnull first, NSDate * _Nonnull second) {
        return [first compare: second];
    }];
    
    NSInteger clampedRequiredMatches = MIN(MAX(requiredMatches, 1), (NSInteger)sortedDates.count);
    NSTimeInterval clampedMaxSkew = MIN(MAX(maxSkewSeconds, kTrustedTimeMinimumMaxSkewSeconds), kTrustedTimeMaximumMaxSkewSeconds);
    
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

+ (NSDate* _Nullable)trustedDateForURLString:(NSString*)urlString {
    NSURL* url = [NSURL URLWithString: urlString];
    if (url == nil) {
        return nil;
    }
    
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url
	                                                           cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
	                                                       timeoutInterval: TRUSTED_TIME_REQUEST_TIMEOUT_SECS];
	request.HTTPMethod = @"HEAD";
	
	__block NSError* requestError = nil;
	__block NSURLResponse* response = nil;
	dispatch_semaphore_t requestSemaphore = dispatch_semaphore_create(0);
	NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	sessionConfig.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
	sessionConfig.timeoutIntervalForRequest = TRUSTED_TIME_REQUEST_TIMEOUT_SECS;
	sessionConfig.timeoutIntervalForResource = TRUSTED_TIME_REQUEST_TIMEOUT_SECS;
	NSURLSession* session = [NSURLSession sessionWithConfiguration: sessionConfig];
	NSURLSessionDataTask* requestTask = [session dataTaskWithRequest: request
													completionHandler:^(NSData* _Nullable data,
																		NSURLResponse* _Nullable urlResponse,
																		NSError* _Nullable error) {
	#pragma unused(data)
		requestError = error;
		response = urlResponse;
		dispatch_semaphore_signal(requestSemaphore);
	}];
	[requestTask resume];
	long waitResult = dispatch_semaphore_wait(requestSemaphore,
											 dispatch_time(DISPATCH_TIME_NOW,
													  (int64_t)((TRUSTED_TIME_REQUEST_TIMEOUT_SECS + 1) * NSEC_PER_SEC)));
	if (waitResult != 0) {
		[requestTask cancel];
		[session finishTasksAndInvalidate];
		return nil;
	}
	[session finishTasksAndInvalidate];
	if (requestError != nil || ![response isKindOfClass: [NSHTTPURLResponse class]]) {
		return nil;
	}
    
    NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 400) {
        return nil;
    }
    
    NSDictionary* responseHeaders = httpResponse.allHeaderFields;
    NSString* dateHeader = nil;
    for (id key in responseHeaders) {
        if ([key isKindOfClass: [NSString class]] && [(NSString*)key caseInsensitiveCompare: @"Date"] == NSOrderedSame) {
            id value = responseHeaders[key];
            if ([value isKindOfClass: [NSString class]]) {
                dateHeader = (NSString*)value;
            }
            break;
        }
    }
    
    if (dateHeader == nil) {
        return nil;
    }
    
    NSDateFormatter* formatter = HTTPDateHeaderFormatter();
    @synchronized (formatter) {
        return [formatter dateFromString: dateHeader];
    }
}

+ (NSDate* _Nullable)consensusTrustedTimeWithSourceURLs:(NSArray<NSString*>*)sourceURLs
                                        requiredMatches:(NSInteger)requiredMatches
                                         maxSkewSeconds:(NSTimeInterval)maxSkewSeconds {
    NSMutableArray<NSDate*>* sourceDates = [NSMutableArray arrayWithCapacity: sourceURLs.count];
    for (NSString* sourceURL in sourceURLs) {
        NSDate* sourceDate = [self trustedDateForURLString: sourceURL];
        if (sourceDate == nil) {
            continue;
        }
        
        [sourceDates addObject: sourceDate];
        NSDate* consensusDate = [self consensusTrustedDateFromSamples: sourceDates
                                                      requiredMatches: requiredMatches
                                                       maxSkewSeconds: maxSkewSeconds];
        if (consensusDate != nil) {
            return consensusDate;
        }
    }
    
    return nil;
}

+ (NSDate* _Nullable)consensusTrustedTimeUsingSettingsDict:(NSDictionary*)settingsDict {
    NSArray<NSString*>* sourceURLs = [self normalizedTrustedTimeSourceURLsFromRawValue: settingsDict[kTrustedTimeSourceURLsSetting]];
    NSInteger requiredMatches = [self normalizedTrustedTimeConsensusRequiredCountFromRawValue: settingsDict[kTrustedTimeConsensusRequiredCountSetting]
                                                                                   sourceCount: sourceURLs.count];
    NSTimeInterval maxSkewSeconds = [self normalizedTrustedTimeConsensusMaxSkewSecondsFromRawValue: settingsDict[kTrustedTimeConsensusMaxSkewSecondsSetting]];
    return [self consensusTrustedTimeWithSourceURLs: sourceURLs
                                    requiredMatches: requiredMatches
                                     maxSkewSeconds: maxSkewSeconds];
}

+ (NSDate* _Nullable)consensusTrustedTimeUsingSettings:(SCSettings*)settings {
    NSDictionary* settingsDict = @{
        kTrustedTimeSourceURLsSetting: [settings valueForKey: kTrustedTimeSourceURLsSetting] ?: @[],
        kTrustedTimeConsensusRequiredCountSetting: [settings valueForKey: kTrustedTimeConsensusRequiredCountSetting] ?: @(kTrustedTimeDefaultRequiredCount),
        kTrustedTimeConsensusMaxSkewSecondsSetting: [settings valueForKey: kTrustedTimeConsensusMaxSkewSecondsSetting] ?: @(kTrustedTimeDefaultMaxSkewSeconds)
    };
    return [self consensusTrustedTimeUsingSettingsDict: settingsDict];
}

+ (void)trustedDateForURLString:(NSString*)urlString completion:(void(^)(NSDate* _Nullable trustedDate))completion {
    NSURL* url = [NSURL URLWithString: urlString];
    if (url == nil) {
        if (completion != nil) {
            completion(nil);
        }
        return;
    }
    
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url
                                                           cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval: TRUSTED_TIME_REQUEST_TIMEOUT_SECS];
    request.HTTPMethod = @"HEAD";
    
    NSURLSessionDataTask* dataTask = [[NSURLSession sharedSession] dataTaskWithRequest: request
                                                                      completionHandler:^(NSData * _Nullable data,
                                                                                          NSURLResponse * _Nullable response,
                                                                                          NSError * _Nullable requestError) {
#pragma unused(data)
        if (requestError != nil || ![response isKindOfClass: [NSHTTPURLResponse class]]) {
            if (completion != nil) {
                completion(nil);
            }
            return;
        }
        
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 400) {
            if (completion != nil) {
                completion(nil);
            }
            return;
        }
        
        NSDictionary* responseHeaders = httpResponse.allHeaderFields;
        NSString* dateHeader = nil;
        for (id key in responseHeaders) {
            if ([key isKindOfClass: [NSString class]] && [(NSString*)key caseInsensitiveCompare: @"Date"] == NSOrderedSame) {
                id value = responseHeaders[key];
                if ([value isKindOfClass: [NSString class]]) {
                    dateHeader = (NSString*)value;
                }
                break;
            }
        }
        
        if (dateHeader == nil) {
            if (completion != nil) {
                completion(nil);
            }
            return;
        }
        
        NSDateFormatter* formatter = HTTPDateHeaderFormatter();
        NSDate* trustedDate = nil;
        @synchronized (formatter) {
            trustedDate = [formatter dateFromString: dateHeader];
        }
        
        if (completion != nil) {
            completion(trustedDate);
        }
    }];
    [dataTask resume];
}

+ (void)consensusTrustedTimeWithSourceURLs:(NSArray<NSString*>*)sourceURLs
                           requiredMatches:(NSInteger)requiredMatches
                            maxSkewSeconds:(NSTimeInterval)maxSkewSeconds
                                completion:(void(^)(NSDate* _Nullable trustedDate))completion {
    if (sourceURLs.count < 1) {
        if (completion != nil) {
            completion(nil);
        }
        return;
    }
    
    NSInteger clampedRequiredMatches = MIN(MAX(requiredMatches, 1), (NSInteger)sourceURLs.count);
    NSMutableArray<NSDate*>* sourceDates = [NSMutableArray arrayWithCapacity: sourceURLs.count];
    dispatch_queue_t stateQueue = dispatch_queue_create("org.eyebeam.selfcontrolx.trusted-time-consensus", DISPATCH_QUEUE_SERIAL);
    
    __block NSInteger completedResponses = 0;
    __block BOOL didComplete = NO;
    NSInteger totalResponses = (NSInteger)sourceURLs.count;
    
    for (NSString* sourceURL in sourceURLs) {
        [self trustedDateForURLString: sourceURL completion:^(NSDate * _Nullable sourceDate) {
            __block BOOL shouldFinish = NO;
            __block NSDate* consensusDate = nil;
            dispatch_sync(stateQueue, ^{
                if (didComplete) {
                    return;
                }
                
                completedResponses += 1;
                if (sourceDate != nil) {
                    [sourceDates addObject: sourceDate];
                    consensusDate = [self consensusTrustedDateFromSamples: sourceDates
                                                           requiredMatches: clampedRequiredMatches
                                                            maxSkewSeconds: maxSkewSeconds];
                }
                
                NSInteger remainingResponses = totalResponses - completedResponses;
                NSInteger maxPossibleMatches = (NSInteger)sourceDates.count + remainingResponses;
                BOOL consensusImpossible = maxPossibleMatches < clampedRequiredMatches;
                if (consensusDate != nil || completedResponses >= totalResponses || consensusImpossible) {
                    didComplete = YES;
                    shouldFinish = YES;
                }
            });
            
            if (shouldFinish && completion != nil) {
                completion(consensusDate);
            }
        }];
    }
}

+ (void)consensusTrustedTimeUsingSettingsDict:(NSDictionary*)settingsDict completion:(void(^)(NSDate* _Nullable trustedDate))completion {
    NSArray<NSString*>* sourceURLs = [self normalizedTrustedTimeSourceURLsFromRawValue: settingsDict[kTrustedTimeSourceURLsSetting]];
    NSInteger requiredMatches = [self normalizedTrustedTimeConsensusRequiredCountFromRawValue: settingsDict[kTrustedTimeConsensusRequiredCountSetting]
                                                                                   sourceCount: sourceURLs.count];
    NSTimeInterval maxSkewSeconds = [self normalizedTrustedTimeConsensusMaxSkewSecondsFromRawValue: settingsDict[kTrustedTimeConsensusMaxSkewSecondsSetting]];
    [self consensusTrustedTimeWithSourceURLs: sourceURLs
                             requiredMatches: requiredMatches
                              maxSkewSeconds: maxSkewSeconds
                                  completion: completion];
}

+ (BOOL)trustedTimeMetadataLooksValidInSettings:(SCSettings*)settings {
    id trustedEndDate = [settings valueForKey: kTrustedBlockEndDateSetting];
    id trustedLastFetchDate = [settings valueForKey: kTrustedTimeLastFetchDateSetting];
    id trustedLastFetchUptime = [settings valueForKey: kTrustedTimeLastFetchUptimeSetting];
    
    if (![trustedEndDate isKindOfClass: [NSDate class]]
        || ![trustedLastFetchDate isKindOfClass: [NSDate class]]
        || ![trustedLastFetchUptime isKindOfClass: [NSNumber class]]) {
        return NO;
    }
    
    if ([(NSDate*)trustedEndDate timeIntervalSince1970] <= 0
        || [(NSDate*)trustedLastFetchDate timeIntervalSince1970] <= 0
        || [(NSNumber*)trustedLastFetchUptime doubleValue] <= 0) {
        return NO;
    }
    
    return YES;
}

+ (BOOL)trustedTimeRefreshRequiredInSettings:(SCSettings*)settings {
    if (![self trustedTimeMetadataLooksValidInSettings: settings]) {
        return YES;
    }
    
    NSTimeInterval currentUptime = [NSProcessInfo processInfo].systemUptime;
    NSTimeInterval trustedLastFetchUptime = [[settings valueForKey: kTrustedTimeLastFetchUptimeSetting] doubleValue];
    if (currentUptime < trustedLastFetchUptime) {
        // reboot or timebase reset
        return YES;
    }
    
    return (currentUptime - trustedLastFetchUptime) >= TRUSTED_TIME_REFRESH_INTERVAL_SECS;
}

+ (NSDate* _Nullable)estimatedTrustedNowFromSettings:(SCSettings*)settings {
    if (![self trustedTimeMetadataLooksValidInSettings: settings]) {
        return nil;
    }
    
    NSDate* trustedLastFetchDate = [settings valueForKey: kTrustedTimeLastFetchDateSetting];
    NSTimeInterval trustedLastFetchUptime = [[settings valueForKey: kTrustedTimeLastFetchUptimeSetting] doubleValue];
    NSTimeInterval currentUptime = [NSProcessInfo processInfo].systemUptime;
    NSTimeInterval uptimeDelta = currentUptime - trustedLastFetchUptime;
    if (uptimeDelta < 0) {
        uptimeDelta = 0;
    }
    
    return [trustedLastFetchDate dateByAddingTimeInterval: uptimeDelta];
}

+ (void)updateTrustedTimeSampleInSettings:(SCSettings*)settings trustedDate:(NSDate*)trustedDate {
    [settings setValue: trustedDate forKey: kTrustedTimeLastFetchDateSetting];
    [settings setValue: @([NSProcessInfo processInfo].systemUptime) forKey: kTrustedTimeLastFetchUptimeSetting];
}

+ (void)reportTrustedTimeFailureIfNeeded:(NSError*)error {
    static NSDate* lastFailureReportDate = nil;
    NSDate* now = [NSDate date];
    
    if (lastFailureReportDate == nil || [now timeIntervalSinceDate: lastFailureReportDate] > TRUSTED_TIME_FAILURE_LOG_THROTTLE_SECS) {
        lastFailureReportDate = now;
        NSLog(@"WARNING: Trusted internet time could not be refreshed. Keeping block active.");
        [SCSentry captureError: error];
    }
}

+ (NSInteger)normalizedMaxBlockLengthMinutesFromSettingsDict:(NSDictionary*)settingsDict {
    NSInteger maxBlockLengthMinutes = [settingsDict[kMaxBlockLengthMinutesSetting] integerValue];
    if (maxBlockLengthMinutes < 1) {
        maxBlockLengthMinutes = kDefaultMaxBlockLengthMinutes;
    }
    
    return MIN(MAX(maxBlockLengthMinutes, 1), kMaximumBlockLengthLimitMinutes);
}

+ (NSInteger)normalizedActiveMaxBlockLengthMinutesForSettings:(SCSettings*)settings {
    NSInteger maxBlockLengthMinutes = [[settings valueForKey: kMaxBlockLengthMinutesSetting] integerValue];
    if (maxBlockLengthMinutes < 1) {
        maxBlockLengthMinutes = kDefaultMaxBlockLengthMinutes;
    }
    
    return MIN(MAX(maxBlockLengthMinutes, 1), kMaximumBlockLengthLimitMinutes);
}


+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    // we reset at the _end_ of every method, but we'll also reset at the _start_ here
    // because startBlock can sometimes take a while, and it'd be a shame if the daemon killed itself
    // before we were done
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    
    [SCSentry addBreadcrumb: @"Daemon method startBlock called" category: @"daemon"];
    
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"ERROR: Can't start block since a block is already running");
        NSError* err = [SCErr errorWithCode: 301];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // clear any legacy block information - no longer useful and could potentially confuse things
    // but first, copy it over one more time (this should've already happened once in the app, but you never know)
    if ([SCMigrationUtilities legacySettingsFoundForUser: controllingUID]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults: controllingUID];
        [SCMigrationUtilities clearLegacySettingsForUser: controllingUID];
        
        // if we had legacy settings, there's a small chance the old helper tool could still be around
        // make sure it's dead and gone
        [LaunchctlHelper unloadLaunchdJobWithPlistAt: @"/Library/LaunchDaemons/org.eyebeam.SelfControlX.plist"];
    }

    SCSettings* settings = [SCSettings sharedSettings];
    if(([blocklist count] <= 0 && !isAllowlist)) {
        NSLog(@"ERROR: Blocklist is empty");
        NSError* err = [SCErr errorWithCode: 302];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    BOOL blockBypassesEnabled = blockSettings[kBlockBypassesEnabledSetting] == nil
        ? YES
        : [blockSettings[kBlockBypassesEnabledSetting] boolValue];
    NSInteger maxBlockLengthMinutes = [self normalizedMaxBlockLengthMinutesFromSettingsDict: blockSettings];
    NSArray<NSString*>* trustedTimeSourceURLs = [self normalizedTrustedTimeSourceURLsFromRawValue: blockSettings[kTrustedTimeSourceURLsSetting]];
    NSInteger trustedTimeConsensusRequiredCount = [self normalizedTrustedTimeConsensusRequiredCountFromRawValue: blockSettings[kTrustedTimeConsensusRequiredCountSetting]
                                                                                                     sourceCount: trustedTimeSourceURLs.count];
    NSTimeInterval trustedTimeConsensusMaxSkewSeconds = [self normalizedTrustedTimeConsensusMaxSkewSecondsFromRawValue: blockSettings[kTrustedTimeConsensusMaxSkewSecondsSetting]];
    
    NSDate* trustedStartDate = nil;
    NSDate* effectiveBlockEndDate = endDate;
    if (blockBypassesEnabled) {
        trustedStartDate = [self consensusTrustedTimeWithSourceURLs: trustedTimeSourceURLs
                                                    requiredMatches: trustedTimeConsensusRequiredCount
                                                     maxSkewSeconds: trustedTimeConsensusMaxSkewSeconds];
        if (trustedStartDate == nil) {
            NSLog(@"ERROR: Trusted internet time unavailable, refusing to start block");
            NSError* err = [SCErr errorWithCode: 311];
            [SCSentry captureError: err];
            reply(err);
            [self.daemonMethodLock unlock];
            return;
        }
        
        NSTimeInterval requestedDurationSecs = [blockSettings[@"RequestedDurationSeconds"] doubleValue];
        if (requestedDurationSecs <= 0) {
            requestedDurationSecs = [endDate timeIntervalSinceDate: trustedStartDate];
        }
        if (requestedDurationSecs <= 0) {
            NSLog(@"ERROR: Block duration is invalid (requested duration was %f)", requestedDurationSecs);
            NSError* err = [SCErr errorWithCode: 302];
            [SCSentry captureError: err];
            reply(err);
            [self.daemonMethodLock unlock];
            return;
        }
        
        effectiveBlockEndDate = [trustedStartDate dateByAddingTimeInterval: requestedDurationSecs];
    } else if ([endDate timeIntervalSinceNow] <= 0) {
        NSLog(@"ERROR: Block end date is not in the future");
        NSError* err = [SCErr errorWithCode: 302];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // update SCSettings with the blocklist and end date that've been requested
    [settings setValue: blocklist forKey: @"ActiveBlocklist"];
    [settings setValue: @(isAllowlist) forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: effectiveBlockEndDate forKey: @"BlockEndDate"];
    
    // update all the settings for the block, which we're basically just copying from defaults to settings
    [settings setValue: blockSettings[@"ClearCaches"] forKey: @"ClearCaches"];
    [settings setValue: blockSettings[@"AllowLocalNetworks"] forKey: @"AllowLocalNetworks"];
    [settings setValue: blockSettings[@"EvaluateCommonSubdomains"] forKey: @"EvaluateCommonSubdomains"];
    [settings setValue: blockSettings[@"IncludeLinkedDomains"] forKey: @"IncludeLinkedDomains"];
    [settings setValue: blockSettings[@"BlockSoundShouldPlay"] forKey: @"BlockSoundShouldPlay"];
    [settings setValue: blockSettings[@"BlockSound"] forKey: @"BlockSound"];
    [settings setValue: @(blockBypassesEnabled) forKey: kBlockBypassesEnabledSetting];
    [settings setValue: @(maxBlockLengthMinutes) forKey: kMaxBlockLengthMinutesSetting];
    [settings setValue: trustedTimeSourceURLs forKey: kTrustedTimeSourceURLsSetting];
    [settings setValue: @(trustedTimeConsensusRequiredCount) forKey: kTrustedTimeConsensusRequiredCountSetting];
    [settings setValue: @(trustedTimeConsensusMaxSkewSeconds) forKey: kTrustedTimeConsensusMaxSkewSecondsSetting];
    
    if (blockBypassesEnabled) {
        [settings setValue: @YES forKey: kTrustedTimeSettingEnforced];
        [settings setValue: effectiveBlockEndDate forKey: kTrustedBlockEndDateSetting];
        [self updateTrustedTimeSampleInSettings: settings trustedDate: trustedStartDate];
    } else {
        [settings setValue: @NO forKey: kTrustedTimeSettingEnforced];
        [settings setValue: [NSDate distantPast] forKey: kTrustedBlockEndDateSetting];
        [settings setValue: [NSDate distantPast] forKey: kTrustedTimeLastFetchDateSetting];
        [settings setValue: @0 forKey: kTrustedTimeLastFetchUptimeSetting];
    }

    NSLog(@"Adding firewall rules...");
    [SCHelperToolUtilities installBlockRulesFromSettings];
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    
    NSError* syncErr = [settings syncSettingsAndWait: 5]; // synchronize ASAP since BlockIsRunning is a really important one
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after starting block", syncErr);
        [SCSentry captureError: syncErr];
    }

    NSLog(@"Firewall rules added!");
    
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon added block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully added.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [[SCDaemon sharedDaemon] startCheckupTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlocklist called" category: @"daemon"];
    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 303];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist since block isn't running");
        NSError* err = [SCErr errorWithCode: 304];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    BOOL blockAsAllowlist = [settings boolForKey: @"ActiveBlockAsWhitelist"];
        
    if (blockAsAllowlist) {
        NSLog(@"ERROR: Attempting to update active blocklist, but this is not possible with an allowlist block");
        NSError* err = [SCErr errorWithCode: 305];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"];
    NSMutableArray* added = [NSMutableArray arrayWithArray: newBlocklist];
    [added removeObjectsInArray: activeBlocklist];
    NSMutableArray* removed = [NSMutableArray arrayWithArray: activeBlocklist];
    [removed removeObjectsInArray: newBlocklist];
    
    // throw a warning if something got removed for some reason, since we ignore them
    if (removed.count > 0) {
        NSLog(@"WARNING: Active blocklist has removed items; these will not be updated. Removed items are %@", removed);
    }
    
    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist: [settings boolForKey: @"ActiveBlockAsWhitelist"]
                                                            allowLocal: [settings boolForKey: @"AllowLocalNetworks"]
                                               includeCommonSubdomains: [settings boolForKey: @"EvaluateCommonSubdomains"]
                                                  includeLinkedDomains: [settings boolForKey: @"IncludeLinkedDomains"]];
    BOOL blockBypassesEnabled = [settings boolForKey: kBlockBypassesEnabledSetting];
    if (blockBypassesEnabled) {
        [SCHelperToolUtilities clearHostsFilesImmutable];
    }
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings: added];
    [blockManager finishAppending];
    if (blockBypassesEnabled) {
        [SCHelperToolUtilities setHostsFilesImmutable];
    }
    
    [settings setValue: newBlocklist forKey: @"ActiveBlocklist"];
    
    // make sure everyone knows about our new list
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after updating blocklist", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon updated blocklist successfully" category: @"daemon"];
    NSLog(@"INFO: Blocklist successfully updated.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlockEndDate called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 306];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date since block isn't running");
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    if (![newEndDate isKindOfClass: [NSDate class]]) {
        NSLog(@"ERROR: Can't update block end date because the new date is invalid (%@)", newEndDate);
        NSError* err = [SCErr errorWithCode: 308];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // this can only be used to *extend* the block end date - not shorten it!
    // we also cap extension size by the configured MaxBlockLengthMinutes.
    id currentEndDateRawValue = [settings valueForKey: @"BlockEndDate"];
    if (![currentEndDateRawValue isKindOfClass: [NSDate class]]) {
        NSLog(@"ERROR: Can't update block end date because current block end date is invalid (%@)", currentEndDateRawValue);
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    NSDate* currentEndDate = (NSDate*)currentEndDateRawValue;
    NSTimeInterval maxExtensionSeconds = [self normalizedActiveMaxBlockLengthMinutesForSettings: settings] * 60;
    if ([newEndDate timeIntervalSinceDate: currentEndDate] < 0) {
        NSLog(@"ERROR: Can't update block end date to an earlier date");
        NSError* err = [SCErr errorWithCode: 308];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if ([newEndDate timeIntervalSinceDate: currentEndDate] > maxExtensionSeconds) {
        NSLog(@"ERROR: Can't extend block end date by more than configured max extension (%f seconds)", maxExtensionSeconds);
        NSError* err = [SCErr errorWithCode: 309];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    [settings setValue: newEndDate forKey: @"BlockEndDate"];
    if ([settings boolForKey: kTrustedTimeSettingEnforced]) {
        [settings setValue: newEndDate forKey: kTrustedBlockEndDateSetting];
    }
    
    // make sure everyone knows about our new end date
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after extending block", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    [SCSentry addBreadcrumb: @"Daemon extended block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully extended.");
    reply(nil);
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)forceClearBlockWithAuthorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    #pragma unused(authData)
    [SCSentry addBreadcrumb: @"Daemon method forceClearBlock called" category: @"daemon"];
    
    if (![SCBlockUtilities anyBlockIsRunning] && ![SCBlockUtilities blockRulesFoundOnSystem]) {
        NSLog(@"ERROR: Can't manually clear block because no block is active");
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    [SCHelperToolUtilities removeBlock];
    
    if ([SCBlockUtilities anyBlockIsRunning] || [SCBlockUtilities blockRulesFoundOnSystem]) {
        NSLog(@"ERROR: Manual block clear failed, block still appears active");
        NSError* err = [SCErr errorWithCode: 401];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon manually cleared block successfully" category: @"daemon"];
    [[SCDaemon sharedDaemon] stopCheckupTimer];
    reply(nil);
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)checkupBlock {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkupBlock called" category: @"daemon"];

    NSTimeInterval integrityCheckIntervalSecs = 15.0;
    static NSDate* lastBlockIntegrityCheck;
    if (lastBlockIntegrityCheck == nil) {
        lastBlockIntegrityCheck = [NSDate distantPast];
    }

    BOOL shouldRunIntegrityCheck = NO;
    SCSettings* settings = [SCSettings sharedSettings];
    if(![SCBlockUtilities anyBlockIsRunning]) {
        // No block appears to be running at all in our settings.
        // Most likely, the user removed it trying to get around the block. Boo!
        // but for safety and to avoid permablocks (we no longer know when the block should end)
        // we should clear the block now.
        // but let them know that we noticed their (likely) cheating and we're not happy!
        NSLog(@"INFO: Checkup ran, no active block found.");
        
        [SCSentry captureMessage: @"Checkup ran and no active block found! Removing block, tampering suspected..."];
        
        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];
        
        // Temporarily disabled the TamperingDetection flag because it was sometimes causing false positives
        // (i.e. people having the background set repeatedly despite no attempts to cheat)
        // We will try to bring this feature back once we can debug it
        // GitHub issue: https://github.com/SelfControlApp/selfcontrol/issues/621
        // [settings setValue: @YES forKey: @"TamperingDetected"];
        //        [settings synchronizeSettings];
        //
        
        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    } else {
        BOOL blockExpired = NO;
        if ([settings boolForKey: kTrustedTimeSettingEnforced]) {
            if ([self trustedTimeRefreshRequiredInSettings: settings]) {
                if (!TRUSTED_TIME_REFRESH_IN_FLIGHT) {
                    TRUSTED_TIME_REFRESH_IN_FLIGHT = YES;
                    NSDictionary* trustedTimeSettingsSnapshot = @{
                        kTrustedTimeSourceURLsSetting: [settings valueForKey: kTrustedTimeSourceURLsSetting] ?: @[],
                        kTrustedTimeConsensusRequiredCountSetting: [settings valueForKey: kTrustedTimeConsensusRequiredCountSetting] ?: @(kTrustedTimeDefaultRequiredCount),
                        kTrustedTimeConsensusMaxSkewSecondsSetting: [settings valueForKey: kTrustedTimeConsensusMaxSkewSecondsSetting] ?: @(kTrustedTimeDefaultMaxSkewSeconds)
                    };
                    [self consensusTrustedTimeUsingSettingsDict: trustedTimeSettingsSnapshot completion:^(NSDate * _Nullable trustedNow) {
                        if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: METHOD_LOCK_TIMEOUT]) {
                            @synchronized (self) {
                                TRUSTED_TIME_REFRESH_IN_FLIGHT = NO;
                            }
                            return;
                        }
                        
                        TRUSTED_TIME_REFRESH_IN_FLIGHT = NO;
                        SCSettings* callbackSettings = [SCSettings sharedSettings];
                        if (![SCBlockUtilities anyBlockIsRunning] || ![callbackSettings boolForKey: kTrustedTimeSettingEnforced]) {
                            [[SCDaemon sharedDaemon] resetInactivityTimer];
                            [self.daemonMethodLock unlock];
                            return;
                        }
                        
                        if (trustedNow == nil) {
                            NSError* err = [SCErr errorWithCode: 312];
                            [self reportTrustedTimeFailureIfNeeded: err];
                            [[SCDaemon sharedDaemon] resetInactivityTimer];
                            [self.daemonMethodLock unlock];
                            return;
                        }
                        
                        [self updateTrustedTimeSampleInSettings: callbackSettings trustedDate: trustedNow];
                        BOOL trustedBlockExpired = NO;
                        if ([self trustedTimeMetadataLooksValidInSettings: callbackSettings]) {
                            NSDate* trustedEndDate = [callbackSettings valueForKey: kTrustedBlockEndDateSetting];
                            trustedBlockExpired = ([trustedNow timeIntervalSinceDate: trustedEndDate] >= 0);
                        }
                        
                        if (trustedBlockExpired) {
                            NSLog(@"INFO: Trusted-time refresh found block expired, removing block.");
                            
                            [SCHelperToolUtilities removeBlock];
                            
                            [SCHelperToolUtilities sendConfigurationChangedNotification];
                            
                            [SCSentry addBreadcrumb: @"Daemon cleared expired trusted-time block after async refresh" category: @"daemon"];
                            [[SCDaemon sharedDaemon] stopCheckupTimer];
                        }
                        
                        [[SCDaemon sharedDaemon] resetInactivityTimer];
                        [self.daemonMethodLock unlock];
                    }];
                }
            } else {
                NSDate* trustedNow = [self estimatedTrustedNowFromSettings: settings];
                if (trustedNow != nil && [self trustedTimeMetadataLooksValidInSettings: settings]) {
                    NSDate* trustedEndDate = [settings valueForKey: kTrustedBlockEndDateSetting];
                    blockExpired = ([trustedNow timeIntervalSinceDate: trustedEndDate] >= 0);
                } else if (trustedNow != nil) {
                    NSError* err = [SCErr errorWithCode: 312];
                    [self reportTrustedTimeFailureIfNeeded: err];
                }
            }
        } else {
            // fallback for pre-trusted blocks
            blockExpired = [SCBlockUtilities currentBlockIsExpired];
        }
        
        if (blockExpired) {
            NSLog(@"INFO: Checkup ran, block expired, removing block.");
            
            [SCHelperToolUtilities removeBlock];
            
            [SCHelperToolUtilities sendConfigurationChangedNotification];
            
            [SCSentry addBreadcrumb: @"Daemon found and cleared expired block" category: @"daemon"];
            
            // once the checkups stop, the daemon will clear itself in a while due to inactivity
            [[SCDaemon sharedDaemon] stopCheckupTimer];
        } else {
            if ([settings boolForKey: kBlockBypassesEnabledSetting]
                && ![settings boolForKey: @"ActiveBlockAsWhitelist"]) {
                // Keep host-file immutability asserted while a block is active.
                [SCHelperToolUtilities setHostsFilesImmutable];
            }
            
            if ([[NSDate date] timeIntervalSinceDate: lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
                lastBlockIntegrityCheck = [NSDate date];
                // The block is still on.  Every once in a while, we should
                // check if anybody removed our rules, and if so
                // re-add them.
                shouldRunIntegrityCheck = YES;
            }
        }
    }
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
    
    // if we need to run an integrity check, we need to do it at the very end after we give up our lock
    // because checkBlockIntegrity requests its own lock, and we don't want it to deadlock
    if (shouldRunIntegrityCheck) {
        [SCDaemonBlockMethods checkBlockIntegrity];
    }
}

+ (BOOL)hostsRulesAppearIntactForSettings:(SCSettings*)settings hostFileBlockerSet:(HostFileBlockerSet*)hostFileBlockerSet {
    if ([settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        // Allowlist mode does not rely on hosts-file entries.
        return YES;
    }
    
    for (HostFileBlocker* blocker in hostFileBlockerSet.blockers) {
        if (![blocker containsSelfControlBlock]) {
            return NO;
        }
    }
    
    return YES;
}

+ (void)reapplyBlockRulesAfterHostsMutation {
    static NSDate* lastHostsMutationReapplyDate = nil;
    NSDate* now = [NSDate date];
    if (lastHostsMutationReapplyDate != nil
        && [now timeIntervalSinceDate: lastHostsMutationReapplyDate] < HOSTS_MUTATION_REAPPLY_THROTTLE_SECS) {
        return;
    }
    lastHostsMutationReapplyDate = now;
    
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: METHOD_LOCK_TIMEOUT]) {
        return;
    }
    
    if (![SCBlockUtilities modernBlockIsRunning]) {
        [self.daemonMethodLock unlock];
        return;
    }
    
    NSLog(@"INFO: Hosts mutation detected during active block, re-applying block rules.");
    [SCSentry addBreadcrumb: @"Hosts mutation detected; daemon is re-applying block rules" category: @"daemon"];
    [SCHelperToolUtilities installBlockRulesFromSettings];
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)checkBlockIntegrity {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkBlockIntegrity called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    PacketFilter* pf = [[PacketFilter alloc] init];
    HostFileBlockerSet* hostFileBlockerSet = [[HostFileBlockerSet alloc] init];
    BOOL pfRulesLookIntact = [pf containsSelfControlBlock];
    BOOL hostsRulesLookIntact = [self hostsRulesAppearIntactForSettings: settings hostFileBlockerSet: hostFileBlockerSet];
    if(!pfRulesLookIntact || !hostsRulesLookIntact) {
        NSLog(@"INFO: Block is missing in PF or hosts, re-adding...");
        // The firewall is missing at least the block header.  Let's clear everything
        // before we re-add to make sure everything goes smoothly.
        [SCHelperToolUtilities clearHostsFilesImmutable];

        [pf stopBlock: false];

        [hostFileBlockerSet removeSelfControlBlock];
        BOOL success = [hostFileBlockerSet writeNewFileContents];
        // Revert the host file blocker's file contents to disk so we can check
        // whether or not it still contains the block after our write (aka we messed up).
        [hostFileBlockerSet revertFileContentsToDisk];
        if(!success || [hostFileBlockerSet.defaultBlocker containsSelfControlBlock]) {
            NSLog(@"WARNING: Error removing host file block.  Attempting to restore backup.");

            if([hostFileBlockerSet restoreBackupHostsFile])
                NSLog(@"INFO: Host file backup restored.");
            else
                NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
        }

        // Get rid of the backup file since we're about to make a new one.
        [hostFileBlockerSet deleteBackupHostsFile];

        // Perform the re-add of the rules
        [SCHelperToolUtilities installBlockRulesFromSettings];
        
        [SCHelperToolUtilities clearCachesIfRequested];

        [SCSentry addBreadcrumb: @"Daemon found compromised block integrity and re-added rules" category: @"daemon"];
        NSLog(@"INFO: Integrity check ran; readded block rules.");
    } else NSLog(@"INFO: Integrity check ran; no action needed.");
    
    [self.daemonMethodLock unlock];
}

@end
