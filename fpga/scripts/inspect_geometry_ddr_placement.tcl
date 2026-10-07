# Purpose: export actual DDR placement from an already routed DB in an isolated
# directory. No compile, map, PNR, STA, project mutation or hardware operation.
# PDS 2022.2-SP6.4 native generate_constraint help was checked. Its Tcl parser
# evaluates ordinary file operations before queued native commands: do not
# create a post-export manifest here. The caller must await native success and
# pass actual_ddr.pcf plus the current PNR .netlist to the PowerShell verifier.
# No gen_netlist: simulation Verilog is not the required native GOP type dump.
# Directory isolation, existence/freshness guards and source hashes belong in
# the invoking PowerShell wrapper, because PDS evaluates this Tcl twice.
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
set_dir -impl_directory $env(GEOMETRY_AUDIT_IMPL)
# Export the complete PHY so critical37 includes DFI registers as well as the
# data slice. This remains read-only; the verifier restricts accepted leaves.
generate_constraint -db $env(GEOMETRY_AUDIT_DB) -devmap_db $env(GEOMETRY_AUDIT_MAP) -pcf $env(GEOMETRY_AUDIT_PCF) -module_inst {I_ips_ddr_top/u_ddrphy_top} -file [file join $env(GEOMETRY_AUDIT_IMPL) actual_ddr.pcf]
# A marker alone is insufficient: the wrapper must require exit code zero and
# the newly generated output, then compute/check before/after hashes outside Tcl.
puts GEOMETRY_DDR_PLACEMENT_EXPORTED
