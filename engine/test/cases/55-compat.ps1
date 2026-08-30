<#
  CONTRACT/COMPAT :: engine\compat.ps1 -Action check, driven against FAKED machines

  WHY THIS FILE EXISTS
  --------------------
  compat.ps1 is 2,400+ lines whose entire stated purpose is to be right on a machine whose
  language, SKU, build, elevation and lockdown state we do not know. Until now the suite
  executed only -Action list and -Action selftest: NOTHING ran the probes, and no capability
  verdict was ever asserted. That was proven vacuous - patching a scratchpad copy so
  Resolve-Verdict returned 'supported' unconditionally and Test-CompatCommand always reported
  the command absent still passed the whole suite green, while compat.ps1 cheerfully printed
  "40 of 40 FrameForge capabilities can run here as designed."

  HOW THE MACHINE IS FAKED
  ------------------------
  New-FFSandbox copies engine\ + data\ into this run's private work dir, and
  Add-FFSandboxEnginePatch splices a stub block into the SANDBOX's compat.ps1 immediately
  before its dispatch. The stubs replace the thirteen probe functions - and nothing else - so
  every line that turns probe readings into facts, facts into constraints, and constraints
  into verdicts is the REAL code, executed as a real child process emitting one real JSON
  document. The machine under the probes is the only thing that is fiction, and it is
  described by data\ff-test-compat-spec.json in the sandbox.

  The real engine\compat.ps1 is never touched.

  THE DOCTRINE INVARIANTS
  -----------------------
  Test-FFCompatDoctrine below re-derives each row's verdict from that row's OWN recorded
  reasons, using an independent copy of the rank, and refuses any row that claims to be
  better than its reasons allow. That is what makes the sabotage test at the bottom possible:
  break Resolve-Verdict, and these assertions must notice.
#>

# The verdict rank, written out again ON PURPOSE. If the test imported compat.ps1's own
# $script:VerdictRank, a sabotaged rank would agree with itself and prove nothing.
$FFVerdictRank = @{ 'supported' = 0; 'needs-admin' = 1; 'unknown' = 2; 'degraded' = 3; 'unavailable' = 4 }

