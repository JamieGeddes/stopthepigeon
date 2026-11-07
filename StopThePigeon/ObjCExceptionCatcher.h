#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns any Objective-C exception it throws, instead of letting
/// it terminate the app. Swift can't catch these itself.
NSException *_Nullable SPCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
