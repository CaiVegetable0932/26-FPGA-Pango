/* ============================================================================
 * cal3.c —— 龙门架第 3 轴（悬臂伸缩）标定控制台
 *
 * 目标：双击即可运行的极简交互程序，用于"时效性极强的标定"操作。
 *   按 1 + 回车 → 发送 measure 3 start（开始以 10 RPM 正转）
 *   按 2 + 回车 → 发送 measure 3 over （停止并回报圈数）
 *   按 3 + 回车 → 显示已回传的标定数据（圈数）
 *   按 0 + 回车 → 急停 stop 3（比 over 快，但不回报圈数）
 *   按 s + 回车 → 显示当前 state 文本
 *   按 q + 回车 → 发送 wake 停止全部轴并退出
 *
 * 为什么不能用普通串口助手：
 *   固件有 1 秒控制租约，只有持续心跳才允许运动；本程序内置 300 ms 心跳线程，
 *   否则 measure 只转约 1 秒就被看门狗停掉。
 *
 * 构建（MinGW / gcc）：
 *   gcc -O2 -Wall -Wextra -o cal3.exe cal3.c -ladvapi32
 *
 * 端口：自动枚举注册表 SERIALCOMM，跳过蓝牙端口；若存在多个则提示选择。
 * ========================================================================== */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <process.h>

#define WIRE_VERSION     2U
#define CMD_GET_INFO     0x40U
#define CMD_OPEN         0x41U
#define CMD_SET_STREAM   0x43U
#define CMD_HEARTBEAT    0x4CU
#define CMD_LEGACY       0x50U
#define CMD_MOVE_ABS     0x46U
#define CMD_HOME         0x48U
#define CMD_ACK_EVENT    0x49U
#define CMD_POSE_ZERO    0x4AU
#define CMD_MANUAL_ZERO  0x51U
#define RSP_GENERIC      0x80U
#define RSP_EVENT        0x90U
#define RSP_NOTICE       0x91U
#define WIRE_MAX_PAYLOAD 240U
#define HEARTBEAT_MS     150U

/* ---------------------------------------------------------------- 基础工具 */
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)rd16(p) | ((uint32_t)rd16(p + 2) << 16); }
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32); }
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void wr32(uint8_t *p, uint32_t v) { wr16(p, (uint16_t)v); wr16(p + 2, (uint16_t)(v >> 16)); }
static void wr64(uint8_t *p, uint64_t v) { wr32(p, (uint32_t)v); wr32(p + 4, (uint32_t)(v >> 32)); }

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

/* ---------------------------------------------------------------- 全局状态 */
static HANDLE             g_port = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION   g_tx, g_out;
static uint64_t           g_boot;
static uint32_t           g_session;
static uint16_t           g_seq;
static uint32_t           g_legacy_id;      /* 下一个 motion id：必须 > 固件 latest_motion */
static volatile LONG      g_quit;
static volatile LONG      g_heartbeat_on;
static volatile LONG      g_hb_sent;   /* 已发送心跳数，故障时用于判断是否真的在发 */

static double             g_revs = -1.0;     /* 最近一次 measure 3 回报的圈数 */
static char               g_revs_text[96];   /* 原始通知文本 */
static int                g_revs_count;
/* 运动默认速度（RPM），可用 speed <n> 修改 */
static int                g_speed = 10;
static DWORD              g_event_mute_until;   /* 启动后静默旧事件的截止时刻 */

static void out(const char *fmt, ...)
{
    va_list ap;
    EnterCriticalSection(&g_out);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
    LeaveCriticalSection(&g_out);
}

