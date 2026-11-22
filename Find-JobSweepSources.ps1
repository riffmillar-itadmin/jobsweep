<#
.SYNOPSIS
    Scouts for new career portals and prints Sources entries ready to paste into
    a JobSweep local profile.

.DESCRIPTION
    A job board that aggregates postings has already filtered them. Employers whose
    own careers portal it never scraped stay invisible. This script works from the
    other end. Give it company names, careers URLs, or both, and for each one it:

      1. works out the provider and its keys from a careers URL
         (Greenhouse, Lever, Workday, iCIMS, UltiPro, ADP WorkforceNow and MyJobs, Dayforce,
         Rippling, Paylocity, ApplicantPro)
      2. or, given only a company name, guesses the slug and probes the providers
         that can be probed by name (Greenhouse, Lever, Dayforce, Rippling)
      3. checks that the board answers, counts its postings, and counts the titles
         that pass your profile's title screen
      4. skips anything already in your profile's Sources
      5. prints a table, plus paste-ready @{ Provider=... } lines for the new ones

    With -EmployerCsv it starts one step earlier, from employer names: it finds
    each employer's careers page and the applicant-tracking system behind it,
    then carries on as above. Employer pages are fetched only where the site's
    robots.txt allows it.

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

.PARAMETER EmployerCsv
    An employer list, such as the one Find-JobSweepEmployers.ps1 writes. Needs a
    company column; website, careers_url, city and already_in_profile are used
    when present. For each employer it finds the careers page (careers_url, else
    the website's careers link, else a guessed website that names the employer
    and its city) and the applicant-tracking system behind it. Systems the
    collector reads go on to the usual probe; the rest are reported by name and
    tallied. Every row is also written to finder-<date>.csv beside the list.

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

.EXAMPLE
    .\Find-JobSweepSources.ps1 -EmployerCsv .\Sweeps\employers-2026-01-15.csv
