#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NSDictionary *HPCapabilities(void);
NSData *HPScreenshot(void);
NSArray *HPOCR(void);
BOOL HPTap(double x,double y);
BOOL HPKey(NSString *name);
