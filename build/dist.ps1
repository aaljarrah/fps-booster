# The one build entry point: `npm run dist`.
# Ensures the icon and a signing certificate exist, then runs electron-builder with the
# signing env wired. Everything it produces lands in dist/: FrameForgeSetup.exe (signed),
# latest.yml + .blockmap (auto-update feed), and SHA256SUMS.txt.
#
# Certificate resolution (docs/signing.md):
#   FF_CSC_LINK + FF_CSC_PASSWORD set  → real certificate, used as-is.
#   otherwise                          → local dev certificate (created on first run).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# 1. Icon (deterministic; regenerated only if missing).
$icon = Join-Path $PSScriptRoot 'icon.png'
if (-not (Test-Path -LiteralPath $icon)) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'generate-icon.ps1') | Write-Output
}

# 2. Signing certificate → CSC_LINK / CSC_KEY_PASSWORD for electron-builder's signtool.
if ($env:FF_CSC_LINK) {
  $env:CSC_LINK = $env:FF_CSC_LINK
  $env:CSC_KEY_PASSWORD = $env:FF_CSC_PASSWORD
  Write-Output "signing with provided certificate: $($env:FF_CSC_LINK)"
} else {
  $pfx = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'ensure-dev-cert.ps1') | Select-Object -Last 1
  if (-not $pfx -or -not (Test-Path -LiteralPath $pfx)) { throw "ensure-dev-cert.ps1 did not produce a PFX (got: '$pfx')" }
  $env:CSC_LINK = $pfx
  $env:CSC_KEY_PASSWORD = (Get-Content -LiteralPath "$pfx.password" -Raw).Trim()
  Write-Output "signing with LOCAL DEV certificate (untrusted chain by design): $pfx"
}

# 3. Build. --publish never: publishing is release automation's job (.github/workflows/release.yml).
Push-Location $root
try {
  npx electron-builder --config electron-builder.config.js --win --x64 --publish never
  if ($LASTEXITCODE -ne 0) { throw "electron-builder failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }

# 4. Checksums for the release page.
$setup = Join-Path $root 'dist\FrameForgeSetup.exe'
if (-not (Test-Path -LiteralPath $setup)) { throw 'expected dist\FrameForgeSetup.exe was not produced' }
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLower()
Set-Content -LiteralPath (Join-Path $root 'dist\SHA256SUMS.txt') -Value "$hash  FrameForgeSetup.exe" -Encoding ascii
Write-Output ("built dist\FrameForgeSetup.exe ({0:N1} MB), sha256 {1}" -f ((Get-Item $setup).Length / 1MB), $hash)
