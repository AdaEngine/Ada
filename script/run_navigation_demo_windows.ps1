# Forward to the independently packaged navigation example.
[CmdletBinding()]
param([switch]$ValidateScript, [string]$CapturePath, [string]$ScratchPath, [string]$ExamplesRoot = $env:ADAEXAMPLES_PATH)
$ErrorActionPreference = 'Stop'
if (-not $ExamplesRoot) { throw 'Set ADAEXAMPLES_PATH or pass -ExamplesRoot for the AdaExamples checkout.' }
$launcher = Join-Path $ExamplesRoot 'Examples/Technical/Navigation/script/run_windows.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Navigation example not found: $launcher" }
$previousEngineRoot = $env:ADAENGINE_ROOT
try {
    $env:ADAENGINE_ROOT = Split-Path -Parent $PSScriptRoot
    & $launcher -ValidateScript:$ValidateScript -CapturePath $CapturePath -ScratchPath $ScratchPath
} finally {
    $env:ADAENGINE_ROOT = $previousEngineRoot
}
