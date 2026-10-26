/*
 * f1_proxy.c - minimal F4 proxy for the F1 gimbal controller.
 *
 * Speaks the F4<->F1 internal frame protocol on USART1 (460800 8N1) and turns
 * it into an interactive text shell:
 *
 *     f1_proxy.exe COM7          interactive
 *     f1_proxy.exe --selftest    frame codec check, no port needed
 *
 * Frame:  55 AA | ver=2 | cmd | seq:u16 | len:u16 | payload | crc16
 * CRC:    CRC-16/CCITT-FALSE (0x1021, init 0xFFFF) over [ver .. payload]
 * Commands handled: 0x20 INFO, 0x21 READY, 0x22 GO, 0x24 ZERO
 * Answers handled:  0xA0 REPLY (boot8 + cmd + result + 2 pad = 12B)
 *                   0xA1 STATE (128B)
 *
 * This is a bench tool, not the real F4: no sessions, motion_id, events or
 * five-axis gantry. It exists so the F1 driver can be exercised with a USB-TTL
 * adapter while the F4/FPGA side is still under development.
 *
 * Build: gcc -std=c11 -O2 -Wall -Wextra -o f1_proxy.exe f1_proxy.c -lm
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <math.h>

#define PROTO_VER      2
#define CMD_INFO       0x20
#define CMD_READY      0x21
#define CMD_GO         0x22
#define CMD_ZERO       0x24
#define CMD_REPLY      0xA0
#define CMD_STATE      0xA1
#define MAX_PAYLOAD    1024
#define STATE_BYTES    128
/* The real F4 sends INFO as a keepalive every 200 ms while the link is up. */
#define HEARTBEAT_MS   200

/* ------------------------------------------------------------------ codec */

static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t get32(const uint8_t *p) { return (uint32_t)get16(p) | ((uint32_t)get16(p + 2) << 16); }
static int32_t  geti32(const uint8_t *p) { return (int32_t)get32(p); }
static uint64_t get64(const uint8_t *p) { return (uint64_t)get32(p) | ((uint64_t)get32(p + 4) << 32); }
static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, (uint16_t)v); put16(p + 2, (uint16_t)(v >> 16)); }
static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)v); put32(p + 4, (uint32_t)(v >> 32)); }

