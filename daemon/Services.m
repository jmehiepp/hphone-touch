#import "Services.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <fcntl.h>
#include <spawn.h>
#include <poll.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <math.h>
#include <errno.h>
#include <CommonCrypto/CommonDigest.h>
#ifndef HP_HOST_TEST
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <roothide.h>
#endif

static NSRecursiveLock *serviceLock;
static void *springboard;
static CFStringRef (*copyFrontmost)(void);
static CFArrayRef (*copyRunning)(BOOL,BOOL);
static Boolean (*pidForApp)(CFStringRef,pid_t *);
static uint32_t (*launchApp)(CFStringRef,CFDictionaryRef,BOOL);
static mach_port_t (*springboardPort)(void);
static void (*getLockStatus)(mach_port_t,BOOL *,BOOL *);
static int (*procPidPath)(int,void *,uint32_t);
static int (*procPidRusage)(int,int,void *);
static CFTypeRef (*gestaltAnswer)(CFStringRef);
static BOOL awake;
static id awakeAssertion;
#ifndef HP_HOST_TEST
static AVAudioPlayer *audioPlayer;
#endif

static NSDictionary *failure(NSString *code,NSString *message) {
    return @{@"ok":@NO,@"code":code?:@"unavailable",@"error":message?:@"Operation unavailable"};
}
static NSDictionary *success(id value) {return value?@{@"ok":@YES,@"value":value}:@{@"ok":@YES};}
static BOOL string(id value){return [value isKindOfClass:NSString.class];}
static BOOL boolean(id value){return [value isKindOfClass:NSNumber.class];}
static BOOL bundleID(id value) {
    if(!string(value)||[value length]<3||[value length]>255||![value containsString:@"."])return NO;
    return [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"].invertedSet].location==NSNotFound;
}
static void setup(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        serviceLock=[NSRecursiveLock new];
#ifndef HP_HOST_TEST
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY|RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",RTLD_LAZY|RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport",RTLD_LAZY|RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit",RTLD_LAZY|RTLD_GLOBAL);
        springboard=dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",RTLD_LAZY);
        if(springboard){
            copyFrontmost=dlsym(springboard,"SBSCopyFrontmostApplicationDisplayIdentifier");
            copyRunning=dlsym(springboard,"SBSCopyApplicationDisplayIdentifiers");
            pidForApp=dlsym(springboard,"SBSProcessIDForDisplayIdentifier");
            launchApp=dlsym(springboard,"SBSLaunchApplicationWithIdentifierAndLaunchOptions");
            springboardPort=dlsym(springboard,"SBSSpringBoardServerPort");
            getLockStatus=dlsym(springboard,"SBGetScreenLockStatus");
        }
        void *gestalt=dlopen("/usr/lib/libMobileGestalt.dylib",RTLD_LAZY);if(gestalt)gestaltAnswer=dlsym(gestalt,"MGCopyAnswer");
#endif
        procPidPath=dlsym(RTLD_DEFAULT,"proc_pidpath");procPidRusage=dlsym(RTLD_DEFAULT,"proc_pid_rusage");
    });
}
static id invoke(id object,NSString *selector) {
    SEL sel=NSSelectorFromString(selector);if(!object||![object respondsToSelector:sel])return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,sel);
}
static id proxyFor(NSString *identifier) {
    Class cls=NSClassFromString(@"LSApplicationProxy");SEL sel=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if(![cls respondsToSelector:sel])return nil;
    id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,sel,identifier);
    return [invoke(proxy,@"applicationIdentifier") isEqual:identifier]&&[invoke(proxy,@"bundleURL") isKindOfClass:NSURL.class]?proxy:nil;
}
static id workspace(void){return invoke(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace");}
static NSDictionary *appInfo(NSString *identifier) {
#ifdef HP_HOST_TEST
    NSString *mapFile=NSProcessInfo.processInfo.environment[@"HPHONE_TEST_APPS"];
    NSDictionary *map=[NSDictionary dictionaryWithContentsOfFile:mapFile];return [map[identifier] isKindOfClass:NSDictionary.class]?map[identifier]:nil;
#else
    id proxy=proxyFor(identifier);if(!proxy)return nil;
    NSURL *url=invoke(proxy,@"bundleURL"),*data=invoke(proxy,@"dataContainerURL");
    NSString *path=url.path;NSDictionary *plist=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    return @{@"bundleId":identifier,@"displayName":invoke(proxy,@"localizedName")?:invoke(proxy,@"itemName")?:identifier,
        @"bundlePath":path?:@"",@"dataContainer":data.path?:@"",@"executable":invoke(proxy,@"bundleExecutable")?:plist[@"CFBundleExecutable"]?:@"",
        @"version":invoke(proxy,@"shortVersionString")?:plist[@"CFBundleShortVersionString"]?:@"",@"applicationType":invoke(proxy,@"applicationType")?:@"unknown"};
#endif
}
static NSString *frontmost(void){return copyFrontmost?CFBridgingRelease(copyFrontmost()):nil;}
static pid_t appPID(NSString *identifier) {
#ifdef HP_HOST_TEST
    return [appInfo(identifier)[@"testPid"] intValue];
#else
    pid_t pid=0;if(pidForApp&&pidForApp((__bridge CFStringRef)identifier,&pid)&&pid>0)return pid;
    id fbs=invoke(NSClassFromString(@"FBSSystemService"),@"sharedService");SEL sel=NSSelectorFromString(@"pidForApplication:");
    if([fbs respondsToSelector:sel]){pid=((pid_t(*)(id,SEL,id))objc_msgSend)(fbs,sel,identifier);if(pid>0)return pid;}
    return 0;
#endif
}
static BOOL canCheckPID(void) {
#ifdef HP_HOST_TEST
    return YES;
#else
    return pidForApp||[invoke(NSClassFromString(@"FBSSystemService"),@"sharedService") respondsToSelector:NSSelectorFromString(@"pidForApplication:")];
#endif
}
static NSString *canonical(NSString *path) {char output[PATH_MAX];return path&&realpath(path.fileSystemRepresentation,output)?@(output):nil;}
static BOOL regularDirectory(NSString *path){struct stat s;return lstat(path.fileSystemRepresentation,&s)==0&&S_ISDIR(s.st_mode);}
static BOOL leafName(id name) {
    if(!string(name)||![name length]||[name length]>80||[name hasPrefix:@"."])return NO;
    return [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. "].invertedSet].location==NSNotFound;
}
static NSString *dataBase(void){
#ifdef HP_HOST_TEST
    return NSProcessInfo.processInfo.environment[@"HPHONE_TEST_DATA"];
#else
    return @"/var/mobile/Library/HPhoneTouch";
#endif
}
static NSString *backupRoot(void){return [dataBase() stringByAppendingPathComponent:@"backups"];}
static BOOL ensureDirectory(NSString *path,NSError **error) {
    if(![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
    return regularDirectory(path);
}
static NSString *containerFor(NSString *identifier,NSString **error) {
    NSDictionary *info=appInfo(identifier);NSString *raw=info[@"dataContainer"],*path=canonical(raw);
    if(!info||!path||!regularDirectory(path)){*error=@"The installed app has no readable data container";return nil;}
#ifdef HP_HOST_TEST
    NSString *allowed=canonical(NSProcessInfo.processInfo.environment[@"HPHONE_TEST_CONTAINERS"]);
    BOOL valid=allowed&&[path hasPrefix:[allowed stringByAppendingString:@"/"]];
#else
    NSString *allowed=canonical(@"/var/mobile/Containers/Data/Application");
    BOOL valid=allowed&&[path.stringByDeletingLastPathComponent isEqual:allowed]&&[[NSUUID alloc] initWithUUIDString:path.lastPathComponent];
#endif
    if(!valid||[identifier hasPrefix:@"com.apple."]||[identifier hasPrefix:@"io.github.jmehiepp.hphone-touch"]){*error=@"Only a selected third-party app data container is allowed";return nil;}
    if(!canCheckPID()){*error=@"Cannot verify that the app is stopped on this iOS build";return nil;}
    if(appPID(identifier)>0){*error=@"Stop the target app before changing or backing up its data";return nil;}
    return path;
}
static BOOL within(NSString *path,NSString *parent){return [path hasPrefix:[parent stringByAppendingString:@"/"]];}
static BOOL relativeSafe(NSString *relative) {
    if(!string(relative)||!relative.length||relative.isAbsolutePath||relative.length>1024)return NO;
    if([relative rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location!=NSNotFound)return NO;
    for(NSString *part in relative.pathComponents)if([part isEqual:@".."]||[part isEqual:@"."]||![part length])return NO;
    return YES;
}
static NSString *fileHash(NSString *path,NSError **error) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];return nil;}
    struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)){close(fd);return nil;}
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char block[65536],hash[CC_SHA256_DIGEST_LENGTH];ssize_t n;
    while((n=read(fd,block,sizeof(block)))>0)CC_SHA256_Update(&ctx,block,(CC_LONG)n);close(fd);
    if(n<0){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];return nil;}
    CC_SHA256_Final(hash,&ctx);NSMutableString *text=[NSMutableString new];for(unsigned i=0;i<sizeof(hash);i++)[text appendFormat:@"%02x",hash[i]];return text;
}
// Only ordinary files/directories are backed up. No symlinks, sockets, metadata files,
// app bundles, shared groups, or keychain records are traversed.
static NSArray *inventory(NSString *root,BOOL source,NSError **error) {
    // NSURL enumeration resolves /var and similar parent aliases on Darwin.
    // Compare against the same canonical root for source and backup payloads.
    root=canonical(root);if(!root)return nil;
    NSFileManager *fm=NSFileManager.defaultManager;NSMutableArray *result=[NSMutableArray new];
    __block NSError *enumerationError=nil;
    NSDirectoryEnumerator *walk=[fm enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url,NSError *problem){enumerationError=problem;return NO;}];
    if(!walk)return nil;NSURL *entryURL;uint64_t total=0;
    while((entryURL=walk.nextObject)){
        NSString *full=entryURL.path;NSString *prefix=[root stringByAppendingString:@"/"];
        if(![full hasPrefix:prefix])return nil;NSString *relative=[full substringFromIndex:prefix.length];
        if(source&&([relative hasPrefix:@".hphone-"]||[relative hasPrefix:@".com.apple.mobile_container_manager.metadata.plist"])){[walk skipDescendants];continue;}
        if(!relativeSafe(relative)){if(error)*error=[NSError errorWithDomain:@"HPhoneServices" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid relative path"}];return nil;}
        NSString *path=[root stringByAppendingPathComponent:relative];struct stat st;
        if(lstat(path.fileSystemRepresentation,&st)||(!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode))||(st.st_nlink>1&&!S_ISDIR(st.st_mode))){
            if(error)*error=[NSError errorWithDomain:@"HPhoneServices" code:2 userInfo:@{NSLocalizedDescriptionKey:[@"Unsupported or unreadable entry: " stringByAppendingString:relative]}];return nil;
        }
        total+=S_ISREG(st.st_mode)?st.st_size:0;
        if(total>512ULL*1024*1024||result.count>=50000){if(error)*error=[NSError errorWithDomain:@"HPhoneServices" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Backup exceeds 512 MiB or 50,000 entries"}];return nil;}
        NSMutableDictionary *row=[@{@"path":relative,@"directory":@(S_ISDIR(st.st_mode)),@"size":@(S_ISREG(st.st_mode)?st.st_size:0),@"mode":@(st.st_mode&0777)} mutableCopy];
        if(S_ISREG(st.st_mode)){NSString *hash=fileHash(path,error);if(!hash)return nil;row[@"sha256"]=hash;}
        [result addObject:row];
    }
    if(enumerationError){if(error)*error=enumerationError;return nil;}
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"path"] compare:b[@"path"]];}];
}
static BOOL copyEntries(NSString *source,NSString *destination,NSArray *entries,NSError **error) {
    for(NSDictionary *row in entries){NSString *relative=row[@"path"],*from=[source stringByAppendingPathComponent:relative],*to=[destination stringByAppendingPathComponent:relative];
        if(!relativeSafe(relative)||!within(to,destination))return NO;
        if([row[@"directory"] boolValue]){if(!ensureDirectory(to,error))return NO;}
        else {
            if(!ensureDirectory(to.stringByDeletingLastPathComponent,error))return NO;
            int in=open(from.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW),out=-1;struct stat st;
            if(in>=0&&fstat(in,&st)==0&&S_ISREG(st.st_mode))out=open(to.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
            if(in<0||out<0){if(in>=0)close(in);return NO;}
            char buffer[65536];ssize_t n;uint64_t copied=0;BOOL ok=YES;
            while((n=read(in,buffer,sizeof(buffer)))>0){copied+=n;if(copied>[row[@"size"] unsignedLongLongValue]){ok=NO;break;}ssize_t pos=0;while(pos<n){ssize_t w=write(out,buffer+pos,n-pos);if(w<=0){ok=NO;break;}pos+=w;}if(!ok)break;}
            if(n<0||copied!=[row[@"size"] unsignedLongLongValue])ok=NO;
            if(fchmod(out,[row[@"mode"] unsignedIntValue]&0777)||fsync(out))ok=NO;close(in);close(out);
            if(!ok||![fileHash(to,error) isEqual:row[@"sha256"]])return NO;
        }
    }
    // Set directory modes last so a read-only source directory does not prevent
    // staging its children. Reverse order handles nested directories first.
    for(NSDictionary *row in entries.reverseObjectEnumerator)if([row[@"directory"] boolValue])
        if(chmod([[destination stringByAppendingPathComponent:row[@"path"]] fileSystemRepresentation],[row[@"mode"] unsignedIntValue]&0777))return NO;
    return YES;
}
static NSDictionary *backupApp(NSString *identifier,NSString *name) {
    NSString *errorText=nil,*container=containerFor(identifier,&errorText);if(!container)return failure(@"container",errorText);
    NSError *error=nil;NSString *parent=[backupRoot() stringByAppendingPathComponent:identifier];
    if(!ensureDirectory(backupRoot(),&error)||!ensureDirectory(parent,&error)||![canonical(parent) isEqual:[[canonical(dataBase()) stringByAppendingPathComponent:@"backups"] stringByAppendingPathComponent:identifier]])return failure(@"directory",@"Cannot create private backup directory");
    NSString *destination=[parent stringByAppendingPathComponent:name];if([NSFileManager.defaultManager fileExistsAtPath:destination])return failure(@"exists",@"A backup with this name already exists");
    NSString *stage=[parent stringByAppendingPathComponent:[@".hphone-stage-" stringByAppendingString:NSUUID.UUID.UUIDString]],*payload=[stage stringByAppendingPathComponent:@"data"];
    if(!ensureDirectory(payload,&error))return failure(@"directory",error.localizedDescription);
    NSArray *entries=inventory(container,YES,&error);
    BOOL ok=entries&&copyEntries(container,payload,entries,&error);uint64_t bytes=0;for(NSDictionary *row in entries)bytes+=[row[@"size"] unsignedLongLongValue];
    NSDictionary *manifest=@{@"format":@1,@"bundleId":identifier,@"name":name,@"date":@((long long)NSDate.date.timeIntervalSince1970),@"dataSize":@(bytes),@"hasKeychain":@NO,@"entries":entries?:@[]};
    if(ok){NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:&error];ok=json&&[json writeToFile:[stage stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&error];}
    if(ok)ok=rename(stage.fileSystemRepresentation,destination.fileSystemRepresentation)==0;
    if(!ok){[NSFileManager.defaultManager removeItemAtPath:stage error:NULL];return failure(@"backup",error.localizedDescription?:@"Backup could not be completed; original data was not changed");}
    return success(@{@"ok":@YES,@"path":destination,@"name":name,@"dataSize":@(bytes),@"keychainCount":@0,@"hasKeychain":@NO});
}
static NSDictionary *loadBackup(NSString *identifier,NSString *name,NSString **folder) {
    NSString *path=[[backupRoot() stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:name];
    if(![canonical(backupRoot()) isEqual:[canonical(dataBase()) stringByAppendingPathComponent:@"backups"]]||!regularDirectory(path)||![canonical(path) isEqual:[[canonical(backupRoot()) stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:name]])return nil;
    NSString *manifest=[path stringByAppendingPathComponent:@"manifest.json"];struct stat st;
    if(lstat(manifest.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size>16*1024*1024)return nil;
    id doc=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifest] options:0 error:NULL];
    if(![doc isKindOfClass:NSDictionary.class]||![doc[@"format"] isEqual:@1]||![doc[@"bundleId"] isEqual:identifier]||![doc[@"name"] isEqual:name]||![doc[@"entries"] isKindOfClass:NSArray.class])return nil;
    if(folder)*folder=path;return doc;
}
// Stage a complete replacement first, then rename each top-level item. A journal
// retains the old data until all renames succeed. Immediate failures roll back.
static NSDictionary *replaceData(NSString *identifier,NSString *name,BOOL wipe) {
    NSString *errorText=nil,*container=containerFor(identifier,&errorText);if(!container)return failure(@"container",errorText);
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;NSString *backup=nil;NSDictionary *manifest=nil;
    NSString *journal=[container stringByAppendingPathComponent:@".hphone-transaction.json"];struct stat journalStat;
    if(lstat(journal.fileSystemRepresentation,&journalStat)==0||errno!=ENOENT)return failure(@"recovery",@"An earlier app-data transaction requires recovery; old data was retained");
    if(!wipe){manifest=loadBackup(identifier,name,&backup);if(!manifest)return failure(@"manifest",@"Backup is missing or has an invalid manifest");}
    NSArray *current=inventory(container,YES,&error);if(!current)return failure(@"inventory",error.localizedDescription);
    NSString *transaction=NSUUID.UUID.UUIDString,*stage=[container stringByAppendingPathComponent:[@".hphone-new-" stringByAppendingString:transaction]],*old=[container stringByAppendingPathComponent:[@".hphone-old-" stringByAppendingString:transaction]];
    if(!ensureDirectory(stage,&error)||!ensureDirectory(old,&error))return failure(@"staging",@"Cannot prepare transactional app data replacement");
    NSArray *entries=wipe?@[]:manifest[@"entries"];
    if(!wipe){
        NSArray *actual=inventory([backup stringByAppendingPathComponent:@"data"],NO,&error);
        // Validate the entire manifest, including unexpected extra files, before mutation.
        if(!actual||![actual isEqual:entries]||!copyEntries([backup stringByAppendingPathComponent:@"data"],stage,entries,&error)){
            [fm removeItemAtPath:stage error:NULL];[fm removeItemAtPath:old error:NULL];return failure(@"integrity",@"Backup data does not match its SHA256 manifest");
        }
    }
    NSMutableOrderedSet *names=[NSMutableOrderedSet new];for(NSDictionary *row in current)[names addObject:[row[@"path"] pathComponents].firstObject];
    for(NSDictionary *row in entries)if(relativeSafe(row[@"path"]))[names addObject:[row[@"path"] pathComponents].firstObject];
    NSMutableArray *movedOld=[NSMutableArray new],*movedNew=[NSMutableArray new];
    if([fm fileExistsAtPath:journal]){[fm removeItemAtPath:stage error:NULL];[fm removeItemAtPath:old error:NULL];return failure(@"recovery",@"An earlier app-data transaction requires recovery; old data was retained");}
    NSDictionary *record=@{@"bundleId":identifier,@"id":transaction,@"old":old.lastPathComponent,@"new":stage.lastPathComponent,@"names":names.array};
    NSData *journalBytes=[NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    if(![journalBytes writeToFile:journal options:NSDataWritingAtomic error:&error]){[fm removeItemAtPath:stage error:NULL];[fm removeItemAtPath:old error:NULL];return failure(@"journal",@"Cannot write transaction journal");}
    BOOL ok=YES;
    for(NSString *entry in names){NSString *live=[container stringByAppendingPathComponent:entry],*prior=[old stringByAppendingPathComponent:entry],*next=[stage stringByAppendingPathComponent:entry];
        if([fm fileExistsAtPath:live]){if(rename(live.fileSystemRepresentation,prior.fileSystemRepresentation)){ok=NO;break;}[movedOld addObject:entry];}
        if([fm fileExistsAtPath:next]){if(rename(next.fileSystemRepresentation,live.fileSystemRepresentation)){ok=NO;break;}[movedNew addObject:entry];}
    }
    if(!ok){BOOL recovered=YES;for(NSString *entry in movedNew.reverseObjectEnumerator)if(rename([[container stringByAppendingPathComponent:entry] fileSystemRepresentation],[[stage stringByAppendingPathComponent:entry] fileSystemRepresentation]))recovered=NO;
        for(NSString *entry in movedOld.reverseObjectEnumerator)if(rename([[old stringByAppendingPathComponent:entry] fileSystemRepresentation],[[container stringByAppendingPathComponent:entry] fileSystemRepresentation]))recovered=NO;
        if(recovered){[fm removeItemAtPath:stage error:NULL];[fm removeItemAtPath:old error:NULL];[fm removeItemAtPath:journal error:NULL];}
        return failure(@"transaction",recovered?@"Data replacement failed and was rolled back":@"Data replacement failed; recovery journal and old data were retained");
    }
    // This marker permits recovery to distinguish committed state from interruption.
    NSMutableDictionary *committed=[record mutableCopy];committed[@"committed"]=@YES;
    [[NSJSONSerialization dataWithJSONObject:committed options:0 error:NULL] writeToFile:journal options:NSDataWritingAtomic error:NULL];
    [fm removeItemAtPath:stage error:NULL];[fm removeItemAtPath:old error:NULL];[fm removeItemAtPath:journal error:NULL];
    return success(@{@"ok":@YES,@"bundleId":identifier,@"keychainAdded":@0,@"hasKeychain":@NO,@"dataOnly":@YES});
}

static NSDictionary *executeCommand(NSDictionary *arguments) {
    NSString *command=arguments[@"command"];if(!string(command)||!command.length||command.length>16384)return failure(@"arguments",@"command must contain 1..16384 characters");
    double timeout=arguments[@"timeout"]?[arguments[@"timeout"] doubleValue]:15;if(!isfinite(timeout)||timeout<.1||timeout>30)return failure(@"arguments",@"timeout must be 0.1..30 seconds");
#ifdef HP_HOST_TEST
    NSString *shell=@"/bin/sh";
#else
    NSString *shell=jbroot(@"/bin/sh");if(access(shell.fileSystemRepresentation,X_OK))shell=jbroot(@"/usr/bin/sh");
#endif
    int pipes[2];if(pipe(pipes))return failure(@"spawn",@"Cannot create output pipe");
    fcntl(pipes[0],F_SETFD,FD_CLOEXEC);fcntl(pipes[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);posix_spawn_file_actions_adddup2(&actions,pipes[1],STDOUT_FILENO);posix_spawn_file_actions_adddup2(&actions,pipes[1],STDERR_FILENO);posix_spawn_file_actions_addclose(&actions,pipes[0]);posix_spawn_file_actions_addclose(&actions,pipes[1]);posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    posix_spawnattr_t attr;posix_spawnattr_init(&attr);short flags=POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags|=POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    posix_spawnattr_setflags(&attr,flags);posix_spawnattr_setpgroup(&attr,0);
    char *argv[]={(char *)shell.fileSystemRepresentation,"-c",(char *)command.UTF8String,NULL};
    // Deliberately build a minimal environment: API tokens are not inherited by scripts.
    NSString *path=[NSString stringWithFormat:@"PATH=%@:%@:/usr/bin:/bin",shell.stringByDeletingLastPathComponent,
#ifdef HP_HOST_TEST
        @"/usr/bin"
#else
        jbroot(@"/usr/bin")
#endif
    ];
    char *envp[]={(char *)path.UTF8String,"HOME=/var/mobile","TMPDIR=/var/tmp","LANG=en_US.UTF-8",NULL};
    pid_t child=0;int code=posix_spawn(&child,shell.fileSystemRepresentation,&actions,&attr,argv,envp);posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);close(pipes[1]);
    if(code){close(pipes[0]);return failure(@"spawn",[NSString stringWithFormat:@"Cannot launch mobile shell: %s",strerror(code)]);}
    fcntl(pipes[0],F_SETFL,O_NONBLOCK);NSMutableData *output=[NSMutableData new];BOOL timedOut=NO,truncated=NO,exited=NO,eof=NO;int status=0;
    double deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    while(!exited||!eof){char buffer[8192];ssize_t n;while((n=read(pipes[0],buffer,sizeof(buffer)))>0){NSUInteger room=1048576-output.length;if(room)[output appendBytes:buffer length:MIN(room,(NSUInteger)n)];if((NSUInteger)n>room){truncated=YES;break;}}if(n==0)eof=YES;
        if(!exited){pid_t waited=waitpid(child,&status,WNOHANG);if(waited==child||waited<0)exited=YES;}
        if(NSProcessInfo.processInfo.systemUptime>=deadline||truncated){timedOut=!truncated;kill(-child,SIGKILL);kill(child,SIGKILL);if(!exited)waitpid(child,&status,0);exited=YES;break;}
        if(exited&&eof)break;struct pollfd p={pipes[0],POLLIN,0};poll(&p,1,20);
    }
    close(pipes[0]);NSString *text=[[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding]?:[output base64EncodedStringWithOptions:0];
    return success(@{@"output":text,@"exitCode":@(WIFEXITED(status)?WEXITSTATUS(status):-1),@"signal":@(WIFSIGNALED(status)?WTERMSIG(status):0),@"timedOut":@(timedOut),@"truncated":@(truncated)});
}
static NSString *localIP(void){struct ifaddrs *head=NULL;NSString *result=@"";if(getifaddrs(&head))return result;for(struct ifaddrs *i=head;i;i=i->ifa_next)if(i->ifa_addr&&i->ifa_addr->sa_family==AF_INET&&strcmp(i->ifa_name,"en0")==0){char buffer[INET_ADDRSTRLEN];if(inet_ntop(AF_INET,&((struct sockaddr_in *)i->ifa_addr)->sin_addr,buffer,sizeof(buffer)))result=@(buffer);}freeifaddrs(head);return result;}
static NSDictionary *memoryFor(pid_t pid) {
    if(pid==getpid()){mach_task_basic_info_data_t info;mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)==KERN_SUCCESS)return success(@(info.resident_size));}
    // rusage_info_v0 starts with 16-byte UUID then user/system time, wakeups,
    // pageins, wired, resident, physical footprint. Request exactly flavor 0.
    struct {unsigned char uuid[16];uint64_t user,system,pkg,idle,pageins,wired,resident,footprint,start,exit;} info={0};
    if(procPidRusage&&procPidRusage(pid,0,&info)==0)return success(@(info.resident));
    return failure(@"permission",@"Memory usage is unavailable for this process");
}
static NSDictionary *deviceInfo(void){struct utsname uts;uname(&uts);NSMutableDictionary *info=[@{@"model":@(uts.machine),@"kernel":@(uts.release),@"hostname":NSProcessInfo.processInfo.hostName,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"uid":@(getuid()),@"pid":@(getpid()),@"localIP":localIP(),@"memory":memoryFor(getpid())[@"value"]?:@0} mutableCopy];
#ifndef HP_HOST_TEST
    info[@"systemVersion"]=UIDevice.currentDevice.systemVersion;info[@"deviceName"]=UIDevice.currentDevice.name;
#endif
    NSString *front=frontmost();if(front)info[@"frontmostApp"]=front;return info;
}

// Safari's offline binary-cookie format is not an Apple public API. These bounds-
// checked format routines are independently written from public format research.
// Unchanged records and footer metadata are retained byte-for-byte on mutation.
static uint32_t cookieU32(const unsigned char *p,BOOL big){return big?((uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]):((uint32_t)p[3]<<24|(uint32_t)p[2]<<16|(uint32_t)p[1]<<8|p[0]);}
static const NSUInteger HPCookieMaxBytes=8*1024*1024,HPCookieMaxRecords=20000;
static void cookiePut(NSMutableData *data,NSUInteger at,uint32_t v,BOOL big){unsigned char bytes[4];for(int i=0;i<4;i++)bytes[big?3-i:i]=(v>>(i*8))&255;[data replaceBytesInRange:NSMakeRange(at,4) withBytes:bytes];}
static void cookieAppend(NSMutableData *data,uint32_t value,BOOL big){NSUInteger at=data.length;[data increaseLengthBy:4];cookiePut(data,at,value,big);}
static double cookieDouble(const unsigned char *p){uint64_t bits=0;for(int i=0;i<8;i++)bits|=(uint64_t)p[i]<<(i*8);double value;memcpy(&value,&bits,8);return value;}
static void cookiePutDouble(NSMutableData *data,NSUInteger at,double value){uint64_t bits;memcpy(&bits,&value,8);unsigned char out[8];for(int i=0;i<8;i++)out[i]=(bits>>(i*8))&255;[data replaceBytesInRange:NSMakeRange(at,8) withBytes:out];}
static NSString *cookieString(const unsigned char *record,NSUInteger size,uint32_t offset){if(offset<56||offset>=size)return nil;const unsigned char *end=memchr(record+offset,0,size-offset);if(!end||end-record-offset>65536)return nil;return [[NSString alloc] initWithBytes:record+offset length:end-record-offset encoding:NSUTF8StringEncoding];}
static NSDictionary *parseCookies(NSData *data) {
    if(data.length<16||data.length>HPCookieMaxBytes)return nil;const unsigned char *bytes=data.bytes;if(memcmp(bytes,"cook",4))return nil;
    uint32_t pages=cookieU32(bytes+4,YES);if(pages>HPCookieMaxRecords||8ULL+4ULL*pages>data.length-8)return nil;NSUInteger position=8+4*pages,decodedBytes=0;NSMutableArray *records=[NSMutableArray new];
    for(uint32_t page=0;page<pages;page++){
        uint32_t size=cookieU32(bytes+8+page*4,YES);if(size<12||size>data.length-position||memcmp(bytes+position,"\0\0\1\0",4))return nil;
        const unsigned char *start=bytes+position;uint32_t count=cookieU32(start+4,NO);if(count>HPCookieMaxRecords||12ULL+4ULL*count>size||records.count+count>HPCookieMaxRecords)return nil;
        if(cookieU32(start+8+count*4,NO)!=0)return nil;
        for(uint32_t item=0;item<count;item++){
            uint32_t offset=cookieU32(start+8+item*4,NO);if(size<56||offset<12+4*count||offset>size-56)return nil;
            const unsigned char *record=start+offset;uint32_t length=cookieU32(record,NO),flags=cookieU32(record+8,NO);if(length<56||length>size-offset||decodedBytes+length>data.length)return nil;decodedBytes+=length;
            NSString *domain=cookieString(record,length,cookieU32(record+16,NO)),*name=cookieString(record,length,cookieU32(record+20,NO)),*path=cookieString(record,length,cookieU32(record+24,NO)),*value=cookieString(record,length,cookieU32(record+28,NO));
            double expiry=cookieDouble(record+40),creation=cookieDouble(record+48);if(!domain||!name||!path||!value||!isfinite(expiry)||!isfinite(creation))return nil;
            [records addObject:@{@"domain":domain,@"name":name,@"path":path,@"value":value,@"secure":@((flags&1)!=0),@"httpOnly":@((flags&4)!=0),@"expiry":@(expiry?expiry+978307200:0),@"creation":@(creation+978307200),@"flags":@(flags),@"_record":[NSData dataWithBytes:record length:length]}];
        }position+=size;
    }
    if(data.length-position<8)return nil;
    return @{@"records":records,@"footer":[data subdataWithRange:NSMakeRange(position,data.length-position)]};
}
static NSDictionary *publicCookie(NSDictionary *record){NSMutableDictionary *row=[record mutableCopy];[row removeObjectForKey:@"_record"];row[@"expirationDate"]=row[@"expiry"]?:@0;row[@"session"]=@([row[@"expiry"] doubleValue]==0);return row;}
static NSData *encodeCookies(NSArray *records,NSData *footer){
    if(records.count>HPCookieMaxRecords)return nil;
    // A single page is sufficient; offset tables are authoritative and preserve
    // all original record bytes irrespective of domain grouping.
    NSMutableData *page=[NSMutableData dataWithBytes:"\0\0\1\0" length:4];cookieAppend(page,(uint32_t)records.count,NO);[page increaseLengthBy:records.count*4+4];
    NSUInteger i=0;for(NSDictionary *row in records){NSData *raw=row[@"_record"];if(![raw isKindOfClass:NSData.class]||raw.length<56||page.length+raw.length>HPCookieMaxBytes)return nil;cookiePut(page,8+4*i++,(uint32_t)page.length,NO);[page appendData:raw];}
    NSMutableData *file=[NSMutableData dataWithBytes:"cook" length:4];cookieAppend(file,1,YES);cookieAppend(file,(uint32_t)page.length,YES);[file appendData:page];
    NSMutableData *tail=footer.length>=8?[footer mutableCopy]:[NSMutableData dataWithLength:8];uint32_t checksum=0;const unsigned char *p=page.bytes;for(NSUInteger at=0;at<page.length;at+=4)checksum+=p[at];cookiePut(tail,0,checksum,YES);[file appendData:tail];return file;
}
static NSDictionary *newCookie(NSDictionary *input) {
    if(![input isKindOfClass:NSDictionary.class])return nil;NSString *domain=input[@"domain"],*name=input[@"name"],*path=input[@"path"]?:@"/",*value=input[@"value"];
    if(!string(domain)||!domain.length||domain.length>253||!string(name)||!name.length||name.length>4096||!string(path)||![path hasPrefix:@"/"]||!string(value)||value.length>65536)return nil;
    NSCharacterSet *bad=[NSCharacterSet characterSetWithCharactersInString:@"\r\n\t"];for(NSString *part in @[domain,name,path,value])if([part rangeOfCharacterFromSet:bad].location!=NSNotFound||[part rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location!=NSNotFound)return nil;
    double expiry=[(input[@"expiry"]?:input[@"expirationDate"]?:@0) doubleValue],creation=[(input[@"creation"]?:@(NSDate.date.timeIntervalSince1970)) doubleValue];if(!isfinite(expiry)||!isfinite(creation)||expiry<0)return nil;
    uint32_t flags=[input[@"flags"] isKindOfClass:NSNumber.class]?[input[@"flags"] unsignedIntValue]:0;
    if(input[@"secure"])flags=(flags&~1u)|([input[@"secure"] boolValue]?1:0);if(input[@"httpOnly"])flags=(flags&~4u)|([input[@"httpOnly"] boolValue]?4:0);
    NSMutableData *record=[NSMutableData dataWithLength:56];cookiePut(record,8,flags,NO);cookiePutDouble(record,40,expiry?expiry-978307200:0);cookiePutDouble(record,48,creation-978307200);
    NSUInteger index=0;for(NSString *part in @[domain,name,path,value]){cookiePut(record,16+4*index++,(uint32_t)record.length,NO);[record appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];[record appendBytes:"\0" length:1];}cookiePut(record,0,(uint32_t)record.length,NO);
    return @{@"domain":domain,@"name":name,@"path":path,@"value":value,@"secure":@((flags&1)!=0),@"httpOnly":@((flags&4)!=0),@"expiry":@(expiry),@"creation":@(creation),@"flags":@(flags),@"_record":record};
}
static BOOL cookieMatches(NSString *host,NSString *filter){
    if(!filter.length||[filter isEqual:@"*"])return YES;host=host.lowercaseString;filter=filter.lowercaseString;while([host hasPrefix:@"."])host=[host substringFromIndex:1];while([filter hasPrefix:@"."])filter=[filter substringFromIndex:1];
    return [host isEqual:filter]||[host hasSuffix:[@"." stringByAppendingString:filter]];
}
static NSData *readPrivateFile(NSString *path){int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0)return nil;struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<0||st.st_size>HPCookieMaxBytes){close(fd);return nil;}NSMutableData *result=[NSMutableData dataWithLength:(NSUInteger)st.st_size];char *p=result.mutableBytes;NSUInteger position=0;while(position<result.length){ssize_t n=read(fd,p+position,result.length-position);if(n<=0){close(fd);return nil;}position+=n;}close(fd);return result;}
static BOOL atomicPrivateFile(NSString *path,NSData *bytes){NSString *temporary=[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".hphone-cookie-" stringByAppendingString:NSUUID.UUID.UUIDString]];int fd=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return NO;const char *p=bytes.bytes;NSUInteger at=0;BOOL ok=YES;while(at<bytes.length){ssize_t n=write(fd,p+at,bytes.length-at);if(n<=0){ok=NO;break;}at+=n;}if(fsync(fd))ok=NO;close(fd);if(ok)ok=rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)==0;if(!ok)unlink(temporary.fileSystemRepresentation);return ok;}
static NSString *cookiesPath(NSDictionary *arguments) {
#ifdef HP_HOST_TEST
    NSString *allowed=NSProcessInfo.processInfo.environment[@"HPHONE_TEST_COOKIE_FILE"];NSString *provided=arguments[@"file"];return !provided||[provided isEqual:allowed]?allowed:nil;
#else
    NSMutableArray *candidates=[NSMutableArray arrayWithObject:@"/var/mobile/Library/Cookies/Cookies.binarycookies"];
    NSString *container=appInfo(@"com.apple.mobilesafari")[@"dataContainer"];if(container.length)[candidates insertObject:[container stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"] atIndex:0];
    NSString *provided=arguments[@"file"];
    for(NSString *candidate in candidates)if((!provided||[provided isEqual:candidate])&&readPrivateFile(candidate))return candidate;
    // Explicit custom fixtures/exports are confined to this tool's scripts tree.
    NSString *resolved=string(provided)?canonical(provided):nil,*scripts=canonical([dataBase() stringByAppendingPathComponent:@"scripts"]);
    return resolved&&scripts&&within(resolved,scripts)&&[resolved hasSuffix:@".binarycookies"]?resolved:nil;
#endif
}
static NSDictionary *cookieOperation(NSString *operation,NSDictionary *arguments){
    NSString *file=cookiesPath(arguments);if(!file)return failure(@"cookieFile",@"No allowed Safari binary-cookie file was found; custom files must be in this tool's scripts folder");
    if([operation isEqual:@"safariCookiesPath"])return success(file);
#ifndef HP_HOST_TEST
    if(!canCheckPID())return failure(@"unavailable",@"Cannot confirm that Safari is stopped");
    if(appPID(@"com.apple.mobilesafari")>0)return failure(@"safariRunning",@"Offline cookie access requires Safari to be closed; live-cookie injection is not enabled");
#endif
    NSData *original=readPrivateFile(file);NSDictionary *parsed=parseCookies(original);if(!parsed)return failure(@"cookieFormat",@"Invalid, unsupported or oversized binary-cookie file");
    NSString *domain=arguments[@"domain"];if(domain&&!string(domain))return failure(@"arguments",@"domain must be a string");NSArray *records=parsed[@"records"];NSMutableArray *selected=[NSMutableArray new];for(NSDictionary *row in records)if(cookieMatches(row[@"domain"],domain))[selected addObject:row];
    if([operation isEqual:@"getCookies"]){NSMutableArray *public=[NSMutableArray new];for(NSDictionary *row in selected)[public addObject:publicCookie(row)];return success(public);}
    if([operation isEqual:@"getCookieHeader"]){NSMutableArray *parts=[NSMutableArray new];for(NSDictionary *row in selected)[parts addObject:[NSString stringWithFormat:@"%@=%@",row[@"name"],row[@"value"]]];return success([parts componentsJoinedByString:@"; "]);}
    if([operation isEqual:@"getCookiesJSON"]){NSMutableArray *public=[NSMutableArray new];for(NSDictionary *row in selected)[public addObject:publicCookie(row)];NSData *json=[NSJSONSerialization dataWithJSONObject:public options:0 error:NULL];return success([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);}
    if([operation isEqual:@"getCookiesText"]){NSMutableString *text=[NSMutableString stringWithString:@"# Netscape HTTP Cookie File\n"];for(NSDictionary *row in selected)[text appendFormat:@"%@%@\t%@\t%@\t%@\t%.0f\t%@\t%@\n",[row[@"httpOnly"] boolValue]?@"#HttpOnly_":@"",row[@"domain"],[row[@"domain"] hasPrefix:@"."]?@"TRUE":@"FALSE",row[@"path"],[row[@"secure"] boolValue]?@"TRUE":@"FALSE",[row[@"expiry"] doubleValue],row[@"name"],row[@"value"]];return success(text);}
    if(!domain.length||![arguments[@"confirmDomain"] isEqual:domain])return failure(@"confirmation",@"Cookie changes require domain plus matching confirmDomain; use '*' only for an explicitly selected whole jar");
    NSString *backup=[file stringByAppendingString:@".hphonebak"];NSData *replacement=nil;NSUInteger changed=0;
    if([operation isEqual:@"restoreCookies"]){NSData *saved=readPrivateFile(backup);NSDictionary *previous=parseCookies(saved);if(!previous)return failure(@"cookieBackup",@"Cookie backup is missing or invalid");if([domain isEqual:@"*"])replacement=saved;else{NSMutableArray *next=[records mutableCopy];[next removeObjectsInArray:selected];for(NSDictionary *row in previous[@"records"])if(cookieMatches(row[@"domain"],domain))[next addObject:row];replacement=encodeCookies(next,parsed[@"footer"]);}if(!replacement)return failure(@"cookieFormat",@"Restored cookie encoding exceeded limits");}
    else {
        NSMutableArray *next=[records mutableCopy];
        if([operation isEqual:@"deleteCookies"]){[next removeObjectsInArray:selected];changed=selected.count;}
        else if([operation isEqual:@"importCookies"]){id items=arguments[@"cookies"]?:arguments[@"json"];if(string(items))items=[NSJSONSerialization JSONObjectWithData:[items dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];if(![items isKindOfClass:NSArray.class]||[items count]>10000)return failure(@"arguments",@"cookies must be an array or JSON cookie array with at most 10,000 records");
            NSMutableArray *incoming=[NSMutableArray new];for(id row in items){NSDictionary *cookie=newCookie(row);if(!cookie||!cookieMatches(cookie[@"domain"],domain))return failure(@"arguments",@"Imported cookie is invalid or outside the selected domain");[incoming addObject:cookie];}
            if(arguments[@"merge"]&&![arguments[@"merge"] boolValue])[next removeObjectsInArray:selected];
            for(NSDictionary *cookie in incoming){NSIndexSet *duplicates=[next indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger index,BOOL *stop){return [row[@"domain"] isEqual:cookie[@"domain"]]&&[row[@"path"] isEqual:cookie[@"path"]]&&[row[@"name"] isEqual:cookie[@"name"]];}];[next removeObjectsAtIndexes:duplicates];[next addObject:cookie];}changed=incoming.count;
        }else return failure(@"unsupported",@"Unknown cookie operation");
        replacement=encodeCookies(next,parsed[@"footer"]);if(!replacement||!parseCookies(replacement))return failure(@"cookieFormat",@"Cookie encoding could not be validated");
    }
    // Check again immediately before commit. Preserve the old jar under private
    // mode; never print its content or send it to an external service.
#ifndef HP_HOST_TEST
    if(appPID(@"com.apple.mobilesafari")>0)return failure(@"safariRunning",@"Safari opened during cookie processing; no file was changed");
#endif
    if(![readPrivateFile(file) isEqual:original])return failure(@"conflict",@"The cookie file changed during processing; no replacement was made");
    NSString *recovery=[operation isEqual:@"restoreCookies"]?[file stringByAppendingString:@".before-restore.hphonebak"]:backup;
    if(!atomicPrivateFile(recovery,original)||!atomicPrivateFile(file,replacement))return failure(@"cookieWrite",@"Atomic cookie write failed; the recovery file was retained when possible");
    return [operation isEqual:@"restoreCookies"]?success(@YES):success(@(changed));
}

static NSDictionary *radioOperation(NSString *operation,NSDictionary *arguments) {
#ifdef HP_HOST_TEST
    return failure(@"unavailable",@"Radio private frameworks are not loaded by host tests");
#else
    BOOL airplane=[@[@"airplaneMode",@"radioAirplane"] containsObject:operation];
    Class cls=NSClassFromString(airplane?@"RadiosPreferences":@"WFClient");
    id object=airplane?[[cls alloc] init]:invoke(cls,@"sharedInstance");
    SEL get=NSSelectorFromString(airplane?@"airplaneMode":@"powered"),set=NSSelectorFromString(airplane?@"setAirplaneMode:":@"setPowered:");
    if(!object||![object respondsToSelector:get])return failure(@"unavailable",@"The requested radio API is unavailable on this iOS build");
    if(arguments[@"enabled"]){
        if(!boolean(arguments[@"enabled"])||![object respondsToSelector:set])return failure(@"arguments",@"A boolean enabled value and supported setter are required");
        BOOL desired=[arguments[@"enabled"] boolValue];((void(*)(id,SEL,BOOL))objc_msgSend)(object,set,desired);
        if(airplane){SEL sync=NSSelectorFromString(@"synchronize");if([object respondsToSelector:sync])((void(*)(id,SEL))objc_msgSend)(object,sync);}
        double until=NSProcessInfo.processInfo.systemUptime+2;
        do{if(airplane){SEL refresh=NSSelectorFromString(@"refresh");if([object respondsToSelector:refresh])((void(*)(id,SEL))objc_msgSend)(object,refresh);}BOOL actual=((BOOL(*)(id,SEL))objc_msgSend)(object,get);if(actual==desired)return success(@(actual));usleep(50000);}while(NSProcessInfo.processInfo.systemUptime<until);
        return failure(@"notApplied",@"The radio setter did not confirm the requested state; entitlement or system policy may deny it");
    }
    return success(@(((BOOL(*)(id,SEL))objc_msgSend)(object,get)));
#endif
}
typedef CFTypeRef (*HPSCCreate)(CFAllocatorRef,CFStringRef,CFStringRef);
static NSDictionary *proxyOperation(NSString *operation,NSDictionary *arguments) {
#ifdef HP_HOST_TEST
    return failure(@"unavailable",@"Host tests never change the host network configuration");
#else
    static void *library;static dispatch_once_t once;dispatch_once(&once,^{library=dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",RTLD_LAZY);});
    if(!library)return failure(@"unavailable",@"SystemConfiguration framework unavailable");
    HPSCCreate create=dlsym(library,"SCPreferencesCreate");
    Boolean(*prefsLock)(CFTypeRef,Boolean)=dlsym(library,"SCPreferencesLock");Boolean(*prefsUnlock)(CFTypeRef)=dlsym(library,"SCPreferencesUnlock");
    CFTypeRef(*currentSet)(CFTypeRef)=dlsym(library,"SCNetworkSetCopyCurrent");CFArrayRef(*copyServices)(CFTypeRef)=dlsym(library,"SCNetworkSetCopyServices");
    CFTypeRef(*getInterface)(CFTypeRef)=dlsym(library,"SCNetworkServiceGetInterface");CFStringRef(*bsdName)(CFTypeRef)=dlsym(library,"SCNetworkInterfaceGetBSDName");
    CFTypeRef(*copyProtocol)(CFTypeRef,CFStringRef)=dlsym(library,"SCNetworkServiceCopyProtocol");CFDictionaryRef(*getConfig)(CFTypeRef)=dlsym(library,"SCNetworkProtocolGetConfiguration");
    Boolean(*setConfig)(CFTypeRef,CFDictionaryRef)=dlsym(library,"SCNetworkProtocolSetConfiguration");Boolean(*commit)(CFTypeRef)=dlsym(library,"SCPreferencesCommitChanges"),(*apply)(CFTypeRef)=dlsym(library,"SCPreferencesApplyChanges");
    if(!create||!prefsLock||!prefsUnlock||!currentSet||!copyServices||!getInterface||!bsdName||!copyProtocol||!getConfig||!setConfig||!commit||!apply)return failure(@"unavailable",@"Required network configuration APIs are missing");
    CFTypeRef prefs=create(NULL,CFSTR("HPhone Touch owner Wi-Fi proxy"),NULL);if(!prefs)return failure(@"permission",@"Network preferences are not accessible to this daemon");
    BOOL writing=![operation isEqual:@"getProxy"],locked=NO;CFTypeRef set=NULL,protocol=NULL;CFArrayRef services=NULL;NSDictionary *result=nil;
    @try {
        if(writing){locked=prefsLock(prefs,false);if(!locked)return failure(@"permission",@"Network preferences are locked or require additional system authorization");}
        set=currentSet(prefs);services=set?copyServices(set):NULL;
        if(services)for(CFIndex i=0;i<CFArrayGetCount(services);i++){CFTypeRef service=CFArrayGetValueAtIndex(services,i),interface=getInterface(service);CFStringRef name=interface?bsdName(interface):NULL;if(name&&CFEqual(name,CFSTR("en0"))){protocol=copyProtocol(service,CFSTR("Proxies"));break;}}
        if(!protocol)return failure(@"unavailable",@"No existing Wi-Fi (en0) proxy protocol exists in the current network set");
        NSDictionary *original=[(__bridge NSDictionary *)getConfig(protocol) copy]?:@{};
        if(!writing)return success(@{@"enabled":@([original[@"HTTPEnable"] boolValue]||[original[@"HTTPSEnable"] boolValue]||[original[@"SOCKSEnable"] boolValue]||[original[@"ProxyAutoConfigEnable"] boolValue]||[original[@"ProxyAutoDiscoveryEnable"] boolValue]),@"manual":@([original[@"HTTPEnable"] boolValue]||[original[@"HTTPSEnable"] boolValue]),@"host":original[@"HTTPProxy"]?:original[@"HTTPSProxy"]?:@"",@"port":original[@"HTTPPort"]?:original[@"HTTPSPort"]?:@0,@"username":original[@"HTTPUser"]?:@""});
        NSMutableDictionary *next=[original mutableCopy];
        if([operation isEqual:@"clearProxy"]){next[@"HTTPEnable"]=@0;next[@"HTTPSEnable"]=@0;next[@"SOCKSEnable"]=@0;next[@"ProxyAutoConfigEnable"]=@0;next[@"ProxyAutoDiscoveryEnable"]=@0;for(NSString *key in @[@"HTTPProxy",@"HTTPPort",@"HTTPUser",@"HTTPSProxy",@"HTTPSPort",@"HTTPSUser"])[next removeObjectForKey:key];}
        else{
            NSString *spec=arguments[@"proxy"],*host=arguments[@"host"];NSNumber *port=arguments[@"port"];
            if(spec){if(!string(spec))return failure(@"arguments",@"proxy must be host:port");NSArray *parts=[spec componentsSeparatedByString:@":"];if(parts.count!=2)return failure(@"unsupported",@"Authenticated proxy and IPv6 string syntax require separate credential integration; use explicit host/port for IPv6");host=parts[0];port=@([parts[1] integerValue]);}
            if(!string(host)||!host.length||host.length>253||!boolean(port)||port.integerValue<1||port.integerValue>65535||[host rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound)return failure(@"arguments",@"Valid host and port 1..65535 required");
            if(arguments[@"username"]||arguments[@"password"])return failure(@"unsupported",@"System proxy authentication requires separately scoped keychain integration");
            next[@"HTTPEnable"]=@1;next[@"HTTPSEnable"]=@1;next[@"HTTPProxy"]=host;next[@"HTTPSProxy"]=host;next[@"HTTPPort"]=port;next[@"HTTPSPort"]=port;next[@"SOCKSEnable"]=@0;next[@"ProxyAutoConfigEnable"]=@0;next[@"ProxyAutoDiscoveryEnable"]=@0;
        }
        NSData *snapshot=[NSPropertyListSerialization dataWithPropertyList:original format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        if(!snapshot||!ensureDirectory(dataBase(),NULL)||!atomicPrivateFile([dataBase() stringByAppendingPathComponent:@"network-before-proxy.plist"],snapshot))return failure(@"backup",@"Cannot save the private pre-change proxy configuration");
        if(!setConfig(protocol,(__bridge CFDictionaryRef)next)||!commit(prefs)||!apply(prefs)){
            BOOL rolledBack=setConfig(protocol,(__bridge CFDictionaryRef)original)&&commit(prefs)&&apply(prefs);
            return @{@"ok":@NO,@"code":@"permission",@"error":@"Wi-Fi proxy configuration was denied or could not be applied",@"rolledBack":@(rolledBack)};
        }
        NSDictionary *actual=(__bridge NSDictionary *)getConfig(protocol);if(![actual isEqual:next])return failure(@"notApplied",@"Proxy commit returned success but stored configuration does not match");result=success(@YES);
    } @finally {if(protocol)CFRelease(protocol);if(services)CFRelease(services);if(set)CFRelease(set);if(locked)prefsUnlock(prefs);CFRelease(prefs);}
    return result?:failure(@"unavailable",@"Proxy operation did not produce a result");
#endif
}

NSDictionary *HPServiceCapabilities(void) {
    setup();return @{@"appInfo":@(NSClassFromString(@"LSApplicationProxy")!=nil),@"appLaunch":@(launchApp!=NULL||workspace()!=nil),@"foreground":@(copyFrontmost!=NULL),@"processQuery":@(canCheckPID()),@"lockState":@(springboardPort&&getLockStatus),
        @"appDataBackup":@YES,@"appDataRestore":@YES,@"appDataWipe":@YES,@"backupMaxBytes":@(512ULL*1024*1024),@"backupMaxEntries":@50000,@"backupKeychain":@NO,@"safariOfflineCookies":@YES,@"safariLiveCookies":@NO,@"systemKeychain":@NO,@"globalGPS":@NO,@"radioControlAPIAvailable":@(NSClassFromString(@"RadiosPreferences")&&NSClassFromString(@"WFClient")),@"systemProxyAPIImplemented":@YES,@"proxyAuthentication":@NO,@"shellUser":@"mobile",@"shellTimeoutMax":@30};
}

NSDictionary *HPService(NSString *operation,NSDictionary *arguments) {
    setup();if(!string(operation)||![arguments isKindOfClass:NSDictionary.class])return failure(@"arguments",@"operation and arguments are required");
    @try {
    if([operation isEqual:@"capabilities"])return success(HPServiceCapabilities());
    if([@[@"getCookies",@"getCookieHeader",@"getCookiesJSON",@"getCookiesText",@"safariCookiesPath",@"importCookies",@"deleteCookies",@"restoreCookies"] containsObject:operation]){
        [serviceLock lock];@try{return cookieOperation(operation,arguments);}@finally{[serviceLock unlock];}
    }
    if([@[@"airplaneMode",@"radioAirplane",@"wifi",@"radioWifi",@"getRadios"] containsObject:operation]){
        [serviceLock lock];@try{
            if([operation isEqual:@"getRadios"]){NSDictionary *air=radioOperation(@"airplaneMode",@{}),*wifi=radioOperation(@"wifi",@{});return success(@{@"airplane":air[@"value"]?:NSNull.null,@"wifi":wifi[@"value"]?:NSNull.null,@"cellular":NSNull.null,@"errors":@{@"airplane":air[@"error"]?:@"",@"wifi":wifi[@"error"]?:@"",@"cellular":@"Cellular control unavailable on this build"}});}
            return radioOperation(operation,arguments);
        }@finally{[serviceLock unlock];}
    }
    if([@[@"setProxy",@"clearProxy",@"getProxy"] containsObject:operation]){[serviceLock lock];@try{return proxyOperation(operation,arguments);}@finally{[serviceLock unlock];}}
    if([operation isEqual:@"overlay"]){
        [serviceLock lock];@try {
            NSString *file=[dataBase() stringByAppendingPathComponent:@"ui-preferences.json"];
            NSData *old=[NSData dataWithContentsOfFile:file];id parsed=old.length&&old.length<16384?[NSJSONSerialization JSONObjectWithData:old options:0 error:NULL]:nil;
            NSMutableDictionary *preferences=[parsed isKindOfClass:NSDictionary.class]?[parsed mutableCopy]:[NSMutableDictionary new];
            if(!preferences[@"overlayEnabled"])preferences[@"overlayEnabled"]=@NO;
            if(arguments[@"enabled"]){if(!boolean(arguments[@"enabled"]))return failure(@"arguments",@"enabled must be boolean");preferences[@"overlayEnabled"]=@([arguments[@"enabled"] boolValue]);}
            if(arguments[@"lastScript"]){NSString *last=arguments[@"lastScript"];if(!string(last)||!last.length||last.length>1024||last.isAbsolutePath||![last hasSuffix:@".lua"]||[last.pathComponents containsObject:@".."]||[last hasPrefix:@"."])return failure(@"arguments",@"lastScript must be a relative Lua script name");preferences[@"lastScript"]=last;}
            if(arguments.count){NSData *bytes=[NSJSONSerialization dataWithJSONObject:preferences options:NSJSONWritingSortedKeys error:NULL];if(!ensureDirectory(dataBase(),NULL)||![bytes writeToFile:file options:NSDataWritingAtomic error:NULL])return failure(@"file",@"Could not write overlay preference");chmod(file.fileSystemRepresentation,0600);}
            preferences[@"requiresSpringBoardLoad"]=@YES;preferences[@"runtimeVerified"]=@NO;return success(preferences);
        } @finally {[serviceLock unlock];}
    }
    if([operation isEqual:@"execute"])return executeCommand(arguments);
    if([operation isEqual:@"deviceInfo"]||[operation isEqual:@"captureDebugInfo"])return success(deviceInfo());
    if([operation isEqual:@"getLocalIP"])return success(localIP());
    if([operation isEqual:@"memoryUsageOfTotal"])return memoryFor(getpid());
    if([operation isEqual:@"getSN"]){if(!gestaltAnswer)return failure(@"unavailable",@"MobileGestalt serial lookup unavailable");id serial=CFBridgingRelease(gestaltAnswer(CFSTR("SerialNumber")));return string(serial)?success(serial):failure(@"permission",@"Serial number lookup not permitted");}
    if([operation isEqual:@"frontMostAppId"]){NSString *front=frontmost();return front?success(front):failure(@"unavailable",@"SpringBoard foreground lookup unavailable");}
    if([operation isEqual:@"runningApps"]){if(!copyRunning)return failure(@"unavailable",@"SpringBoard running-app lookup unavailable");id apps=CFBridgingRelease(copyRunning(YES,NO));return [apps isKindOfClass:NSArray.class]?success(apps):failure(@"permission",@"Cannot read running applications");}
    if([operation isEqual:@"listInstalledApps"]){
#ifdef HP_HOST_TEST
        NSDictionary *map=[NSDictionary dictionaryWithContentsOfFile:NSProcessInfo.processInfo.environment[@"HPHONE_TEST_APPS"]];return success(map.allValues?:@[]);
#else
        NSArray *proxies=invoke(workspace(),@"allApplications");if(![proxies isKindOfClass:NSArray.class])return failure(@"unavailable",@"LaunchServices application list unavailable");NSMutableArray *apps=[NSMutableArray new];
        for(id proxy in proxies){NSString *identifier=invoke(proxy,@"applicationIdentifier");if(bundleID(identifier)){NSDictionary *info=appInfo(identifier);if(info)[apps addObject:info];}}return success(apps);
#endif
    }
    NSSet *appOps=[NSSet setWithArray:@[@"appInfo",@"appRun",@"appActivate",@"appState",@"appIsActive",@"appKill",@"memoryUsageOfApp",@"backupApp",@"restoreApp",@"wipeApp",@"deleteBackup"]];
    if([appOps containsObject:operation]&&!bundleID(arguments[@"bundleId"]))return failure(@"arguments",@"A valid bundleId is required");
    NSString *identifier=arguments[@"bundleId"];
    if([operation isEqual:@"appInfo"]){NSDictionary *info=appInfo(identifier);return info?success(info):failure(@"notFound",@"Application not installed");}
    if([operation isEqual:@"appState"]||[operation isEqual:@"appIsActive"]){NSString *front=frontmost();if(!front||!canCheckPID())return failure(@"unavailable",@"Cannot determine complete app state on this iOS build");BOOL active=[front isEqual:identifier];return success([operation isEqual:@"appIsActive"]?@(active):(active?@"ACTIVATED":appPID(identifier)>0?@"DEACTIVATED":@"NOT RUNNING"));}
    if([operation isEqual:@"memoryUsageOfApp"]){pid_t pid=appPID(identifier);return pid>0?memoryFor(pid):failure(@"notRunning",@"Application is not running or PID lookup is unavailable");}
    if([operation isEqual:@"appRun"]||[operation isEqual:@"appActivate"]){
        if(!appInfo(identifier))return failure(@"notFound",@"Application not installed");
        if(!launchApp)return failure(@"unavailable",@"SpringBoard application launch API unavailable");
        uint32_t code=launchApp((__bridge CFStringRef)identifier,(__bridge CFDictionaryRef)@{},NO);if(code)return failure(@"launch",[NSString stringWithFormat:@"SpringBoard launch failed (%u)",code]);
        if([operation isEqual:@"appRun"])return success(@YES);
        if(!copyFrontmost)return failure(@"unavailable",@"Application launched, but foreground confirmation is unavailable");
        double timeout=arguments[@"timeout"]?[arguments[@"timeout"] doubleValue]:10;if(!isfinite(timeout)||timeout<0||timeout>30)return failure(@"arguments",@"timeout must be 0..30 seconds");
        double until=NSProcessInfo.processInfo.systemUptime+timeout;do{if([frontmost() isEqual:identifier])return success(@YES);usleep(50000);}while(NSProcessInfo.processInfo.systemUptime<until);return success(@NO);
    }
    if([operation isEqual:@"appKill"]){
        if([identifier isEqual:@"com.apple.springboard"]||[identifier isEqual:@"com.apple.backboardd"]||[identifier hasPrefix:@"io.github.jmehiepp.hphone-touch"])return failure(@"protected",@"SpringBoard and HPhone Touch are protected from appKill");
        NSDictionary *info=appInfo(identifier);pid_t pid=appPID(identifier);if(!info||!canCheckPID())return failure(@"unavailable",@"Cannot verify target application process");if(!pid)return success(@YES);
        char path[4096]={0};if(!procPidPath||procPidPath(pid,path,sizeof(path))<=0)return failure(@"verification",@"Cannot verify process executable before termination");
        NSString *executable=canonical(@(path)),*bundle=canonical(info[@"bundlePath"]);if(pid==getpid()||pid<2||!within(executable,bundle))return failure(@"verification",@"PID does not match the selected app bundle");
        if(kill(pid,SIGTERM))return failure(@"permission",@"Cannot terminate selected application");return success(@YES);
    }
    if([operation isEqual:@"openURL"]){NSString *text=arguments[@"url"];NSURL *url=string(text)?[NSURL URLWithString:text]:nil;if(!url.scheme.length||text.length>8192)return failure(@"arguments",@"A valid URL with a scheme is required");id ws=workspace();SEL sel=NSSelectorFromString(@"openURL:");if(![ws respondsToSelector:sel])return failure(@"unavailable",@"LaunchServices URL opening unavailable");BOOL ok=((BOOL(*)(id,SEL,id))objc_msgSend)(ws,sel,url);return ok?success(@YES):failure(@"openURL",@"No application accepted this URL");}
    if([operation isEqual:@"backupApp"]||[operation isEqual:@"restoreApp"]||[operation isEqual:@"wipeApp"]||[operation isEqual:@"deleteBackup"]){
        if(![operation isEqual:@"wipeApp"]&&!leafName(arguments[@"name"]))return failure(@"arguments",@"Backup name must be a flat name containing 1..80 letters, digits, spaces, dot, underscore or hyphen");
        if(([operation isEqual:@"restoreApp"]||[operation isEqual:@"wipeApp"])&&![arguments[@"confirmBundle"] isEqual:identifier])return failure(@"confirmation",@"confirmBundle must match the target bundleId");
        [serviceLock lock];NSDictionary *result;
        @try {
        if([operation isEqual:@"backupApp"])result=backupApp(identifier,arguments[@"name"]);
        else if([operation isEqual:@"deleteBackup"]){NSString *folder=nil;NSDictionary *manifest=loadBackup(identifier,arguments[@"name"],&folder);BOOL ok=manifest&&[NSFileManager.defaultManager removeItemAtPath:folder error:NULL];result=ok?success(@YES):failure(@"notFound",@"Backup is missing, invalid or could not be deleted");}
        else {
            // An automatic pre-change backup retains the previous app data for recovery.
            NSString *name=[NSString stringWithFormat:@"before-%@-%@",[operation isEqual:@"wipeApp"]?@"wipe":@"restore",NSUUID.UUID.UUIDString];
            NSDictionary *saved=backupApp(identifier,name);
            if(![saved[@"ok"] boolValue])result=saved;
            else {NSDictionary *changed=replaceData(identifier,arguments[@"name"],[operation isEqual:@"wipeApp"]);NSMutableDictionary *withRecovery=[changed mutableCopy];withRecovery[@"recoveryBackup"]=name;result=withRecovery;}
        }
        } @finally {[serviceLock unlock];}return result;
    }
    if([operation isEqual:@"listBackups"]){
        if(identifier&&!bundleID(identifier))return failure(@"arguments",@"Invalid bundleId");[serviceLock lock];NSMutableArray *items=[NSMutableArray new];@try {
        NSArray *ids=identifier?@[identifier]:[NSFileManager.defaultManager contentsOfDirectoryAtPath:backupRoot() error:NULL];
        for(NSString *bid in ids)if(bundleID(bid))for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[backupRoot() stringByAppendingPathComponent:bid] error:NULL])if(leafName(name)){NSDictionary *m=loadBackup(bid,name,NULL);if(m)[items addObject:@{@"bundleId":bid,@"name":name,@"date":m[@"date"]?:@0,@"dataSize":m[@"dataSize"]?:@0,@"hasKeychain":@NO}];}
        } @finally {[serviceLock unlock];}return success(items);
    }
#ifndef HP_HOST_TEST
    if([operation isEqual:@"copyText"]||[operation isEqual:@"clipText"]){
        if([operation isEqual:@"copyText"]&&!string(arguments[@"text"]))return failure(@"arguments",@"text must be a string");
        __block NSString *value=nil;__block BOOL ok=YES;
        void (^work)(void)=^{@try{UIPasteboard *board=UIPasteboard.generalPasteboard;if(!board){ok=NO;return;}if([operation isEqual:@"copyText"])board.string=arguments[@"text"];value=board.string?:@"";if([operation isEqual:@"copyText"]&&![value isEqual:arguments[@"text"]])ok=NO;}@catch(NSException *exception){ok=NO;}};
        if(NSThread.isMainThread)work();else dispatch_sync(dispatch_get_main_queue(),work);
        return ok?success([operation isEqual:@"copyText"]?@YES:value):failure(@"permission",@"System clipboard is unavailable to this daemon");
    }
    if([operation isEqual:@"brightness"]){if(arguments[@"value"]){double value=[arguments[@"value"] doubleValue];if(!boolean(arguments[@"value"])||!isfinite(value)||value<0||value>1)return failure(@"arguments",@"Brightness must be 0..1");void (^work)(void)=^{UIScreen.mainScreen.brightness=value;};if(NSThread.isMainThread)work();else dispatch_sync(dispatch_get_main_queue(),work);}return success(@(UIScreen.mainScreen.brightness));}
    if([operation isEqual:@"isScreenLocked"]){if(!springboardPort||!getLockStatus)return failure(@"unavailable",@"Screen lock API unavailable");mach_port_t port=springboardPort();if(!port)return failure(@"permission",@"SpringBoard port unavailable");BOOL locked=NO,passcode=NO;getLockStatus(port,&locked,&passcode);return success(@(locked));}
    if([operation isEqual:@"keepAutoTouchAwake"]||[operation isEqual:@"isKeepingAutoTouchAwake"]){
        [serviceLock lock];@try{if([operation isEqual:@"keepAutoTouchAwake"]){if(!boolean(arguments[@"enabled"]))return failure(@"arguments",@"enabled must be boolean");BOOL enabled=[arguments[@"enabled"] boolValue];
            if(enabled&&!awakeAssertion){Class cls=NSClassFromString(@"BKSDisplayServices");(void)cls;return failure(@"unavailable",@"A verified SpringBoard idle-timer assertion helper is required; daemon-local idleTimerDisabled does not keep other apps awake");}
            if(!enabled){awakeAssertion=nil;awake=NO;}}
            return success(@(awake));} @finally {[serviceLock unlock];}
    }
    if([operation isEqual:@"vibrate"]){AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);return success(@YES);}
    if([operation isEqual:@"playAudio"]||[operation isEqual:@"stopAudio"]||[operation isEqual:@"pauseAudio"]||[operation isEqual:@"resumeAudio"]){
        [serviceLock lock];@try{
        if([operation isEqual:@"playAudio"]){NSString *path=arguments[@"path"];if(!string(path)||!path.isAbsolutePath)return failure(@"arguments",@"An absolute audio file path is required");NSString *resolved=canonical(path);struct stat st;if(!resolved||lstat(resolved.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size>64*1024*1024)return failure(@"file",@"Audio file missing, unsupported or exceeds 64 MiB");
            NSInteger times=arguments[@"times"]?[arguments[@"times"] integerValue]:1;if(times< -1||times>1000)return failure(@"arguments",@"Audio repeat count must be -1..1000");NSError *error=nil;AVAudioPlayer *next=[[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:resolved] error:&error];if(!next)return failure(@"audio",error.localizedDescription);next.numberOfLoops=times<0?-1:MAX(0,times-1);[audioPlayer stop];audioPlayer=next;return [audioPlayer play]?success(@YES):failure(@"audio",@"Audio playback could not start");}
        if([operation isEqual:@"stopAudio"]){[audioPlayer stop];audioPlayer=nil;return success(@YES);}if(!audioPlayer)return failure(@"audio",@"No audio has been loaded");if([operation isEqual:@"pauseAudio"])[audioPlayer pause];else if(![audioPlayer play])return failure(@"audio",@"Audio playback could not resume");return success(@YES);
        } @finally {[serviceLock unlock];}
    }
#endif
    return failure(@"unsupported",[NSString stringWithFormat:@"%@ is not implemented on this device. Safari live cookies, cross-app keychain, radio/proxy/GPS controls and global overlay require separately verified native helpers.",operation]);
    } @catch(NSException *exception) {return failure(@"nativeException",[NSString stringWithFormat:@"%@ failed: %@",operation,exception.reason?:exception.name]);}
}
