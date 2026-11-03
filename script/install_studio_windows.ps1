# Build and install standalone Ada Studio, or install an extracted release directory.
<#
.SYNOPSIS
Installs Ada Studio for the current Windows user, without administrator rights.
.EXAMPLE
./script/install_studio_windows.ps1
.EXAMPLE
./script/install_studio_windows.ps1 -SourcePath 'D:/Downloads/AdaStudio-v1-windows-x86_64'
#>
[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/Ada Studio'),
    [string]$ScratchPath,
    [ValidateRange(1, 64)][int]$Jobs = 2,
    [switch]$NoShortcut,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }

function Get-StudioFullPath([string]$Path) {
    # Resolve existing ancestors too: %TEMP% can contain an 8.3 alias of the user folder.
    $full = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) { return (Resolve-Path -LiteralPath $full).ProviderPath.TrimEnd('\', '/') }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not $parent) { throw "Cannot resolve installation path: $Path" }
    return Join-Path (Get-StudioFullPath $parent) ([IO.Path]::GetFileName($full))
}

function Assert-StudioDirectory([string]$Directory) {
    foreach ($relative in @('AdaEditor.exe', 'adastudio.exe', 'BuildSDK/sdk.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $relative) -PathType Leaf)) {
            throw "Incomplete Studio distribution: missing $relative in $Directory. Use the complete extracted release."
        }
    }
    foreach ($relative in @('AdaEditor_AdaEditor.resources/Assets', 'AdaEngine_AdaRender.resources')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $relative) -PathType Container)) {
            throw "Incomplete Studio distribution: missing $relative in $Directory."
        }
    }
}

function Remove-InstallerDirectory([string]$Directory, [string]$Parent) {
    # Only remove the installer's own uniquely named siblings, never a supplied path.
    $full = [IO.Path]::GetFullPath($Directory)
    if ([IO.Path]::GetDirectoryName($full) -ne $Parent -or
        [IO.Path]::GetFileName($full) -notmatch '^\.ada-studio-(stage|backup|build)-[a-f0-9]{32}$') {
        throw "Refusing to remove an unexpected installer path: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

$studioDestination = Get-StudioFullPath $InstallDirectory
$studioParent = [IO.Path]::GetDirectoryName($studioDestination)
if (-not $studioParent -or $studioDestination -eq [IO.Path]::GetPathRoot($studioDestination).TrimEnd('\')) {
    throw 'InstallDirectory must be an application folder, not a drive root.'
}
$studioStage = Join-Path $studioParent ('.ada-studio-stage-' + [guid]::NewGuid().ToString('N'))
$studioBackup = Join-Path $studioParent ('.ada-studio-backup-' + [guid]::NewGuid().ToString('N'))
$studioBuildParent = Get-StudioFullPath ([IO.Path]::GetTempPath())
$studioBuild = Join-Path $studioBuildParent ('.ada-studio-build-' + [guid]::NewGuid().ToString('N'))
$studioInstalled = $false
try {
    if (-not $SourcePath -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'AdaEditor.exe'))) {
        $SourcePath = $PSScriptRoot
    }
    if (-not $SourcePath) {
        $studioBuilder = Join-Path $PSScriptRoot 'build_studio_windows.ps1'
        if (-not (Test-Path -LiteralPath $studioBuilder)) { throw 'Provide -SourcePath with a complete Studio distribution.' }
        $studioBin = (& $studioBuilder -Configuration release -ScratchPath $ScratchPath -Jobs $Jobs | Select-Object -Last 1).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Studio build failed.' }
        $SourcePath = (& python (Join-Path $PSScriptRoot 'package_studio_windows.py') `
            --bin $studioBin --compiler-root $env:ADAENGINE_GRAVITY_PACKAGE_PATH --tint $env:TINT_EXECUTABLE `
            --output $studioBuild --version local-install --stage-only | Select-Object -Last 1).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Studio packaging failed.' }
    }
    $studioSource = Get-StudioFullPath $SourcePath
    Assert-StudioDirectory $studioSource
    if ($studioSource -eq $studioDestination -or
        $studioSource.StartsWith($studioDestination + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $studioDestination.StartsWith($studioSource + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourcePath and InstallDirectory must be separate, non-overlapping directories.'
    }
    if (Test-Path -LiteralPath $studioDestination) {
        $studioExisting = Get-Item -LiteralPath $studioDestination -Force
        if ($studioExisting.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'InstallDirectory must not be a link or junction.' }
        Assert-StudioDirectory $studioDestination
    }
    foreach ($studioProcess in @(Get-Process -Name AdaEditor, adastudio -ErrorAction SilentlyContinue)) {
        if ($studioProcess.Path -and $studioProcess.Path.StartsWith($studioDestination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Close Ada Studio and its command-line tools before updating this installation.'
        }
    }
    New-Item -ItemType Directory -Path $studioParent -Force | Out-Null
    New-Item -ItemType Directory -Path $studioStage | Out-Null
    Get-ChildItem -LiteralPath $studioSource -Force | Copy-Item -Destination $studioStage -Recurse -Force
    Assert-StudioDirectory $studioStage
    if (Test-Path -LiteralPath $studioDestination) { Move-Item -LiteralPath $studioDestination -Destination $studioBackup }
    try {
        Move-Item -LiteralPath $studioStage -Destination $studioDestination
        $studioInstalled = $true
    } catch {
        if (Test-Path -LiteralPath $studioBackup) { Move-Item -LiteralPath $studioBackup -Destination $studioDestination }
        throw
    }
    Remove-InstallerDirectory $studioBackup $studioParent
    if (-not $NoShortcut) {
        try {
            $studioPrograms = [Environment]::GetFolderPath('Programs')
            $studioShell = New-Object -ComObject WScript.Shell
            $studioShortcut = $studioShell.CreateShortcut((Join-Path $studioPrograms 'Ada Studio.lnk'))
            $studioShortcut.TargetPath = Join-Path $studioDestination 'AdaEditor.exe'
            $studioShortcut.WorkingDirectory = $studioDestination
            $studioShortcut.IconLocation = $studioShortcut.TargetPath + ',0'
            $studioShortcut.Save()
        } catch {
            Write-Warning "Studio is installed, but the Start menu shortcut could not be created: $_"
        }
    }
    Write-Host "Installed Ada Studio: $studioDestination"
    if ($Launch) {
        Start-Process -FilePath (Join-Path $studioDestination 'AdaEditor.exe') -WorkingDirectory $studioDestination -WindowStyle Normal
    }
} finally {
    Remove-InstallerDirectory $studioStage $studioParent
    Remove-InstallerDirectory $studioBuild $studioBuildParent
    if (-not $studioInstalled -and (Test-Path -LiteralPath $studioBackup)) {
        Write-Warning "The previous installation is preserved at $studioBackup"
    }
}
