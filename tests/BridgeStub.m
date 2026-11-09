#import "Bridge.h"
NSDictionary *HPCapabilities(void){return @{@"lua":@YES,@"scripts":@YES,@"testBridge":@YES};}
NSData *HPScreenshot(void){return nil;}
NSArray *HPOCR(void){return nil;}
BOOL HPTap(double x,double y){return NO;}
BOOL HPKey(NSString *key){return NO;}
