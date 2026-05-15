/* Zig translate-c compatibility overlay for the small CoreVideo surface used
 * by pkg/macos. Avoids Xcode 26 headers that Zig 0.16 cannot parse.
 */
#ifndef COREVIDEO_H_
#define COREVIDEO_H_

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

typedef uint64_t CVOptionFlags;
typedef int32_t CVReturn;
typedef struct CVTimeStamp CVTimeStamp;
typedef struct __CVDisplayLink *CVDisplayLinkRef;

enum {
    kCVReturnSuccess = 0,

    kCVPixelFormatType_1Monochrome = 0x00000001,
    kCVPixelFormatType_2Indexed = 0x00000002,
    kCVPixelFormatType_4Indexed = 0x00000004,
    kCVPixelFormatType_8Indexed = 0x00000008,
    kCVPixelFormatType_1IndexedGray_WhiteIsZero = 0x00000021,
    kCVPixelFormatType_2IndexedGray_WhiteIsZero = 0x00000022,
    kCVPixelFormatType_4IndexedGray_WhiteIsZero = 0x00000024,
    kCVPixelFormatType_8IndexedGray_WhiteIsZero = 0x00000028,
    kCVPixelFormatType_16BE555 = 0x00000010,
    kCVPixelFormatType_16LE555 = 'L555',
    kCVPixelFormatType_16LE5551 = '5551',
    kCVPixelFormatType_16BE565 = 'B565',
    kCVPixelFormatType_16LE565 = 'L565',
    kCVPixelFormatType_24RGB = 0x00000018,
    kCVPixelFormatType_24BGR = '24BG',
    kCVPixelFormatType_32ARGB = 0x00000020,
    kCVPixelFormatType_32BGRA = 'BGRA',
    kCVPixelFormatType_32ABGR = 'ABGR',
    kCVPixelFormatType_32RGBA = 'RGBA',
    kCVPixelFormatType_64ARGB = 'b64a',
    kCVPixelFormatType_64RGBALE = 'l64r',
    kCVPixelFormatType_48RGB = 'b48r',
    kCVPixelFormatType_32AlphaGray = 'b32a',
    kCVPixelFormatType_16Gray = 'b16g',
    kCVPixelFormatType_30RGB = 'R10k',
    kCVPixelFormatType_30RGB_r210 = 'r210',
    kCVPixelFormatType_422YpCbCr8 = '2vuy',
    kCVPixelFormatType_4444YpCbCrA8 = 'v408',
    kCVPixelFormatType_4444YpCbCrA8R = 'r408',
    kCVPixelFormatType_4444AYpCbCr8 = 'y408',
    kCVPixelFormatType_4444AYpCbCr16 = 'y416',
    kCVPixelFormatType_4444AYpCbCrFloat = 'r4fl',
    kCVPixelFormatType_444YpCbCr8 = 'v308',
    kCVPixelFormatType_422YpCbCr16 = 'v216',
    kCVPixelFormatType_422YpCbCr10 = 'v210',
    kCVPixelFormatType_444YpCbCr10 = 'v410',
    kCVPixelFormatType_420YpCbCr8Planar = 'y420',
    kCVPixelFormatType_420YpCbCr8PlanarFullRange = 'f420',
    kCVPixelFormatType_422YpCbCr_4A_8BiPlanar = 'a2vy',
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = '420v',
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = '420f',
    kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange = '422v',
    kCVPixelFormatType_422YpCbCr8BiPlanarFullRange = '422f',
    kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange = '444v',
    kCVPixelFormatType_444YpCbCr8BiPlanarFullRange = '444f',
    kCVPixelFormatType_422YpCbCr8_yuvs = 'yuvs',
    kCVPixelFormatType_422YpCbCr8FullRange = 'yuvf',
    kCVPixelFormatType_OneComponent8 = 'L008',
    kCVPixelFormatType_TwoComponent8 = '2C08',
    kCVPixelFormatType_30RGBLEPackedWideGamut = 'w30r',
    kCVPixelFormatType_ARGB2101010LEPacked = 'l10r',
    kCVPixelFormatType_40ARGBLEWideGamut = 'w40a',
    kCVPixelFormatType_40ARGBLEWideGamutPremultiplied = 'w40m',
    kCVPixelFormatType_OneComponent10 = 'L010',
    kCVPixelFormatType_OneComponent12 = 'L012',
    kCVPixelFormatType_OneComponent16 = 'L016',
    kCVPixelFormatType_TwoComponent16 = '2C16',
    kCVPixelFormatType_OneComponent16Half = 'L00h',
    kCVPixelFormatType_OneComponent32Float = 'L00f',
    kCVPixelFormatType_TwoComponent16Half = '2C0h',
    kCVPixelFormatType_TwoComponent32Float = '2C0f',
    kCVPixelFormatType_64RGBAHalf = 'RGhA',
    kCVPixelFormatType_128RGBAFloat = 'RGfA',
    kCVPixelFormatType_14Bayer_GRBG = 'grb4',
    kCVPixelFormatType_14Bayer_RGGB = 'rgg4',
    kCVPixelFormatType_14Bayer_BGGR = 'bgg4',
    kCVPixelFormatType_14Bayer_GBRG = 'gbr4',
    kCVPixelFormatType_DisparityFloat16 = 'hdis',
    kCVPixelFormatType_DisparityFloat32 = 'fdis',
    kCVPixelFormatType_DepthFloat16 = 'hdep',
    kCVPixelFormatType_DepthFloat32 = 'fdep',
    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange = 'x420',
    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange = 'x422',
    kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange = 'x444',
    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange = 'xf20',
    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange = 'xf22',
    kCVPixelFormatType_444YpCbCr10BiPlanarFullRange = 'xf44',
    kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar = 'v0a8',
    kCVPixelFormatType_16VersatileBayer = 'bp16',
    kCVPixelFormatType_64RGBA_DownscaledProResRAW = 'bp64',
    kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange = 'sv22',
    kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange = 'sv44',
    kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar = 's4as',
};

typedef CVReturn (*CVDisplayLinkOutputCallback)(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow,
    const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *displayLinkContext);

CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *displayLinkOut);
void CVDisplayLinkRelease(CVDisplayLinkRef displayLink);
CVReturn CVDisplayLinkStart(CVDisplayLinkRef displayLink);
CVReturn CVDisplayLinkStop(CVDisplayLinkRef displayLink);
bool CVDisplayLinkIsRunning(CVDisplayLinkRef displayLink);
CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef displayLink, CGDirectDisplayID displayID);
CVReturn CVDisplayLinkSetOutputCallback(
    CVDisplayLinkRef displayLink,
    CVDisplayLinkOutputCallback callback,
    void *userInfo);

#endif
