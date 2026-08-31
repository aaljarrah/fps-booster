<#
  VMTEST :: tools\vmtest, validated as code

  The VM matrix cannot be exercised here: it needs Hyper-V and a Windows ISO, and the only
  machine available is the developer's real desktop, which nothing in this suite may mutate. So
  the harness gets the strongest coverage that is honestly available - static verification that
  every .ps1 parses, that every variable a success path reads is one its file actually assigns,
  that every unattend template is well-formed and carries the settings the harness depends on,
  and that matrix.json's references resolve against the engine's real catalogs.

  That is not a claim the matrix works. It is a claim about the code, and tools\vmtest\
  Test-VmHarness.ps1 says so in its own output note. What it does close is the class of defect
  that was actually found there: both of New-TestVm.ps1's success documents referenced
  $planDocDoc - a typo for $planDoc that StrictMode-off silently evaluated to $null, emitting
  plan:null and dropping the entire preflight/oscdimg/path block from the only record of what was
  provisioned. A typo that survives in both success paths proves the file had never completed a
  successful run, and nothing was ever going to notice it but a reader.
#>

$FFVmTestRoot = Join-Path $script:FFRepoRoot 'tools\vmtest'

function Invoke-FFVmHarnessCheck {
  param([string]$Root = $FFVmTestRoot)
  $script = Join-Path $FFVmTestRoot 'Test-VmHarness.ps1'
  $res = Invoke-FFEngineProcess -Script $script -EngineArgs @('-Root', $Root, '-RepoRoot', $script:FFRepoRoot) -TimeoutMs 120000
  $parsed = ConvertFrom-FFEngineStdout -Stdout $res.stdout
  [ordered]@{ res = $res; parsed = $parsed; doc = $parsed.doc }
}

function Get-FFVmCheck {
  param($Doc, [string]$Name)
  @($Doc.checks | Where-Object { "$($_.check)" -eq $Name }) | Select-Object -First 1
}

function Import-FFVmFunction {
  <# Lifts ONE function definition out of a tools\vmtest script with the parser and defines it
     here, so its behaviour can be tested without executing the script's top level (which would
     want Hyper-V, a credential and an ISO). The extent is the real source text: if the function
     is renamed or deleted, this throws rather than silently testing nothing. #>
  param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Name)
  $path = Join-Path $FFVmTestRoot $File
  if (-not (Test-Path -LiteralPath $path)) { throw "vmtest script not found: $path" }
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -gt 0) { throw "$File does not parse: $(@($errors)[0].Message)" }
  $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true)
  if ($null -eq $fn) { throw "$File defines no function '$Name'" }
  [scriptblock]::Create($fn.Extent.Text)
}

# ---------------- the static validator ----------------

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' -Slow `
  -Name 'vmtest: Test-VmHarness.ps1 passes over the real harness, and emits one JSON doc' -Body {
  $r = Invoke-FFVmHarnessCheck
  Assert-Stop $r.parsed.ok "the validator must emit exactly one JSON document ($($r.parsed.error))"
  Assert-Eq '' ("$($r.res.stderr)".Trim()) 'and write nothing to stderr'
  $doc = $r.doc
  $problems = @()
  foreach ($c in @($doc.checks)) { foreach ($p in @($c.problems)) { $problems += "[$($c.check)] $p" } }
  Assert-Eq 0 @($problems).Count "the VM harness must validate clean: $(@($problems) -join ' | ')"
  Assert-Eq $true $doc.ok 'the validator reports ok'
  Assert-Eq 0 $r.res.exitCode 'and exits 0'
}

