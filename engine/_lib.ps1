<#
  FrameForge :: _lib.ps1
  Shared helper library for engine scripts. Dot-source it:
    . (Join-Path $PSScriptRoot '_lib.ps1')

  Everything in here is read-only utility code — nothing mutates system state.
  PowerShell 5.1 compatible (no ternary, no ??, no null-conditional).

  PORTABILITY DOCTRINE (see docs/GAUNTLET.md rule 2): a helper here must never turn a
  failed or unattempted measurement into a confident answer. Where a signal cannot be
  read, the helper returns $null / 'unknown' and says why — it does not return $false.
#>

# ---------------- host environment ----------------

# PowerShell language mode. Under WDAC / AppLocker allowlist enforcement, scripts outside an
# allowed path run in ConstrainedLanguage, where [Security.Principal.*] casts, Add-Type and
# [xml] casts are all blocked. Engines read this and emit an honest JSON error document
# instead of dying with no output at all.
$script:FFLanguageMode = 'Unknown'
try { $script:FFLanguageMode = "$($ExecutionContext.SessionState.LanguageMode)" } catch {}
function Test-FFFullLanguage { return ($script:FFLanguageMode -eq 'FullLanguage') }

function New-FFLanguageModeError {
  <# The standard single JSON error document for a constrained-language host. #>
  [ordered]@{
    ok        = $false
    errorCode = 'constrained-language'
    error     = "PowerShell is running in $($script:FFLanguageMode) (WDAC/AppLocker application control). FrameForge's engines need FullLanguage; ask your administrator to allow the FrameForge script directory."
    languageMode = $script:FFLanguageMode
  }
}

# Native command output (sfc, powercfg, fsutil) is decoded through Console.OutputEncoding.
# UTF-8 (BOM-free) keeps stdout JSON clean for the Electron host. Guarded: throws when the
# process has no console (e.g. some hosted scenarios).
#
# CAVEAT (documented deliberately): assigning [Console]::OutputEncoding calls
# SetConsoleOutputCP(65001) for the whole console, and every child console process this engine
# launches then encodes its redirected stdout with that code page. A few legacy console tools
# truncate or drop output under CP 65001. The prior value is kept here so a caller can restore
# it, and Invoke-FFNative below sidesteps the console entirely by pinning an explicit
# StandardOutputEncoding on the child process. Prefer structured sources (registry, CIM,
# exit codes, event Ids, log FILES read with -Encoding) over anything that round-trips a
# console; that is what the probes in health.ps1 now do.
$script:FFConsoleEncodingPrior = $null
$script:FFConsoleEncodingForced = $false
try { $script:FFConsoleEncodingPrior = [Console]::OutputEncoding } catch {}
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $script:FFConsoleEncodingForced = $true
} catch {}

function Restore-FFConsoleEncoding {
  <# Puts the console output code page back the way it was found. Safe to call more than once. #>
  if (-not $script:FFConsoleEncodingForced) { return }
  try { [Console]::OutputEncoding = $script:FFConsoleEncodingPrior } catch {}
  $script:FFConsoleEncodingForced = $false
}

function Test-Admin {
  <#
    Layered so it survives ConstrainedLanguage:
      1. [Security.Principal.WindowsPrincipal] role check (exact; needs FullLanguage)
      2. whoami /groups matched against the LITERAL SID S-1-5-32-544 (BUILTIN\Administrators).
         SID strings are identical on every locale, so this rung is locale-independent —
         it is the group NAME that is localized, and we never look at the name.
    Returns $false only when both rungs failed to observe the role.
  #>
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {}
  try {
    $g = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null
    $txt = ((@($g) | ForEach-Object { "$_" }) -join "`n")
    # An admin token carries the group AND has it enabled; the SID alone is the portable signal.
    if ($txt -match 'S-1-5-32-544') { return $true }
  } catch {}
  return $false
}

function Write-FFJson {
  <#
    Emits exactly ONE JSON document on stdout, BOM-free.
    - Uses -InputObject (not the pipeline) so a single-element array is not unrolled
      into a bare object — the classic PS 5.1 ConvertTo-Json pitfall.
    - [Console]::Out avoids any host-added BOM and Write-Output enumeration.

    LANGUAGE MODE (this is the whole reason the function is not a one-liner):
    ConstrainedLanguage forbids method invocation on non-core types, and
    [System.Console] is not a core type — so `[Console]::Out.WriteLine($json)` throws
    "Cannot invoke method. Method invocation is supported only on core types in this
    language mode." That is precisely the mode in which the engines are documented to
    emit New-FFLanguageModeError, so the ONLY document that mattered under WDAC/AppLocker
    was the one document that could never be written: every engine died with empty stdout
    AND empty stderr, and the UI could only say "the engine returned no output".

    Write-Output writes to the success stream, which is language-mode safe. Measured, not
    assumed: a 6000-character single-line string round-tripped through a redirected
    `powershell -NoProfile -Command` came back as ONE line of exactly 6000 characters, so
    the success stream does not wrap or truncate the document. Emission is attempted in
    order and the FIRST rung that actually completes wins; if the console rung throws
    (constrained language, no attached console) the pipeline rung still writes the JSON.
  #>
  param(
    [Parameter(Mandatory)]$InputObject,
    [int]$Depth = 12,
    [switch]$Pretty
  )
  if ($Pretty) { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth }
  else         { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress }
  $written = $false
  if (Test-FFFullLanguage) {
    try {
      [Console]::Out.WriteLine($json)
      try { [Console]::Out.Flush() } catch {}
      $written = $true
    } catch { $written = $false }
  }
  if (-not $written) {
    # Constrained/Restricted/NoLanguage host, or a process with no console: the success
    # stream is the rung that still works. Write-Output does not enumerate a [string].
    Write-Output $json
  }
}

# ---------------- error classification (locale-independent) ----------------

