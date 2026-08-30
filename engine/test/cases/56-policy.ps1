<#
  POLICY :: electron/main.js's execution-policy fallback, measured against the real engines

  WHAT IS BEING TESTED. -ExecutionPolicy Bypass sets only the PROCESS scope, and a Group
  Policy scope outranks it, so under "Turn on Script Execution = AllSigned" every unsigned
  FrameForge .ps1 is refused: stdout empty, no stated reason. main.js's fallback therefore
  reads the engine's TEXT and runs it as a scriptblock. That fallback is itself a doctrine
  rule 2 hazard - a way to produce a half-populated document nobody notices - so it has to be
  either genuinely correct or genuinely refusing, and this file measures which.

  THE BUG THIS PINS. The fallback used to invoke the engine with `& ([scriptblock]::Create(...))`.
  `&` runs the engine in a CHILD scope, so an unqualified top-level assignment lands somewhere
  `$script:` does not read from - a dynamically created scriptblock has no backing file, so its
  `$script:` is the -Command host's own top-level scope. repair.ps1 read nine top-level
  variables back through `$script:`; every one of them came back $null, silently. Dot-sourcing
  (`.`) runs the engine in the caller's scope, which IS that top-level scope, so the two names
  are the same variable again - exactly as they are under -File. Test 1 below demonstrates the
  difference from first principles; the rest prove the real engines behave identically under
  the real argv.

  THE ARGV IS NOT COPIED HERE. A second implementation of psArgsForMode living in a test file
  is precisely the "the catalog says one thing and the engine does another" failure this
  project treats as a blocker, so these tests ASK main.js for its argv:
      node electron/main.js --ff-print-ps-argv <mode> <script.ps1> [args...]

  HOW "A POLICY SCOPE WE CANNOT OVERRIDE" IS SIMULATED. A real MachinePolicy/UserPolicy value
  lives in the registry and setting one would MUTATE this machine, which the suite may never
  do. Instead the one token that differs is swapped in the argv main.js produced: Bypass ->
  AllSigned. The resulting process refuses to load script FILES and still runs -Command, which
  is the runtime condition the fallback exists for. What is being measured - can this argv get
  a complete, correct JSON document out of an engine when files cannot be loaded - is
  identical; only how the process acquired the policy differs, and that is not observable to
  anything under test. Test 2 proves the simulation actually bites by showing `file` mode
  failing under it.
#>

$FFMainJs = Join-Path $script:FFRepoRoot 'electron\main.js'

function Get-FFNodeExe {
  $c = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  $null
}

function Get-FFHostArgv {
  <# The argv electron/main.js says it would use, straight from main.js. #>
  param([ValidateSet('file','scriptblock')][string]$Mode, [string]$Script, [string[]]$EngineArgs = @())
  $node = Get-FFNodeExe
  if (-not $node) { throw 'node.exe was not found on PATH. It is a hard dependency of this repo (Electron), and these tests must not pretend to have measured the host without it.' }
  $out = & $node $FFMainJs '--ff-print-ps-argv' $Mode $Script @EngineArgs 2>&1
  $text = (@($out) -join '')
  $doc = $null
  try { $doc = $text | ConvertFrom-Json -ErrorAction Stop } catch { throw "main.js --ff-print-ps-argv did not emit JSON: $text" }
  $doc
}

function ConvertTo-FFBlockedPolicyArgv {
  <# The same argv, but in a process that refuses script FILES. See the header. #>
  param([string[]]$Argv)
  @(@($Argv) | ForEach-Object { if ("$_" -eq 'Bypass') { 'AllSigned' } else { "$_" } })
}

# ---------------- 1. the scope semantics the whole fallback turns on ----------------

