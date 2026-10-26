# Purpose: keep the native diagnostic .pds source list consistent with its Tcl.
# Preserve previous generated project/constraint report; never run build/JTAG.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskProject=Join-Path $taskFpga 'project/mini_camera_diag/mini_camera_diag.pds'
if(Test-Path -LiteralPath ($taskProject+'.lock')){throw 'Diagnostic GUI project is locked; close it before regeneration'}
$taskRun=Join-Path $taskFpga ('build/ddr_dma/project_update_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
Copy-Item -LiteralPath $taskProject -Destination (Join-Path $taskRun 'previous.pds')
$taskReport=Join-Path (Split-Path $taskProject -Parent) 'constraint_check/constraint_check.ccr'
if(Test-Path -LiteralPath $taskReport){Copy-Item -LiteralPath $taskReport -Destination (Join-Path $taskRun 'previous_constraint_check.ccr')}
Push-Location $taskRun
try {
 $taskOut=& "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'create_mini_camera_diag.tcl') -work_dir $taskRun 2>&1
 $taskExit=$LASTEXITCODE
 $taskOut | Set-Content (Join-Path $taskRun 'generation.log') -Encoding utf8
 if($taskExit -ne 0 -or ($taskOut -join "`n") -notmatch 'MINI_NATIVE_PROJECT_GENERATED' -or ($taskOut -join "`n") -match '(?m)^E:'){throw 'Native writer failed; original is archived'}
 # Purpose: reuse the existing reviewed implementation-directory normalization.
 $taskText=Get-Content -LiteralPath $taskProject -Raw
 $taskText=$taskText.Replace('(_option prj_impl_dir (_string "."))','(_option prj_impl_dir (_string "../../build/mini_camera_diag/implementation"))')
 if($taskText -notmatch 'mini_ddr_native_bridge.v' -or $taskText -match 'aq_axi_master_256.v'){throw 'Native source list mismatch'}
 $taskText | Set-Content -LiteralPath $taskProject -Encoding utf8
 [ordered]@{passed=$true;native_exit=$taskExit;project_sha256=(Get-FileHash $taskProject -Algorithm SHA256).Hash;previous_project_sha256=(Get-FileHash (Join-Path $taskRun 'previous.pds') -Algorithm SHA256).Hash;hardware_tested=$false;programmed=$false} |
  ConvertTo-Json | Set-Content (Join-Path $taskRun 'result.json') -Encoding utf8
 Write-Output "DDR_DIAGNOSTIC_PROJECT_UPDATED $taskRun"
} finally {Pop-Location}
