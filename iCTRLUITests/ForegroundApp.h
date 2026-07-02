#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves the bundle identifier of the app currently in the foreground.
/// Uses private XCTest accessibility APIs (same approach as WebDriverAgent).
/// Returns nil if it cannot be determined.
@interface ForegroundApp : NSObject

+ (nullable NSString *)currentBundleID;

/// Lists installed apps as [{bundle_id, name}] via the private
/// LSApplicationWorkspace API. Returns nil if unavailable. `userOnly` filters
/// out system apps when possible.
+ (nullable NSArray<NSDictionary *> *)installedAppsUserOnly:(BOOL)userOnly;

/// Opens an app by bundle id WITHOUT blocking (LSApplicationWorkspace, same as
/// WebDriverAgent). Returns NO immediately if the app can't be opened — no hang.
+ (BOOL)openBundleID:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
