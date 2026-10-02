/**
 * uart_servo_lite.h 鈥?JOHO 鎬荤嚎鑸垫満 UART 鍗忚灞?(HAL 閫傞厤鐗?
 *
 * ============================================================================
 * 绉绘鎸囧崡 鈥?濡備綍灏嗘椹卞姩杩佺Щ鍒版柊 STM32 椤圭洰
 * ============================================================================
 *
 * 1. 澶嶅埗鏂囦欢
 *    灏嗕互涓?4 涓枃浠跺鍒跺埌鏂伴」鐩殑 Core/Inc 鍜?Core/Src 涓細
 *      ring_buffer.h    鈥?鐜舰缂撳啿鍖哄ご鏂囦欢
 *      ring_buffer.c    鈥?鐜舰缂撳啿鍖哄疄鐜? *      uart_servo_lite.h 鈥?鑸垫満鍗忚灞傚ご鏂囦欢 (鏈枃浠?
 *      uart_servo_lite.c 鈥?鑸垫満鍗忚灞傚疄鐜?(HAL 閫傞厤銆佸崗璁В鏋愩€佷笟鍔?API)
 *    鎵€鏈夊姛鑳芥€т唬鐮侀兘鍦ㄨ繖涓や釜 .c/.h 鏂囦欢瀵逛腑锛屼笉渚濊禆鍏朵粬鑷畾涔夋枃浠躲€? *
 * 2. CubeMX 閰嶇疆 UART
 *    鍦?CubeMX 涓惎鐢ㄤ竴涓?USART/UART 澶栬 (濡?USART3)锛? *      Mode: Asynchronous
 *      Baud Rate: 115200 (涓庤埖鏈烘尝鐗圭巼涓€鑷?
 *      Word Length: 8 Bits, Parity: None, Stop Bits: 1
 *      NVIC Settings: 寮€鍚?USART 鍏ㄥ眬涓柇 (Global Interrupt)
 *    鐢熸垚浠ｇ爜鍚庯紝璁颁笅 HAL 鍙ユ焺鍚?(濡?&huart3)銆? *
 *    [閲嶈] 濡傛灉浣跨敤 STM32F4 浠ュ鐨勭郴鍒楋紝闇€淇敼鏈枃浠堕《閮ㄧ殑 HAL 澶存枃浠跺紩鐢細
 *      #include "stm32f1xx_hal.h"  鈫?鏀逛负瀵瑰簲绯诲垪 (濡?stm32f1xx_hal.h)
 *
 * 3. 淇敼涓插彛鍙ユ焺瀹? *    鍦ㄦ湰鏂囦欢涓壘鍒?SERVO_UART_HANDLE 瀹忥紝鏀逛负浣犲湪 CubeMX 涓厤缃殑 UART 鍙ユ焺锛? *      #define SERVO_UART_HANDLE  &huart3   // 鏀规垚浣犵殑 HAL 鍙ユ焺
 *
 * 4. 纭繚 HAL UART 鎺ユ敹涓柇鍥炶皟姝ｇ‘杞彂
 *    uart_servo_lite.c 宸插疄鐜颁簡 HAL_UART_RxCpltCallback() 寮卞畾涔夊洖璋冿紝
 *    閫氳繃鍏ㄥ眬鎸囬拡 g_activeServo 鑷姩鍒ゆ柇骞惰皟鐢?Servo_UART_RxCallback()銆? *    濡傛灉浣犵殑椤圭洰闇€瑕佽嚜瀹氫箟璇ュ洖璋?(渚嬪澶勭悊澶氫釜 UART)锛岃鍦ㄨ嚜瀹氫箟鍥炶皟涓? *    鎵嬪姩璋冪敤 Servo_UART_RxCallback()锛屽弬鑰冩湰椤圭洰涓殑鍐欐硶銆? *
 * 5. 鍦?main.c 涓皟鐢?API 鍑芥暟
 *    瑙佷笅鏂?"涓昏鍔熻兘鎬у嚱鏁? 涓€鑺傘€? *
 * ============================================================================
 * 涓昏鍔熻兘鎬у嚱鏁?(涓氬姟 API)
 * ============================================================================
 *
 * [鍒濆鍖朷
 *   void Servo_UART_Init(Usart_DataTypeDef *usart, UART_HandleTypeDef *huart)
 *     鍔熻兘: 鍒濆鍖栬埖鏈轰覆鍙ｅ疄渚嬶紝缁戝畾 HAL UART 鍙ユ焺锛屽惎鍔ㄤ腑鏂帴鏀? *     鐢ㄦ硶: Servo_UART_Init(&servoUart, SERVO_UART_HANDLE);
 *
 * [鐘舵€佹煡璇
 *   JOHO_STATUS US_Ping(Usart_DataTypeDef *usart, uint8_t servo_id)
 *     鍔熻兘: Ping 鎸囧畾 ID 鐨勮埖鏈猴紝妫€娴嬪叾鏄惁鍦ㄧ嚎
 *     杩斿洖: 0=鍦ㄧ嚎(SUCCESS), 2=瓒呮椂(TIMEOUT), 6=鏍￠獙閿欒(CHECKSUM_ERROR)
 *     鐢ㄦ硶: if (US_Ping(&servoUart, 1) == JOHO_STATUS_SUCCESS) { ... }
 *
 * [瑙掑害鎺у埗]
 *   void USL_SetServoAngle(Usart_DataTypeDef *usart, uint8_t servo_id,
 *                          float posi, uint16_t interval)
 *     鍔熻兘: 璁剧疆鑸垫満鐩爣瑙掑害浣嶇疆
 *     posi = raw position 0..4095; mechanical degrees depend on the servo model.
 *           interval = 杩愬姩鏃堕棿 (ms)锛屾帶鍒惰埖鏈轰粠褰撳墠浣嶇疆杩愬姩鍒扮洰鏍囩殑鏃堕棿
 *     Example: USL_SetServoAngle(&servoUart, 1, 2048, 1000); // raw 2048, 1 second
 *
 * [浣嶇疆璇诲彇]
 *   uint16_t USL_GETPositionVal(Usart_DataTypeDef *usart, uint8_t servo_id)
 *     鍔熻兘: 璇诲彇鑸垫満褰撳墠瀹為檯浣嶇疆
 *     杩斿洖: 0~4095 (鎴愬姛), 0xFFxx (澶辫触: 0xFFFF - 閿欒鐮?
 *     鐢ㄦ硶: uint16_t pos = USL_GETPositionVal(&servoUart, 1);
 *
 * [鎵煩鎺у埗]
 *   void SET_Torque(Usart_DataTypeDef *usart, uint8_t servo_id, uint8_t isopen)
 *     鍔熻兘: 寮€鍚垨鍏抽棴鑸垫満鎵煩 (涓婄數/鍗稿姏)
 *     鍙傛暟: isopen = 1 寮€鍚壄鐭?涓婄數閿佽酱), 0 鍏抽棴鎵煩(鍙墜鍔ㄨ浆鍔?
 *     鐢ㄦ硶: SET_Torque(&servoUart, 1, 1); // 寮€鍚壄鐭? *
 * [鍘熷鏁版嵁鍙戦€乚
 *   void USL_Send_HEX(Usart_DataTypeDef *usart, uint8_t size, uint8_t *content)
 *     鍔熻兘: 閫氳繃鑸垫満涓插彛鍙戦€佸師濮?HEX 瀛楄妭 (涓嶆坊鍔犲崗璁抚澶?鏍￠獙鍜?
 *
 * ============================================================================
 * 鐘舵€佺爜閫熸煡 (JOHO_STATUS)
 * ============================================================================
 *   0 = SUCCESS              閫氫俊鎴愬姛
 *   1 = FAIL                  鍙戦€?璇诲彇澶辫触
 *   2 = TIMEOUT               绛夊緟瓒呮椂 (鏈€甯歌: 鑸垫満鏈繛鎺?鏈緵鐢?ID閿欒)
 *   3 = WRONG_RESPONSE_HEADER 鍝嶅簲甯уご涓嶅尮閰? *   4 = UNKOWN_US_ID          鏈煡鐨勮埖鏈篒D
 *   5 = SIZE_TOO_BIG          鏁版嵁鍖呰繃澶? *   6 = CHECKSUM_ERROR        鏍￠獙鍜岄敊璇? *   7 = ID_NOT_MATCH          杩斿洖鐨勮埖鏈篒D涓庤姹備笉鍖归厤
 *
 * ============================================================================
 */