/* ---------------------------------------------------------------- 串口 */
static int ser_open(const char *name)
{
    char path[128];
    if ((name[0] == 'C' || name[0] == 'c') && (name[1] == 'O' || name[1] == 'o') &&
        (name[2] == 'M' || name[2] == 'm'))
        snprintf(path, sizeof(path), "\\\\.\\%s", name);
    else
        snprintf(path, sizeof(path), "%s", name);

    g_port = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                         OPEN_EXISTING, 0, NULL);
    if (g_port == INVALID_HANDLE_VALUE) return -1;

    DCB dcb;
    memset(&dcb, 0, sizeof(dcb));
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(g_port, &dcb)) { CloseHandle(g_port); return -1; }
    dcb.BaudRate = CBR_115200;
    dcb.ByteSize = 8;
    dcb.Parity   = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary  = TRUE;
    dcb.fParity  = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl  = DTR_CONTROL_DISABLE;   /* 不要复位目标板 */
    dcb.fRtsControl  = RTS_CONTROL_DISABLE;
    dcb.fOutX = dcb.fInX = FALSE;
    if (!SetCommState(g_port, &dcb)) { CloseHandle(g_port); return -1; }

    COMMTIMEOUTS to;
    to.ReadIntervalTimeout         = 20;
    to.ReadTotalTimeoutMultiplier  = 0;
    to.ReadTotalTimeoutConstant    = 20;
    to.WriteTotalTimeoutMultiplier = 0;
    to.WriteTotalTimeoutConstant   = 200;
    SetCommTimeouts(g_port, &to);
    PurgeComm(g_port, PURGE_RXCLEAR | PURGE_TXCLEAR);
    return 0;
}

static int ser_write(const uint8_t *p, size_t n)
{
    DWORD written = 0;
    if (!WriteFile(g_port, p, (DWORD)n, &written, NULL)) return -1;
    if (written != n) return -1;
    return 0;
}

/* 自动挑选串口：跳过蓝牙，只有一个就直接用，多个则提示输入 */
static int pick_port(char *outbuf, size_t cap)
{
    HKEY k;
    char cand[16][24];
    int nc = 0;

    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DEVICEMAP\\SERIALCOMM",
                      0, KEY_READ, &k) != ERROR_SUCCESS)
        return -1;

    for (DWORD i = 0;; ++i) {
        char name[256];
        BYTE data[256];
        DWORD nlen = sizeof(name), dlen = sizeof(data), type = 0;
        if (RegEnumValueA(k, i, name, &nlen, NULL, &type, data, &dlen) != ERROR_SUCCESS)
            break;
        if (strstr(name, "BthModem")) continue;      /* 蓝牙虚拟串口 */
        if (dlen == 0 || dlen >= 24) continue;
        if (nc < 16) { memcpy(cand[nc], data, dlen); cand[nc][dlen] = '\0'; ++nc; }
    }
    RegCloseKey(k);

    if (nc == 0) return -1;
    if (nc == 1) { snprintf(outbuf, cap, "%s", cand[0]); return 0; }

    printf("发现多个串口：\n");
    for (int i = 0; i < nc; ++i) printf("  [%d] %s\n", i + 1, cand[i]);
    printf("请选择序号（回车确认）：");
    fflush(stdout);
    char line[32];
    if (!fgets(line, sizeof(line), stdin)) return -1;
    int idx = atoi(line);
    if (idx < 1 || idx > nc) return -1;
    snprintf(outbuf, cap, "%s", cand[idx - 1]);
    return 0;
}

/* ---------------------------------------------------------------- 组帧/发帧 */
static void put_ctx(uint8_t *p)
{
    wr64(p, g_boot);
    wr32(p + 8, g_session);
}

