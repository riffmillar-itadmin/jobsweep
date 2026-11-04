<#
.SYNOPSIS
    Scouts for new career portals and prints Sources entries ready to paste into
    a JobSweep local profile.

.DESCRIPTION
    A job board that aggregates postings has already filtered them. Employers whose
    own careers portal it never scraped stay invisible. This script works from the
    other end. Give it company names, careers URLs, or both, and for each one it:

      1. works out the provider and its keys from a careers URL
         (Greenhouse, Lever, Workday, iCIMS, UltiPro, ADP WorkforceNow, Dayforce)
      2. or, given only a company name, guesses the slug and probes the providers
         that can be probed by name (Greenhouse, Lever, Dayforce)
      3. checks that the board answers, counts its postings, and counts the titles
         that pass your profile's title screen
      4. skips anything already in your profile's Sources
      5. prints a table, plus paste-ready @{ Provider=... } lines for the new ones

    It never writes to a profile. Where the names and URLs come from is up to you:
    a web search such as  site:myworkdayjobs.com "systems administrator"  turns up
    portals an aggregator missed. From a job site's alert list, take the company
    NAMES only. Most job sites' terms forbid automated scraping, and a name is
    all this script needs.

    A name-based hit is a GUESS. "example" on Greenhouse may be a different
    company of the same name, so open the board before you add it.

.PARAMETER Company
    Company names. Each one is turned into slug guesses and probed.

.PARAMETER Url
    Careers or posting URLs. Each one is read for its provider and keys.

.PARAMETER InputFile
    A text file with one entry per line: a URL, a company name, or
    "Company Name, https://...". Blank lines and lines starting with # are skipped.

.PARAMETER ProfilePath
    Profiles merged for the title screen and the already-have check. Defaults to
    JobSweep.targeting.psd1 plus JobSweep.local.psd1 beside the sweep script, or
    the shipped example when there is no local profile.

.PARAMETER NoProbe
    Read URLs and print entries without any network call. Name-only entries are
    reported as not probed.

.PARAMETER OutFile
    Also write the results as JSON to this path.

.PARAMETER ThrottleMs
    Pause before each request, in milliseconds. Default 500.

.PARAMETER SweepScript
    The collector to read defaults and the title screen from. Defaults to
    Invoke-JobSweep.ps1 beside this script.

.EXAMPLE
    .\Find-JobSweepSources.ps1 -Url 'https://jobs.lever.co/example-fintech' -Company 'Example Logistics, Inc.'

.EXAMPLE
    .\Find-JobSweepSources.ps1 -InputFile .\scout-list.txt -OutFile .\scout.json
