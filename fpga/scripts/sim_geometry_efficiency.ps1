# Purpose: reproduce golden-vs-current equivalence from an immutable Git
# checkpoint. Golden files are mechanically renamed generated fixtures,
# never hand-edited reference RTL. All outputs stay inside fpga/build.
param([string]$Baseline='8b52050b',[string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRepo=Split-Path $taskFpga -Parent
$taskCommit=(& git -C $taskRepo rev-parse --verify ($Baseline+'^{commit}')).Trim()
if($LASTEXITCODE){throw 'Missing immutable baseline'}
$taskRun=Join-Path $taskFpga ('build/geometry_efficiency_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@()
foreach($taskModule in @('geometry_config_bank','geometry_gray_sampler','geometry_map_engine','raw8_display_enhance')){
 $taskRelative=if($taskModule -eq 'raw8_display_enhance'){'rtl/raw8_dual/'}else{'rtl/geometry/'}
 $taskOriginal=(& git -C $taskRepo show ($taskCommit+':fpga/'+$taskRelative+$taskModule+'.v')) -join "`n"
 if($LASTEXITCODE){throw 'Cannot obtain baseline RTL'}
 $taskRenamed=[regex]::Replace($taskOriginal,('\bmodule '+$taskModule+'\b'),('module '+$taskModule+'_golden'))
 # Golden sampler must also use the ORIGINAL tone curve, not the candidate.
 if($taskModule -eq 'geometry_gray_sampler'){
  $taskRenamed=$taskRenamed.Replace('raw8_display_enhance u_curve','raw8_display_enhance_golden u_curve')
 }
 $taskPath=Join-Path $taskRun ($taskModule+'_golden.v')
 [IO.File]::WriteAllText($taskPath,$taskRenamed,[Text.UTF8Encoding]::new($false))
 $taskSources+=$taskPath
 $taskSources+=Join-Path $taskFpga ($taskRelative+$taskModule+'.v')
}
$taskSources+=@('rtl/geometry/geometry_mul_pipe.v','sim/tb_geometry_efficiency.sv') | ForEach-Object {Join-Path $taskFpga $_}
$taskOldModelsim=$env:MODELSIM;$taskPassed=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'vlib failed'}
 @($taskSources+@($PSCommandPath) | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}}) | ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Miter compile failed'}
 foreach($taskTop in @('tb_config_efficiency','tb_sampler_efficiency','tb_map_efficiency','tb_tone_efficiency')){
  & "$ModelSimHome/vsim.exe" -c $taskTop -do 'run -all; quit -f' 2>&1 | Tee-Object ($taskTop+'.log')
  $taskText=Get-Content ($taskTop+'.log') -Raw
  if($LASTEXITCODE -or $taskText -notmatch 'EFFICIENCY_(CONFIG|SAMPLER|MAP|TONE)_PASS' -or $taskText -match 'EFFICIENCY_.*(FAIL|TIMEOUT)|\*\* (Fatal|Error)'){throw "Miter failed: $taskTop"}
 }
 foreach($taskInput in (Get-Content sources.json -Raw | ConvertFrom-Json)){
  if((Get-FileHash -LiteralPath $taskInput.path).Hash -ne $taskInput.sha256){throw 'Input changed while testing'}
 }
 $taskPassed=$true
} finally {
 [ordered]@{baseline_commit=$taskCommit;equivalence_passed=$taskPassed;formal_proof=$false;hardware_tested=$false} | ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
Write-Output "GEOMETRY_EFFICIENCY_PASS $taskRun"