function Get-FFCompatStubPatch {
  <#
    The stub block spliced into the sandbox's compat.ps1. It replaces every probe function
    with one that reads data\ff-test-compat-spec.json, so a scenario is data, not code.
    Everything downstream of the probes - Set-Fact, the rule tables, the constraint builders,
    Resolve-Verdict, New-CapabilityRow, the blockers, the summary - is the real engine.
  #>
  @'
$ffSpecPath = Join-Path $Root 'data\ff-test-compat-spec.json'
if (-not (Test-Path -LiteralPath $ffSpecPath)) { throw "TEST PATCH: no spec at $ffSpecPath" }
$ffSpec = Get-Content -Raw -Encoding UTF8 -LiteralPath $ffSpecPath | ConvertFrom-Json

function FFSpec {
  param([string]$Name, $Default = $null)
  $p = $ffSpec.PSObject.Properties[$Name]
  if ($null -eq $p) { return $Default }
  return $p.Value
}
function FFTri { param($v) if ($null -eq $v) { return $null } return [bool]$v }
function FFList { param($v) if ($null -eq $v) { return @() } return @($v) }

$script:LanguageMode = "$(FFSpec 'languageMode' 'FullLanguage')"
$script:FullLanguage = ($script:LanguageMode -eq 'FullLanguage')

function Get-CompatOsIdentity {
  $raw = FFSpec 'build' 26100
  $b = $null
  if ($null -ne $raw -and "$raw" -match '^\d+$') { $b = [int]$raw }
  $bs = 'could not be read'
  if ($null -ne $b) { $bs = "$b" }
  [ordered]@{
    build = $b; buildString = $bs
    displayVersion = "$(FFSpec 'displayVersion' '24H2')"
    editionId = "$(FFSpec 'edition' 'Professional')"
    generation = (FFSpec 'generation' 'win11')
    installationType = "$(FFSpec 'installationType' 'Client')"
    isServer = (FFTri (FFSpec 'isServer' $false))
    supported = (FFTri (FFSpec 'osSupported' $true))
    unsupportedReason = "$(FFSpec 'unsupportedReason' 'STUB: this platform is not validated.')"
    localAgreesWithLibrary = $null
    detail = 'STUB os identity.'
  }
}
function Get-CompatLanguage {
  $en = FFTri (FFSpec 'english' $true)
  $d = 'STUB: the system UI language is English.'
  if ($en -eq $false) { $d = 'STUB: the system UI language is not English, so every documented English-only last-resort rung is lost here.' }
  elseif ($null -eq $en) { $d = 'STUB: the system UI language could not be read, so FrameForge cannot say whether the English-only rungs apply.' }
  [ordered]@{ english = $en; englishDetail = $d; installLanguageHex = '0409'; uiCulture = 'en-US' }
}
function Get-CompatSystemDrive { [ordered]@{ drive = 'C:'; freeBytes = 200GB; detail = 'STUB drive.' } }
function Get-CompatArchitecture { [ordered]@{ os = 'x64'; process = 'x64'; detail = 'STUB architecture.' } }
function Get-CompatFormFactor {
  [ordered]@{ isPortable = (FFTri (FFSpec 'portable' $false)); portableDetail = 'STUB form factor.'; chassis = 3 }
}
function Get-CompatVirtualization {
  [ordered]@{ isVirtual = (FFTri (FFSpec 'virtual' $false)); detail = 'STUB virtualization reading.'; vendor = 'STUB' }
}
function Get-CompatDisplay {
  [ordered]@{ remoteSession = (FFTri (FFSpec 'remoteSession' $false)); detail = 'STUB display.' }
}
function Get-CompatPowerShell {
  [ordered]@{ supported = (FFTri (FFSpec 'psSupported' $true)); version = '5.1.99999.1'; detail = 'STUB PowerShell version reading.' }
}
function Get-CompatExecutionPolicy {
  $b = FFTri (FFSpec 'bypassBlocked' $false)
  [ordered]@{ bypassBlocked = $b; blockingValue = "$(FFSpec 'blockingValue' 'AllSigned')"; blockingScope = "$(FFSpec 'blockingScope' 'MachinePolicy')"
              detail = 'STUB execution policy reading.' }
}
function Get-CompatLockdown {
  [ordered]@{ languageMode = $script:LanguageMode; wdac = $null; appLocker = $null; detail = 'STUB lockdown reading.' }
}
function Get-CompatElevation {
  [ordered]@{ isAdmin = (FFTri (FFSpec 'admin' $true)); canElevate = (FFTri (FFSpec 'canElevate' $true))
              detail = 'STUB elevation reading.' }
}
function Get-CompatManagement {
  [ordered]@{
    domainJoined = (FFTri (FFSpec 'domainJoined' $false)); domainName = 'WORKGROUP'
    azureAdJoined = (FFTri (FFSpec 'azureAdJoined' $false)); mdmEnrolled = (FFTri (FFSpec 'mdmEnrolled' $false))
    wsusManaged = (FFTri (FFSpec 'wsusManaged' $false)); wsusServer = ''; useWUServer = 0
    w32timeDomainHierarchy = (FFTri (FFSpec 'w32timeDomainHierarchy' $false)); w32timeType = 'NTP'
    optionalFeaturePayload = [ordered]@{ useWindowsUpdateBlocked = (FFTri (FFSpec 'featurePayloadBlocked' $false)) }
    detail = 'STUB management reading.'
  }
}
function Get-CompatCapabilities {
  $missTools = FFList (FFSpec 'missingTools' @());   $unkTools = FFList (FFSpec 'unknownTools' @())
  $missCmds  = FFList (FFSpec 'missingCommands' @()); $unkCmds  = FFList (FFSpec 'unknownCommands' @())
  $missSvcs  = FFList (FFSpec 'missingServices' @()); $offSvcs  = FFList (FFSpec 'disabledServices' @())
  $out = [ordered]@{
    nativeTools = [ordered]@{}; commands = [ordered]@{}; services = [ordered]@{}
    bitLocker = $null; store = $null; optionalFeatures = $null
    systemRestore = $null; winget = $null; storage = $null
    systemDirectory = 'C:\Windows\System32'; systemDirectoryNote = 'STUB system directory.'
  }
  foreach ($t in $script:NativeTools) {
    $p = $true
    if ($missTools -contains $t) { $p = $false }
    if ($unkTools -contains $t) { $p = $null }
    $e = $null; if ($null -eq $p) { $e = 'STUB: the file could not be tested for.' }
    $out.nativeTools[$t] = [ordered]@{ name = $t; present = $p; path = "C:\Windows\System32\$t"; error = $e }
  }
  foreach ($c in $script:NeededCommands) {
    $p = $true
    if ($missCmds -contains $c) { $p = $false }
    if ($unkCmds -contains $c) { $p = $null }
    $e = $null; if ($null -eq $p) { $e = 'STUB: Get-Command could not answer.' }
    $out.commands[$c] = [ordered]@{ name = $c; present = $p; error = $e }
  }
  foreach ($s in $script:NeededServices) {
    $p = $true; $start = 2
    if ($offSvcs -contains $s) { $start = 4 }
    if ($missSvcs -contains $s) { $p = $false; $start = $null }
    $out.services[$s] = [ordered]@{ name = $s; present = $p; start = $start; startName = 'STUB'; error = $null }
  }
  $out.bitLocker        = [ordered]@{ name = 'BitLocker'; available = (FFTri (FFSpec 'bitLocker' $true)); how = 'stub'; detail = 'STUB BitLocker capability.' }
  $out.store            = [ordered]@{ name = 'Store'; available = (FFTri (FFSpec 'store' $true)); how = 'stub'; detail = 'STUB Store capability.' }
  $out.optionalFeatures = [ordered]@{ name = 'OptionalFeatures'; available = (FFTri (FFSpec 'optionalFeatures' $true)); how = 'stub'; detail = 'STUB optional-features capability.' }
  $out.systemRestore    = [ordered]@{ capable = (FFTri (FFSpec 'systemRestore' $true)); detail = 'STUB System Restore capability.'
                                      policyDisabled = $false; checkpointCmdlet = $true; enableCmdlet = $true }
  $out.winget           = [ordered]@{ present = (FFTri (FFSpec 'winget' $true)); detail = 'STUB winget capability.' }
  $out.storage          = [ordered]@{ repairVolume = (FFTri (FFSpec 'storageModule' $true)); getVolume = $true
                                      getPhysicalDisk = $true; reliabilityCounters = $true; detail = 'STUB storage module capability.' }
  $out
}
function Get-CimClass {
  param($ClassName, $Namespace, $ErrorAction)
  $slp = FFTri (FFSpec 'licensingClass' $true)
  if ($slp -eq $true) { return [pscustomobject]@{ CimClassName = "$ClassName" } }
  throw (New-Object System.Exception('STUB: the CIM class is not available here.'))
}
'@
}

