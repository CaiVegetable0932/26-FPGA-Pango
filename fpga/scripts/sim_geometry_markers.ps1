# Purpose: isolated new-marker regression. No PDS, hardware, vendor changes,
# or shared simulation-script edits; output stays under fpga/build.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_markers_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskRepo=Split-Path $taskFpga -Parent
$taskTests=@('tb_geometry_markers','tb_geometry_view','tb_geometry_view_uart','tb_geometry_marker_overlay')
# Capture all geometry/control RTL and golden-reference inputs before generating
# vectors. Re-discovery at exit also detects added or removed RTL source files.
function Get-MarkerEvidencePaths {
 $taskPaths=@(Get-ChildItem (Join-Path $taskFpga 'rtl/geometry'),(Join-Path $taskFpga 'rtl/control') -Recurse -File |
  Where-Object Extension -In '.v','.sv','.vh','.svh' | ForEach-Object FullName)
 foreach($taskTest in $taskTests){$taskPaths+=Join-Path $taskFpga "sim/$taskTest.sv"}
 $taskPaths+=$PSCommandPath
 $taskPaths+=Join-Path $PSScriptRoot 'geometry_marker_vectors.js'
 $taskPaths+=Join-Path $taskRepo 'host/web/fisheye-preview.js'
 $taskPaths | Sort-Object -Unique
}
$taskEvidencePaths=@(Get-MarkerEvidencePaths)
$taskEvidence=@(foreach($taskPath in $taskEvidencePaths){
 [ordered]@{
  path=$taskPath
  relative_path=$taskPath.Substring($taskRepo.Length+1).Replace('\','/')
  bytes=(Get-Item -LiteralPath $taskPath).Length
  sha256=(Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash
 }
})
[ordered]@{
 schema='pango.marker-source-sha256.v1'
 captured_at=(Get-Date).ToString('o')
 captured_before_vector_generation=$true
 algorithm='SHA256'
 source_count=$taskEvidence.Count
 files=$taskEvidence
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskRun 'sources.json') -Encoding UTF8
# Always verify the recorded inputs, including when generation or simulation
# fails. The PASS banner is emitted only after this release-gate check succeeds.
try {
& node (Join-Path $PSScriptRoot 'geometry_marker_vectors.js') $taskRun
if($LASTEXITCODE){throw 'golden generation failed'}
$taskPrevious=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 $taskSources=@(Get-ChildItem (Join-Path $taskFpga 'rtl/geometry') -Filter '*.v' | ForEach-Object FullName)
 $taskSources+=Get-ChildItem (Join-Path $taskFpga 'rtl/control') -Filter '*.v' | ForEach-Object FullName
 foreach($taskTest in $taskTests){$taskSources+=Join-Path $taskFpga "sim/$taskTest.sv"}
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'marker compile failed'}
 foreach($taskTest in $taskTests){
  & "$ModelSimHome/vsim.exe" -c $taskTest -do 'run -all; quit -f' 2>&1 | Tee-Object "$taskTest.log"
  $taskLog=Get-Content "$taskTest.log" -Raw
  if($LASTEXITCODE -or $taskLog -notmatch 'GEOMETRY_(MARKERS|VIEW|VIEW_UART|MARKER_OVERLAY)_PASS' -or $taskLog -match '\*\* (Fatal|Error)'){throw "marker simulation failed: $taskTest"}
 }
 & "$ModelSimHome/vsim.exe" -c tb_geometry_view_uart -gDISPLAY=0 -do 'run -all; quit -f' 2>&1 | Tee-Object 'view_uart_disabled.log'
 $taskLog=Get-Content 'view_uart_disabled.log' -Raw
 if($LASTEXITCODE -or $taskLog -notmatch 'GEOMETRY_VIEW_UART_PASS' -or $taskLog -match '\*\* (Fatal|Error)'){throw 'legacy display capability regression failed'}
} finally {$env:MODELSIM=$taskPrevious;Pop-Location}
} finally {
 $taskAfterPaths=@(Get-MarkerEvidencePaths)
 $taskPathChanges=@(Compare-Object -ReferenceObject $taskEvidencePaths -DifferenceObject $taskAfterPaths)
 $taskVerification=@(foreach($taskSource in $taskEvidence){
  $taskAfterHash=$null
  if(Test-Path -LiteralPath $taskSource.path -PathType Leaf){
   $taskAfterHash=(Get-FileHash -LiteralPath $taskSource.path -Algorithm SHA256).Hash
  }
  [ordered]@{
   relative_path=$taskSource.relative_path
   before_sha256=$taskSource.sha256
   after_sha256=$taskAfterHash
   unchanged=($taskSource.sha256 -eq $taskAfterHash)
  }
 })
 $taskSourcesUnchanged=(@($taskVerification | Where-Object { -not $_.unchanged }).Count -eq 0 -and $taskPathChanges.Count -eq 0)
 [ordered]@{
  schema='pango.marker-source-verification.v1'
  verified_at=(Get-Date).ToString('o')
  passed=$taskSourcesUnchanged
  source_count=$taskVerification.Count
  source_set_changes=$taskPathChanges
  files=$taskVerification
 } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskRun 'sources.verification.json') -Encoding UTF8
 if(-not $taskSourcesUnchanged){throw "marker regression source files changed: $taskRun"}
 Write-Output "GEOMETRY_MARKERS_SOURCES_UNCHANGED count=$($taskVerification.Count) $taskRun"
}
Write-Output "GEOMETRY_MARKERS_REGRESSION_PASS $taskRun"
