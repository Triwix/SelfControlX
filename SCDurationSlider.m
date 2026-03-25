//
//  SCTimeSlider.m
//  SelfControl
//
//  Created by Charlie Stigler on 4/17/21.
//

#import "SCDurationSlider.h"
#import "SCTimeIntervalFormatter.h"
#import <TransformerKit/NSValueTransformer+TransformerKit.h>
#include <math.h>

#define kValueTransformerName @"BlockDurationSliderTransformer"

@implementation SCDurationSlider

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    // Drawing code here.
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder: coder]) {
        [self initializeDurationProperties];
    }
    return self;
}
- (instancetype)init {
    if (self = [super init]) {
        [self initializeDurationProperties];
    }
    return self;
}

- (void)initializeDurationProperties {
    // default: 1 day max
    _maxDuration = 1440;
    _durationIntervalMinutes = 1;
    [self updateSliderBoundsAndNormalizeCurrentValue];

    // register an NSValueTransformer
    [self registerMinutesValueTransformer];
}

- (void)setMaxDuration:(NSInteger)maxDuration {
    _maxDuration = MAX(maxDuration, 1);
    [self updateSliderBoundsAndNormalizeCurrentValue];
}

- (void)setDurationIntervalMinutes:(NSInteger)durationIntervalMinutes {
    _durationIntervalMinutes = MAX(durationIntervalMinutes, 1);
    [self updateSliderBoundsAndNormalizeCurrentValue];
}

- (void)updateSliderBoundsAndNormalizeCurrentValue {
    NSInteger minDuration = MIN(MAX(1, self.durationIntervalMinutes), self.maxDuration);
    [self setMinValue: minDuration];
    [self setMaxValue: self.maxDuration];
    [self normalizeCurrentValue];
}

- (NSInteger)sanitizedDurationMinutesForValue:(NSInteger)candidateMinutes {
    NSInteger minDuration = MAX((NSInteger)lround(self.minValue), 1);
    NSInteger maxDuration = MAX(self.maxDuration, minDuration);
    NSInteger interval = MIN(MAX(self.durationIntervalMinutes, 1), maxDuration);
    
    NSInteger clampedDuration = MIN(MAX(candidateMinutes, minDuration), maxDuration);
    NSInteger snappedDuration = (NSInteger)llround((double)clampedDuration / (double)interval) * interval;
    return MIN(MAX(snappedDuration, minDuration), maxDuration);
}

- (void)normalizeCurrentValue {
    NSInteger sanitizedValue = [self sanitizedDurationMinutesForValue: lroundf(self.floatValue)];
    if (sanitizedValue != lroundf(self.floatValue)) {
        [self setIntegerValue: sanitizedValue];
    }
}

- (void)registerMinutesValueTransformer {
    [NSValueTransformer registerValueTransformerWithName: kValueTransformerName
                                   transformedValueClass: [NSNumber class]
                      returningTransformedValueWithBlock:^id _Nonnull(id  _Nonnull value) {
        // if it's not a number or convertable to one, IDK man
        if (![value respondsToSelector: @selector(floatValue)]) return @0;
        
        long minutesValue = lroundf([value floatValue]);
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        NSInteger maxDuration = [defaults integerForKey: @"MaxBlockLength"];
        if (maxDuration < 1) {
            maxDuration = 1440;
        }
        
        NSInteger interval = [defaults integerForKey: @"BlockDurationSliderIntervalMinutes"];
        interval = MIN(MAX(interval, 1), maxDuration);
        
        NSInteger minDuration = MIN(MAX(1, interval), maxDuration);
        minutesValue = MIN(MAX(minutesValue, minDuration), maxDuration);
        minutesValue = lround((double)minutesValue / (double)interval) * interval;
        minutesValue = MIN(MAX(minutesValue, minDuration), maxDuration);
        return @(minutesValue);
    }];
}

- (NSInteger)durationValueMinutes {
    [self normalizeCurrentValue];
    return lroundf(self.floatValue);
}

- (void)bindDurationToObject:(id)obj keyPath:(NSString*)keyPath {
    [self bind: @"value"
      toObject: obj
   withKeyPath: keyPath
       options: @{
                  NSContinuouslyUpdatesValueBindingOption: @YES,
                  NSValueTransformerNameBindingOption: kValueTransformerName
                  }];
}

- (NSString*)durationDescription {
    return [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: self.durationValueMinutes];
}

// String conversion utility methods

+ (NSString *)timeSliderDisplayStringFromTimeInterval:(NSTimeInterval)numberOfSeconds {
    static SCTimeIntervalFormatter* formatter = nil;
    if (formatter == nil) {
        formatter = [[SCTimeIntervalFormatter alloc] init];
    }

    NSString* formatted = [formatter stringForObjectValue:@(numberOfSeconds)];
    return formatted;
}

+ (NSString *)timeSliderDisplayStringFromNumberOfMinutes:(NSInteger)numberOfMinutes {
    if (numberOfMinutes < 0) return @"Invalid duration";

    static NSCalendar* gregorian = nil;
    if (gregorian == nil) {
        gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    }

    NSRange secondsRangePerMinute = [gregorian
                                     rangeOfUnit:NSCalendarUnitSecond
                                     inUnit:NSCalendarUnitMinute
                                     forDate:[NSDate date]];
    NSInteger numberOfSecondsPerMinute = (NSInteger)NSMaxRange(secondsRangePerMinute);

    NSTimeInterval numberOfSecondsSelected = (NSTimeInterval)(numberOfSecondsPerMinute * numberOfMinutes);

    NSString* displayString = [SCDurationSlider timeSliderDisplayStringFromTimeInterval:numberOfSecondsSelected];
    return displayString;
}


@end
