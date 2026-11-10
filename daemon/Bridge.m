#import "Bridge.h"
#import "IOSurfaceCompat.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import "ScreenAlgorithms.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>
#include <math.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>
#include <stdlib.h>
#include <stdbool.h>
#include <roothide.h>
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
static NSRecursiveLock *inputLock;
static NSObject *visualLock;
static NSMutableDictionary *fingers,*heldKeys,*keptScreens;
static BOOL loadTesseract(void);
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
        inputLock=[NSRecursiveLock new];visualLock=[NSObject new];
        fingers=[NSMutableDictionary new];heldKeys=[NSMutableDictionary new];keptScreens=[NSMutableDictionary new];
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
        @"screenLastCheck":diagnostics,@"ocrMode":@"fast-cpu-pixelbuffer",@"tesseractRuntimePresent":@(loadTesseract()),
        @"inputOperations":@[@"tap",@"doubleTap",@"longPress",@"touchDown",@"touchMove",@"touchUp",@"swipe",@"swipeHold",@"swipePath",@"pinch",@"keyPress",@"keyDown",@"keyUp",@"inputText",@"releaseAll"],
        @"visualOperations":@[@"resolution",@"keepScreen",@"getColor",@"getColors",@"findColor",@"findColors",@"matchColors",@"colorCount",@"findImage",@"screenshot"],
        @"deviceValidation":@"required",@"version":@"0.2.1"};
}
NSData *HPScreenshot(void) {
    CGImageRef image=capture(); if(!image) return nil;
    NSMutableData *data=[NSMutableData data]; CGImageDestinationRef dst=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.png"),1,NULL);
    if(!dst) {CGImageRelease(image);return nil;} CGImageDestinationAddImage(dst,image,NULL);
    BOOL ok=CGImageDestinationFinalize(dst); CFRelease(dst); CGImageRelease(image); return ok?data:nil;
}
NSArray *HPOCR(void) {
    setup();if(![ocrLock tryLock])return nil;
    @try {
    traceStage("OCR capture\n");
    CGImageRef image=capture();if(!image)return nil;
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),sourceRow=CGImageGetBytesPerRow(image);
    CFDataRef source=CGDataProviderCopyData(CGImageGetDataProvider(image));CGImageRelease(image);
    if(!source||CFDataGetLength(source)<sourceRow*height){if(source)CFRelease(source);return nil;}
    CVPixelBufferRef pixels=NULL;
    CVReturn created=CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,NULL,&pixels);
    if(created||!pixels){CFRelease(source);return nil;}
    if(CVPixelBufferLockBaseAddress(pixels,0)){CVPixelBufferRelease(pixels);CFRelease(source);return nil;}
    unsigned char *destination=CVPixelBufferGetBaseAddress(pixels);size_t destinationRow=CVPixelBufferGetBytesPerRow(pixels);
    if(!destination||destinationRow<width*4){CVPixelBufferUnlockBaseAddress(pixels,0);CVPixelBufferRelease(pixels);CFRelease(source);return nil;}
    const unsigned char *bytes=CFDataGetBytePtr(source);
    for(size_t y=0;y<height;y++)memcpy(destination+y*destinationRow,bytes+y*sourceRow,width*4);
    CVPixelBufferUnlockBaseAddress(pixels,0);CFRelease(source);
    traceStage("OCR request init\n");
    VNRecognizeTextRequest *request=[VNRecognizeTextRequest new]; request.recognitionLevel=VNRequestTextRecognitionLevelFast;
    request.usesCPUOnly=YES;
    traceStage("OCR handler init\n");
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixels options:@{}]; NSError *error=nil;
    traceStage("OCR perform\n");
    BOOL ok=[handler performRequests:@[request] error:&error];CVPixelBufferRelease(pixels);if(!ok)return nil;
    traceStage("OCR results\n");
    NSMutableArray *items=[NSMutableArray array];
    for(VNRecognizedTextObservation *ob in request.results) {
        VNRecognizedText *text=[[ob topCandidates:1] firstObject]; if(text) [items addObject:@{@"text":text.string,@"confidence":@(text.confidence),@"x":@(ob.boundingBox.origin.x),@"y":@(ob.boundingBox.origin.y),@"w":@(ob.boundingBox.size.width),@"h":@(ob.boundingBox.size.height)}];
    } return items;
    } @catch(NSException *exception) {return nil;} @finally {[ocrLock unlock];}
}
static NSDictionary *failure(NSString *message){return @{@"error":message?:@"Native operation failed"};}
static BOOL number(id value,double *result){if(![value isKindOfClass:NSNumber.class])return NO;double n=[value doubleValue];if(!isfinite(n))return NO;if(result)*result=n;return YES;}
static double option(NSDictionary *a,NSString *key,double fallback){double v;return a[key]?(number(a[key],&v)?v:NAN):fallback;}
static BOOL bounded(double value,double low,double high){return isfinite(value)&&value>=low&&value<=high;}
static NSString *ownerOf(NSDictionary *a){id owner=a[@"owner"];return [owner isKindOfClass:NSString.class]&&[owner length]&&[owner length]<=160?owner:@"http";}
static BOOL waitFor(double seconds,HPCancellation cancelled){while(seconds>0){if(cancelled&&cancelled())return NO;double tick=fmin(seconds,.01);usleep((useconds_t)(tick*1000000));seconds-=tick;}return !(cancelled&&cancelled());}
static CGSize pixelSize(void){setup();CGSize size=CGSizeZero;@synchronized(captureLock){if(!displayConnection&&mainDisplay)mainDisplay(&displayConnection);if(displayConnection&&displaySize)displaySize(displayConnection,&size);}return size;}
static BOOL validPoint(double x,double y,CGSize size){return isfinite(x)&&isfinite(y)&&x>=0&&y>=0&&x<size.width&&y<size.height;}
/* The changed finger is accompanied by every still-active finger. This is
 * essential for pinch and independent paths: omitting one synthesizes a lift. */
