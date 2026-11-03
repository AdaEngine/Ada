param([string]$Capture = 'local-probes')
$ErrorActionPreference = 'Stop'
$env:PATH = 'C:/Users/Vladislav/AppData/Local/Programs/Swift/Runtimes/6.3.1/usr/bin;' + $env:PATH
$env:ADAENGINE_SHADER_SOURCE_ROOT = 'D:/Development/AdaEngine'
$env:TINT_EXECUTABLE = 'D:/Development/AdaEngine/.build-tools/tint/bin/x86_64-windows/tint.exe'
$env:ADAENGINE_SPONZA_ASSETS = 'D:/Development/AdaEngine/.build-codex/benchmark-assets/intel-sponza/assets'
$env:ADAENGINE_SPONZA_RENDER_PRESET = 'fullRaster'
$env:ADAENGINE_SPONZA_MESHLET_MAP = '0'
$env:ADAENGINE_SPONZA_MESHLETS = 'gpu'
$env:ADAENGINE_SPONZA_MESHLET_LOD = '2'
$env:ADAENGINE_SPONZA_PROFILE_STUTTER = '1'
$env:ADAENGINE_SPONZA_PROFILE_MESHLETS = '0'
$env:ADAENGINE_SPONZA_PROFILE_MESHLET_LOD = '0'
$env:ADAENGINE_STALL_PROBE = '1'
$env:ADAENGINE_STALL_THRESHOLD_MS = '15'
$captureStem = "D:/Development/AdaEngine/.build-codex/meshlets-scene-research/stutter/$Capture"
$env:ADAENGINE_SPONZA_PROFILE_OUTPUT = "$captureStem.json"
$stutterProcess = Start-Process -FilePath 'D:/Development/AdaEngine/.build-codex/meshlets-p0/x86_64-unknown-windows-msvc/release/SponzaDemo.exe' -WindowStyle Normal -WorkingDirectory 'D:/Development/AdaEngine' -RedirectStandardOutput "$captureStem.stdout.log" -RedirectStandardError "$captureStem.stderr.log" -PassThru
$stutterProcess.Id | Set-Content "$captureStem.pid"
$stutterProcess | Select-Object Id,ProcessName
