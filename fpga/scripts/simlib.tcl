# Official compile_simlib API, PDS User Guide p.255 / Simulation Guide p.8-9.
compile_simlib -Simulator {ModelSim Simulator} -family {Logos2} -language Verilog -library ALL -simulator_exec_path $env(FLOW_MODELSIM_BIN) -directory $env(FLOW_SIMLIB_DIR)
puts "FLOW_SIMLIB_COMMAND_DONE"