static BOOL sendFinger(int identifier,double x,double y,int phase,NSString *owner,CGSize size){
    if(!client||!digitizer||!finger||!appendEvent||!dispatchEvent||!validPoint(x,y,size))return NO;
    NSNumber *key=@(identifier);NSDictionary *previous=fingers[key];
    if(phase==0&&previous)return NO;
    if(phase!=0&&(!previous||![previous[@"owner"] isEqual:owner]))return NO;
    uint32_t mask=phase==0?0x23:(phase==1?0x24:0x27);
    HIDEvent parent=digitizer(NULL,mach_absolute_time(),3,1u<<22,1,mask,0,x/size.width,y/size.height,0,0,0,false,false,0);
    if(!parent)return NO;
    if(setInt){setInt(parent,4,1);setInt(parent,0xb0019,1);}if(setSender)setSender(parent,UINT64_C(0x8000000817319372));
    NSMutableDictionary *events=[fingers mutableCopy];events[key]=@{@"x":@(x),@"y":@(y),@"owner":owner};BOOL ok=YES;
    for(NSNumber *n in [[events allKeys] sortedArrayUsingSelector:@selector(compare:)]){
        NSDictionary *point=events[n];BOOL down=![n isEqual:key]||phase!=2;
        uint32_t childMask=[n isEqual:key]?(phase==1?4:3):0;
        HIDEvent child=finger(NULL,mach_absolute_time(),n.unsignedIntValue+2,n.unsignedIntValue+1,childMask,[point[@"x"] doubleValue]/size.width,[point[@"y"] doubleValue]/size.height,0,0,0,down,down,0);
        if(!child){ok=NO;break;}appendEvent(parent,child,0);CFRelease(child);
    }
    if(ok){dispatchEvent(client,parent);if(phase==2)[fingers removeObjectForKey:key];else fingers[key]=events[key];}CFRelease(parent);return ok;
}
static BOOL sendKey(uint32_t page,uint32_t usage,BOOL down){if(!client||!keyboard||!dispatchEvent)return NO;HIDEvent event=keyboard(NULL,mach_absolute_time(),page,usage,down,0);if(!event)return NO;dispatchEvent(client,event);CFRelease(event);return YES;}
static BOOL keyCode(NSString *name,uint32_t *page,uint32_t *usage,BOOL *shift){
    NSDictionary *consumer=@{@"home":@0x40,@"HOME_BUTTON":@0x40,@"power":@0x30,@"POWER_BUTTON":@0x30,@"volumeUp":@0xe9,@"VOLUME_UP_BUTTON":@0xe9,@"volumeDown":@0xea,@"VOLUME_DOWN_BUTTON":@0xea};
    NSNumber *code=consumer[name];*shift=NO;if(code){*page=0xc;*usage=code.unsignedIntValue;return YES;}
    *page=7;NSDictionary *special=@{@"RETURN":@0x28,@"ENTER":@0x28,@"DELETE":@0x2a,@"BACKSPACE":@0x2a,@"TAB":@0x2b,@"SPACE":@0x2c,@"ESCAPE":@0x29,@"UP":@0x52,@"DOWN":@0x51,@"LEFT":@0x50,@"RIGHT":@0x4f,@"CMD":@0xe3,@"COMMAND":@0xe3,@"SHIFT":@0xe1,@"CTRL":@0xe0,@"ALT":@0xe2};
    code=special[name.uppercaseString];if(code){*usage=code.unsignedIntValue;return YES;}
    if(name.length!=1)return NO;unichar c=[name characterAtIndex:0];
    if(c>='A'&&c<='Z'){*usage=4+c-'A';*shift=YES;return YES;}if(c>='a'&&c<='z'){*usage=4+c-'a';return YES;}
    if(c>='1'&&c<='9'){*usage=0x1e + c-'1';return YES;}if(c=='0'){*usage=0x27;return YES;}
    NSString *normal=@"\n\b\t -=[]\\;'`,./",*shifted=@"\n\b\t _+{}|:\"~<>?";
    const uint32_t usages[]={0x28,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,0x31,0x33,0x34,0x35,0x36,0x37,0x38};
    NSRange r=[normal rangeOfString:name];if(r.location!=NSNotFound){*usage=usages[r.location];return YES;}
    r=[shifted rangeOfString:name];if(r.location!=NSNotFound){*usage=usages[r.location];*shift=YES;return YES;}
    r=[@"!@#$%^&*()" rangeOfString:name];if(r.location!=NSNotFound){*usage=r.location==9?0x27:(uint32_t)(0x1e + r.location);*shift=YES;return YES;}return NO;
}
static BOOL otherShiftHeld(NSString *excluded){for(NSString *key in heldKeys){if([key isEqual:excluded])continue;NSDictionary *p=heldKeys[key];if([p[@"shift"] boolValue]||([p[@"page"] unsignedIntValue]==7&&[p[@"usage"] unsignedIntValue]==0xe1))return YES;}return NO;}
static BOOL releaseHeldKey(NSString *key){NSDictionary *held=heldKeys[key];if(!held)return NO;uint32_t page=[held[@"page"] unsignedIntValue],usage=[held[@"usage"] unsignedIntValue];BOOL sharedShift=otherShiftHeld(key);BOOL ok=page==7&&usage==0xe1&&sharedShift?YES:sendKey(page,usage,NO);[heldKeys removeObjectForKey:key];if([held[@"shift"] boolValue]&&!sharedShift)ok=sendKey(7,0xe1,NO)&&ok;return ok;}
static BOOL keyAction(NSString *name,int phase,NSString *owner){
    uint32_t page,usage;BOOL shift;if(!keyCode(name,&page,&usage,&shift))return NO;
    NSString *key=[NSString stringWithFormat:@"%u:%u",page,usage];NSDictionary *held=heldKeys[key];
    if(phase==0){if(held)return NO;BOOL existingShift=otherShiftHeld(nil);if(shift&&!existingShift&&!sendKey(7,0xe1,YES))return NO;if(!sendKey(page,usage,YES)){if(shift&&!existingShift)sendKey(7,0xe1,NO);return NO;}heldKeys[key]=@{@"page":@(page),@"usage":@(usage),@"shift":@(shift),@"owner":owner};return YES;}
    if(!held||![held[@"owner"] isEqual:owner])return NO;
    return releaseHeldKey(key);
}
void HPReleaseInputOwner(NSString *owner){setup();[inputLock lock];CGSize size=pixelSize();
    for(NSNumber *key in [fingers.allKeys copy]){NSDictionary *p=fingers[key];if([p[@"owner"] isEqual:owner]){sendFinger(key.intValue,[p[@"x"] doubleValue],[p[@"y"] doubleValue],2,owner,size);[fingers removeObjectForKey:key];}}
    for(NSString *key in [heldKeys.allKeys copy]){NSDictionary *p=heldKeys[key];if([p[@"owner"] isEqual:owner])releaseHeldKey(key);}
    [inputLock unlock];@synchronized(visualLock){[keptScreens removeObjectForKey:owner];}
}
static BOOL glide(int identifier,NSArray *points,double milliseconds,int steps,NSString *owner,CGSize size,HPCancellation cancelled){
    NSUInteger segments=points.count-1;int segmentSteps=MAX(1,(int)ceil((double)steps/segments));
    for(NSUInteger index=0;index<segments;index++){NSArray *a=points[index],*b=points[index+1];
        for(int i=1;i<=segmentSteps;i++){if(cancelled&&cancelled())return NO;double f=(double)i/segmentSteps;
            double x=[a[0] doubleValue]+([b[0] doubleValue]-[a[0] doubleValue])*f,y=[a[1] doubleValue]+([b[1] doubleValue]-[a[1] doubleValue])*f;
            if(!sendFinger(identifier,x,y,1,owner,size)||!waitFor(milliseconds/segments/segmentSteps/1000,cancelled))return NO;
        }
    }return YES;
}
NSDictionary *HPInput(NSString *operation,NSDictionary *arguments){return HPInputWithCancellation(operation,arguments,nil);}
NSDictionary *HPInputWithCancellation(NSString *operation,NSDictionary *a,HPCancellation cancelled){
    setup();if(![operation isKindOfClass:NSString.class]||![a isKindOfClass:NSDictionary.class])return failure(@"Invalid native input request");
    // A long gesture must not occupy every HTTP worker waiting for this lock.
    for(int attempt=0;![inputLock tryLock];attempt++){if(cancelled&&cancelled())return failure(@"Stopped by user");if(attempt>=100)return failure(@"Input bridge busy; retry after the current gesture");usleep(10000);}
    NSString *owner=ownerOf(a);BOOL successful=NO,cleanup=NO,cleanupKeys=NO;NSSet *originalFingers=[NSSet setWithArray:fingers.allKeys],*originalKeys=[NSSet setWithArray:heldKeys.allKeys];
    @try{
    if(cancelled&&cancelled())return failure(@"Stopped by user");
    if([operation isEqual:@"releaseAll"]){HPReleaseInputOwner(owner);return @{@"ok":@YES};}
    if([operation isEqual:@"keyPress"]||[operation isEqual:@"keyDown"]||[operation isEqual:@"keyUp"]){
        if(![a[@"key"] isKindOfClass:NSString.class])return failure(@"key must be a known key name");
        if([operation isEqual:@"keyUp"])successful=keyAction(a[@"key"],1,owner);
        else{successful=keyAction(a[@"key"],0,owner);if(successful&&[operation isEqual:@"keyPress"]){waitFor(.05,cancelled);successful=keyAction(a[@"key"],1,owner)&&successful;}}
        return successful?@{@"ok":@YES,@"dispatched":@YES}:failure(@"Key unavailable, already held, or owned by another script");
    }
    if([operation isEqual:@"inputText"]){
        cleanupKeys=YES;
        NSString *text=a[@"text"];double delay=option(a,@"delay_us",30000);if(![text isKindOfClass:NSString.class]||text.length>65536||!bounded(delay,0,1000000))return failure(@"text must have at most 65536 UTF-16 units; delay_us 0..1000000");
        /* The clipboard is only used for non-ASCII input, then Cmd+V is sent.
         * Never claim paste reached the target app: HID dispatch has no ack. */
        BOOL ascii=[text canBeConvertedToEncoding:NSASCIIStringEncoding];
        if(ascii&&text.length*(delay/1000000+.01)>120)return failure(@"ASCII input duration exceeds 120 seconds; split text or reduce delay_us");
        if(!ascii){@try{UIPasteboard.generalPasteboard.string=text;}@catch(NSException *e){return failure(@"Clipboard unavailable for Unicode input");}
            if(!keyAction(@"CMD",0,owner))return failure(@"Keyboard bridge unavailable");
            BOOL ok=keyAction(@"v",0,owner);if(ok){waitFor(.03,cancelled);ok=keyAction(@"v",1,owner);}keyAction(@"CMD",1,owner);if(!ok)return failure(@"Paste shortcut could not be dispatched");
        }else for(NSUInteger i=0;i<text.length;i++){if(cancelled&&cancelled())return failure(@"Stopped by user");NSString *ch=[text substringWithRange:NSMakeRange(i,1)];if(!keyAction(ch,0,owner))return failure(@"Text contains an unsupported ASCII control character");waitFor(.01,cancelled);BOOL ok=keyAction(ch,1,owner);if(!ok||!waitFor(delay/1000000,cancelled))return failure(@"Input stopped or keyboard bridge unavailable");}
        return @{@"ok":@YES,@"dispatched":@YES,@"method":ascii?@"hid-ascii":@"clipboard-command-v"};
    }
    CGSize size=pixelSize();if(size.width<=0||size.height<=0)return failure(@"Display size unavailable");
    double idValue=option(a,@"id",1);if(!bounded(idValue,1,30)||floor(idValue)!=idValue)return failure(@"finger id must be an integer 1..30");int identifier=(int)idValue;
    if([operation isEqual:@"touchDown"]||[operation isEqual:@"touchMove"]||[operation isEqual:@"touchUp"]){double x=option(a,@"x",NAN),y=option(a,@"y",NAN);if(!validPoint(x,y,size))return failure(@"Coordinates outside screen");int phase=[operation isEqual:@"touchDown"]?0:([operation isEqual:@"touchMove"]?1:2);successful=sendFinger(identifier,x,y,phase,owner,size);return successful?@{@"ok":@YES,@"dispatched":@YES}:failure(@"Touch unavailable or finger state/owner invalid");}
    cleanup=YES;
    if([operation isEqual:@"tap"]||[operation isEqual:@"doubleTap"]||[operation isEqual:@"longPress"]){
        double x=option(a,@"x",NAN),y=option(a,@"y",NAN),count=option(a,@"count",[operation isEqual:@"doubleTap"]?2:1),interval=option(a,@"interval_us",[operation isEqual:@"doubleTap"]?option(a,@"gap_ms",100)*1000:100000),hold=option(a,@"ms",[operation isEqual:@"longPress"]?800:50);
        if(!validPoint(x,y,size)||!bounded(count,1,1000)||floor(count)!=count||!bounded(interval,0,10000000)||!bounded(hold,0,60000)||count*(hold/1000+interval/1000000)>120)return failure(@"Invalid tap coordinate/count/duration (total <=120s)");
        for(int i=0;i<(int)count;i++){if(!sendFinger(identifier,x,y,0,owner,size)||!waitFor(hold/1000,cancelled)||!sendFinger(identifier,x,y,2,owner,size))return failure(@"Touch stopped or unavailable");if(i+1<count&&!waitFor(interval/1000000,cancelled))return failure(@"Stopped by user");}successful=YES;
    }else if([operation isEqual:@"swipe"]||[operation isEqual:@"swipeHold"]||[operation isEqual:@"swipePath"]){
        NSArray *points=a[@"points"];if(![operation isEqual:@"swipePath"])points=@[@[@(option(a,@"x1",NAN)),@(option(a,@"y1",NAN))],@[@(option(a,@"x2",NAN)),@(option(a,@"y2",NAN))]];
        double ms=option(a,@"ms",[operation isEqual:@"swipePath"]?500:300);if([operation isEqual:@"swipeHold"])ms=option(a,@"move_ms",300);double steps=option(a,@"steps",MAX(2,ceil(ms/16))),before=[operation isEqual:@"swipeHold"]?option(a,@"hold_ms",500):0,after=[operation isEqual:@"swipeHold"]?option(a,@"end_hold_ms",0):0;
        if(![points isKindOfClass:NSArray.class]||points.count<2||points.count>4096||!bounded(ms,1,60000)||!bounded(steps,2,4096)||floor(steps)!=steps||!bounded(before,0,60000)||!bounded(after,0,60000)||ms+before+after>120000)return failure(@"Invalid swipe path/duration/steps");
        for(id p in points){double x,y;if(![p isKindOfClass:NSArray.class]||[p count]<2||!number(p[0],&x)||!number(p[1],&y)||!validPoint(x,y,size))return failure(@"Swipe point outside screen");}
        NSArray *first=points.firstObject,*last=points.lastObject;
        successful=sendFinger(identifier,[first[0] doubleValue],[first[1] doubleValue],0,owner,size)&&waitFor(before/1000,cancelled)&&glide(identifier,points,ms,(int)steps,owner,size,cancelled)&&waitFor(after/1000,cancelled)&&sendFinger(identifier,[last[0] doubleValue],[last[1] doubleValue],2,owner,size);
    }else if([operation isEqual:@"pinch"]){
        double cx=option(a,@"cx",NAN),cy=option(a,@"cy",NAN),start=option(a,@"startDist",NAN),end=option(a,@"endDist",NAN),ms=option(a,@"ms",400);if(!bounded(start,1,size.width)||!bounded(end,1,size.width)||!bounded(ms,1,60000)||!validPoint(cx-MAX(start,end)/2,cy,size)||!validPoint(cx+MAX(start,end)/2,cy,size))return failure(@"Invalid pinch endpoints/duration");
        successful=sendFinger(1,cx-start/2,cy,0,owner,size)&&sendFinger(2,cx+start/2,cy,0,owner,size);int steps=MAX(2,(int)ceil(ms/16));
        for(int i=1;successful&&i<=steps;i++){double distance=start+(end-start)*(double)i/steps;successful=sendFinger(1,cx-distance/2,cy,1,owner,size)&&sendFinger(2,cx+distance/2,cy,1,owner,size)&&waitFor(ms/steps/1000,cancelled);}if(successful)successful=sendFinger(1,cx-end/2,cy,2,owner,size)&&sendFinger(2,cx+end/2,cy,2,owner,size);
    }else return failure(@"Unknown input operation");
    return successful?@{@"ok":@YES,@"dispatched":@YES}:failure(cancelled&&cancelled()?@"Stopped by user":@"Touch bridge unavailable or finger occupied");
    }@catch(NSException *exception){return failure(@"Invalid input arguments or native bridge exception");}
    @finally{
        if(cleanup){CGSize size=pixelSize();for(NSNumber *key in [fingers.allKeys copy]){NSDictionary *p=fingers[key];if(![originalFingers containsObject:key]&&[p[@"owner"] isEqual:owner]){sendFinger(key.intValue,[p[@"x"] doubleValue],[p[@"y"] doubleValue],2,owner,size);[fingers removeObjectForKey:key];}}}
        if(cleanupKeys)for(NSString *key in [heldKeys.allKeys copy]){NSDictionary *p=heldKeys[key];if(![originalKeys containsObject:key]&&[p[@"owner"] isEqual:owner])releaseHeldKey(key);}
        [inputLock unlock];
    }
}
BOOL HPTap(double x,double y){return [HPInput(@"tap",@{@"x":@(x),@"y":@(y)})[@"ok"] boolValue];}
BOOL HPKey(NSString *name){return [HPInput(@"keyPress",@{@"key":name?:@""})[@"ok"] boolValue];}

