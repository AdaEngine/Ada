param(
    [Parameter(Mandatory = $true)][string]$Sdk,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$VulkanSdk = $env:VULKAN_SDK
)
# Builds adaengine_ngx.dll against the NVIDIA DLSS SDK. The SDK is read from $Sdk and is never copied into the repository.
$ErrorActionPreference = "Stop"
if (-not $VulkanSdk) { throw "Set VULKAN_SDK or pass -VulkanSdk (the Vulkan headers are required)." }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $install) { throw "MSVC build tools were not found." }
$vcvars = Join-Path $install "VC\Auxiliary\Build\vcvars64.bat"
New-Item -ItemType Directory -Force $Output | Out-Null
$source = $PSScriptRoot
$library = Join-Path $Sdk "lib\Windows_x86_64\x64\nvsdk_ngx_d.lib"
if (-not (Test-Path $library)) { throw "NGX static library not found: $library" }
$env:PATH = "$(Split-Path $vswhere);$env:PATH"
$command = "cl /nologo /LD /O2 /MD /EHsc /std:c++17 /I`"$source`" /I`"$Sdk\include`" /I`"$VulkanSdk\Include`" `"$source\ada_ngx.cpp`" /Fe:`"$Output\adaengine_ngx.dll`" /Fo:`"$Output\\`" /link `"$library`" /LIBPATH:`"$VulkanSdk\Lib`" advapi32.lib user32.lib"
$script = Join-Path $Output "build.cmd"
Set-Content -Path $script -Encoding ascii -Value "@echo off`r`ncall `"$vcvars`" >nul`r`n$command"
cmd /c "`"$script`""
if ($LASTEXITCODE -ne 0) { throw "Bridge build failed ($LASTEXITCODE)." }
Write-Host "Built $Output\adaengine_ngx.dll"