function Test-FFAccessDenied {
  <#
    Is this ErrorRecord an access denial? Decided from the exception TYPE, the PowerShell
    error CATEGORY, and the Win32 code inside the HRESULT — never from the message text,
    which is localized ('denied' appears only on English Windows).
  #>
  param($ErrorRecord)
  if ($null -eq $ErrorRecord) { return $false }
  $ex = $ErrorRecord.Exception
  if ($ex -is [System.UnauthorizedAccessException]) { return $true }
  if ($ex -is [System.Security.SecurityException]) { return $true }
  try { if ("$($ErrorRecord.CategoryInfo.Category)" -eq 'PermissionDenied') { return $true } } catch {}
  # FACILITY_WIN32 HRESULTs are 0x8007xxxx; 5 = ERROR_ACCESS_DENIED, 32 = ERROR_SHARING_VIOLATION.
  try {
    $h = [int]$ex.HResult
    if ((($h -band [int]0xFFFF0000) -eq [int]0x80070000) -and (($h -band 0xFFFF) -in 5, 32)) { return $true }
  } catch {}
  try { if ($null -ne $ex.NativeErrorCode -and ([int]$ex.NativeErrorCode) -in 5, 32) { return $true } } catch {}
  return $false
}

function Get-FFEventErrorKind {
  <#
    Classifies a Get-WinEvent failure by ERROR IDENTITY, not by message text.
    PowerShell assigns these FullyQualifiedErrorIds regardless of UI language.
      no-events        NoMatchingEventsFound     — the filter matched nothing (see the caveat in Get-FFEvents)
      log-missing      NoMatchingLogsFound / EventLogNotFoundException
      provider-missing NoMatchingProvidersFound  — one named provider does not exist here, so the
                                                   WHOLE query was rejected and matched nothing
      access-denied    UnauthorizedAccessException / PermissionDenied / 0x80070005
      other            anything else
  #>
  param($ErrorRecord)
  if ($null -eq $ErrorRecord) { return 'other' }
  $fqid = ''
  try { $fqid = "$($ErrorRecord.FullyQualifiedErrorId)" } catch {}
  if ($fqid -like 'NoMatchingEventsFound*')    { return 'no-events' }
  if ($fqid -like 'NoMatchingLogsFound*')      { return 'log-missing' }
  if ($fqid -like 'NoMatchingProvidersFound*') { return 'provider-missing' }
  try { if ($ErrorRecord.Exception -is [System.Diagnostics.Eventing.Reader.EventLogNotFoundException]) { return 'log-missing' } } catch {}
  if (Test-FFAccessDenied -ErrorRecord $ErrorRecord) { return 'access-denied' }
  return 'other'
}

# ---------------- event log ----------------

# Last error message from Get-FFEvents when the failure was NOT simply "no events matched"
# (e.g. access denied, missing log channel). Callers that care can inspect it right after a call.
$script:FFLastEventError = $null
# Classification of that failure: 'access-denied' | 'log-missing' | 'provider-missing' | 'other'.
$script:FFLastEventErrorKind = $null
# $true when the returned empty array is NOT proof that no events exist — the channel could not
# be read at all. A caller that grades health from an empty result MUST check this first.
$script:FFLastEventUnreadable = $false

$script:FFLogReadable = @{}     # logName -> @{ readable; kind; error }
$script:FFProviderExists = @{}  # lowercased provider name -> [bool]

function Test-FFEventLogReadable {
  <#
    Can this channel be read at all? Cached per process.

    WHY THIS EXISTS: Get-WinEvent -FilterHashtable reports an ACCESS DENIAL as
    'NoMatchingEventsFound' — verified on Windows 11 25H2 (26200.9168) unelevated against
    Microsoft-Windows-Diagnostics-Performance/Operational, where the -FilterHashtable form
    throws NoMatchingEventsFound while the -LogName form throws UnauthorizedAccessException
    for the very same channel. Treating that as "no events" is how a probe silently grades an
    unreadable subsystem as healthy. The -LogName form is therefore used to re-probe.

    Returns @{ readable = $true|$false|$null; kind; error }. $null means the readability
    itself could not be established (e.g. the filter carried no LogName).
  #>
  param($LogName)
  $name = $null
  if ($LogName -is [System.Array]) { if (@($LogName).Count -gt 0) { $name = "$(@($LogName)[0])" } }
  else { $name = "$LogName" }
  if ([string]::IsNullOrWhiteSpace($name)) {
    return @{ readable = $null; kind = 'unknown'; error = 'The filter carried no LogName, so channel readability could not be re-probed.' }
  }
  if ($script:FFLogReadable.ContainsKey($name)) { return $script:FFLogReadable[$name] }
  $res = $null
  try {
    $null = Get-WinEvent -LogName $name -MaxEvents 1 -ErrorAction Stop
    $res = @{ readable = $true; kind = 'ok'; error = $null }
  } catch {
    $kind = Get-FFEventErrorKind -ErrorRecord $_
    if ($kind -eq 'no-events') {
      # The channel opened; it simply holds no events at all.
      $res = @{ readable = $true; kind = 'empty'; error = $null }
    } else {
      $res = @{ readable = $false; kind = $kind; error = "$($_.Exception.Message)" }
    }
  }
  $script:FFLogReadable[$name] = $res
  return $res
}

function Get-FFEventProviders {
  <#
    Filters a candidate provider-name list down to the providers that actually exist on this
    machine, case-insensitively de-duplicated, order preserved.

    WHY: Get-WinEvent -FilterHashtable rejects the ENTIRE query with NoMatchingProvidersFound
    when any single named provider is unknown here — verified: adding 'iaStorAC' (an Intel RST
    provider absent on a stock NVMe box) makes the whole Ntfs/disk/storahci/stornvme disk-error
    query return nothing. Adding provider names is therefore NOT free; they must be filtered
    first, and the probe must report which ones it actually queried.
  #>
  param([Parameter(Mandatory)][string[]]$Candidates)
  $out = @(); $seen = @{}
  foreach ($c in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    $key = $c.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (-not $script:FFProviderExists.ContainsKey($key)) {
      $exists = $false
      try { if (Get-WinEvent -ListProvider $c -ErrorAction Stop) { $exists = $true } } catch {}
      $script:FFProviderExists[$key] = $exists
    }
    if ($script:FFProviderExists[$key]) { $out += $c }
  }
  # Emitted plainly — collect with @(...) at the call site.
  $out
}