#ifndef __UART_SERVO_LITE_H
#define __UART_SERVO_LITE_H

#include "stm32f1xx_hal.h"
#include "ring_buffer.h"

/* ======================== 涓插彛閰嶇疆瀹忥紙澶嶇敤鏃跺彲淇敼锛?======================== */
/* 鑸垫満浣跨敤鐨勪覆鍙?HAL 鍙ユ焺 */
#define SERVO_UART_HANDLE  &huart3

/* 鏀跺彂鐜舰缂撳啿鍖哄ぇ灏?*/
#define SERVO_SEND_BUF_SIZE  128
#define SERVO_RECV_BUF_SIZE  128

/* ======================== 鍗忚鐘舵€佺爜 ======================== */
#define JOHO_STATUS uint8_t
#define JOHO_STATUS_SUCCESS              0  /* 鍙戦€?璇诲彇鎴愬姛 */
#define JOHO_STATUS_FAIL                 1  /* 鍙戦€?璇诲彇澶辫触 */
#define JOHO_STATUS_TIMEOUT              2  /* 绛夊緟瓒呮椂 */
#define JOHO_STATUS_WRONG_RESPONSE_HEADER 3 /* 鍝嶅簲澶撮敊璇?*/
#define JOHO_STATUS_UNKOWN_US_ID         4  /* 鏈煡鐨勮埖鏈篒D */
#define JOHO_STATUS_SIZE_TOO_BIG         5  /* 鏁版嵁鍖呰繃澶?*/
#define JOHO_STATUS_CHECKSUM_ERROR       6  /* 鏍￠獙鍜岄敊璇?*/
#define JOHO_STATUS_ID_NOT_MATCH         7  /* 杩斿洖鐨勮埖鏈篒D涓嶅尮閰?*/