#>
[CmdletBinding()]
param(
    [string[]] $Company,
    [string[]] $Url,
    [string]   $InputFile,
    [string[]] $ProfilePath,
    [switch]   $NoProbe,
    [string]   $OutFile,
    [int]      $ThrottleMs = 500,
    [string]   $SweepScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
#  PURE HELPERS (the filter suite extracts these by name)
# ============================================================================

function ConvertFrom-CareersUrl {
    <# A careers or posting URL turned into a Sources entry, or $null when the URL
       is not a provider this collector reads. Company is left for the caller. #>
    param([string]$Url)
    if (-not $Url) { return $null }
    $u = $Url.Trim()

    $m = [regex]::Match($u, '(?i)^https?://(?:boards|job-boards)\.greenhouse\.io/(?:embed/job_board\?for=)?([a-z0-9_-]+)')
    if (-not $m.Success) { $m = [regex]::Match($u, '(?i)^https?://boards-api\.greenhouse\.io/v1/boards/([a-z0-9_-]+)') }
    if ($m.Success -and $m.Groups[1].Value -notin @('embed', 'v1')) {
        return @{ Provider = 'Greenhouse'; Token = $m.Groups[1].Value.ToLower() }
    }

    # The collector reads api.lever.co only, so an EU board (jobs.eu.lever.co) is not offered.
    $m = [regex]::Match($u, '(?i)^https?://(?:jobs\.lever\.co|api\.lever\.co/v0/postings)/([a-z0-9_.-]+)')
    if ($m.Success) { return @{ Provider = 'Lever'; Token = $m.Groups[1].Value.ToLower() } }

    # Workday: a tenant host (<tenant>.wdN.myworkdayjobs.com/<site>) or the shared
    # host (wdN.myworkdaysite.com/recruiting/<tenant>/<site>). An optional locale
    # segment such as en-US comes before the site.
    $m = [regex]::Match($u, '(?i)^https?://([a-z0-9-]+)\.(wd\d+)\.myworkdayjobs\.com/(?:wday/cxs/[a-z0-9_-]+/)?(?:[a-z]{2}-[a-z]{2}/)?([a-z0-9_-]+)')
    if ($m.Success) {
        return @{ Provider = 'Workday'; WdHost = ('https://{0}.{1}.myworkdayjobs.com' -f $m.Groups[1].Value.ToLower(), $m.Groups[2].Value.ToLower())
                  Tenant = $m.Groups[1].Value.ToLower(); Site = $m.Groups[3].Value }
    }
    $m = [regex]::Match($u, '(?i)^https?://(wd\d+)\.myworkdaysite\.com/(?:[a-z]{2}-[a-z]{2}/)?recruiting/([a-z0-9_-]+)/([a-z0-9_-]+)')
    if ($m.Success) {
        return @{ Provider = 'Workday'; WdHost = ('https://{0}.myworkdaysite.com' -f $m.Groups[1].Value.ToLower())
                  Tenant = $m.Groups[2].Value.ToLower(); Site = $m.Groups[3].Value }
    }

    $m = [regex]::Match($u, '(?i)^https?://([a-z0-9-]+)\.icims\.com(?:/|$)')
    if ($m.Success -and $m.Groups[1].Value -notin @('www', 'developer', 'community')) {
        return @{ Provider = 'iCIMS'; BaseUrl = ('https://{0}.icims.com' -f $m.Groups[1].Value.ToLower()) }
    }

    $m = [regex]::Match($u, '(?i)^https?://(recruiting\d*\.ultipro\.com)/([a-z0-9]+)/JobBoard/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if ($m.Success) {
        $e = @{ Provider = 'UltiPro'; Tenant = $m.Groups[2].Value.ToUpper(); BoardId = $m.Groups[3].Value.ToLower() }
        $h = $m.Groups[1].Value.ToLower()
        if ($h -ne 'recruiting.ultipro.com') { $e['UkgHost'] = "https://$h" }
        return $e
    }

    if ($u -match '(?i)^https?://workforcenow\.adp\.com/') {
        $cid = [regex]::Match($u, '(?i)[?&]cid=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
        if ($cid.Success) {
            $e = @{ Provider = 'ADP'; Cid = $cid.Groups[1].Value.ToLower() }
            $cc = [regex]::Match($u, '(?i)[?&]ccId=([^&#]+)')
            if ($cc.Success) { $e['CcId'] = [uri]::UnescapeDataString($cc.Groups[1].Value) }
            return $e
        }
        return $null
    }

    $m = [regex]::Match($u, '(?i)^https?://jobs\.dayforcehcm\.com/(?:[a-z]{2}-[a-z]{2}/)?([a-z0-9_-]+)(?:/([a-z0-9_-]+))?')
    if ($m.Success -and $m.Groups[1].Value -notin @('api')) {
        $board = 'CANDIDATEPORTAL'
        if ($m.Groups[2].Success -and $m.Groups[2].Value -and $m.Groups[2].Value -notin @('jobs')) { $board = $m.Groups[2].Value.ToUpper() }
        return @{ Provider = 'Dayforce'; Namespace = $m.Groups[1].Value.ToLower(); Board = $board }
    }
    return $null
}

function Get-SlugGuess {
    <# Slug guesses for a company name, best first: the name run together, then
       hyphenated. Legal suffixes such as Inc or LLC are dropped. #>
    param([string]$Name)
    if (-not $Name) { return @() }
    $n = $Name.ToLower() -replace '&', ' and '
    $n = $n -replace "[^a-z0-9 ]", ' '
    $words = @($n -split '\s+' | Where-Object { $_ })
    $suffix = @('inc', 'incorporated', 'llc', 'llp', 'lp', 'ltd', 'limited', 'corp', 'corporation', 'co', 'company', 'plc', 'pllc', 'pc', 'the')
    while ($words.Count -gt 1 -and $suffix -contains $words[-1]) { $words = @($words[0..($words.Count - 2)]) }
    if ($words.Count -gt 1 -and $words[0] -eq 'the') { $words = @($words[1..($words.Count - 1)]) }
    if ($words.Count -eq 0) { return @() }
    $out = @($words -join '')
    if ($words.Count -gt 1) { $out += ($words -join '-') }
    return @($out | Select-Object -Unique)
}

function Get-SourceKey {
    <# The identity of a source, for the already-in-profile check. #>
    param([hashtable]$Src)
    $g = { param($k) if ($Src.ContainsKey($k) -and $Src[$k]) { ([string]$Src[$k]).ToLower().TrimEnd('/') } else { '' } }
    switch ($Src.Provider) {
        'Greenhouse' { return 'greenhouse|' + (& $g 'Token') }
        'Lever'      { return 'lever|' + (& $g 'Token') }
        'Workday'    { return 'workday|' + (& $g 'Tenant') + '|' + (& $g 'Site') }
        'iCIMS'      { return 'icims|' + (& $g 'BaseUrl') }
        'UltiPro'    { return 'ultipro|' + (& $g 'BoardId') }
        'ADP'        { return 'adp|' + (& $g 'Cid') }
        'Dayforce'   {
            $b = & $g 'Board'; if (-not $b) { $b = 'candidateportal' }
            return 'dayforce|' + (& $g 'Namespace') + '|' + $b
        }
        default      { return ([string]$Src.Provider).ToLower() + '|' + (& $g 'Company') }
    }
}

function Format-SourceEntry {
    <# One Sources line in the profile's own style, keys in a fixed order. #>
    param([hashtable]$Src)
    $order = @('Provider', 'Company', 'Token', 'WdHost', 'Tenant', 'Site', 'BaseUrl', 'UkgHost', 'BoardId', 'Cid', 'CcId', 'Namespace', 'Board')
    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $parts = foreach ($k in $order) { if ($Src.ContainsKey($k) -and $Src[$k]) { '{0}={1}' -f $k, (& $q $Src[$k]) } }
    return '@{ ' + ($parts -join '; ') + ' }'
}

function Get-NameFromSource {
    <# A placeholder company name when a URL came without one: the slug or tenant. #>
    param([hashtable]$Src)
    foreach ($k in 'Token', 'Tenant', 'Namespace') { if ($Src.ContainsKey($k) -and $Src[$k]) { return [string]$Src[$k] } }
    if ($Src.ContainsKey('BaseUrl') -and $Src.BaseUrl) { return (([uri]$Src.BaseUrl).Host -replace '^careers-', '' -replace '\.icims\.com$', '') }
    return [string]$Src.Provider
}

function ConvertFrom-ScoutLine {
    <# One input line: a URL, a name, or "Name, URL". Returns @{ Company; Url } or $null. #>
    param([string]$Line)
    if ($null -eq $Line) { return $null }
    $t = $Line.Trim()
    if (-not $t -or $t.StartsWith('#')) { return $null }
    $i = $t.IndexOf('http', [StringComparison]::OrdinalIgnoreCase)
    if ($i -eq 0) { return @{ Company = ''; Url = $t } }
    if ($i -gt 0) { return @{ Company = $t.Substring(0, $i).Trim().TrimEnd(',', ';', '|', '-').Trim(); Url = $t.Substring($i).Trim() } }
    return @{ Company = $t; Url = '' }
}

# ============================================================================
#  NETWORK PROBES
# ============================================================================

function Invoke-ScoutRequest {
    param([string]$Uri, [string]$Method = 'Get', $Body, [hashtable]$Headers, $WebSession)
    Start-Sleep -Milliseconds $script:ScoutThrottleMs
    $p = @{ Uri = $Uri; Method = $Method; UserAgent = $script:ScoutAgent; TimeoutSec = 30 }
    if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 6 -Compress); $p['ContentType'] = 'application/json' }
    if ($Headers)    { $p['Headers'] = $Headers }
    if ($WebSession) { $p['WebSession'] = $WebSession }
    Invoke-RestMethod @p
}