function Get-FFEvents {
  <#
    Wrapper over Get-WinEvent -FilterHashtable that never throws and never writes to the
    error stream. Returns an array (possibly empty).

    An empty array means one of two very different things, and the caller MUST tell them apart:
      $script:FFLastEventUnreadable -eq $false  -> genuinely no matching events
      $script:FFLastEventUnreadable -eq $true   -> the channel could not be read; the emptiness
                                                   proves nothing. $FFLastEventErrorKind and
                                                   $FFLastEventError say why.
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Filter,
    [int]$MaxEvents = 0
  )
  $script:FFLastEventError = $null
  $script:FFLastEventErrorKind = $null
  $script:FFLastEventUnreadable = $false
  try {
    if ($MaxEvents -gt 0) {
      $ev = @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop)
    } else {
      $ev = @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
    }
    # Emit plainly (enumerated) — callers collect with @(...). Do NOT comma-wrap here:
    # a comma-wrapped empty array re-nests under the caller's @() and fakes a count of 1.
    return $ev
  } catch {
    $rec = $_
    $kind = Get-FFEventErrorKind -ErrorRecord $rec
    if ($kind -eq 'no-events') {
      # Do NOT assume empty (see Test-FFEventLogReadable): re-probe the channel.
      $probe = Test-FFEventLogReadable -LogName $Filter['LogName']
      if ($probe.readable -eq $false) {
        $script:FFLastEventUnreadable = $true
        $script:FFLastEventErrorKind = $probe.kind
        $script:FFLastEventError = $probe.error
      }
      return @()
    }
    # Every other failure means the query did not run over the intended set — including
    # provider-missing, where the unknown provider name suppressed the known ones too.
    $script:FFLastEventError = "$($rec.Exception.Message)"
    $script:FFLastEventErrorKind = $kind
    $script:FFLastEventUnreadable = $true
    return @()
  }
}

function Measure-Probe {
  <#
    Runs a scriptblock and returns @{ result; durationMs; error }.
    A thrown error is captured (error message string), never propagated —
    one broken probe must not break a whole scan.
  #>
  param([Parameter(Mandatory)][scriptblock]$Script)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $result = $null; $err = $null
  try { $result = & $Script } catch { $err = "$($_.Exception.Message)" }
  $sw.Stop()
  @{ result = $result; durationMs = [int]$sw.ElapsedMilliseconds; error = $err }
}

function Get-FFEventDataMap {
  <#
    Named EventData fields of an event as a hashtable (name -> string value).
    Property indexes vary across Windows builds; names are stable — always prefer this
    over Properties[n] guessing. Returns @{} when the event has no parseable XML.

    This is also the locale-independent way to read an event: EventData field VALUES are
    raw data written by the provider, while $Event.Message is rendered from the provider's
    MUI resources and is both localized and $null when those resources cannot be loaded.
  #>
  param([Parameter(Mandatory)]$Event)
  $map = @{}
  try {
    $x = [xml]$Event.ToXml()
    foreach ($d in @($x.Event.EventData.Data)) {
      if ($null -ne $d -and $d.Name) { $map[$d.Name] = "$($d.'#text')" }
    }
  } catch {}
  $map
}

function ConvertTo-FFTime {
  <#
    ISO-8601 string for a nullable DateTime; $null stays $null.
    Event TimeCreated is nullable — calling .ToString() on it directly can throw
    and take a whole probe category down with it.
  #>
  param($Value)
  if ($null -ne $Value) { return $Value.ToString('s') }
  return $null
}

function ConvertTo-FFEventEvidence {
  <#
    Compact, JSON-safe evidence rows for a set of events: id, time (ISO), first message line.
    Message can be $null when provider metadata is missing — degrades to the provider name.
    Collect the result with @(...) at the call site.
  #>
  param($Events, [int]$First = 3)
  $rows = @()
  foreach ($e in (@($Events) | Select-Object -First $First)) {
    $msg = $null
    if ($e.Message) { $msg = ("$($e.Message)" -split "`r?`n")[0] } else { $msg = "(no message) provider=$($e.ProviderName)" }
    if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
    $t = $null
    if ($e.TimeCreated) { $t = $e.TimeCreated.ToString('s') }  # TimeCreated is nullable
    $rows += [ordered]@{ id = $e.Id; time = $t; message = $msg }
  }
  $rows
}

# ---------------- native command capture ----------------