static int send_frame(uint8_t cmd, const uint8_t *payload, uint16_t n)
{
    uint8_t frame[16 + WIRE_MAX_PAYLOAD];
    if (n > WIRE_MAX_PAYLOAD) return -1;
    frame[0] = 0x55; frame[1] = 0xAA; frame[2] = WIRE_VERSION; frame[3] = cmd;
    wr16(frame + 6, n);
    if (n) memcpy(frame + 8, payload, n);

    /* 2026-10-22：序号必须在锁内自增。心跳线程与主线程共用 g_seq，
     * 原来在锁外 ++g_seq，两个线程可能取到同一个序号；F4 对重复序号回放/拒绝，
     * 就不会刷新控制租约，运动中被看门狗判 fault=8(LEASE_LOST) 并中止。
     * 实测 go 20 20 20 20 20 时就发生：伸缩轴走完后整组被 stopped。 */
    EnterCriticalSection(&g_tx);
    uint16_t seq = ++g_seq;
    wr16(frame + 4, seq);
    wr16(frame + 8 + n, crc16(frame + 2, (size_t)6 + n));
    int rc = ser_write(frame, (size_t)n + 10U);
    LeaveCriticalSection(&g_tx);
    return rc;
}

static int send_legacy(const char *text)
{
    size_t len = strlen(text);
    if (len == 0 || len > 95) return -1;
    uint8_t p[16 + 96];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    wr32(p + 12, ++g_legacy_id);
    memcpy(p + 16, text, len);
    return send_frame(CMD_LEGACY, p, (uint16_t)(16 + len));
}

/* ---------------------------------------------------------------- 收帧 */
/* MOVE_ABS：一次同时下发 XYZ 坐标与云台 pitch/yaw。
 * 注意固件逻辑轴序与现场叫法的对应（现场按用户命名）：
 *   target[0] = 轴1 = 单电机 = 现场 X
 *   target[1] = 轴2 = 双电机龙门架 = 现场 Z
 *   target[2] = 轴3 = 悬臂伸缩 = 现场 Y
 *   target[3] = pitch(mdeg)，target[4] = yaw(mdeg)
 * 因此命令行参数顺序是 x y z yaw pitch，内部按上面重新排列。 */
static int send_move(double x, double y, double z, double yaw_deg, double pitch_deg, int rpm)
{
    if (rpm < 1 || rpm > 60) { out("rpm 必须在 1..60"); return -1; }
    if (x < 0.0 || x > 100.0 || y < 0.0 || y > 100.0 || z < 0.0 || z > 100.0) {
        out("XYZ 坐标必须在 0..100（百分比行程）");
        return -1;
    }
    if (yaw_deg < -60.0 || yaw_deg > 60.0 || pitch_deg < -60.0 || pitch_deg > 60.0) {
        out("云台角度必须在 -60..60 度");
        return -1;
    }
    uint8_t p[48];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    wr32(p + 12, ++g_legacy_id);
    p[16] = 0x1FU;                                  /* X|Y|Z|pitch|yaw */
    double coord[3] = { x, z, y };                  /* 固件轴序：1=X 2=Z 3=Y */
    for (int i = 0; i < 3; ++i)
        wr32(p + 20 + 4 * i, (uint32_t)(int32_t)(coord[i] * 1000000.0 + 0.5));
    wr32(p + 32, (uint32_t)(int32_t)(pitch_deg * 1000.0 + (pitch_deg < 0 ? -0.5 : 0.5)));
    wr32(p + 36, (uint32_t)(int32_t)(yaw_deg * 1000.0 + (yaw_deg < 0 ? -0.5 : 0.5)));
    wr16(p + 40, (uint16_t)rpm);
    wr16(p + 42, (uint16_t)rpm);
    wr16(p + 44, (uint16_t)rpm);
    out(">>> MOVE_ABS  X=%.3f  Y=%.3f  Z=%.3f   yaw=%.3f°  pitch=%.3f°   rpm=%d",
        x, y, z, yaw_deg, pitch_deg, rpm);
    return send_frame(CMD_MOVE_ABS, p, sizeof(p));
}

/* 复位（RST）后恢复现场必须的三步，缺任何一步后续指令都会回 result=7：
 *   c = CONFIRM_MANUAL_ZERO：声明"当前物理位置就是三轴零点"（F4 侧坐标才有效）
 *   h = HOME：F1 两轴回到正对角度（云台零位的前提）
 *   z = SET_POSE_ZERO：把回正后的位置登记为姿态零位（zero_valid） */
