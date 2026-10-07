# Purpose: bounded, offline geometry regression. Only project-owned outputs
# are created; no UART/JTAG/Flash is opened and official files remain read-only.
param([string]$ModelSimHome='E:/ModelsimSE/win64',[string]$Python='python',
 [ValidateRange(1843200,250000000)][int]$GeometryUartClockHz=1843200)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_chain_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOldModelsim=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'geometry vlib failed'}
 & $Python -B (Join-Path $taskFpga 'sim/prepare_geometry_vectors.py') $taskRun | Tee-Object reference.log
 if($LASTEXITCODE){throw 'analytic reference failed'}
 $taskSources=@()
 foreach($taskDirectory in @('rtl/geometry','rtl/raw8_dual','rtl/control','rtl/network')){
  $taskSources+=Get-ChildItem (Join-Path $taskFpga $taskDirectory) -Filter '*.v' | ForEach-Object FullName
 }
 $taskSources+=@('tb_geometry_lens.sv','tb_geometry_pipeline.sv','tb_geometry_uart.sv','tb_geometry_pool.sv','tb_geometry.sv') | ForEach-Object {Join-Path $taskFpga "sim/$_"}
 # Purpose: reference generators and the entry script are provenance inputs,
 # but are not Verilog compiler inputs.
 $taskInputs=@($taskSources)+@($PSCommandPath,
  (Join-Path $taskFpga 'sim/prepare_geometry_vectors.py'),
  (Join-Path $taskFpga 'model/fisheye_geometry_reference.py'))
 @($taskInputs | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
  ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'geometry compile failed'}
 foreach($taskTop in @('tb_geometry_lens','tb_geometry_pipeline','tb_geometry_uart','tb_geometry_pool','tb_geometry')){
  # Purpose: optionally exercise the same physical UART suite at the actual
  # 125MHz board domain; serial bit time remains 115200 baud, not scaled.
  $taskSimArgs=@('-c',$taskTop)
  if($taskTop -eq 'tb_geometry_uart'){$taskSimArgs+="-gCLK_HZ=$GeometryUartClockHz"}
  $taskSimArgs+=@('-do','run -all; quit -f')
  & "$ModelSimHome/vsim.exe" @taskSimArgs 2>&1 | Tee-Object "$taskTop.log"
  $taskText=Get-Content "$taskTop.log" -Raw
  if($LASTEXITCODE -or $taskText -notmatch 'GEOMETRY(_LENS|_PIPELINE|_UART|_POOL)?_PASS' -or
     $taskText -match '\*\* (Fatal|Error)|GEOMETRY_.*FAIL|GEOMETRY_.*TIMEOUT'){
   throw "geometry simulation failed: $taskTop; $taskRun"
  }
 }
 & "$ModelSimHome/vsim.exe" -c tb_geometry_lens -gKIND=1 -do 'run -all; quit -f' 2>&1 | Tee-Object brown.log
 $taskText=Get-Content brown.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'GEOMETRY_LENS_PASS model=1' -or
    $taskText -match '\*\* (Fatal|Error)|GEOMETRY_.*FAIL|GEOMETRY_.*TIMEOUT'){throw 'Brown/rotation regression failed'}
 Write-Output "GEOMETRY_CHAIN_PASS $taskRun"
} finally {$env:MODELSIM=$taskOldModelsim;Pop-Location}