function Get-FFCompatSpecDefault {
  <# The healthy control: an elevated, English, FullLanguage Windows 11 Pro with everything
     present. Every scenario below is this, with the one thing under test changed. #>
  [ordered]@{
    build = '26100'; displayVersion = '24H2'; edition = 'Professional'; generation = 'win11'
    installationType = 'Client'; isServer = $false; osSupported = $true
    unsupportedReason = 'STUB: this platform is not validated.'
    english = $true; languageMode = 'FullLanguage'; psSupported = $true
    admin = $true; canElevate = $true; bypassBlocked = $false
    virtual = $false; portable = $false; remoteSession = $false
    bitLocker = $true; store = $true; optionalFeatures = $true
    systemRestore = $true; winget = $true; storageModule = $true; licensingClass = $true
    missingTools = @(); unknownTools = @(); missingCommands = @(); unknownCommands = @()
    missingServices = @(); disabledServices = @()
    domainJoined = $false; azureAdJoined = $false; mdmEnrolled = $false; wsusManaged = $false
    w32timeDomainHierarchy = $false; featurePayloadBlocked = $false
  }
}

function Invoke-FFCompatCheck {
  <#
    Builds a sandbox, writes the scenario spec into it, splices the probe stubs into the
    sandboxed compat.ps1, runs -Action check for real, and returns
      @{ res; parsed; doc; sandbox }
  #>
  param([hashtable]$Spec = @{}, [string]$ExtraPatch = '', [string]$Label = 'compat')
  $full = Get-FFCompatSpecDefault
  foreach ($k in @($Spec.Keys)) { $full[$k] = $Spec[$k] }

  $sbx = New-FFSandbox -Label $Label
  $json = ConvertTo-Json -InputObject $full -Depth 6
  [System.IO.File]::WriteAllText((Join-Path $sbx 'data\ff-test-compat-spec.json'), $json, (New-Object System.Text.UTF8Encoding($false)))

  $patch = Get-FFCompatStubPatch
  if ("$ExtraPatch" -match '\S') { $patch = $patch + "`r`n" + $ExtraPatch }
  $null = Add-FFSandboxEnginePatch -Sandbox $sbx -Engine 'compat' -Patch $patch

  $res = Invoke-FFEngineProcess -Script (Join-Path $sbx 'engine\compat.ps1') -EngineArgs @('-Action', 'check') -TimeoutMs 120000
  $parsed = ConvertFrom-FFEngineStdout -Stdout $res.stdout
  [ordered]@{ res = $res; parsed = $parsed; doc = $parsed.doc; sandbox = $sbx }
}

function Get-FFCompatRow {
  param($Doc, [string]$Id)
  @($Doc.capabilities | Where-Object { "$($_.id)" -eq $Id }) | Select-Object -First 1
}

function Get-FFCompatFact {
  <# The TRI-STATE value of a fact: $true / $false / $null. Every fact in the document is
     {id, value, how, detail}, and it is the .value that carries the reading. #>
  param($Doc, [string]$Id)
  $p = $null
  try { $p = $Doc.facts.PSObject.Properties[$Id] } catch {}
  if ($null -eq $p) { return $null }
  return $p.Value.value
}

function Test-FFCompatFactDeclared {
  param($Doc, [string]$Id)
  $p = $null
  try { $p = $Doc.facts.PSObject.Properties[$Id] } catch {}
  return ($null -ne $p)
}

# compat.ps1 records one UNCONDITIONAL constraint: winget-repair reaches the PowerShell
# Gallery and then Microsoft's servers, and a compatibility check deliberately makes no
# network request of its own - so reachability is declared out of scope rather than guessed.
# It is therefore 'degraded' even on a perfect machine, and the control test says so rather
# than pretending it does not exist.
$FFCompatAlwaysDegraded = @{ 'winget-repair' = 'network-not-probed' }

