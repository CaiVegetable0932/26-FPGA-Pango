set fpga_root [file normalize [file join [file dirname [info script]] ..]]
tcl2prj -tcl [file join $fpga_root project pango_video_top pango_video_top.tcl]
# Directory normalization runs after this PDS process exits and releases its
# project file handle. PDS owns every project/IP field and timestamp.
puts "NATIVE_PROJECT_GENERATED [file join $fpga_root project pango_video_top pango_video_top.pds]"
