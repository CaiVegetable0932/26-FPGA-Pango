/**
 * uart_servo_lite.c
 * JOHO 总线舵机 UART 协议层 (HAL 适配版)
 *
 * 本文件实现了：
 * 1. HAL 适配层：UART 收发、Systick 倒计时、中断回调
 * 2. 协议层：数据包构建/解析/校验
 * 3. 业务层：Ping、角度设置/读取、扭矩控制
 */

#include "uart_servo_lite.h"
#include "host_console.h"
#include <string.h>

/* ======================== HAL 适配层 — 全局变量 ======================== */

/* 当前激活的舵机串口实例（用于中断回调分发） */
static Usart_DataTypeDef *g_activeServo = NULL;

/* 单字节接收缓冲（HAL_UART_Receive_IT 使用） */
static uint8_t rxByte;
static HAL_StatusTypeDef lastTransmitStatus = HAL_OK;

/* Systick 倒计时变量 */
static uint32_t countdownStart  = 0;
static uint32_t countdownMs     = 0;
static uint8_t  countdownActive = 0;

/* ======================== HAL 适配层 — 初始化 ======================== */

/**
 * @brief  初始化舵机 UART 实例
 * @param  usart 舵机串口实例指针
 * @param  huart HAL UART 句柄（如 &huart6）
 */
void Servo_UART_Init(Usart_DataTypeDef *usart, UART_HandleTypeDef *huart)
{
    usart->huart = huart;

    /* 初始化收发环形缓冲区（容量 = 数组大小 - 1） */
    RingBuffer_Init(&usart->sendBuf, SERVO_SEND_BUF_SIZE - 1, usart->sendBufMem);
    RingBuffer_Init(&usart->recvBuf, SERVO_RECV_BUF_SIZE - 1, usart->recvBufMem);

    /* 注册全局指针，供中断回调使用 */
    g_activeServo = usart;

    /* 启动 UART 单字节中断接收 */
    HAL_UART_Receive_IT(huart, &rxByte, 1);
}

/* ======================== HAL 适配层 — UART 发送 ======================== */

/**
 * @brief  将发送环形缓冲区中的数据通过 HAL UART 阻塞发送
 *         发送完成后重置发送缓冲区
 * @param  usart 舵机串口实例指针
 */
void Usart_SendAll(Usart_DataTypeDef *usart)
{
    uint16_t len = RingBuffer_GetByteUsed(&usart->sendBuf);
    if (len == 0) return;

    /* 从环形缓冲区顺序读出到临时线性缓冲区 */
    uint8_t temp[SERVO_SEND_BUF_SIZE];
    uint16_t head = usart->sendBuf.head;
    for (uint16_t i = 0; i < len; i++) {
        head = (head + 1) % usart->sendBuf.size;
        temp[i] = usart->sendBuf.buffer[head];
    }

    /* 重置发送缓冲区 */
    RingBuffer_Reset(&usart->sendBuf);

    /* 阻塞发送（超时 100ms，足够 128 字节 @115200） */
    lastTransmitStatus = HAL_UART_Transmit(usart->huart, temp, len, 100);
}

/* ======================== HAL 适配层 — Systick 倒计时 ======================== */

/**
 * @brief  开始倒计时
 * @param  ms 倒计时毫秒数
 */
void SysTick_CountdownBegin(uint32_t ms)
{
    countdownStart  = HAL_GetTick();
    countdownMs     = ms;
    countdownActive = 1;
}

/**
 * @brief  检查倒计时是否超时
 * @retval 0 未超时 / 1 已超时
 */
uint8_t SysTick_CountdownIsTimeout(void)
{
    if (!countdownActive) return 1;
    return ((HAL_GetTick() - countdownStart) >= countdownMs);
}

/**
 * @brief  取消倒计时（提前结束时调用）
 */
void SysTick_CountdownCancel(void)
{
    countdownActive = 0;
}

/* ======================== HAL 适配层 — UART 接收中断 ======================== */

/**
 * @brief  UART 接收中断回调 — 将接收字节推入环形缓冲区
 * @param  usart 舵机串口实例指针
 *
 * 在 HAL_UART_RxCpltCallback 中调用此函数，
 * 然后重新启动下一次单字节中断接收。
 */
void Servo_UART_RxCallback(Usart_DataTypeDef *usart)
{
    if (usart && usart->huart) {
        RingBuffer_Push(&usart->recvBuf, rxByte);
        HAL_UART_Receive_IT(usart->huart, &rxByte, 1);
    }
}

