#import "Bridge.h"
#import "IOSurfaceCompat.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>
#include <math.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
typedef CFTypeRef HIDEvent;
static void *io,*fb,*quartz;
static void *client;
static void *(*createClient)(CFAllocatorRef);
static void (*dispatchEvent)(void *,HIDEvent);
static HIDEvent (*digitizer)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
static HIDEvent (*finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
static HIDEvent (*keyboard)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,Boolean,uint32_t);
static void (*appendEvent)(HIDEvent,HIDEvent,uint32_t);
static void (*setInt)(HIDEvent,uint32_t,int64_t);
static void (*setSender)(HIDEvent,uint64_t);
// Modern IOMobileFramebuffer connections are opaque pointers, not 32-bit ports.
typedef struct __IOMobileFramebuffer *HPIOMFBRef;
static int (*mainDisplay)(HPIOMFBRef *);
static int (*surfaceForLayer)(HPIOMFBRef,int,IOSurfaceRef *);
static void (*displaySize)(HPIOMFBRef,CGSize *);
static void (*renderDisplay)(int,CFStringRef,IOSurfaceRef,int,int);
static HPIOMFBRef displayConnection;
static NSObject *captureLock;
static NSDictionary *screenDiagnostics;
static NSLock *ocrLock;
static int diagnosticFD=-1;
static void crashTrace(int sig) {
    if(diagnosticFD>=0){void *frames[48];int count=backtrace(frames,48);backtrace_symbols_fd(frames,count,diagnosticFD);fsync(diagnosticFD);}
    signal(sig,SIG_DFL);raise(sig);
}
static void traceStage(const char *stage){if(diagnosticFD>=0)write(diagnosticFD,stage,strlen(stage));}
static void setup(void) {
    static dispatch_once_t once; dispatch_once(&once,^{
        captureLock=[NSObject new];
        ocrLock=[NSLock new];
        diagnosticFD=open("/var/mobile/Library/HPhoneTouch/native-diagnostic.log",O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600);
        if(diagnosticFD>=0){signal(SIGSEGV,crashTrace);signal(SIGABRT,crashTrace);}
        io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
        fb=dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",RTLD_LAZY);
        quartz=dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore",RTLD_LAZY);
        if(quartz)renderDisplay=dlsym(quartz,"CARenderServerRenderDisplay");
        if(io) {
            createClient=dlsym(io,"IOHIDEventSystemClientCreate"); dispatchEvent=dlsym(io,"IOHIDEventSystemClientDispatchEvent");
            digitizer=dlsym(io,"IOHIDEventCreateDigitizerEvent"); finger=dlsym(io,"IOHIDEventCreateDigitizerFingerEvent");
            keyboard=dlsym(io,"IOHIDEventCreateKeyboardEvent"); appendEvent=dlsym(io,"IOHIDEventAppendEvent");
            setInt=dlsym(io,"IOHIDEventSetIntegerValue");
            setSender=dlsym(io,"IOHIDEventSetSenderID");
            if(createClient) client=createClient(kCFAllocatorDefault);
        }
        if(fb) { mainDisplay=dlsym(fb,"IOMobileFramebufferGetMainDisplay"); surfaceForLayer=dlsym(fb,"IOMobileFramebufferGetLayerDefaultSurface"); displaySize=dlsym(fb,"IOMobileFramebufferGetDisplaySize"); }
    });
}
static CGImageRef capture(void) {
    setup(); if(!mainDisplay||!surfaceForLayer) return NULL;
    @synchronized(captureLock) {
    if(!displayConnection){int code=mainDisplay(&displayConnection);if(code||!displayConnection){screenDiagnostics=@{@"stage":@"mainDisplay",@"code":@(code)};return NULL;}}
    IOSurfaceRef s=NULL;
    int code=surfaceForLayer(displayConnection,0,&s);
    BOOL owned=NO;NSString *method=@"framebuffer";
    if(code||!s){
        // iOS may deny direct framebuffer reads to mobile. Render into an owned surface.
        CGSize size=CGSizeZero;if(displaySize)displaySize(displayConnection,&size);
        if(!renderDisplay||!isfinite(size.width)||!isfinite(size.height)||size.width<1||size.height<1||size.width>8192||size.height>8192){screenDiagnostics=@{@"stage":@"displaySurface",@"code":@(code),@"width":@(size.width),@"height":@(size.height)};return NULL;}
        size_t width=(size_t)size.width,height=(size_t)size.height,row=(width*4+63)&~(size_t)63;
        if(row*height>128*1024*1024)return NULL;
        NSDictionary *properties=@{(__bridge NSString *)kIOSurfaceWidth:@(width),(__bridge NSString *)kIOSurfaceHeight:@(height),(__bridge NSString *)kIOSurfaceBytesPerRow:@(row),(__bridge NSString *)kIOSurfaceBytesPerElement:@4,(__bridge NSString *)kIOSurfaceAllocSize:@(row*height),(__bridge NSString *)kIOSurfacePixelFormat:@(0x42475241)};
        s=IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if(!s){screenDiagnostics=@{@"stage":@"createRenderSurface"};return NULL;}
        owned=YES;method=@"renderServer";
        int lockResult=IOSurfaceLock(s,0,NULL);
        if(lockResult){CFRelease(s);screenDiagnostics=@{@"stage":@"lockRenderSurface",@"code":@(lockResult)};return NULL;}
        renderDisplay(0,CFSTR("LCD"),s,0,0);
        IOSurfaceUnlock(s,0,NULL);
    }
    code=IOSurfaceLock(s,kIOSurfaceLockReadOnly,NULL);
    if(code){if(owned)CFRelease(s);screenDiagnostics=@{@"stage":@"lockSurface",@"code":@(code)};return NULL;}
    size_t w=IOSurfaceGetWidth(s),h=IOSurfaceGetHeight(s),row=IOSurfaceGetBytesPerRow(s);
    CGImageRef image=NULL;
    if(w&&h&&w<16384&&h<16384&&row>=w*4&&row<128*1024*1024/h&&IOSurfaceGetBaseAddress(s)) {
        CFDataRef bytes=CFDataCreate(NULL,IOSurfaceGetBaseAddress(s),row*h);
        CGDataProviderRef provider=CGDataProviderCreateWithCFData(bytes);
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        image=CGImageCreate(w,h,8,32,row,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(color); CGDataProviderRelease(provider); CFRelease(bytes);
    }
    screenDiagnostics=@{@"stage":image?@"ok":@"pixelFormat",@"method":method,@"width":@(w),@"height":@(h),@"row":@(row)};
    IOSurfaceUnlock(s,kIOSurfaceLockReadOnly,NULL);if(owned)CFRelease(s);return image;
    }
}
NSDictionary *HPCapabilities(void) {
    NSDictionary *diagnostics;setup();@synchronized(captureLock){diagnostics=screenDiagnostics?:@{@"stage":@"notTried"};}
    setup(); return @{@"lua":@YES,@"scripts":@YES,@"screenBridgePresent":@(mainDisplay&&surfaceForLayer),
        @"touchBridgePresent":@(client&&digitizer&&finger&&appendEvent&&dispatchEvent),@"keyBridgePresent":@(client&&keyboard&&dispatchEvent),
        @"screenLastCheck":diagnostics,@"ocrMode":@"fast-cpu",@"deviceValidation":@"required",@"version":@"0.1.8"};
}
NSData *HPScreenshot(void) {
    NSData *png=HPScreenshot(); if(!png)return nil;
    NSMutableData *data=[NSMutableData data]; CGImageDestinationRef dst=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.png"),1,NULL);
    if(!dst) {CGImageRelease(image);return nil;} CGImageDestinationAddImage(dst,image,NULL);
    BOOL ok=CGImageDestinationFinalize(dst); CFRelease(dst); CGImageRelease(image); return ok?data:nil;
}
NSArray *HPOCR(void) {
    setup();if(![ocrLock tryLock])return nil;
    @try {
    traceStage("OCR capture\n");
    CGImageRef image=capture(); if(!image) return nil;
    traceStage("OCR request init\n");
    VNRecognizeTextRequest *request=[VNRecognizeTextRequest new]; request.recognitionLevel=VNRequestTextRecognitionLevelFast;
    request.usesCPUOnly=YES;
    traceStage("OCR handler init\n");
    CIContext *context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithData:png options:@{VNImageOptionCIContext:context}]; NSError *error=nil;
    traceStage("OCR perform\n");
    BOOL ok=[handler performRequests:@[request] error:&error];if(!ok)return nil;
    traceStage("OCR results\n");
    NSMutableArray *items=[NSMutableArray array];
    for(VNRecognizedTextObservation *ob in request.results) {
        VNRecognizedText *text=[[ob topCandidates:1] firstObject]; if(text) [items addObject:@{@"text":text.string,@"confidence":@(text.confidence),@"x":@(ob.boundingBox.origin.x),@"y":@(ob.boundingBox.origin.y),@"w":@(ob.boundingBox.size.width),@"h":@(ob.boundingBox.size.height)}];
    } return items;
    } @catch(NSException *exception) {return nil;} @finally {[ocrLock unlock];}
}
static BOOL touch(double x,double y,BOOL down) {
    setup(); if(!client||!digitizer||!finger||!appendEvent||!dispatchEvent)return NO;
    CGImageRef im=capture(); if(!im)return NO; double w=CGImageGetWidth(im),h=CGImageGetHeight(im); CGImageRelease(im);
    if(!isfinite(x)||!isfinite(y)||x<0||y<0||x>=w||y>=h)return NO;
    uint32_t parentMask=down?0x23:0x27;
    HIDEvent parent=digitizer(NULL,mach_absolute_time(),3,1u<<22,1,parentMask,0,x/w,y/h,0,0,0,false,false,0);
    HIDEvent child=finger(NULL,mach_absolute_time(),3,2,3,x/w,y/h,0,0,0,down,down,0);
    if(!parent||!child) {if(parent)CFRelease(parent);if(child)CFRelease(child);return NO;}
    if(setInt){setInt(parent,4,1);setInt(parent,0xb0019,1);}
    if(setSender)setSender(parent,UINT64_C(0x8000000817319372));
    appendEvent(parent,child,0); dispatchEvent(client,parent); CFRelease(child);CFRelease(parent); return YES;
}
BOOL HPTap(double x,double y) { if(!touch(x,y,YES))return NO;usleep(50000);return touch(x,y,NO); }
BOOL HPKey(NSString *name) {
    setup(); if(!client||!keyboard||!dispatchEvent)return NO;
    NSDictionary *codes=@{@"home":@0x40,@"power":@0x30,@"volumeUp":@0xe9,@"volumeDown":@0xea}; NSNumber *code=codes[name]; if(!code)return NO;
    for(int i=0;i<2;i++){HIDEvent event=keyboard(NULL,mach_absolute_time(),0xc,code.unsignedIntValue,i==0,0);if(!event)return NO;dispatchEvent(client,event);CFRelease(event);usleep(50000);}return YES;
}
