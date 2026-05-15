/* Zig translate-c compatibility overlay for Xcode 26 CoreGraphics.
 *
 * The SDK umbrella header now pulls in block-based APIs that Zig 0.16 cannot
 * parse through @cImport. Keep this overlay to the symbols used by pkg/macos.
 */
#ifndef COREGRAPHICS_H_
#define COREGRAPHICS_H_

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGBase.h>

#undef CG_NONNULL_ARRAY
#define CG_NONNULL_ARRAY
#undef CG_NULLABLE_ARRAY
#define CG_NULLABLE_ARRAY
#undef __nullable
#define __nullable
#undef __nonnull
#define __nonnull
#undef _Nullable
#define _Nullable
#undef _Nonnull
#define _Nonnull

#include <CoreGraphics/CGAffineTransform.h>
#include <CoreGraphics/CGGeometry.h>
#include <CoreGraphics/CGColorSpace.h>
#include <CoreGraphics/CGFont.h>
#include <CoreGraphics/CGImage.h>

typedef struct CGContext *CGContextRef;
typedef struct CGPath *CGMutablePathRef;
typedef const struct CGPath *CGPathRef;
typedef uint32_t CGDirectDisplayID;

typedef enum CGTextDrawingMode {
    kCGTextFill,
    kCGTextStroke,
    kCGTextFillStroke,
    kCGTextInvisible,
    kCGTextFillClip,
    kCGTextStrokeClip,
    kCGTextFillStrokeClip,
    kCGTextClip,
} CGTextDrawingMode;

CG_EXTERN void CGContextRelease(CGContextRef c);
CG_EXTERN void CGContextSetLineWidth(CGContextRef c, CGFloat width);
CG_EXTERN void CGContextSetAllowsAntialiasing(CGContextRef c, bool allowsAntialiasing);
CG_EXTERN void CGContextSetAllowsFontSmoothing(CGContextRef c, bool allowsFontSmoothing);
CG_EXTERN void CGContextSetAllowsFontSubpixelPositioning(CGContextRef c, bool allowsFontSubpixelPositioning);
CG_EXTERN void CGContextSetAllowsFontSubpixelQuantization(CGContextRef c, bool allowsFontSubpixelQuantization);
CG_EXTERN void CGContextSetShouldAntialias(CGContextRef c, bool shouldAntialias);
CG_EXTERN void CGContextSetShouldSmoothFonts(CGContextRef c, bool shouldSmoothFonts);
CG_EXTERN void CGContextSetShouldSubpixelPositionFonts(CGContextRef c, bool shouldSubpixelPositionFonts);
CG_EXTERN void CGContextSetShouldSubpixelQuantizeFonts(CGContextRef c, bool shouldSubpixelQuantizeFonts);
CG_EXTERN void CGContextSetGrayFillColor(CGContextRef c, CGFloat gray, CGFloat alpha);
CG_EXTERN void CGContextSetGrayStrokeColor(CGContextRef c, CGFloat gray, CGFloat alpha);
CG_EXTERN void CGContextSetRGBFillColor(CGContextRef c, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha);
CG_EXTERN void CGContextSetRGBStrokeColor(CGContextRef c, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha);
CG_EXTERN void CGContextSetTextDrawingMode(CGContextRef c, CGTextDrawingMode mode);
CG_EXTERN void CGContextSetTextMatrix(CGContextRef c, CGAffineTransform t);
CG_EXTERN void CGContextSetTextPosition(CGContextRef c, CGFloat x, CGFloat y);
CG_EXTERN void CGContextFillRect(CGContextRef c, CGRect rect);
CG_EXTERN void CGContextScaleCTM(CGContextRef c, CGFloat sx, CGFloat sy);
CG_EXTERN void CGContextTranslateCTM(CGContextRef c, CGFloat tx, CGFloat ty);

CG_EXTERN CGContextRef CGBitmapContextCreate(
    void *data,
    size_t width,
    size_t height,
    size_t bitsPerComponent,
    size_t bytesPerRow,
    CGColorSpaceRef colorspace,
    CGBitmapInfo bitmapInfo);

CG_EXTERN CGPathRef CGPathCreateWithRect(CGRect rect, const CGAffineTransform *transform);
CG_EXTERN CGMutablePathRef CGPathCreateMutable(void);
CG_EXTERN void CGPathAddRect(CGMutablePathRef path, const CGAffineTransform *m, CGRect rect);
CG_EXTERN CGRect CGPathGetBoundingBox(CGPathRef path);

#endif
