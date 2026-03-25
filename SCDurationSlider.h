//
//  SCTimeSlider.h
//  SelfControl
//
//  Created by Charlie Stigler on 4/17/21.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCDurationSlider : NSSlider

@property (nonatomic, assign) NSInteger maxDuration;
@property (nonatomic, assign) NSInteger durationIntervalMinutes;
@property (readonly) NSInteger durationValueMinutes;
@property (readonly) NSString* durationDescription;

- (NSInteger)durationValueMinutes;
- (NSInteger)sanitizedDurationMinutesForValue:(NSInteger)candidateMinutes;
- (void)bindDurationToObject:(id)obj keyPath:(NSString*)keyPath;
- (NSString*)durationDescription;

+ (NSString *)timeSliderDisplayStringFromTimeInterval:(NSTimeInterval)numberOfSeconds;
+ (NSString *)timeSliderDisplayStringFromNumberOfMinutes:(NSInteger)numberOfMinutes;

@end

NS_ASSUME_NONNULL_END
