# Purpose: commissioning UART only, bound to the board CP2102 identity.
# Supports capability probe, explicit TEST/RAW8 boot profiles, and session/status check.
# No motor, light-control, reset, Flash or OS configuration command is sent.
param([ValidateSet('Probe','Boot','Inspect')][string]$Action='Probe',
 [string]$Port='COM15',[string]$BootJson='', [Parameter(Mandatory=$true)][string]$Out,
 # Purpose: explicit image-profile selection; never silently commission camera with TEST metadata.
 [ValidateSet('TEST','RAW8')][string]$Profile='TEST')
$ErrorActionPreference='Stop'
function Get-Crc16([byte[]]$Data){
 # CCITT-FALSE over version through payload; match FPGA V1 little-endian CRC.
 [int]$taskCrc=65535
 foreach($taskByte in $Data){
  $taskCrc=$taskCrc -bxor ([int]$taskByte -shl 8)
  for($taskBit=0;$taskBit -lt 8;$taskBit++){
   if($taskCrc -band 32768){$taskCrc=(($taskCrc -shl 1) -bxor 4129) -band 65535}
   else {$taskCrc=($taskCrc -shl 1) -band 65535}
  }
 }
 return [uint16]$taskCrc
}
function New-Request([byte]$Command,[uint16]$Sequence,[byte[]]$Payload){
 [byte[]]$taskBody=@(1,$Command)+[BitConverter]::GetBytes($Sequence)+[BitConverter]::GetBytes([uint16]$Payload.Length)+$Payload
 return ,([byte[]](@(85,170)+$taskBody+[BitConverter]::GetBytes((Get-Crc16 $taskBody))))
}
function Exchange([byte[]]$Wire){
 # Bound time and bytes. Only a full CRC-checked, sequence-matched ACK is trusted.
 # Purpose: retain host receive timestamps for approximate counter-rate checks;
 # these are UART arrival times, never camera exposure/HDMI frame timestamps.
 $taskSendUtc=[DateTime]::UtcNow.ToString('o')
 $taskSerial.DiscardInBuffer();$taskSerial.Write($Wire,0,$Wire.Length)
 $taskReply=[Collections.Generic.List[byte]]::new();$taskDeadline=[DateTime]::UtcNow.AddSeconds(2)
 while([DateTime]::UtcNow -lt $taskDeadline -and $taskReply.Count -lt 42){
  try {$taskReply.Add([byte]$taskSerial.ReadByte())}catch [TimeoutException]{}
 }
 [byte[]]$taskRx=$taskReply.ToArray()
 $taskValid=$taskRx.Length -eq 42
 if($taskValid){
  $taskValid=$taskRx[0] -eq 85 -and $taskRx[1] -eq 170 -and $taskRx[2] -eq 1 -and
   $taskRx[3] -in @(128,129) -and $taskRx[4] -eq $Wire[4] -and $taskRx[5] -eq $Wire[5] -and
   [BitConverter]::ToUInt16($taskRx,6) -eq 32 -and $taskRx[9] -eq $Wire[3] -and
   (Get-Crc16 ([byte[]]$taskRx[2..39])) -eq [BitConverter]::ToUInt16($taskRx,40)
 }
 $taskRecord=[ordered]@{request_hex=[Convert]::ToHexString($Wire);reply_hex=[Convert]::ToHexString($taskRx);valid_reply=$taskValid;
  sent_utc=$taskSendUtc;received_utc=[DateTime]::UtcNow.ToString('o');
  received_monotonic_ticks=[Diagnostics.Stopwatch]::GetTimestamp();monotonic_frequency=[Diagnostics.Stopwatch]::Frequency}
 if($taskValid){$taskRecord.result=$taskRx[8];$taskRecord.request_command=$taskRx[9]}
 $taskRecords.Add($taskRecord)
 if(!$taskValid){throw 'No complete valid UART reply (see transcript)'}
 return ,$taskRx
}
# Reject another USB bridge/COM mapping and unsafe report destinations.
$taskDevice=Get-PnpDevice -InstanceId 'USB\VID_10C4&PID_EA60\0001'
if($taskDevice.Status -ne 'OK' -or $taskDevice.FriendlyName -notmatch ('\('+[regex]::Escape($Port)+'\)$')){throw 'CP2102/COM identity mismatch'}
$taskHostRoot=Split-Path $PSScriptRoot -Parent
$taskReport=[IO.Path]::GetFullPath($Out)
if(!$taskReport.StartsWith((Join-Path $taskHostRoot 'reports')+'\') -or (Test-Path -LiteralPath $taskReport)){throw 'Use a fresh host/reports path'}
if((Get-Crc16 ([Text.Encoding]::ASCII.GetBytes('123456789'))) -ne 0x29b1){throw 'CRC self-test failed'}
$taskSerial=[IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$taskSerial.DtrEnable=$false;$taskSerial.RtsEnable=$false;$taskSerial.Handshake=[IO.Ports.Handshake]::None
$taskSerial.ReadTimeout=100;$taskSerial.WriteTimeout=1000
$taskRecords=[Collections.Generic.List[object]]::new();$taskError=$null;$taskFlags=$null;$taskDiagnostics=$null;$taskRaw8Status=$null;$taskVideoSnapshot=$null;$taskChain=$null
try {
 $taskSerial.Open()
 if($Action -eq 'Boot'){
  $taskBoot=Get-Content -LiteralPath $BootJson -Raw | ConvertFrom-Json
  $taskSource=if($Profile -eq 'RAW8'){'OV5640 RAW8 - HARDWARE UNVERIFIED'}else{'SYNTHETIC TEST - NOT CAMERA'}
  $taskCommand=if($Profile -eq 'RAW8'){113}else{112}
  if($taskBoot.source -ne $taskSource){throw 'Boot metadata/image profile mismatch'}
  [byte[]]$taskWire=[Convert]::FromHexString($taskBoot.command_hex)
  if($taskWire.Length -ne 42 -or $taskWire[3] -ne $taskCommand -or (Get-Crc16 ([byte[]]$taskWire[2..39])) -ne [BitConverter]::ToUInt16($taskWire,40)){throw 'Malformed boot command'}
  $taskRx=Exchange $taskWire
  if($taskRx[3] -ne 128 -or $taskRx[8] -ne 0 -or [Text.Encoding]::ASCII.GetString($taskRx,28,4) -ne $Profile -or
     [BitConverter]::ToUInt64($taskRx,12) -ne [BitConverter]::ToUInt64($taskWire,8)){throw 'Boot ACK identity/result mismatch'}
 } else {
  $taskRx=Exchange (New-Request 1 1 ([byte[]]@()))
  if($Action -eq 'Inspect'){
   if($taskRx[8] -ne 0){throw 'MCU endpoint not ready'}
   [uint64]$taskEpoch=[BitConverter]::ToUInt64($taskRx,12)
   [uint32]$taskSession=[BitConverter]::ToUInt32($taskRx,20)
   [uint32]$taskCapabilities=[BitConverter]::ToUInt32($taskRx,32)
   if($taskEpoch -eq 0){throw 'No valid commissioned epoch'}
   # Open a test session only if none exists; existing sessions are not replaced.
   if($taskSession -eq 0){$taskSession=1;[byte[]]$taskPayload=[BitConverter]::GetBytes($taskEpoch)+[BitConverter]::GetBytes($taskSession);$taskRx=Exchange (New-Request 2 2 $taskPayload);if($taskRx[8] -ne 0){throw 'Session open failed'}}
   [byte[]]$taskPayload=[BitConverter]::GetBytes($taskEpoch)+[BitConverter]::GetBytes($taskSession)
   $taskRx=Exchange (New-Request 3 3 $taskPayload)
   if($taskRx[8] -ne 0){throw 'Status request failed'}
   $taskFlags=[BitConverter]::ToUInt32($taskRx,28)
   # Purpose: decode camera status independently of the PHY snapshot. Old RAW8
   # images leave detail bits zero; zero detail does not clear aggregate fault.
   if($Profile -eq 'RAW8'){
    $taskRaw8Status=[ordered]@{sensor_ready=[bool]($taskFlags -band 256);
     frame_published=[bool]($taskFlags -band 512);hdmi_underflow=[bool]($taskFlags -band 1024);
     aggregate_core_or_bridge_fault=[bool]($taskFlags -band 128);
     bridge_read_fault=[bool]($taskFlags -band 16384);bridge_write_fault=[bool]($taskFlags -band 32768);
     writer_fault=[bool]($taskFlags -band 0x01000000);read_arbiter_fault=[bool]($taskFlags -band 0x02000000);
     frame_pool_fault=[bool]($taskFlags -band 0x04000000);network_fault=[bool]($taskFlags -band 0x08000000);
     read_queue_overflow=[bool]($taskFlags -band 0x10000000);writer_first_error=($taskFlags -shr 29)}
   }
   # Optional versioned PHY snapshot: inspect only when explicitly advertised.
   # Old images remain compatible and are not sent an unsupported command05.
   if($taskCapabilities -band 16){
    $taskRx=Exchange (New-Request 5 4 $taskPayload)
    if($taskRx[8] -ne 0 -or $taskRx[39] -ne 1){throw 'Unsupported/failed PHY diagnostic snapshot'}
    [uint32]$taskPhyWord=[BitConverter]::ToUInt32($taskRx,32)
    $taskDiagnostics=[ordered]@{version=1;phy_id=('{0:X8}' -f [BitConverter]::ToUInt32($taskRx,28));
     step=($taskPhyWord -shr 26);phy_address=(($taskPhyWord -shr 21) -band 31);
     last_ack_error=[bool]($taskPhyWord -band 0x100000);last_read=('{0:X4}' -f ($taskPhyWord -band 65535));
     phy_status=('{0:X4}' -f [BitConverter]::ToUInt16($taskRx,36))}
   }
   # Purpose: decode the frozen first WORD violation only when capability5 is
   # advertised. Version0/all-zero means no snapshot, not a validated stream.
   if($taskCapabilities -band 32){
    $taskRx=Exchange (New-Request 6 5 $taskPayload)
    if($taskRx[8] -ne 0 -or $taskRx[39] -notin @(0,1)){throw 'Unsupported/failed video diagnostic snapshot'}
    $taskVideoSnapshot=[ordered]@{version=$taskRx[39];valid=[bool]($taskRx[38] -band 1);
     active=[bool]($taskRx[38] -band 2);offset_mismatch=[bool]($taskRx[38] -band 4);
     count_overrun=[bool]($taskRx[38] -band 8);column_word=$taskRx[37];
     received_offset=([BitConverter]::ToUInt32($taskRx,28) -band 0xffffff);
     expected_offset=([BitConverter]::ToUInt32($taskRx,31) -band 0xffffff);
     accepted_words=([BitConverter]::ToUInt32($taskRx,34) -band 0xffffff)}
   }
   # Purpose: capability-gated diagnostic pages, each an independent snapshot.
   # Counts wrap modulo their widths; no cross-page frame pairing is inferred.
   if($taskCapabilities -band 64){
    $taskChain=[ordered]@{}
    $taskRx=Exchange (New-Request 7 6 $taskPayload)
    if($taskRx[8] -ne 0 -or $taskRx[39] -notin @(0,1)){throw 'DVP geometry query failed'}
    $taskChain.geometry=[ordered]@{version=$taskRx[39];frame_edges=[BitConverter]::ToUInt16($taskRx,28);
     low_vsync_lines=[BitConverter]::ToUInt16($taskRx,30);min_width=[BitConverter]::ToUInt16($taskRx,32);
     max_width=[BitConverter]::ToUInt16($taskRx,34);high_vsync_lines=[BitConverter]::ToUInt16($taskRx,36);
     capture_flags=$taskRx[38];configured=[bool]($taskRx[38] -band 128);armed=[bool]($taskRx[38] -band 64);
     active=[bool]($taskRx[38] -band 32);bad=[bool]($taskRx[38] -band 16);
     closing=[bool]($taskRx[38] -band 8);result_pending=[bool]($taskRx[38] -band 4);
     word_pending=[bool]($taskRx[38] -band 2);overflow=[bool]($taskRx[38] -band 1)}
    $taskRx=Exchange (New-Request 8 7 $taskPayload)
    if($taskRx[8] -ne 0){throw 'DVP progress query failed'}
    $taskChain.progress=[ordered]@{pclk_cycles=[BitConverter]::ToUInt32($taskRx,28);
     rejected=[BitConverter]::ToUInt32($taskRx,32);overflow_frames=[BitConverter]::ToUInt32($taskRx,36)}
    $taskRx=Exchange (New-Request 9 8 $taskPayload)
    if($taskRx[8] -ne 0){throw 'Pipeline query failed'}
    $taskChain.pipeline=[ordered]@{starts=[BitConverter]::ToUInt16($taskRx,28);
     ends=[BitConverter]::ToUInt16($taskRx,30);words=[BitConverter]::ToUInt32($taskRx,32);
     writes=[BitConverter]::ToUInt16($taskRx,36);capture_fsm=($taskRx[38] -shr 6);
     hdmi_fsm=(($taskRx[38] -shr 3) -band 7);record_valid=[bool]($taskRx[38] -band 4);
     record_ready=[bool]($taskRx[38] -band 2);commit=[bool]($taskRx[38] -band 1);
     writer_active=[bool]($taskRx[39] -band 128);writer_fsm=(($taskRx[39] -shr 4) -band 7);
     awvalid=[bool]($taskRx[39] -band 8);fence_request=[bool]($taskRx[39] -band 4);
     writer_ready=[bool]($taskRx[39] -band 2);wready=[bool]($taskRx[39] -band 1)}
   }
  }
 }
}catch {$taskError=$_.Exception.Message}
finally {
 $taskSerial.Dispose()
 New-Item -ItemType Directory -Path (Split-Path $taskReport) -Force | Out-Null
 [ordered]@{action=$Action;port=$Port;pnp=$taskDevice.InstanceId;records=$taskRecords.ToArray();status_flags=$taskFlags;diagnostics=$taskDiagnostics;raw8_status=$taskRaw8Status;video_snapshot=$taskVideoSnapshot;chain=$taskChain;error=$taskError} | ConvertTo-Json -Depth 7 | Tee-Object -FilePath $taskReport
}
if($taskError){throw $taskError}