static uint16_t crc16(const uint8_t *p, size_t n)
{
    uint16_t crc = 0xFFFF;
    while (n--) {
        crc ^= (uint16_t)(*p++) << 8;
        for (unsigned i = 0; i < 8; i++)
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

static size_t build_frame(uint8_t *out, uint8_t cmd, uint16_t seq,
                          const uint8_t *payload, uint16_t n)
{
    if (n > MAX_PAYLOAD) return 0;
    out[0] = 0x55; out[1] = 0xAA; out[2] = PROTO_VER; out[3] = cmd;
    put16(out + 4, seq); put16(out + 6, n);
    if (n) memcpy(out + 8, payload, n);
    put16(out + 8 + n, crc16(out + 2, (size_t)6 + n));
    return (size_t)n + 10u;
}

/* ------------------------------------------------------------------ state */

typedef struct {
    uint64_t boot;
    uint32_t seq;
    uint8_t  phase, zero, home, src, sensor;
    uint64_t imu_us, servo_us[2];
    int32_t  angle[2], servo[2];
    uint16_t raw[2];
    uint32_t i2c_err, missed;

} State;

static void decode_state(const uint8_t *p, State *s)
{
    memset(s, 0, sizeof *s);
    s->boot     = get64(p);
    s->seq      = get32(p + 8);
    s->phase    = p[12];
    s->zero     = p[13];
    s->home     = p[14];
    s->src      = p[15];
    s->imu_us   = get64(p + 16);
    s->servo_us[0] = get64(p + 24);
    s->servo_us[1] = get64(p + 32);
    s->angle[0] = geti32(p + 40);
    s->angle[1] = geti32(p + 44);
    s->servo[0] = geti32(p + 48);
    s->servo[1] = geti32(p + 52);
    s->raw[0]   = get16(p + 56);
    s->raw[1]   = get16(p + 58);
    s->sensor   = p[90];
    s->i2c_err  = get32(p + 92);
    s->missed   = get32(p + 96);

}

static const char *phase_name(unsigned p)
{
    switch (p) {
    case 0: return "idle";
    case 1: return "move";
    case 2: return "homing";
    case 5: return "failed";
    default: return "?";
    }
}

static const char *result_name(int r)
{
    switch (r) {
    case 0:  return "OK";
    case 1:  return "ACCEPTED";
    case 2:  return "BUSY";
    case 3:  return "BAD_LENGTH";
    case 5:  return "BAD_BOOT";
    case 6:  return "BAD_CMD";
    case 7:  return "NOT_READY";
    case 8:  return "CONFLICT";
    case 9:  return "FAULT";
    case 10: return "STALE";
    default: return "?";
    }
}

static const char *cmd_name(unsigned c)
{
    switch (c) {
    case CMD_INFO:  return "INFO";
    case CMD_READY: return "READY";
    case CMD_GO:    return "GO";
    case CMD_ZERO:  return "ZERO";
    default:        return "?";
    }
}

/* ------------------------------------------------------------------ shared */

static CRITICAL_SECTION g_out, g_lock, g_write;
static HANDLE   g_port;
static volatile LONG g_quit, g_mon;
static volatile LONG g_ack_gen;
static volatile LONG g_rx_bytes, g_frames, g_crc_err;
static int      g_ack_cmd = -1, g_ack_result = -1;
static uint64_t g_boot, g_ack_boot;
static State    g_state;
static int      g_have_state;
static uint16_t g_seq;
static DWORD    g_t0;

static void seq_load(void);
static void seq_save(void);

static void say(const char *fmt, ...)
{
    va_list ap;
    EnterCriticalSection(&g_out);
    printf("[%7.3fs] ", (double)(GetTickCount() - g_t0) / 1000.0);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
    LeaveCriticalSection(&g_out);
}

static int write_all(const uint8_t *buf, size_t n)
{
    DWORD wrote = 0, total = 0;
    int ok = 1;
    EnterCriticalSection(&g_write);
    while (total < n) {
        if (!WriteFile(g_port, buf + total, (DWORD)(n - total), &wrote, NULL) || wrote == 0) {
            ok = 0;
            break;
        }
        total += wrote;
    }
    FlushFileBuffers(g_port);
    LeaveCriticalSection(&g_write);
    return ok;
}

static uint16_t next_seq(void)
{
    if (++g_seq == 0) g_seq = 1;
    return g_seq;
}

static int send_cmd(uint8_t cmd, const uint8_t *payload, uint16_t n, uint16_t seq, int quiet)
{
    uint8_t frame[16 + MAX_PAYLOAD];
    size_t len = build_frame(frame, cmd, seq, payload, n);
    int ok;

    if (!len) return 0;
    if (!quiet) say("-> %-5s seq=%u %uB\n", cmd_name(cmd), seq, (unsigned)len);
    ok = write_all(frame, len);
    if (ok && seq) seq_save();
    return ok;
}

static void send_info(uint16_t seq) { send_cmd(CMD_INFO, NULL, 0, seq, 1); }

/* ------------------------------------------------------------------ reader */

static void on_reply(const uint8_t *p, uint16_t n)
{
    if (n < 10) return;
    uint64_t boot = get64(p);
    uint8_t  rcmd = p[8];
    int      res  = p[9];

    EnterCriticalSection(&g_lock);
    g_ack_boot = boot;
    if (rcmd != CMD_INFO) {
        g_ack_cmd = rcmd;
        g_ack_result = res;
        InterlockedIncrement(&g_ack_gen);
    }
    LeaveCriticalSection(&g_lock);

    if (rcmd != CMD_INFO)
        say("[ACK]   %-5s result=%-10s(%d)  boot=0x%llX\n",
            cmd_name(rcmd), result_name(res), res, (unsigned long long)boot);
}

static void on_state(const uint8_t *p, uint16_t n)
{
    static int last_phase = -1, last_zero = -1, last_home = -1;
    static DWORD last_print;
    State s;

    if (n < STATE_BYTES) return;
    decode_state(p, &s);

    EnterCriticalSection(&g_lock);
    g_state = s;
    g_have_state = 1;
    LeaveCriticalSection(&g_lock);

    int changed = (s.phase != last_phase) || (s.zero != last_zero) || (s.home != last_home);
    DWORD now = GetTickCount();
    if (!changed && (!g_mon || (DWORD)(now - last_print) < 200)) return;
    last_phase = s.phase; last_zero = s.zero; last_home = s.home;
    last_print = now;

    say("[STATE] phase=%-7s zero=%d home=%d src=%d | "
        "pitch raw=%-4u ang=%+8.3f deg | yaw raw=%-4u ang=%+8.3f deg\n",
        phase_name(s.phase), s.zero, s.home, s.src,
        s.raw[0], (double)s.angle[0] / 1000.0,
        s.raw[1], (double)s.angle[1] / 1000.0);
}

static void feed(uint8_t *acc, size_t cap, size_t *used, const uint8_t *in, size_t n)
{
    size_t i;
    InterlockedExchangeAdd(&g_rx_bytes, (LONG)n);
    for (i = 0; i < n; i++) {
        if (*used >= cap) break;
        acc[(*used)++] = in[i];
    }

    while (*used >= 2) {
        if (!(acc[0] == 0x55 && acc[1] == 0xAA)) {
            memmove(acc, acc + 1, --(*used));
            continue;
        }
        if (*used < 8) return;
        if (acc[2] != PROTO_VER) { memmove(acc, acc + 1, --(*used)); continue; }
        uint16_t plen = get16(acc + 6);
        if (plen > MAX_PAYLOAD) { memmove(acc, acc + 1, --(*used)); continue; }
        if (*used < (size_t)plen + 10u) return;
        if (get16(acc + 8 + plen) != crc16(acc + 2, (size_t)6 + plen)) {
            InterlockedIncrement(&g_crc_err);
            memmove(acc, acc + 1, --(*used));
            continue;
        }
        InterlockedIncrement(&g_frames);
        uint8_t cmd = acc[3];
        if (cmd == CMD_REPLY)      on_reply(acc + 8, plen);
        else if (cmd == CMD_STATE)  on_state(acc + 8, plen);
        memmove(acc, acc + plen + 10u, *used - (size_t)plen - 10u);
        *used -= (size_t)plen + 10u;
    }
}

static DWORD WINAPI reader(LPVOID arg)
{
    static uint8_t acc[4096];
    size_t used = 0;
    uint8_t buf[1024];
    DWORD last_ping = 0;

    (void)arg;
    while (!g_quit) {
        DWORD now = GetTickCount();
        DWORD got = 0;

        /* INFO doubles as the 1 s motion lease heartbeat for the F1 side. */
        if ((DWORD)(now - last_ping) >= HEARTBEAT_MS) {
            last_ping = now;
            send_info(0);
        }
        if (ReadFile(g_port, buf, sizeof buf, &got, NULL) && got)
            feed(acc, sizeof acc, &used, buf, got);
        Sleep(1);
    }
    return 0;
}

/* ------------------------------------------------------------------ waits */

static int wait_ack(uint8_t want, int timeout_ms, int *result, uint64_t *boot)
{
    LONG start;
    DWORD t0 = GetTickCount();

    EnterCriticalSection(&g_lock);
    start = g_ack_gen;
    LeaveCriticalSection(&g_lock);

    for (;;) {
        LONG gen;
        int rc;
        uint8_t cmd;
        uint64_t b;

        EnterCriticalSection(&g_lock);
        gen = g_ack_gen; rc = g_ack_result; cmd = (uint8_t)g_ack_cmd; b = g_ack_boot;
        LeaveCriticalSection(&g_lock);

        if (gen != start && cmd == want) {
            if (result) *result = rc;
            if (boot)   *boot = b;
            return 0;
        }
        if ((DWORD)(GetTickCount() - t0) > (DWORD)timeout_ms) return -1;
        Sleep(5);
    }
}

static int latest_state(State *out)
{
    int ok;
    EnterCriticalSection(&g_lock);
    ok = g_have_state;
    if (ok) *out = g_state;
    LeaveCriticalSection(&g_lock);
    return ok;
}

static void show_state(const char *tag)
{
    State s;
    if (!latest_state(&s)) { say("[WAIT] no STATE frame yet\n"); return; }
    say("[%s] phase=%s zero=%d home=%d src=%d\n", tag,
        phase_name(s.phase), s.zero, s.home, s.src);
    say("        pitch raw=%u ang=%+.3f servo=%+.3f | yaw raw=%u ang=%+.3f servo=%+.3f\n",
        s.raw[0], (double)s.angle[0] / 1000.0, (double)s.servo[0] / 1000.0,
        s.raw[1], (double)s.angle[1] / 1000.0, (double)s.servo[1] / 1000.0);

}

static int wait_zero(int timeout_ms)
{
    DWORD t0 = GetTickCount();
    State last;
    int saw_active = 0;
    memset(&last, 0, sizeof last);
    for (;;) {
        State s;
        if (latest_state(&s)) {
            if (s.zero && s.home) return 0;
            /* A STATE frame queued before the READY was parsed can still say
             * "failed"; only trust phase=5 after the axes went active. */
            if (s.phase != 5) saw_active = 1;
            if (s.phase == 5 && saw_active) return -1;
            if (s.phase != last.phase || s.zero != last.zero || s.home != last.home) {
                show_state("STATE");
                last = s;
            }
        }
        if ((DWORD)(GetTickCount() - t0) > (DWORD)timeout_ms) return -2;
        Sleep(20);
    }
}

static int wait_motion(int timeout_ms)
{
    DWORD t0 = GetTickCount();
    int moved = 0;
    for (;;) {
        State s;
        if (latest_state(&s)) {
            if (s.phase == 5) return -1;
            if (s.phase != 0) moved = 1;
            else if (moved) return 0;
        }
        if ((DWORD)(GetTickCount() - t0) > (DWORD)timeout_ms) return moved ? -2 : -3;
        Sleep(20);
    }
}

static int ensure_boot(void)
{
    if (g_boot) return 1;
    send_info(0);
    Sleep(400);
    EnterCriticalSection(&g_lock);
    g_boot = g_ack_boot;
    LeaveCriticalSection(&g_lock);
    if (!g_boot) { say("[ERR]   no INFO reply (wrong port/baud or F1 not running)\n"); return 0; }
    seq_load();
    say("[INFO]  boot_id = 0x%llX  (next seq=%u)\n",
        (unsigned long long)g_boot, (unsigned)(g_seq + 1));
    return 1;
}

/* ------------------------------------------------------------------ shell */

static void help(void);
static void do_ready(void);
static void do_zero(void);
static void do_go(double pd, double yd);

static int run_command(char *line)
{
    char *cmd = strtok(line, " \t\r\n");

    if (!cmd) return 0;
    if (strcmp(cmd, "quit") == 0 || strcmp(cmd, "exit") == 0) return 1;
    if (strcmp(cmd, "help") == 0) { help(); return 0; }
    if (strcmp(cmd, "info") == 0) { g_boot = 0; ensure_boot(); return 0; }
    if (strcmp(cmd, "boot") == 0) {
        say("boot_id = 0x%llX\n", (unsigned long long)g_boot);
        return 0;
    }
    if (strcmp(cmd, "ready") == 0) { do_ready(); return 0; }
    if (strcmp(cmd, "zero") == 0) { do_zero(); return 0; }
    if (strcmp(cmd, "status") == 0) { show_state("STATE"); return 0; }
    if (strcmp(cmd, "mon") == 0) {
        char *v = strtok(NULL, " \t\r\n");
        InterlockedExchange(&g_mon, (v && strcmp(v, "on") == 0) ? 1 : 0);
        say("monitor %s\n", g_mon ? "on" : "off");
        return 0;
    }
    if (strcmp(cmd, "sleep") == 0) {
        char *v = strtok(NULL, " \t\r\n");
        int ms = v ? atoi(v) : 0;
        if (ms > 0) { say("[SLEEP] %d ms\n", ms); Sleep((DWORD)ms); }
        return 0;
    }
    if (strcmp(cmd, "go") == 0) {
        char *a = strtok(NULL, " \t\r\n");
        char *b = strtok(NULL, " \t\r\n");
        if (!a || !b) { say("usage: go <pitchDeg> <yawDeg>\n"); return 0; }
        do_go(atof(a), atof(b));
        return 0;
    }
    say("unknown command: %s (try help)\n", cmd);
    return 0;
}

static void link_summary(void)
{
    say("[LINK]  rx_bytes=%ld  frames=%ld  crc_err=%ld\n",
        (long)g_rx_bytes, (long)g_frames, (long)g_crc_err);
}

/* ------------------------------------------------------------------ seq file
 * The F1 firmware deduplicates (seq, payload) within one boot and rejects any
 * seq <= max_seq, so a fresh process must not restart at 1. Persist the last
 * used seq per boot id next to the executable.
 */

static char g_seqfile[MAX_PATH];

static void seq_file_init(void)
{
    char exe[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, exe, sizeof exe);
    char *slash;

    if (!n) { strcpy(g_seqfile, "f1_proxy.seq"); return; }
    slash = strrchr(exe, '\\');
    if (slash) *(slash + 1) = '\0'; else exe[0] = '\0';
    snprintf(g_seqfile, sizeof g_seqfile, "%sf1_proxy.seq", exe);
}

static void seq_load(void)
{
    FILE *f;
    uint64_t boot = 0;
    uint32_t seq = 0;

    /* Unknown history for this boot (first run / unreadable file): jump well
     * past any plausible max_seq, otherwise the firmware replays a cached
     * reply and the command silently does nothing. */
    g_seq = 30000;
    f = fopen(g_seqfile, "rb");
    if (!f) return;
    if (fread(&boot, sizeof boot, 1, f) == 1 && fread(&seq, sizeof seq, 1, f) == 1 &&
        boot == g_boot && seq < 65535)
        g_seq = (uint16_t)seq;
    fclose(f);
}

static void seq_save(void)
{
    FILE *f = fopen(g_seqfile, "wb");
    uint64_t boot = g_boot;
    uint32_t seq = g_seq;

    if (!f) return;
    fwrite(&boot, sizeof boot, 1, f);
    fwrite(&seq, sizeof seq, 1, f);
    fclose(f);
}

static void help(void)
{
    say("commands:\n"
        "  info                  read boot_id (auto on first command)\n"
        "  ready                 home both axes, then wait for the 5 s servo-only zero\n"
        "  zero                  confirm pose zero (needs homed, idle, both axes centred)\n"
        "  go <pitch> <yaw>      relative degrees, each in -60..+60, e.g. go 10 -20\n"
        "  status                print the latest STATE frame\n"
        "  mon on|off            stream STATE at 5 Hz\n"
        "  sleep <ms>            wait before the next script line\n"
        "  boot                  print cached boot_id\n"
        "  help / quit\n"
        "\n"
        "batch mode: f1_proxy.exe COM7 --script seq.txt   (one command per line)\n"
        "F4 simulation: f1_proxy.exe COM7 --f4sim          (heartbeat + retry + move matrix)\n");
}

static void do_ready(void)
{
    int res = -1;
    uint8_t payload[8];

    if (!ensure_boot()) return;
    put64(payload, g_boot);
    if (!send_cmd(CMD_READY, payload, 8, next_seq(), 0)) return;
    if (wait_ack(CMD_READY, 2000, &res, NULL) != 0) { say("[ERR]   no READY reply\n"); return; }
    if (res != 1) return;
    say("[WAIT]  homing + 5 s servo-only settle (keep your hands off, keep the link alive)...\n");
    int rc = wait_zero(25000);
    if (rc == 0)      say("[OK]    zero_valid=1, GO is now allowed\n");
    else if (rc == -1) say("[FAIL]  phase=5 (fault): check servo power, IDs, limits\n");
    else               say("[FAIL]  timeout waiting for zero_valid\n");
    show_state("FINAL");
}

static void do_zero(void)
{
    int res = -1;
    uint8_t payload[8];

    if (!ensure_boot()) return;
    put64(payload, g_boot);
    if (!send_cmd(CMD_ZERO, payload, 8, next_seq(), 0)) return;
    if (wait_ack(CMD_ZERO, 2000, &res, NULL) != 0) { say("[ERR]   no ZERO reply\n"); return; }
    if (res != 1) { show_state("STATE"); return; }
    int rc = wait_zero(20000);
    if (rc == 0) say("[OK]    pose zero re-confirmed\n");
    else         say("[FAIL]  zero not confirmed (rc=%d)\n", rc);
    show_state("FINAL");
}

static void do_go(double pd, double yd)
{
    int res = -1;
    uint8_t payload[16];

    if (pd < -60.0 || pd > 60.0 || yd < -60.0 || yd > 60.0) {
        say("[ERR]   both angles must be within -60..+60 deg\n");
        return;
    }
    if (!ensure_boot()) return;
    put64(payload, g_boot);
    put32(payload + 8,  (uint32_t)(int32_t)lround(pd * 1000.0));
    put32(payload + 12, (uint32_t)(int32_t)lround(yd * 1000.0));
    if (!send_cmd(CMD_GO, payload, 16, next_seq(), 0)) return;
    if (wait_ack(CMD_GO, 2000, &res, NULL) != 0) { say("[ERR]   no GO reply\n"); return; }
    if (res != 1) { show_state("STATE"); return; }
    int rc = wait_motion(8000);
    if (rc == 0)       say("[OK]    move finished\n");
    else if (rc == -1) say("[FAIL]  phase=5 during move\n");
    else if (rc == -3) say("[WARN]  no motion observed (already there?)\n");
    else               say("[WARN]  timeout waiting for idle\n");
    show_state("FINAL");
}

/* ------------------------------------------------------------------ F4 sim */

/* Send with the real F4 retry rule: identical frame (same seq, same payload)
 * is resent on timeout, and the F1 must answer from its duplicate cache
 * without executing the command twice. */
static int send_and_ack(uint8_t cmd, const uint8_t *pl, uint16_t n,
                        int timeout_ms, int tries, int *result)
{
    uint16_t seq = next_seq();
    uint8_t frame[16 + MAX_PAYLOAD];

    for (int t = 0; t < tries; t++) {
        size_t len = build_frame(frame, cmd, seq, pl, n);
        if (!len) return -1;
        if (t == 0) say("-> %-5s seq=%u %uB\n", cmd_name(cmd), seq, (unsigned)len);
        else        say("-> %-5s seq=%u retransmit #%d\n", cmd_name(cmd), seq, t);
        if (!write_all(frame, len)) return -1;
        if (wait_ack(cmd, timeout_ms, result, NULL) == 0) return 0;
        say("[RETRY] %s seq=%u no reply in %d ms\n", cmd_name(cmd), seq, timeout_ms);
    }
    return -1;
}

static int expected_raw(double deg, int center)
{
    long delta = lround(deg * 4095.0 / 270.0);
    return center + (int)delta;
}

static int f4_simulate(void)
{
    static const double plan[][2] = {
        {0.0, 0.0}, {20.0, 20.0}, {-20.0, -20.0}, {50.0, 0.0},
        {0.0, 50.0}, {-50.0, 0.0}, {0.0, -50.0}, {50.0, 50.0},
        {-50.0, -50.0}, {20.0, 20.0}, {0.0, 0.0}
    };
    const int steps = (int)(sizeof plan / sizeof plan[0]);
    const DWORD gap_ms = 3000;   /* dwell between two moves */
    double worst = 0.0, total = 0.0;
    int measured = 0, rejected = 0;

    if (!ensure_boot()) return 1;

    say("[F4SIM] READY\n");
    {
        uint8_t pl[8];
        int res = -1;
        put64(pl, g_boot);
        if (send_and_ack(CMD_READY, pl, 8, 500, 3, &res) != 0 || res != 1) {
            say("[F4SIM] READY rejected result=%d\n", res);
            return 1;
        }
    }
    if (wait_zero(25000) != 0) { say("[F4SIM] zero not confirmed\n"); return 1; }
    say("[F4SIM] zero_valid=1, %d moves planned\n", steps);

    for (int i = 0; i < steps; i++) {
        double pd = plan[i][0], yd = plan[i][1];
        uint8_t pl[16];
        int res = -1, mrc;
        DWORD t0, dt;
        State s;
        int ep, ey;

        put64(pl, g_boot);
        put32(pl + 8,  (uint32_t)(int32_t)lround(pd * 1000.0));
        put32(pl + 12, (uint32_t)(int32_t)lround(yd * 1000.0));
        t0 = GetTickCount();
        if (send_and_ack(CMD_GO, pl, 16, 500, 3, &res) != 0 || res != 1) {
            say("[MOVE ] target %+6.2f/%+6.2f REJECTED result=%d\n", pd, yd, res);
            rejected++;
            continue;
        }
        mrc = wait_motion(8000);
        dt = GetTickCount() - t0;
        if (mrc != 0 || !latest_state(&s)) {
            say("[MOVE ] target %+6.2f/%+6.2f motion rc=%d\n", pd, yd, mrc);
            rejected++;
            continue;
        }
        ep = (int)s.raw[0] - expected_raw(pd, 1881);
        ey = (int)s.raw[1] - expected_raw(yd, 2405);
        {
            double dp = ep * 270.0 / 4095.0, dy = ey * 270.0 / 4095.0;
            double m = fabs(dp) > fabs(dy) ? fabs(dp) : fabs(dy);
            if (m > worst) worst = m;
            total += (fabs(dp) + fabs(dy)) / 2.0;
            measured++;
            say("[MOVE ] target %+6.2f/%+6.2f  raw %4u/%4u  err %+3d/%+3d cnt (%+.2f/%+.2f deg)  %5lu ms\n",
                pd, yd, s.raw[0], s.raw[1], ep, ey, dp, dy, (unsigned long)dt);
        }
        if (i + 1 < steps) { say("[DWELL] %lu ms\n", (unsigned long)gap_ms); Sleep(gap_ms); }
    }

    say("[F4SIM] READY (home)\n");
    {
        uint8_t pl[8];
        int res = -1;
        put64(pl, g_boot);
        if (send_and_ack(CMD_READY, pl, 8, 500, 3, &res) == 0 && res == 1)
            (void)wait_zero(25000);
        else
            say("[F4SIM] final READY result=%d\n", res);
    }

    say("[F4SIM] moves=%d rejected=%d  max|err|=%.3f deg  mean|err|=%.3f deg\n",
        measured, rejected, worst, measured ? total / measured : 0.0);
    link_summary();
    return rejected ? 1 : 0;
}

/* ------------------------------------------------------------------ selftest */

static void to_hex(char *out, const uint8_t *b, size_t n)
{
    static const char *d = "0123456789ABCDEF";
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = d[b[i] >> 4];
        out[2 * i + 1] = d[b[i] & 15];
    }
    out[2 * n] = '\0';
}

static int selftest(void)
{
    uint8_t f[256], pl[128];
    char hex[600];
    int fail = 0;

    if (crc16((const uint8_t *)"123456789", 9) != 0x29B1) {
        printf("FAIL crc check string\n"); fail = 1;
    }

    size_t n = build_frame(f, 0x40, 1, NULL, 0);
    to_hex(hex, f, n);
    if (strcmp(hex, "55AA0240010000008CE2") != 0) {
        printf("FAIL golden GET_INFO frame: %s\n", hex); fail = 1;
    }

    memset(pl, 0, sizeof pl);
    put64(pl, 1);
    n = build_frame(f, CMD_READY, 2, pl, 8);
    to_hex(hex, f, n);
    if (strcmp(hex, "55AA0221020008000100000000000000D13C") != 0) {
        printf("FAIL READY frame: %s\n", hex); fail = 1;
    }

    {
        uint8_t acc[64];
        size_t used = 0;
        feed(acc, sizeof acc, &used, f, n);
        if (used != 0) { printf("FAIL parser left %u bytes\n", (unsigned)used); fail = 1; }
    }

    memset(pl, 0, sizeof pl);
    put64(pl, 7);
    put32(pl + 8, 42);
    pl[12] = 2; pl[13] = 1; pl[14] = 1; pl[15] = 1;
    put64(pl + 16, 1234567);
    put64(pl + 24, 900); put64(pl + 32, 901);
    put32(pl + 40, (uint32_t)10000); put32(pl + 44, (uint32_t)-5000);
    put32(pl + 48, (uint32_t)10000); put32(pl + 52, (uint32_t)-5000);
    put16(pl + 56, 1881); put16(pl + 58, 2405);
    pl[90] = 0; put32(pl + 92, 0);

    {
        State s;
        decode_state(pl, &s);
        if (s.phase != 2 || s.zero != 1 || s.home != 1 || s.src != 1 ||
            s.angle[0] != 10000 || s.angle[1] != -5000 ||
            s.raw[0] != 1881 || s.raw[1] != 2405 || s.seq != 42) {
            printf("FAIL state decode\n"); fail = 1;
        }
    }

    printf("%s\n", fail ? "SELFTEST FAILED" : "SELFTEST OK");
    return fail;
}

/* ------------------------------------------------------------------ main */

static void close_port(void)
{
    if (g_port && g_port != INVALID_HANDLE_VALUE) {
        CloseHandle(g_port);
        g_port = NULL;
    }
}

static BOOL WINAPI on_ctrl(DWORD type)
{
    (void)type;
    InterlockedExchange(&g_quit, 1);
    return TRUE;
}

int main(int argc, char **argv)
{
    const char *port = "COM7";
    const char *script = NULL;
    int baud = 460800;
    int f4sim = 0;
    char line[256];
    HANDLE thread;
    DCB dcb;
    COMMTIMEOUTS to;
    char path[64];

    setvbuf(stdout, NULL, _IONBF, 0);
    g_t0 = GetTickCount();
    seq_file_init();
    InitializeCriticalSection(&g_out);
    InitializeCriticalSection(&g_lock);
    InitializeCriticalSection(&g_write);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0) return selftest();
        else if (strcmp(argv[i], "--f4sim") == 0) f4sim = 1;
        else if (strcmp(argv[i], "--script") == 0 && i + 1 < argc) script = argv[++i];
        else if (strcmp(argv[i], "--baud") == 0 && i + 1 < argc) baud = atoi(argv[++i]);
        else port = argv[i];
    }

    snprintf(path, sizeof path, "\\\\.\\%s", port);
    g_port = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                         OPEN_EXISTING, 0, NULL);
    if (g_port == INVALID_HANDLE_VALUE) {
        printf("cannot open %s (error %lu). Is the serial tool still using it?\n",
               port, (unsigned long)GetLastError());
        return 1;
    }

    memset(&dcb, 0, sizeof dcb);
    dcb.DCBlength = sizeof dcb;
    if (!GetCommState(g_port, &dcb)) { printf("GetCommState failed\n"); return 1; }
    dcb.BaudRate = (DWORD)baud;
    dcb.ByteSize = 8;
    dcb.Parity   = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary  = TRUE;
    dcb.fParity  = FALSE;
    if (!SetCommState(g_port, &dcb)) { printf("SetCommState failed\n"); return 1; }

    to.ReadIntervalTimeout = 20;
    to.ReadTotalTimeoutMultiplier = 0;
    to.ReadTotalTimeoutConstant = 20;
    to.WriteTotalTimeoutMultiplier = 0;
    to.WriteTotalTimeoutConstant = 500;
    SetCommTimeouts(g_port, &to);
    SetupComm(g_port, 8192, 8192);
    PurgeComm(g_port, PURGE_RXCLEAR | PURGE_TXCLEAR);

    SetConsoleCtrlHandler(on_ctrl, TRUE);

    if (f4sim) {
        int rc;
        printf("F1 proxy on %s @ %d 8N1, F4 simulation mode\n", port, baud);
        thread = CreateThread(NULL, 0, reader, NULL, 0, NULL);
        if (!thread) { printf("thread create failed\n"); return 1; }
        rc = f4_simulate();
        InterlockedExchange(&g_quit, 1);
        WaitForSingleObject(thread, 1000);
        CloseHandle(thread);
        close_port();
        printf("simulation done (rc=%d)\n", rc);
        return rc;
    }

    if (script) {
        FILE *fp = fopen(script, "r");
        if (!fp) { printf("cannot open script: %s\n", script); return 1; }
        printf("F1 proxy on %s @ %d 8N1, script=%s\n", port, baud, script);
        thread = CreateThread(NULL, 0, reader, NULL, 0, NULL);
        if (!thread) { printf("thread create failed\n"); return 1; }
        ensure_boot();
        while (fgets(line, sizeof line, fp)) {
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '\0' || *p == '\r' || *p == '\n' || *p == '#') continue;
            say("\n>> %s", p);
            if (run_command(p)) break;
        }
        fclose(fp);
        InterlockedExchange(&g_quit, 1);
        WaitForSingleObject(thread, 1000);
        CloseHandle(thread);
        link_summary();
        close_port();
        printf("script done\n");
        return 0;
    }

    printf("F1 proxy on %s @ %d 8N1. Type help, quit to exit.\n", port, baud);
    thread = CreateThread(NULL, 0, reader, NULL, 0, NULL);
    if (!thread) { printf("thread create failed\n"); return 1; }
    ensure_boot();

    for (;;) {
        say("f1> ");
        if (!fgets(line, sizeof line, stdin)) break;
        if (run_command(line)) break;
    }

    InterlockedExchange(&g_quit, 1);
    WaitForSingleObject(thread, 1000);
    CloseHandle(thread);
    link_summary();
    close_port();
    printf("bye\n");
    return 0;
}
