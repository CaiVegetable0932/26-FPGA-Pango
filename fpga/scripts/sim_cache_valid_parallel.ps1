# Purpose: freeze production 0F/current 69422B and execute the complete 40-case
# 125 MHz same-cycle miter with ModelSim 10.1c. No EDA/hardware; every attempt
# is a new directory, including failed attempts. Source files are never patched.
[CmdletBinding()]
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$build='fpga/build/cache_valid_parallel_20261007_171322_219'
$golden=Join-Path $root "$build/geometry_window_cache.golden.v"
$candidate=Join-Path $root 'fpga/rtl/geometry/geometry_window_cache.v'
if((Get-FileHash -LiteralPath $golden).Hash -cne '0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385' -or
 (Get-Item -LiteralPath $golden).Length -ne 14216){throw 'Frozen production golden drift'}
if((Get-FileHash -LiteralPath $candidate).Hash -cne '69422BF532261480BEB3EC2B1687D8D50BCB1BC14D54C3461C59A63441405635' -or
 (Get-Item -LiteralPath $candidate).Length -ne 15736){throw 'Reviewed current candidate drift'}
$attempt="$build/attempt_"+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')
$run=Join-Path $root $attempt
New-Item -ItemType Directory -Path (Join-Path $run 'sources') -ErrorAction Stop|Out-Null
$encoding=New-Object Text.UTF8Encoding($false)
function Save([string]$Name,$Value){
 $data=$encoding.GetBytes(($Value|ConvertTo-Json -Depth 20))
 $stream=[IO.File]::Open((Join-Path $run $Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
}
# Purpose: origin and exact copied bytes are both recorded before compilation.
# Only the golden fixture changes its top-level name; the original stays 0F.
$pairs=@(
 [pscustomobject]@{role='golden';origin="$build/geometry_window_cache.golden.v";copy='geometry_window_cache.golden.v'},
 [pscustomobject]@{role='candidate';origin='fpga/rtl/geometry/geometry_window_cache.v';copy='geometry_window_cache.v'},
 [pscustomobject]@{role='bench';origin='fpga/sim/tb_cache_valid_parallel.sv';copy='tb_cache_valid_parallel.sv'},
 [pscustomobject]@{role='runner';origin='fpga/scripts/sim_cache_valid_parallel.ps1';copy='sim_cache_valid_parallel.ps1'})
foreach($p in $pairs){Copy-Item -LiteralPath (Join-Path $root $p.origin) -Destination (Join-Path $run ('sources/'+$p.copy)) -ErrorAction Stop}
$text=[IO.File]::ReadAllText($golden)
if(([regex]::Matches($text,'module geometry_window_cache #')).Count -ne 1){throw 'Nonunique golden top'}
[IO.File]::WriteAllText((Join-Path $run 'sources/geometry_window_cache_golden.v'),$text.Replace('module geometry_window_cache #','module geometry_window_cache_golden #'),$encoding)
function Sources{
 $records=@(foreach($p in $pairs){foreach($path in @($p.origin,"$attempt/sources/$($p.copy)")){
  $f=Join-Path $root $path
  [pscustomobject][ordered]@{role=$p.role;path=$path;sha256=(Get-FileHash -LiteralPath $f).Hash;bytes=(Get-Item -LiteralPath $f).Length}
 }})
 $fixture=Join-Path $run 'sources/geometry_window_cache_golden.v'
 $records+=[pscustomobject][ordered]@{role='renamed_golden';path="$attempt/sources/geometry_window_cache_golden.v";sha256=(Get-FileHash -LiteralPath $fixture).Hash;bytes=(Get-Item -LiteralPath $fixture).Length}
 return $records
}
$before=@(Sources);Save 'sources.before.json' ([ordered]@{schema_version='cache-valid-parallel-sources/v1';files=$before})
$oldModelsim=$env:MODELSIM;$passed=$false;$cases=@()
Push-Location $run
try{
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c 2>&1|Tee-Object vmap.log|Out-Null
 if($LASTEXITCODE){throw 'vmap failed'}
 $env:MODELSIM=Join-Path $run 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work 2>&1|Tee-Object vlib.log|Out-Null
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv sources/geometry_window_cache_golden.v sources/geometry_window_cache.v sources/tb_cache_valid_parallel.sv 2>&1|Tee-Object compile.log
 if($LASTEXITCODE){throw 'Parallel-valid miter compile failed'}
 foreach($stride in @(32,128,1536,2048)){foreach($words in @(64,128,256,512,1024)){foreach($seed in @(20261007,987654321)){
  $name="cycle_stride$($stride)_cache$($words)_seed$($seed).log"
  & "$ModelSimHome/vsim.exe" -c -voptargs=+acc tb_cache_valid_parallel ('-gSTRIDE='+$stride) ('-gCACHE_WORDS='+$words) ('-gSEED='+$seed) -do 'onerror {quit -code 2}; run -all; quit -f' 2>&1|Tee-Object $name|Out-Null
  $log=[IO.File]::ReadAllText((Join-Path $run $name))
  if($LASTEXITCODE -or $log -match '\*\* (Fatal|Error)|CACHE_VALID_\w*(FAIL|TIMEOUT)' -or
   ([regex]::Matches($log,"CACHE_VALID_PARALLEL_PASS stride=$stride cache_words=$words seed=$seed requests=2048 ")).Count -ne 1){throw "Miter failed: $name"}
  $cases+=[pscustomobject][ordered]@{stride=$stride;cache_words=$words;seed=$seed;requests=2048;log=$name;passed=$true}
  Write-Host "CACHE_VALID_CASE_PASS stride=$stride cache_words=$words seed=$seed"
 }}}
 $after=@(Sources)
 if(($before|ConvertTo-Json -Depth 10 -Compress) -cne ($after|ConvertTo-Json -Depth 10 -Compress)){throw 'Source drift during miter'}
 $passed=$true
}finally{
 Save 'sources.after.json' ([ordered]@{schema_version='cache-valid-parallel-sources/v1';files=@(Sources)})
 Save 'result.json' ([ordered]@{schema_version='cache-valid-parallel-run/v1';passed=$passed;clock_period_ns=8;
  simulator='ModelSim SE-64 10.1c';golden_sha256='0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385';
  candidate_sha256='69422BF532261480BEB3EC2B1687D8D50BCB1BC14D54C3461C59A63441405635';
  sources_unchanged=$passed;cases=$cases;formal_proof=$false;pds_run=$false;hardware_verified=$false;
  four_state_scope='Raw case-equality including initial X and inactive-coordinate X/Z; active controls and used addresses are binary.'})
 $env:MODELSIM=$oldModelsim;Pop-Location
}
Write-Output "CACHE_VALID_PARALLEL_MITER_PASS $attempt"
