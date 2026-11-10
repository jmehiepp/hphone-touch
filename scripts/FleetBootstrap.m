// Owner-authorized, USB-launched installer adapter. No network listener.
// Loaded only into a development-entitled TrollStore persistence helper.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

static NSString *const directory = @"/var/mobile/Media/RootHideFleet";
static NSString *const officialHelperSHA = @"f0915cb7a608522ef84a43c6617433037e030ff68f5db89a6bb982f8430a0cb9";
static NSString *const developmentIPASHA = @"22b48e78111d2885c621c36fb4bac6c042fed7ea50de84b0f842943129742d65";

static BOOL verify(NSString *path, NSString *sha) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length > 128 * 1024 * 1024) return NO;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *actual = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [actual appendFormat:@"%02x", hash[i]];
    return [actual isEqualToString:sha];
}

static int rootCommand(NSString *helper, NSString *command, NSString *argument) {
    int (*persona)(posix_spawnattr_t *, uid_t, uint32_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    int (*uid)(posix_spawnattr_t *, uid_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    int (*gid)(posix_spawnattr_t *, gid_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!persona || !uid || !gid) return -100;
    posix_spawnattr_t attr;
    int result = posix_spawnattr_init(&attr);
    if (result) return result;
    if ((result = persona(&attr, 99, 1)) || (result = uid(&attr, 0)) || (result = gid(&attr, 0))) {
        posix_spawnattr_destroy(&attr); return result;
    }
    char *argv[] = {(char *)helper.fileSystemRepresentation, (char *)command.UTF8String, (char *)argument.fileSystemRepresentation, NULL};
    pid_t child;
    result = posix_spawn(&child, argv[0], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (result) return result;
    int status;
    if (waitpid(child, &status, 0) != child) return -101;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -102;
}

__attribute__((constructor)) static void fleetBootstrap(void) {
    @autoreleasepool {
        const char *requested = getenv("HPHONE_FLEET_ACTION");
        if (!requested) return;
        NSString *action = @(requested);
        if (![@[@"install-pinned-roothide", @"install-pinned-trollstore", @"install-stock-persistence-helper"] containsObject:action]) return;
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.tips"] || getuid() != 501) return;
        // Delay work until the application run loop is alive; the visible helper stays available.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *helper = [directory stringByAppendingPathComponent:@"PersistenceHelper_Embedded"];
            NSString *ipa = [directory stringByAppendingPathComponent:@"Dopamine-roothide-3.0.13-30-USBDevelopment.tipa"];
            int result = -110;
            NSString *command = @"install";
            NSString *argument = ipa;
            BOOL integrity = verify(helper, officialHelperSHA);
            if ([action isEqualToString:@"install-pinned-roothide"]) integrity &= verify(ipa, developmentIPASHA);
            else if ([action isEqualToString:@"install-pinned-trollstore"]) {
                command = @"install-trollstore";
                argument = [directory stringByAppendingPathComponent:@"TrollStore-2.1.1.tar"];
                integrity &= verify(argument, @"144dc741d1b74d582c861e6ed504ddced3745724e216e3de79ab7d37b27d0551");
            } else {
                command = @"install-persistence-helper";
                argument = @"com.apple.tips";
            }
            if (integrity && chmod(helper.fileSystemRepresentation, 0755) == 0) result = rootCommand(helper, command, argument);
            NSDictionary *evidence = @{@"action":action, @"integrity_verified":@(integrity),
                                      @"exit_code":@(result), @"finished_at":@([[NSDate date] timeIntervalSince1970])};
            NSData *json = [NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[directory stringByAppendingPathComponent:@"native-install-result.json"] atomically:YES];
        });
    }
}
