// Visible, narrowly scoped fleet bootstrap app, temporarily replacing Tips.
#import <UIKit/UIKit.h>
@interface HPFleetBootstrapDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation HPFleetBootstrapDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, UIScreen.mainScreen.bounds.size.width - 40, 180)];
    label.text = @"HPhone Fleet Bootstrap\n\nUSB installation in progress.\nKeep this iPhone connected.";
    label.numberOfLines = 0; label.textAlignment = NSTextAlignmentCenter;
    [controller.view addSubview:label]; self.window.rootViewController = controller;
    [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HPFleetBootstrapDelegate.class)); }
}
