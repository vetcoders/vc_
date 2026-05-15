#ifndef IOSURFACE_REF_H_
#define IOSURFACE_REF_H_

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

typedef int kern_return_t;
typedef uint32_t OSType;
typedef uint32_t IOSurfaceID;
typedef uint32_t IOSurfaceLockOptions;
typedef struct __IOSurface *IOSurfaceRef;

enum {
    kIOSurfacePurgeableEmpty = 2,
};

extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceColorSpace;

IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
kern_return_t IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerElement(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetElementWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetElementHeight(IOSurfaceRef buffer);
OSType IOSurfaceGetPixelFormat(IOSurfaceRef buffer);
void IOSurfaceSetValue(IOSurfaceRef buffer, CFStringRef key, CFTypeRef value);
kern_return_t IOSurfaceSetPurgeable(IOSurfaceRef buffer, uint32_t newState, uint32_t *oldState);

#endif
