#import "NAHDTrap.h"

NSException *NAHDTrap(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e;
    }
}
