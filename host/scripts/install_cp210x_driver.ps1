# Purpose: install only the user-approved, authenticated CP210x VCP package.
# Run elevated through Windows UAC; never disable signature checks or import REG files.
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskPackage=Join-Path $taskRoot 'build/cp210x_driver_20260922/package'
foreach($taskSigned in @('silabser.cat','x64/silabser.sys')){
 if((Get-AuthenticodeSignature -LiteralPath (Join-Path $taskPackage $taskSigned)).Status -ne 'Valid'){
  throw 'Driver signature verification failed'
 }
}
# Keep the native installation result in the host development area, not vendor sources.
$taskLog=Join-Path $taskRoot 'build/cp210x_driver_20260922/install.log'
& "$env:SystemRoot/System32/pnputil.exe" /add-driver (Join-Path $taskPackage 'silabser.inf') /install 2>&1 | Tee-Object -FilePath $taskLog
$taskExit=$LASTEXITCODE
Write-Output "CP210X_INSTALL_EXIT=$taskExit"
exit $taskExit