function Invoke-SourceProbe {
    <# Asks the board for its first page. Returns @{ Answered; Postings; Titles; Note }.
       Postings is what the board says it holds; Titles are the ones seen on that page. #>
    param([hashtable]$Src)
    $r = @{ Answered = $false; Postings = 0; Titles = @(); Note = '' }
    $prop = { param($o, $n) $null -ne $o -and $o.PSObject.Properties.Name -contains $n }
    try {
        switch ($Src.Provider) {
            'Greenhouse' {
                $j = Invoke-ScoutRequest "https://boards-api.greenhouse.io/v1/boards/$($Src.Token)/jobs"
                $jobs = @(); if (& $prop $j 'jobs') { $jobs = @($j.jobs) }
                $r.Answered = $true; $r.Postings = $jobs.Count; $r.Titles = @($jobs | ForEach-Object { [string]$_.title })
            }
            'Lever' {
                $j = @(Invoke-ScoutRequest "https://api.lever.co/v0/postings/$($Src.Token)?mode=json")
                $r.Answered = $true; $r.Postings = $j.Count; $r.Titles = @($j | Where-Object { & $prop $_ 'text' } | ForEach-Object { [string]$_.text })
            }
            'Workday' {
                $j = Invoke-ScoutRequest "$($Src.WdHost)/wday/cxs/$($Src.Tenant)/$($Src.Site)/jobs" -Method Post `
                         -Body @{ appliedFacets = @{}; limit = 20; offset = 0; searchText = '' }
                $r.Answered = $true
                if (& $prop $j 'total') { $r.Postings = [int]$j.total }
                if (& $prop $j 'jobPostings') { $r.Titles = @($j.jobPostings | ForEach-Object { [string]$_.title }) }
                $r.Note = 'titles from the first page only'
            }
            'Dayforce' {
                $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                $c = Invoke-ScoutRequest 'https://jobs.dayforcehcm.com/api/auth/csrf' -WebSession $s
                if (-not (& $prop $c 'csrfToken')) { throw 'no csrfToken' }
                $b = 'CANDIDATEPORTAL'; if ($Src.ContainsKey('Board') -and $Src.Board) { $b = $Src.Board }
                $j = Invoke-ScoutRequest "https://jobs.dayforcehcm.com/api/geo/$($Src.Namespace)/jobposting/search" -Method Post -WebSession $s `
                         -Headers @{ 'X-CSRF-TOKEN' = [string]$c.csrfToken } `
                         -Body @{ clientNamespace = $Src.Namespace; jobBoardCode = $b; cultureCode = 'en-US'; paginationStart = 0 }
                $posts = @(); if ((& $prop $j 'jobPostings') -and $j.jobPostings) { $posts = @($j.jobPostings) }
                if ($posts.Count -gt 0) {
                    $r.Answered = $true
                    $r.Postings = if ((& $prop $j 'maxCount') -and $j.maxCount) { [int]$j.maxCount } else { $posts.Count }
                    $r.Titles = @($posts | Where-Object { & $prop $_ 'jobTitle' } | ForEach-Object { [string]$_.jobTitle })
                    $r.Note = 'titles from the first page only'
                } else { $r.Note = 'no postings on that namespace and board' }
            }
            default { $r.Note = "not probed: run Invoke-JobSweep.ps1 -Source $($Src.Provider) -DryRun with the entry added" }
        }
    }
    catch {
        $r.Answered = $false
        $r.Note = "no answer: $($_.Exception.Message)"
        Write-Verbose "$($Src.Provider) probe failed: $($_.Exception.Message)"
    }
    return $r
}

# The rest runs only when the script is invoked, not when the suite extracts the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

# ============================================================================
#  MAIN
# ============================================================================

if (-not $SweepScript) { $SweepScript = Join-Path $PSScriptRoot 'Invoke-JobSweep.ps1' }
if (-not (Test-Path -LiteralPath $SweepScript)) { throw "Sweep script not found: $SweepScript" }

# The defaults, the profile merge and the title screen come straight from the
# collector, so the counts here match what a real sweep would keep.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($SweepScript, [ref]$null, [ref]$null)
$pieces = @()
$cfg = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Config' }, $true))
$ver = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$JobSweepVersion' }, $true))
if ($cfg.Count -eq 0 -or $ver.Count -eq 0) { throw "Could not read the defaults from $SweepScript" }
$pieces += $ver[0].Extent.Text
$pieces += $cfg[0].Extent.Text
$pieces += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                             $n.Name -in @('Merge-JobSweepProfile', 'Test-TitleMatch') }, $true) | ForEach-Object { $_.Extent.Text })
. ([scriptblock]::Create($pieces -join "`n`n"))
$script:ScoutAgent = "JobSweep/$JobSweepVersion source scout (+https://github.com/riffmillar-itadmin/jobsweep)"
$script:ScoutThrottleMs = [Math]::Max(0, $ThrottleMs)

if (-not $ProfilePath) {
    $dir = Split-Path -Parent $SweepScript
    $local = Join-Path $dir 'JobSweep.local.psd1'
    if (-not (Test-Path -LiteralPath $local)) { $local = Join-Path $dir 'JobSweep.local.example.psd1' }
    $ProfilePath = @((Join-Path $dir 'JobSweep.targeting.psd1'), $local)
}
$Config = Merge-JobSweepProfile -Defaults $Config -ProfilePath $ProfilePath
$have = @{}
foreach ($s in @($Config.Sources)) { $have[(Get-SourceKey $s)] = [string]$s.Company }

# Gather the work list.
$work = @()
foreach ($c in @($Company)) { if ($c) { $work += @{ Company = $c.Trim(); Url = '' } } }
foreach ($x in @($Url))     { if ($x) { $work += @{ Company = ''; Url = $x.Trim() } } }
if ($InputFile) {
    if (-not (Test-Path -LiteralPath $InputFile)) { throw "Input file not found: $InputFile" }
    foreach ($line in Get-Content -LiteralPath $InputFile) { $e = ConvertFrom-ScoutLine $line; if ($e) { $work += $e } }
}
if ($work.Count -eq 0) { throw 'Nothing to scout. Pass -Company, -Url or -InputFile.' }

$results = foreach ($w in $work) {
    $tries = @()
    if ($w.Url) {
        $src = ConvertFrom-CareersUrl $w.Url
        if (-not $src) {
            [pscustomobject][ordered]@{ Input = $w.Url; Company = $(if ($w.Company) { $w.Company } else { $w.Url }); Provider = '-'; Status = 'unrecognised URL'; Postings = '-'; TitleMatches = '-'; Note = 'not a provider the collector reads'; Entry = '' }
            continue
        }
        $name = $w.Company
        if (-not $name) { $name = Get-NameFromSource $src }
        $src['Company'] = $name
        $tries += @{ Src = $src; Guess = $false }
    } else {
        foreach ($slug in (Get-SlugGuess $w.Company)) {
            $tries += @{ Src = @{ Provider = 'Greenhouse'; Company = $w.Company; Token = $slug }; Guess = $true }
            $tries += @{ Src = @{ Provider = 'Lever';      Company = $w.Company; Token = $slug }; Guess = $true }
            $tries += @{ Src = @{ Provider = 'Dayforce';   Company = $w.Company; Namespace = $slug; Board = 'CANDIDATEPORTAL' }; Guess = $true }
        }
    }

    $found = 0
    foreach ($t in $tries) {
        $src = $t.Src
        $key = Get-SourceKey $src
        $input_ = if ($w.Url) { $w.Url } else { $w.Company }
        if ($have.ContainsKey($key)) {
            $found++
            [pscustomobject][ordered]@{ Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = 'already in profile'; Postings = '-'; TitleMatches = '-'; Note = "as $($have[$key])"; Entry = '' }
            continue
        }
        if ($NoProbe) {
            if ($t.Guess) { continue }
            [pscustomobject][ordered]@{ Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = 'new (not probed)'; Postings = '-'; TitleMatches = '-'; Note = ''; Entry = (Format-SourceEntry $src) }
            $found++
            continue
        }
        $p = Invoke-SourceProbe $src
        if ($t.Guess -and -not $p.Answered) { continue }
        $found++
        $matched = @($p.Titles | Where-Object { (Test-TitleMatch $_).Ok }).Count
        $status = if (-not $p.Answered -and $p.Note -like 'not probed*') { 'new (not probed)' }
                  elseif (-not $p.Answered) { 'no answer' }
                  elseif ($t.Guess) { 'new (name guess, check it)' } else { 'new' }
        [pscustomobject][ordered]@{
            Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = $status
            Postings = $(if ($p.Answered) { $p.Postings } else { '-' }); TitleMatches = $(if ($p.Answered) { $matched } else { '-' })
            Note = $p.Note; Entry = $(if ($status -like 'new*') { Format-SourceEntry $src } else { '' })
        }
    }
    if (-not $w.Url -and $found -eq 0) {
        $why = if ($NoProbe) { 'not probed (-NoProbe)' } else { 'no Greenhouse, Lever or Dayforce board under the guessed names; find its careers URL' }
        [pscustomobject][ordered]@{ Input = $w.Company; Company = $w.Company; Provider = '-'; Status = 'not found'; Postings = '-'; TitleMatches = '-'; Note = $why; Entry = '' }
    }
}
$results = @($results)

$results | Select-Object Company, Provider, Status, Postings, TitleMatches, Note |
    Format-Table -AutoSize -Wrap | Out-String -Width 300 | Write-Host

$new = @($results | Where-Object { $_.Entry })
if ($new.Count -gt 0) {
    Write-Host "Paste into Sources in your local profile (check name guesses first):" -ForegroundColor Cyan
    foreach ($n in $new) { Write-Host "    $($n.Entry)" }
} else {
    Write-Host 'No new sources found.'
}
$counts = $results | Group-Object Status | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }
Write-Host ("`nScouted {0} input(s): {1}" -f $work.Count, ($counts -join ', '))

if ($OutFile) {
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host "Wrote $OutFile"
}
