#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
@interface AppDelegate : UIResponder <UIApplicationDelegate,WKNavigationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic) NSUInteger attempts;
@end
@implementation AppDelegate
- (void)loadPage {
    self.attempts++;
    NSString *token=[NSString stringWithContentsOfFile:@"/var/mobile/Library/HPhoneTouch/token" encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    if(token.length<32){[self retry];return;}
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:@[token] options:0 error:NULL];
    NSString *json=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    NSString *script=[NSString stringWithFormat:@"window.HPHONE_TOKEN=(%@)[0];",json];
    [self.web.configuration.userContentController removeAllUserScripts];
    [self.web.configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:8765/"]]];
}
- (void)retry {
    if(self.attempts<10){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self loadPage];});}
    else [self.web loadHTMLString:@"<html><meta name='viewport' content='width=device-width'><body style='font:18px system-ui;padding:30px;background:#101a2c;color:white'><h2>HPhone Touch</h2><p>Daemon chưa sẵn sàng. Kiểm tra máy đã jailbreak bằng RootHide, cài lại gói trong Sileo rồi mở lại app.</p></body></html>" baseURL:nil];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {if(error.code!=NSURLErrorCancelled)[self retry];}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc=[UIViewController new];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    WKWebView *web=[[WKWebView alloc] initWithFrame:self.window.bounds configuration:config];
    self.web=web;web.navigationDelegate=self;
    web.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    vc.view=web; self.window.rootViewController=vc; [self.window makeKeyAndVisible];
    [self loadPage];
    return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class)); } }
