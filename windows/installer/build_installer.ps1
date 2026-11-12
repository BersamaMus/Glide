# Builds Glide for Windows and packs it into build\installer\Glide-Setup-<version>.exe.
# Run from anywhere: powershell -File windows\installer\build_installer.ps1
# Needs Inno Setup (winget install JRSoftware.InnoSetup).
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."

# The version as pubspec.yaml has it, without the build number: 1.0.0+3 is 1.0.0.
$line = Select-String -Path "$root\pubspec.yaml" -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $line) { throw 'No version in pubspec.yaml' }
$version = $line.Matches[0].Groups[1].Value.Split('+')[0]

$iscc = @(
  "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup not found. Install it with: winget install JRSoftware.InnoSetup' }

Push-Location $root
try {
  # A fresh build: Flutter never removes what it no longer builds, and
  # everything here goes into the installer.
  Remove-Item "$root\build\windows\x64\runner\Release" -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Building Glide $version for Windows..."
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

  Write-Host 'Packing the installer...'
  & $iscc "/DAppVersion=$version" "$PSScriptRoot\glide.iss"
  if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
  Write-Host "Done: build\installer\Glide-Setup-$version.exe"
} finally {
  Pop-Location
}
