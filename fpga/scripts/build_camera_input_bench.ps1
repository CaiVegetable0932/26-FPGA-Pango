# 用途：02专用原生PDS基准，隔离工程/构建目录；不改板级共享项目或执行硬件操作。
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [ValidateSet('input','control')][string]$Benchmark='input',
 [ValidateSet('compile','synthesize','dev_map','pnr','report_timing')][string]$Stage='synthesize')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskSubdir=if($Benchmark -eq 'control'){'control_pds'}else{'pds'}
$taskBase=if($Benchmark -eq 'control'){'camera_control_bench'}else{'camera_input_bench'}
if($Benchmark -eq 'control' -and $Stage -notin @('compile','synthesize')){throw 'Control benchmark supports compile/synthesize only'}
$taskRun=Join-Path $taskFpga ('build/camera_input_20261012/'+$taskSubdir)
$taskProjectRoot=Join-Path $taskFpga 'project/camera_input_bench'
New-Item -ItemType Directory -Force $taskRun | Out-Null
$taskGenerate=Join-Path $taskRun 'generate.tcl'
@"
# Purpose: installed native project writer; generated only in the input-specific project.
tcl2prj -tcl [file normalize {$($taskProjectRoot.Replace('\','/'))/${taskBase}.tcl}]
puts CAMERA_INPUT_NATIVE_PROJECT_GENERATED
"@ | Set-Content $taskGenerate -Encoding utf8
# 用途：沿用已核验原生保存路径修正，保证从GUI打开本专用工程也不会在project目录构建。
function Restore-InputBenchLayout {
 $taskPds=Join-Path $taskProjectRoot ($taskBase+'.pds')
 $taskPdsText=Get-Content -LiteralPath $taskPds -Raw
 $taskOld='(_option prj_impl_dir (_string "."))'
 $taskNew='(_option prj_impl_dir (_string "../../build/camera_input_20261012/'+$taskSubdir+'"))'
 if($taskPdsText.Contains($taskOld)){$taskPdsText.Replace($taskOld,$taskNew) | Set-Content -LiteralPath $taskPds -Encoding utf8}
 elseif(!$taskPdsText.Contains($taskNew)){throw 'Unexpected input benchmark layout'}
}
Push-Location $taskRun
try {
 $taskLog=& "$PdsHome/bin/pds_shell.exe" -file $taskGenerate -work_dir $taskRun 2>&1
 $taskExit=$LASTEXITCODE;$taskLog | Set-Content generation.log -Encoding utf8
 if($taskExit -ne 0 -or ($taskLog -join "`n") -notmatch 'CAMERA_INPUT_NATIVE_PROJECT_GENERATED'){throw 'Input benchmark generation failed'}
 Restore-InputBenchLayout
 # 用途：记录本专用基准清单/RTL/约束哈希，避免把后续修改当作相同PnR快照。
 $taskTcl=Get-Content (Join-Path $taskProjectRoot ($taskBase+'.tcl')) -Raw
 $taskInputs=@([regex]::Matches($taskTcl,'(?:add_design|add_constraint) \[file join \$task_fpga ([^\]]+)\]') | ForEach-Object {Join-Path $taskFpga ($_.Groups[1].Value.Replace(' ','/'))})
 @($taskInputs | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash} }) | ConvertTo-Json -Depth 3 | Set-Content 'source_hashes.json' -Encoding UTF8
 $taskBegin=Get-Date
 $taskLog=& "$PdsHome/bin/pds_shell.exe" -project (Join-Path $taskProjectRoot ($taskBase+'.pds')) -work_dir $taskRun -run $Stage 2>&1
 $taskExit=$LASTEXITCODE;$taskLog | Set-Content "$Stage.console.log" -Encoding utf8
 Restore-InputBenchLayout
 $taskText=$taskLog -join "`n"
 $taskPassed=$taskExit -eq 0 -and $taskText -notmatch '(?m)^E:|Check license failed'
 # 进程成功只表示流程执行；独立记录内部时序摘要，不把无外部IO约束当成整机通过。
 $taskExt=@{compile='cmr';synthesize='snr';dev_map='dmr';pnr='prr';report_timing='rtr'}[$Stage]
 $taskReports=@(Get-ChildItem $taskRun -Recurse -Filter "*.$taskExt" | Where-Object {$_.LastWriteTime -ge $taskBegin})
 $taskPassed=$taskPassed -and $taskReports.Count -gt 0
 [ordered]@{benchmark=$Benchmark;stage=$Stage;native_exit=$taskExit;passed=$taskPassed;fresh_reports=@($taskReports.FullName);
 warnings=@($taskLog | Select-String '^W:').Count;internal_only=$true;external_timing_verified=$false;
 cdc_verified=$false;hardware_verified=$false;programmed=$false} | ConvertTo-Json -Depth 4 | Set-Content "$Stage.result.json" -Encoding utf8
 if(!$taskPassed){throw "Input benchmark $Stage failed: $taskRun"}
 Write-Output "CAMERA_INPUT_PDS_STAGE_PASS $Stage $taskRun"
}finally{Pop-Location}
