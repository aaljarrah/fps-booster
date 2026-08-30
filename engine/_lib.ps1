<#
  FrameForge :: _lib.ps1
  Shared helper library for engine scripts. Dot-source it:
    . (Join-Path $PSScriptRoot '_lib.ps1')

  Everything in here is read-only utility code — nothing mutates system state.
  PowerShell 5.1 compatible (no ternary, no ??, no null-conditional).
#>

# Native command output (sfc, powercfg, fsutil) is decoded through Console.OutputEncoding.
# UTF-8 (BOM-free) keeps stdout JSON clean for the Electron host. Guarded: throws when the
# process has no console (e.g. some hosted scenarios).
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-FFJson {
  <#
    Emits exactly ONE JSON document on stdout, BOM-free.
    - Uses -InputObject (not the pipeline) so a single-element array is not unrolled
      into a bare object — the classic PS 5.1 ConvertTo-Json pitfall.
    - [Console]::Out avoids any host-added BOM and Write-Output enumeration.
  #>
  param(
    [Parameter(Mandatory)]$InputObject,
    [int]$Depth = 12,
    [switch]$Pretty
  )
  if ($Pretty) { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth }
  else         { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress }
  [Console]::Out.WriteLine($json)
}

# Last error message from Get-FFEvents when the failure was NOT simply "no events matched"
# (e.g. access denied, missing log channel). Callers that care can inspect it right after a call.
$script:FFLastEventError = $null

function Get-FFEvents {
  <#
    Wrapper over Get-WinEvent -FilterHashtable that never throws and never writes to the
    error stream. Returns an array (possibly empty). "No events were found" is a normal
    empty result; real failures (missing log, access denied) also return @() but record
    the message in $script:FFLastEventError.
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Filter,
    [int]$MaxEvents = 0
  )
  $script:FFLastEventError = $null
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
    $msg = "$($_.Exception.Message)"
    if ($msg -notmatch 'No events were found|NoMatchingEventsFound') { $script:FFLastEventError = $msg }
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
