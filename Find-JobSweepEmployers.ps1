<#
.SYNOPSIS
    Builds a list of employers in your commute zone from public datasets, for the
    source scout to work through.

.DESCRIPTION
    JobSweep only reads employers somebody has already named. This script names
    them. It reads public, employer-level data, keeps the employers above a size
    threshold whose address is in your commute zone, marks the ones already in
    your profile, and writes one CSV:

        <OutputRoot>\Sweeps\employers-<yyyy-MM-dd>.csv

    Datasets (each a small reader; one that fails is reported and skipped):

      IRS   Exempt Organizations Business Master File, the state extract
            (irs.gov/pub/irs-soi/eo_<state>.csv). Size: revenue.
      NCUA  Credit union quarterly call report data, the newest quarter
            (FOICU for name and address, FS220 for total assets). Size: assets.
      FDIC  BankFind API, active institutions headquartered in the state.
            Size: assets.
      Local Your own CSV files (Discovery.ExtraCsv), for employers no dataset
            covers. Columns: company, website, industry, city, zip, and
            optionally size_measure, size_value, notes.

    The zone, the state and the size thresholds live in the Discovery block of
    your local profile, never in this script. Every request is checked against
    the site's robots.txt first; a disallowed path is reported as
    "blocked by robots" and not fetched. Requests are spaced by -ThrottleMs and
    carry a descriptive User-Agent.

    It never writes to a profile. Hand the CSV to the source scout or to Claude.

.PARAMETER ProfilePath
    Profiles merged for the Discovery block and the already-in-profile check.
    Defaults to JobSweep.targeting.psd1 plus JobSweep.local.psd1 beside the sweep
    script, or the shipped example when there is no local profile.

.PARAMETER Dataset
    Run only these datasets: IRS, NCUA, FDIC, Local. Defaults to
    Discovery.Datasets in the profile, else all four.

.PARAMETER OutputRoot
    Folder to write Sweeps\ into. Overrides OutputRoot in the profile.

.PARAMETER OutFile
    Write the CSV here instead of <OutputRoot>\Sweeps\employers-<date>.csv.

.PARAMETER IncludeOutOfZone
    Also write rows outside the zone (in_zone False), for checking the zone.

.PARAMETER ThrottleMs
    Pause before each request, in milliseconds. Default 1000.

.PARAMETER SweepScript
    The collector to read defaults and the profile merge from. Defaults to
    Invoke-JobSweep.ps1 beside this script.

.EXAMPLE
    .\Find-JobSweepEmployers.ps1

.EXAMPLE
    .\Find-JobSweepEmployers.ps1 -Dataset IRS -IncludeOutOfZone -OutFile .\check-zone.csv
