# Purpose: standalone byte-exact comparison against the frozen pre-integration
# scalar sampler, with randomized memory delays/backpressure and hit throughput.
# Only this script's unique fpga/build directory is written; no PDS is invoked.
param([string]$ModelSimHome='E:/ModelsimSE/win64',[int]$Seed=20261006,[int[]]$CacheWords=@(1024,64,256))
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_window_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskBaseline=Join-Path $taskFpga 'build/markers_baseline_20261006'
$taskSources=@(
 (Join-Path $taskBaseline 'geometry/geometry_gray_sampler.v'),
 (Join-Path $taskBaseline 'raw8_dual/raw8_display_enhance.v'))
# Purpose: rename baseline curve and sampler mechanically into immutable test
# fixtures so candidate and reference cannot accidentally share a changed ROM.
$taskGolden=@()
foreach($taskPath in $taskSources){
 $taskText=Get-Content -LiteralPath $taskPath -Raw
 $taskText=$taskText.Replace('geometry_gray_sampler','geometry_gray_sampler_golden').Replace('raw8_display_enhance','raw8_display_enhance_golden')
 $taskCopy=Join-Path $taskRun ([IO.Path]::GetFileNameWithoutExtension($taskPath)+'_golden.v')
 [IO.File]::WriteAllText($taskCopy,$taskText,[Text.UTF8Encoding]::new($false))
 $taskGolden+=$taskCopy
}
$taskCandidate=@('rtl/geometry/geometry_window_sampler.v','rtl/geometry/geometry_window_cache.v','rtl/geometry/geometry_gray_stream.v','rtl/raw8_dual/raw8_display_enhance.v','sim/tb_geometry_window.sv') | ForEach-Object {Join-Path $taskFpga $_}
$taskManifest=@($taskSources+$taskCandidate+@($PSCommandPath) | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$taskOldModelsim=$env:MODELSIM;$taskPassed=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 if($LASTEXITCODE){throw 'vmap failed'}
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'vlib failed'}
 $taskManifest | ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskGolden @taskCandidate 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Window miter compile failed'}
 # Compare fallback/default on the same scenarios. A longer four-angle trace
 # covers sixteen full destination rows and asserts identity source-row reuse.
 foreach($taskCache in $CacheWords){
 foreach($taskCase in @(@{w=32;h=8;s=32;n=4096;t=0},@{w=32;h=8;s=2048;n=4096;t=0},@{w=70;h=19;s=128;n=4096;t=0},@{w=1920;h=1080;s=2048;n=4096;t=0},@{w=1920;h=1080;s=2048;n=30720;t=1})){
  $taskLog='window_'+$taskCase.w+'x'+$taskCase.h+'_stride'+$taskCase.s+'_cache'+$taskCache+'_pixels'+$taskCase.n+'.log'
  & "$ModelSimHome/vsim.exe" -c tb_geometry_window ('-gWIDTH='+$taskCase.w) ('-gHEIGHT='+$taskCase.h) ('-gSTRIDE='+$taskCase.s) ('-gCACHE_WORDS='+$taskCache) ('-gN='+$taskCase.n) ('-gTRACE_ONLY='+$taskCase.t) ('+SEED='+$Seed) -do 'run -all; quit -f' 2>&1 | Tee-Object $taskLog
  $taskText=Get-Content $taskLog -Raw
  if($LASTEXITCODE -or $taskText -notmatch 'WINDOW_EQUIVALENCE_PASS' -or $taskText -match 'WINDOW_.*(FAIL|TIMEOUT)|\*\* (Fatal|Error)'){throw "Window test failed: $taskLog"}
 }
 }
 foreach($taskInput in $taskManifest){
  if((Get-FileHash -LiteralPath $taskInput.path).Hash -ne $taskInput.sha256){throw 'Input changed during standalone test'}
 }
 $taskPassed=$true
} finally {
 [ordered]@{passed=$taskPassed;seed=$Seed;cache_words=$CacheWords;baseline=$taskBaseline;formal_proof=$false;pds_synthesis_run=$false;timing_verified=$false;hardware_tested=$false} | ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
Write-Output "GEOMETRY_WINDOW_PASS $taskRun"