/**
 * @brief  重写 HAL 弱定义回调 — 判断是否属于舵机 UART
 *
 * 如果项目中有其他 UART 也需要中断接收，可在该回调中
 * 增加 else if 分支处理。
 */
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart)
{
    if (g_activeServo && huart == g_activeServo->huart) {
        Servo_UART_RxCallback(g_activeServo);
    } else {
        Host_Console_RxCpltCallback(huart);
    }
}

/* ======================== 协议层 — 数据包构建 ======================== */

/**
 * @brief  构建数据包并发送
 *
 * 数据包结构：[帧头 2B][ID 1B][长度 1B][命令类型 1B][数据 NB][校验和 1B]
 * 长度 = 命令类型(1) + 数据(N) + 校验和(1) = 数据字节数 + 2
 *
 * @param  usart   舵机串口实例
 * @param  usId    舵机 ID
 * @param  size    长度字段（命令类型 + 数据内容 + 校验和）
 * @param  cmdType 命令类型 (CMDType_Ping / Read / Write)
 * @param  content 数据内容指针
 */
void JOHO_PackageBuild_Send(Usart_DataTypeDef *usart, uint8_t usId,
                            uint8_t size, uint8_t cmdType, uint8_t *content)
{
    PackageTypeDef pkg;

    /* 帧头 */
    pkg.header = JOHO_PACK_REQUEST_HEADER;
    /* 舵机 ID */
    pkg.usId = usId;
    /* 数据长度 */
    pkg.size = size;
    /* 命令类型 */
    pkg.sstat = cmdType;
    /* 数据内容（跳过 sstat 和 checksum 占位，实际写入 size-2 字节） */
    if (size > 2) {
        for (int i = 0; i < size - 2; i++) {
            pkg.content[i] = content[i];
        }
    }

    /* 将 Package 序列化到发送环形缓冲区 */
    JOHO_Package2RingBuffer(&pkg, &usart->sendBuf);

    /* 通过串口发送 */
    Usart_SendAll(usart);
}

/* ======================== 协议层 — 原始 HEX 发送 ======================== */

/**
 * @brief  发送原始 HEX 字节数组（不添加协议帧头/校验和）
 */
void USL_Send_HEX(Usart_DataTypeDef *usart, uint8_t size, uint8_t *content)
{
    RingBuffer_WriteByteArray(&usart->sendBuf, content, size);
    Usart_SendAll(usart);
}

/* ======================== 协议层 — 数据包接收与解析 ======================== */

/**
 * @brief  从接收环形缓冲区解析一个响应数据包（状态机方式）
 *
 * 响应帧结构：[帧头 0xF5FF 2B][ID 1B][长度 1B][状态/命令 1B][数据 NB][校验和 1B]
 *
 * @param  usart 舵机串口实例
 * @param  pkg   输出参数 — 解析后的数据包
 * @retval JOHO_STATUS_SUCCESS 成功 / 其他值 错误码
 */
