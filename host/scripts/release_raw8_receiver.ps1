# Purpose: release only this checkout's stale RAW8 Web receiver before a new
# board test, preserving the Web service and rejecting unknown UDP occupants.
# The caller starts the new epoch receiver after this script confirms release.
param([string]$BindIp='169.254.81.186',[int]$Port=50000,[int]$WebPort=8766)
$ErrorActionPreference='Stop'

# Purpose: avoid stopping a process merely because it uses the video UDP port.
$taskUdp=@(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
    Where-Object {$_.LocalAddress -eq $BindIp})
if($taskUdp.Count -eq 0){Write-Output 'RAW8_UDP_ALREADY_FREE'; return}
if($taskUdp.Count -ne 1){throw 'Multiple UDP occupants; manual identity check required'}
$taskWeb=@(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $WebPort -State Listen -ErrorAction SilentlyContinue)
if($taskWeb.Count -ne 1 -or $taskWeb[0].OwningProcess -ne $taskUdp[0].OwningProcess){
    throw 'UDP occupant is not the local Pango Web service; refusing to close it'
}

# Purpose: authenticate the expected project instance before requesting its
# graceful session stop; never terminate the service or unrelated applications.
$taskBase="http://127.0.0.1:$WebPort"
$taskHealth=Invoke-RestMethod -Uri "$taskBase/api/health" -Method Get
$taskRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path.ToLowerInvariant()
$taskExpectedHash=[Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($taskRoot))
).ToLowerInvariant()
if($taskHealth.service -ne 'pango-video-web' -or $taskHealth.workspace -ne $taskExpectedHash){
    throw 'Web service belongs to another checkout; refusing to stop it'
}
$taskSession=Invoke-RestMethod -Uri "$taskBase/api/session" -Method Get
if(-not $taskSession.status.running -or $taskSession.status.config.source_mode -ne 'hardware_unverified' -or
   $taskSession.status.config.bind_ip -ne $BindIp -or $taskSession.status.config.port -ne $Port){
    throw 'Web receiver state differs from the occupied RAW8 endpoint'
}
$taskRunId=$taskSession.status.run_id
$taskHeaders=@{'X-Pango-Token'=$taskSession.token}
$null=Invoke-RestMethod -Uri "$taskBase/api/stop" -Method Post -Headers $taskHeaders -ContentType 'application/json' -Body '{}'

# Purpose: require the operating system to release the socket before another
# receiver is started, rather than relying only on the Web API acknowledgement.
for($taskAttempt=0;$taskAttempt -lt 25;$taskAttempt++){
    if(-not @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object {$_.LocalAddress -eq $BindIp}).Count){
        Write-Output "RAW8_OLD_WEB_SESSION_RELEASED $taskRunId"
        return
    }
    Start-Sleep -Milliseconds 200
}
throw 'Web session stopped but RAW8 UDP port is still occupied'
