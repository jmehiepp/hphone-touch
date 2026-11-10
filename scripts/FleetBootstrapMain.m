// Visible, narrowly scoped fleet bootstrap app, temporarily replacing Tips.
#import <UIKit/UIKit.h>
static UIViewController *fleetController(void) {
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, UIScreen.mainScreen.bounds.size.width - 40, 180)];
    label.text = @"HPhone Fleet Bootstrap\n\nUSB installation in progress.\nKeep this iPhone connected.";
    label.numberOfLines = 0; label.textAlignment = NSTextAlignmentCenter;
    [controller.view addSubview:label]; return controller;
}
@interface HPFleetSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation HPFleetSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = fleetController(); [self.window makeKeyAndVisible];
}
@end
@interface HPFleetBootstrapDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation HPFleetBootstrapDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = fleetController();
    [self.window makeKeyAndVisible]; return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"HPhone Fleet" sessionRole:session.role];
    configuration.delegateClass = HPFleetSceneDelegate.class; configuration.storyboard = nil; return configuration;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HPFleetBootstrapDelegate.class)); }
}
