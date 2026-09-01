# Signs every UNSIGNED .dll in the packed app, then verifies. Discord (this project's
# shipping bar) signs every PE file it ships, including the Electron runtime DLLs
# (ffmpeg.dll, libEGL.dll, libGLESv2.dll, vk_swiftshader.dll, vulkan-1.dll); electron-builder
# only signs .exe files by default, which left exactly those five NotSigned in our build.
#
# Only NotSigned files are touched: a DLL that arrives with a vendor signature
# (e.g. a Microsoft-signed d3dcompiler) keeps it — replacing a trusted vendor chain with
# ours would be a downgrade, the same rule afterPack.js applies to PresentMon.exe.
param(
  [Parameter(Mandatory)][string]$PfxPath,
  [Parameter(Mandatory)][string]$PasswordFile,
  [Parameter(Mandatory)][string]$AppDir,
  [string]$TimestampServer = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AppDir)) { throw "app dir not found: $AppDir" }
$password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
$flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $password, $flags)

$dlls = Get-ChildItem -LiteralPath $AppDir -Filter '*.dll' -Recurse -File
$unsigned = @($dlls | Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -eq 'NotSigned' })
foreach ($f in $unsigned) {
  $r = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $TimestampServer
  if ($r.Status -eq 'Valid' -or $r.Status -eq 'UnknownError') { continue }
  Write-Output "timestamped signing of $($f.Name) returned $($r.Status); retrying without timestamp"
  $r = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256
  if ($r.Status -ne 'Valid' -and $r.Status -ne 'UnknownError') {
    throw "signing $($f.Name) failed: $($r.Status) $($r.StatusMessage)"
  }
}

# Verify by reading back: NOTHING under the app dir may remain NotSigned or HashMismatch.
$bad = @()
foreach ($f in $dlls) {
  $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
  if ($sig.Status -eq 'NotSigned' -or $sig.Status -eq 'HashMismatch') { $bad += "$($f.Name): $($sig.Status)" }
}
if ($bad.Count) { throw ("DLL signature verification failed — " + ($bad -join '; ')) }
Write-Output "signed $($unsigned.Count) previously-unsigned DLLs; all $($dlls.Count) shipped DLLs now carry intact signatures"
