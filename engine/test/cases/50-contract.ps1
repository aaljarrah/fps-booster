<#
  CONTRACT :: the stdout contract the Electron host depends on

  Every engine action must:
    - emit EXACTLY ONE parseable JSON document on stdout
    - emit it BOM-free
    - write NOTHING to stderr on success
    - exit 0 on success, and non-zero WITH a JSON error document on invalid input

  These are the only tests in the suite that run the engines for real. They use only
  read-only actions (list / probe / selftest / ledger / preflight / detect / consent /
  validate / -DryRun); Invoke-FFEngineProcess refuses anything else outright.
#>

$FFEngineDirForCases = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$FFEngines = Split-Path -Parent $FFEngineDirForCases

function Get-FFEnginePath { param([string]$Leaf) Join-Path $FFEngines $Leaf }

# ---------------- successful actions ----------------

foreach ($row in @(
  @{ Script = 'health.ps1';  Args = @('-Action', 'list');                              Keys = @('ok', 'categories', 'supportedOs', 'languageMode'); Slow = $false }
  @{ Script = 'health.ps1';  Args = @('-Action', 'probe', '-Category', 'disk-space');  Keys = @('category', 'status', 'summary', 'findings', 'durationMs', 'supportedOs'); Slow = $false }
  @{ Script = 'health.ps1';  Args = @('-Action', 'probe', '-Category', 'boot');        Keys = @('category', 'status', 'summary', 'findings'); Slow = $true }
  @{ Script = 'health.ps1';  Args = @('-Action', 'scan');                              Keys = @('ok', 'isAdmin', 'scannedAt', 'categories', 'totals', 'os', 'edition'); Slow = $true }
  @{ Script = 'repair.ps1';  Args = @('-Action', 'selftest');                          Keys = @('ok', 'action'); Slow = $false }
  @{ Script = 'repair.ps1';  Args = @('-Action', 'ledger');                            Keys = @('ok', 'count', 'ledgerPath', 'entries'); Slow = $false }
  @{ Script = 'image.ps1';   Args = @('-Action', 'detect');                            Keys = @('ok', 'action'); Slow = $true }
  @{ Script = 'image.ps1';   Args = @('-Action', 'consent');                           Keys = @('ok', 'action', 'contract', 'rails', 'railCheck'); Slow = $true }
  @{ Script = 'sysinfo.ps1'; Args = @();                                               Keys = @('generatedAt', 'os'); Slow = $true }
  @{ Script = 'procs.ps1';   Args = @('-Action', 'windowed');                          Keys = @(); Slow = $false }
  @{ Script = 'measure.ps1'; Args = @('-Action', 'metrics', '-Frametimes', '16.6,16.7,16.5,20.1'); Keys = @('ok', 'frames', 'avgFps'); Slow = $false }
  @{ Script = 'nvidia.ps1';  Args = @('-Action', 'detect');                            Keys = @('nvidia'); Slow = $false }
  @{ Script = 'engine.ps1';  Args = @('-Action', 'list');                              Keys = @(); Slow = $false }
  @{ Script = 'engine.ps1';  Args = @('-Action', 'detect-all');                        Keys = @(); Slow = $true }
  # compat.ps1 is registered only when it exists, so the suite neither breaks on a tree that
  # predates it nor silently stops covering it once it lands.
) + @(if (Test-Path -LiteralPath (Join-Path $FFEngines 'compat.ps1')) { @(
  @{ Script = 'compat.ps1';  Args = @('-Action', 'list');                               Keys = @('ok', 'action', 'probes'); Slow = $false }
  @{ Script = 'compat.ps1';  Args = @('-Action', 'selftest');                            Keys = @('ok', 'action', 'checks'); Slow = $false }
) })) {
  $slow = [bool]$row.Slow
  Register-FFTest -Area 'CONTRACT' -Doctrine 'one-document contract' -Data $row -Slow:$slow `
    -Name "$($row.Script) $(@($row.Args) -join ' ') emits one JSON doc, exit 0, clean stderr" -Body {
    $d = $FFTestData
    $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath $d.Script) -EngineArgs @($d.Args) -TimeoutMs 120000
    $doc = Assert-FFOneJsonDoc -Result $res -Label "$($d.Script) $(@($d.Args) -join ' ')" -ExpectExit 0
    if ($null -ne $doc) {
      foreach ($k in @($d.Keys)) {
        Assert-True ($null -ne $doc.PSObject.Properties[$k]) "the document must carry the documented key '$k'"
      }
    }
  }
}

Register-FFTest -Area 'CONTRACT' -Name 'health.ps1 scan: every category resolves to a value from the declared status vocabulary' -Slow -Body {
  $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath 'health.ps1') -EngineArgs @('-Action', 'scan') -TimeoutMs 120000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'health.ps1 scan' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the scan document must parse'
  $vocab = @('ok', 'needs-admin', 'unknown', 'warning', 'critical')
  Assert-Eq 12 @($doc.categories).Count 'all twelve categories must be reported'
  foreach ($c in @($doc.categories)) {
    Assert-In "$($c.status)" $vocab "category '$($c.category)' must use the declared status vocabulary"
    Assert-Match '\S' "$($c.summary)" "category '$($c.category)' must carry a summary sentence"
    foreach ($f in @($c.findings)) {
      Assert-In "$($f.severity)" @('info', 'unknown', 'warning', 'critical') "finding '$($f.id)' must use the declared severity vocabulary"
      Assert-Match '\S' "$($f.id)" 'every finding must have an id'
    }
  }
  $sum = @($doc.totals.ok) + @($doc.totals.warning) + @($doc.totals.critical) + @($doc.totals.needsAdmin) + @($doc.totals.unknown)
  Assert-Eq 12 (($sum | Measure-Object -Sum).Sum) 'the totals must account for every category exactly once'
  Assert-NotNull $doc.languageMode 'the document must record the PowerShell language mode it was measured under'
  Assert-NotNull $doc.policies 'and the policy snapshot it was read against'
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 2' -Name 'health.ps1 scan: no category claims "ok" while carrying an unknown finding' -Slow -Body {
  # 'unknown' ranks above 'ok' precisely so a failed measurement can never render as a green tick.
  $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath 'health.ps1') -EngineArgs @('-Action', 'scan') -TimeoutMs 120000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'health.ps1 scan' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the scan document must parse'
  foreach ($c in @($doc.categories)) {
    $unknowns = @(@($c.findings) | Where-Object { $_.severity -eq 'unknown' })
    if ($unknowns.Count -gt 0) {
      Assert-Ne 'ok' "$($c.status)" "category '$($c.category)' carries $($unknowns.Count) unknown finding(s) and must not be graded ok"
      Assert-Match 'NOT a clean bill of health' "$($c.summary)" "category '$($c.category)' must say out loud what it could not read"
    }
    $bad = @(@($c.findings) | Where-Object { $_.severity -eq 'warning' -or $_.severity -eq 'critical' })
    if ($bad.Count -gt 0) {
      Assert-Ne 'ok' "$($c.status)" "category '$($c.category)' has faults and must not be graded ok"
    }
  }
}

# ---------------- invalid input ----------------

foreach ($row in @(
  @{ Script = 'repair.ps1'; Args = @('-Action', 'no-such-action');                   Exit = 2; Match = 'Unknown action'; Offers = $true }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'preflight');                        Exit = 2; Match = 'requires -Id'; Offers = $true }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'preflight', '-Id', 'no-such-id');   Exit = 2; Match = 'Unknown repair id'; Offers = $true }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'list', '-DnsProvider', 'nope');     Exit = 2; Match = 'Unknown -DnsProvider'; Offers = $true }
  @{ Script = 'repair.ps1'; Args = @('-Action', 'preflight', '-Id', 'network-flush', '-SourcePath', 'C:\nope\install.wim'); Exit = 2; Match = 'takes no source'; Offers = $false }
  @{ Script = 'image.ps1';  Args = @('-Action', 'no-such-action');                   Exit = 2; Match = 'Unknown action'; Offers = $true }
  @{ Script = 'image.ps1';  Args = @('-Action', 'detect', '-Index', 'abc');          Exit = 2; Match = 'non-negative whole number'; Offers = $false }
  @{ Script = 'image.ps1';  Args = @('-Action', 'validate');                         Exit = 2; Match = 'No media given'; Offers = $false }
  @{ Script = 'image.ps1';  Args = @('-Action', 'validate', '-IsoPath', 'C:\nope\nope.iso'); Exit = 2; Match = 'not found'; Offers = $false }
  @{ Script = 'health.ps1'; Args = @('-Action', 'probe', '-Category', 'no-such-category'); Exit = 2; Match = 'Unknown or missing category'; Offers = $true }
  @{ Script = 'health.ps1'; Args = @('-Action', 'probe');                            Exit = 2; Match = 'Unknown or missing category'; Offers = $true }
) + @(if (Test-Path -LiteralPath (Join-Path $FFEngines 'compat.ps1')) { @(
  @{ Script = 'compat.ps1'; Args = @('-Action', 'no-such-action');                   Exit = 2; Match = 'Unknown action'; Offers = $true }
) })) {
  Register-FFTest -Area 'CONTRACT' -Doctrine 'one-document contract' -Data $row `
    -Name "$($row.Script) $(@($row.Args) -join ' ') fails with a JSON error doc, not a bare error" -Body {
    $d = $FFTestData
    $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath $d.Script) -EngineArgs @($d.Args) -TimeoutMs 60000
    $label = "$($d.Script) $(@($d.Args) -join ' ')"
    $doc = Assert-FFOneJsonDoc -Result $res -Label $label -ExpectExit $d.Exit
    Assert-Stop ($null -ne $doc) "$label must still emit a JSON document"
    Assert-Eq $false $doc.ok 'the error document must carry ok:false'
    $text = "$($doc.error)$($doc.errorCode)"
    Assert-Match $d.Match $text 'the error must name what was wrong'
    if ($d.Offers) {
      # Errors that reject a value from a KNOWN SET must hand back that set, so the caller
      # (and the UI) can recover without guessing. Errors about a path or a free-form value
      # have no set to offer and are exempt.
      $hints = @($doc.validActions) + @($doc.validIds) + @($doc.validProviders) + @($doc.validCategories)
      Assert-True (@($hints | Where-Object { $_ }).Count -gt 0) 'and must offer the valid values so the caller can recover'
    } else {
      Assert-Match '\S' "$($doc.error)" 'and must carry a human-readable explanation'
    }
  }
}

