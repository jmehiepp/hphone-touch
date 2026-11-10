#import "Bridge.h"
#import "IOSurfaceCompat.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>
#include <math.h>
typedef CFTypeRef HIDEvent;
static void *io,*fb;
static void *client;
static void *(*createClient)(CFAllocatorRef);
static void (*dispatchEvent)(void *,HIDEvent);
static HIDEvent (*digitizer)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
static HIDEvent (*finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
static HIDEvent (*keyboard)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,Boolean,uint32_t);
static void (*appendEvent)(HIDEvent,HIDEvent,uint32_t);
static void (*setInt)(HIDEvent,uint32_t,int64_t);
// Modern IOMobileFramebuffer connections are opaque pointers, not 32-bit ports.
typedef struct __IOMobileFramebuffer *HPIOMFBRef;
static int (*mainDisplay)(HPIOMFBRef *);
static int (*surfaceForLayer)(HPIOMFBRef,int,IOSurfaceRef *);
static HPIOMFBRef displayConnection;
static NSObject *captureLock;
static NSDictionary *screenDiagnostics;
static void setup(void) {
    static dispatch_once_t once; dispatch_once(&once,^{
        captureLock=[NSObject new];
        io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
        fb=dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",RTLD_LAZY);
        if(io) {
            createClient=dlsym(io,"IOHIDEventSystemClientCreate"); dispatchEvent=dlsym(io,"IOHIDEventSystemClientDispatchEvent");
            digitizer=dlsym(io,"IOHIDEventCreateDigitizerEvent"); finger=dlsym(io,"IOHIDEventCreateDigitizerFingerEvent");
            keyboard=dlsym(io,"IOHIDEventCreateKeyboardEvent"); appendEvent=dlsym(io,"IOHIDEventAppendEvent");
            setInt=dlsym(io,"IOHIDEventSetIntegerValue");
            if(createClient) client=createClient(kCFAllocatorDefault);
        }
        if(fb) { mainDisplay=dlsym(fb,"IOMobileFramebufferGetMainDisplay"); surfaceForLayer=dlsym(fb,"IOMobileFramebufferGetLayerDefaultSurface"); }
    });
}
static CGImageRef capture(void) {
    setup(); if(!mainDisplay||!surfaceForLayer) return NULL;
    @synchronized(captureLock) {
    if(!displayConnection){int code=mainDisplay(&displayConnection);if(code||!displayConnection){screenDiagnostics=@{@"stage":@"mainDisplay",@"code":@(code)};return NULL;}}
    IOSurfaceRef s=NULL;
    int code=surfaceForLayer(displayConnection,0,&s);
    if(code||!s){screenDiagnostics=@{@"stage":@"displaySurface",@"code":@(code),@"hasSurface":@(s!=NULL)};return NULL;}
    code=IOSurfaceLock(s,kIOSurfaceLockReadOnly,NULL);
    if(code){screenDiagnostics=@{@"stage":@"lockSurface",@"code":@(code)};return NULL;}
    size_t w=IOSurfaceGetWidth(s),h=IOSurfaceGetHeight(s),row=IOSurfaceGetBytesPerRow(s);
    CGImageRef image=NULL;
    if(w&&h&&w<16384&&h<16384&&row>=w*4&&row<128*1024*1024/h&&IOSurfaceGetBaseAddress(s)) {
        CFDataRef bytes=CFDataCreate(NULL,IOSurfaceGetBaseAddress(s),row*h);
        CGDataProviderRef provider=CGDataProviderCreateWithCFData(bytes);
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        image=CGImageCreate(w,h,8,32,row,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(color); CGDataProviderRelease(provider); CFRelease(bytes);
    }
    screenDiagnostics=@{@"stage":image?@"ok":@"pixelFormat",@"width":@(w),@"height":@(h),@"row":@(row)};
    IOSurfaceUnlock(s,kIOSurfaceLockReadOnly,NULL); return image;
    }
}
NSDictionary *HPCapabilities(void) {
    NSDictionary *diagnostics;setup();@synchronized(captureLock){diagnostics=screenDiagnostics?:@{@"stage":@"notTried"};}
    setup(); return @{@"lua":@YES,@"scripts":@YES,@"screenBridgePresent":@(mainDisplay&&surfaceForLayer),
        @"touchBridgePresent":@(client&&digitizer&&finger&&appendEvent&&dispatchEvent),@"keyBridgePresent":@(client&&keyboard&&dispatchEvent),
        @"screenLastCheck":diagnostics,@"deviceValidation":@"required",@"version":@"0.1.2"};
}
NSData *HPScreenshot(void) {
    CGImageRef image=capture(); if(!image) return nil;
    NSMutableData *data=[NSMutableData data]; CGImageDestinationRef dst=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.png"),1,NULL);
    if(!dst) {CGImageRelease(image);return nil;} CGImageDestinationAddImage(dst,image,NULL);
    BOOL ok=CGImageDestinationFinalize(dst); CFRelease(dst); CGImageRelease(image); return ok?data:nil;
}
NSArray *HPOCR(void) {
    CGImageRef image=capture(); if(!image) return nil;
    VNRecognizeTextRequest *request=[VNRecognizeTextRequest new]; request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}]; NSError *error=nil;
    BOOL ok=[handler performRequests:@[request] error:&error]; CGImageRelease(image); if(!ok)return nil;
    NSMutableArray *items=[NSMutableArray array];
    for(VNRecognizedTextObservation *ob in request.results) {
        VNRecognizedText *text=[[ob topCandidates:1] firstObject]; if(text) [items addObject:@{@"text":text.string,@"confidence":@(text.confidence),@"x":@(ob.boundingBox.origin.x),@"y":@(ob.boundingBox.origin.y),@"w":@(ob.boundingBox.size.width),@"h":@(ob.boundingBox.size.height)}];
    } return items;
}
static BOOL touch(double x,double y,BOOL down) {
    setup(); if(!client||!digitizer||!finger||!appendEvent||!dispatchEvent)return NO;
    CGImageRef im=capture(); if(!im)return NO; double w=CGImageGetWidth(im),h=CGImageGetHeight(im); CGImageRelease(im);
    if(!isfinite(x)||!isfinite(y)||x<0||y<0||x>=w||y>=h)return NO;
    HIDEvent parent=digitizer(NULL,mach_absolute_time(),3,0,0,7,0,x/w,y/h,0,0,0,down,down,0);
    HIDEvent child=finger(NULL,mach_absolute_time(),1,2,7,x/w,y/h,0,down?1:0,0,down,down,0);
    if(!parent||!child) {if(parent)CFRelease(parent);if(child)CFRelease(child);return NO;}
    if(setInt)setInt(parent,0xb0019,1);
    appendEvent(parent,child,0); dispatchEvent(client,parent); CFRelease(child);CFRelease(parent); return YES;
}
BOOL HPTap(double x,double y) { if(!touch(x,y,YES))return NO;usleep(50000);return touch(x,y,NO); }
BOOL HPKey(NSString *name) {
    setup(); if(!client||!keyboard||!dispatchEvent)return NO;
    NSDictionary *codes=@{@"home":@0x40,@"power":@0x30,@"volumeUp":@0xe9,@"volumeDown":@0xea}; NSNumber *code=codes[name]; if(!code)return NO;
    for(int i=0;i<2;i++){HIDEvent event=keyboard(NULL,mach_absolute_time(),0xc,code.unsignedIntValue,i==0,0);if(!event)return NO;dispatchEvent(client,event);CFRelease(event);usleep(50000);}return YES;
}
