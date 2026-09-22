# RAW8 双路候选：启动与预览

适用 FPGA top：`mini_raw8_dual`，分支 `codex/fpga-raw8-dual-output`。构建/位流状态见 [FPGA 候选报告](../../fpga/reports/raw8_board_candidate_20260922.md)。本说明不是已经烧录或实测的记录。

## 两路含义

- 网口：J10/CAM1 的 1920×1080 RAW8，PRAW V1，每帧 1482 包；描述符 0x38574152，参数版本 1，Bayer 配置 4（物理相位未验证）。
- HDMI：同一 RAW 帧池的独立读端，1080p30 栅格、RAW 采样复制到 RGB。不是 Y8、ISP S1 或矫正结果；两路不按到达顺序配对。
- 板端不含合成图替代源。来源仍需上板遮挡确认；启动 ACK 不等于来源证明。

## 冷启动后的操作

1. 确认烧录/回读校验通过并冷启动，J10 摄像头、HDMI/Hagibis、板载网口、CP2102 连接正确；后续烧录以 Flash 固化为准。本轮生成版本不自动烧录。
2. 重新核对 PC 网卡 IP/MAC 和 COM 号。每次冷启动重新生成 epoch；不要复用以前的 TEST boot.json 或旧 RAW8 boot.json。板端不实现 ARP、DHCP、ping，必须显式提供双方单播地址。
3. 在仓库根目录离线生成新目录（把示例地址替换为本次确认的地址）：

```powershell
python -B host/scripts/prepare_raw8_boot.py --source-mac 02:00:00:00:00:01 --peer-mac 20:7B:D2:C0:29:96 --source-ip 169.254.81.187 --peer-ip 169.254.81.186 --out host/config/raw8-new-cold-boot
```

4. 先启动 host Web 工作台，在连接设置选择硬件未验证模式，按新 `receiver.json` 填入设备/epoch/IP/端口、1920×1080、Bayer=4 和接收缓冲 8388608，再开始网络接收。界面默认 RAW 灰阶；不要点“开始模拟”。Web 不会自动下发串口配置。
5. 使用 PowerShell 7 发送一次 RAW8 启动配置（确实操作串口；仅在上板测试时执行）：

```powershell
./host/scripts/comms_uart.ps1 -Action Boot -Profile RAW8 -Port COM15 -BootJson host/config/raw8-new-cold-boot/boot.json -Out host/reports/raw8-new-cold-boot/boot.json
```

脚本检查固定 CP2102 物理身份、CRC、命令 0x71、ACK ASCII `RAW8` 和 epoch 回显。0x70/TEST 会被新镜像拒绝。配置锁定直到复位，复位前勿重新发送另一个 epoch。

6. HDMI 输入只能选择 Hagibis 且 VID_1DE1&PID_F105/唯一物理路径核对通过的设备，不能回退到电脑摄像头。协商到的采集分辨率/帧率与板端 HDMI 输出分开记录。其他程序必须释放采集卡。
7. 遮住/放开 J10 镜头，分别保存两路证据并核对变化。HDMI source_frame_id 保持 null/unverified；原始 `.raw` 与元数据归 host/data，PNG 是派生可视化。当前固定曝光/增益只是首板参数。

若只做网络统计，可替代 Web 接收端运行（两者不要同时占用 UDP 50000）：

```powershell
python -B host/scripts/praw.py receive --config host/config/raw8-new-cold-boot/receiver.json --seconds 30
```

以上命令不修改防火墙、系统环境或网卡地址。原始数据未收到时，先检查 LED/RAW8 ACK/网卡链路，不用软件模拟流替代。

## LED 和故障边界

LED0：27 MHz 心跳；LED1：摄像头配置及回读完成；LED2：PHY 配置完成且链路就绪；LED3：至少发布过一个几何合法且写栅栏完成的 RAW 帧；LED4：传感器、PHY、内存协议/队列或网络故障。

LED3 是粘性“曾有有效帧”状态，不是持续帧率证明。HDMI 欠载另由 MCU status bit10 报告，不能仅凭 LED4 熄灭验收；bit8 为 sensor_ready，bit9 为 published。网络错误会排空当前读槽并停发新帧，需定位后复位；摄像头几何坏帧丢弃，不发布不补零。

RGMII 使用独立以太网 PLL 和整包跨时钟 FIFO。桥接器输入溢出/错误或读端异常也会置 LED4 与 status bit7，停止新帧发送；不能靠重新发送 boot 配置清除，需先定位再执行板卡复位。两侧 FIFO 会一起复位，不保留半包。
