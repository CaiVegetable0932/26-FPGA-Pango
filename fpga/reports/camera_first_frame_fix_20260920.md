# 首帧 DDR 写入故障修复与验证

## 已复现的软件逻辑缺陷

aq_axi_master_256 中写 FIFO 预取停止条件使用 RD_LEN，而非 WR_LEN。启动阶段帧池尚无完整帧，不发起显示读请求，RD_LEN为0；512字节写请求应取16个256位字，旧逻辑却请求17次FIFO读取。第17次若FIFO非空会丢掉下一数据字，可能导致完整帧永远凑不齐。

离线复现证据 fpga/build/camera_startup_audit_20260920/axi_before.log：read_len=0、pops=17、beats=16，触发AXI_WRITE_FAIL。本次将长度来源修正为WR_LEN，保留原生DDR桥接接口和摄像头配置表。

修复后证据 axi_after.log：read_len=0/512/1024三种情况下均pops=16、beats=16；插入WREADY暂停后数据顺序及WLAST检查通过，AXI_WRITE_STARTUP_PASS。尚不涵盖任意突发长度；当前顶层固定16拍。

新增高电平指示：LED3(E18)锁存预热后曾放行像素，LED4(A17)表示完成帧已被显示DMA接纳；保留LED0(PCLK)、LED1(配置中亮/完成灭)、LED2(DDR初始化后心跳)。灯亮不等于图像正确，也不证明持续无丢帧。

帧池回归144项通过；视频回归2帧1843200像素、4319640检查通过；HDMI集成静态测试4项通过。新位流尚待原生构建、时序审核、Flash校验及冷启动实测，不能先写成功结论。

注意：native_20260920_152609_522是修复前启动的仅加指示灯构建，没有烧录，不能作为修复版证据。

## 修复版构建与Flash固化

- 原生构建证据 native_20260920_153204_150：15:32:10至15:37:01，退出码0、错误数0；内部STA All Constraints Met。外部DVP时序仍未签核。
- 已归档SBIT/SFC：fpga/build/camera_first_frame_flash_20260920/，SHA256均为2A52E6E4C15EED0F7D6D8CEF8A829C682D3DD1B4923D2FF5576AE4914819101A。
- 本轮按用户既有授权执行整片擦除12.8秒、写入91.1秒、校验31.5秒；三项原生命令全部成功，NATIVE_EXIT=0，JTAG断开。旧Flash内容被修复镜像替换；此前恢复镜像保留，未操作eFuse/密钥。
- program.log为本次固化证据。已请用户断电重启并反馈LED3/LED4，同时释放Hagibis供采集。当前仍不能宣称摄像头图像已显示或全链路验收完成。
