# 上位机发布验证（2026-11-04）

基于远端 main `152be061` 发布当前上位机源码、测试和文档：龙门架坐标/云台角度点击后等待 3 秒发送，使用点击时参数，支持取消；急停立即发送并撤销待发运动，页面关闭/刷新取消待发运动。同时包含采集与控制/板卡设置布局、主机 CPU 显示、FPGA 串口按 USB 身份保留及历史录像目录保护。双路录屏功能保持撤回状态。

## 本次验证

- `python-tests.json` 保留第一次全量测试的原始结果：193 项，191 项通过，2 项因 PATH 中没有 Node 而报 `FileNotFoundError`，无断言失败。
- 将 `host/build/environment/node/bin` 加入 PATH 后，只重跑上述失败模块；`fisheye-retest.log` 记录 2/2 通过。合并两次运行，193 个测试均有通过记录；没有把第一次结果改写成全绿。
- `frontend-tests.tap`：15 个 Node 前端测试文件全部通过，包含 MCU 2999/3000 ms 发送边界、参数快照、急停/取消/pagehide 撤销及重复点击保护。
- `app.js`、`board-link.js` 的 Node 语法检查和 `git diff --check` 通过。
- 使用项目自带 Python 3.12 和 Node 22。本次未驱动物理 MCU、龙门架或云台，也未重新进行浏览器验收；`../mcu-delay-20261103/` 是保留的前一天浏览器验证证据。

## 复现

在仓库根目录执行：

```sh
export PATH="$PWD/host/build/environment/node/bin:$PATH"
host/build/environment/venv/bin/python -B host/scripts/test.py --report host/reports/host-release-20261104/python-tests.json
PYTHONPATH=host/src host/build/environment/venv/bin/python -B -m unittest discover -s host/tests -p test_fisheye_preview.py -v
node --test host/tests/*.cjs
node --check host/web/app.js
node --check host/web/board-link.js
git diff --check
```

本次提交保留本机运行配置、依赖环境、编译缓存及历史采集数据在本地；未修改 Git 忽略规则。