#>
[CmdletBinding()]
param(
    [string[]] $Company,
    [string[]] $Url,
    [string]   $InputFile,
    [string]   $EmployerCsv,
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

    if ($u -match '(?i)^https?://workforcenow\.(cloud\.)?adp\.com/') {
        $cloud = [bool]$Matches[1]
        $cid = [regex]::Match($u, '(?i)[?&]cid=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
        if ($cid.Success) {
            $e = @{ Provider = 'ADP'; Cid = $cid.Groups[1].Value.ToLower() }
            $cc = [regex]::Match($u, '(?i)[?&]ccId=([^&#]+)')
            if ($cc.Success) { $e['CcId'] = [uri]::UnescapeDataString($cc.Groups[1].Value) }
            # employers on the .cloud. host get a 404 from the plain one, so keep it
            if ($cloud) { $e['AdpHost'] = 'https://workforcenow.cloud.adp.com' }
            return $e
        }
        return $null
    }

    # ADP's other careers product (1.13.0): myjobs.adp.com/<name>/cx/... The name is the
    # career site; the collector reads its settings and job list from that alone.
    $m = [regex]::Match($u, '(?i)^https?://myjobs\.adp\.com/([a-z0-9_-]{2,64})(?:/|$|\?)')
    if ($m.Success -and $m.Groups[1].Value.ToLower() -notin @('public', 'admin', 'assets', 'cx')) {
        return @{ Provider = 'ADP'; MyJobs = $m.Groups[1].Value.ToLower() }
    }

    # The older Dayforce form, usNN. or usrNN.dayforcehcm.com/CandidatePortal/<lang>/<namespace>/,
    # is the same board as jobs.dayforcehcm.com/<lang>/<namespace>/CANDIDATEPORTAL.
    $m = [regex]::Match($u, '(?i)^https?://usr?\d+\.dayforcehcm\.com/CandidatePortal/(?:[a-z]{2}-[a-z]{2}/)?([a-z0-9_-]+)')
    if ($m.Success) { return @{ Provider = 'Dayforce'; Namespace = $m.Groups[1].Value.ToLower(); Board = 'CANDIDATEPORTAL' } }

    $m = [regex]::Match($u, '(?i)^https?://jobs\.dayforcehcm\.com/(?:[a-z]{2}-[a-z]{2}/)?([a-z0-9_-]+)(?:/([a-z0-9_-]+))?')
    if ($m.Success -and $m.Groups[1].Value -notin @('api')) {
        $board = 'CANDIDATEPORTAL'
        if ($m.Groups[2].Success -and $m.Groups[2].Value -and $m.Groups[2].Value -notin @('jobs')) { $board = $m.Groups[2].Value.ToUpper() }
        return @{ Provider = 'Dayforce'; Namespace = $m.Groups[1].Value.ToLower(); Board = $board }
    }

    # Rippling board slugs are case-sensitive, so the case in the URL is kept.
    $m = [regex]::Match($u, '(?i)^https?://ats\.rippling\.com/(?:[a-z]{2}-[a-z]{2}/)?([A-Za-z0-9_-]+)')
    if ($m.Success -and $m.Groups[1].Value -notin @('api', 'jobs')) {
        return @{ Provider = 'Rippling'; Board = $m.Groups[1].Value }
    }
    $m = [regex]::Match($u, '(?i)^https?://api\.rippling\.com/platform/api/ats/v[0-9]+/board/([A-Za-z0-9_-]+)')
    if ($m.Success) { return @{ Provider = 'Rippling'; Board = $m.Groups[1].Value } }

    # Paylocity: only a board URL names the board. A posting URL
    # (/Recruiting/Jobs/Details/<id>) does not, so it is left unrecognised.
    $m = [regex]::Match($u, '(?i)^https?://([a-z0-9-]*recruiting\.paylocity\.com)/recruiting/jobs/(?:All|List)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:/([A-Za-z0-9_-]+))?')
    if ($m.Success) {
        $e = @{ Provider = 'Paylocity'; BoardId = $m.Groups[2].Value.ToLower() }
        # The slug after the GUID is the employer's legal name, the best name the URL has.
        if ($m.Groups[3].Success -and $m.Groups[3].Value) { $e['NameHint'] = ($m.Groups[3].Value -replace '[-_]+', ' ').Trim() }
        $h = $m.Groups[1].Value.ToLower()
        if ($h -ne 'recruiting.paylocity.com') { $e['PlcHost'] = "https://$h" }
        return $e
    }

    # ApplicantPro: the tenant is the subdomain. The platform's own hosts are
    # not tenants. A www.applicantpro.com/openings/<tenant>/ link (the sitemap's
    # form) names the tenant in its path.
    $m = [regex]::Match($u, '(?i)^https?://(?:www\.)?applicantpro\.com/openings/([a-z0-9-]+)')
    if ($m.Success) { return @{ Provider = 'ApplicantPro'; Tenant = $m.Groups[1].Value.ToLower() } }
    $m = [regex]::Match($u, '(?i)^https?://([a-z0-9-]+)\.applicantpro\.com(?:[/?#]|$)')
    if ($m.Success -and $m.Groups[1].Value.ToLower() -notin @('www', 'feeds', 'api', 'admin', 'app')) {
        return @{ Provider = 'ApplicantPro'; Tenant = $m.Groups[1].Value.ToLower() }
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
        'ADP'        {
            if (& $g 'MyJobs') { return 'adp|myjobs|' + (& $g 'MyJobs') }
            return 'adp|' + (& $g 'Cid')
        }
        'Dayforce'   {
            $b = & $g 'Board'; if (-not $b) { $b = 'candidateportal' }
            return 'dayforce|' + (& $g 'Namespace') + '|' + $b
        }
        'Rippling'   { return 'rippling|' + (& $g 'Board') }
        'Paylocity'  { return 'paylocity|' + (& $g 'BoardId') }
        'ApplicantPro' { return 'applicantpro|' + (& $g 'Tenant') }
        default      { return ([string]$Src.Provider).ToLower() + '|' + (& $g 'Company') }
    }
}

function Format-SourceEntry {
    <# One Sources line in the profile's own style, keys in a fixed order. #>
    param([hashtable]$Src)
    $order = @('Provider', 'Company', 'Token', 'WdHost', 'Tenant', 'Site', 'BaseUrl', 'UkgHost', 'PlcHost', 'BoardId', 'Cid', 'CcId', 'AdpHost', 'MyJobs', 'Namespace', 'Board')
    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $parts = foreach ($k in $order) { if ($Src.ContainsKey($k) -and $Src[$k]) { '{0}={1}' -f $k, (& $q $Src[$k]) } }
    return '@{ ' + ($parts -join '; ') + ' }'
}

function Get-NameFromSource {
    <# A placeholder company name when a URL came without one: the slug or tenant. #>
    param([hashtable]$Src)
    foreach ($k in 'NameHint', 'Token', 'Tenant', 'MyJobs', 'Namespace', 'Board') { if ($Src.ContainsKey($k) -and $Src[$k]) { return [string]$Src[$k] } }
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

# ---- careers-page finder (-EmployerCsv) ----

function Get-UnsupportedAtsHost {
    <# Applicant-tracking systems the collector does not read, by host pattern.
       Found on a careers page they are reported and tallied, not probed. #>
    return [ordered]@{
        'Jobvite'          = 'jobvite\.com'
        'SmartRecruiters'  = 'smartrecruiters\.com'
        'Paycom'           = 'paycomonline\.(net|com)'
        'Taleo'            = 'taleo\.net'
        'Oracle Cloud HCM' = 'oraclecloud\.com/hcmUI'
        'SuccessFactors'   = 'successfactors\.(com|eu)|jobs\.sap\.com'
        'BrassRing'        = 'brassring\.com'
        'BambooHR'         = 'bamboohr\.com/(careers|jobs)'
        'JazzHR'           = 'applytojob\.com|jazzhr\.com'
        'Workable'         = 'apply\.workable\.com|workable\.com/j/'
        'Ashby'            = 'jobs\.ashbyhq\.com'
        'Breezy'           = 'breezy\.hr'
        'NEOGOV'           = 'governmentjobs\.com|schooljobs\.com|neogov\.com'
        'PeopleAdmin'      = 'peopleadmin\.com'
        'Cornerstone'      = 'csod\.com'
        'Paycor'           = 'recruitingbypaycor\.com'
        'ADP Recruiting'   = 'recruiting\.adp\.com'
        'ClearCompany'     = 'clearcompany\.com'
        'HiringThing'      = 'hiringthing\.com'
        'Recruitee'        = 'recruitee\.com'
        'Teamtailor'       = 'teamtailor\.com'
        'Avature'          = 'avature\.net'
        'Phenom'           = 'phenompeople\.com'
        'Eightfold'        = 'eightfold\.ai'
        'CareerPlug'       = 'careerplug\.com'
        'ApplicantStack'   = 'applicantstack\.com'
        'HealthcareSource' = 'healthcaresource\.com'
        'Hirebridge'       = 'hirebridge\.com'
        'Pinpoint'         = 'pinpointhq\.com'
        'isolved Hire'     = 'isolvedhire\.com'
        'Interfolio'       = 'interfolio\.com'
    }
}

function Get-PageLink {
    <# Every <a href> on a page as @{ Url (absolute); Text }. mailto, tel and
       javascript links and in-page anchors are dropped. #>
    param([string]$Html, [string]$BaseUrl)
    $base = $null
    try { $base = [uri]$BaseUrl } catch { Write-Verbose "bad base URL $BaseUrl"; return @() }
    $out = foreach ($m in [regex]::Matches([string]$Html, '(?is)<a\b[^>]*?\bhref\s*=\s*["'']([^"''#][^"'']*)["''][^>]*>(.*?)</a>')) {
        $href = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim())
        if ($href -match '^(?i)(mailto|tel|javascript|data):') { continue }
        $abs = $null
        try { $abs = [string]([uri]::new($base, $href)) } catch { Write-Verbose "bad href $href"; continue }
        $text = ([Net.WebUtility]::HtmlDecode(($m.Groups[2].Value -replace '<[^>]+>', ' ')) -replace '\s+', ' ').Trim()
        [pscustomobject]@{ Url = $abs; Text = $text }
    }
    return @($out)
}

function Select-CareersLink {
    <# The link most likely to be the careers page, or ''. A link whose whole text
       is "Careers" or "Jobs" beats one that only mentions them; a careers-shaped
       path counts too. Volunteer, partner, donate and resource links lose. #>
    param([object[]]$Link)
    $exact = '^(careers?|jobs|employment|job openings|current openings|open positions|careers? opportunities|employment opportunities|work with us|work for us|work here|join (our|the) team|join us)$'
    $best = ''; $bestScore = 0
    foreach ($l in @($Link)) {
        if (-not $l -or -not $l.Url) { continue }
        $t = ([string]$l.Text).ToLower().Trim()
        $path = ''
        try { $path = ([uri]$l.Url).AbsolutePath.ToLower() } catch { Write-Verbose "bad link $($l.Url)"; continue }
        if ($path -match '\.(pdf|jpe?g|png|gif|docx?)$') { continue }
        $score = 0
        if ($t -match $exact) { $score += 100 }
        elseif ($t.Length -le 40 -and $t -match '\b(careers?|jobs?|employment)\b') { $score += 60 }
        if ($path -match '/(careers?|jobs?|employment|join-?us|work-?with-?us|work-?here)(/|\.|$)') { $score += 50 }
        if ("$t $path" -match 'volunteer|partner|donat|resource|news|blog|event|board-of|career-?development|career center') { $score -= 80 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = [string]$l.Url }
    }
    return $best
}

function Find-AtsReference {
    <# The applicant-tracking system a page points at: every URL in the page,
       scripts and iframes included, with the page's own URL first. A system
       the collector reads wins over one it does not. Returns
       @{ Kind = 'supported' | 'unsupported'; Ats; Src; Url } or $null. #>
    param([string]$Html, [string]$PageUrl)
    $cands = @(@($PageUrl) + @([regex]::Matches([string]$Html, '(?i)https?://[a-z0-9.-]+\.[a-z]{2,}[^\s"''<>)\\]*') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Value) }))
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $src = ConvertFrom-CareersUrl $c
        if ($src) { return @{ Kind = 'supported'; Ats = [string]$src.Provider; Src = $src; Url = $c } }
    }
    $un = Get-UnsupportedAtsHost
    foreach ($k in $un.Keys) {
        $hit = @($cands | Where-Object { $_ -match "(?i)$($un[$k])" } | Select-Object -First 1)
        if ($hit.Count) { return @{ Kind = 'unsupported'; Ats = $k; Src = $null; Url = [string]$hit[0] } }
    }
    return $null
}