/* ======================== 鍛戒护绫诲瀷 ======================== */
#define CMDType_Ping   1  /* Ping 鐘舵€佹煡璇?*/
#define CMDType_Read   2  /* 璇诲彇鏁版嵁 */
#define CMDType_Write  3  /* 鍐欏叆鏁版嵁 */

/* ======================== 鍗忚甯搁噺 ======================== */
#define JOHO_US_NUM                   254 /* 鑸垫満ID鏈€澶у€?*/

/* 閫氫俊瓒呮椂鏃堕棿 (ms) */
#define JOHO_TIMEOUT_MS               100

/* 鏁版嵁鍖呭抚澶?鈥?Little Endian */
#define JOHO_PACK_REQUEST_HEADER      0xFFFF  /* 鍙戦€佸抚澶?*/
#define JOHO_PACK_RESPONSE_HEADER     0xF5FF  /* 鍝嶅簲甯уご */

/* 鍝嶅簲鏁版嵁鍖呮渶澶ч暱搴?*/
#define JOHO_PACK_RESPONSE_MAX_SIZE   50

/* ======================== 鎺ユ敹鐘舵€佹爣蹇椾綅 ======================== */
#define JOHO_RECV_FLAG_HEADER    0x01  /* 甯уご鎺ユ敹瀹屾垚 */
#define JOHO_RECV_FLAG_US_ID     0x02  /* 鑸垫満ID鎺ユ敹瀹屾垚 */
#define JOHO_RECV_FLAG_SIZE      0x04  /* 鏁版嵁闀垮害鎺ユ敹瀹屾垚 */
#define JOHO_RECV_FLAG_SSTAT     0x06  /* 鐘舵€?鍛戒护鎺ユ敹瀹屾垚鏍囧織浣?*/
#define JOHO_RECV_FLAG_CONTENT   0x08  /* 鏁版嵁鎺ユ敹瀹屾垚 */
#define JOHO_RECV_FLAG_CHECKSUM  0x10  /* 鏍￠獙鍜屾帴鏀跺畬鎴?*/

/* ======================== 鏁版嵁缁撴瀯瀹氫箟 ======================== */

/* 涓插彛鏁版嵁绫诲瀷 鈥?HAL 閫傞厤鐗? * 灏佽 HAL UART 鍙ユ焺鍜屾敹鍙戠幆褰㈢紦鍐插尯
 */
typedef struct {
    UART_HandleTypeDef *huart;                     /* HAL UART 鍙ユ焺 */
    RingBufferTypeDef   sendBuf;                    /* 鍙戦€佺幆褰㈢紦鍐插尯 */
    RingBufferTypeDef   recvBuf;                    /* 鎺ユ敹鐜舰缂撳啿鍖?*/
    uint8_t             sendBufMem[SERVO_SEND_BUF_SIZE]; /* 鍙戦€佺紦鍐插尯鍐呭瓨 */
    uint8_t             recvBufMem[SERVO_RECV_BUF_SIZE]; /* 鎺ユ敹缂撳啿鍖哄唴瀛?*/
} Usart_DataTypeDef;

/* 鏁版嵁鍖呯粨鏋勪綋 */
typedef struct {
    uint16_t header;                               /* 甯уご */
    uint8_t  usId;                                 /* 鑸垫満ID */
    uint8_t  size;                                 /* 鏁版嵁闀垮害 = content + 2 */
    uint8_t  sstat;                                /* 鍙戦€?鍛戒护绫诲瀷 / 鎺ユ敹:鑸垫満鐘舵€?*/
    uint8_t  content[JOHO_PACK_RESPONSE_MAX_SIZE]; /* 鏁版嵁鍐呭 */
    uint8_t  checksum;                             /* 鏍￠獙鍜?*/

    uint8_t  status;                               /* 鎺ユ敹鐘舵€佹爣蹇椾綅 */
} PackageTypeDef;

