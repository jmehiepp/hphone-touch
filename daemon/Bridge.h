#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NSDictionary *HPCapabilities(void);
NSData *HPScreenshot(void);
NSArray *HPOCR(void);
BOOL HPTap(double x,double y);
BOOL HPKey(NSString *name);
typedef BOOL (^HPCancellation)(void);
NSDictionary *HPInput(NSString *operation,NSDictionary *arguments);
NSDictionary *HPVisual(NSString *operation,NSDictionary *arguments);
NSDictionary *HPInputWithCancellation(NSString *operation,NSDictionary *arguments,HPCancellation cancelled);
NSDictionary *HPVisualWithCancellation(NSString *operation,NSDictionary *arguments,HPCancellation cancelled);
/* Releases only fingers/keys belonging to owner; call on every VM exit. */
void HPReleaseInputOwner(NSString *owner);
/* Pixel extents (top-left), unlike legacy HPOCR's normalized Vision boxes. */
NSDictionary *HPOCRWithOptions(NSDictionary *options,HPCancellation cancelled);