function Get-EmployerWord {
    <# The words of an employer name worth matching on a page: the name key,
       less connecting words and legal or generic tails. Place names stay. #>
    param([string]$Name)
    $stop = @('of', 'and', 'for', 'the', 'in', 'at', 'a', 'an', 'inc', 'services', 'service', 'association', 'center', 'centre', 'group', 'organization')
    return @((Get-EmployerNameKey $Name) -split ' ' | Where-Object { $_ -and $_.Length -gt 1 -and $stop -notcontains $_ })
}

function Get-DomainGuess {
    <# Homepage guesses for a name with no website, best first: the words run
       together, without generic tails, without the leading place name, and the
       initials of a long name; .org before .com. At most -Max guesses.
       Dropping the place name needs two words left, and a guess is never one
       generic word: "Harborview Medical Center" must not guess medical.com. #>
    param([string]$Name, [int]$Max = 6)
    $all = @((Get-EmployerNameKey $Name) -split ' ' | Where-Object { $_ })
    if ($all.Count -eq 0) { return @() }
    $w = @(Get-EmployerWord $Name)
    $stems = @(($all -join ''))
    if ($w.Count) { $stems += ($w -join '') }
    $tail = @('hospital', 'clinic', 'clinics', 'foundation', 'society', 'institute', 'school', 'club', 'house', 'network', 'project', 'alliance', 'agency')
    $short = @($w | Where-Object { $tail -notcontains $_ })
    if ($short.Count -ge 2) { $stems += ($short -join '') }
    if ($w.Count -ge 3) { $stems += (@($w | Select-Object -Skip 1) -join '') }
    if ($all.Count -ge 3) { $stems += (($all | ForEach-Object { $_[0] }) -join '') }
    $generic = @('medical', 'college', 'health', 'healthcare', 'hospital', 'clinic', 'school', 'schools', 'university', 'city',
                 'county', 'district', 'community', 'public', 'library', 'housing', 'center', 'centre', 'services', 'church',
                 'museum', 'foundation', 'institute', 'society', 'bank', 'credit', 'union', 'law', 'care', 'family', 'children')
    $out = foreach ($s in ($stems | Select-Object -Unique)) {
        if ($generic -contains $s) { continue }
        if ($s.Length -ge 3 -and $s.Length -le 30) { "https://www.$s.org/"; "https://www.$s.com/" }
    }
    return @($out | Select-Object -First $Max)
}

