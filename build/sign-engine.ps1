# Authenticode-signs every engine .ps1 in a packed app directory, then VERIFIES each one
# carries a signature whose hash matches the file. Called by build/afterPack.js with the
# same certificate that signs the exes.
#
# Why this exists: electron/main.js documents that on machines where Group Policy sets
# "Turn on Script Execution = AllSigned", the only complete fix is Authenticode-signed
# engine scripts. Shipping unsigned .ps1 files makes the app silently dead on exactly the
# managed machines most likely to need it.
#
# With the dev certificate the signature chain is untrusted (by design — see
# docs/signing.md); what is verified here is that signing HAPPENED and the digest is
# intact: Status must be Valid or UnknownError (untrusted root), never NotSigned or
# HashMismatch.
param(
  [Parameter(Mandatory)][string]$PfxPath,
  [Parameter(Mandatory)][string]$PasswordFile,
  [Parameter(Mandatory)][string]$EngineDir,
  [string]$TimestampServer = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $EngineDir)) { throw "engine dir not found: $EngineDir" }
$password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
$flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $password, $flags)

$scripts = Get-ChildItem -LiteralPath $EngineDir -Filter '*.ps1' -File
if (-not $scripts) { throw "no .ps1 files found under $EngineDir — wrong directory?" }

foreach ($f in $scripts) {
  $r = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $TimestampServer
  if ($r.Status -eq 'Valid' -or $r.Status -eq 'UnknownError') { continue }
  # One retry without the timestamp server: a flaky TSA must not fail the build, but the
  # fallback is stated on stdout so the build log shows which artifacts lack a timestamp.
  Write-Output "timestamped signing of $($f.Name) returned $($r.Status); retrying without timestamp"
  $r = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256
  if ($r.Status -ne 'Valid' -and $r.Status -ne 'UnknownError') {
    throw "signing $($f.Name) failed: $($r.Status) $($r.StatusMessage)"
  }
}

# Verify by reading back, not by trusting the signing call's return value.
$bad = @()
foreach ($f in $scripts) {
  $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
  if ($sig.Status -eq 'NotSigned' -or $sig.Status -eq 'HashMismatch' -or -not $sig.SignerCertificate) {
    $bad += "$($f.Name): $($sig.Status)"
  }
}
if ($bad.Count) { throw ("engine signature verification failed — " + ($bad -join '; ')) }
Write-Output "signed + verified $($scripts.Count) engine scripts in $EngineDir (signer: $($cert.Subject))"