/* ======================== HAL 閫傞厤灞傚嚱鏁?======================== */

/* 鍒濆鍖栬埖鏈?UART锛堢粦瀹?HAL 鍙ユ焺銆佸垵濮嬪寲鐜舰缂撳啿鍖恒€佸惎鍔ㄤ腑鏂帴鏀讹級 */
void Servo_UART_Init(Usart_DataTypeDef *usart, UART_HandleTypeDef *huart);

/* 灏嗗彂閫佺幆褰㈢紦鍐插尯涓殑鏁版嵁閫氳繃 UART 鍙戦€佸嚭鍘?*/
void Usart_SendAll(Usart_DataTypeDef *usart);

/* Systick 鍊掕鏃跺嚱鏁帮紙鍩轰簬 HAL_GetTick锛?*/
void    SysTick_CountdownBegin(uint32_t ms);
uint8_t SysTick_CountdownIsTimeout(void);
void    SysTick_CountdownCancel(void);

/* UART 鎺ユ敹涓柇鍥炶皟 鈥?灏嗘帴鏀跺埌鐨勫瓧鑺傛帹鍏ユ帴鏀剁幆褰㈢紦鍐插尯
 * 闇€鍦?HAL_UART_RxCpltCallback 涓皟鐢?*/
void Servo_UART_RxCallback(Usart_DataTypeDef *usart);

/* ======================== 鍗忚灞傚嚱鏁?======================== */

/* 鏋勫缓鏁版嵁鍖呭苟鍙戦€?*/
void JOHO_PackageBuild_Send(Usart_DataTypeDef *usart, uint8_t usId,
                            uint8_t size, uint8_t cmdType, uint8_t *content);

/* 鍙戦€佸師濮?HEX 鏁版嵁 */
void USL_Send_HEX(Usart_DataTypeDef *usart, uint8_t size, uint8_t *content);

/* 鎺ユ敹骞惰В鏋愪竴涓暟鎹寘 */
JOHO_STATUS USL_RecvPackage(Usart_DataTypeDef *usart, PackageTypeDef *pkg);

/* 灏?Package 搴忓垪鍖栧啓鍏ョ幆褰㈢紦鍐插尯 */
void JOHO_Package2RingBuffer(PackageTypeDef *pkg, RingBufferTypeDef *ringBuf);

/* 璁＄畻 Package 鏍￠獙鍜?*/
uint8_t JOHO_CalcChecksum(PackageTypeDef *pkg);

/* ======================== 鑸垫満涓氬姟 API ======================== */

/* Ping 鑸垫満 鈥?鐘舵€佹煡璇?*/
JOHO_STATUS US_Ping(Usart_DataTypeDef *usart, uint8_t servo_id);

/* 璁剧疆鑸垫満瑙掑害
 * posi: raw target 0..4095; mechanical degrees depend on the servo model.
 * interval:杩愬姩鏃堕棿 (ms) */
void USL_SetServoAngle(Usart_DataTypeDef *usart, uint8_t servo_id,
                       float posi, uint16_t interval);

/* 璇诲彇鑸垫満褰撳墠浣嶇疆 (杩斿洖鍊? 0~4095, 澶辫触杩斿洖閿欒鐮? */
uint16_t USL_GETPositionVal(Usart_DataTypeDef *usart, uint8_t servo_id);

/* 璁剧疆鑸垫満鎵煩寮€鍏? * isopen: 1=寮€鍚壄鐭? 0=鍏抽棴鎵煩 */
void SET_Torque(Usart_DataTypeDef *usart, uint8_t servo_id, uint8_t isopen);

/* Checked read, with validated response ID/length and explicit servo status. */
JOHO_STATUS USL_ReadRegister(Usart_DataTypeDef *usart, uint8_t id,
                            uint8_t address, uint8_t *data, uint8_t length,
                            uint8_t *servo_status);
JOHO_STATUS USL_ChangeId(Usart_DataTypeDef *usart, uint8_t old_id, uint8_t new_id);
JOHO_STATUS USL_MoveChecked(Usart_DataTypeDef *usart, uint8_t id,
                           uint16_t position, uint16_t interval);
JOHO_STATUS USL_TorqueChecked(Usart_DataTypeDef *usart, uint8_t id, uint8_t enable);

#endif /* __UART_SERVO_LITE_H */

