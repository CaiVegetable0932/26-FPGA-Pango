# Purpose: let the installed native writer own .pds syntax and project fields.
set project_tcl [file normalize [file join [file dirname [info script]] ../project/fpga_comms/fpga_comms.tcl]]
tcl2prj -tcl $project_tcl
puts FPGA_COMMS_NATIVE_PROJECT_GENERATED
