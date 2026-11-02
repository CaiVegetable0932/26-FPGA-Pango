param([string]$Compiler='C:\MinGW\mingw64\bin\gcc.exe')
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'test.ps1') -Compiler $Compiler
