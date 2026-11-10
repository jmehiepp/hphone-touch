// Optional, original SpringBoard-only controls. No system hooks, respring or
// modification of another app's windows, files, safe-mode flags or credentials.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <unistd.h>

static NSString *const HPData=@"/var/mobile/Library/HPhoneTouch";
static NSString *HPOverlayText(id value){return [value isKindOfClass:NSString.class]?value:@"";}
static BOOL HPOverlayBool(id value){return [value respondsToSelector:@selector(boolValue)]?[value boolValue]:NO;}
@interface HPOverlayWindow : UIWindow
@end
@interface HPOverlayController : UIViewController
@property(nonatomic,strong) UIButton *bubble;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSMutableSet<NSString *> *handled;
@property(nonatomic,strong) NSMutableDictionary *preferences;
@property(nonatomic,copy) NSString *token;
@property(nonatomic) NSInteger port;
@property(nonatomic) BOOL fetching;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL running;
@property(nonatomic) CGPoint dragStart;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,weak) UIWindow *previousKeyWindow;
- (void)tick;
- (void)show:(UIAlertController *)controller;
@end

@implementation HPOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    HPOverlayController *controller=(HPOverlayController *)self.rootViewController;
    if(controller.presentedViewController)return [super hitTest:point withEvent:event];
    CGPoint inside=[controller.bubble convertPoint:point fromView:self];
    if(!controller.bubble.hidden&&[controller.bubble pointInside:inside withEvent:event])return [super hitTest:point withEvent:event];
    return nil;
}
- (BOOL)canBecomeKeyWindow {return self.rootViewController.presentedViewController!=nil;}
@end