static int send_confirm(void)
{
    uint8_t p[16];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    p[12] = 0x07U;                    /* X|Y|Z 三轴一起确认 */
    out(">>> CONFIRM_MANUAL_ZERO mask=0x07（把当前位置声明为三轴零点）");
    return send_frame(CMD_MANUAL_ZERO, p, sizeof(p));
}

static int send_home(void)
{
    /* 0x48 的载荷长度固定为 20 字节（ctx 12 + id 4 + mask 1 + 保留 3），
     * 与 0x46 的 48 字节不同；发错长度会得到 result=3(BAD_LENGTH)。 */
    uint8_t p[20];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    wr32(p + 12, ++g_legacy_id);
    p[16] = 0x18U;                    /* 仅云台两轴 */
    out(">>> HOME mask=0x18（F1 两轴回到正对角度，约需 10 秒）");
    return send_frame(CMD_HOME, p, sizeof(p));
}

static int send_pose_zero(void)
{
    uint8_t p[12];
    memset(p, 0, sizeof(p));
    put_ctx(p);
    out(">>> SET_POSE_ZERO（把当前回正位置登记为姿态零位）");
    return send_frame(CMD_POSE_ZERO, p, sizeof(p));
}


static void handle_event(const uint8_t *p, uint16_t n)
{
    if (n < 40) return;
    uint32_t id = rd32(p + 12);
    /* 启动阶段把上次会话遗留的事件只 ACK 不打印，避免误读成新结果 */
    if ((DWORD)GetTickCount() < g_event_mute_until) {
        uint8_t q[16];
        memset(q, 0, sizeof(q));
        put_ctx(q);
        wr32(q + 12, id);
        send_frame(CMD_ACK_EVENT, q, sizeof(q));
        return;
    }
    uint32_t motion = rd32(p + 24);
    uint16_t type = rd16(p + 28);
    uint16_t result = rd16(p + 30);
    uint16_t fault = rd16(p + 36);
    const char *tn = "?";
    switch (type) {
        case 1: tn = "ACCEPTED"; break;
        case 2: tn = "MOTION_DONE"; break;
        case 4: tn = "HOME_DONE"; break;
        case 5: tn = "CANCELLED"; break;
        case 7: tn = "POSE_ZEROED"; break;
        case 8: tn = "LINK_LOST"; break;
        default: break;
    }
    out("[事件] %s  motion=%u  result=%u  fault=%u  （已发心跳 %ld 次）",
        tn, motion, result, fault, (long)InterlockedCompareExchange(&g_hb_sent, 0, 0));
    if (fault != 0)
        out("    提示：fault=8 表示 F4 超过 1 秒没收到上位机命令；若上面心跳数在增长，"
            "说明心跳被拒（序号/会话不符），否则是心跳没发出去。");
    uint8_t q[16];
    memset(q, 0, sizeof(q));
    put_ctx(q);
    wr32(q + 12, id);
    send_frame(CMD_ACK_EVENT, q, sizeof(q));
}

static void handle_notice(const uint8_t *p, uint16_t n)
{
    if (n <= 12) return;
    char text[256];
    uint16_t m = (uint16_t)(n - 12);
    if (m > sizeof(text) - 1) m = sizeof(text) - 1;
    memcpy(text, p + 12, m);
    text[m] = '\0';
    /* 去掉尾随空白 */
    while (m && (text[m - 1] == '\r' || text[m - 1] == '\n' || text[m - 1] == ' '))
        text[--m] = '\0';
    if (!m) return;

    /* 固件 state 文本按"逻辑轴 1/2/3"顺序返回坐标，而现场叫法是
     * 轴1=X、轴2=Z（双电机）、轴3=Y（伸缩）。12.0 这里换成现场命名再打印，
     * 否则很容易把 Y 和 Z 读反。 */
    if (!strncmp(text, "state ", 6)) {
        double a = 0, b = 0, c = 0;
        if (sscanf(text + 6, "%lf %lf %lf", &a, &b, &c) == 3) {
            out("[位置] X=%.3f  Y=%.3f  Z=%.3f   （已按现场命名：Y=伸缩轴，Z=双电机轴）",
                a, c, b);
            return;
        }
    }

    out("[通知] %s", text);

    /* 记录 measure 3 <圈数> */
    if (!strncmp(text, "measure 3 ", 10)) {
        double v = atof(text + 10);
        EnterCriticalSection(&g_out);
        g_revs = v;
        snprintf(g_revs_text, sizeof(g_revs_text), "%s", text);
        ++g_revs_count;
        LeaveCriticalSection(&g_out);
        out("       >>> 标定圈数 = %.6f（第 %d 次回报，请记录）", v, g_revs_count);
    }
}

