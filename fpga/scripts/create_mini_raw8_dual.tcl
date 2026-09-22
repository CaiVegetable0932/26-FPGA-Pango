# Purpose: let the installed PDS native writer generate valid project syntax.
tcl2prj -tcl [file normalize [file join [file dirname [info script]] ../project/mini_raw8_dual/mini_raw8_dual.tcl]]
puts MINI_RAW8_NATIVE_PROJECT_GENERATED
