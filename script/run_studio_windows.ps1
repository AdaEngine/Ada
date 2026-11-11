# Builds, stages and opens the complete standalone Windows Studio.
[CmdletBinding()]
param(
    [string]$ScratchPath
)

$ErrorActionPreference = 'Stop'
$studioBin = (& (Join-Path $PSScriptRoot 'build_studio_windows.ps1') -Configuration release -ScratchPath $ScratchPath | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Studio build failed.' }
$studioRoot = Split-Path -Parent $PSScriptRoot
$studioVersion = 'standalone-local-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff')
$studioDirectory = (& python (Join-Path $PSScriptRoot 'package_studio_windows.py') `
    --bin $studioBin --compiler-root $env:ADAENGINE_GRAVITY_PACKAGE_PATH `
    --output (Join-Path $studioRoot '.build-tools/standalone-studio') --version $studioVersion --stage-only | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Standalone Studio staging failed.' }
Start-Process -FilePath (Join-Path $studioDirectory 'AdaEditor.exe') -WorkingDirectory $studioDirectory -WindowStyle Normal