static void handle_generic(const uint8_t *p, uint16_t n)
{
    if (n < 16) return;
    uint64_t boot = rd64(p);
    uint32_t session = rd32(p + 8);
    uint8_t req = p[12];
    uint8_t result = p[13];
    const uint8_t *data = p + 16;
    uint16_t dn = (uint16_t)(n - 16);

    if (boot) g_boot = boot;
    if (req == CMD_OPEN && result == 0) {
        g_session = session;
        /* OPEN 回应 data = config(4) + latest_motion(4)；
         * LEGACY 要求 motion id 严格大于 latest_motion，否则返回 result=10(STALE)。 */
        if (dn >= 8) {
            uint32_t lm = rd32(data + 4);
            if (lm > g_legacy_id) g_legacy_id = lm;
        }
    }

    if (req == CMD_LEGACY) {
        char text[256];
        uint16_t m = (uint16_t)(dn < sizeof(text) - 1 ? dn : sizeof(text) - 1);
        memcpy(text, data, m);
        text[m] = '\0';
        while (m && (text[m - 1] == '\r' || text[m - 1] == '\n')) text[--m] = '\0';
        /* 固件 state 文本按逻辑轴 1/2/3 顺序返回（轴2=双电机=现场Z，轴3=伸缩=现场Y），
         * 这里换成现场命名再打印，否则极易把 Y / Z 读反。 */
        if (!strncmp(text, "state ", 6)) {
            double a = 0, b = 0, c = 0;
            if (sscanf(text + 6, "%lf %lf %lf", &a, &b, &c) == 3) {
                out("[位置] X=%.3f  Y=%.3f  Z=%.3f   （现场命名：Y=伸缩轴，Z=双电机轴）",
                    a, c, b);
                return;
            }
        }
        if (m) out("[回应] %s", text);
        if (result != 0 && result != 1)
            out("[失败] result=%u（看上面的 error 文本）", (unsigned)result);
        if (req == CMD_MOVE_ABS && result == 2U)
            out("    上一条动作还没结束：等 1~2 秒后把同一条命令再发一次即可");
        return;
    }
    if (req == CMD_HEARTBEAT) return;                      /* 不刷屏 */
    if (result != 0 && result != 1)
        out("[失败] req=0x%02X result=%u", (unsigned)req, (unsigned)result);
}

static void on_frame(uint8_t cmd, const uint8_t *p, uint16_t n)
{
    if (cmd == RSP_NOTICE)        handle_notice(p, n);
    else if (cmd == RSP_EVENT)    handle_event(p, n);
    else if (cmd == RSP_GENERIC)  handle_generic(p, n);
}

static uint8_t rxbuf[2048];
static size_t  rxlen;

