# Purpose: generate the isolated correction target using the installed native writer.
tcl2prj -tcl [file normalize [file join [file dirname [info script]] ../project/mini_raw8_geometry/mini_raw8_geometry.tcl]]
puts MINI_RAW8_GEOMETRY_NATIVE_PROJECT_GENERATED
