# 用途：保留本次临时 CRAM/SRAM 配置流程；因实板出现过温标志，入口当前强制停用。
# 安全暂停：2026-09-10 下载后状态 0x0810FC80 的 over_temp=1，原因尚未确认。
# 此守卫必须在读取路径或连接 JTAG 之前失败；排除供电/散热/状态异常前禁止移除并重试。
error "SRAM programming is suspended after over_temp=1; review the board validation report before any new download."

# 当前入口不保留任何可执行的连接/下载/校验命令，即使调用器忽略错误也不会接触板卡。
# 实际执行版本仅作为证据保存在本轮 jtag/executed_program_sram.tcl，禁止直接重新运行。
