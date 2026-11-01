# MCU tool 兼容性修复与验证

针对 `codex/mcu-test-system@22452f36` 的三项兼容性问题，本次完成以下修改：

- 零位操作改为异步：HTTP 返回 pending；后台每约 200 ms 心跳，持续接收原 seq 的最终结果。超过 0.5 s 时只重发原始报文，最多等待 16 s。成功、拒绝、超时未知和断开未知均单独显示；等待时禁止重复零位与竞争运动。
- 解析并校验 EVENT 的 boot/session、长度和连续事件编号；过滤重复/异会话事件，自动 ACK。OPEN 重放的旧事件被消费，只有当前主动发送的 motion_id 才更新运动终态。完成消息仍要求核对真实角度。
- 读取请求在 120 ms 内合并并使用缓存，避免固件 100 ms 查询限流；BUSY 作为流控处理，不关闭串口。缓存数据没有因为 BUSY 被伪装为新数据。
- 页面同步显示异步操作结果，并正确控制按钮可用性；硬件故障提示优先于旧命令消息。打开实际串口前关闭 DTR/RTS，与 MCU tool 一致。后台线程绑定原连接的停止事件，防止重新连接时旧线程继续续租。

这次提交还包含此前仅留在工作区的 MCU 通道基础代码、Web 接口、页面与协议测试，保证从 main 检出后具备完整运行依赖。原有 3° 目标步长与毫度反馈精度保持一致；XYZ、五轴联动、行程标定仍未实现。

## 验证

| 检查 | 结果 |
| --- | --- |
| MCU 单元测试 | 13/13，通过分片、CRC、上下文、ACK/重放、零位生命周期、重发、BUSY、DTR/RTS 与目标范围验证 |
| Web 集成测试 | 32/32，含真实回环 HTTP、令牌保护、异步零位最终应答及断开 |
| 页面控制器测试 | pending/completed/failed 显示、按钮限制、轮询、精细角度与断开通过 |
| JavaScript 语法 | app.js 通过 |
| 固件异步零位 | 模拟时间 5.6 s，28 次心跳，completed、fault=0 |
| 固件连续运动 | 100 次，200 条 EVENT 全部 ACK，fault=0 |
| 固件旧事件重放 | 20 条旧事件正确消费，新运动结果未被旧事件冒充 |
| 固件查询限流 | 20 ms 内重复读取合并，强制 BUSY 仍保持连接 |
| 固件缓冲边界 | 未 ACK 第 65 条仍触发 fault=9，证明没有绕过固件故障保护 |

固件交叉检查使用 `reference/` 中原样复制的 `f4_link.c`、`wire.c`；只替代硬件和时钟。C/Python 共用虚拟单调时钟，零位检查运行的控制逻辑与后台轮询相同，不需要实际等待 5.6 秒。`results.json`、`provenance.json` 保存修复前证据；`results-after.json`、`validation.json` 保存修复后结果。

在仓库根目录复现：

```sh
PYTHONPATH=host/src host/build/environment/venv/bin/python -B -m unittest discover -s host/tests -p 'test_mcu*.py' -v
PYTHONPATH=host/src host/build/environment/venv/bin/python -B -m unittest discover -s host/tests -p test_webui.py
host/build/environment/node/bin/node --check host/web/app.js
host/build/environment/node/bin/node host/tests/test_mcu_ui.cjs
python3 -B host/reports/mcu-tool-compatibility-20261101/check_regressions.py
```

Web 集成测试需要本机回环套接字权限；沙箱内若报 Operation not permitted，应在允许本地套接字的环境执行。

本次未连接实物 MCU、未驱动电机，未宣称实板验收完成。代码发布后，正在运行的旧上位机进程需要重启并刷新页面才能加载新后台。测试报告中的动态库在目标机器由脚本重新编译，不依赖预编译文件的架构。
