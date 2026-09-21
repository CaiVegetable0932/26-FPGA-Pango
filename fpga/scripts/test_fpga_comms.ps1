# Purpose: one offline-only regression entry for both communication protocols.
# Each child creates its own new evidence directory and fails on missing PASS.
# This script never builds/downloads a bitstream or accesses physical interfaces.
param([string]$ModelSimHome='E:/ModelsimSE/win64',
      [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'sim_mcu_protocol.ps1') -ModelSimHome $ModelSimHome
& (Join-Path $PSScriptRoot 'sim_praw_packetizer.ps1') -ModelSimHome $ModelSimHome
& (Join-Path $PSScriptRoot 'sim_udp_ethernet.ps1') -ModelSimHome $ModelSimHome
& (Join-Path $PSScriptRoot 'sim_video_network.ps1') -ModelSimHome $ModelSimHome
& (Join-Path $PSScriptRoot 'sim_pango_rgmii_tx.ps1') -ModelSimHome $ModelSimHome -PdsHome $PdsHome
Write-Output 'FPGA_COMMS_REGRESSION_PASS (offline simulation only)'
