# Purpose: standalone installed-PDS elaboration/synthesis of formal DMA blocks.
# Unit tops have abstract UI ports, no physical pin/PnR or board timing claim.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$LicenseFile='',
 [string[]]$Units=@('ddr_native_dma','dma_pixel_pack','dma_byte_unpack','dma_row_plan'))
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/ddr_dma/units_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskSources=@()
foreach($taskName in @('ddr_native_dma','dma_pixel_pack','dma_byte_unpack','dma_row_plan')){
 $taskSource=Join-Path $taskRun "$taskName.v"
 Copy-Item -LiteralPath (Join-Path $taskFpga "rtl/memory/$taskName.v") -Destination $taskSource
 $taskSources+=$taskSource
}
$taskSources | ForEach-Object {Get-FileHash -LiteralPath $_ -Algorithm SHA256 | Select-Object Path,Hash} |
 ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
$taskOldLicense=$env:PANGO_LICENSE_FILE
if($LicenseFile){$env:PANGO_LICENSE_FILE=(Resolve-Path -LiteralPath $LicenseFile).Path}
$taskResults=@()
try {
 foreach($taskName in $Units){
  if($taskName -notin @('ddr_native_dma','dma_pixel_pack','dma_byte_unpack','dma_row_plan')){throw 'Unknown unit'}
  $taskUnit=Join-Path $taskRun $taskName
  New-Item -ItemType Directory -Path $taskUnit -Force | Out-Null
  $taskImpl=(Join-Path $taskUnit 'implementation').Replace('\','/')
  New-Item -ItemType Directory -Path $taskImpl -Force | Out-Null
  $taskSource=(Join-Path $taskRun "$taskName.v").Replace('\','/')
  $taskFdc=(Join-Path $taskUnit 'unit.fdc').Replace('\','/')
  # Purpose: constrain internal clk for synthesis only; abstract inputs are not
  # board IO and omitted input/output delays are not certified physical paths.
  'create_clock -name {unit_clk} [get_ports {clk}] -period {8.0}' | Set-Content -LiteralPath $taskFdc -Encoding utf8
  $taskTcl=(Join-Path $taskUnit "$taskName.tcl").Replace('\','/')
  @"
# Purpose: unit synthesis only, native installed writer; no bitstream/download.
set_dir -impl_directory {$taskImpl}
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
add_design {$taskSource}
add_constraint {$taskFdc}
compile -top_module $taskName
synthesize -ads -selected_syn_tool_opt 2
"@ | Set-Content -LiteralPath $taskTcl -Encoding utf8
  $taskGenerator=Join-Path $taskUnit 'generate.tcl'
  "tcl2prj -tcl {$taskTcl}`nputs DDR_UNIT_PROJECT_GENERATED" | Set-Content -LiteralPath $taskGenerator -Encoding utf8
  Push-Location $taskUnit
  try {
   $taskOut=& "$PdsHome/bin/pds_shell.exe" -file $taskGenerator -work_dir $taskUnit 2>&1;$taskExit=$LASTEXITCODE
   $taskOut | Set-Content (Join-Path $taskUnit 'generate.log') -Encoding utf8
   if($taskExit -ne 0 -or ($taskOut -join "`n") -notmatch 'DDR_UNIT_PROJECT_GENERATED'){throw 'Unit generation failed'}
   $taskOut=& "$PdsHome/bin/pds_shell.exe" -project (Join-Path $taskUnit "$taskName.pds") -work_dir $taskImpl -run synthesize 2>&1;$taskExit=$LASTEXITCODE
   $taskOut | Set-Content (Join-Path $taskUnit 'synthesize.log') -Encoding utf8
   # Installed writer may save prj_impl_dir="."; its actual native report then
   # lives beside the project. Both locations stay in this dedicated build run.
   $taskReport=Join-Path $taskImpl "synthesize/$taskName.snr"
   if(!(Test-Path -LiteralPath $taskReport)){$taskReport=Join-Path $taskUnit "synthesize/$taskName.snr"}
   $taskPassed=$taskExit -eq 0 -and (Test-Path -LiteralPath $taskReport) -and ($taskOut -join "`n") -notmatch '(?m)^E:|Check license failed'
   $taskResults+=@{unit=$taskName;passed=$taskPassed;native_exit=$taskExit;report=$taskReport;pnr_tested=$false;hardware_tested=$false}
   $taskResults | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $taskRun 'results.json') -Encoding utf8
   Write-Output "DDR_UNIT_SYNTHESIS unit=$taskName passed=$taskPassed"
   if(!$taskPassed){throw "Unit synthesis failed: $taskName"}
  } finally {Pop-Location}
 }
 Write-Output "DDR_UNITS_SYNTHESIS_COMPLETE $taskRun"
} finally { $env:PANGO_LICENSE_FILE=$taskOldLicense }