static void feed(const uint8_t *d, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        if (rxlen < sizeof(rxbuf)) rxbuf[rxlen++] = d[i];

    size_t i = 0;
    while (rxlen - i >= 10) {
        if (rxbuf[i] != 0x55 || rxbuf[i + 1] != 0xAA || rxbuf[i + 2] != WIRE_VERSION) {
            ++i;
            continue;
        }
        uint16_t len = rd16(rxbuf + i + 6);
        if (len > WIRE_MAX_PAYLOAD) { ++i; continue; }
        size_t total = (size_t)len + 10U;
        if (rxlen - i < total) break;
        uint16_t crc = rd16(rxbuf + i + 8 + len);
        if (crc16(rxbuf + i + 2, (size_t)6 + len) != crc) { ++i; continue; }
        on_frame(rxbuf[i + 3], rxbuf + i + 8, len);
        i += total;
    }
    if (i) { memmove(rxbuf, rxbuf + i, rxlen - i); rxlen -= i; }
}

static unsigned __stdcall reader_thread(void *arg)
{
    (void)arg;
    uint8_t b[256];
    while (!g_quit) {
        DWORD got = 0;
        if (!ReadFile(g_port, b, sizeof(b), &got, NULL)) break;
        if (got) feed(b, got);
        else     Sleep(5);
    }
    return 0;
}

static unsigned __stdcall heartbeat_thread(void *arg)
{
    (void)arg;
    while (!g_quit) {
        if (InterlockedCompareExchange(&g_heartbeat_on, 1, 1)) {
            uint8_t p[12];
            put_ctx(p);
            send_frame(CMD_HEARTBEAT, p, sizeof(p));
            InterlockedIncrement(&g_hb_sent);
        }
        Sleep(HEARTBEAT_MS);
    }
    return 0;
}

/* ---------------------------------------------------------------- 握手 */
static int handshake(void)
{
    uint8_t p[16];

    for (int attempt = 0; attempt < 6; ++attempt) {
        g_boot = 0;
        send_frame(CMD_GET_INFO, NULL, 0);
        for (int i = 0; i < 40 && !g_boot; ++i) Sleep(50);
        if (g_boot) break;
    }
    if (!g_boot) return -1;

    srand((unsigned)GetTickCount());
    uint32_t session = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
    if (!session) session = 0x13572468U;

    memset(p, 0, sizeof(p));
    wr32(p, session);
    wr64(p + 4, g_boot);
    wr32(p + 12, 0);
    g_session = 0;
    send_frame(CMD_OPEN, p, sizeof(p));
    for (int i = 0; i < 40 && !g_session; ++i) Sleep(50);
    if (!g_session) return -2;

    /* 关掉状态流，避免刷屏；心跳仍然保持租约 */
    memset(p, 0, sizeof(p));
    put_ctx(p);
    wr16(p + 12, 0);
    wr16(p + 14, 0);
    send_frame(CMD_SET_STREAM, p, sizeof(p));
    Sleep(100);

    g_event_mute_until = (DWORD)GetTickCount() + 1500U;
    InterlockedExchange(&g_heartbeat_on, 1);
    return 0;
}

/* ---------------------------------------------------------------- 主程序 */
static void show_data(void)
{
    EnterCriticalSection(&g_out);
    double v = g_revs;
    int cnt = g_revs_count;
    char txt[96];
    snprintf(txt, sizeof(txt), "%s", g_revs_text);
    LeaveCriticalSection(&g_out);

    if (v < 0) {
        out("尚无标定数据。请先按 2 结束测量（over）以获取圈数。");
        return;
    }
    out("========== 标定数据 ==========");
    out("  轴            : 3（悬臂伸缩）");
    out("  原始通知      : %s", txt);
    out("  圈数          : %.6f", v);
    out("  脉冲数        : %u（1600 脉冲/圈）", (unsigned)(v * 1600.0 + 0.5));
    out("  回报次数      : %d", cnt);
    out("------------------------------");
    out("  下一步可用文本命令设置行程：");
    out("      set 3 %.6f", v);
    out("  注意：行程只存 RAM，F4 复位即丢失，请立即记录上面的圈数。");
    out("==============================");
}