foreach ($row in @(
  @{ Script = 'health.ps1';  Args = @('-Action', 'no-such-action') }
  @{ Script = 'engine.ps1';  Args = @('-Action', 'no-such-action') }
  @{ Script = 'measure.ps1'; Args = @('-Action', 'no-such-action') }
  @{ Script = 'procs.ps1';   Args = @('-Action', 'no-such-action') }
  @{ Script = 'nvidia.ps1';  Args = @('-Action', 'no-such-action') }
)) {
  # WAS -Xfail, NOW A REAL EXPECTATION. The defect these reproduce: -Action was declared with
  # [ValidateSet], so an unknown action fails PARAMETER BINDING before the script body runs -
  # PowerShell writes a multi-line error to stderr, stdout stays empty, and the process exits 1.
  # The Electron host parses exactly one JSON document per run and gets nothing at all.
  # repair.ps1, image.ps1 and compat.ps1 already avoid this deliberately, and their headers say
  # so in as many words. The fix is to drop [ValidateSet] and validate against a $ValidActions
  # list in the body, emitting {ok:false, error, validActions} with a non-zero exit.
  Register-FFTest -Area 'CONTRACT' -Doctrine 'one-document contract' -Data $row `
    -Name "$($row.Script) with an unknown -Action still emits a JSON error doc" -Body {
    $d = $FFTestData
    $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath $d.Script) -EngineArgs @($d.Args) -TimeoutMs 60000
    $parsed = ConvertFrom-FFEngineStdout -Stdout $res.stdout
    Assert-True $parsed.ok "$($d.Script) must emit a JSON document on stdout even for a bad action$(if ($parsed.error) { " - $($parsed.error)" })"
    Assert-Eq '' ("$($res.stderr)".Trim()) 'and must not spill a raw PowerShell binding error onto stderr'
    Assert-Ne 0 $res.exitCode 'while still exiting non-zero'
    if ($parsed.ok) { Assert-Eq $false $parsed.doc.ok 'the document must carry ok:false' }
  }
}

# ---------------- catalog integrity ----------------

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 5' -Name 'repair.ps1 selftest: the catalog documents exactly what will run' -Body {
  # This is the engine's own catalog-integrity check: every health-checks.json fixesAvailable
  # id resolves, and every whatItRuns line matches the real step commands character for
  # character after the documented normalization.
  $res = Invoke-FFEngineProcess -Script (Get-FFEnginePath 'repair.ps1') -EngineArgs @('-Action', 'selftest') -TimeoutMs 90000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'repair.ps1 selftest' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the selftest document must parse'
  Assert-Eq $true $doc.ok 'the catalog self-test must pass - a failure here means data/repairs.json no longer describes what the engine does'
  Assert-True ($doc.repairCount -gt 20) "the catalog must still hold the full repair ladder (got $($doc.repairCount))"
}

Register-FFTest -Area 'CONTRACT' -Doctrine 'rule 5' -Name 'catalogs: data/*.json parse and carry the ids the engines resolve' -Body {
  $r = Invoke-InEngineScope -Engine 'repair' -Test {
    $TestCtx.repairs = @(Load-Catalog)
    $TestCtx.health = (Get-Content -Raw -Encoding UTF8 -Path $HealthCatalog | ConvertFrom-Json)
  }
  Assert-True (@($r.repairs).Count -gt 20 ) 'data/repairs.json parses and holds the ladder'
  $ids = @(@($r.repairs) | ForEach-Object { "$($_.id)" })
  $dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
  Assert-Eq 0 @($dupes).Count "repair ids must be unique (duplicates: $(@($dupes | ForEach-Object { $_.Name }) -join ', '))"
  foreach ($rep in @($r.repairs)) {
    Assert-Match '\S' "$($rep.name)" "repair '$($rep.id)' must have a name"
    Assert-Match '\S' "$($rep.summary)" "repair '$($rep.id)' must have a summary"
    Assert-In "$($rep.tier)" @('standard', 'aggressive', 'guided') "repair '$($rep.id)' must declare a known tier"
  }
  Assert-NotNull $r.health 'data/health-checks.json parses'
}
