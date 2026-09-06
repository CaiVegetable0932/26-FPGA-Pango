# Run after reviewing and committing changes. Never commits or force-pushes.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
function Invoke-GitChecked {
    $result = & git @args
    if ($LASTEXITCODE -ne 0) { throw "Git command failed: $($args[0])" }
    return $result
}
$expected = 'https://github.com/CaiVegetable0932/26-FPGA-Pango.git'
$remote = Invoke-GitChecked remote get-url --push --all origin
if (@($remote).Count -ne 1 -or $remote -ne $expected) { throw 'Unexpected origin push URL. Check git remote -v.' }
$branch = Invoke-GitChecked symbolic-ref --quiet --short HEAD
if (Invoke-GitChecked status --porcelain) { throw 'Uncommitted files exist. Review and commit them in VS Code first.' }
Invoke-GitChecked fetch origin
Invoke-GitChecked push --atomic --follow-tags --set-upstream origin $branch
$local = Invoke-GitChecked rev-parse HEAD
$remoteRef = Invoke-GitChecked ls-remote --exit-code origin "refs/heads/$branch"
if (($remoteRef -split '\s+')[0] -ne $local) { throw 'Remote verification failed.' }
Write-Host "Cloud backup verified: $branch $local"
Write-Host 'Root reference/ and PDS/ directories and other branches are not included.'
