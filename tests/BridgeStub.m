#import "Bridge.h"
NSDictionary *HPCapabilities(void){return @{@"lua":@YES,@"scripts":@YES,@"testBridge":@YES};}
NSData *HPScreenshot(void){return nil;}
NSArray *HPOCR(void){return nil;}
BOOL HPTap(double x,double y){return NO;}
BOOL HPKey(NSString *key){return NO;}
static NSDictionary *unavailable(void){return @{@"ok":@NO,@"error":@"Native bridge unavailable in host test",@"code":@"hostTest"};}
NSDictionary *HPInput(NSString *operation,NSDictionary *arguments){return unavailable();}
NSDictionary *HPVisual(NSString *operation,NSDictionary *arguments){return unavailable();}
NSDictionary *HPInputWithCancellation(NSString *operation,NSDictionary *arguments,HPCancellation cancelled){return unavailable();}
NSDictionary *HPVisualWithCancellation(NSString *operation,NSDictionary *arguments,HPCancellation cancelled){return unavailable();}
void HPReleaseInputOwner(NSString *owner){}
NSDictionary *HPOCRWithOptions(NSDictionary *options,HPCancellation cancelled){return unavailable();}