JOHO_STATUS USL_RecvPackage(Usart_DataTypeDef *usart, PackageTypeDef *pkg)
{
    pkg->status = 0;            /* 状态机初始化 */
    uint8_t  bIdx   = 0;        /* 数据内容字节索引 */
    uint16_t header = 0;        /* 帧头组装变量 */

    /* 开始超时倒计时 */
    SysTick_CountdownBegin(JOHO_TIMEOUT_MS);

    while (!SysTick_CountdownIsTimeout()) {

        /* 没有新数据时继续等待 */
        if (RingBuffer_GetByteUsed(&usart->recvBuf) == 0) {
            continue;
        }

        if (pkg->status == JOHO_RECV_FLAG_CONTENT) {
            /* ----- 数据内容已接收完毕，接收校验和 ----- */
            pkg->checksum = RingBuffer_ReadByte(&usart->recvBuf);
            pkg->status = pkg->status | JOHO_RECV_FLAG_CHECKSUM;

            if (JOHO_CalcChecksum(pkg) != pkg->checksum) {
                SysTick_CountdownCancel();
                return JOHO_STATUS_CHECKSUM_ERROR;
            } else {
                SysTick_CountdownCancel();
                return JOHO_STATUS_SUCCESS;
            }

        } else if (pkg->status == JOHO_RECV_FLAG_SSTAT) {
            /* ----- 状态已接收，接收数据内容 ----- */
            pkg->content[bIdx] = RingBuffer_ReadByte(&usart->recvBuf);
            bIdx++;
            if (bIdx == (pkg->size - 2)) {
                pkg->status = JOHO_RECV_FLAG_CONTENT;
            }

        } else if (pkg->status == JOHO_RECV_FLAG_SIZE) {
            /* ----- 长度已接收，接收状态/命令字节 ----- */
            pkg->sstat = RingBuffer_ReadByte(&usart->recvBuf);
            pkg->status = JOHO_RECV_FLAG_SSTAT;

            if ((pkg->size - 2) == 0) {
                /* 无数据内容，直接进入校验和状态 */
                pkg->status = JOHO_RECV_FLAG_CONTENT;
            }

        } else if (pkg->status == JOHO_RECV_FLAG_US_ID) {
            /* ----- ID 已接收，接收数据长度 ----- */
            pkg->size = RingBuffer_ReadByte(&usart->recvBuf);

            /* 检查长度合法性 */
            if (pkg->size < 2U || pkg->size > (JOHO_PACK_RESPONSE_MAX_SIZE - 5)) {
                SysTick_CountdownCancel();
                return JOHO_STATUS_SIZE_TOO_BIG;
            }
            pkg->status = JOHO_RECV_FLAG_SIZE;

        } else if (pkg->status == JOHO_RECV_FLAG_HEADER) {
            /* ----- 帧头已接收，接收舵机 ID ----- */
            pkg->usId = RingBuffer_ReadByte(&usart->recvBuf);

            /* 检查 ID 合法性 */
            if (pkg->usId > JOHO_US_NUM) {
                SysTick_CountdownCancel();
                return JOHO_STATUS_UNKOWN_US_ID;
            }
            pkg->status = JOHO_RECV_FLAG_US_ID;

        } else {
            /* ----- 初始状态：接收并验证帧头 0xF5FF ----- */
            if (header == 0) {
                /* 接收帧头第一个字节 */
                header = RingBuffer_ReadByte(&usart->recvBuf);
                if (header != (JOHO_PACK_RESPONSE_HEADER & 0xFF)) {
                    header = 0;   /* 首字节不匹配，丢弃 */
                }
            } else if (header == (JOHO_PACK_RESPONSE_HEADER & 0xFF)) {
                /* 接收帧头第二个字节 */
                header = header | (RingBuffer_ReadByte(&usart->recvBuf) << 8);
                if (header != JOHO_PACK_RESPONSE_HEADER) {
                    header = 0;   /* 第二字节不匹配，丢弃 */
                } else {
                    pkg->header = header;
                    pkg->status = JOHO_RECV_FLAG_HEADER;
                }
            } else {
                header = 0;
            }
        }
    }

    /* 超时 */
    return JOHO_STATUS_TIMEOUT;
}

/* ======================== 协议层 — 数据包序列化 ======================== */

/**
 * @brief  将 Package 序列化写入环形缓冲区（自动计算校验和）
 *
 * 写入顺序：[帧头 2B][ID 1B][长度 1B][状态/命令 1B][数据 NB][校验和 1B]
 */
void JOHO_Package2RingBuffer(PackageTypeDef *pkg, RingBufferTypeDef *ringBuf)
{
    uint8_t checksum;

    /* 帧头（2字节，不参与校验和计算） */
    RingBuffer_WriteUShort(ringBuf, pkg->header);
    /* 舵机 ID */
    RingBuffer_WriteByte(ringBuf, pkg->usId);
    /* 数据长度 */
    RingBuffer_WriteByte(ringBuf, pkg->size);
    /* 状态/命令类型 */
    RingBuffer_WriteByte(ringBuf, pkg->sstat);
    /* 数据内容（长度 = size - 1，再减去内容后的 checksum 1 字节位置 = size - 2） */
    if (pkg->size > 1) {
        RingBuffer_WriteByteArray(ringBuf, pkg->content, pkg->size - 2);
    }
    /* 计算校验和（从第3字节开始，即跳过帧头） */
    checksum = RingBuffer_GetChecksum(ringBuf);
    /* 校验和 */
    RingBuffer_WriteByte(ringBuf, checksum);
}

/* ======================== 协议层 — 校验和计算 ======================== */

/**
 * @brief  计算 Package 的校验和
 *
 * 将 Package 序列化到临时 RingBuffer，
 * 读取自动计算出的校验和值。
 */
