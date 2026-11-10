#import "Runtime.h"
#import "Bridge.h"
#import "Services.h"
#include "lauxlib.h"
#include <time.h>
#include <unistd.h>
#include <math.h>
@interface HPLuaContext:NSObject
@property NSString *name,*identifier;@property(copy) BOOL(^cancel)(void);
@end
@implementation HPLuaContext @end
static HPLuaContext *context(lua_State *L){return (__bridge HPLuaContext *)lua_touserdata(L,lua_upvalueindex(1));}
static NSString *stringArg(lua_State *L,int i){size_t n;const char *p=luaL_checklstring(L,i,&n);return [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];}
static int native(lua_State *L){int result=0;NSString *error=nil;@autoreleasepool{@try{
    HPLuaContext *c=context(L);NSString *kind=stringArg(L,1),*op=stringArg(L,2);id a=lua_isnoneornil(L,3)?@{}:HPReadObject(L,3,0);if(![a isKindOfClass:NSDictionary.class])a=@{};NSMutableDictionary *args=[a mutableCopy];args[@"owner"]=c.identifier;
    NSDictionary *r=nil;if([kind isEqual:@"input"])r=HPInputWithCancellation(op,args,c.cancel);
    else if([kind isEqual:@"visual"]){if([op isEqual:@"findImage"]){NSString *path=HPResolveFile(args[@"image"]);if(!path)r=@{@"error":@"Template path must be an existing script-store file"};else args[@"image"]=path;}if(!r)r=HPVisualWithCancellation(op,args,c.cancel);}
    else if([kind isEqual:@"service"])r=HPService(op,args);
    else if([kind isEqual:@"fs"])r=HPFile(args);
    else if([kind isEqual:@"http"])r=HPHTTP(args,c.cancel);
    else if([kind isEqual:@"ocr"])r=HPOCRWithOptions(args,c.cancel);
    else if([kind isEqual:@"schedule"])r=HPSchedule(args);
    else if([kind isEqual:@"ui"]){r=HPUI(args);if([args[@"type"] isEqual:@"dialog"]&&r[@"id"]){NSString *identifier=r[@"id"];for(;;){if(c.cancel()) {HPUI(@{@"action":@"cancel",@"id":identifier});r=@{@"error":@"Stopped by user"};break;}NSDictionary *state=HPUI(@{@"action":@"result",@"id":identifier});if(![state[@"pending"] boolValue]){r=state;break;}usleep(50000);}}}
    else if([kind isEqual:@"jobs"]){if([op isEqual:@"run"])r=HPStartScript(args[@"name"]);else if([op isEqual:@"stop"])r=@{@"ok":@YES,@"count":@(HPStopScripts(args[@"id"]))};else r=@{@"ok":@YES,@"jobs":HPJobs()};}
    if(!r)r=@{@"error":@"Unknown native operation"};HPPushObject(L,r);result=1;
}@catch(NSException *e){error=e.reason?:@"Invalid native arguments";}}
    if(error)return luaL_error(L,"%s",error.UTF8String);return result;
}
static int printLua(lua_State *L){@autoreleasepool{NSMutableArray *parts=[NSMutableArray new];for(int i=1;i<=lua_gettop(L);i++){size_t n;const char *s=luaL_tolstring(L,i,&n);[parts addObject:[[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding]?:@"<binary>"];lua_pop(L,1);}HPLog([parts componentsJoinedByString:@"\t"],context(L).identifier);}return 0;}
static int sleepLua(lua_State *L){double sec=luaL_checknumber(L,1);if(!isfinite(sec)||sec<0||sec>86400)return luaL_error(L,"sleep expects 0..86400 seconds");BOOL(^cancel)(void)=context(L).cancel;while(sec>0){if(cancel())return luaL_error(L,"Stopped by user");double step=fmin(sec,.05);usleep((useconds_t)(step*1e6));sec-=step;}return 0;}
static int jsonLua(lua_State *L){NSString *error=nil;@autoreleasepool{@try{NSString *op=stringArg(L,1);if([op isEqual:@"encode"]){id obj=HPReadObject(L,2,0);NSData *data=[NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingFragmentsAllowed|(lua_toboolean(L,3)?NSJSONWritingPrettyPrinted:0) error:NULL];if(data){lua_pushlstring(L,data.bytes,data.length);return 1;}}else{size_t n;const char *s=luaL_checklstring(L,2,&n);id obj=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:s length:n] options:NSJSONReadingFragmentsAllowed error:NULL];if(obj){HPPushObject(L,obj);return 1;}}error=@"Invalid JSON value";}@catch(NSException *e){error=e.reason;}}lua_pushnil(L);lua_pushstring(L,error.UTF8String);return 2;}
static int base64Lua(lua_State *L){@autoreleasepool{BOOL encode=lua_toboolean(L,1);size_t n;const char *s=luaL_checklstring(L,2,&n);NSData *data=[NSData dataWithBytes:s length:n];if(encode){NSString *text=[data base64EncodedStringWithOptions:0];lua_pushstring(L,text.UTF8String);return 1;}NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];text=[[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];NSData *decoded=[[NSData alloc] initWithBase64EncodedString:text?:@"!" options:0];if(decoded){lua_pushlstring(L,decoded.bytes,decoded.length);return 1;}lua_pushnil(L);lua_pushliteral(L,"Invalid base64");return 2;}}
static int millisLua(lua_State *L){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);lua_pushnumber(L,ts.tv_sec*1000.0+ts.tv_nsec/1e6);return 1;}
static int clearLua(lua_State *L){HPClearLog();return 0;}
static int rawScreenshot(lua_State *L){@autoreleasepool{NSData *data=HPScreenshot();if(data){lua_pushlstring(L,data.bytes,data.length);return 1;}}return luaL_error(L,"Screen capture unavailable");}
static int contextGC(lua_State *L){void **ptr=lua_touserdata(L,1);if(ptr&&*ptr){CFRelease(*ptr);*ptr=NULL;}return 0;}
static int foldLua(lua_State *L){NSString *source=stringArg(L,1);@autoreleasepool{NSString *folded=[[source stringByFoldingWithOptions:NSDiacriticInsensitiveSearch|NSCaseInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]] stringByReplacingOccurrencesOfString:@"đ" withString:@"d"];NSData *data=[folded dataUsingEncoding:NSUTF8StringEncoding];lua_pushlstring(L,data.bytes,data.length);}return 1;}
static void stopHook(lua_State *L,lua_Debug *ar){lua_getfield(L,LUA_REGISTRYINDEX,"hphone.context");HPLuaContext *c=(__bridge HPLuaContext *)lua_touserdata(L,-1);lua_pop(L,1);if(c.cancel())luaL_error(L,"Stopped by user");}
void HPRegisterLua(lua_State *L,NSString *name,NSString *identifier,BOOL(^cancel)(void)){
    HPLuaContext *c=[HPLuaContext new];c.name=name;c.identifier=identifier;c.cancel=cancel;
    // Kept alive by a retained pointer, released by the VM's sentinel __gc.
    void **sentinel=lua_newuserdatauv(L,sizeof(void *),0);*sentinel=(__bridge_retained void *)c;
    if(luaL_newmetatable(L,"hphone.context-owner")){lua_pushcfunction(L,contextGC);lua_setfield(L,-2,"__gc");}lua_setmetatable(L,-2);lua_setfield(L,LUA_REGISTRYINDEX,"hphone.sentinel");
    lua_pushlightuserdata(L,(__bridge void *)c);lua_setfield(L,LUA_REGISTRYINDEX,"hphone.context");
    const struct{const char *name;lua_CFunction fn;} funcs[]={{"_hp",native},{"print",printLua},{"log",printLua},{"sleep",sleepLua},{"_json",jsonLua},{"_b64",base64Lua},{"millis",millisLua},{"clearLog",clearLua},{"screenshotBytes",rawScreenshot},{"_fold",foldLua}};
    for(size_t i=0;i<sizeof(funcs)/sizeof(funcs[0]);i++){lua_pushlightuserdata(L,(__bridge void *)c);lua_pushcclosure(L,funcs[i].fn,1);lua_setglobal(L,funcs[i].name);}HPPushObject(L,name);lua_setglobal(L,"_HP_NAME");HPPushObject(L,HPScriptsRoot());lua_setglobal(L,"_HP_ROOT");HPPushObject(L,identifier);lua_setglobal(L,"_HP_ID");lua_sethook(L,stopHook,LUA_MASKCOUNT,1000);
}
