# Purpose: bind the DirectShow index to the unique Hagibis USB identity before
# capture. This script rejects webcam/virtual-camera indexes instead of probing.
param(
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
$hostRoot = Split-Path $PSScriptRoot -Parent
$source = Join-Path $hostRoot 'src/DirectShowDeviceEnumerator.cs'
Add-Type -Path $source
$devices = @([CameraRgb565Hdmi.Host.DirectShowDeviceEnumerator]::Enumerate())

# Purpose: require both the exact friendly name and the known physical USB
# VID/PID in the DirectShow moniker or DevicePath; one field alone is not enough.
$hagibis = @($devices | Where-Object {
    $_.FriendlyName -eq 'Hagibis' -and
    (($_.MonikerDisplayName + ' ' + $_.DevicePath) -match '(?i)vid_1de1&pid_f105')
})
$excluded = @($devices | Where-Object {
    $_.FriendlyName -match '(?i)USB.*(Cam|WebCam)|Integrated Camera|Virtual|TranScreen'
})
$result = [ordered]@{
    enumerated_at = (Get-Date).ToString('o')
    devices = $devices
    hagibis_matches = $hagibis
    excluded_devices = $excluded
    unique_hagibis = $hagibis.Count -eq 1
    selected_index = if ($hagibis.Count -eq 1) { $hagibis[0].Index } else { $null }
    expected_vid_pid = 'VID_1DE1&PID_F105'
}
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
$result | ConvertTo-Json -Depth 8
if ($hagibis.Count -ne 1) {
    throw "Expected exactly one Hagibis DirectShow device with VID_1DE1&PID_F105; found $($hagibis.Count)"
}