function ConvertTo-FFNativeText {
  <#
    Joins captured native output into one string and strips interleaved NULs.
    Some in-box tools (sfc.exe most notably) write UTF-16, which surfaces through a redirected
    pipe as ASCII text with NUL between every character. Apply this UNIFORMLY to every native
    capture — a missing NUL-strip silently breaks any parse of that tool's output.
  #>
  param($Raw)
  (((@($Raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '')
}

function Invoke-FFNative {
  <#
    Runs a console tool out-of-process with an EXPLICIT stdout/stderr decoder, so the parse does
    not silently depend on the console code page this library forced to 65001.
    Returns @{ exitCode; stdout; stderr; text; error }. $exitCode is $null when the process
    could not be started; $error carries the reason.

    Read-only by contract: callers here pass query-only verbs (sfc /verifyonly, fsutil dirty
    query, Dism /AnalyzeComponentStore, powercfg /a). This helper does not police that.

    -Arguments are joined with a single space and NOT quoted, so a caller passing a path with
    spaces must quote it itself. Every caller in this engine passes bare switches and a drive
    letter, so no quoting is needed today.
  #>
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [System.Text.Encoding]$Encoding = $null,
    [int]$TimeoutMs = 0
  )
  $res = [ordered]@{ exitCode = $null; stdout = ''; stderr = ''; text = ''; error = $null }
  if ($null -eq $Encoding) { $Encoding = New-Object System.Text.UTF8Encoding($false) }
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if ($Arguments.Count -gt 0) { $psi.Arguments = ($Arguments -join ' ') }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Encoding
    $psi.StandardErrorEncoding = $Encoding
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    # Read both streams concurrently: reading one to end while the other fills its pipe buffer
    # is the classic redirect deadlock.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $exited = $true
    if ($TimeoutMs -gt 0) { $exited = $p.WaitForExit($TimeoutMs) } else { $p.WaitForExit() }
    if (-not $exited) {
      $res.error = "The command did not finish within $TimeoutMs ms."
    } else {
      $res.exitCode = $p.ExitCode
    }
    try { $res.stdout = "$($outTask.Result)" } catch {}
    try { $res.stderr = "$($errTask.Result)" } catch {}
    $res.text = (ConvertTo-FFNativeText @($res.stdout, $res.stderr))
  } catch {
    $res.error = "$($_.Exception.Message)"
  } finally {
    if ($null -ne $p) { try { $p.Dispose() } catch {} }
  }
  $res
}

# ---------------- volume dirty bit (locale-independent) ----------------

$script:FFVolumeApiReady = $null

function Initialize-FFVolumeApi {
  if ($null -ne $script:FFVolumeApiReady) { return $script:FFVolumeApiReady }
  $script:FFVolumeApiReady = $false
  if (-not (Test-FFFullLanguage)) { return $false }   # Add-Type is blocked under application control
  try {
    if (-not ('FFVolumeApi' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class FFVolumeApi {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
      IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
  [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
  private static extern bool DeviceIoControl(SafeFileHandle hDevice, uint dwIoControlCode,
      IntPtr lpInBuffer, uint nInBufferSize, ref uint lpOutBuffer, uint nOutBufferSize,
      out uint lpBytesReturned, IntPtr lpOverlapped);

  // FSCTL_IS_VOLUME_DIRTY = CTL_CODE(FILE_DEVICE_FILE_SYSTEM(0x09), 30, METHOD_BUFFERED, FILE_ANY_ACCESS)
  //   = (0x09 << 16) | (0 << 14) | (30 << 2) | 0 = 0x00090078.   Query only; it reads the flag.
  //   (FSCTL_MARK_VOLUME_DIRTY, the mutating one, is 0x00090030 and is never used here.)
  private const uint FSCTL_IS_VOLUME_DIRTY = 0x00090078;
  private const uint VOLUME_IS_DIRTY = 0x00000001;

  // 1 = dirty, 0 = clean, -1 = the volume could not be opened, -2 = the IOCTL was rejected.
  public static int QueryDirty(string volumePath, out uint accessUsed, out int win32Error) {
    accessUsed = 0; win32Error = 0;
    int lastOpenError = 0; int lastIoctlError = 0;
    // Access-mask ladder, measured on Windows 11 25H2 (26200.9168), UNELEVATED:
    //   0x20 FILE_TRAVERSE      -> CreateFile succeeds AND the IOCTL answers. This is the rung
    //                             that makes the dirty bit readable without administrator rights.
    //   0x80 FILE_READ_ATTRIBUTES -> CreateFile succeeds but the file system rejects the IOCTL
    //                             with ERROR_INVALID_FUNCTION (1).
    //   0x01 FILE_READ_DATA / 0x80000000 GENERIC_READ -> CreateFile fails with ERROR_ACCESS_DENIED (5)
    //                             unless elevated; kept as rungs for the elevated case.
    uint[] masks = new uint[] { 0x00000020, 0x00000080, 0x00000001, 0x80000000 };
    foreach (uint mask in masks) {
      using (SafeFileHandle h = CreateFileW(volumePath, mask, 0x00000003, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
        if (h.IsInvalid) { lastOpenError = Marshal.GetLastWin32Error(); continue; }
        uint outBuf = 0; uint bytes = 0;
        if (DeviceIoControl(h, FSCTL_IS_VOLUME_DIRTY, IntPtr.Zero, 0, ref outBuf, 4, out bytes, IntPtr.Zero)) {
          accessUsed = mask;
          if ((outBuf & VOLUME_IS_DIRTY) != 0) { return 1; }
          return 0;
        }
        lastIoctlError = Marshal.GetLastWin32Error();
      }
    }
    if (lastIoctlError != 0) { win32Error = lastIoctlError; return -2; }
    win32Error = lastOpenError; return -1;
  }
}
'@
    }
    $script:FFVolumeApiReady = $true
  } catch {}
  return $script:FFVolumeApiReady
}

function Get-FFVolumeDirtyBit {
  <#
    Reads the NTFS dirty bit for a volume. Returns
      @{ volume; dirty = $true|$false|$null; source; detail; needsAdmin; fsutilExitCode; fsutilOutput; win32Error }
    dirty = $null means COULD NOT DETERMINE — never "clean".

    Ladder, most structural first:
      1. FSCTL_IS_VOLUME_DIRTY over a volume handle (DeviceIoControl). Completely locale- and
         console-independent, and readable UNELEVATED via FILE_TRAVERSE (see the C# comment).
      2. fsutil dirty query, matched against the ENGLISH strings 'is NOT Dirty' / 'is Dirty'.
         This rung is DOCUMENTED ENGLISH-ONLY and only ever runs when rung 1 was unavailable
         (application control blocking Add-Type, or an unexpected IOCTL rejection).
      3. Honest unknown. fsutil's EXIT CODE is captured as evidence but is deliberately NOT used
         as a verdict: unelevated it exits 1 with 'Error 5: Access is denied' (verified on this
         box), which is indistinguishable by exit code alone from a legitimate "not dirty", and
         guessing there is exactly the kind of confident-but-unmeasured answer doctrine rule 2 bans.
  #>
  param(
    [string]$Volume = $env:SystemDrive,
    [bool]$IsAdmin = $false
  )
  $vol = "$Volume".Trim().TrimEnd('\')
  if ($vol -match '^[A-Za-z]$') { $vol = $vol + ':' }
  $res = [ordered]@{
    volume = $vol; dirty = $null; source = 'none'; detail = $null; needsAdmin = $false
    fsutilExitCode = $null; fsutilOutput = $null; win32Error = $null; accessMask = $null
  }

  if (Initialize-FFVolumeApi) {
    try {
      $access = [uint32]0
      $err = [int]0
      $rc = [FFVolumeApi]::QueryDirty("\\.\$vol", [ref]$access, [ref]$err)
      $res.win32Error = $err
      $res.accessMask = ('0x{0:X8}' -f $access)
      if ($rc -eq 1) {
        $res.dirty = $true;  $res.source = 'fsctl-is-volume-dirty'
        $res.detail = "FSCTL_IS_VOLUME_DIRTY reports the dirty bit is SET on $vol."
        return $res
      } elseif ($rc -eq 0) {
        $res.dirty = $false; $res.source = 'fsctl-is-volume-dirty'
        $res.detail = "FSCTL_IS_VOLUME_DIRTY reports the dirty bit is clear on $vol."
        return $res
      } else {
        $res.detail = "FSCTL_IS_VOLUME_DIRTY was unavailable (rc=$rc, win32=$err)."
      }
    } catch {
      $res.detail = "FSCTL_IS_VOLUME_DIRTY could not be called: $($_.Exception.Message)"
    }
  } else {
    $res.detail = "The volume API could not be compiled (language mode: $script:FFLanguageMode)."
  }

  # Rung 2 / 3: fsutil.
  $fs = Invoke-FFNative -FilePath (Join-Path $env:SystemRoot 'System32\fsutil.exe') -Arguments @('dirty', 'query', $vol)
  $res.fsutilExitCode = $fs.exitCode
  $txt = "$($fs.text)".Trim()
  if ($txt.Length -gt 400) { $txt = $txt.Substring(0, 400) }
  $res.fsutilOutput = $txt
  # DOCUMENTED ENGLISH-ONLY parse. Order matters: 'is Dirty' is a substring of nothing else,
  # but 'is NOT Dirty' contains 'Dirty', so the negative must be tested first.
  if ($txt -match 'is NOT Dirty') {
    $res.dirty = $false; $res.source = 'fsutil-english-text'
    $res.detail = "fsutil reported the dirty bit clear on $vol (English output parse)."
    return $res
  }
  if ($txt -match 'is Dirty') {
    $res.dirty = $true; $res.source = 'fsutil-english-text'
    $res.detail = "fsutil reported the dirty bit SET on $vol (English output parse)."
    return $res
  }
  if (-not $IsAdmin) {
    $res.needsAdmin = $true
    $res.source = 'indeterminate-needs-admin'
    $res.detail = "The dirty bit could not be read: the volume IOCTL was unavailable and fsutil needs administrator rights (exit code $($fs.exitCode))."
  } else {
    $res.source = 'indeterminate'
    $res.detail = "The dirty bit could not be read: the volume IOCTL was unavailable and fsutil's output did not match the documented English form (exit code $($fs.exitCode))."
  }
  return $res
}

# ---------------- power capabilities (locale-independent Fast Startup) ----------------

$script:FFPowerApiReady = $null

function Initialize-FFPowerApi {
  if ($null -ne $script:FFPowerApiReady) { return $script:FFPowerApiReady }
  $script:FFPowerApiReady = $false
  if (-not (Test-FFFullLanguage)) { return $false }
  try {
    if (-not ('FFPowerApi' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
// SYSTEM_POWER_CAPABILITIES, 76 bytes on x64 (verified: CallNtPowerInformation returns
// STATUS_SUCCESS only when the buffer is exactly this size; a short struct returns
// STATUS_BUFFER_TOO_SMALL 0xC0000023).
[StructLayout(LayoutKind.Sequential)]
public struct FF_POWER_CAPS {
  [MarshalAs(UnmanagedType.I1)] public bool PowerButtonPresent;
  [MarshalAs(UnmanagedType.I1)] public bool SleepButtonPresent;
  [MarshalAs(UnmanagedType.I1)] public bool LidPresent;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS1;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS2;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS3;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS4;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS5;
  [MarshalAs(UnmanagedType.I1)] public bool HiberFilePresent;
  [MarshalAs(UnmanagedType.I1)] public bool FullWake;
  [MarshalAs(UnmanagedType.I1)] public bool VideoDimPresent;
  [MarshalAs(UnmanagedType.I1)] public bool ApmPresent;
  [MarshalAs(UnmanagedType.I1)] public bool UpsPresent;
  [MarshalAs(UnmanagedType.I1)] public bool ThermalControl;
  [MarshalAs(UnmanagedType.I1)] public bool ProcessorThrottle;
  public byte ProcessorMinThrottle;
  public byte ProcessorMaxThrottle;
  [MarshalAs(UnmanagedType.I1)] public bool FastSystemS4;
  [MarshalAs(UnmanagedType.I1)] public bool Hiberboot;
  [MarshalAs(UnmanagedType.I1)] public bool WakeAlarmPresent;
  [MarshalAs(UnmanagedType.I1)] public bool AoAc;
  [MarshalAs(UnmanagedType.I1)] public bool DiskSpinDown;
  public byte HiberFileType;
  [MarshalAs(UnmanagedType.I1)] public bool AoAcConnectivitySupported;
  [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] spare3;
  [MarshalAs(UnmanagedType.I1)] public bool SystemBatteriesPresent;
  [MarshalAs(UnmanagedType.I1)] public bool BatteriesAreShortTerm;
  [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public uint[] BatteryScale;
  public uint AcOnLineWake;
  public uint SoftLidWake;
  public uint RtcWake;
  public uint MinDeviceWakeState;
  public uint DefaultLowLatencyWake;
}
public static class FFPowerApi {
  [DllImport("powrprof.dll", SetLastError = true)]
  private static extern uint CallNtPowerInformation(int InformationLevel, IntPtr lpInputBuffer,
      uint nInputBufferSize, ref FF_POWER_CAPS lpOutputBuffer, uint nOutputBufferSize);
  // SystemPowerCapabilities = 4
  public static uint GetCapabilities(ref FF_POWER_CAPS caps) {
    uint size = (uint)Marshal.SizeOf(typeof(FF_POWER_CAPS));
    return CallNtPowerInformation(4, IntPtr.Zero, 0, ref caps, size);
  }
}
'@
    }
    $script:FFPowerApiReady = $true
  } catch {}
  return $script:FFPowerApiReady
}

function Get-FFPowerCapabilities {
  <#
    SYSTEM_POWER_CAPABILITIES via CallNtPowerInformation — the structured, locale-free answer to
    "is hibernation (and therefore Fast Startup) available on this machine".
    Returns @{ available = $true|$false; systemS4; hiberFilePresent; hiberboot; ntStatus; error }.
    available = $false means the API could not be called, NOT that hibernation is off.
  #>
  $out = [ordered]@{ available = $false; systemS4 = $null; hiberFilePresent = $null; hiberboot = $null; ntStatus = $null; error = $null }
  if (-not (Initialize-FFPowerApi)) {
    $out.error = "The power API could not be compiled (language mode: $script:FFLanguageMode)."
    return $out
  }
  try {
    $caps = New-Object FF_POWER_CAPS
    $rc = [FFPowerApi]::GetCapabilities([ref]$caps)
    $out.ntStatus = ('0x{0:X8}' -f $rc)
    if ($rc -eq 0) {
      $out.available = $true
      $out.systemS4 = [bool]$caps.SystemS4
      $out.hiberFilePresent = [bool]$caps.HiberFilePresent
      $out.hiberboot = [bool]$caps.Hiberboot
    } else {
      $out.error = "CallNtPowerInformation(SystemPowerCapabilities) returned NTSTATUS $($out.ntStatus)."
    }
  } catch {
    $out.error = "$($_.Exception.Message)"
  }
  return $out
}

# ---------------- OS / edition / capability / policy (the SKU + build gate) ----------------

$script:FFOsInfoCache = $null

function Get-FFOsInfo {
  <#
    Build identity and the supported-platform gate. Cached per process.

    NEVER read CurrentVersion\ProductName for the generation: on this Windows 11 25H2 box it
    literally reads "Windows 10 Pro". CurrentBuildNumber is the authority (>= 22000 is Win11),
    with Win32_OperatingSystem.Caption as the human-facing product name.

    supported = a Client installation on build >= 22000. Everything else (Windows 10, Server,
    Server Core) is UNVALIDATED: read-only actions may still run, mutating actions must refuse
    with errorCode 'unsupported-os' rather than pretend the platform was tested.
  #>
  if ($null -ne $script:FFOsInfoCache) { return $script:FFOsInfoCache }
  $cv = $null; try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch {}
  $ci = $null; try { $ci = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
  # THE TRAP (image.ps1's Get-FFOsIdentity documents the same one): [int]$null is 0, NOT an
  # error. `$build = [int]$cv.CurrentBuildNumber` on a machine whose CurrentBuildNumber is
  # absent or non-numeric (GPO-hardened images, Server Core, a stripped hive) therefore
  # produced the NUMBER 0 — which made the ($null -eq $build) CIM fallback on the next line
  # dead code, graded the box generation 'older', supported=false, and fabricated the sentence
  # "Windows build 0 is older than 22000 (Windows 11)". A supported Windows 11 machine was
  # slandered and gated out of every mutating repair with a reason that was never measured.
  # Digits or nothing: parse the STRING, and only accept a positive whole number.
  $build = $null; $buildSource = 'unreadable'
  if ($null -ne $cv) {
    $rawBuild = $null
    try { $rawBuild = "$($cv.CurrentBuildNumber)".Trim() } catch {}
    if ($rawBuild -match '^\d+$') { $b = [int]$rawBuild; if ($b -gt 0) { $build = $b; $buildSource = 'registry-currentbuildnumber' } }
  }
  if ($null -eq $build -and $null -ne $ci) {
    $rawCimBuild = $null
    try { $rawCimBuild = "$($ci.BuildNumber)".Trim() } catch {}
    if ($rawCimBuild -match '^\d+$') { $b = [int]$rawCimBuild; if ($b -gt 0) { $build = $b; $buildSource = 'cim-win32-operatingsystem-buildnumber' } }
  }
  $ubr = $null
  if ($null -ne $cv) {
    $rawUbr = $null
    try { $rawUbr = "$($cv.UBR)".Trim() } catch {}
    if ($rawUbr -match '^\d+$') { $ubr = [int]$rawUbr }
  }
  $displayVersion = ''; if ($null -ne $cv) { $displayVersion = "$($cv.DisplayVersion)" }
  $caption = ''; if ($null -ne $ci) { $caption = "$($ci.Caption)" }
  $installationType = ''; if ($null -ne $cv) { $installationType = "$($cv.InstallationType)" }
  # Same [int]$null trap as the build above: an unreadable ProductType must stay $null, never
  # become the number 0 (which is not even a valid Win32_OperatingSystem ProductType).
  $productType = $null
  if ($null -ne $ci) {
    $rawPt = $null
    try { $rawPt = "$($ci.ProductType)".Trim() } catch {}
    if ($rawPt -match '^\d+$') { $productType = [int]$rawPt }
  }
  $generation = 'unknown'
  if ($null -ne $build) {
    if ($build -ge 22000) { $generation = 'win11' }
    elseif ($build -ge 10240) { $generation = 'win10' }
    else { $generation = 'older' }
  }
  $buildString = $null
  if ($null -ne $build) {
    if ($null -ne $ubr) { $buildString = "$build.$ubr" } else { $buildString = "$build" }
  }
  $supported = ($null -ne $build -and $build -ge 22000 -and $installationType -eq 'Client')
  $reason = $null
  # 'undetermined' distinguishes "measured, and it is not a supported platform" from "could not
  # measure the platform at all". Both refuse a mutating action, but only one of them may be
  # WORDED as a fact about this machine (docs/GAUNTLET.md rule 2).
  $undetermined = $false
  if (-not $supported) {
    if ($null -eq $build) {
      $undetermined = $true
      $reason = 'The Windows build number could not be read from either CurrentVersion\CurrentBuildNumber or Win32_OperatingSystem, so this platform could not be identified and cannot be confirmed as supported. This is NOT a statement that the platform is unsupported.'
    } elseif ([string]::IsNullOrWhiteSpace($installationType)) {
      $undetermined = $true
      $reason = "The installation type (Client / Server / Server Core) could not be read from CurrentVersion\InstallationType, so build $build could not be confirmed as a Windows 11 client. This is NOT a statement that the platform is unsupported."
    } elseif ($installationType -ne 'Client') {
      $reason = "This is a '$installationType' installation (build $build). FrameForge is validated on Windows 11 client builds only."
    } else {
      $reason = "Windows build $build is older than 22000 (Windows 11). FrameForge is validated on Windows 11 client builds only."
    }
  }
  $script:FFOsInfoCache = [ordered]@{
    build            = $build            # 22000=21H2 22621=22H2 22631=23H2 26100=24H2 26200=25H2
    buildSource      = $buildSource      # registry-currentbuildnumber | cim-win32-operatingsystem-buildnumber | unreadable
    ubr              = $ubr
    buildString      = $buildString
    displayVersion   = $displayVersion
    caption          = $caption          # authoritative product name
    installationType = $installationType # Client | Server | Server Core
    productType      = $productType      # 1 = workstation
    generation       = $generation
    supported        = $supported
    # $true = supported is $false because the platform could NOT BE MEASURED, not because it was
    # measured and found unsupported. Consumers that word a refusal must say "could not
    # determine", not "unsupported". Additive field; `supported` and `unsupportedReason` keep
    # their existing meaning and shape.
    platformUndetermined = $undetermined
    unsupportedReason = $reason
  }
  return $script:FFOsInfoCache
}

$script:FFEditionCache = $null

function Get-FFEdition {
  <#
    Windows edition identity, so a probe can tell a by-design absence from a fault.
    Cached per process. Every field is $null when it could not be read — never a guessed default.

      editionId        HKLM\...\CurrentVersion\EditionID (works unelevated; e.g. Professional, EnterpriseS)
      sku              Win32_OperatingSystem.OperatingSystemSKU (48 = Professional)
      caption          Win32_OperatingSystem.Caption
      isN              EditionID ends in N or KN (media-feature-pack editions)
      isLtsc           EnterpriseS / EnterpriseSN / IoTEnterprise* — these ship WITHOUT the Microsoft Store
      isServer         InstallationType is not 'Client'
      isDomainJoined   Win32_ComputerSystem.PartOfDomain
      isMdmEnrolled    an MDM enrollment with a DiscoveryServiceFullURL exists. NOTE: the bare key
                       HKLM\SOFTWARE\Microsoft\PolicyManager\current\device exists on stock consumer
                       Windows 11 (verified on this box), so its presence alone is NOT enrollment;
                       it is reported separately as policyManagerPresent.
  #>
  if ($null -ne $script:FFEditionCache) { return $script:FFEditionCache }
  $os = Get-FFOsInfo
  $editionId = $null; $source = @()
  try {
    $editionId = "$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID)"
    if ($editionId) { $source += 'registry-editionid' }
  } catch {}
  $sku = $null
  try { $sku = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).OperatingSystemSKU; $source += 'cim-sku' } catch {}
  $isN = $null; $isLtsc = $null
  if ($editionId) {
    $isN = [bool]($editionId -match '(?i)(N|KN)$')
    $isLtsc = [bool]($editionId -match '(?i)^(EnterpriseS|EnterpriseSN|IoTEnterprise|IoTEnterpriseS|IoTEnterpriseSK|ServerRdsh)$')
  }
  $isDomainJoined = $null
  try { $isDomainJoined = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain; $source += 'cim-computersystem' } catch {}
  $policyManagerPresent = $null
  try { $policyManagerPresent = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device') } catch {}
  $isMdmEnrolled = $null
  try {
    $isMdmEnrolled = $false
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop)) {
      $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
      if ($null -ne $p -and "$($p.DiscoveryServiceFullURL)" -ne '' -and [int]$p.EnrollmentState -eq 1) { $isMdmEnrolled = $true; break }
    }
    $source += 'registry-enrollments'
  } catch { $isMdmEnrolled = $null }
  $isServer = $null
  if ($os.installationType) { $isServer = ($os.installationType -ne 'Client') }
  $script:FFEditionCache = [ordered]@{
    editionId            = $editionId
    sku                  = $sku
    caption              = $os.caption
    installationType     = $os.installationType
    isN                  = $isN
    isLtsc               = $isLtsc
    isServer             = $isServer
    isDomainJoined       = $isDomainJoined
    isMdmEnrolled        = $isMdmEnrolled
    policyManagerPresent = $policyManagerPresent
    source               = ($source -join ',')
  }
  return $script:FFEditionCache
}

function Test-FFCapability {
  <#
    Does this Windows have a given capability at all? Returns
      @{ name; available = $true|$false|$null; how; detail }
    available = $null means COULD NOT DETERMINE. This function never returns $false from a probe
    it did not actually run — that distinction is the whole point.
  #>
  param(
    [Parameter(Mandatory)]
    [ValidateSet('BitLocker','Store','SystemRestore','OptionalFeatures')]
    [string]$Name
  )
  $out = [ordered]@{ name = $Name; available = $null; how = 'none'; detail = $null }
  switch ($Name) {
    'BitLocker' {
      try {
        if (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction Stop) {
          $out.available = $true; $out.how = 'cmdlet'
          $out.detail = 'The BitLocker PowerShell module is present, so BitLocker management is available on this edition.'
          return $out
        }
      } catch {}
      try {
        $null = Get-CimInstance -Namespace 'Root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop
        $out.available = $true; $out.how = 'wmi'
        $out.detail = 'The Win32_EncryptableVolume provider answered, so BitLocker is present on this edition.'
        return $out
      } catch {
        if (Test-FFAccessDenied -ErrorRecord $_) {
          $out.detail = 'The BitLocker WMI provider exists but could not be queried without administrator rights.'
          return $out   # available stays $null: denied is not absent
        }
      }
      $ed = Get-FFEdition
      if ($ed.editionId -match '(?i)^(Core|CoreN|CoreSingleLanguage|CoreCountrySpecific|Home.*)$') {
        $out.available = $false; $out.how = 'registry'
        $out.detail = "Windows edition '$($ed.editionId)' does not include BitLocker management."
        return $out
      }
      $out.detail = 'Neither the BitLocker module nor its WMI provider could be reached, and the edition is not conclusive.'
      return $out
    }
    'Store' {
      $ed = Get-FFEdition
      if ($ed.isLtsc -eq $true) {
        $out.available = $false; $out.how = 'registry'
        $out.detail = "Windows edition '$($ed.editionId)' (LTSC/IoT) ships without the Microsoft Store by design."
        return $out
      }
      if ($ed.isServer -eq $true) {
        $out.available = $false; $out.how = 'registry'
        $out.detail = "This is a '$($ed.installationType)' installation, which ships without the Microsoft Store by design."
        return $out
      }
      try {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq 'Microsoft.WindowsStore' })
        $out.available = ($prov.Count -gt 0); $out.how = 'cmdlet'
        if ($out.available) { $out.detail = 'Microsoft.WindowsStore is provisioned in this Windows image.' }
        else { $out.detail = 'Microsoft.WindowsStore is not provisioned in this Windows image.' }
        return $out
      } catch {}
      try {
        if (@(Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop).Count -gt 0) {
          $out.available = $true; $out.how = 'cmdlet'
          $out.detail = 'The Microsoft Store package is registered for the current user.'
          return $out
        }
      } catch {}
      $out.detail = 'The provisioned-package list needs administrator rights and the per-user query did not answer, so Store availability in this image is undetermined.'
      return $out
    }
    'SystemRestore' {
      $disabled = $null
      try { $disabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name DisableSR -ErrorAction Stop).DisableSR } catch {}
      if ($null -ne $disabled -and [int]$disabled -eq 1) {
        $out.available = $false; $out.how = 'registry'
        $out.detail = 'System Restore is disabled by policy (Policies\Microsoft\Windows NT\SystemRestore\DisableSR = 1).'
        return $out
      }
      try {
        if (Get-Command -Name 'Checkpoint-Computer' -ErrorAction Stop) {
          $out.available = $true; $out.how = 'cmdlet'
          $out.detail = 'Checkpoint-Computer is available; System Restore points can be requested (per-volume protection may still be off).'
          return $out
        }
      } catch {}
      $out.detail = 'Checkpoint-Computer was not found and no policy value was readable, so System Restore availability is undetermined.'
      return $out
    }
    'OptionalFeatures' {
      try {
        if (Get-Command -Name 'Get-WindowsOptionalFeature' -ErrorAction Stop) {
          $out.available = $true; $out.how = 'cmdlet'
          $out.detail = 'The DISM PowerShell module is present, so optional features can be enumerated (elevation still required to query -Online).'
          return $out
        }
      } catch {}
      $out.detail = 'Get-WindowsOptionalFeature was not found, so optional-feature management is undetermined.'
      return $out
    }
  }
  return $out
}

function Get-FFPolicySnapshot {
  <#
    Read-only enumeration of the HKLM\SOFTWARE\Policies subkeys FrameForge cares about, returned
    as evidence so a probe can say "this machine is managed, here is by what" instead of grading
    a deliberate policy as a fault.
    Each entry is @{ path; present = $true|$false|$null; values = @{...}; error }.
    present = $null means the key could not be read (denied), which is not the same as absent.
  #>
  $paths = [ordered]@{
    windowsUpdate       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    windowsUpdateAu     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    deliveryOptimization= 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    systemRestore       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
    windowsStore        = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    updateUxSettings    = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
  }
  $out = [ordered]@{}
  foreach ($k in $paths.Keys) {
    $p = $paths[$k]
    $entry = [ordered]@{ path = ($p -replace '^HKLM:', 'HKLM'); present = $null; values = @{}; error = $null }
    try {
      if (Test-Path -Path $p -ErrorAction Stop) {
        $entry.present = $true
        $props = Get-ItemProperty -Path $p -ErrorAction Stop
        $vals = [ordered]@{}
        foreach ($n in @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
          $vals[$n.Name] = $n.Value
        }
        $entry.values = $vals
      } else {
        $entry.present = $false
      }
    } catch {
      $entry.error = "$($_.Exception.Message)"
      if (Test-FFAccessDenied -ErrorRecord $_) { $entry.present = $null }
    }
    $out[$k] = $entry
  }
  return $out
}