Register-FFTest -Area 'POLICY' -Doctrine 'rule 2' -Name 'scriptblock scope: `&` loses $script: variables and `.` does not' -Body {
  # From first principles, on a throwaway file in this run's scratch - no engine involved, so
  # this stays true (and stays the REASON) however the engines are written.
  $p = Join-Path $script:FFWorkDir ('scope-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
  [System.IO.File]::WriteAllText($p, "`$v = 'set-at-top-level'`r`nWrite-Output (`"[`$(`$script:v)]`")`r`n", (New-Object System.Text.UTF8Encoding($true)))
  $q = $p -replace "'", "''"
  $call = & $script:FFPwsh -NoProfile -ExecutionPolicy AllSigned -Command "`$s = Get-Content -Raw -LiteralPath '$q'; & ([scriptblock]::Create(`$s))"
  $dot  = & $script:FFPwsh -NoProfile -ExecutionPolicy AllSigned -Command "`$s = Get-Content -Raw -LiteralPath '$q'; . ([scriptblock]::Create(`$s))"
  Assert-Eq '[]'                "$call".Trim() '`&` runs the text in a CHILD scope, so $script: reads nothing - this is the silent half-populated document'
  Assert-Eq '[set-at-top-level]' "$dot".Trim() '`.` runs it in the caller''s scope, which is the scope $script: resolves to'
}

Register-FFTest -Area 'POLICY' -Doctrine 'rule 2' -Name 'main.js invokes the engine scriptblock with `.`, never `&`' -Body {
  $plan = Get-FFHostArgv -Mode 'scriptblock' -Script 'health.ps1' -EngineArgs @('-Action', 'list')
  $cmd = (@($plan.args) -join ' ')
  Assert-Match ([regex]::Escape('. ([scriptblock]::Create($ffSrc))')) $cmd 'the engine text must be DOT-SOURCED'
  Assert-True (-not [regex]::IsMatch($cmd, [regex]::Escape('& ([scriptblock]::Create($ffSrc))'))) `
    'and must NOT be called with `&`, which would silently null every $script: variable'
  # The rest of the mode's honesty rails, so a future edit cannot quietly drop them.
  Assert-Match 'policy-file-dotsource' $cmd 'an engine that still loads a .ps1 from disk must REFUSE with a named error, not run half-way'
  Assert-Match 'engine-file-unreadable' $cmd 'and an unreadable engine file must be reported as that, not as empty output'
  Assert-Match ([regex]::Escape('$FFLibBlock')) $cmd '_lib.ps1 must be loaded as a scriptblock too - dot-sourcing it from a file is what the policy refuses'
  Assert-Match '-Command' $cmd 'the fallback runs through -Command, which execution policy does not gate'
  Assert-True (-not [regex]::IsMatch($cmd, '(?<!\S)-File(?!\S)')) 'and must not fall back to -File, which it exists to avoid'
}

Register-FFTest -Area 'POLICY' -Name 'main.js file mode is the plain -File invocation' -Body {
  $plan = Get-FFHostArgv -Mode 'file' -Script 'health.ps1' -EngineArgs @('-Action', 'list')
  $a = @($plan.args)
  Assert-Eq '-NoProfile' $a[0] 'no profile is loaded'
  Assert-True ($a -contains '-File') 'file mode passes -File'
  Assert-True ($a -contains 'Bypass') 'with -ExecutionPolicy Bypass, which covers the Process scope'
  Assert-Eq '-Action' $a[$a.Count - 2] 'and the engine arguments come last, unquoted parameter names first'
}

# ---------------- 2. the simulation bites ----------------

Register-FFTest -Area 'POLICY' -Name 'the blocked-policy simulation really refuses script files' -Slow -Body {
  # The negative control for every test below it: if AllSigned did not actually refuse the
  # engine files here, "scriptblock mode works under a blocking policy" would be measuring
  # nothing at all.
  $plan = Get-FFHostArgv -Mode 'file' -Script 'health.ps1' -EngineArgs @('-Action', 'list')
  $res = Invoke-FFHostArgv -Exe $plan.exe -Argv (ConvertTo-FFBlockedPolicyArgv -Argv $plan.args) `
                           -SafetyScript 'health.ps1' -SafetyArgs @('-Action', 'list') -TimeoutMs 90000
  Assert-False $res.timedOut 'the probe must finish'
  Assert-Eq '' "$($res.stdout)".Trim() 'a blocking policy leaves stdout EMPTY - that is the failure the fallback exists for'
  Assert-Match '(?i)not digitally signed|cannot be loaded' "$($res.stderr)" 'and refuses the file by name'
  Assert-Ne 0 $res.exitCode 'exiting non-zero'
}

# ---------------- 3. the real engines, through the real argv, under that policy ----------------

foreach ($row in @(
  @{ Script = 'health.ps1'; Args = @('-Action', 'list');     Slow = $false }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'selftest'); Slow = $false }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'ledger');   Slow = $false }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'list');     Slow = $true }
  @{ Script = 'engine.ps1'; Args = @('-Action', 'list');     Slow = $false }
  @{ Script = 'image.ps1';  Args = @('-Action', 'detect');   Slow = $true }
)) {
  Register-FFTest -Area 'POLICY' -Doctrine 'rule 2' -Data $row -Slow:([bool]$row.Slow) `
    -Name "scriptblock mode returns a COMPLETE document for $($row.Script) $(@($row.Args) -join ' ')" -Body {
    $d = $FFTestData
    $label = "$($d.Script) $(@($d.Args) -join ' ')"

    # The reference: the same call the normal way, which is what the fallback must reproduce.
    $filePlan = Get-FFHostArgv -Mode 'file' -Script $d.Script -EngineArgs @($d.Args)
    $fileRes = Invoke-FFHostArgv -Exe $filePlan.exe -Argv $filePlan.args -SafetyScript $d.Script -SafetyArgs @($d.Args) -TimeoutMs 120000
    $fileDoc = Assert-FFOneJsonDoc -Result $fileRes -Label "$label (-File)" -ExpectExit 0
    Assert-Stop ($null -ne $fileDoc) 'the reference document must parse'

    # The fallback, under a policy that refuses files.
    $sbPlan = Get-FFHostArgv -Mode 'scriptblock' -Script $d.Script -EngineArgs @($d.Args)
    $sbRes = Invoke-FFHostArgv -Exe $sbPlan.exe -Argv (ConvertTo-FFBlockedPolicyArgv -Argv $sbPlan.args) `
                               -SafetyScript $d.Script -SafetyArgs @($d.Args) -TimeoutMs 120000
    Assert-False $sbRes.timedOut "$label must finish in scriptblock mode"
    Assert-Ne '' "$($sbRes.stdout)".Trim() "$label must NEVER return empty output - that is the silently dead app this mode exists to prevent"
    $sbDoc = Assert-FFOneJsonDoc -Result $sbRes -Label "$label (scriptblock, AllSigned)" -ExpectExit 0
    Assert-Stop ($null -ne $sbDoc) 'the scriptblock document must parse'

    # NOT A HALF-POPULATED DOCUMENT. Same keys, and every key the normal invocation filled in
    # with a real scalar must still be filled in. This is the assertion that would have caught
    # the `&` bug: it nulled top-level values while the document still parsed.
    $fileKeys = @($fileDoc.PSObject.Properties | ForEach-Object { $_.Name })
    $sbKeys   = @($sbDoc.PSObject.Properties   | ForEach-Object { $_.Name })
    Assert-Eq ($fileKeys -join ',') ($sbKeys -join ',') "$label must produce the same document SHAPE in both modes"
    foreach ($name in $fileKeys) {
      $fv = $fileDoc.$name
      if ($null -eq $fv) { continue }
      if ($fv -is [string] -and "$fv" -eq '') { continue }
      if ($fv -is [System.Management.Automation.PSCustomObject] -or $fv -is [System.Array]) { continue }
      Assert-NotNull $sbDoc.$name "$label : '$name' is populated when run normally and must not come back null from memory"
      # A wall-clock stamp or a duration is different on every run, by design. Those are held
      # to "still populated" only - the equality check is for the values that must not move.
      if ($name -match '(?i)(^at$|At$|Ms$|^generatedAt$|^duration|^elapsed|Seconds$|Time$)') { continue }
      if ($fv -is [string] -or $fv -is [bool] -or $fv -is [int] -or $fv -is [long]) {
        Assert-Eq "$fv" "$($sbDoc.$name)" "$label : '$name' must read the same in both modes"
      }
    }
    Assert-Eq '' "$($sbRes.stderr)".Trim() "$label must not spill anything to stderr in scriptblock mode"
  }
}

Register-FFTest -Area 'POLICY' -Doctrine 'rule 2' -Name 'scriptblock mode reads repair.ps1''s top-level state variables back correctly' -Body {
  # The concrete shape of the old bug: repair.ps1 resolves its state root at top level and
  # reports it back through $script:. Under `&` these came back empty. `-Action ledger` is the
  # action that prints them, so it is the direct regression check.
  $plan = Get-FFHostArgv -Mode 'scriptblock' -Script 'repair.ps1' -EngineArgs @('-Action', 'ledger')
  $res = Invoke-FFHostArgv -Exe $plan.exe -Argv (ConvertTo-FFBlockedPolicyArgv -Argv $plan.args) `
                           -SafetyScript 'repair.ps1' -SafetyArgs @('-Action', 'ledger') -TimeoutMs 90000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'repair.ps1 ledger (scriptblock, AllSigned)' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the ledger document must parse'
  Assert-Eq $true $doc.ok 'the document is a success document'
  Assert-Match '\S' "$($doc.stateDir)"    'the state directory must come back populated, not empty'
  Assert-Match '\S' "$($doc.ledgerPath)"  'and so must the ledger path'
  Assert-Match '\S' "$($doc.stateDirSource)" 'and where the state root came from'
  Assert-True ("$($doc.stateDir)".StartsWith($res.stateDir, [System.StringComparison]::OrdinalIgnoreCase)) `
    "the resolved state root must be this run's scratch, not the real profile (got '$($doc.stateDir)')"
  Assert-NotNull $doc.entries 'and the entries array must be present rather than silently absent'
}

# ---------------- 4. genuine refusal, never a partial answer ----------------

Register-FFTest -Area 'POLICY' -Doctrine 'rule 2' -Name 'an engine the fallback cannot neutralise is REFUSED with a named error, not run half-way' -Body {
  # The residual guard. If an engine ever grows a file dot-source the rewrite does not
  # recognise, that line would be refused by the very policy this mode exists for - so the
  # host must refuse the whole call and say so, rather than emit a document built from a
  # half-loaded engine. Proven by feeding the guard's own regex a source that trips it.
  $plan = Get-FFHostArgv -Mode 'scriptblock' -Script 'health.ps1' -EngineArgs @('-Action', 'list')
  $cmd = (@($plan.args) -join ' ')
  $m = [regex]::Match($cmd, "IsMatch\(\`$ffSrc, '(.+?)'\)\)")
  Assert-Stop $m.Success 'the residual-dot-source guard must be present in the argv'
  $pattern = $m.Groups[1].Value -replace "''", "'"
  Assert-True ([regex]::IsMatch(". (Join-Path `$PSScriptRoot 'other.ps1')", $pattern)) 'the guard must match an unrewritten file dot-source'
  Assert-True ([regex]::IsMatch(".    `$PSScriptRoot\helper.ps1", $pattern)) 'including a bare one'
  Assert-False ([regex]::IsMatch('. $FFLibBlock', $pattern)) 'and must NOT match the rewritten library load, or every call would refuse'
  Assert-False ([regex]::IsMatch('$x = "a.ps1"', $pattern)) 'nor a mere mention of a .ps1 path'

  # And no engine trips it today - if one did, the app would refuse under policy and the
  # release note has to say so.
  foreach ($e in @('health.ps1', 'repair.ps1', 'image.ps1', 'engine.ps1', 'compat.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:FFEngineDir $e))) { continue }
    $src = Get-FFEngineSource -Engine ([System.IO.Path]::GetFileNameWithoutExtension($e))
    $rewritten = $src -replace "\.\s*\(\s*Join-Path\s+\`$\{?PSScriptRoot\}?\s+'_lib\.ps1'\s*\)", '. $FFLibBlock'
    Assert-False ([regex]::IsMatch($rewritten, $pattern)) "$e must not load a .ps1 from disk that the fallback cannot neutralise"
  }
}
