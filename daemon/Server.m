#import <Foundation/Foundation.h>
#import "Bridge.h"
#import "Runtime.h"
#import "Services.h"
#include "lauxlib.h"
#include "lualib.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#ifdef HP_HOST_TEST
static NSString *jbroot(NSString *p){return NSProcessInfo.processInfo.environment[@"HPHONE_TEST_WEB"]?:p;}
#else
#include <roothide.h>
#endif
@interface HPJob:NSObject
@property NSString *identifier,*name;@property double started;@property(atomic) BOOL cancelled;
@end
@implementation HPJob @end
static NSString *base=@"/var/mobile/Library/HPhoneTouch",*token,*webRoot,*libraryRoot;
static NSRecursiveLock *lock;static NSMutableArray *logs,*timers,*events;
static NSMutableDictionary<NSString *,HPJob *> *jobs;static NSMutableDictionary *uiResults;
static NSUInteger sequence,jobSequence,eventSequence;static NSString *autoLaunch;
static double appHeartbeat,overlayHeartbeat;
static NSDictionary *memoryBudget;
static void *limitedAlloc(void *ud,void *ptr,size_t old,size_t size){size_t *used=ud,previous=ptr?old:0;if(!size){free(ptr);*used-=previous;return NULL;}if(size>32*1024*1024||*used-previous>32*1024*1024-size)return NULL;void *next=realloc(ptr,size);if(next)*used=*used-previous+size;return next;}
void HPLog(NSString *message,NSString *identifier){if(message.length>4096)message=[[message substringToIndex:4096] stringByAppendingString:@" … [truncated]"];[lock lock];[logs addObject:@{@"id":@(++sequence),@"text":message?:@"",@"script":identifier?:@""}];while(logs.count>500)[logs removeObjectAtIndex:0];[lock unlock];}
void HPClearLog(void){[lock lock];[logs removeAllObjects];[lock unlock];}
NSArray *HPJobs(void){[lock lock];NSMutableArray *list=[NSMutableArray new];for(HPJob *job in jobs.allValues)[list addObject:@{@"id":job.identifier,@"name":job.name,@"path":[HPScriptsRoot() stringByAppendingPathComponent:job.name],@"started":@(job.started),@"stopping":@(job.cancelled)}];[lock unlock];return list;}
NSUInteger HPStopScripts(NSString *identifier){[lock lock];NSUInteger count=0;for(HPJob *job in jobs.allValues)if(!identifier.length||[job.identifier isEqual:identifier]||[job.name isEqual:identifier]||[[HPScriptsRoot() stringByAppendingPathComponent:job.name] isEqual:identifier]){job.cancelled=YES;count++;}[lock unlock];return count;}
NSDictionary *HPStartScript(NSString *name){
    if(![name isKindOfClass:NSString.class]||![name hasSuffix:@".lua"])return @{@"error":@"A .lua script is required"};
    NSString *path=HPResolveFile(name);if(!path)return @{@"error":@"Script missing or unsafe path"};NSString *relative=[path substringFromIndex:HPScriptsRoot().length+1];NSDictionary *file=HPFile(@{@"action":@"read",@"path":relative});NSData *source=[[NSData alloc] initWithBase64EncodedString:file[@"base64"]?:@"" options:0];if(![file[@"ok"] boolValue]||source.length>1048576)return @{@"error":@"Script missing or exceeds 1 MiB"};
    [lock lock];if(jobs.count>=4){[lock unlock];return @{@"error":@"At most four scripts may run concurrently"};}HPJob *job=[HPJob new];job.name=relative;job.identifier=[NSString stringWithFormat:@"%@#%lu",relative,(unsigned long)++jobSequence];job.started=NSDate.date.timeIntervalSince1970;jobs[job.identifier]=job;[lock unlock];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        size_t allocated=0;lua_State *L=lua_newstate(limitedAlloc,&allocated);HPLog([@"Run: " stringByAppendingString:relative],job.identifier);
        if(L){luaL_openlibs(L);HPRegisterLua(L,relative,job.identifier,^BOOL{return job.cancelled;});
            NSString *compat=[libraryRoot stringByAppendingPathComponent:@"compat.lua"];int result=luaL_loadfilex(L,compat.fileSystemRepresentation,"t");if(!result)result=lua_pcall(L,0,0,0);
            if(!result)result=luaL_loadbufferx(L,source.bytes,source.length,path.UTF8String,"t");if(!result)result=lua_pcall(L,0,LUA_MULTRET,0);
            if(result){const char *msg=lua_tostring(L,-1);HPLog([NSString stringWithFormat:@"Error: %s",msg?:"Lua failure"],job.identifier);}else HPLog(@"Finished",job.identifier);lua_close(L);
        }else HPLog(@"Cannot create Lua VM",job.identifier);
        HPReleaseInputOwner(job.identifier);HPUI(@{@"action":@"cancelOwner",@"owner":job.identifier});[lock lock];[jobs removeObjectForKey:job.identifier];[lock unlock];
    }});return @{@"ok":@YES,@"id":job.identifier};
}
static void saveTimers(void){NSDictionary *data=@{@"timers":timers,@"autoLaunch":autoLaunch?:@""};NSData *json=[NSJSONSerialization dataWithJSONObject:data options:0 error:NULL];NSString *p=[base stringByAppendingPathComponent:@"schedule.json"];[json writeToFile:p options:NSDataWritingAtomic error:NULL];chmod(p.fileSystemRepresentation,0600);}
NSArray *HPSchedules(void){[lock lock];NSArray *list=[[NSArray alloc] initWithArray:timers copyItems:YES];[lock unlock];return list;}
NSDictionary *HPSchedule(NSDictionary *args){[lock lock];@try{
    NSString *action=args[@"action"],*name=args[@"name"];
    if([action isEqual:@"listAuto"])return @{@"ok":@YES,@"paths":autoLaunch.length?@[autoLaunch]:@[]};
    if([action isEqual:@"list"])return @{@"ok":@YES,@"schedules":HPSchedules()};
    if(![name isKindOfClass:NSString.class]||![name hasSuffix:@".lua"])return @{@"error":@".lua script name required"};
    BOOL mustExist=[action isEqual:@"set"]||([action isEqual:@"auto"]&&[args[@"enabled"] boolValue]);
    if(mustExist&&!HPResolveFile(name))return @{@"error":@"Existing .lua script required"};
    if([name isAbsolutePath])name=[name substringFromIndex:HPScriptsRoot().length+1];
    if([action isEqual:@"auto"]){autoLaunch=[args[@"enabled"] boolValue]?name:@"";saveTimers();return @{@"ok":@YES};}
    if(![@[@"set",@"remove"] containsObject:action])return @{@"error":@"Unknown schedule action"};
    double fire=[args[@"fireTime"] doubleValue],interval=[args[@"interval"] doubleValue];BOOL repeat=[args[@"repeat"] boolValue];if([action isEqual:@"set"]&&(!isfinite(fire)||fire<1||!isfinite(interval)||(repeat&&interval<1)))return @{@"error":@"Valid Unix fireTime and repeat interval >= 1 required"};
    NSIndexSet *matching=[timers indexesOfObjectsPassingTest:^BOOL(NSDictionary *item,NSUInteger i,BOOL *stop){return [item[@"name"] isEqual:name];}];
    if([action isEqual:@"set"]&&timers.count-matching.count>=128)return @{@"error":@"At most 128 timers"};[timers removeObjectsAtIndexes:matching];
    if([action isEqual:@"set"])[timers addObject:[@{@"name":name,@"fireTime":@(fire),@"repeat":@(repeat),@"interval":@(interval)} mutableCopy]];saveTimers();return @{@"ok":@YES};
}@finally{[lock unlock];}}
NSDictionary *HPUI(NSDictionary *args){[lock lock];@try{
    NSString *action=args[@"action"],*identifier=args[@"id"];
    double now=NSDate.date.timeIntervalSince1970;
    if([action isEqual:@"heartbeat"]){if([args[@"surface"] isEqual:@"app"])appHeartbeat=now;else if([args[@"surface"] isEqual:@"overlay"])overlayHeartbeat=now;return @{@"ok":@YES};}
    for(NSDictionary *event in [events copy])if([event[@"expires"] doubleValue]<now){[events removeObject:event];if([event[@"type"] isEqual:@"dialog"])uiResults[event[@"id"]]=@{@"error":@"UI request expired"};}
    while(uiResults.count>64)[uiResults removeObjectForKey:uiResults.allKeys.firstObject];
    if([action isEqual:@"result"]){NSDictionary *r=uiResults[identifier];if(r){[uiResults removeObjectForKey:identifier];return r;}return @{@"pending":@YES};}
    if([action isEqual:@"respond"]||[action isEqual:@"cancel"]){NSDictionary *found=nil;for(NSDictionary *e in events)if([e[@"id"] isEqual:identifier]){found=e;break;}if(found){[events removeObject:found];if([found[@"type"] isEqual:@"dialog"])uiResults[identifier]=[action isEqual:@"cancel"]?@{@"error":@"Dialog cancelled"}:@{@"ok":@YES,@"button":args[@"button"]?:@0,@"controls":[args[@"controls"] isKindOfClass:NSArray.class]?args[@"controls"]:found[@"controls"]?:@[]};}return @{@"ok":@YES};}
    if([action isEqual:@"cancelOwner"]){for(NSDictionary *e in [events copy])if([e[@"owner"] isEqual:args[@"owner"]]&&[e[@"type"] isEqual:@"dialog"]){[events removeObject:e];[uiResults removeObjectForKey:e[@"id"]];}return @{@"ok":@YES};}
    if(!args[@"type"])return @{@"ok":@YES,@"events":[events copy]};
    if(events.count>=32)return @{@"error":@"UI queue full"};NSString *type=args[@"type"];if(![@[@"toast",@"alert",@"dialog"] containsObject:type])return @{@"error":@"Unknown UI event"};
    NSMutableDictionary *event=[args mutableCopy];event[@"target"]=(now-appHeartbeat>3&&now-overlayHeartbeat<5)?@"overlay":@"app";event[@"id"]=[NSString stringWithFormat:@"ui-%lu",(unsigned long)++eventSequence];event[@"expires"]=@(now+([type isEqual:@"toast"]?MAX(1,MIN(30,[args[@"seconds"] doubleValue]?:3)):300));[events addObject:event];return @{@"ok":@YES,@"id":event[@"id"]};
}@finally{[lock unlock];}}
static NSData *json(id o){return [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];}
static void reply(int fd,int status,NSString *type,NSData *data){NSString *head=[NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; img-src 'self' blob:; style-src 'self'; script-src 'self'; frame-ancestors 'none'\r\n\r\n",status,status==200?@"OK":@"Error",type,(unsigned long)data.length];NSMutableData *out=[NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];[out appendData:data];const char *p=out.bytes;size_t n=out.length;while(n){ssize_t sent=send(fd,p,n,0);if(sent<=0)break;p+=sent;n-=sent;}}
static void answer(int fd,int status,id body){reply(fd,status,@"application/json; charset=utf-8",json(body));}
static void result(int fd,NSDictionary *value){answer(fd,value[@"error"]?([value[@"ok"] boolValue]?200:400):200,value);}
static void handle(int fd){
    struct timeval timeout={5,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    NSMutableData *raw=[NSMutableData new];NSRange boundary=NSMakeRange(NSNotFound,0);char buffer[8192];NSData *sep=[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while(raw.length<16384){ssize_t n=recv(fd,buffer,sizeof(buffer),0);if(n<=0)return;[raw appendBytes:buffer length:n];boundary=[raw rangeOfData:sep options:0 range:NSMakeRange(0,raw.length)];if(boundary.location!=NSNotFound)break;}
    if(boundary.location==NSNotFound||boundary.location>16384){answer(fd,400,@{@"error":@"Invalid headers"});return;}
    NSString *header=[[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0,boundary.location)] encoding:NSUTF8StringEncoding];NSArray *lines=[header componentsSeparatedByString:@"\r\n"],*first=[lines.firstObject componentsSeparatedByString:@" "];if(first.count!=3){answer(fd,400,@{@"error":@"Invalid request"});return;}
    NSString *method=first[0],*path=first[1];NSMutableDictionary *headers=[NSMutableDictionary new];for(NSUInteger i=1;i<lines.count;i++){NSString *line=lines[i];NSRange c=[line rangeOfString:@":"];if(c.location==NSNotFound){answer(fd,400,@{@"error":@"Invalid header"});return;}NSString *key=[[line substringToIndex:c.location] lowercaseString];if(headers[key]){answer(fd,400,@{@"error":@"Duplicate header"});return;}headers[key]=[[line substringFromIndex:c.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];}
    if(headers[@"transfer-encoding"]){answer(fd,400,@{@"error":@"Chunked requests unsupported"});return;}NSString *length=headers[@"content-length"]?:@"0";if(!length.length||[length rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location!=NSNotFound||length.length>8||length.longLongValue>1048576){answer(fd,413,@{@"error":@"Request too large"});return;}
    NSUInteger start=boundary.location+4,needed=length.integerValue;while(raw.length<start+needed){ssize_t n=recv(fd,buffer,MIN(sizeof(buffer),start+needed-raw.length),0);if(n<=0)return;[raw appendBytes:buffer length:n];}
    if([path hasPrefix:@"/api/"]&&![headers[@"x-hphone-token"] isEqualToString:token]){answer(fd,401,@{@"error":@"Token required"});return;}
    NSDictionary *body=@{};if([method isEqual:@"POST"]){id obj=[NSJSONSerialization JSONObjectWithData:[raw subdataWithRange:NSMakeRange(start,needed)] options:0 error:NULL];if(![obj isKindOfClass:NSDictionary.class]){answer(fd,400,@{@"error":@"JSON object required"});return;}body=obj;}
    if([method isEqual:@"GET"]){
        if([path isEqual:@"/api/status"]||[path isEqual:@"/api/summary"]){[lock lock];NSArray *active=HPJobs(),*snapshot=[logs copy];[lock unlock];NSMutableDictionary *caps=[HPCapabilities() mutableCopy];caps[@"services"]=HPServiceCapabilities();caps[@"parallelScripts"]=@4;NSMutableDictionary *state=[@{@"running":@(active.count>0),@"jobs":active,@"capabilities":caps,@"memoryBudget":memoryBudget?:@{}} mutableCopy];if([path isEqual:@"/api/status"])state[@"logs"]=snapshot;answer(fd,200,state);return;}
        if([path isEqual:@"/api/jobs"]){answer(fd,200,@{@"jobs":HPJobs()});return;}
        if([path isEqual:@"/api/schedules"]){answer(fd,200,@{@"schedules":HPSchedules()});return;}
        if([path isEqual:@"/api/ui"]){answer(fd,200,HPUI(@{}));return;}
        if([path isEqual:@"/api/docs"]){NSData *d=[NSData dataWithContentsOfFile:[libraryRoot stringByAppendingPathComponent:@"api.json"]];if(d)reply(fd,200,@"application/json",d);else answer(fd,503,@{@"error":@"API index missing"});return;}
        if([path isEqual:@"/api/files"]){NSMutableArray *files=[NSMutableArray new];NSDirectoryEnumerator *enumerator=[NSFileManager.defaultManager enumeratorAtPath:HPScriptsRoot()];for(NSString *n in enumerator){if([n.lastPathComponent hasPrefix:@"."]){[enumerator skipDescendants];continue;}if([n hasSuffix:@".lua"]&&HPResolveFile(n))[files addObject:n];if(files.count>=2000)break;}answer(fd,200,@{@"files":[files sortedArrayUsingSelector:@selector(compare:)]});return;}
        if([path isEqual:@"/api/screen"]){NSData *d=HPScreenshot();if(d)reply(fd,200,@"image/png",d);else answer(fd,503,@{@"error":@"Screen bridge unavailable"});return;}
        NSDictionary *staticFiles=@{@"/":@[@"index.html",@"text/html; charset=utf-8"],@"/app.js":@[@"app.js",@"text/javascript; charset=utf-8"],@"/style.css":@[@"style.css",@"text/css; charset=utf-8"]};NSArray *asset=staticFiles[path];if(asset){NSData *d=[NSData dataWithContentsOfFile:[webRoot stringByAppendingPathComponent:asset[0]]];if(d){reply(fd,200,asset[1],d);return;}}
    }
    if([method isEqual:@"POST"]){
        if([path isEqual:@"/api/run"]){NSDictionary *r=HPStartScript(body[@"name"]);answer(fd,r[@"error"]?409:200,r);return;}
        if([path isEqual:@"/api/stop"]){id target=body[@"id"]?:body[@"name"];if(target&&![target isKindOfClass:NSString.class]){answer(fd,400,@{@"error":@"Invalid script identifier"});return;}answer(fd,200,@{@"ok":@YES,@"count":@(HPStopScripts(target))});return;}
        if([path isEqual:@"/api/clear-log"]){HPClearLog();answer(fd,200,@{@"ok":@YES});return;}
        if([path isEqual:@"/api/fs"]){result(fd,HPFile(body));return;}
        if([path isEqual:@"/api/file"]){if(![body[@"name"] isKindOfClass:NSString.class]||![body[@"name"] hasSuffix:@".lua"]){answer(fd,400,@{@"error":@"Invalid script name"});return;}NSMutableDictionary *args=[body mutableCopy];args[@"path"]=args[@"name"];if([args[@"action"] isEqual:@"save"])args[@"action"]=@"write";result(fd,HPFile(args));return;}
        if([path isEqual:@"/api/schedule"]){result(fd,HPSchedule(body));return;}
        if([path isEqual:@"/api/ui"]){result(fd,HPUI(body));return;}
        if([path isEqual:@"/api/ocr"]){NSDictionary *r=HPOCRWithOptions(body,nil);answer(fd,r[@"error"]?503:200,r);return;}
        if([path isEqual:@"/api/tap"]){NSDictionary *r=HPInput(@"tap",body);answer(fd,r[@"error"]?503:200,r);return;}
        if([path isEqual:@"/api/key"]){NSDictionary *r=HPInput(@"keyPress",body);answer(fd,r[@"error"]?503:200,r);return;}
        if([@[@"/api/input",@"/api/visual",@"/api/service"] containsObject:path]){id op=body[@"operation"],args=body[@"args"]?:@{};if(![op isKindOfClass:NSString.class]||![args isKindOfClass:NSDictionary.class]){answer(fd,400,@{@"error":@"operation and object args required"});return;}NSDictionary *r=[path isEqual:@"/api/input"]?HPInput(op,args):[path isEqual:@"/api/visual"]?HPVisual(op,args):HPService(op,args);result(fd,r);return;}
    }
    answer(fd,404,@{@"error":@"Not found"});
}
static void serve(int fd){@autoreleasepool{@try{handle(fd);}@catch(NSException *e){answer(fd,400,@{@"error":@"Invalid request fields"});}}}
static void runAuto(void){[lock lock];NSString *name=autoLaunch;[lock unlock];if(name.length){NSDictionary *r=HPStartScript(name);if(r[@"error"])HPLog([@"Auto launch: " stringByAppendingString:r[@"error"]],nil);}}
#ifndef HP_HOST_TEST
static void springboardStarted(CFNotificationCenterRef center,void *observer,CFStringRef name,const void *object,CFDictionaryRef userInfo){runAuto();}
#endif
int main(void){@autoreleasepool{
#ifndef HP_HOST_TEST
    setenv("HOME","/var/mobile",1);setenv("CFFIXED_USER_HOME","/var/mobile",1);setenv("TMPDIR","/var/tmp",1);
    extern int memorystatus_control(uint32_t,int32_t,uint32_t,void *,size_t);struct{int32_t active;uint32_t aa;int32_t inactive;uint32_t ia;} limits={256,1,256,1};errno=0;int code=memorystatus_control(7,getpid(),0,&limits,sizeof(limits)),err=errno;if(!code)memorystatus_control(8,getpid(),0,&limits,sizeof(limits));memoryBudget=@{@"setResult":@(code),@"errno":@(err),@"activeMB":@(limits.active),@"inactiveMB":@(limits.inactive)};
#else
    base=NSProcessInfo.processInfo.environment[@"HPHONE_TEST_DATA"];if(!base.length)return 4;
#endif
    lock=[NSRecursiveLock new];logs=[NSMutableArray new];jobs=[NSMutableDictionary new];timers=[NSMutableArray new];events=[NSMutableArray new];uiResults=[NSMutableDictionary new];
    webRoot=jbroot(@"/usr/share/hphone-touch/web");libraryRoot=[webRoot stringByDeletingLastPathComponent];HPConfigureRuntime(base,libraryRoot);
    NSFileManager *fm=NSFileManager.defaultManager;if(![fm createDirectoryAtPath:HPScriptsRoot() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL])return 1;chmod(base.fileSystemRepresentation,0700);chmod(HPScriptsRoot().fileSystemRepresentation,0700);
    NSString *p=[base stringByAppendingPathComponent:@"token"];token=[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];if(token.length<32){token=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];if(![token writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL])return 2;}chmod(p.fileSystemRepresentation,0600);
    if(!HPResolveFile(@"hello.lua"))HPFile(@{@"action":@"write",@"path":@"hello.lua",@"content":@"print('Hello from HPhone Touch')\nfor i=1,3 do print('Step',i); sleep(1) end\n"});
    NSData *stored=[NSData dataWithContentsOfFile:[base stringByAppendingPathComponent:@"schedule.json"]];id schedule=stored?[NSJSONSerialization JSONObjectWithData:stored options:0 error:NULL]:nil;if([schedule isKindOfClass:NSDictionary.class]){if([schedule[@"timers"] isKindOfClass:NSArray.class])for(id t in schedule[@"timers"])if([t isKindOfClass:NSDictionary.class]&&timers.count<128)[timers addObject:[t mutableCopy]];if([schedule[@"autoLaunch"] isKindOfClass:NSString.class])autoLaunch=schedule[@"autoLaunch"];}
    NSString *portPath=[base stringByAppendingPathComponent:@"port"];NSInteger saved=[[NSString stringWithContentsOfFile:portPath encoding:NSUTF8StringEncoding error:NULL] integerValue];int port=saved>=1024&&saved<=65535?(int)saved:8765;
    int server=socket(AF_INET,SOCK_STREAM,0),yes=1;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));struct sockaddr_in addr={0};addr.sin_family=AF_INET;addr.sin_port=htons(port);addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(server,(struct sockaddr *)&addr,sizeof(addr))||listen(server,16)){if(errno!=EADDRINUSE){close(server);return 3;}close(server);server=socket(AF_INET,SOCK_STREAM,0);addr.sin_port=0;if(bind(server,(struct sockaddr *)&addr,sizeof(addr))||listen(server,16)){close(server);return 3;}}
    socklen_t size=sizeof(addr);if(getsockname(server,(struct sockaddr *)&addr,&size)){close(server);return 3;}if(![[NSString stringWithFormat:@"%u",ntohs(addr.sin_port)] writeToFile:portPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]){close(server);return 3;}chmod(portPath.fileSystemRepresentation,0600);
    for(int i=0;i<6;i++)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{for(;;){int fd=accept(server,NULL,NULL);if(fd>=0){serve(fd);close(fd);}}});
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{for(;;){@autoreleasepool{NSMutableArray *due=[NSMutableArray new];[lock lock];double now=NSDate.date.timeIntervalSince1970;BOOL changed=NO;for(NSMutableDictionary *timer in [timers copy])if([timer[@"fireTime"] doubleValue]<=now){[due addObject:timer[@"name"]?:@""];double interval=[timer[@"interval"] doubleValue];if([timer[@"repeat"] boolValue]&&interval>=1)timer[@"fireTime"]=@(now+interval);else[timers removeObject:timer];changed=YES;}if(changed)saveTimers();[lock unlock];for(NSString *name in due){NSDictionary *r=HPStartScript(name);if(r[@"error"])HPLog([@"Timer: " stringByAppendingString:r[@"error"]],nil);}}usleep(250000);}});
#ifndef HP_HOST_TEST
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,springboardStarted,CFSTR("com.apple.springboard.finishedstartup"),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
#endif
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{runAuto();});HPLog(@"HPhone Touch 0.2.0 ready",nil);dispatch_main();return 0;
}}