int main(void)
{
    SetConsoleOutputCP(65001);
    SetConsoleTitleA("Axis-3 Calibration Console (cal3)");

    InitializeCriticalSection(&g_tx);
    InitializeCriticalSection(&g_out);

    char port[24];
    if (pick_port(port, sizeof(port)) != 0) {
        printf("未找到可用的串口。请确认 USB-TTL 已插入。按回车退出。");
        fflush(stdout);
        getchar();
        return 1;
    }

    if (ser_open(port) != 0) {
        printf("打开串口 %s 失败（GetLastError=%lu）。按回车退出。",
               port, (unsigned long)GetLastError());
        fflush(stdout);
        getchar();
        return 1;
    }
    printf("已打开 %s（115200 8N1）\n", port);

    HANDLE hr = (HANDLE)_beginthreadex(NULL, 0, reader_thread, NULL, 0, NULL);
    if (!hr) { printf("创建读取线程失败。\n"); return 1; }

    int hs = handshake();
    if (hs != 0) {
        printf("握手失败（%d）：目标板未响应。\n", hs);
        printf("  1) 检查 F4 是否上电、USB-TTL 的 TXD->PD9 / RXD->PD8 / GND；\n");
        printf("  2) 若刚烧录完，等 2 秒后重新双击本程序。\n");
        InterlockedExchange(&g_quit, 1);
        WaitForSingleObject(hr, 1000);
        printf("按回车退出。");
        fflush(stdout);
        getchar();
        return 1;
    }

    HANDLE hh = (HANDLE)_beginthreadex(NULL, 0, heartbeat_thread, NULL, 0, NULL);

    printf("\n");
    printf("====================================================\n");
    printf("  龙门架第 3 轴（悬臂伸缩）标定控制台\n");
    printf("  已连接，boot=%lu，心跳 300 ms 已启动\n", (unsigned long)g_boot);
    printf("----------------------------------------------------\n");
    printf("   1 + 回车   开始测量   measure 3 start\n");
    printf("   2 + 回车   结束并回报 measure 3 over\n");
    printf("   3 + 回车   显示标定数据\n");
    printf("   4 + 回车   把圈数写入行程   set 3 <测得的圈数>\n");
    printf("   5 + 回车   回到物理零点     out 0 10   （需先 4）\n");
    printf("   0 + 回车   急停       stop 3   （更快，但无圈数回报）\n");
    printf("   s + 回车   查看 state 文本\n");
    printf("   q + 回车   停止全部轴并退出\n");
    printf("----------------------------------------------------\n");
    printf("   复位(RST)后恢复现场，按 c → h → z 顺序：\n");
    printf("   c + 回车   确认三轴手动零位（当前位置=零点）\n");
    printf("   h + 回车   F1 两轴回正（约 10 秒）\n");
    printf("   z + 回车   登记姿态零位\n");
    printf("----------------------------------------------------\n");
    printf("       例：go 5 6 7 8 9  →  X=5 Y=6 Z=7，yaw=8°，pitch=9°，速度 %d\n", g_speed);
    printf("       （Y=悬臂伸缩，Z=双电机龙门架，坐标 0..100 为行程百分比）\n");
    printf("   speed <rpm>                设置默认速度（1..60）\n");
    printf("   wait <ms>                  等待指定毫秒（用于连续动作）\n");
    printf("----------------------------------------------------\n");
    printf("   警告：measure 3 没有软限位，只有 2 或 0 能停。\n");
    printf("        10 RPM 下人反应 0.5 秒约多转 0.08 圈。\n");
    printf("====================================================\n\n");

    char line[128];
    for (;;) {
        printf("> ");
        fflush(stdout);
        if (!fgets(line, sizeof(line), stdin)) break;

        /* ---- 文本命令：go / speed ---- */
        {
            char kw[16] = {0};
            if (sscanf(line, "%15s", kw) == 1) {
                if (!_stricmp(kw, "go")) {
                    double x = 0, y = 0, z = 0, yaw = 0, pitch = 0;
                    int rpm = 0;
                    int m = sscanf(line, "%*s %lf %lf %lf %lf %lf %d",
                                   &x, &y, &z, &yaw, &pitch, &rpm);
                    if (m < 5) {
                        out("用法：go <X> <Y> <Z> <yaw°> <pitch°> [rpm]");
                        out("  例：go 5 6 7 8 9  →  X=5 Y=6 Z=7，yaw=8°，pitch=9°");
                    } else {
                        send_move(x, y, z, yaw, pitch, (m >= 6) ? rpm : g_speed);
                    }
                    continue;
                }
                if (!_stricmp(kw, "speed")) {
                    int rpm = 0;
                    if (sscanf(line, "%*s %d", &rpm) == 1 && rpm >= 1 && rpm <= 60) {
                        g_speed = rpm;
                        out("默认速度已设为 %d RPM", g_speed);
                    } else {
                        out("用法：speed <1..60>");
                    }
                    continue;
                }
                if (!_stricmp(kw, "wait")) {
                    int ms = 0;
                    if (sscanf(line, "%*s %d", &ms) == 1 && ms >= 0 && ms <= 600000) {
                        out("等待 %d ms ...", ms);
                        Sleep((DWORD)ms);
                    } else {
                        out("用法：wait <毫秒，0..600000>");
                    }
                    continue;
                }
            }
        }

        char c = 0;
        for (char *q = line; *q; ++q) {
            if (*q != ' ' && *q != '\t' && *q != '\r' && *q != '\n') { c = *q; break; }
        }
        if (!c) continue;

        if (c == '1') {
            out(">>> 发送 measure 3 start（轴 3 开始以 10 RPM 正转）");
            out("    停止请按 2（over，回报圈数）或 0（stop 3，急停不含圈数）");
            if (send_legacy("measure 3 start") != 0) out("!! 发送失败");
        } else if (c == '2') {
            out(">>> 发送 measure 3 over（停止并回报圈数）");
            if (send_legacy("measure 3 over") != 0) out("!! 发送失败");
            else out("    请等待 [通知] measure 3 x.xxxxxx 到达后再按 3 查看");
        } else if (c == '3') {
            show_data();
        } else if (c == '4') {
            if (g_revs <= 0.0) {
                out("没有可用圈数：请先按 1 开始、2 结束，等 [通知] 到达后再按 4。");
            } else {
                char cmd[64];
                snprintf(cmd, sizeof(cmd), "set 3 %.6f", g_revs);
                out(">>> 发送 %s", cmd);
                if (send_legacy(cmd) != 0) out("!! 发送失败");
                else out("    成功后会显示 ok set 3 <圈数>；之后可用 5 回零点验证");
            }
        } else if (c == '5') {
            out(">>> 发送 out 0 10（以 10 RPM 回到物理零点）");
            if (send_legacy("out 0 10") != 0) out("!! 发送失败");
        } else if (c == '0') {
            out(">>> 发送 stop 3（急停，不回报圈数）");
            if (send_legacy("stop 3") != 0) out("!! 发送失败");
        } else if (c == 's' || c == 'S') {
            out(">>> 发送 state");
            send_legacy("state");
        } else if (c == 'c' || c == 'C') {
            send_confirm();
        } else if (c == 'h' || c == 'H') {
            send_home();
        } else if (c == 'z' || c == 'Z') {
            send_pose_zero();
        } else if (c == 'q' || c == 'Q') {
            out(">>> 发送 wake 停止全部轴，退出");
            send_legacy("wake");
            Sleep(300);
            break;
        } else {
            out("无效输入：%c（可用 1/2/3/4/5/0/s/q，或 go/speed 文本命令）", c);
        }
    }

    InterlockedExchange(&g_quit, 1);
    if (hh) { WaitForSingleObject(hh, 500); CloseHandle(hh); }
    WaitForSingleObject(hr, 500);
    CloseHandle(hr);
    CloseHandle(g_port);
    printf("\n已退出。若需把圈数写入行程，请重新连接后发 set 3 <圈数>。\n");
    return 0;
}
