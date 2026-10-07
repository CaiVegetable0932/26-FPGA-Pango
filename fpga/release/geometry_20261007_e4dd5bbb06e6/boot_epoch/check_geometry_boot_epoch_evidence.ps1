# Purpose: READ-ONLY fail-closed gate for the reviewed immutable boot/UART proof.
# PS5.1/7. No saved evidence writes, EDA/native invocation, hardware or RTL edits.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$EvidenceDirectory,
 [string]$WorkspaceRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
function Require($Condition,[string]$Message){if(-not $Condition){throw "BootEpochEvidence: $Message"}}
function Keys($Object,[string[]]$Names,[string]$Label){
 Require ($Object -is [pscustomobject]) "$Label object required"
 Require ((@($Object.PSObject.Properties.Name|Sort-Object)-join '|') -ceq (($Names|Sort-Object)-join '|')) "$Label closed keys"
}
function Bool($Value,[bool]$Expected,[string]$Label){Require ($Value -is [bool] -and $Value -eq $Expected) "$Label typed bool"}
function Int($Value,[long]$Expected,[string]$Label){Require (($Value -is [int] -or $Value -is [long]) -and $Value -eq $Expected) "$Label exact integer"}
function TextHash([string]$Text){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','')}finally{$h.Dispose()}}
# Reject duplicate JSON keys, nonfinite numbers, trailing/truncated tokens before
# ConvertFrom-Json (whose duplicate handling differs between PowerShell versions).
function StrictJson([string]$Text){
 $script:jt=$Text;$script:jp=0
 function WS {while($script:jp -lt $script:jt.Length -and [char]::IsWhiteSpace($script:jt[$script:jp])){$script:jp++}}
 function JString {
  $m=[regex]::Match($script:jt.Substring($script:jp),'^"(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"')
  Require $m.Success 'invalid JSON string';$script:jp+=$m.Length;return $m.Value
 }
 function JValue {
  WS;Require ($script:jp -lt $script:jt.Length) 'truncated JSON';$ch=$script:jt[$script:jp]
  if($ch -eq '{'){
   $script:jp++;WS;$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
   if($script:jp -lt $script:jt.Length -and $script:jt[$script:jp] -eq '}'){$script:jp++;return}
   while($true){
    WS;$token=JString;$key=@(('['+$token+']')|ConvertFrom-Json)[0]
    Require ($seen.Add([string]$key)) 'duplicate JSON key';WS
    Require ($script:jp -lt $script:jt.Length -and $script:jt[$script:jp] -eq ':') 'JSON colon required';$script:jp++;JValue;WS
    Require ($script:jp -lt $script:jt.Length) 'truncated object'
    $end=$script:jt[$script:jp];$script:jp++
    if($end -eq '}'){break};Require ($end -eq ',') 'JSON object separator'
   };return
  }
  if($ch -eq '['){
   $script:jp++;WS;if($script:jp -lt $script:jt.Length -and $script:jt[$script:jp] -eq ']'){$script:jp++;return}
   while($true){JValue;WS;Require ($script:jp -lt $script:jt.Length) 'truncated array';$end=$script:jt[$script:jp];$script:jp++;if($end -eq ']'){break};Require ($end -eq ',') 'JSON array separator'};return
  }
  if($ch -eq '"'){$null=JString;return}
  $m=[regex]::Match($script:jt.Substring($script:jp),'^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)')
  Require $m.Success 'invalid/nonfinite JSON token';$script:jp+=$m.Length
  if($m.Value -notin @('true','false','null')){
   $number=0.0
   Require ([double]::TryParse($m.Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and -not [double]::IsInfinity($number) -and -not [double]::IsNaN($number)) 'nonfinite JSON number'
  }
 }
 JValue;WS;Require ($script:jp -eq $script:jt.Length) 'trailing JSON'
 # PS7.5 otherwise silently converts ISO text to DateTime; retain JSON types.
 if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ($Text|ConvertFrom-Json -DateKind String)}
 return ($Text|ConvertFrom-Json)
}
$project=[IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)).TrimEnd('\','/')
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
# Exact copied checkers derive their finite private fixture as their own project.
# The live checker approves only its own project, with no historic fixture aliases.
$allowedRoots=@($project)
Require (@($allowedRoots|Where-Object {[IO.Path]::GetFullPath($_).TrimEnd('\','/') -ieq $root}).Count -eq 1) 'WorkspaceRoot not approved production/finite test root'
function NoLink([string]$Path){
 $p=$Path;while($p.Length -ge $root.Length){Require (((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse path forbidden';if($p -ieq $root){break};$p=Split-Path $p -Parent}
}
function File([string]$Path){
 Require ([IO.Path]::IsPathRooted($Path)) 'absolute file path required'
 $p=[IO.Path]::GetFullPath($Path)
 Require ($p.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'file escapes workspace'
 Require (Test-Path -LiteralPath $p -PathType Leaf) "missing file $p";NoLink $p;return $p
}
$proof=Join-Path $root 'fpga/build/mcu_stable_epoch_proof_20261007_144143_995'
# Only this independently rerun/reviewed attempt binds current physical Top and
# runner bytes. Historic attempts remain immutable and are stale for this gate.
$attempts=@('attempt_20261007_161933_853_98ae2b14')
$dir=[IO.Path]::GetFullPath($EvidenceDirectory).TrimEnd('\','/')
if($dir -ieq $proof){$dir=Join-Path $proof $attempts[0]}
$attempt=Split-Path $dir -Leaf
Require ($attempt -cin $attempts -and $dir -ieq (Join-Path $proof $attempt)) 'unapproved/stale EvidenceDirectory'
$sourceDir=Join-Path $dir 'sources'
$expected=@'
[
{"role":"golden","live":"proof/mcu_protocol.old.v","file":"mcu_protocol.old.v","sha":"A0110F5AD0795FC29AF2A492087A0C8C458C27E77A253860576CE8B975EB8104","bytes":25035},
{"role":"golden_fixture","live":"proof/mcu_protocol_golden.v","file":"mcu_protocol_golden.v","sha":"4B83F5C99A0E86FB5F84230628CEAB18D28026A980A68532C490AE32075F512D","bytes":25042},
{"role":"candidate","live":"fpga/rtl/control/mcu_protocol.v","file":"mcu_protocol.v","sha":"47FB9B886CA67790124F96E4BDEFA1EA08C29B6509A2C6001611BBCBA8ED057D","bytes":26117},
{"role":"board_contract","live":"fpga/rtl/board/mini_raw8_geometry.v","file":"mini_raw8_geometry.v","sha":"39EAC934A1718849B0A37CE2D5D3D42E040736A4EE1A830045A5743C99D19A53","bytes":19064},
{"role":"runner","live":"fpga/scripts/sim_mcu_stable_link_epoch.ps1","file":"sim_mcu_stable_link_epoch.ps1","sha":"5221885AFDCDB8193444F267984DB055FD1BE95348189D02B27F062E897D80C3","bytes":6546},
{"role":"bench","live":"fpga/sim/tb_mcu_stable_link_epoch.sv","file":"tb_mcu_stable_link_epoch.sv","sha":"FE1153B93A8B285AD696592821135E0068338FE060A09C00634E79948427EBBE","bytes":13702},
{"role":"boot","live":"fpga/rtl/control/comms_boot_config.v","file":"comms_boot_config.v","sha":"B082003139E4560648BFADDBF21B981CFC59C2004AE1E126F833C6083D8B820C","bytes":4539},
{"role":"uart_rx","live":"fpga/rtl/control/mcu_uart_rx.v","file":"mcu_uart_rx.v","sha":"1AECCF08189E42F8E548A2D16EA2022726038F3D9F01517FAA21CDC0757C6AF9","bytes":2604},
{"role":"uart_tx","live":"fpga/rtl/control/mcu_uart_tx.v","file":"mcu_uart_tx.v","sha":"656E4FB1ECF0FDED3A346CFB65A18DA1988D3F17E41E28B6F16625C00481E553","bytes":1371},
{"role":"frame_rx","live":"fpga/rtl/control/mcu_frame_rx.v","file":"mcu_frame_rx.v","sha":"030FDE66741E2B3F529DD4C5BACCD3CA6DF65C116507DCAEC29C7F76C5C170B4","bytes":5656},
{"role":"frame_tx","live":"fpga/rtl/control/mcu_frame_tx.v","file":"mcu_frame_tx.v","sha":"6E15BBD1B42BB15A43B5592AC78780FB8056CFF36C4237FA97F4274D5A3CD2B3","bytes":2701}
]
'@|ConvertFrom-Json
$before=New-Object 'System.Collections.Generic.List[object]'
$paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
function Capture([string]$Path){
 $p=File $Path;Require ($paths.Add($p)) 'duplicate artifact path'
 $item=Get-Item -LiteralPath $p;Require ($item.Length -gt 0) 'empty evidence file'
 $record=[pscustomobject][ordered]@{path=$p;sha256=(Get-FileHash -LiteralPath $p).Hash;bytes=[long]$item.Length}
 $before.Add($record);return $record
}
$meta=@{};foreach($name in @('source_manifest.json','source_verification.json','result.json')){$p=Join-Path $dir $name;$meta[$name]=Capture $p}
$manifest=StrictJson ([IO.File]::ReadAllText($meta['source_manifest.json'].path))
$result=StrictJson ([IO.File]::ReadAllText($meta['result.json'].path))
$verification=@(StrictJson ([IO.File]::ReadAllText($meta['source_verification.json'].path)))
Keys $manifest @('schema','captured_before_compile','golden_top_rename_only','shared_helper_identical','files') 'manifest'
Require ($manifest.schema -ceq 'mcu-stable-epoch-source.v1') 'manifest schema'
foreach($key in @('captured_before_compile','golden_top_rename_only','shared_helper_identical')){Bool $manifest.$key $true $key}
Require ($manifest.files -is [array] -and $manifest.files.Count -eq 11 -and $verification.Count -eq 11) '11 closed source roles required'
$rolePaths=@{}
for($i=0;$i -lt 11;$i++){
 $e=$expected[$i];$f=$manifest.files[$i];$v=$verification[$i]
 Keys $f @('path','frozen','sha256','bytes') "source $i";Keys $v @('path','frozen','expected','live','snapshot') "verification $i"
 $live=if($e.live.StartsWith('proof/')){Join-Path $proof $e.live.Substring(6)}else{Join-Path $root $e.live}
 $frozen=Join-Path $sourceDir $e.file
 Require ($f.path -is [string] -and $f.path -ieq $live -and $f.frozen -is [string] -and $f.frozen -ieq $frozen) "role/path mismatch $($e.role)"
 Require ($f.sha256 -is [string] -and $f.sha256 -ceq $e.sha) "independent source SHA $($e.role)";Int $f.bytes $e.bytes "source bytes $($e.role)"
 Require ($v.path -is [string] -and $v.path -ieq $live -and $v.frozen -is [string] -and $v.frozen -ieq $frozen) 'verification role mismatch'
 foreach($key in @('expected','live','snapshot')){Require ($v.$key -is [string] -and $v.$key -ceq $e.sha) "verification SHA $key"}
 foreach($p in @($live,$frozen)){$rec=Capture $p;Require ($rec.sha256 -ceq $e.sha -and $rec.bytes -eq $e.bytes) "actual source drift $($e.role)"}
 $rolePaths[$e.role]=$frozen
}
Keys $result @('passed','source_manifest_sha256','runs','formal_proof','pds_run','hardware_tested','sources_unchanged','finished') 'result'
Bool $result.passed $true 'passed';Bool $result.sources_unchanged $true 'sources_unchanged'
foreach($key in @('formal_proof','pds_run','hardware_tested')){Bool $result.$key $false $key}
Require ($result.source_manifest_sha256 -is [string] -and $result.source_manifest_sha256 -ceq $meta['source_manifest.json'].sha256) 'manifest SHA binding'
$dt=[DateTimeOffset]::MinValue
Require ($result.finished -is [string] -and $result.finished -cmatch '^\d{4}-\d{2}-\d{2}T' -and [DateTimeOffset]::TryParse($result.finished,[ref]$dt)) 'finished timestamp'
Require ($result.runs -is [array] -and $result.runs.Count -eq 2) 'both configs required'
# Reviewed COMPLETE log hashes normalize only this permitted workspace prefix/CRLF.
# Reviewed after real full+clock125 rerun against frozen eight-input UART miter.
# Top is a boot/reset contract binding only; it is not a physical-board compile.
# Thus rehashed semantic/truncated/ignored-compile logs cannot become approved.
$logPins=@{
 'attempt_20261007_161933_853_98ae2b14'=@{
 'compile.log'='FDD6BCDA8B9D448578F254D583D9DD505D4CA752C273B18B482AC145A06E0C3B'
 'full.log'='D79FC93F5D56437C5DD54933088DF1FBC5EB9CD32F0FF6885D9333253F11327D'
 'clock125.log'='B3EBEECD2BC63D361797091FEC73730B7C02EA303E6EF2DF58C7614F03EE7D6A'
 'full_transcript.log'='D2598B52454FB3328D1BAB36B2F905BA4FC021BB83F4B85F28D609D4BFEE02F0'
 'clock125_transcript.log'='DC02F2C1AEB8960F602DF041C8F0479A6C652200494CC4D6940C4179CE56C76A'}
}
$logs=@{};$logRecords=@{}
foreach($name in @('compile.log','full.log','clock125.log','full_transcript.log','clock125_transcript.log')){
 $rec=Capture (Join-Path $dir $name);$logRecords[$name]=$rec
 $s=[IO.File]::ReadAllText($rec.path);$normalized=$s.Replace($root,'<WORKSPACE>').Replace($root.Replace('\','/'),'<WORKSPACE>').Replace("`r`n","`n")
 Require ((TextHash $normalized) -ceq $logPins[$attempt][$name]) "independent complete log SHA $name"
 Require ($s -notmatch '\*\* (Error|Fatal)|MCU_STABLE_EPOCH_FAIL|MCU_STABLE_EPOCH_TIMEOUT') "failure log $name";$logs[$name]=$s
}
$compiled=@([regex]::Matches($logs['compile.log'],'(?m)^-- Compiling module (\w+)\s*$')|ForEach-Object {$_.Groups[1].Value})
Require (($compiled -join '|') -ceq 'mcu_uart_rx|mcu_uart_tx|mcu_frame_rx|mcu_frame_tx|comms_boot_config|mcu_protocol_golden|mcu_reply_queue_ram|mcu_protocol|mcu_reply_queue_ram|tb_mcu_stable_link_epoch') 'actual compiled module inventory'
Require ($logs['compile.log'].Contains($rolePaths.candidate) -and $logs['compile.log'].Contains($rolePaths.bench)) 'actual frozen compile paths'
$banners=@(
 'MCU_STABLE_EPOCH_PASS clk=1843200 full=1 cycles=2073674 checks=6237515 releases=68 invalid_boot=7 guard_noise=1 reset_pending=2 reset_uart=1 reset_guard=1 single_bits=64 replies=188 pushes=115 pops=113 env=4 geometry=9 max_queue=8',
 'MCU_STABLE_EPOCH_PASS clk=125000000 full=0 cycles=13410978 checks=40234162 releases=2 invalid_boot=2 guard_noise=1 reset_pending=1 reset_uart=0 reset_guard=0 single_bits=0 replies=14 pushes=11 pops=10 env=2 geometry=2 max_queue=1')
$names=@('full','clock125');$hz=@(1843200,125000000)
for($i=0;$i -lt 2;$i++){
 $run=$result.runs[$i];$name=$names[$i]
 Keys $run @('name','clock_hz','baud','full','plus_acc','exit_code','passed','log','log_sha256') "run $name"
 Require ($run.name -ceq $name -and $run.log -ceq ($name+'.log')) 'run name/log identity'
 Int $run.clock_hz $hz[$i] 'clock_hz';Int $run.baud 115200 'baud';Int $run.exit_code 0 'exit_code'
 Bool $run.full ($i -eq 0) 'full';Bool $run.plus_acc $true 'plus_acc';Bool $run.passed $true 'run passed'
 Require ($run.log_sha256 -is [string] -and $run.log_sha256 -ceq $logRecords[$run.log].sha256) 'run actual log SHA'
 foreach($suffix in @('.log','_transcript.log')){
  $s=$logs[$name+$suffix]
  Require ([regex]::Matches($s,'(?m)^# MCU_STABLE_EPOCH_PASS .*\r?$').Count -eq 1 -and $s.Contains('# '+$banners[$i])) "exact coverage banner $name"
  Require ([regex]::Matches($s,'(?m)^# vsim .*\r?$').Count -eq 1 -and $s.Contains('-voptargs=+acc') -and $s.Contains('-gCLK_HZ='+$hz[$i]) -and $s.Contains('-gFULL='+(1-$i)) -and $s.Contains('tb_mcu_stable_link_epoch')) 'actual native vsim params'
 }
}
# Source pins are independent; textual checks also forbid candidate-vs-self fixtures.
$old=[IO.File]::ReadAllText($rolePaths.golden);$fixture=[IO.File]::ReadAllText($rolePaths.golden_fixture);$candidate=[IO.File]::ReadAllText($rolePaths.candidate)
Require ($old.Replace('module mcu_protocol #(','module mcu_protocol_golden #(').Replace("`r`n","`n").TrimEnd() -ceq $fixture.Replace("`r`n","`n").TrimEnd()) 'golden top rename only'
Require (($old -split 'module mcu_reply_queue_ram',2)[1].Replace("`r`n","`n").TrimEnd() -ceq ($candidate -split 'module mcu_reply_queue_ram',2)[1].Replace("`r`n","`n").TrimEnd()) 'shared helper identical'
Require ($candidate -match 'parameter integer STABLE_LINK_EPOCH = 0' -and $candidate -match '!STABLE_LINK_EPOCH && \(link_epoch != observed_epoch\)') 'legacy comparison contract'
$bench=[IO.File]::ReadAllText($rolePaths.bench);$board=[IO.File]::ReadAllText($rolePaths.board_contract)
Require ($bench.Contains('.STABLE_LINK_EPOCH(1)') -and $bench.Contains('wire mcu_reset_n=reset_n && configured') -and $board.Contains('.STABLE_LINK_EPOCH(1)') -and $board.Contains('.rst_n(mem_reset_n && commissioned)')) 'actual stable1 producer reset contract'
# TOCTOU check hashes and sizes of ALL returned inputs after semantics, not just source.
foreach($rec in $before){$p=File $rec.path;Require ((Get-FileHash -LiteralPath $p).Hash -ceq $rec.sha256 -and (Get-Item -LiteralPath $p).Length -eq $rec.bytes) 'evidence changed during check'}
$compileRoles=@('uart_rx','uart_tx','frame_rx','frame_tx','boot','golden_fixture','candidate','bench')
[pscustomobject][ordered]@{
 schema_version='geometry-boot-epoch-evidence/v1';passed=$true
 inputs=@($before|Sort-Object path|ForEach-Object {[pscustomobject][ordered]@{path=$_.path;sha256=$_.sha256}})
 source_count=11;artifact_count=$before.Count;sources_unchanged=$true
 actual_compile_inputs=@($compileRoles|ForEach-Object {$rolePaths[$_]})
 matrix=@([pscustomobject]@{name='full';clock_hz=1843200;cycles=2073674;releases=68;single_bits=64;max_queue=8},[pscustomobject]@{name='clock125';clock_hz=125000000;cycles=13410978;releases=2;single_bits=0;max_queue=1})
 formal_proof=$false;pds_run=$false;hardware_tested=$false
}

