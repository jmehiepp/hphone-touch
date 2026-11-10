#ifndef HP_SCREEN_ALGORITHMS_H
#define HP_SCREEN_ALGORITHMS_H
#include <stddef.h>
#include <stdint.h>
/* All buffers are owned BGRA8 pixels, top-left origin. No platform framework. */
typedef struct {const uint8_t *bytes; size_t width,height,row;} HPBitmap;
typedef struct {int x,y,width,height;} HPRegion;
typedef struct {uint32_t color;int dx,dy,tolerance,any,invert;} HPColorPoint;
typedef struct {int x,y,width,height;double score;} HPImageMatch;
typedef int (*HPCancelCheck)(void *context);
int HPBitmapValid(HPBitmap image);
uint32_t HPColorAt(HPBitmap image,size_t x,size_t y);
int HPColorClose(uint32_t a,uint32_t b,int tolerance);
/* count=0 means all, bounded by capacity. Returns total stored; negative=cancelled. */
int HPFindColors(HPBitmap image,const HPColorPoint *pattern,size_t length,HPRegion region,
                 int rightToLeft,int bottomToTop,size_t count,int *xy,size_t capacity,
                 HPCancelCheck cancelled,void *context);
int64_t HPCountColor(HPBitmap image,uint32_t color,int tolerance,HPRegion region,
                     HPCancelCheck cancelled,void *context);
/* SAD RGB score, alpha=0 template pixels skipped. 250M channel operations max;
 * -2 signals explicit budget exhaustion, -1 cancellation, >=0 match count. */
int HPFindImage(HPBitmap image,HPBitmap pattern,HPRegion region,double threshold,
                size_t count,size_t step,HPImageMatch *matches,size_t capacity,
                HPCancelCheck cancelled,void *context);
#endif
