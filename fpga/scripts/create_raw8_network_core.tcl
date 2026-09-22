# Purpose: ask the installed PDS writer to create the component .pds syntax.
set project_tcl [file normalize [file join [file dirname [info script]] ../project/raw8_network_core/raw8_network_core.tcl]]
tcl2prj -tcl $project_tcl
puts RAW8_NATIVE_COMPONENT_GENERATED
