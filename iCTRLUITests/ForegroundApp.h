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

/// Opens an arbitrary URL (any scheme, with query) from inside the XCTest runner,
/// where UIApplication.openURL is unreliable. Uses LSApplicationWorkspace's
/// openSensitiveURL:/openURL: private APIs. Returns YES on success.
+ (BOOL)openURL:(NSURL *)url;

/// Activate an app by bundle id, catching any XCTest NSException (which Swift
/// cannot catch and which would otherwise abort the whole runner). Returns YES if
/// activation was attempted without throwing. Must be safe to call off-main.
+ (BOOL)safeActivateBundleID:(NSString *)bundleId;

/// Terminate an app by bundle id, catching any XCTest NSException. Returns YES if
/// termination was attempted without throwing.
+ (BOOL)safeTerminateBundleID:(NSString *)bundleId;

/// Returns the XCUIApplicationState raw value for a bundle id, caught safely:
///   0 = unknown, 1 = notRunning, 2 = runningBackgroundSuspended,
///   3 = runningBackground, 4 = runningForeground.
/// Used to tell "app crashed/closed" from "app just not frontmost".
+ (NSInteger)appStateForBundleID:(NSString *)bundleId;

/// Whether a system alert / permission dialog is currently on screen (owned by
/// SpringBoard, covering the app). When true, actions should target the system
/// UI to dismiss it first. Caught safely; returns NO on any error.
+ (BOOL)hasSystemAlert;

@end

NS_ASSUME_NONNULL_END