static NSDictionary *pixelsFromImage(CGImageRef image){
    if(!image)return nil;size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),row=width*4;
    if(!width||!height||width>8192||height>8192||row>32*1024*1024/height)return nil;
    NSMutableData *pixels=[NSMutableData dataWithLength:row*height];CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels.mutableBytes,width,height,8,row,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);CGColorSpaceRelease(color);if(!context)return nil;
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);
    return @{@"bytes":pixels,@"width":@(width),@"height":@(height),@"row":@(row)};
}
static HPBitmap bitmap(NSDictionary *snapshot){return (HPBitmap){[snapshot[@"bytes"] bytes],[snapshot[@"width"] unsignedIntegerValue],[snapshot[@"height"] unsignedIntegerValue],[snapshot[@"row"] unsignedIntegerValue]};}
static NSDictionary *screenPixels(NSString *owner){@synchronized(visualLock){if(keptScreens[owner])return keptScreens[owner];}CGImageRef image=capture();NSDictionary *s=pixelsFromImage(image);if(image)CGImageRelease(image);return s;}
static BOOL parseRegion(id object,HPBitmap image,HPRegion *region){*region=(HPRegion){0,0,(int)image.width,(int)image.height};if(!object||object==NSNull.null)return YES;if(![object isKindOfClass:NSArray.class]||[object count]!=4)return NO;double values[4];for(int i=0;i<4;i++)if(!number(object[i],values+i)||floor(values[i])!=values[i]||!bounded(values[i],0,8192))return NO;region->x=(int)values[0];region->y=(int)values[1];region->width=(int)values[2];region->height=(int)values[3];return region->width>0&&region->height>0&&(size_t)region->x<image.width&&(size_t)region->y<image.height&&(size_t)region->width<=image.width-region->x&&(size_t)region->height<=image.height-region->y;}
static BOOL parsePattern(NSArray *colors,HPColorPoint *pattern,int tolerance){if(![colors isKindOfClass:NSArray.class]||!colors.count||colors.count>256)return NO;NSUInteger i=0;for(id p in colors){double c=0,x,y,t=tolerance;BOOL any=NO,invert=NO;if([p isKindOfClass:NSDictionary.class]){any=[p[@"any"] boolValue];invert=[p[@"not"] boolValue];if(!number(p[@"dx"]?:p[@"1"],&x)||!number(p[@"dy"]?:p[@"2"],&y)||(!any&&!number(p[@"color"]?:p[@"0"],&c)))return NO;if(p[@"tolerance"]&&!number(p[@"tolerance"],&t))return NO;}else if([p isKindOfClass:NSArray.class]&&[p count]>=3){if(!number(p[0],&c)||!number(p[1],&x)||!number(p[2],&y))return NO;if([p count]>=4&&!number(p[3],&t))return NO;}else return NO;if(!bounded(c,0,0xffffff)||floor(c)!=c||!bounded(x,-8192,8192)||floor(x)!=x||!bounded(y,-8192,8192)||floor(y)!=y||!bounded(t,0,255)||floor(t)!=t)return NO;pattern[i++]=(HPColorPoint){(uint32_t)c,(int)x,(int)y,(int)t,any,invert};}return YES;}
static int cancelledC(void *context){HPCancellation block=(__bridge HPCancellation)context;return block&&block();}
static NSDictionary *algorithmError(int result){return failure(result==-1?@"Stopped by user":(result==-2?@"Search budget exhausted; use a smaller region, larger step or more distinctive template":@"Invalid pixel search arguments"));}
NSDictionary *HPVisual(NSString *operation,NSDictionary *arguments){return HPVisualWithCancellation(operation,arguments,nil);}
NSDictionary *HPVisualWithCancellation(NSString *operation,NSDictionary *a,HPCancellation cancelled){
    setup();if(![operation isKindOfClass:NSString.class]||![a isKindOfClass:NSDictionary.class])return failure(@"Invalid visual request");if(cancelled&&cancelled())return failure(@"Stopped by user");NSString *owner=ownerOf(a);
    @try{
    if([operation isEqual:@"keepScreen"]){BOOL enabled=[a[@"enabled"] boolValue];if(!enabled){@synchronized(visualLock){[keptScreens removeObjectForKey:owner];}return @{@"ok":@YES,@"enabled":@NO};}NSDictionary *s=screenPixels(owner);if(!s)return failure(@"Screen capture unavailable");@synchronized(visualLock){if(!keptScreens[owner]&&keptScreens.count>=4)return failure(@"At most four screen snapshots may be retained");NSUInteger retained=[s[@"bytes"] length];for(NSString *key in keptScreens)if(![key isEqual:owner])retained+=[keptScreens[key][@"bytes"] length];if(retained>16*1024*1024)return failure(@"Retained screen memory exceeds 16 MiB; release another snapshot");keptScreens[owner]=s;}return @{@"ok":@YES,@"enabled":@YES};}
    if([operation isEqual:@"resolution"]){CGSize size=pixelSize();CGFloat scale=UIScreen.mainScreen.scale;if(size.width<1||size.height<1||scale<=0)return failure(@"Display size unavailable");return @{@"ok":@YES,@"width":@(size.width),@"height":@(size.height),@"scale":@(scale)};}
    NSDictionary *s=screenPixels(owner);if(!s)return failure(@"Screen capture unavailable");HPBitmap im=bitmap(s);HPRegion region;if(!parseRegion(a[@"region"],im,&region))return failure(@"region must be {x,y,width,height} inside the screen");
    if([operation isEqual:@"screenshot"]){CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)s[@"bytes"]);CGImageRef image=CGImageCreate(im.width,im.height,8,32,im.row,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault);CGColorSpaceRelease(color);CGDataProviderRelease(provider);if(!image)return failure(@"PNG encode unavailable");CGImageRef crop=CGImageCreateWithImageInRect(image,CGRectMake(region.x,region.y,region.width,region.height));CGImageRelease(image);if(!crop)return failure(@"Could not crop screen");NSMutableData *png=[NSMutableData new];CGImageDestinationRef dst=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);if(!dst){CGImageRelease(crop);return failure(@"PNG encode unavailable");}CGImageDestinationAddImage(dst,crop,NULL);CGImageRelease(crop);BOOL ok=CGImageDestinationFinalize(dst);CFRelease(dst);return ok?@{@"ok":@YES,@"pngBase64":[png base64EncodedStringWithOptions:0],@"width":@(region.width),@"height":@(region.height)}:failure(@"PNG encode failed");}
    if([operation isEqual:@"getColor"]||[operation isEqual:@"getColors"]){NSArray *points=[operation isEqual:@"getColor"]?@[@[a[@"x"]?:NSNull.null,a[@"y"]?:NSNull.null]]:a[@"points"];if(![points isKindOfClass:NSArray.class]||points.count>10000)return failure(@"points must be an array of at most 10000 coordinates");NSMutableArray *colors=[NSMutableArray new];for(id p in points){double x,y;if(![p isKindOfClass:NSArray.class]||[p count]<2||!number(p[0],&x)||!number(p[1],&y)||floor(x)!=x||floor(y)!=y||!validPoint(x,y,CGSizeMake(im.width,im.height)))return failure(@"Pixel coordinate outside screen");[colors addObject:@(HPColorAt(im,(size_t)x,(size_t)y))];}return [operation isEqual:@"getColor"]?@{@"ok":@YES,@"color":colors.firstObject}:@{@"ok":@YES,@"colors":colors};}
    double tolerance=option(a,@"tolerance",0);if(!bounded(tolerance,0,255)||floor(tolerance)!=tolerance)return failure(@"tolerance must be an integer 0..255");
    if([operation isEqual:@"colorCount"]){double c;if(!number(a[@"color"],&c)||!bounded(c,0,0xffffff)||floor(c)!=c)return failure(@"color must be 0x000000..0xFFFFFF");int64_t n=HPCountColor(im,(uint32_t)c,(int)tolerance,region,cancelledC,(__bridge void *)cancelled);return n>=0?@{@"ok":@YES,@"count":@(n)}:algorithmError((int)n);}
    if([operation isEqual:@"matchColors"]){NSArray *colors=a[@"colors"];if(![colors isKindOfClass:NSArray.class]||colors.count>10000)return failure(@"colors must contain {x,y,color[,tolerance]} rows");for(id p in colors){double x,y,c,t=tolerance;if(![p isKindOfClass:NSArray.class]||[p count]<3||!number(p[0],&x)||!number(p[1],&y)||!number(p[2],&c)||([p count]>3&&!number(p[3],&t))||floor(x)!=x||floor(y)!=y||floor(c)!=c||!validPoint(x,y,CGSizeMake(im.width,im.height))||!bounded(c,0,0xffffff)||!bounded(t,0,255))return failure(@"Invalid absolute color point");if(!HPColorClose(HPColorAt(im,(size_t)x,(size_t)y),(uint32_t)c,(int)t))return @{@"ok":@YES,@"match":@NO};}return @{@"ok":@YES,@"match":@YES};}
    double count=option(a,@"count",0);if(!bounded(count,0,10000)||floor(count)!=count)return failure(@"count must be an integer 0..10000");
    if([operation isEqual:@"findColor"]||[operation isEqual:@"findColors"]){HPColorPoint pattern[256];NSArray *colors=a[@"colors"];if([operation isEqual:@"findColor"])colors=@[@[a[@"color"]?:NSNull.null,@0,@0]];if(!parsePattern(colors,pattern,(int)tolerance))return failure(@"Invalid color pattern (maximum 256 points)");int xy[20000];int n=HPFindColors(im,pattern,colors.count,region,[a[@"rightToLeft"] boolValue],[a[@"bottomToTop"] boolValue],(size_t)count,xy,10000,cancelledC,(__bridge void *)cancelled);if(n<0)return algorithmError(n);NSMutableArray *points=[NSMutableArray new];for(int i=0;i<n;i++)[points addObject:@[@(xy[i*2]),@(xy[i*2+1])]];return @{@"ok":@YES,@"points":points,@"truncated":@(n==10000&&count==0)};}
    if([operation isEqual:@"findImage"]){
        NSString *path=a[@"image"];if(![path isKindOfClass:NSString.class]||!path.isAbsolutePath)return failure(@"image must be an absolute path in HPhoneTouch/scripts");
        char resolved[PATH_MAX],root[PATH_MAX];if(!realpath("/var/mobile/Library/HPhoneTouch/scripts",root)||!realpath(path.fileSystemRepresentation,resolved))return failure(@"Template image missing");NSString *real=[NSString stringWithUTF8String:resolved],*prefix=[[NSString stringWithUTF8String:root] stringByAppendingString:@"/"];if(![real hasPrefix:prefix])return failure(@"Template image must be inside HPhoneTouch/scripts");struct stat st;if(stat(resolved,&st)||!S_ISREG(st.st_mode)||st.st_size>8*1024*1024)return failure(@"Template image must be a regular file <=8 MiB");
        double threshold=option(a,@"threshold",.9),step=option(a,@"step",1);if(!bounded(threshold,0,1)||!bounded(step,1,8192)||floor(step)!=step)return failure(@"threshold must be 0..1; step an integer 1..8192");
        CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:real],NULL);if(!source)return failure(@"Template PNG/JPEG could not be decoded");NSDictionary *metadata=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));double w=[metadata[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue],h=[metadata[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];if(w<1||h<1||w>2048||h>2048){CFRelease(source);return failure(@"Template dimensions must be 1..2048 pixels");}CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL);CFRelease(source);NSDictionary *p=pixelsFromImage(image);if(image)CGImageRelease(image);if(!p)return failure(@"Template image decode failed");HPImageMatch *matches=calloc(1000,sizeof(HPImageMatch));if(!matches)return failure(@"Template search memory unavailable");int n=HPFindImage(im,bitmap(p),region,threshold,(size_t)count,(size_t)step,matches,1000,cancelledC,(__bridge void *)cancelled);NSMutableArray *rows=[NSMutableArray new];if(n>=0)for(int i=0;i<n;i++){HPImageMatch m=matches[i];[rows addObject:@{@"x":@(m.x),@"y":@(m.y),@"w":@(m.width),@"h":@(m.height),@"centerX":@(m.x+m.width/2.0),@"centerY":@(m.y+m.height/2.0),@"score":@(m.score)}];}free(matches);return n<0?algorithmError(n):@{@"ok":@YES,@"matches":rows,@"truncated":@(n==1000&&(count==0||count>1000))};
    }
    return failure(@"Unknown visual operation");
    }@catch(NSException *exception){return failure(@"Invalid visual arguments or native bridge exception");}
}

