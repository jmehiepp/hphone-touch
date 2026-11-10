#import <Foundation/Foundation.h>
#import "Services.h"
#include <stdio.h>
int main(void){@autoreleasepool{
    char *line=NULL;size_t capacity=0;ssize_t count;
    while((count=getline(&line,&capacity,stdin))>0){@autoreleasepool{
        NSData *bytes=[NSData dataWithBytes:line length:count];
        id request=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        NSDictionary *result=HPService(request[@"operation"],request[@"arguments"]?:@{});
        NSData *out=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        fwrite(out.bytes,1,out.length,stdout);fputc('\n',stdout);fflush(stdout);
    }}free(line);return 0;
}}
