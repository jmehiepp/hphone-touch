// Owner-authorized, USB-launched installer adapter. No network listener.
// Loaded only into a development-entitled TrollStore persistence helper.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <math.h>
#import <objc/message.h>
extern char **environ;

static NSString *const directory = @"/var/mobile/Media/RootHideFleet";
static NSString *const officialHelperSHA = @"3634607f8165fb41c6844cb0b7608f38ee1f51c2e96e353ed13d4c76a28aa1bd";
static NSString *const developmentIPASHA = @"22b48e78111d2885c621c36fb4bac6c042fed7ea50de84b0f842943129742d65";

// Runs in the temporary platform helper, which has container-manager access.
// House Arrest cannot vend a TrollStore app registered as a System app.
static BOOL prepareRootHideSileo(void) {
    Class proxyClass=NSClassFromString(@"LSApplicationProxy");
    SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if(!proxyClass||![proxyClass respondsToSelector:lookup])return NO;
    id proxy=((id(*)(id,SEL,id))objc_msgSend)(proxyClass,lookup,@"com.opa334.Dopamine-roothide");
    SEL dataSelector=NSSelectorFromString(@"dataContainerURL");
    if(![proxy respondsToSelector:dataSelector])return NO;
    NSURL *url=((id(*)(id,SEL))objc_msgSend)(proxy,dataSelector);
    if(![url isKindOfClass:NSURL.class]||!url.isFileURL)return NO;
    NSString *base=url.URLByResolvingSymlinksInPath.path;
    if(![base hasPrefix:@"/private/var/mobile/Containers/Data/Application/"] && ![base hasPrefix:@"/var/mobile/Containers/Data/Application/"])return NO;
    NSString *preferencesDirectory=[base stringByAppendingPathComponent:@"Library/Preferences"];
    NSString *path=[preferencesDirectory stringByAppendingPathComponent:@"com.opa334.Dopamine.plist"];
    NSMutableDictionary *preferences=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if(!preferences && [[NSFileManager defaultManager] fileExistsAtPath:path])return NO;
    if(!preferences)preferences=[NSMutableDictionary new];
    if([preferences[@"removeJailbreakEnabled"] boolValue])return NO;
    preferences[@"enabledPkgManagers"]=@[@"org.coolstar.SileoStore"];
    if(![[NSFileManager defaultManager] createDirectoryAtPath:preferencesDirectory withIntermediateDirectories:YES attributes:nil error:nil])return NO;
    if(![preferences writeToFile:path atomically:YES])return NO;
    return [[NSDictionary dictionaryWithContentsOfFile:path] isEqualToDictionary:preferences];
}

static BOOL verify(NSString *path, NSString *sha) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length > 128 * 1024 * 1024) return NO;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *actual = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [actual appendFormat:@"%02x", hash[i]];
    return [actual isEqualToString:sha];
}

