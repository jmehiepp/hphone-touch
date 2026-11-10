#import "Runtime.h"
#include "lauxlib.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>
static NSString *root,*assets;
static NSRecursiveLock *fileLock;
void HPConfigureRuntime(NSString *data,NSString *resources){root=[data stringByAppendingPathComponent:@"scripts"];assets=resources;fileLock=[NSRecursiveLock new];}
NSString *HPScriptsRoot(void){return root;}
static NSDictionary *failure(NSString *text){return @{@"ok":@NO,@"error":text?:@"Operation failed"};}
// Walk every ancestor with openat(O_NOFOLLOW), so a symlink cannot escape the script store.
static NSArray *components(id path){
    if(![path isKindOfClass:NSString.class]||[path length]>512)return nil;
    if([path isAbsolutePath]){if(![path hasPrefix:[root stringByAppendingString:@"/"]])return nil;path=[path substringFromIndex:root.length+1];}
    if([path isEqual:@""]||[path isEqual:@"."])return @[];
    NSArray *parts=[path componentsSeparatedByString:@"/"];
    NSString *nul=[NSString stringWithFormat:@"%C",(unichar)0];
    for(NSString *p in parts)if(!p.length||[p isEqual:@".."]||[p isEqual:@"."]||[p hasPrefix:@"."]||[p containsString:@"\\"]||[p containsString:nul])return nil;
    return parts;
}
static int parentFD(NSArray *parts,BOOL create){
    int fd=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);if(fd<0)return -1;
    for(NSUInteger i=0;i+1<parts.count;i++){const char *p=[parts[i] fileSystemRepresentation];if(create&&mkdirat(fd,p,0700)&&errno!=EEXIST){close(fd);return -1;}int next=openat(fd,p,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);close(fd);if(next<0)return -1;fd=next;}return fd;
}
NSString *HPResolveFile(NSString *path){NSArray *parts=components(path);if(!parts.count)return nil;int fd=parentFD(parts,NO);if(fd<0)return nil;struct stat st;int ok=fstatat(fd,[parts.lastObject fileSystemRepresentation],&st,AT_SYMLINK_NOFOLLOW);close(fd);if(ok||!S_ISREG(st.st_mode))return nil;return [root stringByAppendingPathComponent:[parts componentsJoinedByString:@"/"]];}
static NSData *readFD(int fd){NSMutableData *data=[NSMutableData data];char bytes[8192];for(;;){ssize_t n=read(fd,bytes,sizeof(bytes));if(n==0)return data;if(n<0||data.length+n>16*1024*1024)return nil;[data appendBytes:bytes length:n];}}
NSDictionary *HPFile(NSDictionary *args){[fileLock lock];@try{
    NSString *action=args[@"action"];NSArray *parts=components(args[@"path"]?:@"");if(!parts)return failure(@"Path must stay inside scripts; hidden paths and symlinks are forbidden");
    BOOL createsParents=[@[@"write",@"append",@"removeFirstLine",@"mkdir"] containsObject:action];int dir=parentFD(parts,createsParents);if(dir<0)return failure(@"Cannot open parent directory");
    const char *name=parts.count?[parts.lastObject fileSystemRepresentation]:".";
    @try{
        struct stat st={0};BOOL exists=fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW)==0;
        if(exists&&!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode))return failure(@"Symlinks and special files are forbidden");
        if([action isEqual:@"exists"])return @{@"ok":@YES,@"exists":@(exists)};
        if([action isEqual:@"list"]){int folder=openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);if(folder<0)return failure(@"Not a directory");NSString *full=parts.count?[root stringByAppendingPathComponent:[parts componentsJoinedByString:@"/"]]:root;NSMutableArray *entries=[NSMutableArray new];for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:full error:NULL]){if([entry hasPrefix:@"."])continue;struct stat info;if(fstatat(folder,entry.fileSystemRepresentation,&info,AT_SYMLINK_NOFOLLOW)||(!S_ISDIR(info.st_mode)&&!S_ISREG(info.st_mode)))continue;[entries addObject:@{@"name":entry,@"isDir":@(S_ISDIR(info.st_mode)),@"size":@(info.st_size),@"path":[full stringByAppendingPathComponent:entry],@"mtime":@(info.st_mtime)}];if(entries.count>=2000)break;}close(folder);[entries sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){if([a[@"isDir"] boolValue]!=[b[@"isDir"] boolValue])return [a[@"isDir"] boolValue]?NSOrderedAscending:NSOrderedDescending;return [a[@"name"] compare:b[@"name"]];}];return @{@"ok":@YES,@"entries":entries};}
        if(!parts.count)return failure(@"A file name is required");
        if([action isEqual:@"mkdir"]){BOOL ok=mkdirat(dir,name,0700)==0||(exists&&S_ISDIR(st.st_mode));return ok?@{@"ok":@YES}:failure(@"Cannot create directory");}
        if([action isEqual:@"delete"]){if(!exists||!S_ISREG(st.st_mode))return failure(@"A regular file is required");return unlinkat(dir,name,0)==0?@{@"ok":@YES}:failure(@"Delete failed");}
        NSData *old=nil;if([@[@"read",@"append",@"removeFirstLine"] containsObject:action]){int fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);if(fd>=0){struct stat actual;if(!fstat(fd,&actual)&&S_ISREG(actual.st_mode))old=readFD(fd);close(fd);}if(!old&&![action isEqual:@"append"])return failure(@"File missing or exceeds 16 MiB");}
        if([action isEqual:@"append"]&&exists&&!old)return failure(@"Existing file could not be read or exceeds 16 MiB");
        if([action isEqual:@"read"]){NSString *text=[[NSString alloc] initWithData:old encoding:NSUTF8StringEncoding];NSMutableDictionary *r=[@{@"ok":@YES,@"base64":[old base64EncodedStringWithOptions:0],@"size":@(old.length)} mutableCopy];if(text)r[@"content"]=text;return r;}
        NSData *content=nil;NSString *line=nil;
        if([action isEqual:@"removeFirstLine"]&&!old.length)return @{@"ok":@YES};
        if([action isEqual:@"removeFirstLine"]){NSString *text=[[NSString alloc] initWithData:old encoding:NSUTF8StringEncoding];if(!text)return failure(@"UTF-8 text required");NSRange newline=[text rangeOfString:@"\n"];line=newline.location==NSNotFound?text:[text substringToIndex:newline.location];if([line hasSuffix:@"\r"])line=[line substringToIndex:line.length-1];NSString *tail=newline.location==NSNotFound?@"":[text substringFromIndex:newline.location+1];content=[tail dataUsingEncoding:NSUTF8StringEncoding];}
        else if([action isEqual:@"write"]||[action isEqual:@"append"]){if([args[@"base64"] isKindOfClass:NSString.class])content=[[NSData alloc] initWithBase64EncodedString:args[@"base64"] options:0];else if([args[@"content"] isKindOfClass:NSString.class])content=[args[@"content"] dataUsingEncoding:NSUTF8StringEncoding];if(!content)return failure(@"content or valid base64 required");if([action isEqual:@"append"]){NSMutableData *combined=[NSMutableData dataWithData:old?:[NSData data]];if(combined.length&&((const char *)combined.bytes)[combined.length-1]!='\n')[combined appendBytes:"\n" length:1];[combined appendData:content];content=combined;}}
        else return failure(@"Unknown file action");
        if(content.length>16*1024*1024)return failure(@"File exceeds 16 MiB");
        NSString *temp=[@".hphone-" stringByAppendingString:NSUUID.UUID.UUIDString];int out=openat(dir,temp.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(out<0)return failure(@"Cannot create temporary file");BOOL ok=YES;const char *p=content.bytes;size_t remain=content.length;while(remain){ssize_t n=write(out,p,remain);if(n<=0){ok=NO;break;}p+=n;remain-=n;}if(fsync(out))ok=NO;close(out);if(ok)ok=renameat(dir,temp.UTF8String,dir,name)==0;if(!ok)unlinkat(dir,temp.UTF8String,0);if(!ok)return failure(@"Atomic write failed");NSMutableDictionary *result=[@{@"ok":@YES,@"path":[root stringByAppendingPathComponent:[parts componentsJoinedByString:@"/"]]} mutableCopy];if(line)result[@"line"]=line;return result;
    }@finally{close(dir);}
}@finally{[fileLock unlock];}}

