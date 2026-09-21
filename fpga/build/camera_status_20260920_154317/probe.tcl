# 用途：使用 PDS 2022.2-SP6.4 原生配置终端扫描本机 JTAG 并读取器件 ID/状态。
# 本脚本不关联位流、不配置 FPGA、不操作 Flash/eFuse，也不复位正在运行的用户逻辑。
# 对应官方 Fabric Configuration 手册 4.5.1/4.5.2；调用方须把工作/日志目录放在 fpga/build。
cfg_set_tcl_break -flag true
puts "JTAG_PROBE_MODE=IDENTIFICATION_ONLY"

# 连接已在专用工作目录启动的同版本本地 JTAG 服务，保留扫描到的真实链信息。
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain

# 仅读取第一个器件的身份与配置状态；由调用方核对链长度和 PG2L100H 型号后才能下载。
cfg_read_device_property -mode 0 -device_index 0
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts "JTAG_PROBE_COMPLETED"
cfg_close