Register-FFTest -Area 'VMTEST' -Slow -Name 'vmtest: the validator really performs every check it claims' -Body {
  # A validator that quietly stops running a check is worse than no validator: it turns a gap
  # into a green tick. Each of these must be PRESENT and passing, by name.
  $r = Invoke-FFVmHarnessCheck
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  foreach ($name in @('ps1-files-parse', 'variables-resolve', 'strict-mode-declared',
                      'unattend-templates', 'unattend-tokens-substituted',
                      'guest-bootstrap-not-circular', 'matrix-references-resolve',
                      'outcome-codes-documented')) {
    $c = Get-FFVmCheck -Doc $r.doc -Name $name
    Assert-NotNull $c "the validator must run the '$name' check"
    Assert-Eq $true $c.ok "'$name' must pass"
  }
  $parseCheck = Get-FFVmCheck -Doc $r.doc -Name 'ps1-files-parse'
  Assert-True ([int]$parseCheck.detail.files -ge 15) "and it must actually see the harness's scripts (found $($parseCheck.detail.files))"
  $tpl = (Get-FFVmCheck -Doc $r.doc -Name 'unattend-templates').detail.templates
  Assert-True (@($tpl).Count -ge 4) 'every unattend template is inspected'
  foreach ($t in @($tpl)) {
    Assert-Eq $true $t.wellFormed "$($t.file) is well-formed XML"
    Assert-Eq $true $t.localAdmin "$($t.file) defines the local administrator PowerShell Direct authenticates as"
    Assert-Eq $true $t.tokenFilterPolicyInSpecialize "$($t.file) sets LocalAccountTokenFilterPolicy in the SPECIALIZE pass, before first logon"
  }
}

