# Code signing

Every FrameForge release artifact is Authenticode-signed and RFC3161-timestamped:

| Artifact | Signed by | Why |
| --- | --- | --- |
| `FrameForge.exe` (the app) | electron-builder → signtool | identity + SmartScreen reputation |
| `FrameForgeSetup.exe` (installer) | electron-builder → signtool | what users actually download |
| `Uninstall FrameForge.exe` | electron-builder → signtool | uninstall must be as trustworthy as install |
| `engine/*.ps1` (all engines) | `build/sign-engine.ps1` (afterPack hook) | on machines where Group Policy sets **Turn on Script Execution = AllSigned**, unsigned engine scripts are refused and the app is silently dead — `electron/main.js` documents this as the only complete fix |
| Electron runtime DLLs (ffmpeg, libEGL, libGLESv2, vk_swiftshader, vulkan-1) | `build/sign-unsigned-dlls.ps1` (afterPack hook) | electron-builder signs only exes; Discord signs every PE it ships. Only DLLs that arrive **unsigned** are signed — vendor signatures (Intel's PresentMon.exe, any Microsoft-signed DLL) are kept, never replaced |

The pipeline runs on every `npm run dist`. There is no unsigned build path.

## Development signing (the default)

With no configuration, `build/dist.ps1` creates a **local, self-signed development
certificate** on first build (`build/ensure-dev-cert.ps1` → `build/certs/`, gitignored) and
signs everything with it. This exercises the entire signing path end to end — signtool,
timestamping, the engine-script pass, electron-updater's publisher check — with one honest
limitation: **the chain is untrusted on other machines**, so `signtool verify /pa` fails
chain validation there and SmartScreen shows "Unknown publisher". That is a property of any
test certificate, not a gap in the pipeline.

## The one swap for production

Set two environment variables before `npm run dist`:

```
FF_CSC_LINK     = C:\secrets\your-real-certificate.pfx   (or base64 of the PFX)
FF_CSC_PASSWORD = <its password>
FF_PUBLISHER_NAME = <the certificate's exact CN>          (electron-updater verifies
                                                           downloaded updates against this)
```

Nothing else changes — same build command, same hooks, same verification.

In CI (`.github/workflows/release.yml`), provide the same values as repository secrets
`FF_CSC_LINK_B64` (base64 of the PFX), `FF_CSC_PASSWORD`, and `FF_PUBLISHER_NAME`. Releases
built without the secrets are dev-signed and say so in the release notes.

### What to buy

- **OV certificate** (~$70–200/yr, e.g. Certum, SSL.com, Sectigo): valid signature
  immediately; SmartScreen reputation builds over downloads/weeks.
- **EV certificate or Azure Trusted Signing**: immediate SmartScreen reputation. Azure
  Trusted Signing (~$10/mo) is the cheapest route to it; electron-builder supports it via
  `win.azureSignOptions` if you prefer it over a PFX.

Discord (this project's shipping bar) uses an EV certificate from DigiCert; that is the
end state to aim for once downloads justify it.

## Verifying a build

```powershell
# exe + installer + uninstaller
Get-AuthenticodeSignature dist\FrameForgeSetup.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
# every engine script inside the packed app
Get-ChildItem 'dist\win-unpacked\resources\app\engine\*.ps1' | Get-AuthenticodeSignature | Format-Table Status, Path
# every PE file in the shipped payload — nothing may be NotSigned or HashMismatch
Get-ChildItem dist\win-unpacked -Recurse -Include *.exe, *.dll |
  Get-AuthenticodeSignature | Where-Object { $_.Status -in 'NotSigned', 'HashMismatch' } |
  Format-Table Status, Path   # empty output = pass
```

Dev-signed builds report `UnknownError` (= signature intact, chain untrusted) on machines
that don't hold the dev certificate; production builds report `Valid`. `NotSigned` or
`HashMismatch` anywhere is a release blocker.