function Test-FFCompatDoctrine {
  <#
    Returns the list of doctrine violations in a -Action check document. EMPTY means the
    document is internally honest. This is the function the sabotage test proves has teeth:
    it recomputes each verdict from that row's OWN reasons with an independent rank, so a
    Resolve-Verdict that always answers 'supported' contradicts the reasons it recorded.
  #>
  param($Doc)
  $bad = @()
  if ($null -eq $Doc) { return @('the document is null') }
  $rows = @($Doc.capabilities)
  if ($rows.Count -eq 0) { return @('the document carries no capability rows at all') }

  foreach ($r in $rows) {
    $v = "$($r.verdict)"
    if (-not $FFVerdictRank.ContainsKey($v)) { $bad += "[$($r.id)] verdict '$v' is not in the declared vocabulary"; continue }
    $reasons = @($r.reasons)

    # 1. A verdict may never be better than the worst constraint the row itself recorded.
    $worst = 'supported'
    foreach ($c in $reasons) {
      $cv = "$($c.verdict)"
      if (-not $FFVerdictRank.ContainsKey($cv)) { $bad += "[$($r.id)] reason code '$($c.code)' carries verdict '$cv', which is not in the vocabulary"; continue }
      if ($FFVerdictRank[$cv] -gt $FFVerdictRank[$worst]) { $worst = $cv }
    }
    if ($v -ne $worst) {
      $codes = (@($reasons | ForEach-Object { "$($_.code)=$($_.verdict)" }) -join ', ')
      $bad += "[$($r.id)] reports verdict '$v' but its own reasons resolve to '$worst' ($codes)"
    }

    # 2. Every row must carry a non-empty, human-readable reason.
    if (-not ("$($r.reason)" -match '\S')) { $bad += "[$($r.id)] carries no reason text" }

    # 3. 'supported' means: nothing stood in the way. It may not be reached with constraints
    #    on the record, and it may not be reached over a requirement that was not measured.
    if ($v -eq 'supported' -and $reasons.Count -gt 0) {
      $bad += "[$($r.id)] is 'supported' while recording $($reasons.Count) constraint(s)"
    }
    foreach ($need in @($r.requires)) {
      $f = Get-FFCompatFact -Doc $Doc -Id "$need"
      if ($f -eq $true) { continue }
      if ($v -eq 'supported' -or $v -eq 'needs-admin') {
        $state = 'false'; if ($null -eq $f) { $state = 'null (could not determine)' }
        $bad += "[$($r.id)] is '$v' although the fact it requires, '$need', is $state"
      }
    }
  }

  # 4. The totals must describe the rows that are actually there.
  $sum = 0
  foreach ($p in @($Doc.totals.PSObject.Properties)) { $sum += [int]$p.Value }
  if ($sum -ne $rows.Count) { $bad += "totals sum to $sum but there are $($rows.Count) capability rows" }
  foreach ($p in @($Doc.totals.PSObject.Properties)) {
    $n = @($rows | Where-Object { "$($_.verdict)" -eq "$($p.Name)" }).Count
    if ([int]$p.Value -ne $n) { $bad += "totals['$($p.Name)'] says $($p.Value) but $n row(s) carry that verdict" }
  }

  # 5. Every fact must be tri-state, and every fact a row cites must exist.
  foreach ($p in @($Doc.facts.PSObject.Properties)) {
    $val = $p.Value.value
    if ($null -ne $val -and -not ($val -is [bool])) { $bad += "fact '$($p.Name)' is neither true, false nor null (got '$val')" }
  }
  @($bad)
}

# ---------------- the real machine, with the real probes ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: on THIS machine, with the real probes, the document is internally honest' -Body {
  <#
    Every other test in this file replaces the thirteen probe functions, so none of them executes
    Get-CompatOsIdentity, Get-CompatLanguage, Get-CompatElevation and the rest against a real
    Windows. This one does - read-only, unelevated, on the developer's own desktop - and holds the
    result to exactly the same doctrine invariants. It cannot assert WHAT this machine is (that
    would be a test of the machine, not of the engine), only that whatever compat.ps1 says about
    it is consistent with what compat.ps1 itself measured.
  #>
  $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath 'compat.ps1') -EngineArgs @('-Action', 'check') -TimeoutMs 120000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'compat.ps1 check' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the check document must parse'

  $violations = Test-FFCompatDoctrine -Doc $doc
  Assert-Eq 0 @($violations).Count "no doctrine violation against the real machine: $(@($violations) -join ' | ')"
  Assert-True (@($doc.capabilities).Count -ge 30) 'every capability is judged'
  Assert-NotNull $doc.facts 'the facts the verdicts were derived from are in the document'
  Assert-NotNull $doc.probes 'and so are the probe readings underneath them'
  Assert-Match '\S' "$($doc.summary)" 'and a one-line summary a human can read'

  # The suite runs unelevated, so this is also the one place the real elevation probe is checked
  # against the truth the runner already knows.
  $admin = $false
  try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
  Assert-Eq $admin (Get-FFCompatFact -Doc $doc -Id 'env:admin') 'the real elevation probe agrees with the token this process actually holds'
  if (-not $admin) {
    Assert-True ([int]$doc.totals.'needs-admin' -gt 0) 'and unelevated, the admin-gated capabilities are reported as such'
    Assert-Eq 1 @($doc.blockers | Where-Object { "$($_.id)" -eq 'not-elevated' }).Count 'with the reason stated once at the top'
  }
}