#>
[CmdletBinding()]
param(
    [string[]] $ProfilePath,
    [ValidateSet('IRS', 'NCUA', 'FDIC', 'Local')]
    [string[]] $Dataset,
    [string]   $OutputRoot,
    [string]   $OutFile,
    [switch]   $IncludeOutOfZone,
    [int]      $ThrottleMs = 1000,
    [string]   $SweepScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
#  PURE HELPERS (the filter suite extracts these by name)
# ============================================================================

function Get-DiscoverySetting {
    <# The Discovery block with defaults filled in. Thresholds are in dollars. #>
    param($Config)
    $d = @{}
    if ($Config -and $Config.ContainsKey('Discovery') -and $Config.Discovery) { $d = $Config.Discovery }
    $get = { param($k, $def) if ($d.ContainsKey($k) -and $null -ne $d[$k]) { $d[$k] } else { $def } }
    return @{
        State                = ([string](& $get 'State' '')).Trim().ToUpper()
        ZoneZipPrefixes      = @(& $get 'ZoneZipPrefixes' @())
        ZoneZips             = @(& $get 'ZoneZips' @())
        ZoneCities           = @(& $get 'ZoneCities' @())
        ZoneExcludeZips      = @(& $get 'ZoneExcludeZips' @())
        ZoneExcludeCities    = @(& $get 'ZoneExcludeCities' @())
        MinNonprofitRevenue  = [long](& $get 'MinNonprofitRevenue' 10000000)
        MinCreditUnionAssets = [long](& $get 'MinCreditUnionAssets' 100000000)
        MinBankAssets        = [long](& $get 'MinBankAssets' 500000000)
        NteeExclude          = @(& $get 'NteeExclude' @())
        IrsSubsections       = @(& $get 'IrsSubsections' @())
        Datasets             = @(& $get 'Datasets' @('IRS', 'NCUA', 'FDIC', 'Local'))
        ExtraCsv             = @(& $get 'ExtraCsv' @())
    }
}

function ConvertTo-ZipFive {
    param([string]$Zip)
    $m = [regex]::Match([string]$Zip, '\d{5}')
    if ($m.Success) { return $m.Value }
    return ''
}

function ConvertTo-NameCase {
    <# "EXAMPLE HEALTH SERVICES INC" -> "Example Health Services Inc". Names that
       already mix case are left alone. #>
    param([string]$Name)
    $n = ([string]$Name).Trim() -replace '\s+', ' '
    if ($n -cmatch '[a-z]') { return $n }
    return (Get-Culture).TextInfo.ToTitleCase($n.ToLower())
}

function Test-EmployerInZone {
    <# Exclusions win. Then an exact ZIP, a ZIP prefix, or a city puts the row in.
       With no zone configured at all, every row is in (the caller warns). #>
    param([string]$Zip, [string]$City, [hashtable]$Setting)
    $z = ConvertTo-ZipFive $Zip
    $c = ([string]$City).Trim().ToLower()
    if ($z -and @($Setting.ZoneExcludeZips | ForEach-Object { [string]$_ }) -contains $z) { return $false }
    if ($c -and @($Setting.ZoneExcludeCities | ForEach-Object { ([string]$_).ToLower() }) -contains $c) { return $false }
    $any = (@($Setting.ZoneZipPrefixes).Count + @($Setting.ZoneZips).Count + @($Setting.ZoneCities).Count) -gt 0
    if (-not $any) { return $true }
    if ($z -and @($Setting.ZoneZips | ForEach-Object { [string]$_ }) -contains $z) { return $true }
    if ($z) { foreach ($p in @($Setting.ZoneZipPrefixes)) { if ($p -and $z.StartsWith([string]$p)) { return $true } } }
    if ($c -and @($Setting.ZoneCities | ForEach-Object { ([string]$_).ToLower() }) -contains $c) { return $true }
    return $false
}

function Get-EmployerNameKey {
    <# A loose key for "is this employer already in the profile". #>
    param([string]$Name)
    $k = ([string]$Name).ToLower() -replace '&', ' and ' -replace ("[`'" + [char]0x2019 + ']'), '' -replace '[^a-z0-9]+', ' '
    $k = " $k " -replace ' the ', ' '
    $k = $k -replace ' (inc|incorporated|llc|corp|corporation|co|company|ltd|pllc|pc|na)(?= )', ' '
    return ($k -replace '\s+', ' ').Trim()
}

function Test-EmployerInProfile {
    <# Equal keys, or one name is the other plus more words ("Example Health" vs
       "Example Health Services"). Returns the profile name that matched, or ''. #>
    param([string]$Name, [hashtable]$ProfileKeys)
    $k = Get-EmployerNameKey $Name
    if (-not $k) { return '' }
    if ($ProfileKeys.ContainsKey($k)) { return $ProfileKeys[$k] }
    foreach ($pk in $ProfileKeys.Keys) {
        if (-not $pk) { continue }
        if ($k.StartsWith("$pk ") -or $pk.StartsWith("$k ")) { return $ProfileKeys[$pk] }
    }
    return ''
}

function Get-NteeIndustry {
    <# The NTEE major group (first letter) as a plain industry name. #>
    param([string]$Code)
    $c = ([string]$Code).Trim().ToUpper()
    if (-not $c) { return 'nonprofit (unclassified)' }
    $map = @{
        A = 'arts and culture'; B = 'education'; C = 'environment'; D = 'animal welfare'
        E = 'health care'; F = 'mental health'; G = 'health (disease and disorders)'; H = 'medical research'
        I = 'crime and legal'; J = 'employment'; K = 'food and agriculture'; L = 'housing'
        M = 'public safety'; N = 'recreation and sports'; O = 'youth development'; P = 'human services'
        Q = 'international'; R = 'civil rights'; S = 'community improvement'; T = 'philanthropy'
        U = 'science and technology'; V = 'social science'; W = 'public and societal benefit'; X = 'religion'
        Y = 'mutual and membership benefit'; Z = 'unknown'
    }
    $k = $c.Substring(0, 1)
    if ($map.ContainsKey($k)) { return $map[$k] }
    return 'nonprofit (unclassified)'
}

