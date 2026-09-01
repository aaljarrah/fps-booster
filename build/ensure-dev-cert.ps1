# Ensures a LOCAL, DEVELOPMENT-ONLY code-signing certificate exists and prints its PFX path.
#
# This is the test half of the signing pipeline. Every build artifact — the app exe, the
# installer, the uninstaller and each engine .ps1 — is Authenticode-signed and RFC3161
# timestamped with this certificate, so the entire signing path is exercised end to end.
# What a self-signed certificate cannot provide is TRUST: machines that have never seen it
# report the chain as untrusted, and SmartScreen has no reputation for it.
#
# THE ONE SWAP FOR A REAL CERTIFICATE (see docs/signing.md):
#   set FF_CSC_LINK  = path to your purchased .pfx  (or use Azure Trusted Signing)
#   set FF_CSC_PASSWORD = its password
# and this script is skipped entirely. Nothing else in the build changes.
#
# The PFX lives in build/certs/ (gitignored). The password is random per machine and kept
# beside it — it protects nothing (the cert is trust-less by design); it exists because
# signtool requires one.
$ErrorActionPreference = 'Stop'
$certDir = Join-Path $PSScriptRoot 'certs'
$pfxPath = Join-Path $certDir 'frameforge-dev.pfx'
$pwPath = Join-Path $certDir 'frameforge-dev.pfx.password'
$subject = 'CN=FrameForge Development Signing (untrusted test certificate)'

if ((Test-Path $pfxPath) -and (Test-Path $pwPath)) {
  Write-Output $pfxPath
  exit 0
}

New-Item -ItemType Directory -Force -Path $certDir | Out-Null

$cert = New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject $subject `
  -KeyAlgorithm RSA -KeyLength 3072 `
  -HashAlgorithm SHA256 `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -NotAfter (Get-Date).AddYears(3)

# RNGCryptoServiceProvider, not RandomNumberGenerator::Fill — this must run on Windows
# PowerShell 5.1 (.NET Framework), where Fill does not exist.
$bytes = New-Object byte[] 24
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
$rng.GetBytes($bytes)
$rng.Dispose()
$password = [Convert]::ToBase64String($bytes)
Set-Content -LiteralPath $pwPath -Value $password -NoNewline -Encoding ascii

$secure = ConvertTo-SecureString -String $password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $secure | Out-Null

# The private key does not need to stay in the user's store once exported.
Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $cert.Thumbprint) -ErrorAction SilentlyContinue

Write-Output $pfxPath