function Test-PageNamesEmployer {
    <# A guessed homepage is accepted only when its title (or og:site_name) holds
       most of the employer's words AND the page names the employer's city, so a
       namesake elsewhere ("Children's Hospital" in another state) is refused.
       With no city to check, the title must hold every word. #>
    param([string]$Html, [string]$Name, [string]$City)
    $t = [regex]::Match([string]$Html, '(?is)<title[^>]*>(.*?)</title>').Groups[1].Value
    $t += ' ' + [regex]::Match([string]$Html, '(?i)<meta[^>]+property=["'']og:site_name["''][^>]+content=["'']([^"'']+)').Groups[1].Value
    $tk = ' ' + (Get-EmployerNameKey ([Net.WebUtility]::HtmlDecode($t))) + ' '
    $w = @(Get-EmployerWord $Name)
    if ($w.Count -eq 0) { return $false }
    $hit = @($w | Where-Object { $tk -like "* $_ *" }).Count
    if (-not $City) { return ($hit -eq $w.Count) }
    if (($hit / $w.Count) -lt 0.5) { return $false }
    $c = [regex]::Escape(([string]$City).Trim())
    return [bool]([regex]::IsMatch([string]$Html, "(?i)\b$c\b"))
}

function Test-PageNeedsBrowser {
    <# A page that is mostly script: almost no links at all, or few links and a
       script root or a "turn on JavaScript" notice. Its content is built in
       the browser. #>
    param([string]$Html, [int]$LinkCount)
    if ($LinkCount -le 2) { return $true }
    if ($LinkCount -ge 15) { return $false }
    return [bool]([string]$Html -match '(?i)enable javascript|javascript (is )?required|id=["''](root|app|__next|__nuxt)["'']')
}