uint8_t JOHO_CalcChecksum(PackageTypeDef *pkg)
{
    uint8_t checksum;
    RingBufferTypeDef ringBuf;
    uint8_t pkgBuf[JOHO_PACK_RESPONSE_MAX_SIZE + 1];

    RingBuffer_Init(&ringBuf, JOHO_PACK_RESPONSE_MAX_SIZE, pkgBuf);
    JOHO_Package2RingBuffer(pkg, &ringBuf);

    /* 校验和位于缓冲区最后一个有效字节 */
    checksum = RingBuffer_GetValueByIndex(&ringBuf,
                RingBuffer_GetByteUsed(&ringBuf) - 1);
    return checksum;
}

/* ======================== 舵机业务 API ======================== */

/**
 * @brief  Ping 舵机 — 查询舵机是否在线
 * @param  usart    舵机串口实例
 * @param  servo_id 舵机 ID
 * @retval JOHO_STATUS_SUCCESS 在线 / 其他 离线或错误
 */
JOHO_STATUS US_Ping(Usart_DataTypeDef *usart, uint8_t servo_id)
{
    uint8_t statusCode;
    uint8_t echoServoId;

    /* 发送 Ping：长度=2，命令和校验和，无额外数据。 */
    JOHO_PackageBuild_Send(usart, servo_id, 2, CMDType_Ping, NULL);

    /* 接收响应 */
    PackageTypeDef pkg;
    statusCode = USL_RecvPackage(usart, &pkg);

    if (statusCode == JOHO_STATUS_SUCCESS) {
        echoServoId = (uint8_t)pkg.usId;
        if (echoServoId != servo_id) {
            return JOHO_STATUS_ID_NOT_MATCH;
        }
    }
    return statusCode;
}

/**
 * @brief  设置舵机角度位置
 * @param  usart    舵机串口实例
 * @param  servo_id 舵机 ID
 * @param  posi     目标原始位置 (0~4095，机械角度依舵机型号而定)
 * @param  interval 运动时间 (ms)
 *
 * 发送示例：FF FF 01 07 03 2A 00 00 03 E8 DF
 */
void USL_SetServoAngle(Usart_DataTypeDef *usart, uint8_t servo_id,
                       float posi, uint16_t interval)
{
    /* 位置范围限制 */
    if (posi > 4095) posi = 4095;
    if (posi < 0)    posi = 0;

    uint16_t posit = (uint16_t)posi;
    uint8_t content[5];

    /* 写入角度命令 0x2A */
    content[0] = 0x2A;
    /* 目标位置 (大端序) */
    content[1] = (posit >> 8) & 0xFF;
    content[2] =  posit       & 0xFF;
    /* 运动时间 (大端序) */
    content[3] = (interval >> 8) & 0xFF;
    content[4] =  interval       & 0xFF;

    /* 长度=命令(1)+地址/位置/时间数据(5)+校验和(1)=7。 */
    JOHO_PackageBuild_Send(usart, servo_id, 7, CMDType_Write, content);
}

/**
 * @brief  读取舵机当前位置
 * @param  usart    舵机串口实例
 * @param  servo_id 舵机 ID
 * @retval 0~4095 位置值 / 0xFFFF~ 减去错误码 (失败时)
 */
uint16_t USL_GETPositionVal(Usart_DataTypeDef *usart, uint8_t servo_id)
{
    uint16_t value = 0xFFFF;
    uint8_t statusCode;
    uint8_t content[2];

    /* 读取位置命令 0x38 0x02 */
    content[0] = 0x38;
    content[1] = 0x02;

    /* 发送读取命令 */
    JOHO_PackageBuild_Send(usart, servo_id, 4, CMDType_Read, content);

    /* 接收响应 */
    PackageTypeDef pkg;
    statusCode = USL_RecvPackage(usart, &pkg);

    if (statusCode == JOHO_STATUS_SUCCESS) {
        /* 位置值：大端序 2 字节 */
        value = ((uint16_t)pkg.content[0] << 8) | pkg.content[1];
    } else {
        value = value - statusCode;
    }
    return value;
}

/**
 * @brief  设置舵机扭矩开关
 * @param  usart    舵机串口实例
 * @param  servo_id 舵机 ID
 * @param  isopen   1=开启扭矩（上电）, 0=关闭扭矩（卸力）
 *
 * 发送示例：FF FF 01 04 03 28 01 CE  (开启扭矩)
 *           FF FF 01 04 03 28 00 CF  (关闭扭矩)
 */
