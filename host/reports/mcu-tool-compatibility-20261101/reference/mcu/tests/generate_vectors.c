#include "wire.h"
#include <stdio.h>
#include <string.h>

/* C-generated wire evidence is checked by a separate Python implementation. */
static FILE *output;
static void emit(const char *name,uint8_t cmd,uint16_t seq,const uint8_t *p,uint16_t n,int last)
{
    uint8_t frame[300]; size_t size=wire_frame(frame,cmd,seq,p,n);
    fprintf(output,"  \"%s\": \"",name);
    for(size_t i=0;i<size;i++) fprintf(output,"%02X",frame[i]);
    fprintf(output,"\"%s\n",last?"":",");
}
int main(int argc,char **argv)
{
    if(argc!=2) return 1;
    output=fopen(argv[1],"wb"); if(!output) return 1;
    fputs("{\n",output);
    uint8_t p[96]={0}; emit("GET_INFO",0x40,1,p,0,0);
    wire_put32(p,100);wire_put64(p+4,11);emit("OPEN",0x41,2,p,16,0);
    memset(p,0,sizeof(p));wire_put64(p,11);wire_put32(p+8,100);wire_put32(p+12,1);
    wire_put32(p+16,7);wire_put32(p+20,0x8df);wire_put64(p+24,1000000);wire_put64(p+32,1001000);
    wire_put32(p+40,1000000);wire_put32(p+44,2000000);wire_put32(p+48,3000000);
    wire_put32(p+52,10000);wire_put32(p+56,(uint32_t)-20000);wire_put64(p+60,999000);
    wire_put32(p+80,1);wire_put32(p+84,1);p[88]=31;p[89]=31;p[90]=21;p[91]=10;p[93]=2;
    emit("STATE",0x81,7,p,96,0);
    memset(p,0,sizeof(p));wire_put64(p,11);wire_put32(p+8,100);wire_put32(p+12,1);p[16]=3;
    wire_put32(p+20,1000000);wire_put32(p+24,2000000);wire_put16(p+40,10);wire_put16(p+42,10);
    emit("MOVE_ABS",0x46,3,p,48,0);
    memset(p,0,sizeof(p));wire_put64(p,11);wire_put32(p+8,100);wire_put32(p+12,1);
    wire_put64(p+16,1000000);wire_put32(p+24,1);wire_put16(p+28,2);wire_put32(p+32,1);p[38]=3;
    emit("EVENT",0x90,1,p,40,0);
    memset(p,0,sizeof(p));wire_put64(p,11);wire_put32(p+8,100);wire_put32(p+12,1);
    wire_put64(p+16,900000);wire_put64(p+24,1000000);wire_put64(p+32,1000100);
    emit("SYNC_REPLY",0x82,4,p,40,1);fputs("}\n",output);
    return fclose(output)!=0;
}