Register-FFTest -Area 'VMTEST' -Doctrine 'the suite is a gate' -Slow `
  -Name 'vmtest: SABOTAGE - the validator catches a $planDocDoc-style typo in a copy of the tree' -Body {
  # The exact defect that shipped: a success document referencing a variable that does not exist.
  # If the validator cannot see it in a copy, its green result over the real tree means nothing.
  $copy = Join-Path $script:FFWorkDir ('vmtest-sabotage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $copy | Out-Null
  Copy-Item -Path (Join-Path $FFVmTestRoot '*') -Destination $copy -Recurse -Force
  $target = Join-Path $copy 'New-TestVm.ps1'
  Assert-Stop (Test-Path -LiteralPath $target) 'the copy carries New-TestVm.ps1'

  # First prove the COPY is clean, so the sabotage below is the only difference.
  $before = Invoke-FFVmHarnessCheck -Root $copy
  Assert-Stop $before.parsed.ok "the copy validates and emits one JSON doc ($($before.parsed.error))"
  Assert-Eq $true $before.doc.ok 'an untouched copy of the harness validates clean'

  $text = Get-Content -LiteralPath $target -Raw -Encoding UTF8
  $sabotaged = $text -replace 'plan = \$planDoc\b', 'plan = $planDocDoc'
  Assert-Stop ($sabotaged -ne $text) 'the sabotage actually changed something (the success documents still reference $planDoc)'
  [System.IO.File]::WriteAllText($target, $sabotaged, (New-Object System.Text.UTF8Encoding($true)))

  $after = Invoke-FFVmHarnessCheck -Root $copy
  Assert-Stop $after.parsed.ok "the validator still emits one JSON doc over the sabotaged copy ($($after.parsed.error))"
  Assert-Eq $false $after.doc.ok 'THE VALIDATOR MUST CATCH IT: a variable no file assigns is exactly the defect that shipped'
  Assert-Eq 1 $after.res.exitCode 'and it must exit non-zero, so CI cannot be green over it'
  $vars = Get-FFVmCheck -Doc $after.doc -Name 'variables-resolve'
  Assert-Eq $false $vars.ok 'the variables-resolve check is the one that fires'
  Assert-Match 'planDocDoc' (@($vars.problems) -join ' | ') 'and it names the variable'
}

# ---------------- the probe-depth precondition ----------------

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' `
  -Name 'vmtest: the component-store rows declare the deep probe they need' -Body {
  # matrix.json paired the component-store-broken fault with sfc-scannow and dism-restorehealth,
  # and NEITHER carries probeDeep in data\repairs.json - so detection ran the SHALLOW system-files
  # probe. That probe's only component-store reading is Repair-WindowsImage -Online -CheckHealth,
  # which reads the corruption FLAGS a previous servicing operation recorded; it does not scan.
  # Renaming a WinSxS payload file sets no flag, so CheckHealth answers Healthy and both rows
  # recorded 'false-pass' - this harness's declared release blocker - on EVERY cell including the
  # en-US control, for a reason with nothing to do with locale or with the engine.
  $matrix = Get-Content -LiteralPath (Join-Path $FFVmTestRoot 'matrix.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $rows = @($matrix.repairPlan | Where-Object { "$($_.fault)" -eq 'component-store-broken' })
  Assert-True ($rows.Count -ge 2) "the component-store fault is still paired with repairs (got $($rows.Count))"
  foreach ($row in $rows) {
    Assert-Eq $true ([bool]$row.requiresProbeDeep) "the '$($row.repair)' row must declare that its fault needs the DEEP probe"
  }
  $doc = @($matrix.planFieldNotes.PSObject.Properties | Where-Object { $_.Name -eq 'requiresProbeDeep' })
  Assert-Eq 1 $doc.Count 'and planFieldNotes must explain what the field means'
  Assert-Match 'CheckHealth' "$($doc[0].Value)" 'naming the shallow probe that cannot see it'

  # The code lives under notJudgedCodes, NOT skipCodes: an unmet precondition is a catalog
  # defect somebody owns, and filing it with "the VM was not available" is how it went quiet.
  $nj = @($matrix.notJudgedCodes.PSObject.Properties | Where-Object { $_.Name -eq 'harness-precondition-unmet' })
  Assert-Eq 1 $nj.Count 'the outcome the runner uses must be a documented NOT-JUDGED code'
  Assert-Match 'never a FAIL' "$($nj[0].Value)" 'and it must say plainly that this is never scored against the engine'
  Assert-Match 'never a SKIP' "$($nj[0].Value)" 'nor filed away as a skip'
  $skip = @($matrix.skipCodes.PSObject.Properties | Where-Object { $_.Name -eq 'harness-precondition-unmet' })
  Assert-Eq 0 $skip.Count 'and it must NOT also be a skip code - one state, one meaning'
  $oc = @($matrix.outcomeCodes.PSObject.Properties | Where-Object { $_.Name -eq 'not-judged' })
  Assert-Eq 1 $oc.Count 'not-judged must be a documented outcome in its own right'
  Assert-Match 'NEVER folded into pass' "$($oc[0].Value)" 'and the documentation must say it is never a pass'
}

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' `
  -Name 'vmtest: Test-RowPrecondition refuses to judge rather than misattributing when the catalog cannot see the fault' -Body {
  . (Import-FFVmFunction -File 'Invoke-VmMatrix.ps1' -Name 'Test-RowPrecondition')

  # 1. The row declares the deep probe and the catalog provides it: run the row.
  $ok = Test-RowPrecondition -Plan_ ([pscustomobject]@{ requiresProbeDeep = $true }) `
                             -CatEntry ([pscustomobject]@{ probeDeep = $true }) -RepairId 'sfc-scannow'
  Assert-Null $ok 'a satisfied precondition lets the row run'

  # 2. The row declares it and the catalog does NOT: refuse, and name the catalog entry.
  $bad = Test-RowPrecondition -Plan_ ([pscustomobject]@{ requiresProbeDeep = $true }) `
                              -CatEntry ([pscustomobject]@{ }) -RepairId 'sfc-scannow'
  Assert-NotNull $bad 'an unsatisfied precondition stops the row'
  Assert-Match 'sfc-scannow' "$bad" 'and names the repair whose catalog entry has to change'
  Assert-Match 'probeDeep' "$bad" 'and the field that is missing'
  Assert-Match 'repairs\.json' "$bad" 'and the file it is missing from'
  Assert-Match 'NOTHING is concluded' "$bad" 'and says explicitly that no verdict about the engine is drawn'

  # 3. A row that declares nothing is unaffected. A precondition that fired on every row would be
  #    its own kind of dishonesty - it would hide real failures behind a skip.
  $none = Test-RowPrecondition -Plan_ ([pscustomobject]@{ }) -CatEntry ([pscustomobject]@{ }) -RepairId 'network-flush'
  Assert-Null $none 'a row with no declared precondition is untouched'
}

Register-FFTest -Area 'VMTEST' -Slow `
  -Name 'vmtest: an unmet probe-depth precondition is reported, never silently passed over' -Body {
  # Whether the catalog satisfies it TODAY is not this test's business - the repair fixer owns
  # data\repairs.json. What must hold either way is that the state is REPORTED: an unmet
  # precondition that nobody can see is indistinguishable from a row that quietly stopped testing.
  $r = Invoke-FFVmHarnessCheck
  Assert-Stop $r.parsed.ok "one JSON document ($($r.parsed.error))"
  $rows = @($r.doc.probeDepthPreconditions)
  Assert-True ($rows.Count -ge 2) "the validator reports every declared probe-depth precondition (got $($rows.Count))"
  foreach ($row in $rows) {
    Assert-Eq $true ([bool]$row.requiresProbeDeep) 'each reported row is one that declares the requirement'
    Assert-Match '\S' "$($row.effect)" 'and states what the harness will actually do about it'
    if (-not $row.catalogHasProbeDeep) {
      Assert-Match 'NOT JUDGED' "$($row.effect)" "an unsatisfied precondition must resolve to the NOT-JUDGED state for '$($row.repair)', never to a verdict"
      Assert-Match 'never a skip and never a pass' "$($row.effect)" 'and must say that it is neither of the two states a reader would otherwise assume'
      Assert-Match 'NO conclusion' "$($row.effect)" 'and must say so in as many words'
    } else {
      Assert-Match 'runs and is judged' "$($row.effect)" "a satisfied precondition must say the row is actually judged ('$($row.repair)')"
    }
  }
}

# ---------------- the results matrix cannot hide a row ----------------

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' `
  -Name 'vmtest: a row that could not be judged is a DISTINCT, visible state - never a skip, never a pass' -Body {
  # The regression this pins: the previous round converted a loud false-pass into a silent skip,
  # which hid the problem instead of fixing it. New-Summary is lifted out and run over synthetic
  # rows, so this is the real renderer's real output rather than a reading of the source.
  . (Import-FFVmFunction -File 'Invoke-VmMatrix.ps1' -Name 'New-Summary')
  $rows = @(
    [pscustomobject]@{ cell = 'ctrl'; repair = 'sfc-scannow';        outcome = 'pass';       code = 'ok';                        message = 'fine' }
    [pscustomobject]@{ cell = 'ctrl'; repair = 'dism-restorehealth'; outcome = 'not-judged'; code = 'harness-precondition-unmet'; message = 'the catalog cannot see this fault' }
    [pscustomobject]@{ cell = 'de';   repair = 'sfc-scannow';        outcome = 'skip';       code = 'cell-unavailable';           message = 'no VM' }
    [pscustomobject]@{ cell = 'de';   repair = 'dism-restorehealth'; outcome = 'fail';       code = 'false-pass';                 message = 'green tick over a real fault' }
  )
  $md = New-Summary -Results $rows -Matrix ([pscustomobject]@{}) -RunRoot 'D:\nowhere' -CellScans @{}
  Assert-Stop ("$md".Length -gt 0) 'the summary renders'

  Assert-Match '1 pass / 1 fail / 1 NOT JUDGED / 1 skip' "$md" 'the headline count must break the not-judged rows out on their own'
  Assert-Match 'NOT JUDGED \(harness-precondition-unmet\)' "$md" 'and the matrix table must name the state in the cell itself'
  Assert-Match '(?s)1 row\(s\) were NOT JUDGED' "$md" 'and say so in the "read this first" section'
  Assert-Match 'not a skip and certainly not a pass' "$md" 'in as many words'
  Assert-Match 'FAIL \(false-pass\)' "$md" 'a real failure is still rendered as a failure'
  Assert-Match 'skip \(cell-unavailable\)' "$md" 'and a genuine skip is still a skip'

  # The not-judged cell must not be rendered as a pass ANYWHERE, and the two states must not
  # be spelled the same way.
  $njLine = @("$md" -split "`r?`n" | Where-Object { $_ -match '^\| dism-restorehealth \|' })
  Assert-Eq 1 @($njLine).Count 'the repair has exactly one row in the matrix table'
  Assert-NoMatch '\| PASS \|' "$($njLine[0])" 'and the not-judged cell is not printed as PASS'

  # The absence of false passes must never be claimed over rows nobody judged: the not-judged
  # block has to appear even in the run where everything else was clean.
  $cleanRows = @(
    [pscustomobject]@{ cell = 'ctrl'; repair = 'sfc-scannow';        outcome = 'pass';       code = 'ok';                        message = 'fine' }
    [pscustomobject]@{ cell = 'ctrl'; repair = 'dism-restorehealth'; outcome = 'not-judged'; code = 'harness-precondition-unmet'; message = 'the catalog cannot see this fault' }
  )
  $md2 = New-Summary -Results $cleanRows -Matrix ([pscustomobject]@{}) -RunRoot 'D:\nowhere' -CellScans @{}
  Assert-Match 'No false passes' "$md2" 'the clean-run sentence still appears'
  Assert-Match 'row\(s\) were NOT JUDGED' "$md2" 'but never on its own - the rows it does not cover are printed next to it'
  Assert-True ("$md2".IndexOf('were NOT JUDGED') -gt "$md2".IndexOf('No false passes')) `
    'and immediately after it, so nobody reads the clean bill of health without the caveat'
  Assert-True ("$md2".IndexOf('were NOT JUDGED') -lt "$md2".IndexOf('## Matrix')) `
    'and above the matrix table, not buried under it'
}

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' `
  -Name 'vmtest: a probe result of "unknown" is never read as a successful detection' -Body {
  # 'unknown' is the honest answer a probe gives when it could not read the signal. The harness
  # must treat it as a GAP (fail / detect-unknown), never as the 'problem' it was looking for -
  # otherwise a cell where the measurement stopped working scores as coverage.
  $src = Get-Content -LiteralPath (Join-Path $FFVmTestRoot 'Invoke-VmMatrix.ps1') -Raw -Encoding UTF8

  # The decisive predicate: detection succeeds ONLY on state 'problem' WITH a matching finding.
  Assert-Match ([regex]::Escape('$okD = ($dState -eq ''problem'' -and $relCount -gt 0)')) $src `
    'the fault-detected assertion must require state=problem AND at least one matching finding'
  Assert-True ([regex]::Matches($src, [regex]::Escape('$okD =')).Count -eq 1) 'and it must be decided in exactly one place'

  # Nothing may compare the detection state against 'unknown' in order to accept it.
  Assert-NoMatch '\$dState\s+-eq\s+''unknown''' $src 'no branch may treat an unknown detection state as anything but a gap'
  Assert-NoMatch '\$dState\s+-ne\s+''problem''' $src 'and the predicate must not be re-derived by negation somewhere else'

  # detect-unknown is a FAILURE, and it is documented as one.
  Assert-Match ([regex]::Escape("Finish 'fail' 'detect-unknown'")) $src "an 'unknown' detection must Finish as a FAIL"
  Assert-True ([regex]::Matches($src, [regex]::Escape("Finish 'pass'")).Count -eq 1) `
    'and there must be exactly ONE place a row can pass, so no early branch can shortcut to it'
  $matrix = Get-Content -LiteralPath (Join-Path $FFVmTestRoot 'matrix.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $du = @($matrix.failCodes.PSObject.Properties | Where-Object { $_.Name -eq 'detect-unknown' })
  Assert-Eq 1 $du.Count "'detect-unknown' must be documented as a FAIL code, not a skip code"
  Assert-Eq 0 @($matrix.skipCodes.PSObject.Properties | Where-Object { $_.Name -eq 'detect-unknown' }).Count 'and must not also be a skip'
  Assert-Eq 0 @($matrix.notJudgedCodes.PSObject.Properties | Where-Object { $_.Name -eq 'detect-unknown' }).Count 'nor a not-judged code: the probe DID run, it just could not read the signal'

  # The same rule one layer down: the fault oracle's own "could not determine" is a failure too,
  # so a row is never judged against a fault the harness could not confirm it created.
  Assert-Match 'COULD NOT DETERMINE whether the fault is present' $src 'an oracle that cannot confirm the fault must say so'
  Assert-Match ([regex]::Escape("Finish 'fail' 'fault-injection-failed'")) $src 'and the row must fail rather than proceed to judge the engine'
}

# ---------------- the guest bootstrap ----------------

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' `
  -Name 'vmtest: the guest bootstrap no longer needs the privilege it exists to grant' -Body {
  # The circularity: Initialize-Guest.ps1 set LocalAccountTokenFilterPolicy=1 as its step 4, after
  # Set-ExecutionPolicy -Scope LocalMachine and Enable-ComputerRestore - and all three are HKLM
  # writes. On the harness's own premise (Invoke-VmMatrix.ps1: without that value the PowerShell
  # Direct token is filtered) the script could never have bootstrapped itself: the write that
  # grants the privilege needs the privilege. It is now set by the unattend's specialize pass,
  # which runs as LOCAL SYSTEM before any logon exists to be filtered.
  $init = Get-Content -LiteralPath (Join-Path $FFVmTestRoot 'guest\setup\Initialize-Guest.ps1') -Raw -Encoding UTF8
  Assert-NoMatch 'Set-ItemProperty[^\r\n]*LocalAccountTokenFilterPolicy' $init 'the guest script must not WRITE the policy it needs in order to write it'
  Assert-Match 'LocalAccountTokenFilterPolicy' $init 'but it must still VERIFY it, so an old base image fails loudly'
  Assert-Match 'IsInRole' $init 'and it must measure its own token before applying anything'

  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $FFVmTestRoot 'unattend') -Filter '*.xml')) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($f.FullName)
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $paths = @($xml.SelectNodes("//u:settings[@pass='specialize']//u:RunSynchronousCommand/u:Path", $ns) | ForEach-Object { "$($_.InnerText)" })
    Assert-True (@($paths | Where-Object { $_ -match 'LocalAccountTokenFilterPolicy' }).Count -ge 1) `
      "$($f.Name) sets the policy in the specialize pass, which runs as SYSTEM before first logon"
  }
}

Register-FFTest -Area 'VMTEST' -Doctrine 'rule 2' `
  -Name 'vmtest: New-TestVm refuses a guest whose baseline did not apply, instead of freezing it' -Body {
  # -Role base logged a line and carried on; -Role cell did not check at all. If System Protection
  # failed to enable, every restorePoint:"enforced" row aborts - and Invoke-VmMatrix.ps1 would
  # score that abort against the ENGINE. Refusing at provisioning time is the only place that
  # misattribution can be stopped.
  . (Import-FFVmFunction -File 'New-TestVm.ps1' -Name 'Get-GuestProp')
  . (Import-FFVmFunction -File 'New-TestVm.ps1' -Name 'Get-InitializeGuestFailure')

  $good = Get-InitializeGuestFailure -Result ([pscustomobject]@{ parsed = $true; raw = ''
    json = ([pscustomobject]@{ ok = $true; steps = @([pscustomobject]@{ step = 'system-protection'; ok = $true; detail = 'on' }) }) })
  Assert-Null $good 'a guest that reported ok:true is accepted'

  $bad = Get-InitializeGuestFailure -Result ([pscustomobject]@{ parsed = $true; raw = ''
    json = ([pscustomobject]@{ ok = $false; steps = @(
      [pscustomobject]@{ step = 'directories'; ok = $true; detail = 'made' },
      [pscustomobject]@{ step = 'system-protection'; ok = $false; detail = 'System Protection could NOT be enabled.' }) }) })
  Assert-NotNull $bad 'a guest that reported ok:false is refused'
  Assert-Match 'system-protection' "$bad" 'and the refusal names the step that failed'
  Assert-Match 'System Protection could NOT be enabled' "$bad" 'and carries its detail'
  Assert-NoMatch 'directories' "$bad" 'without dragging in the steps that succeeded'

  $unparsed = Get-InitializeGuestFailure -Result ([pscustomobject]@{ parsed = $false; raw = 'not json'; json = $null })
  Assert-NotNull $unparsed 'output that did not parse is a refusal, not a shrug'
  Assert-Match 'UNKNOWN' "$unparsed" 'because an unknown baseline is not a good one'

  $noField = Get-InitializeGuestFailure -Result ([pscustomobject]@{ parsed = $true; raw = ''; json = ([pscustomobject]@{ action = 'initialize-guest' }) })
  Assert-NotNull $noField 'JSON with no ok field is a refusal too'
  Assert-Match 'UNKNOWN' "$noField" 'for the same reason'

  # And the refusal has to be wired in on BOTH roles, not just the one that logged a line.
  $src = Get-Content -LiteralPath (Join-Path $FFVmTestRoot 'New-TestVm.ps1') -Raw -Encoding UTF8
  Assert-Eq 2 @([regex]::Matches($src, 'Get-InitializeGuestFailure -Result')).Count 'both -Role base and -Role cell must check it'
  Assert-Match 'guest-initialization-failed' $src 'and refuse with a named error code'
}
