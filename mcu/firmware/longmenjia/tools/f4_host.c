/*
 * f4_host.c —— STM32F407 龙门架控制器 PC 侧测试工具（MCU_POSE_V2 协议）
 *
 * 作用：把版本 2 二进制帧（55 AA ... CRC）封装好，让操作者只打 ASCII。
 *   - 交互控制台：手打 measure 3 start / over / set 3 1.234 / out 0 10 / state，
 *     工具负责封成 0x50 LEGACY 帧，并每 300 ms 自动发 HEARTBEAT 续租约。
 *   - 结构化命令：/state /move /home /posezero /gimbal /counters ...
 *   - 只读模式：--mode fpga，只发 INFO/OPEN/STREAM/STATUS/COUNTERS/SYNC。
 *
 * 协议依据（实现与文档核对一致）：
 *   output/MCU_POSE_V2接口实现补充.md
 *   output/MCU五轴控制与FPGA通信开发交接文档.md
 *   mcu/firmware/common/wire.c（帧与 CRC）
 *   mcu/firmware/longmenjia/Core/Src/f4_link.c（命令与状态语义）
 *   mcu/firmware/longmenjia/Core/Src/main.c（LEGACY 文本语义）
 *
 * 构建（Windows + MinGW）：
 *   gcc -O2 -Wall -Wextra -o f4_host.exe f4_host.c
 * 自检（不需要硬件）：
 *   f4_host.exe --selftest
 *
 * 本工具只读硬件状态、只按操作者输入发命令；不烧录、不改固件。
 */

/* MinGW 默认走老 msvcrt，不支持 %lld / %zu；必须在任何头文件之前打开 ANSI stdio。 */
#if defined(_WIN32) && !defined(__USE_MINGW_ANSI_STDIO)
#define __USE_MINGW_ANSI_STDIO 1
#endif

#if !defined(_WIN32)
#error "当前只实现 Windows 串口与线程；Linux 版需要补 termios/pthread 分支。"
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>
#include <conio.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>

/* ------------------------------------------------------------------ */
/* 协议常量                                                            */
/* ------------------------------------------------------------------ */

#define WIRE_VERSION      2U
#define WIRE_MAX_PAYLOAD  1024U
#define WIRE_MAX_FRAME    (WIRE_MAX_PAYLOAD + 10U)

#define CMD_GET_INFO      0x40U
#define CMD_OPEN          0x41U
#define CMD_GET_CONFIG    0x42U
#define CMD_SET_STREAM    0x43U
#define CMD_GET_STATUS    0x44U
#define CMD_SYNC          0x45U
#define CMD_MOVE_ABS      0x46U
#define CMD_HOME          0x48U
#define CMD_ACK_EVENT     0x49U
#define CMD_SET_POSE_ZERO 0x4AU
#define CMD_GET_COUNTERS  0x4BU
#define CMD_HEARTBEAT     0x4CU
#define CMD_GET_RAW_IMU   0x4DU
#define CMD_LEGACY        0x50U
#define CMD_CONFIRM_ZERO  0x51U
#define CMD_GET_GIMBAL    0x52U

#define RSP_GENERIC       0x80U
#define RSP_STATE         0x81U
#define RSP_SYNC          0x82U
#define RSP_EVENT         0x90U
#define RSP_NOTICE        0x91U

/* result 码，见交接文档 line 156 */
#define RES_OK            0U
#define RES_ACCEPTED      1U
#define RES_BUSY          2U
#define RES_BAD_LENGTH    3U
#define RES_RANGE         4U
#define RES_BAD_CONTEXT   5U
#define RES_UNSUPPORTED   6U
#define RES_NOT_READY     7U
#define RES_CONFLICT      8U
#define RES_FAULT         9U
#define RES_STALE         10U

#define MASK_X 0x01U
#define MASK_Y 0x02U
#define MASK_Z 0x04U
#define MASK_XYZ (MASK_X | MASK_Y | MASK_Z)
#define MASK_GIMBAL 0x18U

#define COORD_SCALE 100000000LL  /* 0..100 归一化坐标，1e-6 单位 */

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static uint64_t now_us(void)
{
    static LARGE_INTEGER freq;
    static int ready;
    LARGE_INTEGER c;
    if (!ready) {
        QueryPerformanceFrequency(&freq);
        ready = 1;
    }
    QueryPerformanceCounter(&c);
    return (uint64_t)((double)c.QuadPart * 1000000.0 / (double)freq.QuadPart);
}

static void sleep_ms(unsigned ms) { Sleep(ms); }

static unsigned long long U64(uint64_t v) { return (unsigned long long)v; }

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)rd16(p) | ((uint32_t)rd16(p + 2) << 16); }
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32); }
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void wr32(uint8_t *p, uint32_t v) { wr16(p, (uint16_t)v); wr16(p + 2, (uint16_t)(v >> 16)); }
static void wr64(uint8_t *p, uint64_t v) { wr32(p, (uint32_t)v); wr32(p + 4, (uint32_t)(v >> 32)); }

/* "12.345678"：X/Y/Z 是 1e-6 单位的 0..100 归一化坐标 */
static void fmt_coord(int32_t v, char *out, size_t cap)
{
    long long mag = (v < 0) ? -(long long)v : (long long)v;
    snprintf(out, cap, "%s%lld.%06lld", (v < 0) ? "-" : "",
             mag / 1000000LL, mag % 1000000LL);
}

/* mdeg -> "+125.031" 度 */
static void fmt_mdeg(int32_t v, char *out, size_t cap)
{
    long long mag = (v < 0) ? -(long long)v : (long long)v;
    snprintf(out, cap, "%s%lld.%03lld", (v < 0) ? "-" : "",
             mag / 1000LL, mag % 1000LL);
}

static const char *result_name(unsigned r)
{
    switch (r) {
    case RES_OK:          return "OK";
    case RES_ACCEPTED:    return "ACCEPTED";
    case RES_BUSY:        return "BUSY";
    case RES_BAD_LENGTH:  return "BAD_LENGTH";
    case RES_RANGE:       return "RANGE";
    case RES_BAD_CONTEXT: return "BAD_CONTEXT";
    case RES_UNSUPPORTED: return "UNSUPPORTED";
    case RES_NOT_READY:   return "NOT_READY";
    case RES_CONFLICT:    return "CONFLICT";
    case RES_FAULT:       return "FAULT";
    case RES_STALE:       return "STALE";
    default:              return "?";
    }
}

static const char *fault_name(unsigned f)
{
    switch (f) {
    case 0:  return "NONE";
    case 1:  return "IMU_IO";
    case 2:  return "IMU_STALE";
    case 3:  return "IMU_CALIBRATION";
    case 4:  return "LIMIT";
    case 5:  return "DRIVER";
    case 6:  return "HOME_TIMEOUT";
    case 7:  return "MOTION_TIMEOUT";
    case 8:  return "CONTROL_LINK_LOST";
    case 9:  return "EVENT_OVERFLOW";
    case 10: return "CONFIG";
    case 11: return "ANGLE_NOT_SETTLED";
    default: return "?";
    }
}

static const char *motion_name(unsigned m)
{
    switch (m) {
    case 0: return "IDLE";
    case 1: return "MOVING";
    case 2: return "HOMING";
    case 3: return "SETTLING";
    case 4: return "(reserved)";
    case 5: return "FAULT";
    default: return "?";
    }
}

static const char *event_name(unsigned t)
{
    switch (t) {
    case 1: return "ACCEPTED";
    case 2: return "MOTION_DONE";
    case 4: return "HOME_DONE";
    case 5: return "CANCELLED";
    case 7: return "POSE_ZEROED";
    case 8: return "LINK_LOST";
    default: return "?";
    }
}

static const char *event_result_name(unsigned r)
{
    switch (r) {
    case 0: return "OK";
    case 1: return "FAILED";
    case 2: return "USER_STOP";
    case 3: return "LEASE_LOST";
    default: return "?";
    }
}

/* ------------------------------------------------------------------ */
/* CRC-16/CCITT-FALSE（与 common/wire.c 同一算法）                      */
/* ------------------------------------------------------------------ */

static uint16_t crc16(const uint8_t *p, size_t n)
{
    uint16_t crc = 0xFFFFU;
    while (n--) {
        crc ^= (uint16_t)(*p++) << 8;
        for (unsigned j = 0; j < 8; ++j)
            crc = (uint16_t)((crc & 0x8000U) ? (((uint32_t)crc << 1) ^ 0x1021U)
                                             : ((uint32_t)crc << 1));
    }
    return crc;
}

/* ------------------------------------------------------------------ */
/* 帧解析（流式，抗丢字节）                                             */
/* ------------------------------------------------------------------ */

typedef void (*frame_cb)(uint8_t cmd, uint16_t seq, const uint8_t *payload, uint16_t n);

typedef struct {
    uint8_t  buf[WIRE_MAX_FRAME];
    size_t   used;
    uint32_t crc_errors;
    uint32_t length_errors;
} Wire;

static void wire_reset(Wire *w) { w->used = 0; w->crc_errors = 0; w->length_errors = 0; }

static void wire_drop(Wire *w, size_t n)
{
    if (n >= w->used) { w->used = 0; return; }
    memmove(w->buf, w->buf + n, w->used - n);
    w->used -= n;
}

/* 逐字节喂入；坏帧只丢 1 字节，让后面嵌套的好帧还能活下来。 */
static void wire_feed(Wire *w, uint8_t b, frame_cb cb)
{
    if (w->used >= sizeof(w->buf)) wire_drop(w, 1);
    w->buf[w->used++] = b;

    for (;;) {
        if (w->used == 0) return;
        if (w->buf[0] != 0x55U || (w->used > 1 && w->buf[1] != 0xAAU)) { wire_drop(w, 1); continue; }
        if (w->used < 8) return;
        uint16_t n = rd16(w->buf + 6);
        if (w->buf[2] != WIRE_VERSION || n > WIRE_MAX_PAYLOAD) {
            ++w->length_errors; wire_drop(w, 1); continue;
        }
        size_t need = (size_t)n + 10U;
        if (w->used < need) return;
        if (rd16(w->buf + 8 + n) != crc16(w->buf + 2, (size_t)6 + n)) {
            ++w->crc_errors; wire_drop(w, 1); continue;
        }
        cb(w->buf[3], rd16(w->buf + 4), w->buf + 8, n);
        wire_drop(w, need);
    }
}

static size_t wire_build(uint8_t *out, uint8_t cmd, uint16_t seq,
                         const uint8_t *payload, uint16_t n)
{
    if (n > WIRE_MAX_PAYLOAD) return 0;
    out[0] = 0x55; out[1] = 0xAA; out[2] = WIRE_VERSION; out[3] = cmd;
    wr16(out + 4, seq);
    wr16(out + 6, n);
    if (n) memcpy(out + 8, payload, n);
    wr16(out + 8 + n, crc16(out + 2, (size_t)6 + n));
    return (size_t)n + 10U;
}

