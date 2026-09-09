# PDS 2022.2-SP6.4 native project generation, including file/IP timestamps.
set fpga_root [file normalize [file join [file dirname [info script]] ..]]
tcl2prj -tcl [file join $fpga_root project pango_video_top pango_video_top.tcl]

# The 2022.2-SP6.4 converter leaves prj_impl_dir at "." even when the input
# contains set_dir. Adjust only this project-directory option after native
# serialization; all file/IP grammar and timestamps remain tool-generated.
set project_file [file join $fpga_root project pango_video_top pango_video_top.pds]
set input [open $project_file r]
set data [read $input]
close $input
set old {(_option prj_impl_dir (_string "."))}
set replacement {(_option prj_impl_dir (_string "../../build/pango_video_top"))}
if {[string first $old $data] < 0} {
    error "Unexpected native project format: prj_impl_dir was not found"
}
set output [open $project_file w]
puts -nonewline $output [string map [list $old $replacement] $data]
close $output