# ---------------- the control: a machine where everything really is fine ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: an elevated English Pro machine with everything present is all-supported' -Body {
  $r = Invoke-FFCompatCheck
  Assert-Stop $r.parsed.ok "compat.ps1 -Action check must emit exactly one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq '' ("$($r.res.stderr)".Trim()) 'and nothing on stderr'
  Assert-Eq 0 $r.res.exitCode 'and exit 0'
  Assert-Eq $true $doc.ok 'the document reports ok'
  Assert-Eq 'check' $doc.action 'and names the action it performed'

  $violations = Test-FFCompatDoctrine -Doc $doc
  Assert-Eq 0 @($violations).Count "no doctrine violation on the control machine: $(@($violations) -join ' | ')"

  $rows = @($doc.capabilities)
  Assert-True ($rows.Count -ge 30) "the check produces a verdict for every capability (got $($rows.Count))"
  $notSupported = @($rows | Where-Object { "$($_.verdict)" -ne 'supported' -and -not $FFCompatAlwaysDegraded.ContainsKey("$($_.id)") })
  Assert-Eq 0 $notSupported.Count "every capability but the documented exception is supported here: $(@($notSupported | ForEach-Object { "$($_.id)=$($_.verdict)" }) -join ', ')"
  foreach ($id in @($FFCompatAlwaysDegraded.Keys)) {
    $row = Get-FFCompatRow -Doc $doc -Id $id
    Assert-NotNull $row "the documented always-degraded capability '$id' is still in the catalog"
    Assert-Eq 'degraded' "$($row.verdict)" "$id declares a dependency compat.ps1 deliberately does not probe"
    Assert-Match $FFCompatAlwaysDegraded[$id] (@($row.reasons | ForEach-Object { $_.code }) -join ',') 'and names it'
  }
  Assert-Eq ($rows.Count - $FFCompatAlwaysDegraded.Count) ([int]$doc.totals.supported) 'and the totals say so'
  $blocking = @($doc.blockers | Where-Object { "$($_.severity)" -eq 'blocking' })
  Assert-Eq 0 $blocking.Count 'nothing blocks FrameForge on this machine'

  # Every fact a rule cites must actually exist in the document, or a typo becomes a silent
  # permanent 'unknown' nobody notices.
  foreach ($row in $rows) {
    foreach ($need in @($row.requires) + @($row.softens)) {
      if (-not ("$need" -match '\S')) { continue }
      Assert-True (Test-FFCompatFactDeclared -Doc $doc -Id "$need") "[$($row.id)] cites fact '$need', which the probes must actually produce"
    }
  }
}

# ---------------- lockdown: ConstrainedLanguage ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: ConstrainedLanguage makes EVERY capability unavailable, and says so once at the top' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ languageMode = 'ConstrainedLanguage' } -Label 'compat-cl'
  Assert-Stop $r.parsed.ok "the check still emits one JSON document under lockdown ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 'ConstrainedLanguage' "$($doc.languageMode)" 'the document reports the language mode it found'
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'

  $rows = @($doc.capabilities)
  $wrong = @($rows | Where-Object { "$($_.verdict)" -ne 'unavailable' })
  Assert-Eq 0 $wrong.Count "WDAC/AppLocker lockdown stops everything: $(@($wrong | ForEach-Object { "$($_.id)=$($_.verdict)" }) -join ', ')"
  Assert-Eq 0 ([int]$doc.totals.supported) 'and nothing may be counted as supported'
  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'constrained-language' })
  Assert-Eq 1 $b.Count 'the blocker is named once, plainly, at the top'
  Assert-Eq 'blocking' "$($b[0].severity)" 'at blocking severity'
}

# ---------------- elevation ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: unelevated downgrades what needs admin and NEVER calls it supported' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ admin = $false; canElevate = $true } -Label 'compat-noadmin'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-Eq $false (Get-FFCompatFact -Doc $doc -Id 'env:admin') 'the elevation fact is measured false'

  # system-files is declared admin-only, so it must lose 'supported'.
  $sf = Get-FFCompatRow -Doc $doc -Id 'system-files'
  Assert-NotNull $sf 'the system-files health category has a row'
  Assert-Eq 'needs-admin' "$($sf.verdict)" 'an admin-only check reports needs-admin unelevated'
  Assert-Match 'needs-elevation' (@($sf.reasons | ForEach-Object { $_.code }) -join ',') 'and names elevation as the reason'

  Assert-True ([int]$doc.totals.'needs-admin' -gt 0) 'the totals count the admin-gated capabilities'
  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'not-elevated' })
  Assert-Eq 1 $b.Count 'and the report says once, at the top, that it is running unelevated'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: elevation that could not be determined is unknown, not needs-admin' -Body {
  # 'unknown' outranks 'needs-admin' deliberately: not knowing is worse than knowing you need
  # rights, because it cannot be acted on.
  $r = Invoke-FFCompatCheck -Spec @{ admin = $null; canElevate = $null } -Label 'compat-elevunk'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-HonestUnknown (Get-FFCompatFact -Doc $doc -Id 'env:admin') 'an elevation reading that failed'
  $sf = Get-FFCompatRow -Doc $doc -Id 'system-files'
  Assert-Eq 'unknown' "$($sf.verdict)" 'an admin-gated check whose elevation could not be read is unknown'
  Assert-Match 'elevation-undetermined' (@($sf.reasons | ForEach-Object { $_.code }) -join ',') 'and the code says exactly that'

  # EVERY row that needs elevation must be 'unknown' - never 'needs-admin' (which would claim
  # a reading nobody took) and never 'supported'.
  $adminRows = @($doc.capabilities | Where-Object { $_.requiresAdmin -eq $true })
  Assert-True ($adminRows.Count -ge 5) "the catalog really does declare admin-only repairs (got $($adminRows.Count))"
  foreach ($row in $adminRows) {
    Assert-NotIn "$($row.verdict)" @('supported', 'needs-admin') "$($row.id) needs elevation nobody could measure, so it is not promised either way"
  }
  Assert-Eq 0 ([int]$doc.totals.'needs-admin') 'nothing may be reported as merely needing admin when elevation itself was not measured'
  # A capability that needs no elevation is legitimately untouched by this, and saying so is
  # the difference between an honest report and a scare.
  $net = Get-FFCompatRow -Doc $doc -Id 'network'
  Assert-Eq 'supported' "$($net.verdict)" 'a capability that needs no elevation is unaffected'
}

