#import <Foundation/Foundation.h>
#import "Bridge.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#ifdef HP_HOST_TEST
static NSString *jbroot(NSString *path){return NSProcessInfo.processInfo.environment[@"HPHONE_TEST_WEB"]?:path;}
#else
#include <roothide.h>
#endif

static NSString *base=@"/var/mobile/Library/HPhoneTouch", *scripts, *token, *webRoot;
static NSLock *lock;
static NSMutableArray *logs;
static BOOL running;
static atomic_bool cancelled;
static NSUInteger sequence;
static void *limitedAlloc(void *ud,void *ptr,size_t oldSize,size_t newSize) {
    size_t *used=ud,previous=ptr?oldSize:0;
    if(!newSize){free(ptr);*used-=previous;return NULL;}
    if(newSize>32*1024*1024 || *used-previous>32*1024*1024-newSize)return NULL;
    void *next=realloc(ptr,newSize);if(next)*used=*used-previous+newSize;return next;
}

static void logLine(NSString *message) {
    if(message.length>4096)message=[[message substringToIndex:4096] stringByAppendingString:@" … [truncated]"];
    [lock lock]; [logs addObject:@{@"id":@(++sequence),@"text":message?:@""}];
    if(logs.count>500)[logs removeObjectAtIndex:0]; [lock unlock];
}
static NSString *scriptPath(id name) {
    if(![name isKindOfClass:NSString.class] || [name length]<5 || [name length]>80 || ![name hasSuffix:@".lua"]) return nil;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. "];
    if([name rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound || [name hasPrefix:@"."])return nil;
    NSString *path=[scripts stringByAppendingPathComponent:name]; struct stat s;
    if(lstat(path.fileSystemRepresentation,&s)==0 && !S_ISREG(s.st_mode))return nil;
    return path;
}
static int lprint(lua_State *L) { @autoreleasepool {
    NSMutableArray *parts=[NSMutableArray array];
    for(int i=1;i<=lua_gettop(L);i++){size_t n;const char *s=luaL_tolstring(L,i,&n);[parts addObject:[[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding]?:@"<binary>"];lua_pop(L,1);}
    logLine([parts componentsJoinedByString:@"\t"]); return 0;
}}
static void stopHook(lua_State *L,lua_Debug *ar) { if(atomic_load(&cancelled))luaL_error(L,"Stopped by user"); }
static int lsleep(lua_State *L) {
    double sec=luaL_checknumber(L,1); if(!isfinite(sec)||sec<0||sec>86400)return luaL_error(L,"sleep expects 0..86400 seconds");
    while(sec>0){if(atomic_load(&cancelled))return luaL_error(L,"Stopped by user");double step=fmin(sec,.05);usleep((useconds_t)(step*1000000));sec-=step;}return 0;
}
static int ltap(lua_State *L){double x=luaL_checknumber(L,1),y=luaL_checknumber(L,2);BOOL ok;@autoreleasepool{ok=HPTap(x,y);}if(!ok)return luaL_error(L,"Touch bridge unavailable, or coordinates outside screen");return 0;}
static int lkey(lua_State *L){const char *key=luaL_checkstring(L,1);BOOL ok;@autoreleasepool{ok=HPKey([NSString stringWithUTF8String:key]);}if(!ok)return luaL_error(L,"Key bridge unavailable or unknown key");return 0;}
static int lscreenshot(lua_State *L){BOOL ok;@autoreleasepool{NSData *png=HPScreenshot();ok=png!=nil;if(ok)lua_pushlstring(L,png.bytes,png.length);}if(!ok)return luaL_error(L,"Screen capture unavailable");return 1;}
static int locr(lua_State *L){BOOL ok;@autoreleasepool{NSArray *items=HPOCR();ok=items!=nil;if(ok){lua_newtable(L);int i=0;for(NSDictionary *row in items){lua_newtable(L);for(NSString *key in row){id v=row[key];if([v isKindOfClass:NSString.class])lua_pushstring(L,[v UTF8String]);else lua_pushnumber(L,[v doubleValue]);lua_setfield(L,-2,key.UTF8String);}lua_rawseti(L,-2,++i);}}}if(!ok)return luaL_error(L,"OCR or screen capture unavailable");return 1;}
static void runScript(NSData *source,NSString *name) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        size_t allocated=0;lua_State *L=lua_newstate(limitedAlloc,&allocated);
        if(L){luaL_openlibs(L);lua_register(L,"print",lprint);lua_register(L,"log",lprint);lua_register(L,"sleep",lsleep);lua_register(L,"tap",ltap);lua_register(L,"key",lkey);lua_register(L,"screenshot",lscreenshot);lua_register(L,"ocr",locr);lua_sethook(L,stopHook,LUA_MASKCOUNT,1000);
            logLine([@"Run: " stringByAppendingString:name]);
            int result=luaL_loadbufferx(L,source.bytes,source.length,name.UTF8String,"t");if(!result)result=lua_pcall(L,0,LUA_MULTRET,0);
            if(result)logLine([NSString stringWithFormat:@"Error: %s",lua_tostring(L,-1)]);else logLine(@"Finished");lua_close(L);
        }else logLine(@"Cannot create Lua VM");
        [lock lock];running=NO;[lock unlock];
    }});
}
static NSData *json(id value){return [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];}
static void reply(int fd,int status,NSString *type,NSData *data) {
    NSString *head=[NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; img-src 'self' blob:; style-src 'self'; script-src 'self'; frame-ancestors 'none'\r\n\r\n",status,status==200?@"OK":@"Error",type,(unsigned long)data.length];
    NSMutableData *out=[NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];[out appendData:data];const char *p=out.bytes;size_t n=out.length;
    while(n){ssize_t sent=send(fd,p,n,0);if(sent<=0)break;p+=sent;n-=sent;}
}
static void answer(int fd,int status,id body){reply(fd,status,@"application/json; charset=utf-8",json(body));}
static void serve(int fd) { @autoreleasepool {
    struct timeval timeout={5,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    NSMutableData *raw=[NSMutableData data];NSRange boundary=NSMakeRange(NSNotFound,0);char buffer[8192];NSData *sep=[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while(raw.length<16384){ssize_t n=recv(fd,buffer,sizeof(buffer),0);if(n<=0)return;[raw appendBytes:buffer length:n];boundary=[raw rangeOfData:sep options:0 range:NSMakeRange(0,raw.length)];if(boundary.location!=NSNotFound)break;}
    if(boundary.location==NSNotFound||boundary.location>16384){answer(fd,400,@{@"error":@"Invalid headers"});return;}
    NSString *header=[[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0,boundary.location)] encoding:NSUTF8StringEncoding];NSArray *lines=[header componentsSeparatedByString:@"\r\n"],*first=[lines.firstObject componentsSeparatedByString:@" "];
    if(first.count!=3){answer(fd,400,@{@"error":@"Invalid request"});return;}NSString *method=first[0],*path=first[1];NSMutableDictionary *headers=[NSMutableDictionary dictionary];
    for(NSUInteger i=1;i<lines.count;i++){NSString *line=lines[i];NSRange c=[line rangeOfString:@":"];if(c.location==NSNotFound){answer(fd,400,@{@"error":@"Invalid header"});return;}NSString *key=[[line substringToIndex:c.location] lowercaseString];if(headers[key]){answer(fd,400,@{@"error":@"Duplicate header"});return;}headers[key]=[[line substringFromIndex:c.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];}
    if(headers[@"transfer-encoding"]){answer(fd,400,@{@"error":@"Chunked requests unsupported"});return;}
    NSString *length=headers[@"content-length"]?:@"0";NSCharacterSet *digits=NSCharacterSet.decimalDigitCharacterSet;
    if(!length.length||[length rangeOfCharacterFromSet:digits.invertedSet].location!=NSNotFound||length.length>8||length.longLongValue>1048576){answer(fd,413,@{@"error":@"Request too large"});return;}
    NSUInteger start=boundary.location+4,needed=length.integerValue;
    while(raw.length<start+needed){ssize_t n=recv(fd,buffer,MIN(sizeof(buffer),start+needed-raw.length),0);if(n<=0)return;[raw appendBytes:buffer length:n];}
    BOOL api=[path hasPrefix:@"/api/"];if(api&&![headers[@"x-hphone-token"] isEqualToString:token]){answer(fd,401,@{@"error":@"Token required"});return;}
    NSDictionary *body=@{};if([method isEqual:@"POST"]){id obj=[NSJSONSerialization JSONObjectWithData:[raw subdataWithRange:NSMakeRange(start,needed)] options:0 error:NULL];if(![obj isKindOfClass:NSDictionary.class]){answer(fd,400,@{@"error":@"JSON object required"});return;}body=obj;}
    if([method isEqual:@"GET"]&&[path isEqual:@"/api/status"]){[lock lock];NSDictionary *v=@{@"running":@(running),@"logs":[logs copy],@"capabilities":HPCapabilities()};[lock unlock];answer(fd,200,v);return;}
    if([method isEqual:@"GET"]&&[path isEqual:@"/api/files"]){NSMutableArray *files=[NSMutableArray array];for(NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:scripts error:NULL])if(scriptPath(n))[files addObject:n];answer(fd,200,@{@"files":[files sortedArrayUsingSelector:@selector(compare:)]});return;}
    if([method isEqual:@"GET"]&&[path isEqual:@"/api/screen"]){NSData *data=HPScreenshot();if(data)reply(fd,200,@"image/png",data);else answer(fd,503,@{@"error":@"Screen bridge unavailable"});return;}
    if([method isEqual:@"POST"]&&[path isEqual:@"/api/ocr"]){NSArray *items=HPOCR();answer(fd,items?200:503,items?@{@"items":items}:@{@"error":@"OCR unavailable"});return;}
    if([method isEqual:@"POST"]&&[path isEqual:@"/api/tap"]){id x=body[@"x"],y=body[@"y"];BOOL valid=[x isKindOfClass:NSNumber.class]&&[y isKindOfClass:NSNumber.class];BOOL ok=valid&&HPTap([x doubleValue],[y doubleValue]);answer(fd,ok?200:503,ok?@{@"dispatched":@YES}:@{@"error":@"Touch unavailable or invalid coordinates"});return;}
    if([method isEqual:@"POST"]&&[path isEqual:@"/api/key"]){id key=body[@"key"];BOOL ok=[key isKindOfClass:NSString.class]&&HPKey(key);answer(fd,ok?200:503,ok?@{@"dispatched":@YES}:@{@"error":@"Key unavailable"});return;}
    if([method isEqual:@"POST"]&&[path isEqual:@"/api/stop"]){atomic_store(&cancelled,true);answer(fd,200,@{@"ok":@YES});return;}
    if([method isEqual:@"POST"]&&([path isEqual:@"/api/file"]||[path isEqual:@"/api/run"])){NSString *file=scriptPath(body[@"name"]);if(!file){answer(fd,400,@{@"error":@"Invalid script name"});return;}NSString *action=body[@"action"];
        if([path isEqual:@"/api/run"]){NSData *source=[NSData dataWithContentsOfFile:file];if(!source||source.length>1048576){answer(fd,400,@{@"error":@"Script missing or too large"});return;}[lock lock];BOOL busy=running;if(!busy){running=YES;atomic_store(&cancelled,false);}[lock unlock];if(busy){answer(fd,409,@{@"error":@"A script is running"});return;}runScript(source,body[@"name"]);answer(fd,200,@{@"ok":@YES});return;}
        if([action isEqual:@"read"]){NSString *content=[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];answer(fd,content?200:404,content?@{@"content":content}:@{@"error":@"File missing or not UTF-8"});return;}
        if([action isEqual:@"delete"]){BOOL ok=[[NSFileManager defaultManager] removeItemAtPath:file error:NULL];answer(fd,ok?200:400,@{@"ok":@(ok)});return;}
        if([action isEqual:@"save"]&&[body[@"content"] isKindOfClass:NSString.class]){NSData *data=[body[@"content"] dataUsingEncoding:NSUTF8StringEncoding];int out=open(file.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);BOOL ok=out>=0;if(ok){const char *p=data.bytes;size_t n=data.length;while(n){ssize_t done=write(out,p,n);if(done<=0){ok=NO;break;}p+=done;n-=done;}close(out);}answer(fd,ok?200:500,@{@"ok":@(ok)});return;}
        answer(fd,400,@{@"error":@"Unknown action"});return;
    }
    if([method isEqual:@"GET"]){NSDictionary *assets=@{@"/":@[@"index.html",@"text/html; charset=utf-8"],@"/app.js":@[@"app.js",@"text/javascript; charset=utf-8"],@"/style.css":@[@"style.css",@"text/css; charset=utf-8"]};NSArray *asset=assets[path];if(asset){NSData *data=[NSData dataWithContentsOfFile:[webRoot stringByAppendingPathComponent:asset[0]]];if(data){reply(fd,200,asset[1],data);return;}}}
    answer(fd,404,@{@"error":@"Not found"});
}}
int main(void){@autoreleasepool {
#ifdef HP_HOST_TEST
    base=NSProcessInfo.processInfo.environment[@"HPHONE_TEST_DATA"];
    if(!base.length)return 4;
#endif
    lock=[NSLock new];logs=[NSMutableArray new];scripts=[base stringByAppendingPathComponent:@"scripts"];
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    if(![fm createDirectoryAtPath:scripts withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error])return 1;
    chmod(base.fileSystemRepresentation,0700);chmod(scripts.fileSystemRepresentation,0700);
    NSString *tokenPath=[base stringByAppendingPathComponent:@"token"];token=[NSString stringWithContentsOfFile:tokenPath encoding:NSUTF8StringEncoding error:NULL];
    if(token.length<32){token=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];if(![token writeToFile:tokenPath atomically:YES encoding:NSUTF8StringEncoding error:NULL])return 2;}
    chmod(tokenPath.fileSystemRepresentation,0600);webRoot=jbroot(@"/usr/share/hphone-touch/web");
    NSString *sample=[scripts stringByAppendingPathComponent:@"hello.lua"];if(![fm fileExistsAtPath:sample])[@"print('Hello from HPhone Touch')\nfor i=1,3 do\n  print('Step',i)\n  sleep(1)\nend\n" writeToFile:sample atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *portPath=[base stringByAppendingPathComponent:@"port"];
    NSInteger savedPort=[[NSString stringWithContentsOfFile:portPath encoding:NSUTF8StringEncoding error:NULL] integerValue];
    int preferredPort=(savedPort>=1024&&savedPort<=65535)?(int)savedPort:8765;
    int server=socket(AF_INET,SOCK_STREAM,0),yes=1;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));struct sockaddr_in addr={0};addr.sin_family=AF_INET;addr.sin_port=htons(preferredPort);addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(server,(struct sockaddr *)&addr,sizeof(addr))||listen(server,8)) {
        if(errno!=EADDRINUSE){close(server);return 3;}
        close(server);server=socket(AF_INET,SOCK_STREAM,0);addr.sin_port=0;
        if(bind(server,(struct sockaddr *)&addr,sizeof(addr))||listen(server,8)){close(server);return 3;}
    }
    socklen_t addrSize=sizeof(addr);
    if(getsockname(server,(struct sockaddr *)&addr,&addrSize)){close(server);return 3;}
    NSString *portValue=[NSString stringWithFormat:@"%u",ntohs(addr.sin_port)];
    if(![portValue writeToFile:portPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]){close(server);return 3;}
    chmod(portPath.fileSystemRepresentation,0600);
    // Four workers keep stop/status available while an OCR request is executing.
    for(int i=0;i<4;i++)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{for(;;){int fd=accept(server,NULL,NULL);if(fd>=0){serve(fd);close(fd);}}});
    logLine(@"HPhone Touch 0.1.3 ready; native bridges require device testing");dispatch_main();return 0;
}}