@implementation HPOverlayController
- (BOOL)shouldAutorotate {return NO;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.clearColor;self.handled=[NSMutableSet new];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest=1.5;configuration.timeoutIntervalForResource=2;
    configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    self.session=[NSURLSession sessionWithConfiguration:configuration];
    self.bubble=[UIButton buttonWithType:UIButtonTypeCustom];self.bubble.frame=CGRectMake(12,220,46,46);
    self.bubble.backgroundColor=[UIColor colorWithRed:.08 green:.23 blue:.38 alpha:.94];self.bubble.layer.cornerRadius=23;
    self.bubble.layer.borderWidth=1;self.bubble.layer.borderColor=[UIColor colorWithWhite:1 alpha:.5].CGColor;
    self.bubble.titleLabel.font=[UIFont boldSystemFontOfSize:23];[self.bubble setTitle:@"H" forState:UIControlStateNormal];
    self.bubble.accessibilityLabel=@"HPhone Touch controls";self.bubble.accessibilityHint=@"Open script controls. Drag to move.";
    [self.bubble addTarget:self action:@selector(menu) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *drag=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];[self.bubble addGestureRecognizer:drag];
    [self.view addSubview:self.bubble];self.bubble.hidden=YES;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self tick];
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if(gesture.state==UIGestureRecognizerStateBegan)self.dragStart=self.bubble.center;
    CGPoint shift=[gesture translationInView:self.view];CGRect frame=self.view.bounds;UIEdgeInsets inset=self.view.safeAreaInsets;
    self.bubble.center=CGPointMake(MAX(24,MIN(frame.size.width-24,self.dragStart.x+shift.x)),MAX(inset.top+24,MIN(frame.size.height-inset.bottom-24,self.dragStart.y+shift.y)));
}
- (void)request:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *result))completion {
    if(!self.enabled||self.token.length!=32||self.port<1024||self.port>65535){if(completion)completion(nil);return;}
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/api/%@",(long)self.port,path]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=body?@"POST":@"GET";
    [request setValue:self.token forHTTPHeaderField:@"X-HPhone-Token"];
    if(body){request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];}
    NSUInteger generation=self.generation;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        NSDictionary *result=nil;NSHTTPURLResponse *http=(NSHTTPURLResponse *)response;
        if(!error&&[http isKindOfClass:NSHTTPURLResponse.class]&&http.statusCode==200&&data.length<=2*1024*1024){id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if([parsed isKindOfClass:NSDictionary.class])result=parsed;}
        dispatch_async(dispatch_get_main_queue(),^{if(generation==self.generation&&completion)completion(result);});
    }] resume];
}
- (void)tick {
    if(!self.presentedViewController&&self.view.window.isKeyWindow){[self.view.window resignKeyWindow];[self.previousKeyWindow makeKeyWindow];self.previousKeyWindow=nil;}
    NSString *file=[HPData stringByAppendingPathComponent:@"ui-preferences.json"];NSData *data=[NSData dataWithContentsOfFile:file];
    id prefs=data.length&&data.length<16384?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL]:nil;
    if(![prefs isKindOfClass:NSDictionary.class])prefs=[NSMutableDictionary new];self.preferences=[prefs mutableCopy];
    BOOL enabled=HPOverlayBool(self.preferences[@"overlayEnabled"]);
    if(enabled!=self.enabled){self.generation++;self.fetching=NO;}self.enabled=enabled;self.bubble.hidden=!enabled;
    if(!enabled){if(self.presentedViewController)[self dismissViewControllerAnimated:NO completion:nil];return;}
    NSString *rawToken=[[NSString stringWithContentsOfFile:[HPData stringByAppendingPathComponent:@"token"] encoding:NSUTF8StringEncoding error:NULL] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    self.token=rawToken.length==32&&[rawToken rangeOfCharacterFromSet:hex.invertedSet].location==NSNotFound?rawToken:nil;
    self.port=[[NSString stringWithContentsOfFile:[HPData stringByAppendingPathComponent:@"port"] encoding:NSUTF8StringEncoding error:NULL] integerValue];
    if(self.fetching)return;self.fetching=YES;
    [self request:@"ui" body:@{@"action":@"heartbeat",@"surface":@"overlay"} completion:nil];
    [self request:@"status" body:nil completion:^(NSDictionary *status){
        self.fetching=NO;self.running=HPOverlayBool(status[@"running"]);
        self.bubble.backgroundColor=status?(self.running?[UIColor colorWithRed:.65 green:.15 blue:.16 alpha:.95]:[UIColor colorWithRed:.08 green:.23 blue:.38 alpha:.94]):[UIColor colorWithWhite:.25 alpha:.9];
        [self.bubble setTitle:self.running?@"■":@"H" forState:UIControlStateNormal];
    }];
    if(!self.presentedViewController)[self request:@"ui" body:nil completion:^(NSDictionary *result){NSArray *events=result[@"events"];if([events isKindOfClass:NSArray.class])for(NSDictionary *event in events){if(self.presentedViewController)break;if([event isKindOfClass:NSDictionary.class])@try{[self handle:event];}@catch(NSException *exception){/* Reject a malformed owner event without crashing SpringBoard. */}}}];
}
- (void)show:(UIAlertController *)controller {
    if(!self.view.window.isKeyWindow){for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)if([scene isKindOfClass:UIWindowScene.class])for(UIWindow *window in ((UIWindowScene *)scene).windows)if(window.isKeyWindow)self.previousKeyWindow=window;}
    [self presentViewController:controller animated:YES completion:^{[self.view.window makeKeyWindow];}];
}
- (void)message:(NSString *)text {
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(12,MAX(self.view.safeAreaInsets.top+8,30),self.view.bounds.size.width-24,90)];
    label.numberOfLines=3;label.textAlignment=NSTextAlignmentCenter;label.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium];label.textColor=UIColor.whiteColor;label.backgroundColor=[UIColor colorWithWhite:.06 alpha:.93];label.layer.cornerRadius=12;label.clipsToBounds=YES;label.text=text;
    [self.view addSubview:label];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{[label removeFromSuperview];});
}
- (void)menu {
    if(self.presentedViewController)return;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"HPhone Touch" message:self.running?@"Script đang chạy":@"Chọn thao tác" preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *last=self.preferences[@"lastScript"];if(![last isKindOfClass:NSString.class]||![last hasSuffix:@".lua"])last=@"hello.lua";
    [menu addAction:[UIAlertAction actionWithTitle:[@"▶ " stringByAppendingString:last] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self request:@"run" body:@{@"name":last} completion:^(NSDictionary *result){[self message:result?@"Đã gửi chạy script":@"Không chạy được; xem log trong app"];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Chọn script…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self chooseScript];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"■ Dừng tất cả" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[self request:@"stop" body:@{} completion:^(NSDictionary *result){[self message:result?@"Đã gửi yêu cầu dừng":@"Daemon chưa sẵn sàng"];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Mở HPhone Touch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self openApp];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Ẩn nút nổi" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self request:@"service" body:@{@"operation":@"overlay",@"args":@{@"enabled":@NO}} completion:^(NSDictionary *result){if(result)[self tick];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=self.bubble;menu.popoverPresentationController.sourceRect=self.bubble.bounds;[self show:menu];
}
- (void)chooseScript {
    [self request:@"files" body:nil completion:^(NSDictionary *result){
        if(self.presentedViewController)return;NSArray *files=result[@"files"];
        if(![files isKindOfClass:NSArray.class]||!files.count){[self message:@"Chưa có script hoặc daemon chưa sẵn sàng"];return;}
        UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Chạy script" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for(NSString *name in files)if([name isKindOfClass:NSString.class]&&[name hasSuffix:@".lua"]&&menu.actions.count<40){[menu addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            [self request:@"service" body:@{@"operation":@"overlay",@"args":@{@"enabled":@YES,@"lastScript":name}} completion:nil];
            [self request:@"run" body:@{@"name":name} completion:^(NSDictionary *run){[self message:run?@"Đã gửi chạy script":@"Không chạy được; xem log trong app"];}];
        }]];}
        [menu addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];menu.popoverPresentationController.sourceView=self.bubble;menu.popoverPresentationController.sourceRect=self.bubble.bounds;[self show:menu];
    }];
}
- (void)openApp {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_GLOBAL);
    Class cls=NSClassFromString(@"LSApplicationWorkspace");SEL get=NSSelectorFromString(@"defaultWorkspace"),open=NSSelectorFromString(@"openApplicationWithBundleID:");
    id ws=[cls respondsToSelector:get]?((id(*)(id,SEL))objc_msgSend)(cls,get):nil;
    if([ws respondsToSelector:open])((void(*)(id,SEL,id))objc_msgSend)(ws,open,@"io.github.jmehiepp.hphone-touch.app");else [self message:@"Không mở được app qua LaunchServices"];
}
- (void)respond:(id)identifier button:(NSInteger)button controls:(NSArray *)controls {
    NSMutableDictionary *body=[@{@"action":@"respond",@"id":identifier,@"button":@(button)} mutableCopy];if(controls)body[@"controls"]=controls;
    [self request:@"ui" body:body completion:nil];
}
- (void)handle:(NSDictionary *)event {
    id identifier=event[@"id"];if(![identifier isKindOfClass:NSString.class]&&![identifier isKindOfClass:NSNumber.class])return;
    NSString *key=[identifier description];if([self.handled containsObject:key])return;
    NSString *target=event[@"target"];if([target isKindOfClass:NSString.class]&&[target isEqual:@"app"])return;
    NSString *kind=event[@"type"],*message=[event[@"message"] isKindOfClass:NSString.class]?event[@"message"]:@"",*title=[event[@"title"] isKindOfClass:NSString.class]?event[@"title"]:@"HPhone Touch";
    if(![@[@"toast",@"alert",@"dialog"] containsObject:kind])return;
    [self.handled addObject:key];if(self.handled.count>1000)[self.handled removeObject:self.handled.anyObject];
    if([kind isEqual:@"toast"]){[self message:message];[self respond:identifier button:0 controls:nil];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if([kind isEqual:@"alert"]){[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self respond:identifier button:1 controls:nil];}]];[self show:alert];return;}
    NSArray *source=event[@"controls"];if(![source isKindOfClass:NSArray.class]||source.count>40){[self respond:identifier button:0 controls:@[]];return;}
    NSMutableArray *controls=[NSMutableArray new],*fields=[NSMutableArray new],*buttons=[NSMutableArray new];NSMutableString *labels=[NSMutableString new];
    for(id row in source)if([row isKindOfClass:NSDictionary.class]){
        NSMutableDictionary *control=[row mutableCopy];[controls addObject:control];NSString *type=[[control[@"type"] description] uppercaseString];
        NSDictionary *types=@{@"0":@"LABEL",@"1":@"INPUT",@"2":@"TEXTVIEW",@"3":@"PICKER",@"4":@"SWITCH",@"5":@"BUTTON",@"6":@"REMEMBER"};type=types[type]?:type;
        if([type isEqual:@"LABEL"]){[labels appendFormat:@"%@\n",HPOverlayText(control[@"text"])];continue;}
        if([type isEqual:@"BUTTON"]){[buttons addObject:@{@"control":control,@"index":@(buttons.count+1)}];continue;}
        if([type isEqual:@"REMEMBER"])continue;
        if([@[@"INPUT",@"TEXTVIEW",@"PICKER",@"SWITCH"] containsObject:type]){
            [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=HPOverlayText(control[@"title"]);if(!field.placeholder.length)field.placeholder=HPOverlayText(control[@"key"]);id value=control[@"value"];field.text=value&&value!=NSNull.null?[value description]:@"";field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.secureTextEntry=HPOverlayBool(control[@"secure"]);if([type isEqual:@"SWITCH"]){field.placeholder=[NSString stringWithFormat:@"%@ (true/false)",field.placeholder?:@""];field.text=HPOverlayBool(value)?@"true":@"false";}if([type isEqual:@"PICKER"]&&[control[@"options"] isKindOfClass:NSArray.class]){NSMutableArray *choices=[NSMutableArray new];for(id option in control[@"options"])[choices addObject:[option description]];field.placeholder=[NSString stringWithFormat:@"%@ (%@)",field.placeholder?:@"",[choices componentsJoinedByString:@" / "]];}[fields addObject:@{@"control":control,@"field":field,@"type":type}];}];
        }
    }
    if(labels.length)alert.message=[message stringByAppendingFormat:@"\n%@",labels];
    if(!buttons.count)[buttons addObject:@{@"control":@{@"title":@"OK"},@"index":@1}];
    for(NSDictionary *button in buttons){NSString *text=[button[@"control"][@"title"] description]?:@"OK";[alert addAction:[UIAlertAction actionWithTitle:text style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        for(NSDictionary *mapping in fields){NSMutableDictionary *control=mapping[@"control"];UITextField *field=mapping[@"field"];NSString *type=mapping[@"type"];
            if([type isEqual:@"SWITCH"])control[@"value"]=@([@[@"true",@"1",@"yes",@"on"] containsObject:field.text.lowercaseString]);else if([type isEqual:@"PICKER"]){NSArray *options=[control[@"options"] isKindOfClass:NSArray.class]?control[@"options"]:@[];NSUInteger index=[options indexOfObject:field.text?:@""];control[@"value"]=index==NSNotFound?field.text?:@"":@(index+1);}else control[@"value"]=field.text?:@"";
        }[self respond:identifier button:[button[@"index"] integerValue] controls:controls];
    }]];}
    [self show:alert];
}
@end

static HPOverlayWindow *overlayWindow;
__attribute__((constructor)) static void HPInstallOverlay(void) {
    @autoreleasepool {
        if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"])return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            overlayWindow=[[HPOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];overlayWindow.windowLevel=UIWindowLevelAlert+2000;overlayWindow.backgroundColor=UIColor.clearColor;overlayWindow.rootViewController=[HPOverlayController new];overlayWindow.hidden=NO;
        });
    }
}