@interface HPDownload:NSObject<NSURLSessionDataDelegate>
@property NSMutableData *data;@property NSHTTPURLResponse *response;@property NSError *error;@property dispatch_semaphore_t done;
@end
@implementation HPDownload
-(instancetype)init{if((self=[super init])){_data=[NSMutableData new];_done=dispatch_semaphore_create(0);}return self;}
-(void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void(^)(NSURLSessionResponseDisposition))completion{@synchronized(self){self.response=(NSHTTPURLResponse *)response;}completion(response.expectedContentLength>8*1024*1024?NSURLSessionResponseCancel:NSURLSessionResponseAllow);}
-(void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data{@synchronized(self){if(self.data.length+data.length>8*1024*1024){self.error=[NSError errorWithDomain:@"HPhone" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Response exceeds 8 MiB"}];[task cancel];}else[self.data appendData:data];}}
-(void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error{@synchronized(self){if(!self.error)self.error=error;}dispatch_semaphore_signal(self.done);}
@end
NSDictionary *HPHTTP(NSDictionary *args,BOOL(^cancel)(void)){
    NSURLComponents *url=[NSURLComponents componentsWithString:[args[@"url"] isKindOfClass:NSString.class]?args[@"url"]:@""];
    if(![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length)return failure(@"HTTP(S) URL required");
    NSMutableArray *query=[url.queryItems mutableCopy]?:[NSMutableArray new];id q=args[@"query"];if([q isKindOfClass:NSDictionary.class])for(id key in q)[query addObject:[NSURLQueryItem queryItemWithName:[key description] value:[q[key] description]]];if(query.count)url.queryItems=query;
    double timeout=[args[@"timeout"] doubleValue];if(!isfinite(timeout)||timeout<=0)timeout=30;timeout=MIN(timeout,120);
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    NSString *method=args[@"method"]?:@"GET";if(![method isKindOfClass:NSString.class]||[method rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet].location!=NSNotFound)return failure(@"Invalid method");req.HTTPMethod=method;
    id heads=args[@"headers"];if([heads isKindOfClass:NSDictionary.class])for(NSString *k in heads){NSString *v=[heads[k] description];if(![k isKindOfClass:NSString.class]||[k containsString:@"\n"]||[k containsString:@"\r"]||[v containsString:@"\n"]||[v containsString:@"\r"])return failure(@"Invalid header");[req setValue:v forHTTPHeaderField:k];}
    id form=args[@"form"],value=args[@"json"],body=args[@"body"];
    if([form isKindOfClass:NSDictionary.class]){NSMutableArray *pairs=[NSMutableArray new];NSCharacterSet *safe=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];for(id key in form)[pairs addObject:[NSString stringWithFormat:@"%@=%@",[[key description] stringByAddingPercentEncodingWithAllowedCharacters:safe],[[form[key] description] stringByAddingPercentEncodingWithAllowedCharacters:safe]]];req.HTTPBody=[[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];[req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];}
    else if(value){req.HTTPBody=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:NULL];if(!req.HTTPBody)return failure(@"Invalid JSON body");[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];}
    else if([body isKindOfClass:NSString.class])req.HTTPBody=[body dataUsingEncoding:NSUTF8StringEncoding];
    if(req.HTTPBody.length>8*1024*1024)return failure(@"Body exceeds 8 MiB");
    HPDownload *delegate=[HPDownload new];NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.HTTPCookieStorage=nil;config.URLCredentialStorage=nil;config.timeoutIntervalForResource=timeout;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];NSURLSessionDataTask *task=[session dataTaskWithRequest:req];[task resume];
    double deadline=NSDate.date.timeIntervalSince1970+timeout+2;BOOL stopped=NO;
    while(dispatch_semaphore_wait(delegate.done,dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC))){if((cancel&&cancel())||NSDate.date.timeIntervalSince1970>deadline){stopped=YES;[task cancel];break;}}
    if(stopped)dispatch_semaphore_wait(delegate.done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));[session invalidateAndCancel];
    @synchronized(delegate){NSInteger status=delegate.response.statusCode;NSData *bytes=[delegate.data copy];NSString *text=[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];return @{@"ok":@(!stopped&&!delegate.error&&status>=200&&status<300),@"status":@(status),@"body":text?:@"",@"bodyBase64":[bytes base64EncodedStringWithOptions:0],@"headers":delegate.response.allHeaderFields?:@{},@"error":stopped?@"Request cancelled or timed out":delegate.error.localizedDescription?:@""};}
}

static void pushObject(lua_State *L,id obj,int depth){
    if(depth>24||!lua_checkstack(L,4))@throw [NSException exceptionWithName:@"LuaValue" reason:@"Table nesting exceeds 24 or Lua stack exhausted" userInfo:nil];
    if(!obj||obj==NSNull.null){lua_pushnil(L);return;}
    if([obj isKindOfClass:NSString.class]){NSData *d=[obj dataUsingEncoding:NSUTF8StringEncoding];lua_pushlstring(L,d.bytes,d.length);}
    else if([obj isKindOfClass:NSNumber.class]){if(CFGetTypeID((__bridge CFTypeRef)obj)==CFBooleanGetTypeID())lua_pushboolean(L,[obj boolValue]);else lua_pushnumber(L,[obj doubleValue]);}
    else if([obj isKindOfClass:NSArray.class]){lua_createtable(L,(int)[obj count],0);int i=0;for(id item in obj){pushObject(L,item,depth+1);lua_rawseti(L,-2,++i);}}
    else if([obj isKindOfClass:NSDictionary.class]){lua_newtable(L);for(id key in obj){NSData *encoded=[[key description] dataUsingEncoding:NSUTF8StringEncoding];lua_pushlstring(L,encoded.bytes,encoded.length);pushObject(L,obj[key],depth+1);lua_settable(L,-3);}}
    else lua_pushnil(L);
}
void HPPushObject(lua_State *L,id obj){pushObject(L,obj,0);}
id HPReadObject(lua_State *L,int index,int depth){if(depth>24||!lua_checkstack(L,4))@throw [NSException exceptionWithName:@"LuaValue" reason:@"Table nesting exceeds 24" userInfo:nil];index=lua_absindex(L,index);switch(lua_type(L,index)){case LUA_TNIL:return NSNull.null;case LUA_TBOOLEAN:return @(lua_toboolean(L,index));case LUA_TNUMBER:{double n=lua_tonumber(L,index);if(!isfinite(n))@throw [NSException exceptionWithName:@"LuaValue" reason:@"Nonfinite JSON number" userInfo:nil];return @(n);}case LUA_TSTRING:{size_t n;const char *s=lua_tolstring(L,index,&n);NSString *v=[[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];if(!v)@throw [NSException exceptionWithName:@"LuaValue" reason:@"UTF-8 required (use base64 for binary)" userInfo:nil];return v;}case LUA_TTABLE:{NSMutableDictionary *dict=[NSMutableDictionary new];NSMutableArray *array=[NSMutableArray new];NSUInteger count=0,largest=0;BOOL sequential=YES;lua_pushnil(L);while(lua_next(L,index)){if(++count>100000)@throw [NSException exceptionWithName:@"LuaValue" reason:@"Table too large" userInfo:nil];id value=HPReadObject(L,-1,depth+1);if(lua_isinteger(L,-2)&&lua_tointeger(L,-2)>0){NSUInteger k=(NSUInteger)lua_tointeger(L,-2);largest=MAX(largest,k);dict[[NSString stringWithFormat:@"%lu",(unsigned long)k]]=value;}else{sequential=NO;if(lua_type(L,-2)!=LUA_TSTRING)@throw [NSException exceptionWithName:@"LuaValue" reason:@"Object keys must be strings" userInfo:nil];size_t keyLength;const char *keyBytes=lua_tolstring(L,-2,&keyLength);NSString *key=[[NSString alloc] initWithBytes:keyBytes length:keyLength encoding:NSUTF8StringEncoding];if(!key)@throw [NSException exceptionWithName:@"LuaValue" reason:@"UTF-8 object keys required" userInfo:nil];dict[key]=value;}lua_pop(L,1);}if(sequential&&count==largest){for(NSUInteger i=1;i<=count;i++)[array addObject:dict[[NSString stringWithFormat:@"%lu",(unsigned long)i]]];return array;}return dict;}default:@throw [NSException exceptionWithName:@"LuaValue" reason:@"JSON does not support function/userdata/thread" userInfo:nil];}}
