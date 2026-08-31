<#
  FrameForge VM test harness :: Test-VmHarness.ps1

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\vmtest\Test-VmHarness.ps1

  STATIC, READ-ONLY validation of the whole VM harness. It creates nothing, needs no elevation,
  needs no Hyper-V, and touches no VM - which is the point: the harness cannot be exercised
  without a hypervisor, so everything about it that CAN be checked as code must be, or its
  defects are found only by the person who was relying on it.

  It was written after a round in which:
    * both of New-TestVm.ps1's success documents referenced $planDocDoc - a typo for $planDoc
      that StrictMode-off silently evaluated to $null, emitting plan:null and dropping the entire
      preflight/oscdimg/path block from the only record of what was provisioned. That the typo
      survived at all proves the file had never completed a successful run;
    * matrix.json paired a fault with two repairs whose detection probe could not see it, so
      both rows would have recorded the harness's own declared release blocker on every cell.

  WHAT IT CHECKS
    parse            every .ps1 under tools\vmtest tokenizes and parses with zero errors
    variables        every variable READ in a .ps1 is one that file also defines (the check the
                     $planDocDoc typo needed); scope-insensitive and therefore conservative
    strict-mode      the files that must run under Set-StrictMode actually declare it
    xml              every unattend template is well-formed, carries the local admin account, and
                     carries the LocalAccountTokenFilterPolicy command in the SPECIALIZE pass -
                     i.e. before first logon, which is the fix for the bootstrap circularity
    tokens           every {{TOKEN}} the templates use is one New-TestVm.ps1 substitutes
    matrix           matrix.json parses; every cell's unattend exists; every plan row names a
                     repair that exists in data\repairs.json; every fault it names has a script
    codes            every outcome code Invoke-VmMatrix.ps1 can emit is documented in matrix.json
    preconditions    every plan row that declares requiresProbeDeep is reported with whether the
                     catalog satisfies it - and the runner must implement the skip path, so an
                     unsatisfied precondition can never be scored against the engine

  Emits ONE JSON document on stdout. Exit 0 when ok, 1 when not. PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$RepoRoot,
  [switch]$Pretty
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not $Root)     { $Root = $PSScriptRoot }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $Root) }

$failures = @()
$checks   = @()
function Add-Check {
  param([string]$Name, [bool]$Ok, $Detail = $null, [string[]]$Problems = @())
  $script:checks += [ordered]@{ check = $Name; ok = $Ok; detail = $Detail; problems = @($Problems) }
  foreach ($p in @($Problems)) { $script:failures += "[$Name] $p" }
}

# =====================================================================================
# 1) every .ps1 parses
# =====================================================================================

$psFiles = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -Recurse -File | Sort-Object FullName)
$parsed = @{}
$parseProblems = @()
foreach ($f in $psFiles) {
  $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
  # PSParser first: it is the tokenizer the docs name, and it reports lexical damage the AST
  # parser can mask.
  $tokErrors = $null
  $null = [System.Management.Automation.PSParser]::Tokenize($text, [ref]$tokErrors)
  foreach ($e in @($tokErrors)) { $parseProblems += "$($f.Name):$($e.Token.StartLine) tokenize: $($e.Message)" }
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
  foreach ($e in @($errors)) { $parseProblems += "$($f.Name):$($e.Extent.StartLineNumber) parse: $($e.Message)" }
  $parsed[$f.FullName] = [ordered]@{ file = $f; ast = $ast; text = $text }
}
Add-Check 'ps1-files-parse' ($parseProblems.Count -eq 0) ([ordered]@{ files = $psFiles.Count }) $parseProblems

# =====================================================================================
# 2) every variable that is READ is one the file also defines
# =====================================================================================
# Deliberately conservative: the union of every name assigned ANYWHERE in the file counts as
# defined, so a genuine cross-scope mistake can slip through - but a name that is never assigned
# at all cannot, and that is the $planDocDoc class of bug. False positives are worse than useless
# here, so the automatic-variable list below is generous.