# ============================================================================
#  NETWORK PROBES
# ============================================================================

$script:HasOperationTimeout = (Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds')

function Invoke-ScoutRequest {
    param([string]$Uri, [string]$Method = 'Get', $Body, [hashtable]$Headers, $WebSession)
    Start-Sleep -Milliseconds $script:ScoutThrottleMs
    $p = @{ Uri = $Uri; Method = $Method; UserAgent = $script:ScoutAgent; TimeoutSec = 30 }
    if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 6 -Compress); $p['ContentType'] = 'application/json' }
    if ($Headers)    { $p['Headers'] = $Headers }
    if ($WebSession) { $p['WebSession'] = $WebSession }
    # PowerShell 7.4+: -TimeoutSec covers the connect only; this bounds a stalled body.
    if ($script:HasOperationTimeout) { $p['OperationTimeoutSeconds'] = 30 }
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
            'Rippling' {
                $j = Invoke-ScoutRequest "https://api.rippling.com/platform/api/ats/v2/board/$($Src.Board)/jobs?groupJobsByLocation=true&page=0&pageSize=100"
                $items = @(); if ((& $prop $j 'items') -and $j.items) { $items = @($j.items) }
                $r.Answered = $true
                $r.Postings = if ((& $prop $j 'totalItems') -and $j.totalItems) { [int]$j.totalItems } else { $items.Count }
                $r.Titles = @($items | Where-Object { & $prop $_ 'name' } | ForEach-Object { [string]$_.name })
                if ($r.Postings -gt $items.Count) { $r.Note = 'titles from the first page only' }
            }
            'Paylocity' {
                $plc = 'https://recruiting.paylocity.com'; if ($Src.ContainsKey('PlcHost') -and $Src.PlcHost) { $plc = $Src.PlcHost }
                # Invoke-RestMethod hands an HTML page back as its text.
                $h = [string](Invoke-ScoutRequest "$plc/recruiting/jobs/All/$($Src.BoardId)")
                $m = [regex]::Match($h, '(?s)window\.pageData\s*=\s*(\{.*?\});\s*\r?\n')
                if (-not $m.Success) { $r.Note = 'board page has no job list (window.pageData)' }
                else {
                    $pd = $m.Groups[1].Value | ConvertFrom-Json
                    $jobs = @(); if ((& $prop $pd 'Jobs') -and $pd.Jobs) { $jobs = @($pd.Jobs) }
                    $r.Answered = $true; $r.Postings = $jobs.Count
                    $r.Titles = @($jobs | Where-Object { & $prop $_ 'JobTitle' } | ForEach-Object { [string]$_.JobTitle })
                    if ((& $prop $pd 'ModuleTitle') -and $pd.ModuleTitle) { $r.Note = "board name: $($pd.ModuleTitle)" }
                }
            }
            'ApplicantPro' {
                # The /jobs/ page is built in the browser; its script reads the list
                # from /core/jobs/<domainId>, so the probe does the same.
                $base = "https://$($Src.Tenant).applicantpro.com"
                $h = [string](Invoke-ScoutRequest "$base/jobs/")
                $m = [regex]::Match($h, '(?<![\w])domainId\s*:\s*"?(\d+)')
                if (-not $m.Success) { $r.Note = 'jobs page has no domain id' }
                else {
                    $j = Invoke-ScoutRequest "$base/core/jobs/$($m.Groups[1].Value)?getParams=%7B%7D"
                    $jobs = @()
                    if ((& $prop $j 'data') -and (& $prop $j.data 'jobs') -and $j.data.jobs) { $jobs = @($j.data.jobs) }
                    $r.Answered = $true; $r.Postings = $jobs.Count
                    $r.Titles = @($jobs | Where-Object { & $prop $_ 'title' } | ForEach-Object { [string]$_.title })
                    $t = [regex]::Match($h, 'domainTitle\s*:\s*"([^"]+)"')
                    if ($t.Success) { $r.Note = "board name: $($t.Groups[1].Value)" }
                }
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

function Invoke-PageRequest {
    <# One polite GET of an employer's own page: robots.txt first (once per
       site), then the throttle. Returns @{ Ok; Url (after redirects); Html; Note }. #>
    param([string]$Url)
    $r = @{ Ok = $false; Url = $Url; Html = ''; Note = '' }
    $u = $null
    try { $u = [uri]$Url } catch { $r.Note = 'bad URL'; return $r }
    $origin = $u.Scheme + '://' + $u.Authority
    if (-not $script:RobotsCache.ContainsKey($origin)) {
        $txt = ''
        try {
            Start-Sleep -Milliseconds $script:ScoutThrottleMs
            $txt = [string](Invoke-WebRequest -Uri "$origin/robots.txt" -UserAgent $script:ScoutAgent -UseBasicParsing -TimeoutSec 20).Content
            if ($txt -match '(?i)<html') { $txt = '' }   # a page served for a missing file is not a robots file
        } catch { Write-Verbose "no robots.txt at $origin, treated as allow-all: $($_.Exception.Message)" }
        $script:RobotsCache[$origin] = $txt
    }
    if (-not (Test-RobotsAllowed $script:RobotsCache[$origin] $u.PathAndQuery)) { $r.Note = 'blocked by robots'; return $r }
    try {
        Start-Sleep -Milliseconds $script:ScoutThrottleMs
        $p = @{ Uri = $Url; UserAgent = $script:ScoutAgent; UseBasicParsing = $true; TimeoutSec = 25; MaximumRedirection = 5 }
        if ($script:HasOperationTimeout) { $p['OperationTimeoutSeconds'] = 30 }
        $resp = Invoke-WebRequest @p
        $r.Html = [string]$resp.Content
        $final = $null
        $br = $resp.BaseResponse
        if ($br -and $br.PSObject.Properties.Name -contains 'RequestMessage' -and $br.RequestMessage) { $final = $br.RequestMessage.RequestUri }
        elseif ($br -and $br.PSObject.Properties.Name -contains 'ResponseUri') { $final = $br.ResponseUri }
        if ($final) { $r.Url = [string]$final }
        $r.Ok = $true
    } catch {
        $r.Note = ($_.Exception.Message -split "`n")[0]
        Write-Verbose "GET $Url failed: $($r.Note)"
    }
    return $r
}

