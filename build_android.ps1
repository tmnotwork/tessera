# Build Android APK (output in LOCALAPPDATA; junction so Flutter finds APK)
$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$junctionTarget = Join-Path $env:LOCALAPPDATA "tessera_android_build\app\outputs\flutter-apk"
$junctionSource = Join-Path $projectRoot "build\app\outputs\flutter-apk"
$parentDir = Join-Path $projectRoot "build\app\outputs"

if (-not (Test-Path $junctionTarget)) {
    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
}

if (-not (Test-Path $parentDir)) {
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
}

if (Test-Path $junctionSource) {
    $item = Get-Item $junctionSource -Force
    $isJunction = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isJunction) {
        Write-Host "ERROR: build\app\outputs\flutter-apk exists as folder. Remove it first." -ForegroundColor Red
        Write-Host "  Remove-Item -Recurse -Force build\app\outputs\flutter-apk" -ForegroundColor Gray
        exit 1
    }
}
else {
    cmd /c mklink /J "$junctionSource" "$junctionTarget"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: mklink failed. Try running as Administrator." -ForegroundColor Red
        exit 1
    }
    Write-Host "Junction created: flutter-apk -> LOCALAPPDATA" -ForegroundColor Green
}

Set-Location $projectRoot
Write-Host "Running flutter build apk..." -ForegroundColor Cyan
flutter build apk --dart-define=dart.library.io.force_staggered_ipv6_lookup=true
if ($LASTEXITCODE -eq 0) {
    Write-Host "APK: build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Green
}