$auto = @(
  '_', 'args', 'error', 'false', 'true', 'null', 'this', 'input', 'psitem', 'matches',
  'pscmdlet', 'psboundparameters', 'psscriptroot', 'pscommandpath', 'myinvocation',
  'host', 'home', 'pwd', 'pid', 'profile', 'psversiontable', 'pshome', 'executioncontext',
  'stacktrace', 'lastexitcode', 'foreach', 'switch', 'ofs', 'shellid', 'consolefilename',
  'erroractionpreference', 'progresspreference', 'warningpreference', 'verbosepreference',
  'debugpreference', 'informationpreference', 'confirmpreference', 'whatifpreference',
  'psdefaultparametervalues', 'psemailserver', 'psculture', 'psuiculture', 'nestedpromptlevel',
  'outputencoding', 'psstyle', 'iswindows', 'islinux', 'ismacos', 'iscoreclr', 'sender', 'event',
  'eventargs', 'eventsubscriber', 'psevent'
)

function Get-BareVariableName {
  <# 'script:RowFiles', 'Global:x' and 'x' must all normalize to the same key, or a variable
     WRITTEN as $script:x and READ as $script:x looks unassigned and the check cries wolf. #>
  param([string]$UserPath)
  $n = "$UserPath".ToLowerInvariant()
  if ($n -match ':') { $n = ($n -split ':')[-1] }
  $n
}

function Get-DefinedVariableNames {
  param($Ast)
  $names = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($n in $auto) { $null = $names.Add($n) }

  # every parameter of the script and of every function
  foreach ($p in @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true))) {
    $null = $names.Add((Get-BareVariableName $p.Name.VariablePath.UserPath))
  }
  # every assignment target (including $script:x = ..., $a += ..., and multi-assignment)
  foreach ($a in @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
    foreach ($v in @($a.Left.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
      $null = $names.Add((Get-BareVariableName $v.VariablePath.UserPath))
    }
  }
  # foreach ($x in ...) loop variables
  foreach ($fe in @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))) {
    $null = $names.Add((Get-BareVariableName $fe.Variable.VariablePath.UserPath))
  }
  # catch [x] { } binds $_ (already automatic); trap binds nothing new
  # data { } and convert-to-variable cmdlets are not used by this harness
  $names
}

