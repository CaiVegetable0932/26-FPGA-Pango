#include "wire.h"
#include <assert.h>
#include <string.h>
static unsigned frames;
static void receive(void *c,uint8_t cmd,uint16_t seq,const uint8_t *p,uint16_t n,uint64_t t)
{ (void)c;(void)t; assert(cmd==0x46 && seq==7 && n==3 && p[0]==0x55 && p[1]==0xaa); ++frames; }
int main(void)
{
    uint8_t frame[64], payload[]={0x55,0xaa,1};
    assert(wire_crc((const uint8_t *)"123456789",9)==0x29b1);
    size_t n=wire_frame(frame,0x46,7,payload,sizeof(payload));
    WireParser p; wire_init(&p,30,receive,0);
    for (size_t i=0;i<n;i++) wire_feed(&p,frame[i],100+i);
    assert(frames==1 && p.crc_errors==0);
    frame[n-1]^=1; for (size_t i=0;i<n;i++) wire_feed(&p,frame[i],1000+i);
    assert(frames==1 && p.crc_errors==1);
    frame[n-1]^=1;
    for (unsigned j=0;j<2;j++) for (size_t i=0;i<n;i++) wire_feed(&p,frame[i],2000+j*100+i);
    assert(frames==3);
    wire_feed(&p,0x55,5000); wire_feed(&p,0xaa,5001); wire_poll(&p,35000);
    assert(p.timeouts==1 && !p.used);
    uint8_t bad_header[]={0x55,0xaa,2,0x40,1,0,1,4};
    uint32_t length_errors=p.length_errors;
    for (unsigned i=0;i<sizeof(bad_header);i++) wire_feed(&p,bad_header[i],40000+i);
    assert(p.length_errors==length_errors+1);
    for (size_t i=0;i<n;i++) wire_feed(&p,frame[i],50000+i);
    assert(frames==4);
    /* An incomplete corrupt frame must preserve the following valid frame. */
    wire_feed(&p,0x55,60000);wire_feed(&p,0xaa,60001);
    for (size_t i=0;i<n;i++) wire_feed(&p,frame[i],60002+i);
    assert(frames==5);
    return 0;
}
