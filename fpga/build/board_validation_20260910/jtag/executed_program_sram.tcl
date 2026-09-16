# 用途：对已核对为 PG2L100H 的单器件 JTAG 链执行临时 CRAM/SRAM 配置及原生回读校验。
# PANGO_VALIDATION_BITSTREAM 仅由调用进程传入本轮 .sbit 绝对路径，同目录须保留 .smsk。
# 使用 Tcl 原生变量，不使用本版本会漏执行注释后命令的命令行文本占位符替换路径。
# 此脚本会替换当前易失 FPGA 配置，但不包含 Flash、eFuse、密钥或固化命令。
# 前置条件：调用方先完成器件/板卡核对和新鲜构建审计；原生文件匹配失败时必须中止。
set validation_bitstream [file normalize $env(PANGO_VALIDATION_BITSTREAM)]
if {![file exists $validation_bitstream]} { error "Validated bitstream is missing" }
cfg_set_tcl_break -flag true
puts "CONFIGURATION_TARGET=VOLATILE_FPGA_CRAM_ONLY"
cfg_connect -ip 127.0.0.1 -port 65420

# 再次扫描真实链；由工具核对器件与位流目标，禁止以手工添加器件绕过不匹配检查。
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_assign_file -file $validation_bitstream -device_index 0

# 按官方属性位启用关断/ISC 配置及回读；仅作用于 FPGA 配置存储器，不访问启动 Flash。
cfg_set_device_property -device_index 0 -program 3 -readback 3
cfg_program -device_index 0
cfg_verify -device_index 0

# Verify 只比较非 DRM 配置位，不能代替 DDR/RAM 数据测试；随后读取 DONE 与配置错误状态。
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts "SRAM_PROGRAM_AND_VERIFY_COMPLETED"
cfg_close
