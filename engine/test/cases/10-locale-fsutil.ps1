<#
  LOCALE :: the NTFS dirty bit
           (_lib.ps1 Get-FFVolumeDirtyBit, repair.ps1 Get-VolumeDirtyState)

  Rung 1 (FSCTL_IS_VOLUME_DIRTY) is locale-free and is what answers on a healthy host, so
  most of these tests force it OFF - the situation under WDAC/AppLocker, where Add-Type is
  blocked, and on any machine whose file system rejects the IOCTL - and then measure what
  the fsutil TEXT rung does with each UI language.

  The bar: English must reach the right verdict; every other language must reach
  dirty = $null ("could not determine"). A localized machine silently graded "clean" is
  precisely the failure doctrine rule 2 forbids, and chkdsk scheduling reads this value.
#>

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'dirty bit: the structured FSCTL rung answers without consulting fsutil' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{ fsutilCalls = 0 } -Mocks {
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
      $TestCtx.fsutilCalls++
      New-FFNativeResult -Text '' -ExitCode 1
    }
  } -Test {
    $TestCtx.res = Get-FFVolumeDirtyBit -Volume $env:SystemDrive -IsAdmin $false
  }
  Assert-Eq 'fsctl-is-volume-dirty' $r.res.source 'FSCTL_IS_VOLUME_DIRTY must be the source on a normal host, unelevated'
  Assert-NotNull $r.res.dirty 'the structured rung must produce a definite verdict'
  Assert-Eq 0 $r.fsutilCalls 'fsutil must NOT be consulted once the structured rung answered'
  Assert-Eq '0x00000020' $r.res.accessMask 'FILE_TRAVERSE (0x20) is the documented unelevated access mask'
}

foreach ($row in @(
  @{ Lang = 'en-US'; File = 'fsutil/en-US-clean.txt'; Expect = $false; Confident = $true }
  @{ Lang = 'en-US'; File = 'fsutil/en-US-dirty.txt'; Expect = $true;  Confident = $true }
  @{ Lang = 'de-DE'; File = 'fsutil/de-DE-clean.txt'; Expect = $null;  Confident = $false }
  @{ Lang = 'de-DE'; File = 'fsutil/de-DE-dirty.txt'; Expect = $null;  Confident = $false }
  @{ Lang = 'ja-JP'; File = 'fsutil/ja-JP-clean.txt'; Expect = $null;  Confident = $false }
  @{ Lang = 'ja-JP'; File = 'fsutil/ja-JP-dirty.txt'; Expect = $null;  Confident = $false }
  @{ Lang = 'fr-FR'; File = 'fsutil/fr-FR-clean.txt'; Expect = $null;  Confident = $false }
  @{ Lang = 'fr-FR'; File = 'fsutil/fr-FR-dirty.txt'; Expect = $null;  Confident = $false }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "dirty bit: fsutil text rung, $(Split-Path -Leaf $row.File)" -Body {
    $d = $FFTestData
    $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{ text = (Get-FFFixture -Path $d.File) } -Mocks {
      function Initialize-FFVolumeApi { $false }   # force the documented text rung
      function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
        $TestCtx.args = @($Arguments)
        $TestCtx.file = "$FilePath"
        New-FFNativeResult -Text $TestCtx.text -ExitCode 0
      }
    } -Test {
      $TestCtx.res = Get-FFVolumeDirtyBit -Volume 'C:' -IsAdmin $false
    }
    Assert-Match 'fsutil\.exe$' $r.file 'the text rung must call fsutil.exe'
    Assert-Eq 'dirty query C:' (@($r.args) -join ' ') 'fsutil must be invoked with the read-only "dirty query" verb'
    if ($d.Confident) {
      Assert-Eq $d.Expect $r.res.dirty 'English fsutil output must be read correctly'
      Assert-Eq 'fsutil-english-text' $r.res.source 'the verdict must declare that it came from the English text parse'
    } else {
      Assert-HonestUnknown $r.res.dirty "$($d.Lang) fsutil output"
      Assert-Match '^indeterminate' $r.res.source "$($d.Lang) must record an indeterminate source, not a verdict source"
      Assert-NotNull $r.res.fsutilOutput 'the unparsed output must be kept as evidence'
    }
  }
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'dirty bit: "is NOT Dirty" is never mistaken for "is Dirty"' -Body {
  # The negative form contains the word Dirty. Testing the two patterns in the wrong order
  # would invert the verdict on every clean English machine.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{ text = (Get-FFFixture -Path 'fsutil/en-US-clean.txt') } -Mocks {
    function Initialize-FFVolumeApi { $false }
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs) New-FFNativeResult -Text $TestCtx.text }
  } -Test { $TestCtx.res = Get-FFVolumeDirtyBit -Volume 'C:' -IsAdmin $false }
  Assert-Eq $false $r.res.dirty '"Volume - C: is NOT Dirty" must read as CLEAN'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'dirty bit: an access-denied fsutil says needs-admin, never clean' -Body {
  foreach ($fx in @('fsutil/en-US-access-denied.txt', 'fsutil/de-DE-access-denied.txt', 'fsutil/empty.txt')) {
    $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{ text = (Get-FFFixture -Path $fx) } -Mocks {
      function Initialize-FFVolumeApi { $false }
      function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs) New-FFNativeResult -Text $TestCtx.text -ExitCode 1 }
    } -Test { $TestCtx.res = Get-FFVolumeDirtyBit -Volume 'C:' -IsAdmin $false }
    Assert-HonestUnknown $r.res.dirty "an unelevated fsutil failure ($fx)"
    Assert-True $r.res.needsAdmin "$fx unelevated must set needsAdmin so the UI can offer elevation"
    Assert-Eq 'indeterminate-needs-admin' $r.res.source "$fx must name the reason it could not decide"
  }
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'dirty bit: the fsutil exit code alone is never used as a verdict' -Body {
  # Unelevated fsutil exits 1 for an access denial, which is indistinguishable by exit code
  # from a legitimate "not dirty". Deciding from it would be a confident unmeasured answer.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    function Initialize-FFVolumeApi { $false }
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs) New-FFNativeResult -Text '' -ExitCode 0 }
  } -Test { $TestCtx.res = Get-FFVolumeDirtyBit -Volume 'C:' -IsAdmin $true }
  Assert-HonestUnknown $r.res.dirty 'exit code 0 with no recognizable text'
  Assert-Eq 0 $r.res.fsutilExitCode 'the exit code is kept as evidence'
  Assert-Eq 'indeterminate' $r.res.source 'an elevated but unreadable result is plain indeterminate'
}

