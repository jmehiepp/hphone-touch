#include "ScreenAlgorithms.h"
#include <math.h>
#include <stdlib.h>
#include <limits.h>
int HPBitmapValid(HPBitmap v){return v.bytes&&v.width&&v.height&&v.width<=8192&&v.height<=8192&&v.row>=v.width*4&&v.row<=128*1024*1024/v.height;}
uint32_t HPColorAt(HPBitmap v,size_t x,size_t y){const uint8_t *p=v.bytes+y*v.row+x*4;return ((uint32_t)p[2]<<16)|((uint32_t)p[1]<<8)|p[0];}
int HPColorClose(uint32_t a,uint32_t b,int t){if(t<0||t>255)return 0;return abs((int)((a>>16)&255)-(int)((b>>16)&255))<=t&&abs((int)((a>>8)&255)-(int)((b>>8)&255))<=t&&abs((int)(a&255)-(int)(b&255))<=t;}
static int regionValid(HPBitmap v,HPRegion r){return HPBitmapValid(v)&&r.x>=0&&r.y>=0&&r.width>0&&r.height>0&&(size_t)r.x<v.width&&(size_t)r.y<v.height&&(size_t)r.width<=v.width-(size_t)r.x&&(size_t)r.height<=v.height-(size_t)r.y;}
int HPFindColors(HPBitmap v,const HPColorPoint *p,size_t n,HPRegion r,int rtl,int btt,size_t count,int *xy,size_t capacity,HPCancelCheck cancel,void *ctx){
    if(!regionValid(v,r)||!p||!n||n>256||!xy||!capacity)return -3;
    size_t used=0,limit=count&&count<capacity?count:capacity;uint64_t work=0;
    for(int yi=0;yi<r.height;yi++){int y=r.y+(btt?r.height-1-yi:yi);if(cancel&&cancel(ctx))return -1;
        for(int xi=0;xi<r.width;xi++){int x=r.x+(rtl?r.width-1-xi:xi),match=1;
            for(size_t i=0;i<n;i++){if(++work>250000000)return -2;if(p[i].dx<-8192||p[i].dx>8192||p[i].dy<-8192||p[i].dy>8192)return -3;
                int px=x+p[i].dx,py=y+p[i].dy;if(px<0||py<0||(size_t)px>=v.width||(size_t)py>=v.height){match=0;break;}
                if(!p[i].any){int same=HPColorClose(HPColorAt(v,(size_t)px,(size_t)py),p[i].color,p[i].tolerance);if((p[i].invert&&same)||(!p[i].invert&&!same)){match=0;break;}}
            }if(match){xy[used*2]=x;xy[used*2+1]=y;if(++used>=limit)return (int)used;}
        }
    }return (int)used;
}
int64_t HPCountColor(HPBitmap v,uint32_t color,int t,HPRegion r,HPCancelCheck cancel,void *ctx){if(!regionValid(v,r)||t<0||t>255)return -3;int64_t n=0;for(int y=r.y;y<r.y+r.height;y++){if(cancel&&cancel(ctx))return -1;for(int x=r.x;x<r.x+r.width;x++)n+=HPColorClose(HPColorAt(v,(size_t)x,(size_t)y),color,t);}return n;}
int HPFindImage(HPBitmap v,HPBitmap p,HPRegion r,double threshold,size_t count,size_t step,HPImageMatch *out,size_t capacity,HPCancelCheck cancel,void *ctx){
    if(!regionValid(v,r)||!HPBitmapValid(p)||!isfinite(threshold)||threshold<0||threshold>1||!step||step>8192||!out||!capacity)return -3;
    if(p.width>(size_t)r.width||p.height>(size_t)r.height)return 0;
    uint64_t pixels=0;for(size_t y=0;y<p.height;y++)for(size_t x=0;x<p.width;x++)if(p.bytes[y*p.row+x*4+3])pixels++;
    if(!pixels)return -3;
    double maximum=(double)pixels*3*255,allowed=(1-threshold)*maximum;size_t used=0,limit=count&&count<capacity?count:capacity;uint64_t work=0;
    int xmax=r.x+r.width-(int)p.width,ymax=r.y+r.height-(int)p.height;
    for(int y=r.y;y<=ymax;y+=(int)step){for(int x=r.x;x<=xmax;x+=(int)step){
        if(cancel&&cancel(ctx))return -1;
        int overlap=0;for(size_t k=0;k<used;k++)if(x<out[k].x+out[k].width&&x+(int)p.width>out[k].x&&y<out[k].y+out[k].height&&y+(int)p.height>out[k].y){overlap=1;break;}if(overlap)continue;
        uint64_t sad=0;int fail=0;
        for(size_t py=0;py<p.height&&!fail;py++){
            if(cancel&&cancel(ctx))return -1;
            const uint8_t *vp=v.bytes+((size_t)y+py)*v.row+(size_t)x*4,*pp=p.bytes+py*p.row;
            for(size_t px=0;px<p.width;px++,vp+=4,pp+=4){if(!pp[3])continue;
                work+=3;if(work>250000000)return -2;
                sad+=(uint64_t)(abs((int)vp[0]-pp[0])+abs((int)vp[1]-pp[1])+abs((int)vp[2]-pp[2]));
                if((double)sad>allowed){fail=1;break;}
            }
        }
        if(!fail){out[used]=(HPImageMatch){x,y,(int)p.width,(int)p.height,1-(double)sad/maximum};if(++used>=limit)return (int)used;}
    }}return (int)used;
}
