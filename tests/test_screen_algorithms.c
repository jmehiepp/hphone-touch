#include "ScreenAlgorithms.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static int yes(void *ctx){(void)ctx;return 1;}
int main(void){
    uint8_t bgra[4*4*4]={0};for(size_t i=0;i<16;i++)bgra[i*4+3]=255;
    bgra[(1*4+2)*4+2]=255;bgra[(2*4+3)*4+1]=128;
    HPBitmap image={bgra,4,4,16};HPRegion all={0,0,4,4};int xy[32];HPImageMatch found[16];
    assert(HPBitmapValid(image));assert(HPColorAt(image,2,1)==0xff0000);assert(HPColorClose(0xfe0100,0xff0000,1));assert(!HPColorClose(0xfe0200,0xff0000,1));
    HPColorPoint red={0xff0000,0,0,0,0,0};
    assert(HPFindColors(image,&red,1,all,0,0,1,xy,16,0,0)==1&&xy[0]==2&&xy[1]==1);
    HPColorPoint pair[2]={red,{0x008000,1,1,0,0,0}};
    assert(HPFindColors(image,pair,2,all,0,0,0,xy,16,0,0)==1);
    pair[1].invert=1;assert(HPFindColors(image,pair,2,all,0,0,0,xy,16,0,0)==0);
    pair[1].any=1;assert(HPFindColors(image,pair,2,all,0,0,0,xy,16,0,0)==1);
    assert(HPCountColor(image,0,0,all,0,0)==14);assert(HPCountColor(image,0,0,all,yes,0)==-1);
    assert(HPFindColors(image,&red,1,all,1,1,0,xy,16,yes,0)==-1);
    uint8_t patch[4]={0,0,255,255};HPBitmap pattern={patch,1,1,4};
    assert(HPFindImage(image,pattern,all,1,1,1,found,16,0,0)==1&&found[0].x==2&&found[0].y==1&&found[0].score==1);
    assert(HPFindImage(image,pattern,(HPRegion){0,0,1,1},1,1,1,found,16,0,0)==0);
    patch[3]=0;assert(HPFindImage(image,pattern,all,1,1,1,found,16,0,0)==-3);patch[3]=255;
    assert(HPFindImage(image,pattern,all,1,1,1,found,16,yes,0)==-1);
    assert(HPFindImage(image,pattern,all,1,1,0,found,16,0,0)==-3);
    assert(HPCountColor(image,0,0,(HPRegion){-1,0,4,4},0,0)==-3);
    assert(HPFindColors(image,&red,1,(HPRegion){0,0,4,4},0,0,1,xy,16,0,0)==1);
    HPColorPoint black={0,0,0,0,0,0};assert(HPFindColors(image,&black,1,all,1,1,1,xy,16,0,0)==1&&xy[0]==3&&xy[1]==3);
    /* Near matches force substantial work: verify the CPU budget aborts with
     * an explicit error instead of hanging or reporting a false empty set. */
    uint8_t *large=calloc(512*512,4),*almost=malloc(256*256*4);assert(large&&almost);
    for(size_t i=0;i<512*512;i++)large[i*4+3]=255;
    for(size_t i=0;i<256*256;i++){almost[i*4]=almost[i*4+1]=almost[i*4+2]=1;almost[i*4+3]=255;}
    assert(HPFindImage((HPBitmap){large,512,512,512*4},(HPBitmap){almost,256,256,256*4},(HPRegion){0,0,512,512},.9961,1,1,found,16,0,0)==-2);
    free(almost);free(large);
    puts("screen algorithms: BGRA, tolerances, offsets, inverse/any, region, order, SAD, transparency, cancellation passed");return 0;
}
