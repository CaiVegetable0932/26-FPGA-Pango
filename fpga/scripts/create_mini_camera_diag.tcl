# Purpose: use the installed PDS project writer, never hand-author .pds grouping.
set project_tcl [file normalize [file join [file dirname [info script]] ../project/mini_camera_diag/mini_camera_diag.tcl]]
tcl2prj -tcl $project_tcl
puts MINI_NATIVE_PROJECT_GENERATED