/* ------------------------------------------------------------------ */
/* 串口（Win32，DTR/RTS 关闭，避免复位目标板）                           */
/* ------------------------------------------------------------------ */

typedef struct { HANDLE h; } Ser;

static int ser_open(Ser *s, const char *name, unsigned baud)
{
    char path[128];
    if ((name[0] == 'C' || name[0] == 'c') && (name[1] == 'O' || name[1] == 'o') &&
        (name[2] == 'M' || name[2] == 'm'))
        snprintf(path, sizeof(path), "\\\\.\\%s", name);
    else
        snprintf(path, sizeof(path), "%s", name);

    s->h = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                       OPEN_EXISTING, 0, NULL);
    if (s->h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "打开串口失败 %s（GetLastError=%lu）\n", path,
                (unsigned long)GetLastError());
        return -1;
    }

    DCB dcb;
    memset(&dcb, 0, sizeof(dcb));
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(s->h, &dcb)) { fprintf(stderr, "GetCommState 失败\n"); return -1; }
    dcb.BaudRate = (DWORD)baud;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    dcb.fParity = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;
    dcb.fDsrSensitivity = FALSE;
    /* 关键：不能让 DTR/RTS 去动 BOOT0/RST。 */
    dcb.fDtrControl = DTR_CONTROL_DISABLE;
    dcb.fRtsControl = RTS_CONTROL_DISABLE;
    if (!SetCommState(s->h, &dcb)) { fprintf(stderr, "SetCommState 失败\n"); return -1; }

    COMMTIMEOUTS to;
    memset(&to, 0, sizeof(to));
    /* 收到字节就返回；没有字节时最多等 20 ms，避免忙等。 */
    to.ReadIntervalTimeout = MAXDWORD;
    to.ReadTotalTimeoutMultiplier = 0;
    to.ReadTotalTimeoutConstant = 20;
    to.WriteTotalTimeoutMultiplier = 0;
    to.WriteTotalTimeoutConstant = 500;
    if (!SetCommTimeouts(s->h, &to)) { fprintf(stderr, "SetCommTimeouts 失败\n"); return -1; }

    SetupComm(s->h, 8192, 8192);
    PurgeComm(s->h, PURGE_RXCLEAR | PURGE_TXCLEAR);
    return 0;
}

static void ser_close(Ser *s)
{
    if (s->h && s->h != INVALID_HANDLE_VALUE) CloseHandle(s->h);
    s->h = NULL;
}

static int ser_write(Ser *s, const uint8_t *p, size_t n)
{
    DWORD written = 0;
    if (!WriteFile(s->h, p, (DWORD)n, &written, NULL)) return -1;
    return (written == n) ? 0 : -1;
}

static int ser_read(Ser *s, uint8_t *p, size_t cap)
{
    DWORD got = 0;
    if (!ReadFile(s->h, p, (DWORD)cap, &got, NULL)) return -1;
    return (int)got;
}

/* 运行中改波特率（不重开句柄），用于"用不同速率注入另一条 UART"的测试。
 * 只清 RX：清 TX 会把刚写入驱动缓冲、还没发完的数据截断。 */
static int ser_set_baud(Ser *s, unsigned baud)
{
    DCB dcb;
    memset(&dcb, 0, sizeof(dcb));
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(s->h, &dcb)) return -1;
    dcb.BaudRate = (DWORD)baud;
    if (!SetCommState(s->h, &dcb)) return -1;
    PurgeComm(s->h, PURGE_RXCLEAR);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 互斥与线程                                                          */
/* ------------------------------------------------------------------ */

typedef CRITICAL_SECTION Mutex;
static void mtx_init(Mutex *m) { InitializeCriticalSection(m); }
static void mtx_lock(Mutex *m) { EnterCriticalSection(m); }
static void mtx_unlock(Mutex *m) { LeaveCriticalSection(m); }

typedef HANDLE Thread;
static Thread thread_start(unsigned (__stdcall *fn)(void *), void *arg)
{
    return (Thread)_beginthreadex(NULL, 0, fn, arg, 0, NULL);
}

/* ------------------------------------------------------------------ */
/* 全局状态                                                            */
/* ------------------------------------------------------------------ */

enum { MODE_HOST = 0, MODE_FPGA = 1 };

typedef struct {
    char     port[64];
    unsigned baud;
    int      mode;
    unsigned rate;
    unsigned heartbeat_ms;
    int      heartbeat_on;
    int      verbose;
    int      raw;           /* 原样打印收到的每个字节（诊断接线/波特率） */
    int      state_all;     /* 每一帧 STATE 都打印，不只在变化时 */
    int      loopback;      /* 只做 TX-RX 短接自检 */
    int      terminal;      /* 原始串口终端，不做协议 */
    char     echo_text[64]; /* --echo：发送该文本并统计回显 */
    unsigned listen_ms;     /* >0：只监听不发送，用于判断对端是否在发 */
    unsigned capture_ms;    /* >0：只收不发送，把收到的字节按文本打印 */
    FILE    *log;
} Config;

typedef struct {
    uint64_t boot;          /* 目标板本次启动 id，来自 GET_INFO/任何回应头 */
    uint32_t session;
    uint32_t config;
    uint32_t next_motion;   /* LEGACY request_id 与 MOVE/HOME motion_id 共用 */
    uint16_t seq;
    int      opened;
    uint64_t t0;

    int      have_state;
    uint32_t last_sample;
    uint32_t last_motion_seen;
    uint32_t last_event_seen;
    uint32_t last_event_acked;
    uint8_t  last_valid;
    uint8_t  last_motion_state;
    uint16_t last_fault;
    uint32_t last_flags;
    int32_t  last_pos[5];
    uint32_t state_printed;
    int      zero_expected; /* 已发 SET_POSE_ZERO，等最终回应 */
} State;

static Config g_cfg;
static State  g_st;
static Ser    g_ser;
static Mutex  g_tx_lock;
static Mutex  g_out_lock;
static int    g_out_ready;
static Wire   g_wire;
static volatile int g_quit;
static volatile uint32_t g_rx_bytes;
static unsigned g_listen_frames;

/* ------------------------------------------------------------------ */
/* 输出                                                                */
/* ------------------------------------------------------------------ */

static void out_init(void)
{
    if (!g_out_ready) { mtx_init(&g_out_lock); g_out_ready = 1; }
}

static void out_line(const char *fmt, ...)
{
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    if (g_out_ready) mtx_lock(&g_out_lock);
    fputs(buf, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    if (g_cfg.log) { fputs(buf, g_cfg.log); fputc('\n', g_cfg.log); }
    if (g_out_ready) mtx_unlock(&g_out_lock);
}

/* 带相对时间戳的一行 */
static void log_line(const char *tag, const char *fmt, ...)
{
    char body[1600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    uint64_t us = now_us();
    unsigned long long ms = us / 1000ULL;
    out_line("[%7llu.%03llu] %-2s %s", ms / 1000ULL, ms % 1000ULL, tag, body);
}

/* ------------------------------------------------------------------ */
/* 发送                                                                */
/* ------------------------------------------------------------------ */

static void dump_hex(const uint8_t *p, size_t n, char *out, size_t cap)
{
    size_t o = 0;
    out[0] = '\0';
    for (size_t i = 0; i < n && o + 4 < cap; ++i) {
        int w = snprintf(out + o, cap - o, "%02X ", p[i]);
        if (w < 0) break;
        o += (size_t)w;
    }
}

/* 返回实际用的 seq；payload 已含上下文（除 GET_INFO/OPEN） */
static uint16_t send_frame(uint8_t cmd, const uint8_t *payload, uint16_t n, const char *what)
{
    uint8_t frame[WIRE_MAX_FRAME];
    uint16_t seq = g_st.seq;

    if (seq == 0 || seq >= 0xFFF0U) {
        out_line("!! seq 即将耗尽（%u），必须重启目标板与工具", (unsigned)seq);
        return 0;
    }
    ++g_st.seq;

    size_t len = wire_build(frame, cmd, seq, payload, n);
    if (!len) { out_line("!! 帧过长"); return 0; }

    mtx_lock(&g_tx_lock);
    int rc = ser_write(&g_ser, frame, len);
    mtx_unlock(&g_tx_lock);

    if (rc) { out_line("!! 串口写失败"); return 0; }

    if (g_cfg.verbose) {
        char hex[WIRE_MAX_FRAME * 3];
        dump_hex(frame, len, hex, sizeof(hex));
        log_line("TX", "0x%02X seq=%-5u %-22s %s", cmd, (unsigned)seq,
                 what ? what : "", hex);
    } else {
        log_line("TX", "0x%02X seq=%-5u %s", cmd, (unsigned)seq, what ? what : "");
    }
    return seq;
}

/* 填上下文：boot(8) + session(4) */
static void put_ctx(uint8_t *p)
{
    wr64(p, g_st.boot);
    wr32(p + 8, g_st.session);
}

/* ------------------------------------------------------------------ */
/* 结构化请求                                                          */
/* ------------------------------------------------------------------ */

static void req_get_info(void)          { send_frame(CMD_GET_INFO, NULL, 0, "GET_INFO"); }

static void req_open(uint32_t session)
{
    uint8_t p[16];
    memset(p, 0, sizeof(p));
    wr32(p, session);
    wr64(p + 4, g_st.boot);
    wr32(p + 12, 0);
    send_frame(CMD_OPEN, p, sizeof(p), "OPEN");
}

static void req_set_stream(unsigned hz)
{
    uint8_t p[16];
    put_ctx(p);
    wr16(p + 12, (uint16_t)hz);
    wr16(p + 14, 0);
    send_frame(CMD_SET_STREAM, p, sizeof(p), "SET_STREAM");
}

static void req_get_status(void)
{
    uint8_t p[12];
    put_ctx(p);
    send_frame(CMD_GET_STATUS, p, sizeof(p), "GET_STATUS");
}

static void req_get_config(void)
{
    uint8_t p[12];
    put_ctx(p);
    send_frame(CMD_GET_CONFIG, p, sizeof(p), "GET_CONFIG");
}

static void req_get_counters(void)
{
    uint8_t p[12];
    put_ctx(p);
    send_frame(CMD_GET_COUNTERS, p, sizeof(p), "GET_COUNTERS");
}

static void req_get_gimbal(void)
{
    uint8_t p[12];
    put_ctx(p);
    send_frame(CMD_GET_GIMBAL, p, sizeof(p), "GET_GIMBAL");
}

static void req_heartbeat(void)
{
    uint8_t p[12];
    put_ctx(p);
    send_frame(CMD_HEARTBEAT, p, sizeof(p), "HEARTBEAT");
}

static void req_ack(uint32_t event_id)
{
    uint8_t p[16];
    put_ctx(p);
    wr32(p + 12, event_id);
    send_frame(CMD_ACK_EVENT, p, sizeof(p), "ACK_EVENT");
}

static void req_confirm_zero(uint8_t mask)
{
    uint8_t p[16];
    put_ctx(p);
    p[12] = mask;
    p[13] = p[14] = p[15] = 0;
    send_frame(CMD_CONFIRM_ZERO, p, sizeof(p), "CONFIRM_MANUAL_ZERO");
    out_line("   注：要求对应轴已停止且脉冲计数为 0；成功后 config_version 会 +1");
}

static void req_move(uint8_t mask, const int32_t target[5], const uint16_t rpm[3])
{
    uint8_t p[48];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    uint32_t id = g_st.next_motion++;
    wr32(p + 12, id);
    p[16] = mask;
    for (unsigned i = 0; i < 5; ++i) wr32(p + 20 + 4 * i, (uint32_t)target[i]);
    for (unsigned i = 0; i < 3; ++i) wr16(p + 40 + 2 * i, rpm[i]);
    char what[64];
    snprintf(what, sizeof(what), "MOVE_ABS id=%u mask=0x%02X", (unsigned)id, (unsigned)mask);
    send_frame(CMD_MOVE_ABS, p, sizeof(p), what);
}

static void req_home(uint8_t mask)
{
    uint8_t p[20];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    uint32_t id = g_st.next_motion++;
    wr32(p + 12, id);
    p[16] = mask;
    char what[64];
    snprintf(what, sizeof(what), "HOME id=%u mask=0x%02X", (unsigned)id, (unsigned)mask);
    send_frame(CMD_HOME, p, sizeof(p), what);
}

static void req_pose_zero(void)
{
    uint8_t p[12];
    put_ctx(p);
    send_frame(CMD_SET_POSE_ZERO, p, sizeof(p), "SET_POSE_ZERO");
    g_st.zero_expected = 1;
    out_line("   注：0x4A 没有即时回应，最终结果约 5 s 后到（cmd=0x4A, result=0）");
    out_line("   注：期间必须保持 HEARTBEAT，本工具已自动发送");
}

static void req_sync(uint32_t sync_id)
{
    uint8_t p[24];
    put_ctx(p);
    wr32(p + 12, sync_id);
    wr64(p + 16, now_us());
    send_frame(CMD_SYNC, p, sizeof(p), "SYNC");
}

/* LEGACY 文本合法性：1..95 个可打印 ASCII（0x20..0x7E）。
 * 固件 f4_link.c 会拒绝 <32 或 >126 的字节，并把 >95 的请求判为 BAD_LENGTH。 */
static int legacy_validate(const char *text, size_t len)
{
    if (len == 0 || len > 95) return -1;
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x20U || c > 0x7EU) return -1;
    }
    return 0;
}

