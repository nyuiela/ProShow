#import "ProShowObjCTry.h"

BOOL ProShowObjCTry(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
