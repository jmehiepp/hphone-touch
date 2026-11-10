#import <Foundation/Foundation.h>
#include "lua.h"
void HPConfigureRuntime(NSString *data,NSString *assets);
NSString *HPScriptsRoot(void);
NSString *HPResolveFile(NSString *path);
NSDictionary *HPFile(NSDictionary *args);
NSDictionary *HPHTTP(NSDictionary *args,BOOL(^cancel)(void));
void HPPushObject(lua_State *L,id value);
id HPReadObject(lua_State *L,int index,int depth);
void HPRegisterLua(lua_State *L,NSString *name,NSString *identifier,BOOL(^cancel)(void));
NSDictionary *HPStartScript(NSString *name);
NSUInteger HPStopScripts(NSString *identifier);
NSArray *HPJobs(void);
void HPLog(NSString *message,NSString *identifier);
void HPClearLog(void);
NSDictionary *HPSchedule(NSDictionary *args);
NSArray *HPSchedules(void);
NSDictionary *HPUI(NSDictionary *args);