function Assert-DatasetColumn {
    <# Format drift: a dataset whose columns changed fails loudly, naming them. #>
    param([string]$Dataset, [string[]]$Have, [string[]]$Need)
    $miss = @($Need | Where-Object { $Have -notcontains $_ })
    if ($miss.Count) { throw "$Dataset : missing column(s) $($miss -join ', ')" }
}

function New-EmployerRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a row object in memory; it changes no system state.')]
    param([string]$Company, [string]$Website, [string]$Industry, [string]$Dataset, [string]$SourceId,
          [string]$City, [string]$Zip, [string]$SizeMeasure, $SizeValue, [string]$Notes)
    [pscustomobject][ordered]@{
        company = $Company; website = $Website; industry = $Industry
        source_dataset = $Dataset; source_id = $SourceId
        city = $City; zip = (ConvertTo-ZipFive $Zip)
        size_measure = $SizeMeasure; size_value = $SizeValue
        in_zone = $false; already_in_profile = ''; notes = $Notes
    }
}

function ConvertFrom-IrsEoCsv {
    <# The IRS EO BMF state extract. Size is REVENUE_AMT. IrsSubsections keeps
       only those 501(c) subsections ('03' charities); benefit trusts and union
       funds report large revenue but employ few people. #>
    param([string]$Text, [hashtable]$Setting)
    $rows = @($Text | ConvertFrom-Csv)
    if ($rows.Count -eq 0) { return @() }
    $need = @('EIN', 'NAME', 'CITY', 'ZIP', 'REVENUE_AMT', 'NTEE_CD')
    $subs = @($Setting.IrsSubsections | ForEach-Object { ([string]$_).Trim().PadLeft(2, '0') })
    if ($subs.Count) { $need += 'SUBSECTION' }
    Assert-DatasetColumn 'IRS EO BMF' @($rows[0].PSObject.Properties.Name) $need
    $out = foreach ($r in $rows) {
        if ($subs.Count -and $subs -notcontains ([string]$r.SUBSECTION).Trim().PadLeft(2, '0')) { continue }
        $rev = 0L
        if ([string]$r.REVENUE_AMT -match '^\d+$') { $rev = [long]$r.REVENUE_AMT }
        if ($rev -lt $Setting.MinNonprofitRevenue) { continue }
        $ntee = ([string]$r.NTEE_CD).Trim().ToUpper()
        $drop = $false
        foreach ($x in @($Setting.NteeExclude)) { if ($x -and $ntee.StartsWith(([string]$x).ToUpper())) { $drop = $true; break } }
        if ($drop) { continue }
        New-EmployerRow -Company (ConvertTo-NameCase $r.NAME) -Website '' -Industry (Get-NteeIndustry $ntee) `
            -Dataset 'IRS EO BMF' -SourceId ([string]$r.EIN) -City (ConvertTo-NameCase $r.CITY) -Zip $r.ZIP `
            -SizeMeasure 'revenue' -SizeValue $rev -Notes $(if ($ntee) { "NTEE $ntee" } else { '' })
    }
    return @($out)
}

function ConvertFrom-NcuaCallReport {
    <# FOICU (name, address) joined to FS220 (ACCT_010, total assets) on
       CU_NUMBER, for one state. FOICU drops "Credit Union" from the name, so it
       is put back: the employer is known by it, and the IRS file uses it. #>
    param([string]$FoicuText, [string]$Fs220Text, [hashtable]$Setting)
    $fo = @($FoicuText | ConvertFrom-Csv)
    $fs = @($Fs220Text | ConvertFrom-Csv)
    if ($fo.Count -eq 0) { return @() }
    Assert-DatasetColumn 'NCUA FOICU' @($fo[0].PSObject.Properties.Name) @('CU_NUMBER', 'CU_NAME', 'CITY', 'STATE', 'ZIP_CODE')
    if ($fs.Count) { Assert-DatasetColumn 'NCUA FS220' @($fs[0].PSObject.Properties.Name) @('CU_NUMBER', 'ACCT_010') }
    $assets = @{}
    foreach ($f in $fs) { if ([string]$f.ACCT_010 -match '^-?\d+$') { $assets[[string]$f.CU_NUMBER] = [long]$f.ACCT_010 } }
    $out = foreach ($r in $fo) {
        if (([string]$r.STATE).Trim().ToUpper() -ne $Setting.State) { continue }
        $id = [string]$r.CU_NUMBER
        $a = if ($assets.ContainsKey($id)) { $assets[$id] } else { 0L }
        if ($a -lt $Setting.MinCreditUnionAssets) { continue }
        $cuName = ConvertTo-NameCase $r.CU_NAME
        if ($cuName -notmatch '(?i)\bcredit union\b|\bcu\b') { $cuName = "$cuName Credit Union" }
        New-EmployerRow -Company $cuName -Website '' -Industry 'credit union' `
            -Dataset 'NCUA' -SourceId $id -City (ConvertTo-NameCase $r.CITY) -Zip $r.ZIP_CODE `
            -SizeMeasure 'assets' -SizeValue $a -Notes ''
    }
    return @($out)
}

