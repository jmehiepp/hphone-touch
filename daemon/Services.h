#import <Foundation/Foundation.h>

// Results are JSON-safe dictionaries: {ok, value?, error?, code?}.
// No operation below changes the jailbreak, elevates the daemon, or logs secrets.
NSDictionary *HPService(NSString *operation, NSDictionary *arguments);
NSDictionary *HPServiceCapabilities(void);

