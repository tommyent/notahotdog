#import <Foundation/Foundation.h>

// Not NS_NOESCAPE: Swift's escape verification aborted the app here on macOS 27.
NSException * _Nullable NAHDTrap(void (^ _Nonnull block)(void));
