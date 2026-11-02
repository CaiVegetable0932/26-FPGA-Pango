# MCU 分支合并验证

日期：2026-11-02。

将远端 `codex/mcu-test-system` 的 `22452f36dae80ebac5b5386a60a2e92481862b0e` 合并到 `main` 的 `9ec3c07dd804c66e313ab39768e2d92f4ed45fed`，纳入 10 个源分支提交。在独立工作区执行，原工作区的设备配置、测试报告及未跟踪文件不参与提交。

## 合并处理

- 协议向量测试同时检查 host 独立 fixture 和 MCU C 生成的 `mcu/tests/vectors.json`，解决路径冲突。
- 接口方案保留源分支新增的历史说明及新接口文档链接。
- 修正既有启动迁移测试：复制 `host/src` 顶层 Python 模块，确保隔离目录包含 `mcu_pose_v2.py`。
- MCU 已跟踪文件与源分支完全一致，FPGA 文件与合并前 main 完全一致。保留源分支已有文件迁移、构建产物和忽略规则。

## 软件验证

- 使用本机项目 Python 3.12 环境及 Node，主机回归 **180/180 通过**，详见 `host-tests.json`。测试使用本机 HTTP/UDP 套接字，首次沙箱权限错误不作为代码失败；最终结果来自允许本机套接字的运行。
- 按 `mcu/scripts/test.ps1` 的 10 组源文件、包含目录和严格 GCC 参数，在 Linux ARM64 运行原生离线 C 测试：**5 组通过、5 组失败**，详见 `mcu-tests.json`。
- 通过：wire、mpu6050、gimbal、console、servo。
- 失败：pose 的 `!p.source` 旧断言；gateway、f1_link、d36a、old_main 的模拟接口未覆盖当前 DMA、GPIO、时钟等固件依赖，另有严格编译的未使用函数诊断。MCU 源码和测试与源分支逐文件一致，这些失败不是合并冲突解决引入；本次未修改这些源分支代码。
- C 向量生成器成功，生成内容与已跟踪 `mcu/tests/vectors.json` 一致。
- 两处冲突解决及启动测试改动的空白检查通过。整体差异检查仍报告源分支既有空白问题（包括已跟踪 CMake 构建输出），未批量改写源分支产物。
- 本机没有 `arm-none-eabi-gcc`，未重编译 MCU 目标固件；未烧录设备、发送实际运动指令或执行硬件验收。

本记录证明合并结果与软件检查范围，不表示 MCU 全部回归或整机硬件验收通过。
