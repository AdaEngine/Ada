# Builds the native Windows Studio and prints the binary directory on the last line.
[CmdletBinding()]
param(
    [string]$ScratchPath,
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [ValidateRange(1, 64)][int]$Jobs = 2
)

$ErrorActionPreference = 'Stop'
$studioRoot = Split-Path -Parent $PSScriptRoot
$studioEditor = Join-Path $studioRoot 'Editor'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    throw 'This launcher requires Windows.'
}

# Headless builds are useful for tests, but cannot display Studio.
$env:ADAENGINE_HEADLESS = '0'
$env:ADAENGINE_DISABLE_SWAN = '0'
$env:ADAENGINE_PACKAGE_PATH = $studioRoot
if (-not $env:ADAEDITOR_SWIFTTERM_PACKAGE_PATH) {
    $studioSwiftTerm = & python (Join-Path $studioRoot 'script/ensure_windows_swiftterm.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows SwiftTerm preparation failed.' }
    $env:ADAEDITOR_SWIFTTERM_PACKAGE_PATH = ($studioSwiftTerm | Select-Object -Last 1).Trim()
}
if (-not $env:ADA_MCP_LOCAL_PATH) {
    $studioMCP = & python (Join-Path $studioRoot 'script/ensure_windows_mcp.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows AdaMCP dependency preparation failed.' }
    $env:ADA_MCP_LOCAL_PATH = ($studioMCP | Select-Object -Last 1).Trim()
}
& python (Join-Path $studioRoot 'script/ensure_windows_icon.py') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Studio icon compilation failed.' }

if (-not $env:ADAENGINE_GRAVITY_PACKAGE_PATH) {
    $studioGravity = & python (Join-Path $studioRoot 'script/ensure_windows_gravity.py')
    if ($LASTEXITCODE -ne 0) { throw 'Windows AdaScript dependency preparation failed.' }
    $env:ADAENGINE_GRAVITY_PACKAGE_PATH = ($studioGravity | Select-Object -Last 1).Trim()
}
& python (Join-Path $studioRoot 'script/ensure_windows_export_tools.py') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'AdaScript export compiler preparation failed.' }

if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $studioVS = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($studioVS) {
            $studioNinja = Join-Path $studioVS 'Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja'
            if (Test-Path -LiteralPath (Join-Path $studioNinja 'ninja.exe')) {
                $env:Path = "$studioNinja;$env:Path"
            }
        }
    }
}

$studioTint = & python (Join-Path $studioRoot 'script/ensure_tint.py') --jobs $Jobs
if ($LASTEXITCODE -ne 0) { throw 'Tint setup failed. Check Python, CMake, Ninja and the C++ toolchain.' }
$env:TINT_EXECUTABLE = ($studioTint | Select-Object -Last 1).Trim()

# Debug also prepares the package tests. Release ships the ordinary executable
# without enabling testable imports in production modules.
$studioProduct = if ($Configuration -eq 'release') { 'AdaEditor' } else { 'AdaEditorPackageTests' }
$studioBuildArguments = @('build', '--package-path', $studioEditor, '--configuration', $Configuration, '--jobs', $Jobs, '--product', $studioProduct)
if ($ScratchPath) { $studioBuildArguments += @('--scratch-path', $ScratchPath) }
$studioBuildLog = Join-Path $studioRoot ".build-tools/studio-$Configuration-build.log"
Write-Host "Building Studio ($Configuration); compiler log: $studioBuildLog"
& swift @studioBuildArguments *> $studioBuildLog
$studioBuildExit = $LASTEXITCODE
Get-Content -LiteralPath $studioBuildLog -Tail 30 | Out-Host
if ($studioBuildExit -ne 0) { throw "Studio build failed. See $studioBuildLog for full diagnostics." }

$studioBinaryArguments = @('build', '--package-path', $studioEditor, '--configuration', $Configuration, '--show-bin-path')
if ($ScratchPath) { $studioBinaryArguments += @('--scratch-path', $ScratchPath) }
$studioBin = (& swift @studioBinaryArguments | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not locate the built Studio executable.' }
Write-Output $studioBin
