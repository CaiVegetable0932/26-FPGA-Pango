# Purpose: PDS native writer owns every .pds grouping and generated option.
tcl2prj -tcl [file normalize [file join [file dirname [info script]] ../project/mini_comms_bringup/mini_comms_bringup.tcl]]
puts MINI_COMMS_NATIVE_PROJECT_GENERATED
