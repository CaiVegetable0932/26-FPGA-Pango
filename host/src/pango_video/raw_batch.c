/* Validate/copy an admitted RAW frame's queued chunks without per-packet GIL
 * transitions. New identities and exceptional layouts return to Python's
 * reference decoder; CRC and byte-exact duplicate checks are never skipped. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <time.h>
#include <zlib.h>

struct pango_result {
    uint32_t consumed, accepted, duplicates, retransmitted, out_of_order;
    uint32_t rejected_crc, complete, conflict;
    int32_t highest_index;
    uint64_t payload_bytes, complete_ns;
};

static uint32_t little32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24);
}
static uint32_t little16(const uint8_t *p) {return (uint32_t)p[0] | ((uint32_t)p[1]<<8);}
static uint64_t monotonic_ns(void) {
    struct timespec stamp;
    clock_gettime(CLOCK_MONOTONIC, &stamp);
    return (uint64_t)stamp.tv_sec*1000000000ULL + (uint64_t)stamp.tv_nsec;
}

/* Explicit fixed-width result ABI shared by ctypes on Linux ARM64/x86_64.
 * Buffers belong to the caller and remain alive until this call returns. */
void pango_raw_apply(const struct mmsghdr *messages, uint32_t start, uint32_t count,
        uint32_t peer_address, uint16_t peer_port, const uint8_t *template_header,
        uint8_t *data, uint32_t frame_bytes, uint8_t *seen, uint32_t packet_count,
        uint32_t received, int32_t highest_index, uint64_t deadline_ns,
        struct pango_result *result) {
    static const uint8_t zeros[4] = {0,0,0,0};
    memset(result, 0, sizeof(*result));
    result->highest_index = highest_index;
    for (uint32_t n=0; n<count; n++) {
        const struct mmsghdr *message = &messages[start+n];
        const struct sockaddr_in *peer = message->msg_hdr.msg_name;
        const uint8_t *p = message->msg_hdr.msg_iov[0].iov_base;
        uint32_t length = message->msg_len;
        uint64_t now = monotonic_ns();
        if (now>=deadline_ns || peer->sin_family!=AF_INET || peer->sin_addr.s_addr!=peer_address
                || peer->sin_port!=peer_port || length<=64 || length>1464)
            break;
        /* Invariants include magic/version/type, source epoch/frame, geometry,
         * Bayer phase, descriptor and packet count, matching Python exactly. */
        if (memcmp(p,template_header,9) || memcmp(p+10,template_header+10,34)
                || memcmp(p+50,template_header+50,2) || memcmp(p+54,template_header+54,2)
                || memcmp(p+60,template_header+60,4))
            break;
        uint32_t index=little16(p+52), offset=little32(p+44), bytes=little16(p+48), flags=p[9];
        if (index>=packet_count || offset!=index*1400 || offset>=frame_bytes)
            break;
        uint32_t expected=frame_bytes-offset;
        if (expected>1400)expected=1400;
        if (bytes!=expected || length!=64+bytes || (flags & ~3U)
                || !!(flags & 2U)!=(index==packet_count-1))
            break;
        uLong crc=crc32(0,p,56);
        crc=crc32(crc,zeros,4);
        crc=crc32(crc,p+60,length-60);
        result->consumed++;
        result->payload_bytes+=length;
        if ((uint32_t)crc!=little32(p+56)) {result->rejected_crc++;continue;}
        if (seen[index]) {
            if (memcmp(data+offset,p+64,bytes)) {result->conflict=1;break;}
            result->duplicates++;continue;
        }
        if ((int32_t)index<result->highest_index)result->out_of_order++;
        if ((int32_t)index>result->highest_index)result->highest_index=(int32_t)index;
        memcpy(data+offset,p+64,bytes);
        seen[index]=1;
        result->accepted++;
        if (flags & 1U)result->retransmitted++;
        if (received+result->accepted==packet_count) {
            result->complete=1;result->complete_ns=now;break;
        }
    }
}
