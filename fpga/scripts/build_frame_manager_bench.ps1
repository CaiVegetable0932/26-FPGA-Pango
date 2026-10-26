# Purpose: run an isolated native PDS benchmark, preserving shared board projects.
param(
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [ValidateSet('compile','synthesize','dev_map','pnr','report_timing')][string]$Stage='synthesize',
 [ValidateRange(30,3600)][int]$TimeoutSeconds=480,
 [string]$Python='python'
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga 'build/frame_manager/pds'
$taskProjectRoot=Join-Path $taskFpga 'project/frame_manager_bench'
$taskShell=Join-Path $PdsHome 'bin/pds_shell.exe'
New-Item -ItemType Directory -Force $taskRun | Out-Null
& $Python (Join-Path $PSScriptRoot 'generate_frame_manager_layout.py')
if($LASTEXITCODE -ne 0){throw 'Frame layout generation failed'}
# Purpose: tcl2prj uses the installed native writer; all references point only
# into this FPGA development area and all generated logs have an explicit cwd.
$taskGenerate=Join-Path $taskRun 'generate.tcl'
@"
tcl2prj -tcl [file normalize {$($taskProjectRoot.Replace('\','/'))/frame_manager_bench.tcl}]
puts FRAME_MANAGER_NATIVE_PROJECT_GENERATED
"@ | Set-Content -LiteralPath $taskGenerate -Encoding utf8
Push-Location $taskRun
try {
 & $taskShell -file $taskGenerate -work_dir $taskRun 2>&1 | Tee-Object generation.log
 if($LASTEXITCODE -ne 0){throw 'PDS benchmark project generation failed'}
 $taskProject=Join-Path $taskProjectRoot 'frame_manager_bench.pds'
 $taskStarted=Get-Date
 $taskStdout=Join-Path $taskRun "$Stage.console.log"
 $taskStderr=Join-Path $taskRun "$Stage.stderr.log"
 $taskArguments=@('-project',('"'+$taskProject+'"'),'-work_dir',('"'+$taskRun+'"'),'-run',$Stage)
 # Purpose: hidden, bounded native build. On timeout, terminate only this exact
 # launched process and verified same-project PDS children; preserve all logs.
 $taskProcess=Start-Process -FilePath $taskShell -ArgumentList $taskArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskStdout -RedirectStandardError $taskStderr
 $taskTimedOut=$false
 while(!$taskProcess.WaitForExit(1000)){
  if(((Get-Date)-$taskStarted).TotalSeconds -ge $TimeoutSeconds){
   $taskTimedOut=$true
   $taskChildren=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($taskProcess.Id)")
   $taskNormalizedProject=$taskProject.Replace('\','/')
   foreach($taskChild in $taskChildren){
    # Native Windows launches an owned console host even for a hidden process;
    # it closes with its parent and is not an unrelated build task.
    if($taskChild.Name -eq 'conhost.exe'){continue}
    if($taskChild.Name -eq 'pds_shell.exe' -and $taskChild.CommandLine.Replace('\','/').Contains($taskNormalizedProject)){
     Stop-Process -Id $taskChild.ProcessId -ErrorAction SilentlyContinue
    } else {throw 'Unexpected build child preserved; inspect process tree'}
   }
   Stop-Process -Id $taskProcess.Id -ErrorAction SilentlyContinue
   break
  }
 }
 $taskProcess.WaitForExit()
 $taskExit=$taskProcess.ExitCode
 $taskText=(Get-Content -LiteralPath $taskStdout -Raw)+(Get-Content -LiteralPath $taskStderr -Raw)
 $taskSuffix=@{compile='cmr';synthesize='snr';dev_map='dmr';pnr='prr';report_timing='rtr'}[$Stage]
 $taskStageDir=@{compile='compile';synthesize='synthesize';dev_map='device_map';pnr='place_route';report_timing='report_timing'}[$Stage]
 $taskReport=Join-Path $taskRun "$taskStageDir/frame_manager_bench.$taskSuffix"
 $taskFresh=(Test-Path -LiteralPath $taskReport) -and (Get-Item -LiteralPath $taskReport).LastWriteTime -ge $taskStarted
 $taskPassed=!$taskTimedOut -and $taskExit -eq 0 -and $taskFresh -and $taskText -notmatch '(?m)^E:|Check license failed|crashes'
 $taskSources=@('rtl/memory/frame_manager_pkg.sv','rtl/memory/frame_manager_layout.vh','rtl/memory/frame_pool_bank.sv','rtl/memory/frame_manager.sv','sim/frame_manager_bench.sv','constraints/frame_manager_bench.fdc','project/frame_manager_bench/frame_manager_bench.tcl')
 $taskHashes=@($taskSources | ForEach-Object {$taskSource=Join-Path $taskFpga $_;[ordered]@{path=$taskSource;sha256=(Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash}})
 [ordered]@{stage=$Stage;native_exit=$taskExit;passed=$taskPassed;timed_out=$taskTimedOut;elapsed_seconds=((Get-Date)-$taskStarted).TotalSeconds;fresh_report=$taskFresh;sources=$taskHashes;hardware_tested=$false;board_top=$false;programmed=$false} |
  ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$Stage.result.json" -Encoding utf8
 if(!$taskPassed){throw "PDS benchmark $Stage failed; inspect $taskRun"}
} finally {Pop-Location}