void SET_Torque(Usart_DataTypeDef *usart, uint8_t servo_id, uint8_t isopen)
{
    uint8_t content[2];

    content[0] = 0x28;           /* 扭矩控制命令 */
    content[1] = (isopen != 0) ? 0x01 : 0x00;  /* 1=开启, 0=关闭 */

    JOHO_PackageBuild_Send(usart, servo_id, 4, CMDType_Write, content);
}

JOHO_STATUS USL_ReadRegister(Usart_DataTypeDef *usart, uint8_t id,
                            uint8_t address, uint8_t *data, uint8_t length,
                            uint8_t *servo_status)
{
    uint8_t request[2] = {address, length};
    uint32_t started;
    PackageTypeDef pkg;
    JOHO_STATUS result;
    if (id < 1U || id > 250U || !data || length < 1U || length > 40U) {
        return JOHO_STATUS_FAIL;
    }
    HAL_Delay(5U); /* Let preceding write acknowledgements finish. */
    uint32_t mask = __get_PRIMASK();
    __disable_irq();
    RingBuffer_Reset(&usart->recvBuf);
    __set_PRIMASK(mask);
    JOHO_PackageBuild_Send(usart, id, 4U, CMDType_Read, request);
    if (lastTransmitStatus != HAL_OK) {
        return JOHO_STATUS_FAIL;
    }
    started = HAL_GetTick();
    do {
        memset(&pkg, 0, sizeof(pkg));
        result = USL_RecvPackage(usart, &pkg);
        if (result != JOHO_STATUS_SUCCESS) {
            return result;
        }
        if (pkg.usId == id && pkg.size == length + 2U) {
            memcpy(data, pkg.content, length);
            if (servo_status) {
                *servo_status = pkg.sstat;
            }
            return JOHO_STATUS_SUCCESS;
        }
    } while (HAL_GetTick() - started < JOHO_TIMEOUT_MS);
    return JOHO_STATUS_ID_NOT_MATCH;
}

JOHO_STATUS USL_ChangeId(Usart_DataTypeDef *usart, uint8_t old_id, uint8_t new_id)
{
    uint8_t request[2] = {0x05U, new_id};
    uint8_t readback, servoStatus;
    if (old_id < 1U || old_id > 250U || new_id < 1U || new_id > 250U) {
        return JOHO_STATUS_FAIL;
    }
    JOHO_PackageBuild_Send(usart, old_id, 4U, CMDType_Write, request);
    if (lastTransmitStatus != HAL_OK) {
        return JOHO_STATUS_FAIL;
    }
    HAL_Delay(100U);
    JOHO_STATUS status = USL_ReadRegister(usart, new_id, 0x05U, &readback, 1U,
                                         &servoStatus);
    if (status == JOHO_STATUS_SUCCESS && readback != new_id) {
        return JOHO_STATUS_ID_NOT_MATCH;
    }
    if (status == JOHO_STATUS_SUCCESS && servoStatus != 0U) {
        return JOHO_STATUS_FAIL;
    }
    return status;
}

JOHO_STATUS USL_MoveChecked(Usart_DataTypeDef *usart, uint8_t id,
                           uint16_t position, uint16_t interval)
{
    if (id < 1U || id > 250U || position > 4095U || interval == 0U) {
        return JOHO_STATUS_FAIL;
    }
    USL_SetServoAngle(usart, id, (float)position, interval);
    return lastTransmitStatus == HAL_OK ? JOHO_STATUS_SUCCESS : JOHO_STATUS_FAIL;
}

JOHO_STATUS USL_TorqueChecked(Usart_DataTypeDef *usart, uint8_t id, uint8_t enable)
{
    if (id < 1U || id > 250U || enable > 1U) {
        return JOHO_STATUS_FAIL;
    }
    SET_Torque(usart, id, enable);
    return lastTransmitStatus == HAL_OK ? JOHO_STATUS_SUCCESS : JOHO_STATUS_FAIL;
}

void HAL_UART_ErrorCallback(UART_HandleTypeDef *huart)
{
    if (g_activeServo && huart == g_activeServo->huart) {
        HAL_UART_Receive_IT(huart, &rxByte, 1U);
    } else {
        Host_Console_ErrorCallback(huart);
    }
}