# ---------------- UI language ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: a non-English UI degrades the checks that keep an English-only rung' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ english = $false } -Label 'compat-de'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-Eq $false (Get-FFCompatFact -Doc $doc -Id 'env:english-ui') 'the UI-language fact is measured false'

  # 'disk' declares an English fallback (the fsutil dirty-bit text), so it must not stay clean.
  $disk = Get-FFCompatRow -Doc $doc -Id 'disk'
  Assert-NotNull $disk 'the disk health category has a row'
  Assert-NotIn "$($disk.verdict)" @('supported') 'a check that lost its English rung is not simply supported'
  Assert-Match 'english-only-fallback-lost' (@($disk.reasons | ForEach-Object { $_.code }) -join ',') 'and the reason names the lost rung'

  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'non-english-ui' })
  Assert-Eq 1 $b.Count 'the report says once that the UI is not English'
  Assert-Eq 'info' "$($b[0].severity)" 'at info severity - it costs fidelity, never correctness'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: a UI language that could not be read is unknown, never assumed English' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ english = $null } -Label 'compat-langunk'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-HonestUnknown (Get-FFCompatFact -Doc $doc -Id 'env:english-ui') 'a UI language that could not be read'
  $disk = Get-FFCompatRow -Doc $doc -Id 'disk'
  Assert-NotIn "$($disk.verdict)" @('supported') 'and the check that depends on it is not declared supported'
  Assert-Match 'ui-language-undetermined' (@($disk.reasons | ForEach-Object { $_.code }) -join ',') 'the code says the language is undetermined'
}

# ---------------- missing / unmeasurable dependencies ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: a missing cmdlet makes what binds to it unavailable, and names it' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ missingCommands = @('Repair-WindowsImage', 'Get-PhysicalDisk') } -Label 'compat-nocmd'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-Eq $false (Get-FFCompatFact -Doc $doc -Id 'cmdlet:Repair-WindowsImage') 'the missing cmdlet is measured absent'

  foreach ($pair in @(@('system-files', 'Repair-WindowsImage'), @('disk', 'Get-PhysicalDisk'))) {
    $row = Get-FFCompatRow -Doc $doc -Id $pair[0]
    Assert-Eq 'unavailable' "$($row.verdict)" "$($pair[0]) cannot run without $($pair[1])"
    Assert-Match 'missing-requirement' (@($row.reasons | ForEach-Object { $_.code }) -join ',') 'and the code says a requirement is missing'
    Assert-Match ([regex]::Escape($pair[1])) "$($row.reason)" 'and the sentence NAMES the thing that is missing'
  }
  # An in-box tool that is present must not be dragged down with it.
  $net = Get-FFCompatRow -Doc $doc -Id 'network'
  Assert-Eq 'supported' "$($net.verdict)" 'a capability with no missing dependency is untouched'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: a cmdlet whose presence could NOT be determined is unknown, not absent and not fine' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ unknownCommands = @('Get-WinEvent') } -Label 'compat-unkcmd'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-HonestUnknown (Get-FFCompatFact -Doc $doc -Id 'cmdlet:Get-WinEvent') 'a Get-Command call that failed'
  foreach ($id in @('stability', 'windows-update')) {
    $row = Get-FFCompatRow -Doc $doc -Id $id
    Assert-Eq 'unknown' "$($row.verdict)" "$id depends on Get-WinEvent, which could not be measured"
    Assert-Match 'requirement-undetermined' (@($row.reasons | ForEach-Object { $_.code }) -join ',') 'and says the requirement is undetermined'
  }
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: an edition with no Store cannot run the Store capabilities' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ edition = 'EnterpriseS'; store = $false } -Label 'compat-nostore'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  $row = Get-FFCompatRow -Doc $doc -Id 'store'
  Assert-Eq 'unavailable' "$($row.verdict)" 'the store health category cannot run without the Store'
  Assert-Match 'no-store-on-this-edition' (@($row.reasons | ForEach-Object { $_.code }) -join ',') 'and the code names the edition as the reason'
}