function Resolve-CareersPage {
    <# From a careers page URL to the system behind it: the URL itself, then the
       page, then one "view openings" link on it. #>
    param([string]$Url)
    $ats = Find-AtsReference '' $Url
    if ($ats) { return @{ Ats = $ats; Status = ''; Note = '' } }
    $c = Invoke-PageRequest $Url
    if (-not $c.Ok) {
        $st = if ($c.Note -eq 'blocked by robots') { 'blocked by robots' } else { 'careers page did not load' }
        return @{ Ats = $null; Status = $st; Note = $c.Note }
    }
    $ats = Find-AtsReference $c.Html $c.Url
    if ($ats) { return @{ Ats = $ats; Status = ''; Note = '' } }
    $links = @(Get-PageLink $c.Html $c.Url)
    $next = @($links | Where-Object { $_.Text -match '(?i)\b(search|view|see|browse|current|open)\b.{0,20}\b(jobs|openings|positions|opportunities)\b' } | Select-Object -First 1)
    if ($next.Count) {
        $ats = Find-AtsReference '' $next[0].Url
        if (-not $ats) {
            $c2 = Invoke-PageRequest $next[0].Url
            if ($c2.Ok) { $ats = Find-AtsReference $c2.Html $c2.Url }
        }
        if ($ats) { return @{ Ats = $ats; Status = ''; Note = '' } }
    }
    if (Test-PageNeedsBrowser $c.Html $links.Count) { return @{ Ats = $null; Status = 'needs a browser'; Note = "$($links.Count) links on $($c.Url)" } }
    return @{ Ats = $null; Status = 'no ATS found'; Note = "jobs may be listed on the employer's own site: $($c.Url)" }
}