$varProblems = @()
foreach ($k in @($parsed.Keys | Sort-Object)) {
  $entry = $parsed[$k]
  if ($null -eq $entry.ast) { continue }
  $defined = Get-DefinedVariableNames -Ast $entry.ast
  $seen = @{}
  foreach ($v in @($entry.ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
    $path = $v.VariablePath
    if ($path.IsDriveQualified) { continue }   # $env:X, $function:X, $variable:X
    $name = Get-BareVariableName $path.UserPath
    if ($name -eq '') { continue }
    if ($defined.Contains($name)) { continue }
    $key = "$($entry.file.Name)|$name"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $varProblems += "$($entry.file.Name):$($v.Extent.StartLineNumber) reads `$$($path.UserPath), which this file never assigns. With StrictMode off that silently evaluates to `$null."
  }
}
Add-Check 'variables-resolve' ($varProblems.Count -eq 0) $null $varProblems

# =====================================================================================
# 3) the files that must run strict, do
# =====================================================================================
# New-TestVm.ps1 writes the ONLY record of what was provisioned, and a null in that record is a
# lie about a machine somebody is about to trust. StrictMode is what makes the next typo an error.

$strictRequired = @('New-TestVm.ps1', 'Test-VmHarness.ps1')
$strictProblems = @()
foreach ($name in $strictRequired) {
  $hit = @($parsed.Keys | Where-Object { (Split-Path -Leaf $_) -eq $name })
  if ($hit.Count -eq 0) { $strictProblems += "$name is missing from the harness"; continue }
  $text = $parsed[$hit[0]].text
  if ($text -notmatch '(?m)^\s*Set-StrictMode\s+-Version\s+2\.0\s*$') {
    $strictProblems += "$name must declare 'Set-StrictMode -Version 2.0' at file scope"
  }
}
Add-Check 'strict-mode-declared' ($strictProblems.Count -eq 0) ([ordered]@{ files = $strictRequired }) $strictProblems

# =====================================================================================
# 4) unattend templates
# =====================================================================================

$unattendDir = Join-Path $Root 'unattend'
$xmlFiles = @(Get-ChildItem -LiteralPath $unattendDir -Filter '*.xml' -File | Sort-Object Name)
$xmlProblems = @()
$xmlRows = @()
foreach ($x in $xmlFiles) {
  $row = [ordered]@{ file = $x.Name; wellFormed = $false; localAdmin = $false; tokenFilterPolicyInSpecialize = $false; tokens = @() }
  $doc = $null
  try {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($x.FullName)
    $row.wellFormed = $true
  } catch {
    $xmlProblems += "$($x.Name) is not well-formed XML: $($_.Exception.Message)"
    $xmlRows += $row
    continue
  }
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

  $acct = $doc.SelectNodes("//u:UserAccounts/u:LocalAccounts/u:LocalAccount[u:Group='Administrators']", $ns)
  $row.localAdmin = ($acct.Count -ge 1)
  if (-not $row.localAdmin) { $xmlProblems += "$($x.Name) defines no local account in the Administrators group; PowerShell Direct has nothing to authenticate as." }

  # THE circularity fix: the policy must be set BEFORE first logon, which means the specialize
  # pass (RunSynchronousCommand runs as LOCAL SYSTEM there). Setting it from the guest script was
  # impossible - that write needs the very token the value grants.
  $cmds = $doc.SelectNodes("//u:settings[@pass='specialize']//u:RunSynchronousCommand/u:Path", $ns)
  foreach ($c in @($cmds)) {
    if ("$($c.InnerText)" -match 'LocalAccountTokenFilterPolicy') { $row.tokenFilterPolicyInSpecialize = $true }
  }
  if (-not $row.tokenFilterPolicyInSpecialize) {
    $xmlProblems += "$($x.Name) does not set LocalAccountTokenFilterPolicy in the specialize pass. Without it the PowerShell Direct token is filtered, Initialize-Guest.ps1 refuses, and no cell built from this template can be judged."
  }
  # The guest script must NOT set it: that was the circular bootstrap.
  $row.tokens = @([regex]::Matches($doc.OuterXml, '\{\{([A-Z_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $xmlRows += $row
}
if ($xmlFiles.Count -eq 0) { $xmlProblems += "no unattend templates found under $unattendDir" }
Add-Check 'unattend-templates' ($xmlProblems.Count -eq 0) ([ordered]@{ templates = $xmlRows }) $xmlProblems

# every token a template uses must be one New-TestVm.ps1 actually substitutes
$tokenProblems = @()
$newTestVmKey = @($parsed.Keys | Where-Object { (Split-Path -Leaf $_) -eq 'New-TestVm.ps1' })
if ($newTestVmKey.Count -eq 1) {
  $ntvText = $parsed[$newTestVmKey[0]].text
  $substituted = @([regex]::Matches($ntvText, "\{\{([A-Z_]+)\}\}") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  foreach ($row in $xmlRows) {
    foreach ($t in @($row.tokens)) {
      if ($substituted -notcontains $t) { $tokenProblems += "$($row.file) uses {{$t}}, which New-TestVm.ps1 never substitutes - the ISO would be built with the placeholder still in it." }
    }
  }
} else {
  $tokenProblems += 'New-TestVm.ps1 could not be located, so template tokens could not be checked.'
}
Add-Check 'unattend-tokens-substituted' ($tokenProblems.Count -eq 0) $null $tokenProblems

# the guest bootstrap must no longer set the policy it needs in order to set it
$initKey = @($parsed.Keys | Where-Object { (Split-Path -Leaf $_) -eq 'Initialize-Guest.ps1' })
$bootProblems = @()
if ($initKey.Count -eq 1) {
  $initText = $parsed[$initKey[0]].text
  if ($initText -match 'Set-ItemProperty[^\r\n]*LocalAccountTokenFilterPolicy') {
    $bootProblems += "Initialize-Guest.ps1 WRITES LocalAccountTokenFilterPolicy. That is the circular bootstrap: the write needs the elevated token the value exists to grant, and so do the steps before it. It belongs in the unattend's specialize pass."
  }
  if ($initText -notmatch 'IsInRole') {
    $bootProblems += 'Initialize-Guest.ps1 does not measure its own token before applying the baseline, so an unelevated run would report several unrelated-looking failures instead of the one real reason.'
  }
} else {
  $bootProblems += 'guest\setup\Initialize-Guest.ps1 could not be located.'
}
Add-Check 'guest-bootstrap-not-circular' ($bootProblems.Count -eq 0) $null $bootProblems

# =====================================================================================
# 5) matrix.json against the engine's own catalog and the harness's own scripts
# =====================================================================================

$matrixPath  = Join-Path $Root 'matrix.json'
$repairsPath = Join-Path $RepoRoot 'data\repairs.json'
$matrix = $null; $repairs = $null
$matrixProblems = @()
try { $matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $matrixProblems += "matrix.json could not be read: $($_.Exception.Message)" }
try { $repairs = (Get-Content -LiteralPath $repairsPath -Raw -Encoding UTF8 | ConvertFrom-Json).repairs } catch { $matrixProblems += "data\repairs.json could not be read: $($_.Exception.Message)" }

$planRows = @()
$preconditionRows = @()
if ($null -ne $matrix -and $null -ne $repairs) {
  $catalogIds = @($repairs | ForEach-Object { "$($_.id)" })
  $planIds = @($matrix.repairPlan | ForEach-Object { "$($_.repair)" })
  $planRows = @($matrix.repairPlan)

  foreach ($id in $planIds) {
    if ($catalogIds -notcontains $id) { $matrixProblems += "repairPlan names '$id', which is not in data\repairs.json." }
  }
  foreach ($id in $catalogIds) {
    if ($planIds -notcontains $id) { $matrixProblems += "data\repairs.json carries '$id' and repairPlan has no row for it - a repair with no plan row is a repair nothing ever tests." }
  }

  $faultIds = @($matrix.faults | ForEach-Object { "$($_.id)" })
  foreach ($p in @($matrix.repairPlan)) {
    $fault = ''
    try { $fault = "$($p.fault)" } catch {}
    if ($fault -match '\S') {
      if ($faultIds -notcontains $fault) { $matrixProblems += "repairPlan row '$($p.repair)' names fault '$fault', which matrix.json's faults[] does not describe." }
      $script = Join-Path $Root "guest\faults\$fault.ps1"
      if (-not (Test-Path -LiteralPath $script)) { $matrixProblems += "fault '$fault' has no script at guest\faults\$fault.ps1." }
    }
  }
  foreach ($c in @($matrix.cells)) {
    $tpl = Join-Path $Root "$($c.unattend)"
    if (-not (Test-Path -LiteralPath $tpl)) { $matrixProblems += "cell '$($c.id)' names unattend template '$($c.unattend)', which does not exist." }
    foreach ($cond in @($c.conditioning)) {
      if (-not ("$cond" -match '\S')) { continue }
      if (-not (Test-Path -LiteralPath (Join-Path $Root "guest\faults\$cond.ps1"))) { $matrixProblems += "cell '$($c.id)' declares conditioning '$cond', which has no script." }
    }
  }

  # ---- THE probe-depth precondition ----
  # A plan row whose fault the SHALLOW detection probe cannot see produces 'false-pass' - the
  # release blocker this harness exists to find - on every cell including the en-US control, for
  # a reason that has nothing to do with the engine. Such a row must declare requiresProbeDeep,
  # and the runner must skip it (never fail it) while the catalog does not satisfy that.
  foreach ($p in @($matrix.repairPlan)) {
    $wants = $false
    try { $wants = [bool]$p.requiresProbeDeep } catch {}
    if (-not $wants) { continue }
    $entry = @($repairs | Where-Object { "$($_.id)" -eq "$($p.repair)" }) | Select-Object -First 1
    $has = $false
    try { if ($null -ne $entry) { $has = [bool]$entry.probeDeep } } catch {}
    $preconditionRows += [ordered]@{
      repair = "$($p.repair)"; fault = "$($p.fault)"; requiresProbeDeep = $true; catalogHasProbeDeep = $has
      effect = $(if ($has) { 'The row runs and is judged.' } else { "The row is recorded as NOT JUDGED (outcome not-judged, code harness-precondition-unmet) - its own visible state in the results matrix, never a skip and never a pass. It draws NO conclusion about the engine: add `"probeDeep`": true to the '$($p.repair)' entry in data\repairs.json to enable it." })
    }
  }
}
Add-Check 'matrix-references-resolve' ($matrixProblems.Count -eq 0) ([ordered]@{ planRows = @($planRows).Count }) $matrixProblems

# ---- outcome codes: every code the runner can emit must be documented ----
$codeProblems = @()
$runnerKey = @($parsed.Keys | Where-Object { (Split-Path -Leaf $_) -eq 'Invoke-VmMatrix.ps1' })
$emitted = @()
if ($runnerKey.Count -eq 1 -and $null -ne $matrix) {
  $runnerText = $parsed[$runnerKey[0]].text
  # Both Finish and New-Row can stamp an outcome, and both are matched: an outcome that only
  # ever reaches the results through New-Row would otherwise be invisible to this check.
  foreach ($m in [regex]::Matches($runnerText, "Finish\s+'([a-z-]+)'\s+'([a-z0-9-]+)'")) {
    $emitted += [ordered]@{ outcome = $m.Groups[1].Value; code = $m.Groups[2].Value }
  }
  foreach ($m in [regex]::Matches($runnerText, "-Outcome\s+'([a-z-]+)'\s+-Code\s+'([a-z0-9-]+)'")) {
    $emitted += [ordered]@{ outcome = $m.Groups[1].Value; code = $m.Groups[2].Value }
  }
  $documentedOutcome = @($matrix.outcomeCodes.PSObject.Properties | ForEach-Object { $_.Name })
  $documentedFail = @($matrix.failCodes.PSObject.Properties | ForEach-Object { $_.Name })
  $documentedSkip = @($matrix.skipCodes.PSObject.Properties | ForEach-Object { $_.Name })
  $documentedNotJudged = @($matrix.notJudgedCodes.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($e in $emitted) {
    if ($documentedOutcome -notcontains $e.outcome) { $codeProblems += "Invoke-VmMatrix.ps1 can emit outcome '$($e.outcome)', which matrix.json outcomeCodes does not document - and an outcome the summary does not know about renders as a blank cell or, worse, as a pass." }
    if ($e.outcome -eq 'fail' -and $documentedFail -notcontains $e.code) { $codeProblems += "Invoke-VmMatrix.ps1 can emit fail code '$($e.code)', which matrix.json failCodes does not document." }
    if ($e.outcome -eq 'skip' -and $documentedSkip -notcontains $e.code) { $codeProblems += "Invoke-VmMatrix.ps1 can emit skip code '$($e.code)', which matrix.json skipCodes does not document." }
    if ($e.outcome -eq 'not-judged' -and $documentedNotJudged -notcontains $e.code) { $codeProblems += "Invoke-VmMatrix.ps1 can emit not-judged code '$($e.code)', which matrix.json notJudgedCodes does not document." }
  }
  # Every non-pass outcome must be rendered in the matrix table by name. The table defaults to
  # PASS, so an outcome with no branch there is silently reported as a passing cell - which is
  # the exact class of failure this harness exists to make impossible.
  foreach ($o in @($documentedOutcome | Where-Object { $_ -ne 'pass' })) {
    if ($runnerText -notmatch [regex]::Escape("'$o'")) { $codeProblems += "matrix.json documents the '$o' outcome and Invoke-VmMatrix.ps1 never mentions it, so a row carrying it would fall through the matrix table's default and be printed as PASS." }
  }
  if ($runnerText -notmatch 'notJudged') { $codeProblems += 'Invoke-VmMatrix.ps1 does not count not-judged rows in its totals, so rows it could not judge would disappear from the run document.' }
  # And the precondition path must actually exist in the runner, or a declared precondition is
  # decoration and the row would still be scored against the engine.
  if (@($preconditionRows).Count -gt 0) {
    if ($runnerText -notmatch 'requiresProbeDeep') { $codeProblems += "matrix.json declares requiresProbeDeep on $(@($preconditionRows).Count) row(s), and Invoke-VmMatrix.ps1 does not implement it - so those rows would still record false-pass over a probe that cannot see the fault." }
    if ($runnerText -notmatch "harness-precondition-unmet") { $codeProblems += 'Invoke-VmMatrix.ps1 does not emit harness-precondition-unmet, so an unmet precondition has nowhere honest to go.' }
  }
} else {
  $codeProblems += 'Invoke-VmMatrix.ps1 or matrix.json could not be read, so the outcome-code vocabulary could not be checked.'
}
Add-Check 'outcome-codes-documented' ($codeProblems.Count -eq 0) ([ordered]@{ emitted = @($emitted).Count }) $codeProblems

# =====================================================================================
# result
# =====================================================================================

$out = [ordered]@{
  ok = ($failures.Count -eq 0)
  action = 'test-vm-harness'
  ranAt = (Get-Date).ToString('s')
  root = $Root
  repoRoot = $RepoRoot
  checks = @($checks)
  failures = @($failures)
  probeDepthPreconditions = @($preconditionRows)
  note = 'Static and read-only: no VM, no ISO, no elevation, nothing created. This is everything about the VM harness that can be verified without a hypervisor - which is why it exists, and why a green run here is a claim about the code and NOT a claim that the matrix has ever run.'
}

$json = ConvertTo-Json -InputObject $out -Depth 12 -Compress:(-not $Pretty)
[Console]::Out.WriteLine($json)
if ($out.ok) { exit 0 } else { exit 1 }