# ---------------- System Restore ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 4' -Slow `
  -Name 'compat check: System Restore off degrades every restorePoint:enforced repair, and says why' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ systemRestore = $false } -Label 'compat-nosr'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-Eq $false (Get-FFCompatFact -Doc $doc -Id 'cap:system-restore') 'the capability is measured false'

  $enforced = @($doc.capabilities | Where-Object { "$($_.restorePoint)" -eq 'enforced' })
  Assert-True ($enforced.Count -ge 3) "the catalog really does declare enforced-restore-point repairs (got $($enforced.Count))"
  foreach ($row in $enforced) {
    Assert-NotIn "$($row.verdict)" @('supported') "$($row.id) creates a checkpoint FIRST and aborts if it cannot, so it is not simply supported"
    Assert-Match 'restore-point-unavailable' (@($row.reasons | ForEach-Object { $_.code }) -join ',') "$($row.id) must name the missing checkpoint"
  }
  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'no-restore-point' })
  Assert-Eq 1 $b.Count 'and it is called out once at the top'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: a System Restore capability that could not be read is unknown, not off' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ systemRestore = $null } -Label 'compat-srunk'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-HonestUnknown (Get-FFCompatFact -Doc $doc -Id 'cap:system-restore') 'an unreadable System Restore capability'
  $enforced = @($doc.capabilities | Where-Object { "$($_.restorePoint)" -eq 'enforced' })
  foreach ($row in $enforced) {
    Assert-NotIn "$($row.verdict)" @('supported', 'needs-admin') "$($row.id) cannot be promised when the checkpoint capability is unknown"
  }
  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'no-restore-point' })
  Assert-Eq 0 $b.Count 'and an UNKNOWN capability is not reported as a measured "no restore point" blocker'
}

# ---------------- the build number ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: an unreadable build makes every build-gated repair undetermined, never applicable' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ build = $null; osSupported = $null; generation = $null
                                     unsupportedReason = 'STUB: the Windows build number could not be read.' } -Label 'compat-nobuild'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-Eq $false (Get-FFCompatFact -Doc $doc -Id 'env:build-readable') 'the build is recorded as unreadable'
  Assert-HonestUnknown (Get-FFCompatFact -Doc $doc -Id 'env:os-supported') 'and the platform verdict is an honest unknown'

  $rows = @($doc.capabilities)
  $claimed = @($rows | Where-Object { "$($_.verdict)" -eq 'supported' -or "$($_.verdict)" -eq 'needs-admin' })
  Assert-Eq 0 $claimed.Count "nothing may be promised on a machine whose Windows version could not be read: $(@($claimed | ForEach-Object { $_.id }) -join ', ')"

  # applicableOnThisBuild is the field the UI reads. It must be null, not true.
  $gated = @($rows | Where-Object { "$($_.kind)" -eq 'repair' -and $null -eq $_.applicableOnThisBuild })
  Assert-True ($gated.Count -ge 1) 'at least one repair declares a build or generation gate that now reads as undetermined'
  $liar = @($rows | Where-Object { "$($_.kind)" -eq 'repair' -and $_.applicableOnThisBuild -eq $false })
  Assert-Eq 0 $liar.Count 'and no repair is declared NOT applicable on a build nobody could read'
  Assert-Match 'could not be determined' "$($doc.summary)" 'the one-line summary admits what could not be determined'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: an unvalidated platform is degraded and named, not silently accepted' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ build = '19045'; generation = 'win10'; osSupported = $false
                                     unsupportedReason = 'STUB: Windows build 19045 is older than 22000.' } -Label 'compat-win10'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  $rows = @($doc.capabilities)
  $supported = @($rows | Where-Object { "$($_.verdict)" -eq 'supported' })
  Assert-Eq 0 $supported.Count 'nothing is "supported as designed" on a platform FrameForge is not validated on'
  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'unvalidated-platform' })
  Assert-Eq 1 $b.Count 'and the report says so once, at the top'
  Assert-Match '19045' "$($b[0].detail)" 'naming the build it actually read'
}

# ---------------- execution policy ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: a policy that refuses script FILES is a blocker, and reaches the repairs that shell out' -Body {
  $r = Invoke-FFCompatCheck -Spec @{ bypassBlocked = $true } -Label 'compat-xp'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'
  Assert-Eq $false (Get-FFCompatFact -Doc $doc -Id 'env:execution-policy-allows-file') 'the policy fact is measured false'
  $b = @($doc.blockers | Where-Object { "$($_.id)" -eq 'execution-policy-blocks-script-files' })
  Assert-Eq 1 $b.Count 'it is reported once at the top'
  Assert-Eq 'blocking' "$($b[0].severity)" 'at blocking severity'
  $affected = @($doc.capabilities | Where-Object { "$($_.kind)" -eq 'repair' -and (@($_.reasons | ForEach-Object { $_.code }) -contains 'child-script-blocked-by-policy') })
  Assert-True ($affected.Count -ge 1) 'and it reaches every repair that detects by running health.ps1 as a child process'
}

# ---------------- THE SABOTAGE TEST ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: SABOTAGE - a Resolve-Verdict stubbed to always pass is CAUGHT' -Body {
  <#
    The whole point. Before this file existed, patching a scratchpad copy so Resolve-Verdict
    returned 'supported' unconditionally and Test-CompatCommand always reported absent still
    passed the suite green, while compat.ps1 printed "40 of 40 capabilities can run here as
    designed". If Test-FFCompatDoctrine has teeth, that sabotage cannot pass here.
    This test FAILS if the sabotage goes unnoticed.
  #>
  $sabotage = @'