static int rootCommand(NSString *helper, NSString *command, NSString *argument) {
    int (*persona)(posix_spawnattr_t *, uid_t, uint32_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    int (*uid)(posix_spawnattr_t *, uid_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    int (*gid)(posix_spawnattr_t *, gid_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!persona || !uid || !gid) return -100;
    posix_spawnattr_t attr;
    int result = posix_spawnattr_init(&attr);
    if (result) return result;
    if ((result = persona(&attr, 99, 1)) || (result = uid(&attr, 0)) || (result = gid(&attr, 0))) {
        posix_spawnattr_destroy(&attr); return result;
    }
    char *argv[] = {(char *)helper.fileSystemRepresentation, (char *)command.UTF8String, (char *)argument.fileSystemRepresentation, NULL};
    pid_t child;
    result = posix_spawn(&child, argv[0], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (result) return result;
    int status;
    if (waitpid(child, &status, 0) != child) return -101;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -102;
}

// Single bounded HID events, derived from HPhone Touch's published bridge.
// PC automation observes the foreground screen before requesting an event.
static int inputEvent(NSString *action) {
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io) return -120;
    void *(*create)(CFAllocatorRef) = dlsym(io,"IOHIDEventSystemClientCreate");
    void (*send)(void *,CFTypeRef) = dlsym(io,"IOHIDEventSystemClientDispatchEvent");
    if (!create || !send) return -121;
    void *client = create(kCFAllocatorDefault); if (!client) return -122;
    if ([action isEqualToString:@"tap-observed-element"]) {
        const char *xs=getenv("HPHONE_FLEET_X"), *ys=getenv("HPHONE_FLEET_Y");
        if (!xs || !ys) return -123;
        double x=atof(xs),y=atof(ys); if (!isfinite(x)||!isfinite(y)||x<0||x>=1||y<0||y>=1) return -124;
        CFTypeRef (*parentEvent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t)=dlsym(io,"IOHIDEventCreateDigitizerEvent");
        CFTypeRef (*fingerEvent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t)=dlsym(io,"IOHIDEventCreateDigitizerFingerEvent");
        void (*append)(CFTypeRef,CFTypeRef,uint32_t)=dlsym(io,"IOHIDEventAppendEvent");
        void (*setInt)(CFTypeRef,uint32_t,int64_t)=dlsym(io,"IOHIDEventSetIntegerValue");
        void (*sender)(CFTypeRef,uint64_t)=dlsym(io,"IOHIDEventSetSenderID");
        if (!parentEvent||!fingerEvent||!append) return -125;
        for (int phase=0;phase<2;phase++) {
            Boolean down=phase==0;
            CFTypeRef parent=parentEvent(NULL,mach_absolute_time(),3,1u<<22,1,down?0x23:0x27,0,x,y,0,0,0,false,false,0);
            CFTypeRef finger=fingerEvent(NULL,mach_absolute_time(),3,2,3,x,y,0,0,0,down,down,0);
            if (!parent||!finger) return -126;
            if(setInt){setInt(parent,4,1);setInt(parent,0xb0019,1);}if(sender)sender(parent,UINT64_C(0x8000000817319372));
            append(parent,finger,0);send(client,parent);CFRelease(finger);CFRelease(parent);usleep(80000);
        }
    } else {
        const char *text=getenv("HPHONE_FLEET_TEXT"); if (!text||strlen(text)>128) return -127;
        CFTypeRef (*key)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,Boolean,uint32_t)=dlsym(io,"IOHIDEventCreateKeyboardEvent");
        if (!key) return -128;
        for (const char *c=text;*c;c++) {
            unsigned usage=(*c>='a'&&*c<='z') ? 4 + *c - 'a' : (*c>='1'&&*c<='9') ? 0x1e + *c - '1' : *c=='0' ? 0x27 : *c=='\t' ? 0x2b : 0;
            if (!usage) return -129;
            for(int phase=0;phase<2;phase++){CFTypeRef event=key(NULL,mach_absolute_time(),7,usage,phase==0,0);if(!event)return -130;send(client,event);CFRelease(event);usleep(30000);}
        }
    }
    CFRelease(client); return 0;
}

__attribute__((constructor)) static void fleetBootstrap(void) {
    @autoreleasepool {
        const char *requested = getenv("HPHONE_FLEET_ACTION");
        if (!requested) return;
        NSString *action = @(requested);
        if (![@[@"install-pinned-roothide", @"install-pinned-trollstore", @"install-stock-persistence-helper", @"tap-observed-element", @"type-lowercase-ascii"] containsObject:action]) return;
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.tips"] || getuid() != 501) return;
        // Delay work until the application run loop is alive; the visible helper stays available.
        BOOL input=[action isEqualToString:@"tap-observed-element"]||[action isEqualToString:@"type-lowercase-ascii"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (input?3:1)*NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *helper = [directory stringByAppendingPathComponent:@"trollstorehelper"];
            NSString *ipa = [directory stringByAppendingPathComponent:@"Dopamine-roothide-3.0.13-30-USBDevelopment.tipa"];
            int result = -110;
            NSString *command = @"install";
            NSString *argument = ipa;
            BOOL integrity = verify(helper, officialHelperSHA);
            if ([action isEqualToString:@"install-pinned-roothide"]) integrity &= verify(ipa, developmentIPASHA);
            else if ([action isEqualToString:@"install-pinned-trollstore"]) {
                command = @"install-trollstore";
                argument = [directory stringByAppendingPathComponent:@"TrollStore-2.1.1.tar"];
                integrity &= verify(argument, @"144dc741d1b74d582c861e6ed504ddced3745724e216e3de79ab7d37b27d0551");
            } else {
                command = @"install-persistence-helper";
                argument = @"com.apple.tips";
            }
            if(input){integrity=YES;result=inputEvent(action);}
            else if (integrity && chmod(helper.fileSystemRepresentation, 0755) == 0) result = rootCommand(helper, command, argument);
            BOOL sileoPrepared=NO;
            if(result==0 && [action isEqualToString:@"install-pinned-roothide"])sileoPrepared=prepareRootHideSileo();
            NSDictionary *evidence = @{@"action":action, @"integrity_verified":@(integrity),
                                      @"sileo_prepared":@(sileoPrepared),
                                      @"exit_code":@(result), @"finished_at":@([[NSDate date] timeIntervalSince1970])};
            NSData *json = [NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[directory stringByAppendingPathComponent:@"native-install-result.json"] atomically:YES];
        });
    }
}