function Get-NcuaNewestZip {
    <# The newest call-report-data-YYYY-MM.zip link on the quarterly data page. #>
    param([string]$Html)
    $best = ''; $bestKey = ''
    foreach ($m in [regex]::Matches([string]$Html, '(?i)["''](?<u>[^"''<>\s]*call-report-data-(?<y>\d{4})-(?<q>\d{2})\.zip)["'']')) {
        $key = $m.Groups['y'].Value + $m.Groups['q'].Value
        if ($key -gt $bestKey) { $bestKey = $key; $best = $m.Groups['u'].Value }
    }
    if ($best -and $best -notmatch '^https?://') { $best = 'https://ncua.gov' + $(if ($best.StartsWith('/')) { '' } else { '/' }) + $best }
    return $best
}

function ConvertFrom-FdicInstitution {
    <# BankFind institutions JSON. ASSET is reported in thousands of dollars. #>
    param([string]$Json, [hashtable]$Setting)
    $j = $Json | ConvertFrom-Json
    $out = foreach ($i in @($j.data)) {
        $d = $i.data
        $names = @($d.PSObject.Properties.Name)
        Assert-DatasetColumn 'FDIC BankFind' $names @('NAME', 'CITY', 'ZIP', 'ASSET')
        $a = 0L
        if ([string]$d.ASSET -match '^\d+$') { $a = [long]$d.ASSET * 1000 }
        if ($a -lt $Setting.MinBankAssets) { continue }
        $web = if ($names -contains 'WEBADDR') { ([string]$d.WEBADDR).Trim() } else { '' }
        if ($web -and $web -notmatch '^https?://') { $web = "https://$web" }
        $id = if ($names -contains 'ID') { [string]$d.ID } elseif ($names -contains 'CERT') { [string]$d.CERT } else { '' }
        New-EmployerRow -Company (ConvertTo-NameCase $d.NAME) -Website $web -Industry 'bank' -Dataset 'FDIC' `
            -SourceId $id -City (ConvertTo-NameCase $d.CITY) -Zip ([string]$d.ZIP) -SizeMeasure 'assets' -SizeValue $a -Notes ''
    }
    return @($out)
}

function ConvertFrom-LocalEmployerCsv {
    <# Your own list. company is required; the rest are optional. #>
    param([string]$Text, [string]$Name)
    $rows = @($Text | ConvertFrom-Csv)
    if ($rows.Count -eq 0) { return @() }
    $have = @($rows[0].PSObject.Properties.Name)
    Assert-DatasetColumn "local CSV $Name" $have @('company')
    $v = { param($r, $k) if ($have -contains $k) { ([string]$r.$k).Trim() } else { '' } }
    $out = foreach ($r in $rows) {
        $c = & $v $r 'company'
        if (-not $c) { continue }
        $sv = & $v $r 'size_value'
        New-EmployerRow -Company $c -Website (& $v $r 'website') -Industry (& $v $r 'industry') -Dataset "local: $Name" `
            -SourceId '' -City (& $v $r 'city') -Zip (& $v $r 'zip') -SizeMeasure (& $v $r 'size_measure') `
            -SizeValue $(if ($sv -match '^\d+$') { [long]$sv } else { $sv }) -Notes (& $v $r 'notes')
    }
    return @($out)
}

function Merge-EmployerRow {
    <# One row per employer: the same name key from two datasets keeps the larger
       row, and its notes say where else it appeared. #>
    param([object[]]$Rows)
    $byKey = [ordered]@{}
    foreach ($r in @($Rows)) {
        $k = Get-EmployerNameKey $r.company
        if (-not $k) { continue }
        if (-not $byKey.Contains($k)) { $byKey[$k] = $r; continue }
        $keep = $byKey[$k]
        $other = $r
        if (($r.size_value -as [long]) -gt ($keep.size_value -as [long])) { $keep = $r; $other = $byKey[$k] }
        if (-not $keep.website -and $other.website) { $keep.website = $other.website }
        $also = "also in $($other.source_dataset) $($other.source_id)".Trim()
        $keep.notes = (@($keep.notes, $also) | Where-Object { $_ }) -join '; '
        $byKey[$k] = $keep
    }
    return @($byKey.Values)
}

function Test-RobotsAllowed {
    <# robots.txt for the "*" group: the longest matching Allow or Disallow wins,
       Allow on a tie. * and a closing $ work as in the robots standard. Line
       endings may be LF, CRLF or bare CR (some sites still use CR). An empty
       Disallow allows everything. #>
    param([string]$RobotsText, [string]$Path)
    $lines = ([string]$RobotsText) -split "`r`n|`r|`n"
    $rules = @(); $inStar = $false; $lastWasAgent = $false
    foreach ($line in $lines) {
        $l = ($line -replace '#.*$', '').Trim()
        if (-not $l) { continue }
        if ($l -match '^(?i)user-agent\s*:\s*(.*)$') {
            $isStar = ($Matches[1].Trim() -eq '*')
            if ($lastWasAgent) { $inStar = $inStar -or $isStar } else { $inStar = $isStar }
            $lastWasAgent = $true
            continue
        }
        $lastWasAgent = $false
        if (-not $inStar) { continue }
        if ($l -match '^(?i)(allow|disallow)\s*:\s*(.*)$') {
            $rules += [pscustomobject]@{ Allow = ($Matches[1].ToLower() -eq 'allow'); Pattern = $Matches[2].Trim() }
        }
    }
    $best = $null
    foreach ($r in $rules) {
        if (-not $r.Pattern) { continue }
        $rx = '^' + ([regex]::Escape($r.Pattern) -replace '\\\*', '.*' -replace '\\\$$', '$')
        if ($Path -notmatch $rx) { continue }
        if ($null -eq $best -or $r.Pattern.Length -gt $best.Pattern.Length -or
            ($r.Pattern.Length -eq $best.Pattern.Length -and $r.Allow)) { $best = $r }
    }
    if ($null -eq $best) { return $true }
    return $best.Allow
}

# ============================================================================
#  NETWORK
# ============================================================================

$script:RobotsCache = @{}
function Invoke-DiscoveryRequest {
    <# One polite GET: robots.txt first (once per host), then the throttle.
       -OutFile saves the body to disk; otherwise the text is returned. #>
    param([string]$Uri, [string]$OutFile)
    $u = [uri]$Uri
    $origin = $u.Scheme + '://' + $u.Authority
    if (-not $script:RobotsCache.ContainsKey($origin)) {
        $txt = ''
        try {
            Start-Sleep -Milliseconds $script:DiscoveryThrottleMs
            $txt = [string](Invoke-WebRequest -Uri "$origin/robots.txt" -UserAgent $script:DiscoveryAgent -UseBasicParsing -TimeoutSec 30).Content
        } catch { Write-Verbose "no robots.txt at $origin, treated as allow-all: $($_.Exception.Message)" }
        $script:RobotsCache[$origin] = $txt
    }
    if (-not (Test-RobotsAllowed $script:RobotsCache[$origin] $u.PathAndQuery)) { throw "blocked by robots: $Uri" }
    Start-Sleep -Milliseconds $script:DiscoveryThrottleMs
    $p = @{ Uri = $Uri; UserAgent = $script:DiscoveryAgent; UseBasicParsing = $true; TimeoutSec = 300 }
    if ($OutFile) { Invoke-WebRequest @p -OutFile $OutFile | Out-Null; return $OutFile }
    return [string](Invoke-WebRequest @p).Content
}

function Read-ZipEntryText {
    param([string]$ZipPath, [string]$EntryName)
    $z = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $e = @($z.Entries | Where-Object { $_.Name -ieq $EntryName }) | Select-Object -First 1
        if (-not $e) { throw "NCUA zip: $EntryName not found" }
        $sr = [IO.StreamReader]::new($e.Open())
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $z.Dispose() }
}

# ============================================================================
#  MAIN
# ============================================================================

if (-not $SweepScript) { $SweepScript = Join-Path $PSScriptRoot 'Invoke-JobSweep.ps1' }
if (-not (Test-Path -LiteralPath $SweepScript)) { throw "Sweep script not found: $SweepScript" }

# Defaults and the profile merge come from the collector, so a profile that
# the sweep accepts is accepted here.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($SweepScript, [ref]$null, [ref]$null)
$pieces = @()
$cfg = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Config' }, $true))
$ver = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$JobSweepVersion' }, $true))
if ($cfg.Count -eq 0 -or $ver.Count -eq 0) { throw "Could not read the defaults from $SweepScript" }
$pieces += $ver[0].Extent.Text
$pieces += $cfg[0].Extent.Text
$pieces += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                             $n.Name -eq 'Merge-JobSweepProfile' }, $true) | ForEach-Object { $_.Extent.Text })
. ([scriptblock]::Create($pieces -join "`n`n"))
$script:DiscoveryAgent = "JobSweep/$JobSweepVersion employer discovery (+https://github.com/riffmillar-itadmin/jobsweep)"
$script:DiscoveryThrottleMs = [Math]::Max(0, $ThrottleMs)

if (-not $ProfilePath) {
    $dir = Split-Path -Parent $SweepScript
    $local = Join-Path $dir 'JobSweep.local.psd1'
    if (-not (Test-Path -LiteralPath $local)) { $local = Join-Path $dir 'JobSweep.local.example.psd1' }
    $ProfilePath = @((Join-Path $dir 'JobSweep.targeting.psd1'), $local)
}
$Config = Merge-JobSweepProfile -Defaults $Config -ProfilePath $ProfilePath
$set = Get-DiscoverySetting $Config
if (-not $OutputRoot) {
    $OutputRoot = if ($Config.ContainsKey('OutputRoot') -and $Config.OutputRoot) {
        [Environment]::ExpandEnvironmentVariables([string]$Config.OutputRoot)
    } else { Split-Path -Parent $SweepScript }
}
if (-not $OutFile) {
    $sweepDir = Join-Path $OutputRoot 'Sweeps'
    New-Item -ItemType Directory -Path $sweepDir -Force | Out-Null
    $OutFile = Join-Path $sweepDir ("employers-{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd'))
}
$run = if ($Dataset) { @($Dataset) } else { @($set.Datasets) }

$profileKeys = @{}
foreach ($s in @($Config.Sources)) { $k = Get-EmployerNameKey ([string]$s.Company); if ($k -and -not $profileKeys.ContainsKey($k)) { $profileKeys[$k] = [string]$s.Company } }

$zoneSet = (@($set.ZoneZipPrefixes).Count + @($set.ZoneZips).Count + @($set.ZoneCities).Count) -gt 0
if (-not $zoneSet) { Write-Warning 'No zone in Discovery (ZoneZipPrefixes, ZoneZips, ZoneCities): every row counts as in zone.' }

$summary = [System.Collections.Generic.List[object]]::new()
$all = @()
foreach ($ds in @('IRS', 'NCUA', 'FDIC', 'Local')) {
    if ($run -notcontains $ds) { $summary.Add([pscustomobject]@{ Dataset = $ds; Status = 'SKIP'; AboveSize = '-'; Note = 'not selected' }); continue }
    if ($ds -ne 'Local' -and $set.State -notmatch '^[A-Z]{2}$') {
        $summary.Add([pscustomobject]@{ Dataset = $ds; Status = 'SKIP'; AboveSize = '-'; Note = 'Discovery.State is not set (two letters)' }); continue
    }
    if ($ds -eq 'Local' -and @($set.ExtraCsv).Count -eq 0) {
        $summary.Add([pscustomobject]@{ Dataset = $ds; Status = 'SKIP'; AboveSize = '-'; Note = 'no Discovery.ExtraCsv files' }); continue
    }
    Write-Host "-> $ds" -ForegroundColor Cyan
    try {
        $rows = @()
        $note = ''
        switch ($ds) {
            'IRS' {
                $u = "https://www.irs.gov/pub/irs-soi/eo_$($set.State.ToLower()).csv"
                $rows = @(ConvertFrom-IrsEoCsv (Invoke-DiscoveryRequest $u) $set)
                $note = "revenue >= $('{0:N0}' -f $set.MinNonprofitRevenue)"
            }
            'NCUA' {
                $page = Invoke-DiscoveryRequest 'https://ncua.gov/analysis/credit-union-corporate-call-report-data/quarterly-data'
                $zipUrl = Get-NcuaNewestZip $page
                if (-not $zipUrl) { throw 'NCUA: no call-report-data zip link on the quarterly data page' }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-ncua-{0}.zip" -f ([guid]::NewGuid().ToString('N')))
                try {
                    $null = Invoke-DiscoveryRequest $zipUrl -OutFile $tmp
                    $rows = @(ConvertFrom-NcuaCallReport (Read-ZipEntryText $tmp 'FOICU.txt') (Read-ZipEntryText $tmp 'FS220.txt') $set)
                } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                $note = "$(Split-Path $zipUrl -Leaf); assets >= $('{0:N0}' -f $set.MinCreditUnionAssets)"
            }
            'FDIC' {
                $u = "https://api.fdic.gov/banks/institutions?filters=STALP%3A$($set.State)%20AND%20ACTIVE%3A1&fields=NAME%2CCITY%2CZIP%2CASSET%2CWEBADDR%2CCERT&limit=10000&format=json"
                $rows = @(ConvertFrom-FdicInstitution (Invoke-DiscoveryRequest $u) $set)
                $note = "headquartered in state; assets >= $('{0:N0}' -f $set.MinBankAssets)"
            }
            'Local' {
                foreach ($f in @($set.ExtraCsv)) {
                    $p = [Environment]::ExpandEnvironmentVariables([string]$f)
                    if (-not (Test-Path -LiteralPath $p)) { throw "local CSV not found: $p" }
                    $rows += @(ConvertFrom-LocalEmployerCsv (Get-Content -LiteralPath $p -Raw) (Split-Path $p -Leaf))
                }
                $note = "$(@($set.ExtraCsv).Count) file(s)"
            }
        }
        $all += $rows
        $summary.Add([pscustomobject]@{ Dataset = $ds; Status = 'PASS'; AboveSize = $rows.Count; Note = $note })
    } catch {
        $msg = $_.Exception.Message
        $st = if ($msg -like 'blocked by robots*') { 'SKIP' } else { 'FAIL' }
        Write-Warning "$ds : $msg"
        $summary.Add([pscustomobject]@{ Dataset = $ds; Status = $st; AboveSize = '-'; Note = $msg })
    }
}

$all = @(Merge-EmployerRow $all)
foreach ($r in $all) {
    $r.in_zone = [bool](Test-EmployerInZone $r.zip $r.city $set)
    $r.already_in_profile = Test-EmployerInProfile $r.company $profileKeys
}
$inZone = @($all | Where-Object { $_.in_zone })
$write  = if ($IncludeOutOfZone) { $all } else { $inZone }
$write  = @($write | Sort-Object @{ Expression = { $_.size_value -as [long] }; Descending = $true })

$csvArgs = @{ Encoding = 'UTF8' }
if ($PSVersionTable.PSVersion.Major -lt 6) { $csvArgs['NoTypeInformation'] = $true }
$write | Export-Csv -LiteralPath $OutFile @csvArgs
Write-Host ("`nWrote {0} rows to {1}" -f $write.Count, $OutFile)

$inProfile = @($inZone | Where-Object { $_.already_in_profile }).Count
$summary.Add([pscustomobject]@{ Dataset = 'All (merged)'; Status = 'INFO'; AboveSize = $all.Count; Note = ("{0} in zone, {1} of those already in profile, {2} new" -f $inZone.Count, $inProfile, ($inZone.Count - $inProfile)) })

$sPass = @($summary | Where-Object Status -eq 'PASS').Count
$sFail = @($summary | Where-Object Status -eq 'FAIL').Count
$sSkip = @($summary | Where-Object Status -eq 'SKIP').Count
. (Join-Path $PSScriptRoot 'JobSweep.Summary.ps1')
Write-JobSweepSummary -Script 'Find-JobSweepEmployers.ps1' -Target ("{0} -> {1}" -f (($ProfilePath | ForEach-Object { Split-Path $_ -Leaf }) -join ' + '), $OutFile) `
    -Rows @($summary) -Pass $sPass -Fail $sFail -Skip $sSkip
if ($sFail -gt 0) { exit 1 }
