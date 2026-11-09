// Minimal C declarations for iPhoneOS SDKs without the IOSurface umbrella header.
// ABI references: Apple's IOSurfaceGet* / IOSurfaceLock documentation.
#if __has_include(<IOSurface/IOSurface.h>)
#import <IOSurface/IOSurface.h>
#else
#include <stdint.h>
#include <stddef.h>
typedef struct __IOSurface *IOSurfaceRef;
enum { kIOSurfaceLockReadOnly = 1 };
extern int IOSurfaceLock(IOSurfaceRef surface,uint32_t options,uint32_t *seed);
extern int IOSurfaceUnlock(IOSurfaceRef surface,uint32_t options,uint32_t *seed);
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
#endif