Register-FFTest -Area 'STATE' -Name 'dirty bit: the volume argument is normalized (D -> D:) for a non-C: system drive' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    function Initialize-FFVolumeApi { $false }
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
      $TestCtx.args = @($Arguments); New-FFNativeResult -Text '' -ExitCode 1 }
  } -Test {
    $TestCtx.bare = Get-FFVolumeDirtyBit -Volume 'D' -IsAdmin $false
    $TestCtx.argsBare = @($TestCtx.args)
    $TestCtx.slash = Get-FFVolumeDirtyBit -Volume 'D:\' -IsAdmin $false
    $TestCtx.argsSlash = @($TestCtx.args)
  }
  Assert-Eq 'D:' $r.bare.volume  'a bare drive letter is normalized to D:'
  Assert-Eq 'D:' $r.slash.volume 'a trailing backslash is trimmed'
  Assert-Eq 'dirty query D:' (@($r.argsBare) -join ' ')  'fsutil is asked about D:, not a hard-coded C:'
  Assert-Eq 'dirty query D:' (@($r.argsSlash) -join ' ') 'the D:\ form resolves to the same query'
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'repair.ps1 Get-VolumeDirtyState degrades honestly when every rung fails' -Body {
  # Also proves the miniature ladder inside repair.ps1 survives an older _lib.ps1 that has
  # no Get-FFVolumeDirtyBit at all - the reason that fallback exists.
  $r = Invoke-InEngineScope -Engine 'repair' -Ctx @{} -Mocks {
    Remove-Item -Path 'function:Get-FFVolumeDirtyBit' -ErrorAction SilentlyContinue
    function Get-CimInstance { param($ClassName, $Filter, $Namespace, $ErrorAction)
      throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
  } -Test {
    # Rung 3 shells out to fsutil directly. Point $env:SystemRoot at a folder that has no
    # System32\fsutil.exe so nothing is executed, then assert the outcome.
    $old = $env:SystemRoot
    $env:SystemRoot = [System.IO.Path]::GetTempPath()
    try { $TestCtx.res = Get-VolumeDirtyState -DriveLetter 'C:' } finally { $env:SystemRoot = $old }
  }
  Assert-HonestUnknown $r.res.dirty "repair.ps1's dirty read with every rung unavailable"
  Assert-Eq $false $r.res.readable 'readable must stay false so no caller can mistake it for "clean"'
  Assert-Eq 'C:' $r.res.drive 'the drive it answered about is reported'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'BootExecute: only a real scheduled autochk for THIS volume counts' -Body {
  $r = Invoke-InEngineScope -Engine 'repair' -Test {
    $default   = @('autocheck autochk *')
    $scheduled = @('autocheck autochk *', 'autocheck autochk /r \??\C:')
    $otherVol  = @('autocheck autochk *', 'autocheck autochk /r \??\D:')
    $TestCtx.defaultC   = Test-BootExecuteSchedulesVolume -Entries $default   -DriveLetter 'C:'
    $TestCtx.scheduledC = Test-BootExecuteSchedulesVolume -Entries $scheduled -DriveLetter 'C:'
    $TestCtx.otherC     = Test-BootExecuteSchedulesVolume -Entries $otherVol  -DriveLetter 'C:'
    $TestCtx.otherD     = Test-BootExecuteSchedulesVolume -Entries $otherVol  -DriveLetter 'D:'
    $TestCtx.emptyC     = Test-BootExecuteSchedulesVolume -Entries @()        -DriveLetter 'C:'
  }
  Assert-False $r.defaultC 'the wildcard default present on every machine must NOT read as a scheduled check'
  Assert-True  $r.scheduledC 'an explicit \??\C: entry must read as a scheduled check'
  Assert-False $r.otherC 'a check scheduled for D: must not be attributed to C:'
  Assert-True  $r.otherD 'a non-C: system drive is detected on its own letter'
  Assert-False $r.emptyC 'no entries means no scheduled check'
}
