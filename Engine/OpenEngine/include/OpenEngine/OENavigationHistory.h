#import <Foundation/Foundation.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

/// A page's back/forward list, packed as Open's OPNH v1 container
/// (docs/plans/memory-fork.md §7.1; byte-identical to OpenSleep's
/// SleepHistoryContainer): "OPNH", version 1, entry count (1...512), current
/// index, flags (bit 0: page state), 3 zero bytes, then per entry a
/// little-endian UInt32 length and that many bytes of Chromium's session
/// pickle. At most 2 MiB in total. Immutable.
NS_SWIFT_SENDABLE
OE_EXPORT @interface OENavigationHistory : NSObject

/// Validates `container` as OPNH v1 (magic, version, counts, index, flags,
/// reserved bytes, lengths, no trailing bytes, at most 2 MiB). Returns nil
/// if any check fails; a partial history is never accepted. The Chromium
/// pickles inside are decoded only when the history is restored.
- (nullable instancetype)initWithContainer:(NSData*)container;
- (instancetype)init NS_UNAVAILABLE;

/// The OPNH v1 bytes.
@property(nonatomic, readonly, copy) NSData* container;
@property(nonatomic, readonly) NSInteger entryCount;
@property(nonatomic, readonly) NSInteger currentIndex;
/// True if the entries carry scroll position and form values. A capture
/// drops page state when the history would not fit 2 MiB otherwise.
@property(nonatomic, readonly) BOOL hasPageState;
/// The current entry at capture time. nil/empty for a history made from a
/// stored container: keep these in the store next to the container.
@property(nonatomic, readonly, copy, nullable) NSURL* currentURL;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy, nullable) NSURL* faviconURL;
@end

/// How a web content created with a navigation history came up.
typedef NS_ENUM(NSInteger, OENavigationHistoryRestore) {
  /// Not created with a history.
  OENavigationHistoryRestoreNone = 0,
  /// Waiting for the page to be created (the view enters a window).
  OENavigationHistoryRestorePending,
  /// The history is installed; the current entry loads when the page shows.
  OENavigationHistoryRestoreRestored,
  /// The engine could not install it (an entry did not decode, for example
  /// after an engine update, or a Chrome style page outside an OEBrowser).
  /// The page loaded the fallback URL instead, with no back/forward list.
  OENavigationHistoryRestoreFailed,
};

NS_HEADER_AUDIT_END(nullability, sendability)