function Resolve-EmployerCareer {
    <# One employer row to its applicant-tracking system. Uses careers_url, then
       website, then a guessed domain that names the employer and its city.
       Returns @{ Status; Ats; Website; CareersUrl; Note }; Status is '' when
       an ATS was found. #>
    param([string]$Company, [string]$Website, [string]$CareersUrl, [string]$City)
    $res = @{ Status = ''; Ats = $null; Website = ''; CareersUrl = $CareersUrl; Note = '' }
    if ($CareersUrl) {
        $cp = Resolve-CareersPage $CareersUrl
        $res.Ats = $cp.Ats; $res.Status = $cp.Status; $res.Note = $cp.Note
        return $res
    }
    $page = $null
    if ($Website) {
        if ($Website -notmatch '^(?i)https?://') { $Website = "https://$Website" }
        $page = Invoke-PageRequest $Website
        if (-not $page.Ok) {
            $res.Status = if ($page.Note -eq 'blocked by robots') { 'blocked by robots' } else { 'website did not load' }
            $res.Website = $Website; $res.Note = $page.Note
            return $res
        }
    } else {
        foreach ($g in (Get-DomainGuess $Company)) {
            $try = Invoke-PageRequest $g
            if ($try.Ok -and (Test-PageNamesEmployer $try.Html $Company $City)) { $page = $try; $res.Note = 'website guessed: check it'; break }
        }
        if (-not $page) { $res.Status = 'no website found'; $res.Note = 'add a website column value for this employer'; return $res }
    }
    $res.Website = $page.Url
    $ats = Find-AtsReference $page.Html $page.Url
    if ($ats) { $res.Ats = $ats; return $res }
    $links = @(Get-PageLink $page.Html $page.Url)
    $careers = Select-CareersLink $links
    if (-not $careers) {
        $res.Status = if (Test-PageNeedsBrowser $page.Html $links.Count) { 'needs a browser' } else { 'no careers link found' }
        $res.Note = (@($res.Note, "$($links.Count) links on the homepage") | Where-Object { $_ }) -join '; '
        return $res
    }
    $res.CareersUrl = $careers
    $cp = Resolve-CareersPage $careers
    $res.Ats = $cp.Ats; $res.Status = $cp.Status
    $res.Note = (@($res.Note, $cp.Note) | Where-Object { $_ }) -join '; '
    return $res
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
$script:RobotsCache = @{}
if ($EmployerCsv) {
    # The robots parser and the employer name key are shared with the employer list.
    $empScript = Join-Path $PSScriptRoot 'Find-JobSweepEmployers.ps1'
    if (-not (Test-Path -LiteralPath $empScript)) { throw "Find-JobSweepEmployers.ps1 not found beside the scout: $empScript" }
    $eAst = [System.Management.Automation.Language.Parser]::ParseFile($empScript, [ref]$null, [ref]$null)
    $eFns = @($eAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                               $n.Name -in @('Test-RobotsAllowed', 'Get-EmployerNameKey') }, $true))
    if ($eFns.Count -ne 2) { throw "Could not read Test-RobotsAllowed and Get-EmployerNameKey from $empScript" }
    . ([scriptblock]::Create((@($eFns | ForEach-Object { $_.Extent.Text }) -join "`n`n")))
}

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
$finderRows = @()
if ($EmployerCsv) {
    if (-not (Test-Path -LiteralPath $EmployerCsv)) { throw "Employer list not found: $EmployerCsv" }
    $emp = @(Import-Csv -LiteralPath $EmployerCsv)
    if ($emp.Count -gt 0 -and $emp[0].PSObject.Properties.Name -notcontains 'company') { throw "Employer list has no company column: $EmployerCsv" }
    $col = { param($r, $n) if ($r.PSObject.Properties.Name -contains $n -and $null -ne $r.$n) { ([string]$r.$n).Trim() } else { '' } }
    $i = 0
    foreach ($e in $emp) {
        $i++
        $name = & $col $e 'company'
        if (-not $name) { continue }
        Write-Host ("[{0}/{1}] {2}" -f $i, $emp.Count, $name)
        $inProf = & $col $e 'already_in_profile'
        if ($inProf) {
            $finderRows += [pscustomobject][ordered]@{ Input = $name; Company = $name; Provider = '-'; Status = 'already in profile'; Postings = '-'; TitleMatches = '-'; Note = "as $inProf"; Entry = '' }
            continue
        }
        $f = Resolve-EmployerCareer -Company $name -Website (& $col $e 'website') -CareersUrl (& $col $e 'careers_url') -City (& $col $e 'city')
        if ($f.Ats -and $f.Ats.Kind -eq 'supported') {
            $work += @{ Company = $name; Url = $f.Ats.Url }
            continue
        }
        $where = @($f.CareersUrl, $f.Website) | Where-Object { $_ } | Select-Object -First 1
        if ($f.Ats) {
            $finderRows += [pscustomobject][ordered]@{ Input = $name; Company = $name; Provider = $f.Ats.Ats; Status = "unsupported ATS ($($f.Ats.Ats))"; Postings = '-'; TitleMatches = '-'; Note = $f.Ats.Url; Entry = '' }
        } else {
            $finderRows += [pscustomobject][ordered]@{ Input = $name; Company = $name; Provider = '-'; Status = $f.Status; Postings = '-'; TitleMatches = '-'; Note = ((@($where, $f.Note) | Where-Object { $_ }) -join '; '); Entry = '' }
        }
    }
}
if ($work.Count -eq 0 -and $finderRows.Count -eq 0) { throw 'Nothing to scout. Pass -Company, -Url, -InputFile or -EmployerCsv.' }

