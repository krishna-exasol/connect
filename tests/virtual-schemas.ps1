#!/usr/bin/env pwsh
# virtual-schemas.ps1 - the Windows bridge to the virtual schema engine, run
# against the REAL engine and the simulated Exasol of tests/virtual-schemas.sh.
# What only this side can get wrong:
#   - a credential piped to Python survives byte for byte, non-ASCII included
#     (Windows PowerShell 5.1 pipes to native programs in ASCII by default)
#   - no empty argument reaches the engine
#   - exit 20 repairs DNS and retries once; exit 21 offers Java and stops when declined
#   - `exakit connect` refuses a credential given as an argument
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/virtual-schemas.ps1
#   pwsh -NoProfile -File tests/virtual-schemas.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function J { param([string[]]$Parts) $p = $repo; foreach ($x in $Parts) { $p = Join-Path $p $x }; return $p }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-vs-ps-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { $python = Get-Command python3 }
$python = $python.Source

# Definitions copied with stand-in artifacts pinned and cached, as in the bash suite.
# The same layout as a kit copy: setup/virtual-schemas beside setup/core,
# which the engine imports.
$setupCopy = Join-Path $work "setup"; New-Item -ItemType Directory -Force -Path $setupCopy | Out-Null
$defs = Join-Path $setupCopy "virtual-schemas"; $home2 = Join-Path $work "kit"; $deploy = Join-Path $work "deploy"
Copy-Item -Recurse (J @("setup", "virtual-schemas")) $defs
Copy-Item -Recurse (J @("setup", "core")) (Join-Path $setupCopy "core")
New-Item -ItemType Directory -Force -Path (Join-Path $deploy "local/runtime/exa/bucketfs/bfsdefault/default"), (Join-Path $deploy "local/runtime/exa/jdbc") | Out-Null
$seed = @'
import hashlib, json, os, sys
defs, home = sys.argv[1:3]
for cid in ("postgresql",):
    path = os.path.join(defs, "connectors", cid, "connector.json")
    doc = json.load(open(path))
    for role in ("adapter", "driver"):
        data = (role + "-" + cid).encode()
        doc[role]["size"], doc[role]["sha256"] = len(data), hashlib.sha256(data).hexdigest()
        folder = os.path.join(home, "cache", "virtual-schemas", doc[role]["sha256"])
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, doc[role]["asset"]), "wb").write(data)
    json.dump(doc, open(path, "w"), indent=2)
'@
$seedFile = Join-Path $work "seed.py"; Set-Content -LiteralPath $seedFile -Value $seed -Encoding ASCII
& $python $seedFile $defs $home2

# --- the kit around the module, replaced --------------------------------------
$script:ExakitHome = $home2
$script:LogFile = Join-Path $work "log.txt"
function Write-ExakitLog { param($L, $M) Add-Content -LiteralPath $script:LogFile -Value "$L $M" }
$script:shown = New-Object System.Collections.ArrayList
function Ok([string]$M) { [void]$script:shown.Add("OK $M") }
function Info([string]$M) { [void]$script:shown.Add("INFO $M") }
function Warn2([string]$M) { [void]$script:shown.Add("WARN $M") }
function Get-ExakitRepoRoot { return $null }
function Get-PyexasolVenvPython { return $python }
function Get-ExakitManifestValue { param([string]$Path)
    switch ($Path) { "runtime.deployment_dir" { return $deploy } "runtime.dsn" { return "127.0.0.1:8563" } "runtime.user" { return "sys" } default { return "" } } }
. (J @("setup", "lib", "core-setup.ps1"))
. (J @("setup", "lib", "virtual-schemas.ps1"))
function Get-ExakitVsDefs { return $defs }

$state = Join-Path $work "db.json"
$env:EXAKIT_VS_FAKE_DB = J @("tests", "lib", "fake-exasol-vs.py")
$env:FAKE_VS_STATE = $state
Set-Content -LiteralPath $state -Value '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}' -Encoding ASCII

Write-Host ""
Write-Host "== the engine through the PowerShell bridge =="
$r = Invoke-ExakitVsEngine -Arguments @("resolve", "mssql")
Check "resolve runs and answers" "RESULT {`"connector`": `"sqlserver`"}" ($r.Lines -join "")
$secret = "pässwörd-€-日本"
$r = Invoke-ExakitVsEngine -Arguments @("connect", "postgresql", "--name", "sales", "--set", "host=pg.example.com", "--set", "database=sales", "--set", "user=reader", "--secret-stdin") -Secret $secret
Check "connect through the bridge: exit 0" 0 $r.Code
$db = Get-Content -Raw -LiteralPath $state -Encoding UTF8 | ConvertFrom-Json
Check "a non-ASCII credential reaches the CONNECTION byte for byte" $secret $db.connections.EXAKIT_SRC_SALES.secret
Check "...and is in none of the output" $false (($r.Lines -join "`n").Contains("pässw"))
$result = Show-ExakitVsLines -Lines (Invoke-ExakitVsEngine -Arguments @("list")).Lines
Check "list comes back parsed" "sales" (@($result.sources)[0].name)

Write-Host ""
Write-Host "== repair and retry =="
$script:codes = New-Object System.Collections.ArrayList
$script:calls = New-Object System.Collections.ArrayList
function Invoke-ExakitVsEngine { param([string[]]$Arguments = @(), [string]$Secret = "")
    [void]$script:calls.Add($Arguments[0]); $c = $script:codes[0]; $script:codes.RemoveAt(0)
    return [pscustomobject]@{ Code = $c; Lines = @() } }
function Repair-PersonalSlcDns { [void]$script:calls.Add("REPAIR"); return $true }
function Install-ExakitVsJava { [void]$script:calls.Add("JAVA"); return $false }
$script:codes.AddRange(@(20, 0)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 20: DNS repaired, retried once, exit 0" "0 connect|REPAIR|connect" ("$code " + ($script:calls -join "|"))
$script:codes.AddRange(@(21)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 21: Java offered; declined, not retried" "21 connect|JAVA" ("$code " + ($script:calls -join "|"))
$script:codes.AddRange(@(1)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "any other failure: no retry" "1 connect" ("$code " + ($script:calls -join "|"))

Write-Host ""
Write-Host "== exakit connect refuses a credential argument =="
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((J @("setup", "exakit.ps1")), [ref]$null, [ref]$null)
foreach ($def in @($cliAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Invoke-CmdConnect" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) throw "DENY $Message" }
function Assert-ExakitInstalled { param([switch]$Json) [void]$script:calls.Add("ASSERT") }
$script:calls.Clear()
$denied = ""
try { Invoke-CmdConnect -Arguments @("pg", "--name", "sales", "--password=hunter2") } catch { $denied = "$_" }
Check "a password argument is refused" $true ($denied -like "DENY A credential is never taken as an argument*")
Check "...before anything ran" "" ($script:calls -join "|")

Remove-Item Env:\EXAKIT_VS_FAKE_DB, Env:\FAKE_VS_STATE
if (-not $env:KEEP_WORK) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue } else { Write-Host "work: $work" }
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