function Resolve-Verdict { param($Constraints) return 'supported' }
'@
  $r = Invoke-FFCompatCheck -Spec @{ missingCommands = @('Repair-WindowsImage', 'Get-PhysicalDisk', 'Get-WinEvent', 'Checkpoint-Computer')
                                     admin = $false; english = $false; systemRestore = $false } `
                            -ExtraPatch $sabotage -Label 'compat-sabotage'
  Assert-Stop $r.parsed.ok "the sabotaged engine still emits one JSON document ($($r.parsed.error))"
  $doc = $r.doc

  # The sabotage does exactly what it did to the real tree: everything reads as fine.
  Assert-Match 'can run here as designed' "$($doc.summary)" 'the sabotaged engine reports a clean bill of health'
  $supported = @($doc.capabilities | Where-Object { "$($_.verdict)" -eq 'supported' })
  Assert-Eq @($doc.capabilities).Count $supported.Count 'and calls every single capability supported'

  # ...and the suite must not believe a word of it.
  $violations = Test-FFCompatDoctrine -Doc $doc
  Assert-True (@($violations).Count -gt 0) 'THE SUITE MUST CATCH THIS. A stubbed Resolve-Verdict that always answers "supported" has to be reported as a doctrine violation, or none of the tests above are evidence.'
  Assert-Match 'but its own reasons resolve to' (@($violations) -join ' | ') 'and the violation must say the verdict contradicts the row own recorded reasons'
  Assert-Match 'although the fact it requires' (@($violations) -join ' | ') 'and that a capability was promised over a dependency that is not there'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Slow `
  -Name 'compat check: SABOTAGE - a probe that reports every command absent is CAUGHT' -Body {
  # The second half of the original sabotage, on its own: Test-CompatCommand always absent.
  # Here Resolve-Verdict is left honest, so the ENGINE gets this right - and the test proves
  # the assertion is measuring the engine rather than the stub, by demanding the correct
  # (pessimistic) answer instead of a green one.
  $r = Invoke-FFCompatCheck -Spec @{ missingCommands = @(
        'Repair-WindowsImage', 'Get-WindowsOptionalFeature', 'Enable-WindowsOptionalFeature',
        'Repair-Volume', 'Get-Volume', 'Get-PhysicalDisk', 'Get-StorageReliabilityCounter',
        'Get-AppxPackage', 'Add-AppxPackage', 'Get-AppxProvisionedPackage',
        'Get-BitsTransfer', 'Remove-BitsTransfer', 'Set-DnsClientServerAddress', 'Resolve-DnsName',
        'Checkpoint-Computer', 'Enable-ComputerRestore', 'Get-ComputerRestorePoint',
        'Get-BitLockerVolume', 'Set-Service', 'Restart-Service', 'Start-Service', 'Stop-Service',
        'Get-HotFix', 'Get-WinEvent', 'Get-CimInstance', 'Get-Service', 'Repair-WinGetPackageManager') } `
      -Label 'compat-nocmds'
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $doc = $r.doc
  Assert-Eq 0 @(Test-FFCompatDoctrine -Doc $doc).Count 'the document stays internally honest'

  # Every capability that binds to ANY of those cmdlets must be unavailable and must name it.
  $bound = @($doc.capabilities | Where-Object { @($_.requires) -match '^cmdlet:' })
  Assert-True ($bound.Count -ge 10) "many capabilities bind to a cmdlet (got $($bound.Count))"
  foreach ($row in $bound) {
    Assert-Eq 'unavailable' "$($row.verdict)" "$($row.id) binds to a cmdlet this image does not have"
    Assert-Match 'missing-requirement' (@($row.reasons | ForEach-Object { $_.code }) -join ',') "$($row.id) must say a requirement is missing"
  }
  Assert-True ([int]$doc.totals.unavailable -ge $bound.Count) 'and the totals count them as unavailable'
  # What is left is what genuinely still works: a capability that shells out to an in-box .exe
  # and touches no cmdlet is unaffected, and inventing a failure for it would be its own lie.
  $stillOk = @($doc.capabilities | Where-Object { "$($_.verdict)" -eq 'supported' })
  foreach ($row in $stillOk) {
    Assert-Eq 0 @(@($row.requires) -match '^cmdlet:').Count "$($row.id) is only still supported because it binds to no missing cmdlet"
  }
}

# ---------------- the stub rig itself ----------------

Register-FFTest -Area 'CONTRACT' -Name 'compat: the sandbox patcher refuses to touch anything outside this run work dir' -Body {
  # Add-FFSandboxEnginePatch REWRITES an engine file. The guard that keeps it inside the
  # per-run sandbox is the only thing standing between a test and the real tree.
  Assert-Throws { Add-FFSandboxEnginePatch -Sandbox $script:FFRepoRoot -Engine 'compat' -Patch '# no' } `
    'patching the REAL tree is refused' 'REFUSING to patch an engine outside'
  $sbx = New-FFSandbox -Label 'compat-guard'
  Assert-Throws { Add-FFSandboxEnginePatch -Sandbox $sbx -Engine 'no-such-engine' -Patch '# no' } `
    'a missing engine is an error, not a silent no-op' 'Sandboxed engine not found'
}