$seen = @{}
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
            $tries += @{ Src = @{ Provider = 'Rippling';   Company = $w.Company; Board = $slug }; Guess = $true }
            $tries += @{ Src = @{ Provider = 'Rippling';   Company = $w.Company; Board = "$slug-careers" }; Guess = $true }
        }
    }

    $found = 0
    foreach ($t in $tries) {
        $src = $t.Src
        $key = Get-SourceKey $src
        $input_ = if ($w.Url) { $w.Url } else { $w.Company }
        if ($seen.ContainsKey($key)) {
            # Two employers can share a board (a parent and its affiliate); offer it once.
            $found++
            [pscustomobject][ordered]@{ Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = 'same board as above'; Postings = '-'; TitleMatches = '-'; Note = "found first for $($seen[$key])"; Entry = '' }
            continue
        }
        if ($have.ContainsKey($key)) {
            $found++
            [pscustomobject][ordered]@{ Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = 'already in profile'; Postings = '-'; TitleMatches = '-'; Note = "as $($have[$key])"; Entry = '' }
            continue
        }
        if ($NoProbe) {
            if ($t.Guess) { continue }
            [pscustomobject][ordered]@{ Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = 'new (not probed)'; Postings = '-'; TitleMatches = '-'; Note = ''; Entry = (Format-SourceEntry $src) }
            $seen[$key] = $src.Company
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
        $seen[$key] = $src.Company
        [pscustomobject][ordered]@{
            Input = $input_; Company = $src.Company; Provider = $src.Provider; Status = $status
            Postings = $(if ($p.Answered) { $p.Postings } else { '-' }); TitleMatches = $(if ($p.Answered) { $matched } else { '-' })
            Note = $p.Note; Entry = $(if ($status -like 'new*') { Format-SourceEntry $src } else { '' })
        }
    }
    if (-not $w.Url -and $found -eq 0) {
        $why = if ($NoProbe) { 'not probed (-NoProbe)' } else { 'no Greenhouse, Lever, Dayforce or Rippling board under the guessed names; find its careers URL' }
        [pscustomobject][ordered]@{ Input = $w.Company; Company = $w.Company; Provider = '-'; Status = 'not found'; Postings = '-'; TitleMatches = '-'; Note = $why; Entry = '' }
    }
}
$results = @($finderRows) + @($results)

$new = @($results | Where-Object { $_.Entry })
if ($new.Count -gt 0) {
    Write-Host "`nPaste into Sources in your local profile (check name guesses first):" -ForegroundColor Cyan
    foreach ($n in $new) { Write-Host "    $($n.Entry)" }
} else {
    Write-Host "`nNo new sources found."
}

if ($OutFile) {
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host "Wrote $OutFile"
}
if ($EmployerCsv) {
    $finderCsv = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $EmployerCsv).Path) ("finder-{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd'))
    $csvArgs = @{ Encoding = 'UTF8' }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $csvArgs['NoTypeInformation'] = $true }
    $results | Select-Object Company, Provider, Status, Postings, TitleMatches, Note, Entry, Input | Export-Csv -LiteralPath $finderCsv @csvArgs
    Write-Host "Wrote $finderCsv"
}

# Pass: the board answered, or the source is already in the profile.
# Skip: nothing to probe (not found, unrecognised URL, -NoProbe).
# Fail: a board named by its URL did not answer.
$sPass = @($results | Where-Object { $_.Status -in 'new', 'new (name guess, check it)', 'already in profile' }).Count
$sFail = @($results | Where-Object { $_.Status -eq 'no answer' }).Count
. (Join-Path $PSScriptRoot 'JobSweep.Summary.ps1')
$sumRows = @($results | Select-Object Company, Provider, Status, Postings, TitleMatches, Note)
$target = "{0} input(s) against {1}" -f $work.Count, (($ProfilePath | ForEach-Object { Split-Path $_ -Leaf }) -join ' + ')
if ($EmployerCsv) {
    # One row per employer is in the CSV; the banner holds the tally.
    $results | Select-Object Company, Provider, Status, Postings, TitleMatches | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $target = "{0} employers from {1} -> {2}" -f @($results).Count, (Split-Path $EmployerCsv -Leaf), (Split-Path $finderCsv -Leaf)
    $sumRows = @($results | Group-Object { if ($_.Status -like 'unsupported ATS*') { 'unsupported ATS' } else { $_.Status } } | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Result = $_.Name; Count = $_.Count; Detail = '' } })
    $tally = @($results | Where-Object { $_.Status -like 'unsupported ATS*' } | Group-Object Provider | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" })
    $read  = @($results | Where-Object { $_.Status -like 'new*' } | Group-Object Provider | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" })
    $sumRows += [pscustomobject]@{ Result = 'new, by provider'; Count = @($results | Where-Object { $_.Status -like 'new*' }).Count; Detail = ($read -join ', ') }
    $sumRows += [pscustomobject]@{ Result = 'unsupported ATS tally'; Count = @($results | Where-Object { $_.Status -like 'unsupported ATS*' }).Count; Detail = ($tally -join ', ') }
}
Write-JobSweepSummary -Script 'Find-JobSweepSources.ps1' -Target $target `
    -Rows $sumRows `
    -Pass $sPass -Fail $sFail -Skip ($results.Count - $sPass - $sFail)