/* 文本走 LEGACY：1..95 个可打印 ASCII，不能含 NUL/CR/LF/TAB */
static int req_legacy(const char *text)
{
    char buf[96];
    size_t len = strlen(text);
    while (len && (text[0] == ' ' || text[0] == '\t')) { ++text; --len; }
    while (len && (text[len - 1] == ' ' || text[len - 1] == '\t')) --len;
    if (len == 0) { out_line("!! 空命令"); return -1; }
    if (len > 95) { out_line("!! 文本超过 95 字节（固件上限）"); return -1; }
    if (legacy_validate(text, len)) {
        out_line("!! 文本含不可打印字符，固件会拒绝（result=4）");
        return -1;
    }
    memcpy(buf, text, len);
    buf[len] = '\0';

    uint8_t p[12 + 4 + 95];
    put_ctx(p);
    uint32_t id = g_st.next_motion++;
    wr32(p + 12, id);
    memcpy(p + 16, buf, len);
    char what[128];
    snprintf(what, sizeof(what), "LEGACY id=%u \"%s\"", (unsigned)id, buf);
    send_frame(CMD_LEGACY, p, (uint16_t)(16 + len), what);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 收帧解码                                                            */
/* ------------------------------------------------------------------ */

static void print_state(const uint8_t *p, uint16_t n)
{
    if (n < 96) { log_line("!!", "STATE 长度 %u 不对", (unsigned)n); return; }

    uint32_t sample = rd32(p + 16);
    uint32_t flags  = rd32(p + 20);
    uint8_t  valid  = p[89];
    uint8_t  ms     = p[92];
    uint16_t fault  = rd16(p + 94);
    int32_t  x = (int32_t)rd32(p + 40);
    int32_t  y = (int32_t)rd32(p + 44);
    int32_t  z = (int32_t)rd32(p + 48);
    int32_t  pitch = (int32_t)rd32(p + 52);
    int32_t  yaw = (int32_t)rd32(p + 56);

    /* 只在"有意义的变化"时打印：位置/有效位/运动态/故障/标志位。
     * sample 只是每帧递增的序号，单独变化不刷屏。 */
    int changed = !g_st.have_state || valid != g_st.last_valid ||
                  ms != g_st.last_motion_state || fault != g_st.last_fault ||
                  flags != g_st.last_flags ||
                  x != g_st.last_pos[0] || y != g_st.last_pos[1] ||
                  z != g_st.last_pos[2] || pitch != g_st.last_pos[3] ||
                  yaw != g_st.last_pos[4];
    g_st.have_state = 1;
    g_st.last_sample = sample;
    g_st.last_valid = valid;
    g_st.last_motion_state = ms;
    g_st.last_fault = fault;
    g_st.last_flags = flags;
    g_st.last_pos[0] = x; g_st.last_pos[1] = y; g_st.last_pos[2] = z;
    g_st.last_pos[3] = pitch; g_st.last_pos[4] = yaw;
    if (!changed && !g_cfg.state_all) return;
    ++g_st.state_printed;

    char cx[32] = "无效", cy[32] = "无效", cz[32] = "无效", cp[32] = "-", cw[32] = "-";
    if (valid & MASK_X) fmt_coord(x, cx, sizeof(cx));
    if (valid & MASK_Y) fmt_coord(y, cy, sizeof(cy));
    if (valid & MASK_Z) fmt_coord(z, cz, sizeof(cz));
    if (flags & (1U << 3)) fmt_mdeg(pitch, cp, sizeof(cp));
    if (flags & (1U << 4)) fmt_mdeg(yaw, cw, sizeof(cw));

    log_line("RX", "STATE sample=%-7u cfg=%-4u flags=0x%03X valid=0x%02X %-8s fault=%u(%s)",
             (unsigned)sample, (unsigned)rd32(p + 12), (unsigned)flags, (unsigned)valid,
             motion_name(ms), (unsigned)fault, fault_name(fault));
    out_line("              X=%-14s Y=%-14s Z=%-14s", cx, cy, cz);
    out_line("              pitch=%-12s yaw=%-12s  motion_id=%u event_id=%u",
             cp, cw, (unsigned)rd32(p + 80), (unsigned)rd32(p + 84));

    static const char *const bitname[12] = {
        "X有效", "Y有效", "Z有效", "pitch有效", "yaw有效", "IMU有效",
        "F1零位完成", "配置已验证", "运动中", "状态被替换", "事件溢出", "时间近似"
    };
    char on[256];
    size_t o = 0;
    on[0] = '\0';
    for (unsigned i = 0; i < 12; ++i) {
        if (flags & (1U << i)) {
            int w = snprintf(on + o, sizeof(on) - o, "%s%s", o ? "," : "", bitname[i]);
            if (w < 0) break;
            o += (size_t)w;
        }
    }
    out_line("              置位：%s", o ? on : "（无）");
}

static void print_event(const uint8_t *p, uint16_t n)
{
    if (n < 40) { log_line("!!", "EVENT 长度 %u 不对", (unsigned)n); return; }
    uint32_t id = rd32(p + 12);
    uint32_t motion = rd32(p + 24);
    uint16_t type = rd16(p + 28);
    uint16_t result = rd16(p + 30);
    uint16_t fault = rd16(p + 36);

    /* F4 每 100 ms 重发最早未确认事件，不确认就是刷屏，64 条环形缓冲还会溢出。 */
    if (id != g_st.last_event_acked) {
        g_st.last_event_acked = id;
        g_st.last_event_seen = id;
        log_line("EV", "event=%u motion=%u type=%u(%s) result=%u(%s) fault=%u(%s) mask=0x%02X",
                 (unsigned)id, (unsigned)motion, (unsigned)type, event_name(type),
                 (unsigned)result, event_result_name(result),
                 (unsigned)fault, fault_name(fault), (unsigned)p[38]);
        req_ack(id);
    }
}

static void print_generic(const uint8_t *p, uint16_t n)
{
    if (n < 16) { log_line("!!", "回应长度 %u 不对", (unsigned)n); return; }
    uint64_t boot = rd64(p);
    uint32_t session = rd32(p + 8);
    uint8_t req = p[12];
    uint8_t result = p[13];
    const uint8_t *data = p + 16;
    uint16_t dn = (uint16_t)(n - 16);

    /* 任何回应头都带当前 boot；顺手记录，方便断线重连判断 */
    if (boot) g_st.boot = boot;

    log_line("RX", "0x%02X req=0x%02X result=%u(%s) session=0x%08X boot=%llu data=%u B",
             RSP_GENERIC, req, (unsigned)result, result_name(result),
             (unsigned)session, U64(boot), (unsigned)dn);

    if (req == CMD_GET_INFO && dn >= 48) {
        uint64_t device = rd64(data);
        out_line("              device_id=0x%016llX fw=%u.%u profile=0x%04X 能力=0x%02X",
                 U64(device), (unsigned)rd16(data + 8), (unsigned)rd16(data + 10),
                 (unsigned)rd16(data + 14), (unsigned)rd16(data + 20));
        out_line("              config=%u pc_rate=%u fpga_rate=%u 事件=%u..%u",
                 (unsigned)rd32(data + 32), (unsigned)rd16(data + 38),
                 (unsigned)rd16(data + 36), (unsigned)rd32(data + 40),
                 (unsigned)rd32(data + 44));
        if (result == RES_FAULT)
            out_line("              !! 启动代次日志异常（boot=0），运动权限已关闭");
        return;
    }

    if (req == CMD_OPEN) {
        if (result == RES_OK) {
            /* 会话号来自回应头（固件回显请求里的新 session）。
             * 必须写回 g_st.session，否则后续请求的上下文全是 0 → BAD_CONTEXT。 */
            if (session) g_st.session = session;
            g_st.opened = 1;
            if (dn >= 8) {
                g_st.config = rd32(data);
                g_st.last_motion_seen = rd32(data + 4);
                g_st.next_motion = g_st.last_motion_seen + 1;
                out_line("              会话建立：config=%u latest_motion=%u 下一个 motion_id=%u",
                         (unsigned)g_st.config, (unsigned)g_st.last_motion_seen,
                         (unsigned)g_st.next_motion);
            }
            return;
        }
        g_st.opened = 0;
        if (result == RES_BAD_CONTEXT)
            out_line("              !! boot_id 或 session 不匹配：先 /open 重新握手");
        else
            out_line("              !! OPEN 失败，检查 GET_INFO 是否成功、boot 是否为 0");
        return;
    }

    if (req == CMD_GET_COUNTERS && dn >= 40) {
        out_line("              crc_err=%u len_err=%u timeout=%u ctx_err=%u "
                 "状态被替换=%u 事件溢出=%u 看门狗=%u",
                 (unsigned)rd32(data), (unsigned)rd32(data + 4),
                 (unsigned)rd32(data + 8), (unsigned)rd32(data + 12),
                 (unsigned)rd32(data + 28), (unsigned)rd32(data + 32),
                 (unsigned)rd32(data + 36));
        if (dn >= 64) {
            unsigned cr1 = (unsigned)rd32(data + 40), sr = (unsigned)rd32(data + 44);
            unsigned gst = (unsigned)rd32(data + 48);
            unsigned f1_rx = (unsigned)rd32(data + 52), f1_ovr = (unsigned)rd32(data + 56);
            unsigned f1_crc = (unsigned)rd32(data + 60), f1_to = (unsigned)rd32(data + 64);
            out_line("              UART4(F4侧): CR1=0x%08X  SR=0x%08X  RE=%s RXNE=%s ORE=%s",
                     cr1, sr, (cr1 & 0x4u) ? "1" : "0", (sr & 0x20u) ? "1" : "0",
                     (sr & 0x8u) ? "1" : "0");
            out_line("              F1 侧诊断：INFO计数(低6位)=%u  PA10有活动=%s  ORE=%s",
                     gst & 0x3Fu, (gst & 0x40u) ? "是" : "否", (gst & 0x80u) ? "1" : "0");
            out_line("              F1 侧 USART1 接收：累计字节(低8位)=%u  接收失败=%u  CRC错=%u  超时=%u",
                     f1_rx, f1_ovr, f1_crc, f1_to);
            if (dn >= 120) {
                out_line("              租约年龄=%u us  忙掩码=0x%X  pending年龄=%u",
                         (unsigned)rd32(data + 100), (unsigned)rd32(data + 104),
                         (unsigned)rd32(data + 108));
                unsigned step = (unsigned)rd32(data + 112), st = (unsigned)rd32(data + 116);
                const char *txt = "无失败";
                switch (step) {
                    case 10: txt = "读舵机ID失败"; break;
                    case 11: txt = "进入位置模式失败(核验)"; break;
                    case 12: txt = "限位检查失败"; break;
                    case 20: txt = "进入位置模式失败(准备)"; break;
                    case 21: txt = "读位置失败"; break;
                    case 22: txt = "锁位发送失败"; break;
                    case 23: txt = "开扭矩失败"; break;
                    case 24: txt = "回读扭矩为0"; break;
                    default: break;
                }
                out_line("              舵机总线：就绪失败步号=%u（%s）  Gimbal_State=%u（0空闲/1运动/2回正/5故障）",
                         step, txt, st);
            }
            if (dn >= 100) {
                unsigned a0 = (unsigned)rd32(data + 84), a1 = (unsigned)rd32(data + 88);
                int off = (int)rd32(data + 92);
                unsigned fl = (unsigned)rd32(data + 96);
                out_line("              反馈新鲜度：轴0年龄=%u us  轴1年龄=%u us  (门限 60000 us)",
                         a0, a1);
                out_line("              f1_offset=%d us  phase=%u zero_valid=%u home=%u servo_valid=0x%X"
                         "  → fresh=%s",
                         off, fl & 0xFFu, (fl >> 8) & 0xFFu, (fl >> 16) & 0xFFu, (fl >> 24) & 0xFu,
                         (a0 != 0xFFFFFFFFu && a1 != 0xFFFFFFFFu && a0 <= 60000u && a1 <= 60000u)
                             ? "是" : "否");
            }
        }
        out_line("              诊断：f1 累计字节=%u  完整帧=%u  F1回执(0xA0)=%u",
                 (unsigned)rd32(data + 16), (unsigned)rd32(data + 20),
                 (unsigned)rd32(data + 24));
        return;
    }

    if (req == CMD_GET_GIMBAL && dn >= 32) {
        char a1[32], a2[32], r1[32], r2[32], f1[32], f2[32];
        fmt_mdeg((int32_t)rd32(data + 12), a1, sizeof(a1));
        fmt_mdeg((int32_t)rd32(data + 16), a2, sizeof(a2));
        fmt_mdeg((int32_t)rd32(data + 20), r1, sizeof(r1));
        fmt_mdeg((int32_t)rd32(data + 24), r2, sizeof(r2));
        fmt_mdeg((int32_t)rd32(data + 4), f1, sizeof(f1));
        fmt_mdeg((int32_t)rd32(data + 8), f2, sizeof(f2));
        out_line("              raw pitch/yaw = %u / %u   (中心应为 1881 / 2405)",
                 (unsigned)rd16(data), (unsigned)rd16(data + 2));
        out_line("              绝对角 %s / %s 度   相对角 %s / %s 度",
                 a1, a2, r1, r2);
        out_line("              融合角 %s / %s 度   source=0x%02X zero_valid=%u",
                 f1, f2, (unsigned)data[28], (unsigned)data[29]);
        if (!data[29])
            out_line("              !! zero_valid=0：必须先 /home 再 /posezero，否则云台定位会被拒（result=7）");
        return;
    }

    if (req == CMD_GET_CONFIG && dn >= 264) {
        out_line("              config=%u", (unsigned)rd32(data));
        static const char *const nm[5] = { "X", "Y", "Z", "pitch", "yaw" };
        for (unsigned j = 0; j < 5; ++j) {
            const uint8_t *a = data + 104 + 32 * j;
            out_line("              %-5s min=%d max=%d vel/time=%d limit=%u",
                     nm[j], (int)rd32(a + 4), (int)rd32(a + 8),
                     (int)rd32(a + 12), (unsigned)rd32(a + 24));
        }
        out_line("              注：前三个 limit 是行程脉冲数，0 = 该轴尚未 set");
        return;
    }

    if (req == CMD_LEGACY) {
        if (dn) {
            char text[300];
            uint16_t m = (uint16_t)(dn < sizeof(text) - 1 ? dn : sizeof(text) - 1);
            memcpy(text, data, m);
            text[m] = '\0';
            out_line("              文本回应：%s", text);
        } else {
            out_line("              （空回应；后续异步文本会以 NOTICE 形式到达）");
        }
        if (result != RES_OK && result != RES_ACCEPTED)
            out_line("              !! result=%u(%s)：看上面文本里的 error 原因",
                     (unsigned)result, result_name(result));
        return;
    }

    if (req == CMD_SET_POSE_ZERO) {
        if (g_st.zero_expected) {
            g_st.zero_expected = 0;
            if (result == RES_OK) {
                if (dn >= 12) {
                    g_st.config = rd32(data);
                    out_line("              姿态零位完成，新 config=%u", (unsigned)rd32(data));
                }
                out_line("              下一步：/gimbal 确认 zero_valid=1，然后 /gimbalgo p y");
            } else {
                out_line("              !! 姿态零位失败 result=%u(%s)：检查两轴是否居中、F1 是否在线",
                         (unsigned)result, result_name(result));
            }
        }
        return;
    }

    if (req == CMD_MOVE_ABS || req == CMD_HOME) {
        if (result == RES_ACCEPTED && dn >= 4)
            out_line("              已接受 motion_id=%u，终态通过 EVENT 通知", (unsigned)rd32(data));
        else if (result == RES_NOT_READY)
            out_line("              !! NOT_READY：轴未 set / 未确认手动零位 / F1 未就绪");
        else if (result == RES_BUSY)
            out_line("              !! BUSY：有轴在动，或 100 ms 查询限流中");
        else if (result == RES_UNSUPPORTED)
            out_line("              !! UNSUPPORTED：F4 的 X/Y/Z 不支持 HOME；FPGA 会话无运动权");
        else if (result == RES_FAULT)
            out_line("              !! FAULT：已锁存故障，需重新 /open 并恢复（人工确认零位）");
        return;
    }

    if (dn && g_cfg.verbose) {
        char hex[400];
        dump_hex(data, dn < 100 ? dn : 100, hex, sizeof(hex));
        out_line("              data: %s", hex);
    }
}

static void print_sync(const uint8_t *p, uint16_t n)
{
    if (n < 40) { log_line("!!", "SYNC 长度 %u 不对", (unsigned)n); return; }
    uint32_t sync_id = rd32(p + 12);
    uint64_t t1 = rd64(p + 16);
    uint64_t t2 = rd64(p + 24);
    uint64_t t3 = rd64(p + 32);
    log_line("SY", "sync_id=%u t1=%llu t2=%llu t3=%llu  (t2-t1=%lld us, t3-t2=%lld us)",
             (unsigned)sync_id, U64(t1), U64(t2), U64(t3),
             (long long)(t2 - t1), (long long)(t3 - t2));
}

static void print_notice(const uint8_t *p, uint16_t n)
{
    if (n < 12) return;
    char text[300];
    uint16_t m = (uint16_t)(n - 12);
    if (m > sizeof(text) - 1) m = sizeof(text) - 1;
    memcpy(text, p + 12, m);
    text[m] = '\0';
    log_line("NT", "%s", text);
}

static void on_frame(uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n)
{
    (void)seq;
    switch (cmd) {
    case RSP_GENERIC: print_generic(p, n); break;
    case RSP_STATE:   print_state(p, n); break;
    case RSP_SYNC:    print_sync(p, n); break;
    case RSP_EVENT:   print_event(p, n); break;
    case RSP_NOTICE:  print_notice(p, n); break;
    default:
        log_line("RX", "未知回应 0x%02X 长度 %u（固件新增？升级本工具）", cmd, (unsigned)n);
        break;
    }
}

/* ------------------------------------------------------------------ */
/* 接收线程                                                            */
/* ------------------------------------------------------------------ */

static unsigned __stdcall reader_thread(void *arg)
{
    Ser *s = (Ser *)arg;
    uint8_t buf[512];
    while (!g_quit) {
        int got = ser_read(s, buf, sizeof(buf));
        if (got < 0) { out_line("!! 串口读失败，接收线程退出"); break; }
        for (int i = 0; i < got; ++i) {
            ++g_rx_bytes;
            if (g_cfg.raw) {
                if (g_rx_bytes <= 200) out_line("RAW %02X", buf[i]);
                else if (g_rx_bytes == 201) out_line("（原始字节打印已截断）");
            }
            wire_feed(&g_wire, buf[i], on_frame);
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 心跳线程                                                            */
/* ------------------------------------------------------------------ */

static unsigned __stdcall heartbeat_thread(void *arg)
{
    (void)arg;
    while (!g_quit) {
        sleep_ms(g_cfg.heartbeat_ms);
        if (g_quit) break;
        if (!g_cfg.heartbeat_on || !g_st.opened || g_cfg.mode != MODE_HOST) continue;
        req_heartbeat();
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 握手                                                                */
/* ------------------------------------------------------------------ */

static uint64_t wait_boot(uint64_t old_boot, unsigned timeout_ms)
{
    unsigned waited = 0;
    while (waited < timeout_ms) {
        if (g_st.boot && g_st.boot != old_boot) return g_st.boot;
        sleep_ms(10);
        waited += 10;
    }
    if (g_st.boot) return g_st.boot;
    return 0;
}

static int handshake(void)
{
    g_st.boot = 0;
    g_st.opened = 0;

    out_line("");
    out_line("== 握手：GET_INFO ==");
    for (unsigned attempt = 0; attempt < 3 && !g_st.boot; ++attempt) {
        req_get_info();
        if (wait_boot(0, 600)) break;
        out_line("  没有拿到 boot_id，重试（%u/3）", attempt + 1);
    }
    if (!g_st.boot) {
        out_line("");
        out_line("!! 目标板没有回应。已收到原始字节：%u", (unsigned)g_rx_bytes);
        if (g_rx_bytes == 0) {
            out_line("   一个字节都没到 —— 发送方向不通，或板子没在跑这份固件：");
            out_line("   1) 模块 TXD 必须接 F4 的 PD9(RX)，模块 RXD 接 PD8(TX)，两板必须共地；");
            out_line("   2) PD8/PD9 是不是接反了（PD8 是 F4 的 TX）；");
            out_line("   3) 确认接的是 USART3(PD8/PD9)，不是 PC6/PC7(FPGA 口) 或 PA9/PA10(F1 口)；");
            out_line("   4) 板子跑的是不是带 MCU_POSE_V2 的固件？BOOT0 是否误入下载模式；");
            out_line("   5) 3.3 V TTL 电平，CH340 模块 VCC 建议 3.3 V。");
        } else {
            out_line("   收到了字节但都成不了帧 —— 波特率或协议不匹配：");
            out_line("   1) USART3 固定 115200；若接到 PA9/PA10 或 PC6/PC7 那是 460800；");
            out_line("   2) 用 --raw 可看原始十六进制，帧头应是 55 AA 02；");
            out_line("   3) 线上干扰/电平不匹配时先缩短线长。");
        }
        out_line("");
        out_line("   排查建议：先 --raw 跑一次；若字节很多，再用 --raw --baud 460800 对比。");
        return -1;
    }
    out_line("   boot_id=%llu", U64(g_st.boot));

    uint32_t session = (uint32_t)(now_us() & 0x7FFFFFFFU);
    if (!session) session = 1;
    out_line("");
    out_line("== 握手：OPEN session=0x%08X ==", (unsigned)session);
    req_open(session);
    for (unsigned i = 0; i < 60 && !g_st.opened; ++i) sleep_ms(10);
    if (!g_st.opened) { out_line("!! OPEN 未成功"); return -1; }

    if (g_cfg.mode == MODE_HOST) {
        out_line("");
        out_line("== SET_STREAM %u Hz ==", g_cfg.rate);
        req_set_stream(g_cfg.rate);
        sleep_ms(50);
    } else {
        out_line("");
        out_line("== SET_STREAM %u Hz（FPGA 会话） ==", g_cfg.rate);
        req_set_stream(g_cfg.rate);
        sleep_ms(50);
        req_get_config();
        sleep_ms(50);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 交互命令                                                            */
/* ------------------------------------------------------------------ */

static int parse_u32(const char *s, uint32_t *out)
{
    char *end = NULL;
    if (!s || !*s) return -1;
    unsigned long v = strtoul(s, &end, 0); /* 支持 0x 前缀 */
    if (!end || *end != '\0' || v > 0xFFFFFFFFUL) return -1;
    *out = (uint32_t)v;
    return 0;
}

/* 解析 0..100 的定点数（最多 6 位小数）为 1e-6 单位 */
static int parse_coord(const char *s, int32_t *out)
{
    if (!s || !*s) return -1;
    long long whole = 0, frac = 0;
    int scale = 0;
    const char *p = s;
    while (*p >= '0' && *p <= '9') {
        whole = whole * 10 + (*p++ - '0');
        if (whole > 100) return -1;
    }
    if (*p == '.') {
        ++p;
        if (*p < '0' || *p > '9') return -1;
        while (*p >= '0' && *p <= '9') {
            if (scale >= 6) return -1;
            frac = frac * 10 + (*p++ - '0');
            ++scale;
        }
    }
    if (*p != '\0') return -1;
    while (scale < 6) { frac *= 10; ++scale; }
    long long v = whole * 1000000LL + frac;
    if (v > COORD_SCALE) return -1;
    *out = (int32_t)v;
    return 0;
}

static void help(void)
{
    out_line("");
    out_line("直接打固件原生文本命令（自动封装为 0x50 LEGACY，并自动维持心跳）：");
    out_line("  state                    当前位置（0..100 归一化坐标）");
    out_line("  measure 3 start          轴 3 从零点开始测量（10 RPM 正转）");
    out_line("  measure 3 over           结束测量，回报累计圈数（异步文本）");
    out_line("  set 3 1.234567           把行程设为该圈数（记录结果用）");
    out_line("  out 0 10                 轴 3 以 10 RPM 回到坐标 0");
    out_line("  go 5 5 10                轴 1/2 到坐标 5,5，10 RPM");
    out_line("  stop 3                   紧急停止该轴（比 over 快，不回报圈数）");
    out_line("  wake                     停止全部轴（会取消正在进行的运动）");
    out_line("");
    out_line("结构化命令（'/' 前缀）：");
    out_line("  /state            二进制 STATE（96 B，含 valid/flags/fault）");
    out_line("  /config           配置实体（看各轴 limit 是否为 0）");
    out_line("  /counters         CRC/超时/溢出计数");
    out_line("  /gimbal           云台 raw 与角度（确认 1881/2405）");
    out_line("  /confirm [mask]   人工零位确认，mask 默认 0x03");
    out_line("  /move x y [rpm]   MOVE_ABS mask=0x03，rpm 默认 10");
    out_line("  /movez z [rpm]    MOVE_ABS mask=0x04（轴 3 必须先 set）");
    out_line("  /move3 x y z [rpm] MOVE_ABS mask=0x07");
    out_line("  /home             HOME mask=0x18（仅云台；F4 的 XYZ 会返回 UNSUPPORTED）");
    out_line("  /posezero         SET_POSE_ZERO，约 5 s 后出结果");
    out_line("  /gimbalgo p y     云台相对角度定位（mdeg，±60000）");
    out_line("  /ack <id>         确认事件（防 64 条环形缓冲溢出）");
    out_line("  /sync             FPGA 专用 SYNC（host 会话会返回 UNSUPPORTED）");
    out_line("  /wait <ms>        等待（脚本化用，心跳期间不停）");
    out_line("  /stream <hz>      PC 可用 0/10/20；FPGA 可用 0/100/200");
    out_line("  /open             重新握手（换了板子/复位后用）");
    out_line("  /verbose          切换完整帧十六进制打印");
    out_line("  /help  /quit");
    out_line("");
    out_line("提示：运动期间不要停止心跳；本工具已每 300 ms 自动发送。");
    out_line("      Ctrl-C 会尝试先发 wake 停轴再退出。");
    out_line("");
}

/* 按空白切分（最多 max 段），返回段数；原地写 '\0' */
static int tokenize(char *s, char *tok[], int max)
{
    int n = 0;
    while (n < max) {
        while (*s == ' ' || *s == '\t') ++s;
        if (!*s) break;
        tok[n++] = s;
        while (*s && *s != ' ' && *s != '\t') ++s;
        if (*s) *s++ = '\0';
    }
    return n;
}

static void meta_command(char *line)
{
    char *cmd = line + 1;
    char *arg = strpbrk(cmd, " \t");
    if (arg) { *arg = '\0'; ++arg; while (*arg == ' ' || *arg == '\t') ++arg; }
    else arg = (char *)"";

    if (!strcmp(cmd, "help") || !*cmd) { help(); return; }
    if (!strcmp(cmd, "quit") || !strcmp(cmd, "exit") || !strcmp(cmd, "q")) { g_quit = 1; return; }
    if (!strcmp(cmd, "open")) { handshake(); return; }
    if (!strcmp(cmd, "verbose")) {
        g_cfg.verbose = !g_cfg.verbose;
        out_line("verbose = %s", g_cfg.verbose ? "on" : "off");
        return;
    }
    if (!strcmp(cmd, "stateall")) {
        g_cfg.state_all = !g_cfg.state_all;
        out_line("stateall = %s（每帧 STATE 都打印）", g_cfg.state_all ? "on" : "off");
        return;
    }
    if (!strcmp(cmd, "baud")) {
        uint32_t rate;
        if (parse_u32(arg, &rate) || rate < 1200 || rate > 4000000) {
            out_line("用法：/baud 460800");
            return;
        }
        mtx_lock(&g_tx_lock);
        int rc = ser_set_baud(&g_ser, rate);
        mtx_unlock(&g_tx_lock);
        out_line("端口波特率 -> %u %s", (unsigned)rate, rc ? "失败" : "OK");
        return;
    }
    /* 脚本化用：等一段时间再发下一条，心跳线程在等待期间照常工作 */
    if (!strcmp(cmd, "wait")) {
        uint32_t ms;
        if (parse_u32(arg, &ms) || ms > 120000) {
            out_line("用法：/wait <毫秒>（上限 120000）");
            return;
        }
        sleep_ms(ms);
        return;
    }
    if (!strcmp(cmd, "state")) { req_get_status(); return; }
    if (!strcmp(cmd, "config")) { req_get_config(); return; }
    if (!strcmp(cmd, "counters")) { req_get_counters(); return; }
    if (!strcmp(cmd, "gimbal")) { req_get_gimbal(); return; }

    if (!strcmp(cmd, "stream")) {
        uint32_t hz;
        if (parse_u32(arg, &hz)) { out_line("用法：/stream 10"); return; }
        if (g_cfg.mode == MODE_HOST && !(hz == 0 || hz == 10 || hz == 20)) {
            out_line("PC 链路只接受 0/10/20 Hz");
            return;
        }
        if (g_cfg.mode == MODE_FPGA && !(hz == 0 || hz == 100 || hz == 200)) {
            out_line("FPGA 链路只接受 0/100/200 Hz");
            return;
        }
        g_cfg.rate = hz;
        req_set_stream(hz);
        return;
    }
    if (!strcmp(cmd, "ack")) {
        uint32_t id;
        if (parse_u32(arg, &id) || !id) { out_line("用法：/ack <event_id>"); return; }
        req_ack(id);
        return;
    }
    if (!strcmp(cmd, "sync")) {
        if (g_cfg.mode != MODE_FPGA)
            out_line("提示：SYNC 是 FPGA 专用命令，host 会话发出去会返回 UNSUPPORTED");
        req_sync((uint32_t)(now_us() & 0xFFFFFFFFU));
        return;
    }
    if (!strcmp(cmd, "confirm")) {
        uint32_t mask = MASK_XYZ & ~MASK_Z; /* 默认 0x03 */
        if (*arg && parse_u32(arg, &mask)) { out_line("用法：/confirm 0x03"); return; }
        if (!mask || (mask & ~0x07U)) { out_line("mask 只能是 1..7"); return; }
        out_line("提示：确认前请断电把机构摆到真实零点，再上电（软件位置=0）");
        req_confirm_zero((uint8_t)mask);
        return;
    }
    if (!strcmp(cmd, "move3")) {
        char *tok[4];
        int n = tokenize(arg, tok, 4);
        if (n < 3) { out_line("用法：/move3 x y z [rpm]"); return; }
        int32_t t[3];
        for (int i = 0; i < 3; ++i) {
            if (parse_coord(tok[i], &t[i])) {
                out_line("坐标必须是 0..100，最多 6 位小数");
                return;
            }
        }
        uint32_t rpm = 10;
        if (n >= 4 && (parse_u32(tok[3], &rpm) || rpm < 1 || rpm > 60)) {
            out_line("rpm 必须是 1..60");
            return;
        }
        int32_t target[5] = { t[0], t[1], t[2], 0, 0 };
        uint16_t speeds[3] = { (uint16_t)rpm, (uint16_t)rpm, (uint16_t)rpm };
        req_move(MASK_XYZ, target, speeds);
        return;
    }
    if (!strcmp(cmd, "movez")) {
        char *tok[2];
        int n = tokenize(arg, tok, 2);
        int32_t z;
        if (n < 1 || parse_coord(tok[0], &z)) {
            out_line("用法：/movez z [rpm]，坐标 0..100");
            return;
        }
        uint32_t rpm = 10;
        if (n >= 2 && (parse_u32(tok[1], &rpm) || rpm < 1 || rpm > 60)) {
            out_line("rpm 必须是 1..60");
            return;
        }
        if (!g_st.have_state)
            out_line("提示：轴 3 未 set 时 MOVE_ABS 会返回 NOT_READY，先用 LEGACY 的 set 3 m");
        int32_t target[5] = { 0, 0, z, 0, 0 };
        uint16_t speeds[3] = { 0, 0, (uint16_t)rpm };
        req_move(MASK_Z, target, speeds);
        return;
    }
    if (!strcmp(cmd, "move")) {
        char *tok[3];
        int n = tokenize(arg, tok, 3);
        if (n < 2) { out_line("用法：/move x y [rpm]"); return; }
        int32_t x, y;
        if (parse_coord(tok[0], &x) || parse_coord(tok[1], &y)) {
            out_line("坐标必须是 0..100，最多 6 位小数");
            return;
        }
        uint32_t rpm = 10;
        if (n >= 3 && (parse_u32(tok[2], &rpm) || rpm < 1 || rpm > 60)) {
            out_line("rpm 必须是 1..60");
            return;
        }
        int32_t target[5] = { x, y, 0, 0, 0 };
        uint16_t speeds[3] = { (uint16_t)rpm, (uint16_t)rpm, 0 };
        req_move(MASK_X | MASK_Y, target, speeds);
        return;
    }
    if (!strcmp(cmd, "home")) { req_home(MASK_GIMBAL); return; }
    if (!strcmp(cmd, "posezero")) { req_pose_zero(); return; }
    if (!strcmp(cmd, "gimbalgo")) {
        char *a = arg, *b = strpbrk(a, " \t");
        if (!b) { out_line("用法：/gimbalgo <pitch_mdeg> <yaw_mdeg>"); return; }
        *b++ = '\0';
        long p = strtol(a, NULL, 10);
        long y = strtol(b, NULL, 10);
        if (p < -60000 || p > 60000 || y < -60000 || y > 60000) {
            out_line("两轴都在 ±60000 mdeg（±60°）");
            return;
        }
        int32_t target[5] = { 0, 0, 0, (int32_t)p, (int32_t)y };
        uint16_t speeds[3] = { 0, 0, 0 };
        req_move(MASK_GIMBAL, target, speeds);
        return;
    }

    if (!strcmp(cmd, "injectf1")) {
        /* 注入一帧伪造的 F1_STATE，验证 F4 的 USART2 接收通路是否真的能收字节。
         * 用法：模块 TXD 同时接到 PD9 和 PA3（一根跳线），把真实 F1 的线从 PA3 拔掉，
         * 然后 /injectf1 0x1234。若 /gimbal 立刻返回 raw=1881/2405，说明 F4 收得到。 */
        uint32_t boot;
        if (parse_u32(arg, &boot) || !boot) {
            out_line("用法：/injectf1 <boot_id，非 0，如 0x1234>");
            return;
        }
        uint8_t payload[128];
        memset(payload, 0, sizeof(payload));
        wr64(payload, boot);
        payload[12] = 0;   /* phase = IDLE */
        payload[13] = 1;   /* zero_valid */
        payload[14] = 1;   /* home_confirmed */
        payload[15] = 1;   /* angle_source */
        wr16(payload + 56, 1881);
        wr16(payload + 58, 2405);
        uint8_t frame[WIRE_MAX_FRAME];
        size_t len = wire_build(frame, 0xA1, 0, payload, 128);

        mtx_lock(&g_tx_lock);
        int rc = ser_write(&g_ser, frame, len);
        if (!rc) FlushFileBuffers(g_ser.h);   /* 等这一帧真正发完再返回，避免被后续改波特率截断 */
        mtx_unlock(&g_tx_lock);
        out_line("注入伪 F1_STATE：boot=%u, 128 B, phase=IDLE, zero_valid=1, raw=1881/2405 %s",
                 (unsigned)boot, rc ? "发送失败" : "已发送");
        if (rc) return;
        sleep_ms(15);
        out_line("立刻查询 /gimbal，看看 F4 有没有收到这一帧：");
        req_get_gimbal();
        return;
    }

    out_line("未知命令 /%s，用 /help", cmd);
}

/* ------------------------------------------------------------------ */
/* Ctrl-C：先停轴再退出                                                 */
/* ------------------------------------------------------------------ */

static BOOL WINAPI ctrl_handler(DWORD type)
{
    (void)type;
    g_quit = 1;
    if (g_st.opened) {
        uint8_t p[16 + 4];
        put_ctx(p);
        wr32(p + 12, g_st.next_motion++);
        memcpy(p + 16, "wake", 4);
        uint8_t frame[WIRE_MAX_FRAME];
        uint16_t seq = g_st.seq++;
        size_t len = wire_build(frame, CMD_LEGACY, seq, p, 20);
        mtx_lock(&g_tx_lock);
        ser_write(&g_ser, frame, len);
        mtx_unlock(&g_tx_lock);
        fputs("\n[中断] 已发送 wake 尝试停止全部轴\n", stdout);
        fflush(stdout);
    }
    ExitProcess(0);
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* 自检                                                                */
/* ------------------------------------------------------------------ */

typedef struct { int calls; uint8_t cmd; uint16_t seq; uint16_t n; uint8_t payload[64]; } Cap;
static Cap g_cap;

static void cap_cb(uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n)
{
    ++g_cap.calls;
    g_cap.cmd = cmd;
    g_cap.seq = seq;
    g_cap.n = n;
    if (n <= sizeof(g_cap.payload)) memcpy(g_cap.payload, p, n);
}

static int failures;

static void check(int cond, const char *what)
{
    if (cond) {
        printf("  PASS  %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        ++failures;
    }
}

static int selftest(void)
{
    printf("== f4_host 自检（不需要硬件）==\n");

    /* 1. CRC 标准校验值：CRC-16/CCITT-FALSE("123456789") = 0x29B1 */
    printf("\n[1] CRC-16/CCITT-FALSE\n");
    const uint8_t vec[] = { '1','2','3','4','5','6','7','8','9' };
    uint16_t c = crc16(vec, 9);
    printf("      crc16(\"123456789\") = 0x%04X\n", c);
    check(c == 0x29B1, "标准校验值 0x29B1");

    /* 2. 帧构造/解析往返 */
    printf("\n[2] 帧往返\n");
    uint8_t frame[WIRE_MAX_FRAME];
    uint8_t payload[32];
    memset(payload, 0, sizeof(payload));
    wr64(payload, 0x1122334455667788ULL);
    wr32(payload + 8, 0xAABBCCDDUL);
    size_t len = wire_build(frame, CMD_HEARTBEAT, 0x1234, payload, 12);
    printf("      HEARTBEAT 帧长 %zu：", len);
    for (size_t i = 0; i < len; ++i) printf("%02X ", frame[i]);
    printf("\n");
    check(len == 22, "长度 = 12+10 = 22");

    Wire w;
    memset(&w, 0, sizeof(w));
    memset(&g_cap, 0, sizeof(g_cap));
    for (size_t i = 0; i < len; ++i) wire_feed(&w, frame[i], cap_cb);
    check(g_cap.calls == 1, "回调被调用一次");
    check(g_cap.cmd == CMD_HEARTBEAT, "cmd 正确");
    check(g_cap.seq == 0x1234, "seq 正确");
    check(g_cap.n == 12, "长度正确");
    check(rd64(g_cap.payload) == 0x1122334455667788ULL, "boot 字段正确");
    check(rd32(g_cap.payload + 8) == 0xAABBCCDDUL, "session 字段正确");

    /* 3. 分片喂入 */
    printf("\n[3] 分片喂入\n");
    memset(&w, 0, sizeof(w));
    memset(&g_cap, 0, sizeof(g_cap));
    for (size_t i = 0; i < len; ++i) wire_feed(&w, frame[i], cap_cb);
    check(g_cap.calls == 1, "整帧喂完只回调一次");

    memset(&w, 0, sizeof(w));
    memset(&g_cap, 0, sizeof(g_cap));
    for (size_t i = 0; i + 1 < len; ++i) wire_feed(&w, frame[i], cap_cb);
    check(g_cap.calls == 0, "少最后一个字节时不回调");
    wire_feed(&w, frame[len - 1], cap_cb);
    check(g_cap.calls == 1, "补齐最后一个字节后回调");

    /* 4. 前导垃圾 + 坏 CRC */
    printf("\n[4] 抗噪\n");
    memset(&w, 0, sizeof(w));
    memset(&g_cap, 0, sizeof(g_cap));
    const uint8_t junk[] = { 0x00, 0x55, 0x00, 0xFF, 0x55, 0xAA, 0x09 };
    for (size_t i = 0; i < sizeof(junk); ++i) wire_feed(&w, junk[i], cap_cb);
    for (size_t i = 0; i < len; ++i) wire_feed(&w, frame[i], cap_cb);
    check(g_cap.calls == 1, "skipped 垃圾后仍解析出好帧");

    memset(&w, 0, sizeof(w));
    frame[len - 1] ^= 0xFF;
    for (size_t i = 0; i < len; ++i) wire_feed(&w, frame[i], cap_cb);
    check(w.crc_errors > 0, "坏 CRC 被计数并丢弃");
    frame[len - 1] ^= 0xFF;

    /* 5. 回应解码 */
    printf("\n[5] 回应解码\n");
    uint8_t resp[16 + 8];
    memset(resp, 0, sizeof(resp));
    wr64(resp, 0xABCDEF0123456789ULL);
    wr32(resp + 8, 0x0000002AUL);
    resp[12] = CMD_OPEN;
    resp[13] = RES_OK;
    wr32(resp + 16, 7);   /* config */
    wr32(resp + 20, 99);  /* last_motion */
    len = wire_build(frame, RSP_GENERIC, 5, resp, (uint16_t)sizeof(resp));
    memset(&w, 0, sizeof(w));
    memset(&g_cap, 0, sizeof(g_cap));
    for (size_t i = 0; i < len; ++i) wire_feed(&w, frame[i], cap_cb);
    check(g_cap.calls == 1 && g_cap.cmd == RSP_GENERIC, "通用回应的 cmd 字节正确");
    check(rd64(g_cap.payload) == 0xABCDEF0123456789ULL, "回应头 boot 正确");
    check(rd32(g_cap.payload + 8) == 0x2A, "回应头 session 正确");
    check(g_cap.payload[12] == CMD_OPEN && g_cap.payload[13] == RES_OK,
          "request_cmd/result 位置正确");

    /* 6. 坐标解析/格式化 */
    printf("\n[6] 坐标定点转换\n");
    int32_t v;
    check(parse_coord("0", &v) == 0 && v == 0, "0 -> 0");
    check(parse_coord("100", &v) == 0 && v == COORD_SCALE, "100 -> 1e8");
    check(parse_coord("5.69625", &v) == 0 && v == 5696250, "5.69625 -> 5696250");
    check(parse_coord("100.000001", &v) != 0, "超 100 被拒");
    check(parse_coord("-1", &v) != 0, "负坐标被拒");
    check(parse_coord("1.2345678", &v) != 0, "超 6 位小数被拒");
    char buf[32];
    fmt_coord(5696250, buf, sizeof(buf));
    check(!strcmp(buf, "5.696250"), "格式化 5696250 -> 5.696250");
    fmt_coord(-1234567, buf, sizeof(buf));
    check(!strcmp(buf, "-1.234567"), "负值格式化");

    /* 7. LEGACY 文本限制 */
    printf("\n[7] LEGACY 文本约束（与 f4_link.c 的判定一致）\n");
    check(legacy_validate("measure 3 start", 15) == 0, "合法命令通过");
    char big[120];
    memset(big, 'a', sizeof(big));
    check(legacy_validate(big, 95) == 0, "95 字节通过");
    check(legacy_validate(big, 96) != 0, "96 字节被拒（固件也判 BAD_LENGTH）");
    check(legacy_validate("a\tb", 3) != 0, "TAB 被拒");
    check(legacy_validate("a\r\nb", 4) != 0, "CR/LF 被拒");
    check(legacy_validate("", 0) != 0, "空文本被拒");

    /* 8. 打印一个可直接粘进串口助手的样本帧 */
    printf("\n[8] 样本：LEGACY \"measure 3 start\"（boot=1, session=1, id=1）\n");
    uint8_t lp[16 + 15];
    memset(lp, 0, sizeof(lp));
    wr64(lp, 1);
    wr32(lp + 8, 1);
    wr32(lp + 12, 1);
    memcpy(lp + 16, "measure 3 start", 15);
    len = wire_build(frame, CMD_LEGACY, 1, lp, (uint16_t)(16 + 15));
    printf("      ");
    for (size_t i = 0; i < len; ++i) printf("%02X ", frame[i]);
    printf("\n      注：boot/session 是运行时值，不能照抄；仅用于核对 CRC 算法。\n");

    /* 9. OPEN 回应必须把 session 写回全局状态（回归：曾经漏掉导致全部 BAD_CONTEXT） */
    printf("\n[9] OPEN 会话回填（走真实 on_frame 路径）\n");
    out_init();
    g_st.boot = 0; g_st.session = 0; g_st.opened = 0; g_st.next_motion = 1;
    uint8_t openr[16 + 8];
    memset(openr, 0, sizeof(openr));
    wr64(openr, 0x1122334455667788ULL);
    wr32(openr + 8, 0xDEADBEEFUL);
    openr[12] = CMD_OPEN;
    openr[13] = RES_OK;
    wr32(openr + 16, 9);   /* config */
    wr32(openr + 20, 77);  /* last_motion */
    len = wire_build(frame, RSP_GENERIC, 1, openr, (uint16_t)sizeof(openr));
    memset(&w, 0, sizeof(w));
    for (size_t i = 0; i < len; ++i) wire_feed(&w, frame[i], on_frame);
    check(g_st.session == 0xDEADBEEFUL, "session 写回（否则后续全 BAD_CONTEXT）");
    check(g_st.opened == 1, "opened = 1");
    check(g_st.boot == 0x1122334455667788ULL, "boot_id 写回");
    check(g_st.next_motion == 78, "next_motion = latest_motion + 1");

    printf("\n== 结果：%s（%d 项失败）==\n", failures ? "失败" : "全部通过", failures);
    return failures ? 1 : 0;
}

/* ------------------------------------------------------------------ */
/* 回环自检：把模块 TXD 与 RXD 短接，验证"电平/驱动/线材"这一段           */
/* ------------------------------------------------------------------ */

static int loopback_test(void)
{
    printf("\n== 回环自检 ==\n");
    printf("   请把 USB-TTL 模块的 TXD 与 RXD 直接短接（先拔掉通往 F4 的线）\n\n");

    uint8_t payload[12];
    for (unsigned i = 0; i < 12; ++i) payload[i] = (uint8_t)(0xA0 + i);
    uint8_t frame[WIRE_MAX_FRAME];
    size_t len = wire_build(frame, CMD_HEARTBEAT, 0x5A5A, payload, 12);
    printf("   发送探针帧 %zu 字节 ×3：%02X %02X %02X ...\n", len, frame[0], frame[1], frame[2]);

    uint8_t rx[512];
    size_t rxn = 0;

    /* 清空可能残留的字节 */
    { uint8_t tmp[128]; while (ser_read(&g_ser, tmp, sizeof(tmp)) > 0) {} }

    for (unsigned round = 0; round < 3; ++round) {
        if (ser_write(&g_ser, frame, len)) { printf("   !! 写串口失败\n"); return 1; }
        uint64_t t0 = now_us();
        while (now_us() - t0 < 250000ULL) {
            uint8_t buf[128];
            int got = ser_read(&g_ser, buf, sizeof(buf));
            if (got > 0) {
                for (int i = 0; i < got && rxn < sizeof(rx); ++i) rx[rxn++] = buf[i];
            } else {
                sleep_ms(5);
            }
        }
    }

    printf("   收到 %zu 字节\n", rxn);
    if (rxn == 0) {
        printf("\nFAIL：短接后一个字节都没回来。可能原因：\n");
        printf("   1) TXD/RXD 没有真正短接（杜邦线没插到底、插错排针）；\n");
        printf("   2) 模块供电/驱动异常；\n");
        printf("   3) 模块只有 TX 或只有 RX 坏了。\n");
        return 1;
    }
    if (rxn != len * 3) {
        printf("\nFAIL：字节数不符（期望 %zu）。多半是接触不良或线太长。\n", len * 3);
        return 1;
    }
    for (size_t i = 0; i < rxn; ++i) {
        if (rx[i] != frame[i % len]) {
            printf("\nFAIL：第 %zu 字节被改写（%02X != %02X），存在干扰或电平问题。\n",
                   i, rx[i], frame[i % len]);
            return 1;
        }
    }
    printf("\nPASS：模块收发与电平都正常。问题在 F4 那一侧（接线/引脚/固件/供电）。\n");
    return 0;
}

static void listen_cb(uint8_t cmd, uint16_t seq, const uint8_t *p, uint16_t n)
{
    /* 只看前几帧，避免 133 Hz 刷屏 */
    static unsigned shown;
    ++g_listen_frames;
    if (shown >= 6) return;
    ++shown;
    unsigned long long boot = (n >= 8) ? U64(rd64(p)) : 0ULL;
    printf("   FRAME cmd=0x%02X seq=%-5u len=%-3u boot=%llu%s\n",
           cmd, (unsigned)seq, (unsigned)n, boot,
           (n >= 8 && boot == 0) ? "   <-- boot=0，F4 会整帧丢弃" : "");
    if (n >= 8) {
        printf("         payload[0..7] =");
        for (unsigned i = 0; i < 8; ++i) printf(" %02X", p[i]);
        printf("\n");
    }
}

/* ------------------------------------------------------------------ */
/* 只监听：不发任何字节，只报告对端在线上说了什么                        */
/* ------------------------------------------------------------------ */

static int listen_only(unsigned ms)
{
    printf("\n== 只监听 %u ms（本工具不发送任何数据）==\n", ms);
    unsigned long total = 0;
    int found_frame = 0;
    unsigned prev1 = 0, prev2 = 0;
    uint8_t line[16];
    unsigned in_line = 0;
    uint64_t t0 = now_us();
    Wire w;
    wire_reset(&w);
    unsigned frames = 0;

    while (now_us() - t0 < (uint64_t)ms * 1000ULL) {
        uint8_t buf[256];
        int got = ser_read(&g_ser, buf, sizeof(buf));
        if (got <= 0) { sleep_ms(5); continue; }
        for (int i = 0; i < got; ++i) {
            uint8_t b = buf[i];
            ++total;
            if (prev1 == 0x55 && prev2 == 0xAA && b == 0x02) found_frame = 1;
            prev1 = prev2;
            prev2 = b;
            line[in_line++] = b;
            if (in_line == 16) { in_line = 0; }
            wire_feed(&w, b, listen_cb);
        }
        if (in_line == 0) {
            printf("   ");
            for (unsigned k = 0; k < 16; ++k) printf(" %02X", line[k]);
            printf("\n");
        }
    }
    if (in_line) {
        printf("   ");
        for (unsigned k = 0; k < in_line; ++k) printf(" %02X", line[k]);
        printf("\n");
    }
    frames = g_listen_frames;

    printf("\n   共收到 %lu 字节，解码 %u 帧，CRC 错 %u，长度错 %u\n",
           total, frames, (unsigned)w.crc_errors, (unsigned)w.length_errors);
    if (total == 0) {
        printf("   对端一个字都没发。这个测试点本身没有流量，或对端没在跑。\n");
        return 1;
    }
    if (found_frame)
        printf("   PASS：检测到 55 AA 02 帧头 —— 对端在发版本 2 帧，电平/波特率/共地都对。\n");
    else
        printf("   有字节但没看到 55 AA 02 帧头 —— 波特率不匹配或线上有干扰。\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* 纯文本抓取：只收不发，把收到的字节按文本打印                          */
/* ------------------------------------------------------------------ */

static int capture_mode(unsigned ms)
{
    printf("\n== 抓取 %u ms（只收不发）==\n", ms);
    uint8_t buf[512];
    unsigned total = 0;
    uint64_t t0 = now_us();
    while (now_us() - t0 < (uint64_t)ms * 1000ULL) {
        int got = ser_read(&g_ser, buf, sizeof(buf));
        if (got > 0) {
            for (int i = 0; i < got; ++i) {
                uint8_t c = buf[i];
                if (c == '\n') { putchar('\n'); }
                else if (c != '\r') { putchar((c >= 32 && c < 127) ? c : '.'); }
            }
            fflush(stdout);
            total += (unsigned)got;
        } else {
            sleep_ms(5);
        }
    }
    printf("\n共收到 %u 字节\n", total);
    if (!total) printf("==> 没有任何数据\n");
    return total ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* 原始串口终端：不做任何协议，用于最小回环测试                          */
/* ------------------------------------------------------------------ */

static int terminal_mode(void)
{
    printf("\n== 原始串口终端（无协议）==\n");
    printf("   输入字符即发送，收到的字节原样回显。回车发送 CRLF，ESC 退出。\n");
    printf("   用途：F4/F1 烧入纯回环固件后，打 Hello World 应能原样回来。\n\n");

    uint8_t buf[256];
    while (ser_read(&g_ser, buf, sizeof(buf)) > 0) { }

    for (;;) {
        int got = ser_read(&g_ser, buf, sizeof(buf));
        while (got > 0) {
            fwrite(buf, 1, (size_t)got, stdout);
            fflush(stdout);
            got = ser_read(&g_ser, buf, sizeof(buf));
        }
        while (_kbhit()) {
            int c = _getch();
            if (c == 27) { printf("\n[ESC] 退出终端\n"); return 0; }
            if (c == '\r') {
                uint8_t crlf[2] = { '\r', '\n' };
                putchar('\n');
                fflush(stdout);
                ser_write(&g_ser, crlf, 2);
            } else if (c == 8 || c == 127) {
                uint8_t bs = 8;
                printf("\b \b");
                fflush(stdout);
                ser_write(&g_ser, &bs, 1);
            } else {
                uint8_t ch = (uint8_t)c;
                putchar(c);
                fflush(stdout);
                ser_write(&g_ser, &ch, 1);
            }
        }
        sleep_ms(3);
    }
}

/* ------------------------------------------------------------------ */
/* 回环探测：发送一段文本并统计回显，不需要人工敲键                       */
/* ------------------------------------------------------------------ */

static int echo_probe(const char *text)
{
    uint8_t buf[256];
    while (ser_read(&g_ser, buf, sizeof(buf)) > 0) { }

    if (ser_write(&g_ser, (const uint8_t *)text, strlen(text)) ||
        ser_write(&g_ser, (const uint8_t *)"\r\n", 2)) {
        printf("写串口失败\n");
        return 1;
    }
    printf("\n发送 %zu 字节: \"%s\" + CRLF\n", strlen(text) + 2, text);

    unsigned total = 0;
    uint64_t t0 = now_us();
    while (now_us() - t0 < 1500000ULL) {
        int got = ser_read(&g_ser, buf, sizeof(buf));
        if (got > 0) {
            printf("  收到 %d 字节:", got);
            for (int i = 0; i < got; ++i) printf(" %02X", buf[i]);
            printf("  |");
            for (int i = 0; i < got; ++i) {
                uint8_t c = buf[i];
                putchar((c >= 32 && c < 127) ? c : '.');
            }
            printf("|\n");
            total += (unsigned)got;
        } else {
            sleep_ms(5);
        }
    }
    printf("\n合计回显 %u 字节\n", total);
    if (total == 0) printf("==> 没有任何回显：链路不通，或固件没在跑\n");
    else printf("==> 有回显：F1<->F4 双向链路是通的\n");
    return total ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

static void usage(void)
{
    printf("用法：\n");
    printf("  f4_host.exe --port COM5 [--baud 115200] [--mode host|fpga]\n");
    printf("              [--rate 10] [--heartbeat 300] [--no-heartbeat]\n");
    printf("              [--log f4.log] [--verbose] [--raw]\n");
    printf("  f4_host.exe --selftest\n");
    printf("  f4_host.exe --port COM8 --loopback      （短接模块 TXD/RXD 后跑，验证模块）\n");
    printf("  f4_host.exe --port COM8 --listen 3000 --baud 460800 （只监听不发送）\n");
    printf("\n");
    printf("  --port       PC 侧 USART3 的 COM 口（F4 的 PD8/PD9），115200 8N1\n");
    printf("  --mode host  运动控制（默认）；fpga = 只读会话，接 PC6/PC7 460800\n");
    printf("  --rate       状态流频率；host 用 10，fpga 用 200\n");
    printf("  --heartbeat  心跳周期 ms（默认 300，必须 < 1000，否则租约超时停轴）\n");
}

int main(int argc, char **argv)
{
    g_cfg.baud = 115200;
    g_cfg.mode = MODE_HOST;
    g_cfg.rate = 10;
    g_cfg.heartbeat_ms = 300;
    g_cfg.heartbeat_on = 1;
    g_st.seq = 1;
    g_st.next_motion = 1;

    if (argc > 1 && !strcmp(argv[1], "--selftest")) return selftest();
    if (argc > 1 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) { usage(); return 0; }

    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!strcmp(a, "--port") && v) { snprintf(g_cfg.port, sizeof(g_cfg.port), "%s", v); ++i; }
        else if (!strcmp(a, "--baud") && v) { g_cfg.baud = (unsigned)strtoul(v, NULL, 10); ++i; }
        else if (!strcmp(a, "--mode") && v) {
            if (!strcmp(v, "fpga")) { g_cfg.mode = MODE_FPGA; g_cfg.rate = 200; g_cfg.baud = 460800; }
            else g_cfg.mode = MODE_HOST;
            ++i;
        }
        else if (!strcmp(a, "--rate") && v) { g_cfg.rate = (unsigned)strtoul(v, NULL, 10); ++i; }
        else if (!strcmp(a, "--heartbeat") && v) { g_cfg.heartbeat_ms = (unsigned)strtoul(v, NULL, 10); ++i; }
        else if (!strcmp(a, "--no-heartbeat")) g_cfg.heartbeat_on = 0;
        else if (!strcmp(a, "--log") && v) {
            g_cfg.log = fopen(v, "ab");
            if (!g_cfg.log) fprintf(stderr, "无法打开日志 %s\n", v);
            ++i;
        }
        else if (!strcmp(a, "--verbose")) g_cfg.verbose = 1;
        else if (!strcmp(a, "--raw")) g_cfg.raw = 1;
        else if (!strcmp(a, "--loopback")) g_cfg.loopback = 1;
        else if (!strcmp(a, "--terminal")) g_cfg.terminal = 1;
        else if (!strcmp(a, "--echo") && v) {
            snprintf(g_cfg.echo_text, sizeof(g_cfg.echo_text), "%s", v);
            ++i;
        }
        else if (!strcmp(a, "--capture") && v) { g_cfg.capture_ms = (unsigned)strtoul(v, NULL, 10); ++i; }
        else if (!strcmp(a, "--listen") && v) { g_cfg.listen_ms = (unsigned)strtoul(v, NULL, 10); ++i; }
        else { fprintf(stderr, "未知参数 %s\n", a); usage(); return 2; }
    }

    if (!g_cfg.port[0]) { fprintf(stderr, "必须指定 --port COMx\n"); usage(); return 2; }
    if (g_cfg.heartbeat_ms >= 1000)
        fprintf(stderr, "警告：心跳 %u ms ≥ 1000 ms，运动中会被租约看门狗停掉\n", g_cfg.heartbeat_ms);

    SetConsoleOutputCP(65001);
    if (g_cfg.mode == MODE_FPGA && g_cfg.baud == 115200)
        g_cfg.baud = 460800;

    if (ser_open(&g_ser, g_cfg.port, g_cfg.baud)) return 1;

    if (g_cfg.capture_ms) {
        int rc = capture_mode(g_cfg.capture_ms);
        ser_close(&g_ser);
        return rc;
    }

    if (g_cfg.terminal) {
        int rc = terminal_mode();
        ser_close(&g_ser);
        return rc;
    }

    if (g_cfg.echo_text[0]) {
        int rc = echo_probe(g_cfg.echo_text);
        ser_close(&g_ser);
        return rc;
    }

    if (g_cfg.loopback) {
        int rc = loopback_test();
        ser_close(&g_ser);
        return rc;
    }

    if (g_cfg.listen_ms) {
        int rc = listen_only(g_cfg.listen_ms);
        ser_close(&g_ser);
        return rc;
    }

    mtx_init(&g_tx_lock);
    out_init();
    wire_reset(&g_wire);
    g_st.t0 = now_us();

    out_line("");
    out_line("F4 龙门架 PC 工具  port=%s baud=%u mode=%s rate=%uHz heartbeat=%s%ums",
             g_cfg.port, g_cfg.baud, g_cfg.mode == MODE_FPGA ? "fpga" : "host",
             g_cfg.rate, g_cfg.heartbeat_on ? "" : "off ", g_cfg.heartbeat_ms);

    SetConsoleCtrlHandler(ctrl_handler, TRUE);

    Thread rd = thread_start(reader_thread, &g_ser);
    if (!rd) { out_line("!! 无法创建接收线程"); return 1; }
    Thread hb = NULL;
    if (g_cfg.heartbeat_on) hb = thread_start(heartbeat_thread, NULL);

    int rc = 0;
    if (handshake()) {
        out_line("握手失败，仍进入控制台（可用 /open 重试）");
        rc = 0;
    }

    out_line("输入 /help 看命令；直接打 measure/set/out/go/state/stop 就是固件原生文本命令。");
    out_line("");

    char line[256];
    for (;;) {
        printf("f4> ");
        fflush(stdout);
        if (!fgets(line, sizeof(line), stdin)) break;

        size_t len = strlen(line);
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = '\0';
        if (!len) continue;

        if (!strcmp(line, "quit") || !strcmp(line, "exit")) break;
        if (line[0] == '/') { meta_command(line); continue; }
        if (!strcmp(line, "help")) { help(); continue; }

        if (!g_st.opened) {
            out_line("!! 会话未建立，先 /open");
            continue;
        }
        req_legacy(line);
    }

    /* 退出前停轴，避免人走轴还在动 */
    if (g_st.opened) {
        out_line("");
        out_line("退出：发送 wake 停止全部轴");
        req_legacy("wake");
        sleep_ms(300);
    }
    g_quit = 1;
    if (hb) WaitForSingleObject(hb, 1500);
    WaitForSingleObject(rd, 1500);
    ser_close(&g_ser);
    if (g_cfg.log) fclose(g_cfg.log);
    out_line("bye");
    return rc;
}
