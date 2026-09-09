$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'original.pds') -Raw
$original = '(_file "../../rtl/pango_video_top.v" + "pango_video_top" (_format verilog))'
$cases = [ordered]@{
    original = $source
    line22_newlines = $source.Replace($original, "(_file `"../../rtl/pango_video_top.v`" + `"pango_video_top`"`n                    (_format verilog)`n                )")
    line22_timespec = $source.Replace($original, '(_file "../../rtl/pango_video_top.v" + "pango_video_top" (_format verilog) (_timespec "2026-09-09T00:00:00"))')
}
foreach ($entry in $cases.GetEnumerator()) {
    $projectPath = Join-Path $PSScriptRoot ($entry.Key + '.pds')
    $logPath = Join-Path $PSScriptRoot ($entry.Key + '.log')
    $entry.Value | Set-Content -LiteralPath $projectPath -Encoding utf8NoBOM
    $output = & 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe' -project $projectPath -work_dir $PSScriptRoot 2>&1
    $output | Set-Content -LiteralPath $logPath -Encoding utf8NoBOM
    Write-Output "CASE $($entry.Key)"
    $output | Select-String -Pattern 'Flow-0130|Flow-0121|PDS_PROJECT_READ_PASS|E:|Analyzing project'
}
