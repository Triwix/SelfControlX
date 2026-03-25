//
//  SCDaemonTestStub.m
//  SelfControlTests
//
//  Provides a minimal daemon class for logic tests that compile
//  daemon block methods without linking the full daemon executable target.
//

#import "SCDaemon.h"

@implementation SCDaemon

+ (instancetype)sharedDaemon {
    static SCDaemon* daemon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        daemon = [SCDaemon new];
    });
    return daemon;
}

- (void)start {
}

- (void)startCheckupTimer {
}

- (void)stopCheckupTimer {
}

- (void)resetInactivityTimer {
}

@end