/* Optional upstream Tesseract ABI. No private Tesseract structures are copied:
 * opaque handles + exported C API keep this compatible with v4 and v5. */
typedef struct {
    void *library;
    void *(*create)(void);void (*destroy)(void *);
    int (*initialize)(void *,const char *,const char *,int);
    void (*setImage)(void *,const unsigned char *,int,int,int,int);
    void (*setMode)(void *,int);int (*setVariable)(void *,const char *,const char *);
    int (*recognize)(void *,void *);void *(*iterator)(void *);
    void (*deleteIterator)(void *);void *(*pageIterator)(void *);
    int (*next)(void *,int);char *(*text)(const void *,int);
    float (*confidence)(const void *,int);int (*box)(const void *,int,int *,int *,int *,int *);
    void (*deleteText)(const char *);
    void *(*monitorCreate)(void);void (*monitorDelete)(void *);
    void (*monitorCancel)(void *,bool (*)(void *,int));void (*monitorContext)(void *,void *);
    void (*monitorDeadline)(void *,int);
} HPTesseractAPI;
static HPTesseractAPI tess;
static BOOL loadTesseract(void){
    static dispatch_once_t once;dispatch_once(&once,^{
        for(NSString *name in @[@"/usr/lib/libtesseract.5.dylib",@"/usr/lib/libtesseract.4.dylib",@"/usr/lib/libtesseract.dylib"]){tess.library=dlopen(jbroot(name).fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);if(tess.library)break;}
        if(!tess.library)return;
#define HP_TESS(field,symbol) tess.field=dlsym(tess.library,symbol)
        HP_TESS(create,"TessBaseAPICreate");HP_TESS(destroy,"TessBaseAPIDelete");HP_TESS(initialize,"TessBaseAPIInit2");
        HP_TESS(setImage,"TessBaseAPISetImage");HP_TESS(setMode,"TessBaseAPISetPageSegMode");HP_TESS(setVariable,"TessBaseAPISetVariable");
        HP_TESS(recognize,"TessBaseAPIRecognize");HP_TESS(iterator,"TessBaseAPIGetIterator");HP_TESS(deleteIterator,"TessResultIteratorDelete");
        HP_TESS(pageIterator,"TessResultIteratorGetPageIterator");HP_TESS(next,"TessResultIteratorNext");HP_TESS(text,"TessResultIteratorGetUTF8Text");
        HP_TESS(confidence,"TessResultIteratorConfidence");HP_TESS(box,"TessPageIteratorBoundingBox");HP_TESS(deleteText,"TessDeleteText");
        HP_TESS(monitorCreate,"TessMonitorCreate");HP_TESS(monitorDelete,"TessMonitorDelete");HP_TESS(monitorCancel,"TessMonitorSetCancelFunc");
        HP_TESS(monitorContext,"TessMonitorSetCancelThis");HP_TESS(monitorDeadline,"TessMonitorSetDeadlineMSecs");
#undef HP_TESS
    });
    return tess.library&&tess.create&&tess.destroy&&tess.initialize&&tess.setImage&&tess.setMode&&tess.setVariable&&tess.recognize&&tess.iterator&&tess.deleteIterator&&tess.pageIterator&&tess.next&&tess.text&&tess.confidence&&tess.box&&tess.deleteText&&tess.monitorCreate&&tess.monitorDelete&&tess.monitorCancel&&tess.monitorContext&&tess.monitorDeadline;
}
typedef struct {__unsafe_unretained HPCancellation cancelled;CFAbsoluteTime deadline;} HPOCRMonitor;
static bool cancelTesseract(void *opaque,int words){(void)words;HPOCRMonitor *m=opaque;return CFAbsoluteTimeGetCurrent()>=m->deadline||(m->cancelled&&m->cancelled());}
static NSDictionary *ocrItem(NSString *text,double confidence,CGRect box){return @{@"text":text?:@"",@"confidence":@(fmax(0,fmin(1,confidence))),@"x":@(box.origin.x),@"y":@(box.origin.y),@"width":@(box.size.width),@"height":@(box.size.height),@"centerX":@(CGRectGetMidX(box)),@"centerY":@(CGRectGetMidY(box))};}
NSDictionary *HPOCRWithOptions(NSDictionary *options,HPCancellation cancelled){
    setup();if(![options isKindOfClass:NSDictionary.class])return failure(@"OCR options must be an object");
    NSString *engine=options[@"engine"]?:@"auto";NSArray *languages=options[@"languages"]?:@[@"en"];NSString *level=options[@"level"]?:@"fast";
    if(![engine isKindOfClass:NSString.class]||![@[@"auto",@"vision",@"tesseract"] containsObject:engine]||![languages isKindOfClass:NSArray.class]||languages.count<1||languages.count>8||![level isKindOfClass:NSString.class]||![@[@"fast",@"accurate"] containsObject:level])return failure(@"OCR requires engine auto/vision/tesseract, level fast/accurate and a language array");
    NSMutableArray *tessLanguages=[NSMutableArray new],*visionLanguages=[NSMutableArray new];BOOL vietnamese=NO,otherLanguage=NO;
    for(id language in languages){if(![language isKindOfClass:NSString.class]||[language length]>32)return failure(@"Invalid OCR language");NSString *name=[language lowercaseString];if([@[@"vi",@"vie",@"vi-vn"] containsObject:name]){vietnamese=YES;[tessLanguages addObject:@"vie"];[visionLanguages addObject:@"vi-VN"];}else if([@[@"en",@"eng",@"en-us",@"en-gb"] containsObject:name]){[tessLanguages addObject:@"eng"];[visionLanguages addObject:@"en-US"];}else{otherLanguage=YES;[visionLanguages addObject:language];}}
    if([engine isEqual:@"auto"])engine=vietnamese?@"tesseract":@"vision";
    if([engine isEqual:@"tesseract"]&&otherLanguage)return failure(@"Bundled Tesseract models support English and Vietnamese only");
    if([engine isEqual:@"vision"]&&vietnamese)return failure(@"Vietnamese requires engine=tesseract on iOS 15");
    double deadlineMS=option(options,@"timeout_ms",15000);if(!bounded(deadlineMS,100,30000))return failure(@"OCR timeout_ms must be 100..30000");if(cancelled&&cancelled())return failure(@"Stopped by user");
    if(![ocrLock tryLock])return failure(@"An OCR request is already running");
    void *api=NULL,*iterator=NULL,*monitor=NULL;CVPixelBufferRef pixels=NULL;
    @try{
        NSDictionary *snapshot=screenPixels(ownerOf(options));if(!snapshot)return failure(@"Screen capture unavailable");HPBitmap source=bitmap(snapshot);HPRegion region;if(!parseRegion(options[@"region"],source,&region))return failure(@"OCR region must be inside screen");
        BOOL words=[options[@"words"] boolValue];NSMutableArray *items=[NSMutableArray new];
        if([engine isEqual:@"tesseract"]){
            if(!loadTesseract())return failure(@"Tesseract runtime missing: install the compatible libtesseract package in Sileo and restart HPhone Touch daemon");
            NSString *dataPath=jbroot(@"/usr/share/hphone-touch/tessdata");
            for(NSString *language in tessLanguages){NSString *file=[dataPath stringByAppendingPathComponent:[language stringByAppendingString:@".traineddata"]];if(![NSFileManager.defaultManager isReadableFileAtPath:file])return failure(@"Pinned Tesseract language models missing; reinstall HPhone Touch");}
            traceStage("Tesseract initialize\n");api=tess.create();if(!api)return failure(@"Tesseract allocation failed");
            tess.setVariable(api,"debug_file","/dev/null");
            if(tess.initialize(api,dataPath.fileSystemRepresentation,[[tessLanguages componentsJoinedByString:@"+"] UTF8String],1))return failure(@"Tesseract language initialization failed");
            size_t row=(size_t)region.width*3;NSMutableData *rgb=[NSMutableData dataWithLength:row*(size_t)region.height];unsigned char *destination=rgb.mutableBytes;
            for(int y=0;y<region.height;y++){if(cancelled&&cancelled())return failure(@"Stopped by user");const uint8_t *p=source.bytes+(size_t)(region.y+y)*source.row+(size_t)region.x*4;for(int x=0;x<region.width;x++){size_t offset=(size_t)y*row+(size_t)x*3;destination[offset]=p[x*4+2];destination[offset+1]=p[x*4+1];destination[offset+2]=p[x*4];}}
            tess.setImage(api,rgb.bytes,region.width,region.height,3,(int)row);tess.setMode(api,11);tess.setVariable(api,"user_defined_dpi","300");
            monitor=tess.monitorCreate();if(!monitor)return failure(@"Tesseract progress monitor unavailable");HPOCRMonitor context={cancelled,CFAbsoluteTimeGetCurrent()+deadlineMS/1000};tess.monitorCancel(monitor,cancelTesseract);tess.monitorContext(monitor,&context);tess.monitorDeadline(monitor,(int)deadlineMS);
            traceStage("Tesseract recognize\n");int result=tess.recognize(api,monitor);if(result||cancelTesseract(&context,0))return failure(cancelled&&cancelled()?@"Stopped by user":@"Tesseract recognition failed or exceeded its deadline");
            iterator=tess.iterator(api);int itemLevel=words?3:2;
            if(iterator)do{if(cancelled&&cancelled())return failure(@"Stopped by user");int left,top,right,bottom;void *page=tess.pageIterator(iterator);if(!page||!tess.box(page,itemLevel,&left,&top,&right,&bottom))continue;char *text=tess.text(iterator,itemLevel);NSString *value=text?[[NSString stringWithUTF8String:text] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:nil;if(text)tess.deleteText(text);if(value.length)[items addObject:ocrItem(value,tess.confidence(iterator,itemLevel)/100.0,CGRectMake(region.x+left,region.y+top,right-left,bottom-top))];if(items.count>=10000)break;}while(tess.next(iterator,itemLevel));
            traceStage("Tesseract complete\n");
        }else{
            /* Same CPU/CVPixelBuffer path as the verified legacy route. Never
             * construct a CIImage/CIContext in this mobile launch daemon. */
            if(CVPixelBufferCreate(kCFAllocatorDefault,(size_t)region.width,(size_t)region.height,kCVPixelFormatType_32BGRA,NULL,&pixels)||!pixels)return failure(@"OCR pixel buffer allocation failed");
            if(CVPixelBufferLockBaseAddress(pixels,0))return failure(@"OCR pixel buffer lock failed");uint8_t *destination=CVPixelBufferGetBaseAddress(pixels);size_t row=CVPixelBufferGetBytesPerRow(pixels);if(!destination||row<(size_t)region.width*4){CVPixelBufferUnlockBaseAddress(pixels,0);return failure(@"OCR pixel buffer layout unavailable");}
            for(int y=0;y<region.height;y++)memcpy(destination+(size_t)y*row,source.bytes+(size_t)(region.y+y)*source.row+(size_t)region.x*4,(size_t)region.width*4);CVPixelBufferUnlockBaseAddress(pixels,0);
            VNRecognizeTextRequest *request=[VNRecognizeTextRequest new];request.recognitionLevel=[level isEqual:@"accurate"]?VNRequestTextRecognitionLevelAccurate:VNRequestTextRecognitionLevelFast;request.usesCPUOnly=YES;request.recognitionLanguages=visionLanguages;
            VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixels options:@{}];NSError *error=nil;
            traceStage("Vision options recognize\n");if(![handler performRequests:@[request] error:&error])return failure(@"Vision recognition failed; check language support for this iOS version");if(cancelled&&cancelled())return failure(@"Stopped by user");
            for(VNRecognizedTextObservation *ob in request.results){VNRecognizedText *text=[ob topCandidates:1].firstObject;if(!text)continue;
                if(words){[text.string enumerateSubstringsInRange:NSMakeRange(0,text.string.length) options:NSStringEnumerationByWords usingBlock:^(NSString *word,NSRange range,NSRange enclosing,BOOL *stop){(void)enclosing;(void)stop;VNRectangleObservation *rectangle=[text boundingBoxForRange:range error:NULL];if(!rectangle)return;CGRect box=rectangle.boundingBox;box=CGRectMake(region.x+box.origin.x*region.width,region.y+(1-CGRectGetMaxY(box))*region.height,box.size.width*region.width,box.size.height*region.height);[items addObject:ocrItem(word,text.confidence,box)];}];}
                else{CGRect box=ob.boundingBox;box=CGRectMake(region.x+box.origin.x*region.width,region.y+(1-CGRectGetMaxY(box))*region.height,box.size.width*region.width,box.size.height*region.height);[items addObject:ocrItem(text.string,text.confidence,box)];}
                if(items.count>=10000)break;
            }
        }
        return @{@"ok":@YES,@"engine":engine,@"items":items};
    }@catch(NSException *exception){return failure(@"OCR native exception");}
    @finally{if(iterator)tess.deleteIterator(iterator);if(monitor)tess.monitorDelete(monitor);if(api)tess.destroy(api);if(pixels)CVPixelBufferRelease(pixels);[ocrLock unlock];}
}
