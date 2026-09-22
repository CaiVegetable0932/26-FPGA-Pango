# Purpose: audit the FINAL timing run and source hashes before publishing a
# self-contained commissioning image. Offline conversion only, no hardware I/O.
param([Parameter(Mandatory=$true)][string]$Run,
 [Parameter(Mandatory=$true)][string]$Simulation,
 [Parameter(Mandatory=$true)][string]$ClockSimulation,
 [Parameter(Mandatory=$true)][string]$BridgeSimulation,
 [string]$CfgRuntime='E:/PDS_Pangu/PDS_2022.2-SP6.4')
$ErrorActionPreference='Stop'
# Validate and fingerprint the caller-selected offline runtime. The official
# unmodified device list lacks XT25F128; never patch an installation here.
$CfgRuntime=(Resolve-Path -LiteralPath $CfgRuntime).Path
$taskCfgExe=Join-Path $CfgRuntime 'bin/cdt_cfg_shell.exe'
$taskFlashList=Join-Path $CfgRuntime 'arch/vendor/pango/arch/cdt/flash_list_cd.cfl'
if(!(Test-Path -LiteralPath $taskCfgExe) -or
   !(Select-String -LiteralPath $taskFlashList -Pattern '"xt25f128"' -Quiet)){
 throw 'Select an existing project runtime with XT25F128 support; official files must remain read-only'
}
$taskRuntimeHashes=@($taskCfgExe,$taskFlashList | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
})
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=(Resolve-Path -LiteralPath $Run).Path
$taskAuditText=& python -B (Join-Path $PSScriptRoot 'audit_raw8_candidate.py') $taskRun $Simulation $ClockSimulation $BridgeSimulation
if($LASTEXITCODE){throw 'Final candidate audit failed'}
$taskAudit=($taskAuditText -join "`n")|ConvertFrom-Json
$taskRelease=Join-Path $taskFpga ('release/raw8_dual_'+(Get-Date -Format yyyyMMdd)+'_'+$taskAudit.bitstream_sha256.Substring(0,12))
if(Test-Path -LiteralPath $taskRelease){throw "Release already exists: $taskRelease"}
New-Item -ItemType Directory -Path $taskRelease | Out-Null
Copy-Item -LiteralPath $taskAudit.bitstream -Destination (Join-Path $taskRelease 'mini_raw8_dual.sbit')
Copy-Item -LiteralPath $taskAudit.timing_report -Destination (Join-Path $taskRelease 'timing.rtr')
Copy-Item -LiteralPath (Join-Path $taskRun 'source_manifest.json') -Destination $taskRelease
$taskAuditText | Set-Content (Join-Path $taskRelease 'audit.json') -Encoding utf8
$taskOldSbit=$env:COMMS_SBIT;$taskOldSfc=$env:COMMS_SFC
$env:COMMS_SBIT=Join-Path $taskRelease 'mini_raw8_dual.sbit'
$env:COMMS_SFC=Join-Path $taskRelease 'mini_raw8_dual.sfc'
Push-Location $taskRelease
try {
 # The Tcl contains ONLY set-break, format conversion and close. Do not add
 # scan/connect/erase/program commands to this export workflow.
 $taskTcl=(Join-Path $PSScriptRoot 'convert_comms_sfc.tcl').Replace('\','/')
 "source {$taskTcl}" | & "$CfgRuntime/bin/cdt_cfg_shell.exe" 2>&1 | Tee-Object conversion.log
 if($LASTEXITCODE -or !(Select-String conversion.log -Pattern 'COMMS_SFC_OFFLINE_GENERATED' -Quiet) -or
    (Select-String conversion.log -Pattern '^E:|Check license failed|is not supported' -Quiet) -or !(Test-Path $env:COMMS_SFC)){
  throw 'SFC conversion incomplete: retained SBIT/audit are not a complete Flash release'
 }
 if((Get-Item -LiteralPath $env:COMMS_SFC).Length -lt 10000){throw 'Empty or truncated converted image'}
 foreach($taskRuntimeFile in $taskRuntimeHashes){
  if((Get-FileHash -LiteralPath $taskRuntimeFile.path).Hash -ne $taskRuntimeFile.sha256){
   throw 'Offline runtime changed during conversion; do not publish this attempt'
  }
 }
 # Manifest distinguishes file generation from write/verify/cold-boot evidence.
 [ordered]@{image_kind='1080p RAW8 camera + HDMI raw-gray + Ethernet first-board candidate';
  target='PG2L100H-6FBG676';flash='XT25F128';spi_width=1;opcode=11;start_address=0;
  programmed=$false;flash_verified=$false;cold_boot_verified=$false;camera_video=$true;camera_source_verified=$false;external_dvp_timing_verified=$false;
  strict_native_pll_simulation_passed=$false;timing_constraints_met=$true;
  files=@(Get-Item $env:COMMS_SBIT,$env:COMMS_SFC | ForEach-Object {
   [ordered]@{name=$_.Name;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
  });conversion_runtime=$CfgRuntime;runtime_hashes=$taskRuntimeHashes;
  reference_directories_modified=$false} |
  ConvertTo-Json -Depth 5 | Set-Content manifest.json -Encoding utf8
} finally {
 $env:COMMS_SBIT=$taskOldSbit;$env:COMMS_SFC=$taskOldSfc;Pop-Location
}
Write-Output "RAW8_CANDIDATE_EXPORTED $taskRelease"
