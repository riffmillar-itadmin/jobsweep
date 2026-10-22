<#
.SYNOPSIS
    Collects IT job postings from first-party employer boards, screens them against
    your own title and geography rules, and reports only postings not seen on a prior run.

.DESCRIPTION
    Mechanical layer of the job sweep. Sources ONLY first-party employer boards whose robots.txt permits it --
    no LinkedIn, Indeed, Dice, Glassdoor or NEOGOV/governmentjobs. Those are hostile to scripting, against
    their terms, and are the sources that produce stale listings that outlive the
    requisition.

    Every run writes a timestamped log to <OutputRoot>\Sweeps\logs and exits with a
    status code, so an unattended failure is visible in Task Scheduler's Last Run
    Result and diagnosable from the log afterwards.

    Writes three files per run into <OutputRoot>\Sweeps:
        sweep-<date>-candidates.csv   postings that passed screening (summary)
        sweep-<date>-candidates.json  the same postings WITH full description text
        sweep-<date>-screened.csv     postings that were filtered out, and why

    The .json is the file to hand to Claude for the judgement pass -- it carries the
    full requirement text, so nothing needs re-fetching.

    State lives in <OutputRoot>\Sweeps\_seen.json. Requisitions already in state are
    not reported again.

.PARAMETER OutputRoot
    Folder to write Sweeps\ into. Overrides OutputRoot in your local profile; with
    neither set, Sweeps\ goes beside this script.

.PARAMETER Source
    Run only one provider: Greenhouse, Lever, Workday, Microsoft. Omit for all.

.PARAMETER DryRun
    Fetch, screen and report, but do NOT update the seen-state file. Safe to re-run.

.PARAMETER SkipDetail
    Skip per-posting description fetches. Much faster, but degree and driver's-licence
    screening cannot run, so everything lands in candidates for manual reading.

.PARAMETER MaxAttempts
    Attempts per HTTP request before giving up. Retries cover HTTP 429, 408 and 5xx
    plus bare network faults, with exponential backoff that honours Retry-After.
    Default 5.

.PARAMETER LogRetentionDays
    Age at which old log files are deleted from Sweeps\logs. Default 30.

.EXAMPLE
    .\Invoke-JobSweep.ps1 -Source Greenhouse -DryRun
    Smoke-test one provider without touching state. Start here.

.EXAMPLE
    .\Invoke-JobSweep.ps1
    Full run. Suitable for a scheduled task.

.NOTES
    Written 2026-09-07.
    Revised 2026-09-08 (morning): fixed a StrictMode .Count fault, dropped the NEOGOV
    provider on robots.txt grounds, repointed Microsoft at the current
    apply.careers.microsoft.com/api/pcsx endpoints, added progress output.
    Revised 2026-09-08 (after a scheduled run hit HTTP 429 on Microsoft): every request
    now retries with exponential backoff and honours Retry-After, Microsoft is throttled
    to 1500 ms between calls, everything is written to a timestamped log under
    Sweeps\logs, and the script exits with a code Task Scheduler can report.

    EXIT CODES
        0  clean run
        1  finished, but with warnings or a provider failure -- read the log
        2  aborted on an unhandled error -- read the log

    Revised 2026-09-09: ADP WorkforceNow provider added (Lighthouse -- legal technology),
    plus information-governance and eDiscovery title keywords.

    1.1.0 (2026-10-20): default OutputRoot changed to a new folder.
    1.2.0 (2026-10-20): no personal path in the script. OutputRoot is now a local
    profile key (%VAR% expanded); the fallback is the script's own folder.
    1.2.1 (2026-10-20): a profile that fails to load now reports its own error, logs
    beside the script and exits 2, instead of "Write-Log is not recognized".
    1.2.2 (2026-10-20): changelog wording only.
    1.2.3 (2026-10-20): Test-JobSweepFilters.ps1 -BothEditions runs the suite under
    Windows PowerShell 5.1 and PowerShell 7, failing if either fails or is missing.
    1.3.0 (2026-10-21): prompts\build-tracking-board.md, a Claude prompt that turns
    the candidates .json files and your criteria into a job tracking board.
    1.3.1 (2026-10-21): GitHub Actions workflow runs the filter suite under 5.1 and
    7 on every push to main and every pull request.
    1.3.2 (2026-10-21): workflow moves to actions/checkout@v7 (Node 24); v4 ran on
    the deprecated Node 20.
    1.3.3 (2026-10-21): build-tracking-board.md gains three rules from retrofitting a
    real board -- date added never after date applied, tags wrap at phone width,
    and a strong-match threshold check after scoring.
    1.3.4 (2026-10-21): CLAUDE.local.md is gitignored -- personal Claude Code
    instructions with local paths stay out of the public repo.

    Greenhouse, Workday and Microsoft dry runs verified working 2026-09-08.
    Requires PowerShell 5.1 or later. No modules, no authentication.
#>

[CmdletBinding()]
param(
    # Resolved after the profiles load: this parameter, else OutputRoot in a
    # profile, else the folder this script lives in.
    [string] $OutputRoot,
    [ValidateSet('Greenhouse','Lever','Workday','Microsoft','ADP','iCIMS','UltiPro')]
    [string] $Source,
    [switch] $DryRun,
    [switch] $SkipDetail,
    [int]    $MaxAttempts = 5,
    [int]    $WorkdayMaxPostings = 2000,
    [int]    $LogRetentionDays = 30,

    # One or more .psd1 profile files overlaid onto the built-in defaults,
    # applied in order. Defaults to JobSweep.targeting.psd1 plus
    # JobSweep.local.psd1 sitting beside this script.
    [string[]] $ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# A courteous User-Agent is good manners to an API you are polling, and some
# providers rate-limit an unidentified client harder. It is also the one string in
# this script that leaves your machine on every request, so it belongs in your
# LOCAL profile, not here. Set UserAgent there; this generic default is the fallback.
$JobSweepVersion = '1.3.4'
$UserAgent = "JobSweep/$JobSweepVersion (+https://github.com/riffmillar-itadmin/jobsweep)"
$PolitenessMs = 400     # default pause between requests
$MaxPerQuery  = 60      # Microsoft: stop after this many results per query/location combo

# Run state -- drives the summary and the exit code Task Scheduler reports
$script:RunErrors   = 0
$script:RunWarnings = 0
$script:RunStart    = Get-Date
$script:LogFile     = $null
$script:ExitCode    = 0
$script:Throttle    = $PolitenessMs   # per-provider override, set in the source loop

# ============================================================================
#  CONFIGURATION -- edit this block, not the logic below
# ============================================================================

$Config = @{

    # ---------------------------------------------------------------------
    # BUILT-IN DEFAULTS. Generic signal knowledge, not a search profile:
    # how to recognise a remote posting and how to tell an operations role
    # from a developer one. Reusable by anyone; no personal tuning here.
    #
    # The search profile -- titles, geography, employers -- is overlaid from
    # the .psd1 files at run time by Merge-JobSweepProfile below. A key
    # present in a profile REPLACES the default wholesale, so a list can be
    # shortened as well as extended.
    # ---------------------------------------------------------------------

    RemotePatterns = @(
        '\bremote\b','work from home','\bwfh\b','\bvirtual\b','\banywhere\b',
        'home[- ]based','telecommut','distributed'
    )

    # ---- REMOTE STATED IN THE TITLE, added 2026-09-21.
    #
    # Option Care Health files every req against its Springfield, IL head office,
    # including "Engineer, Endpoint - Remote". The location field said Springfield
    # and nothing else, so the posting died on "location out of scope" -- a fully
    # remote req squarely in the target title family, screened out by a head-office
    # address. Employers on Workday do this routinely; the title is the only place
    # the remote arrangement appears in the list payload.
    #
    # This list is DELIBERATELY NARROWER than RemotePatterns. A location string is
    # a place and reads unambiguously; a title is a job name, and three of the
    # RemotePatterns entries are ordinary title words -- "Distributed Systems
    # Engineer" is not a remote job, "Virtual Desktop Engineer" is not a remote
    # job, and "anywhere" turns up in marketing copy. Only phrases that can ONLY
    # mean a work arrangement belong here.
    #
    # Measured before adding: across the screened lists of 09-09, 09-18 and 09-21
    # (800 rows) this rescues exactly 1 posting -- the Option Care endpoint req --
    # and creates 0 false positives. The other title matches were all "Virtual
    # Family Nurse Practitioner" variants, which die on the 'nurse' exclude before
    # the location screen ever runs.
    RemoteTitlePatterns = @(
        '\bremote\b','work from home','\bwfh\b','home[- ]based','telecommut'
    )

    # ---- DEVELOPER-IN-DISGUISE SCREEN, added 2026-09-10.
    #
    # Two leads in a fortnight carried a systems title over a software-engineering
    # job: Overland AI's "Junior Systems Administrator" (Python and C++) and UW's
    # "Senior Systems Engineer" REQ-0000134242-1. TitleExclude cannot catch these --
    # the title is one the include list actively wants -- so the posting TEXT has to.
    #
    # Scored, not absolute. A sysadmin posting legitimately mentions scripting and
    # code review; a developer posting stacks several of these. Two or more distinct
    # signals raises a CHECK, and the matched signals are named in the reason so you
    # can judge rather than trust a verdict.
    # IT-context test for the compliance title family, added 2026-09-30.
    # 'compliance analyst', 'controls analyst' and '\bgrc\b' in TitleInclude ran
    # 2-for-2 noise -- financial and regulatory compliance reqs, not IT compliance.
    # Rather than drop the keywords (which would bin the genuine hits), the title
    # keeps the posting alive and the DESCRIPTION has to earn it. Gate runs in the
    # post-detail re-screen loop, same place as Test-PhysicalDemand.
    ItContextSignals = @(
        'information (technology|security|systems)', '\bIT\b', '\bICT\b',
        'cyber', 'infosec', 'information assurance',
        'NIST', '800-171', '800-53', '\bCMMC\b', 'ISO 27001', 'SOC 2', '\bFedRAMP\b',
        'HIPAA Security Rule', '\bCJIS\b', '\bITAR\b', '\bPCI[ -]?DSS\b',
        'access (control|review|certification)', 'identity', 'least privilege',
        'vulnerabilit', 'patch', 'endpoint', 'encryption', 'SIEM',
        'Active Directory', '\bEntra\b', 'Azure', 'Microsoft 365', '\bM365\b',
        'system(s)? (hardening|baseline|configuration)',
        'audit (log|trail|evidence)', 'control (owner|evidence|testing|mapping)',
        'security (control|posture|framework|policy|awareness)'
    )

    DeveloperSignals = [ordered]@{
        'software development lifecycle' = '(?i)software development life\s?cycle|\bSDLC\b'
        'writes production code'         = '(?i)(writ\w+|develop\w+|ship\w+)[^.]{0,30}production[- ]?(code|software|services)'
        'designs and builds software'    = '(?i)design\w*\s+and\s+(develop|implement|build)\w*\s+(software|applications|services|features)'
        # NO TRAILING \b HERE. '+' and '#' are non-word characters, so \b after c\+\+
        # or c# can never match and the whole branch would be dead -- found by test
        # on 2026-09-10, which is exactly the silent-rule failure this suite is for.
        'compiled-language proficiency'  = '(?i)proficien\w+[^.]{0,40}(\bc\+\+|\bjava\b|\bgolang\b|\bgo\b|\brust\b|\bscala\b|\bkotlin\b|\bc#)'
        'years of software engineering'  = '(?i)\d\+?\s*years?[^.]{0,40}software\s+(development|engineering)'
        'source control workflow'        = '(?i)\bpull requests?\b|\bcode reviews?\b|\bmerge requests?\b'
        'test-driven development'        = '(?i)\bunit tests?\b|test[- ]driven|\bTDD\b'
        'front or back end'              = '(?i)\bfull[- ]stack\b|\bfront[- ]end\b|\bback[- ]end\b'
        'builds APIs'                    = '(?i)(design|develop|build|implement)\w*[^.]{0,25}\b(rest|graphql)\b[^.]{0,15}api'
        'computer science degree'        = '(?i)degree in computer science'
    }

    # ---- REMOTE VETTING, added 2026-09-10.
    #
    # Remote reqs fail in ways an onsite req does not, and the location string never
    # says so -- it has to come out of the posting text.

    # ABSOLUTE. A remote role that will not hire in Washington is not a lead, in the
    # same class as the driver's-licence requirement.
    RemoteFlag = [ordered]@{
        'CHECK: Eastern-hours coverage stated -- that is a 5-6am start here' =
            @('\beastern (?:time|standard time|daylight time)\b','\bET\s+hours\b','\bEST\b','\bEDT\b','east coast hours')
        'CHECK: remote in name only -- requires living near an office' =
            @('within\s+commuting\s+distance','must\s+resid[e]?\s+(?:in|within|near)','commutable\s+distance',
              'hybrid[^.]{0,40}\d\s*days?\s*(?:per|a)\s*week','required\s+to\s+be\s+onsite')
        'CHECK: relocation expected' = @('relocat(?:e|ion)\s+(?:is\s+)?(?:required|expected)')
        'CHECK: travel requirement stated' = @('travel[^.]{0,30}\d{2}\s*%','up\s+to\s+\d{2}\s*%\s+travel')
    }

    # ---- GEOGRAPHY THAT CANNOT BE DECIDED FROM THE STRING ----
    #
    # Both default to empty, which reproduces the behaviour of a profile that
    # does not set them: nothing is flagged. Your LOCAL profile populates them.
    # They live in the defaults so every lookup below is safe under StrictMode
    # whatever a profile omits.

    # Cities that are only PARTLY in scope. A posting carries a city and never a
    # street address, so these cannot be screened either way -- they are flagged.
    # Renamed from EastsideCheck on 2026-10-12: that name described a REGION while
    # the values were CITIES and the question asked was a street address.
    WorksiteCheck     = @()
    WorksiteCheckNote = ''

    # Phrases that name a REGION rather than a city -- "Greater Seattle Area",
    # "Puget Sound". No city-level rule can judge these, in either direction.
    RegionCheck       = @()
    RegionCheckNote   = ''

}

function Merge-JobSweepProfile {
    <# Overlays profile data files onto the built-in defaults and returns the
       merged config.

       REPLACE-BY-KEY, not deep-merge: a key present in a profile replaces the
       default wholesale, so a list can be SHORTENED as well as extended. Files
       apply in order, so a later one wins.

       Import-PowerShellDataFile parses data only and will not execute code in a
       profile, which is the point. Note that it REJECTS [ordered]@{}, so any key
       whose order is semantic has to stay in the defaults above -- RemoteFlag and
       DeveloperSignals both do. #>
    param(
        [Parameter(Mandatory)][hashtable] $Defaults,
        [Parameter(Mandatory)][string[]]  $ProfilePath,
        [string[]] $RequireKeys = @('TitleInclude','TitleExclude','LocationInclude','Sources'),

        # Keys a profile may set that have NO entry in the defaults above. Every
        # other valid key is a default key. Adding a profile setting means adding
        # it here or to the defaults -- see the unknown-key check below for why.
        [string[]] $KnownKeys = @(
            'TitleInclude','TitleProtect','TitleExclude',
            'LocationExclude','CommuteExclude','LocationInclude',
            'RemoteBlock','LiftingLimitLb','Sources','OutputRoot'
        )
    )

    $merged = @{}
    foreach ($k in $Defaults.Keys) { $merged[$k] = $Defaults[$k] }

    $validKeys = @($Defaults.Keys) + $KnownKeys

    foreach ($path in $ProfilePath) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Profile not found: $path" }
        $data = Import-PowerShellDataFile -LiteralPath $path

        # A RENAME MUST NOT SILENTLY DISABLE A FILTER. Added 2026-10-12.
        #
        # Merging is replace-by-key, so an unrecognised key was simply carried into
        # $Config and never read. Rename a key in this script, forget the profile,
        # and the filter stops firing with no error anywhere -- the screening just
        # quietly gets weaker. That is the same silent-wrong-answer shape as an
        # empty TitleInclude, and it is cheap to close: anything not in the schema
        # is a typo or a stale name, and both deserve to stop the run.
        $unknown = @($data.Keys | Where-Object { $_ -notin $validKeys })
        if ($unknown.Count -gt 0) {
            throw ("Profile '{0}' has unrecognised key(s): {1}.`n  Valid keys: {2}" -f `
                   $path, ($unknown -join ', '), (($validKeys | Sort-Object) -join ', '))
        }

        foreach ($k in $data.Keys) { $merged[$k] = $data[$k] }
    }

    # FAIL LOUDLY, NEVER QUIETLY. Without this, a profile that did not load leaves
    # TitleInclude empty, Test-TitleMatch then matches nothing, and the run reports
    # zero candidates and a normal-looking quiet day. That is a silent wrong answer,
    # which is the worst failure class this toolset has shipped.
    $missing = @($RequireKeys | Where-Object {
        -not $merged.ContainsKey($_) -or @($merged[$_]).Count -eq 0 })
    if ($missing.Count -gt 0) {
        throw ("Profile incomplete -- missing or empty: {0}. Checked: {1}" -f `
               ($missing -join ', '), ($ProfilePath -join ', '))
    }

    $merged
}

# ============================================================================
#  LOGGING AND RETRY
# ============================================================================

# Write-Log and the startup helpers are defined BEFORE the profiles load. The trap
# in MAIN covers the whole script, and when it fired on a profile error with
# Write-Log not yet defined, all anyone saw was "Write-Log is not recognized" --
# the real error, a missing profile or an unknown key, was swallowed. Fixed 2026-10-20.
function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string] $Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "$stamp  [$($Level.PadRight(5))] $Message"
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
        catch { }   # never let logging break the run
    }
    switch ($Level) {
        'ERROR' { $script:RunErrors++;   Write-Host $Message -ForegroundColor Red }
        'WARN'  { $script:RunWarnings++; Write-Host $Message -ForegroundColor Yellow }
        'OK'    { Write-Host $Message -ForegroundColor Green }
        'STEP'  { Write-Host $Message -ForegroundColor Cyan }
        default { Write-Host $Message -ForegroundColor DarkGray }
    }
}

function Open-FallbackLog {
    <# Before the output root is known there is no Sweeps\logs, so a run that dies
       at startup logs beside the script instead. There is still a record of why. #>
    param([string] $Stamp)
    $fallbackDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'logs' } else { Join-Path $env:TEMP 'JobSweep-logs' }
    try {
        if (-not (Test-Path $fallbackDir)) { New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null }
        $script:LogFile = Join-Path $fallbackDir ("sweep-{0}.log" -f $Stamp)
    } catch { }
}

function Complete-RunEarly {
    Write-Log ('-' * 62)
    Write-Log 'Aborted during startup. Exit code 2.' 'ERROR'
}

$logStamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'

# Profiles live beside this script unless -ProfilePath says otherwise.
if (-not $ProfilePath) {
    $here = Split-Path -Parent $PSCommandPath
    $ProfilePath = @(
        (Join-Path $here 'JobSweep.targeting.psd1')
        (Join-Path $here 'JobSweep.local.psd1')
    )
}

try {
    $Config = Merge-JobSweepProfile -Defaults $Config -ProfilePath $ProfilePath

    # Where you keep your sweeps is personal, so it lives in the LOCAL profile, not
    # here. A .psd1 cannot read $env:, so %VAR% references in the profile value are
    # expanded. With neither set, output lands beside the script, where Sweeps\ is
    # gitignored.
    if (-not $PSBoundParameters.ContainsKey('OutputRoot')) {
        $OutputRoot = if ($Config.ContainsKey('OutputRoot') -and $Config.OutputRoot) {
            [Environment]::ExpandEnvironmentVariables([string]$Config.OutputRoot)
        } else {
            Split-Path -Parent $PSCommandPath
        }
    }
} catch {
    Open-FallbackLog $logStamp
    Write-Log ('=' * 62)
    Write-Log "Profile failed to load: $($_.Exception.Message)" 'ERROR'
    Write-Log "Profiles: $($ProfilePath -join ', ')" 'ERROR'
    Complete-RunEarly
    exit 2
}

function Get-HttpFailure {
    <# Pulls status code and Retry-After out of a terminating web error on both
       PowerShell 5.1 (HttpWebResponse) and 7+ (HttpResponseMessage). #>
    param($ErrorRecord)
    $result = [pscustomobject]@{ Status = 0; RetryAfter = 0 }
    try {
        $resp = $ErrorRecord.Exception.Response
        if (-not $resp) { return $result }

        try { $result.Status = [int]$resp.StatusCode } catch { }

        # PS 7 / .NET: Headers is a collection of KeyValuePair
        try {
            $ra = $resp.Headers | Where-Object { $_.Key -eq 'Retry-After' } | Select-Object -First 1
            if ($ra) { $result.RetryAfter = [int]([string]($ra.Value | Select-Object -First 1)) }
        } catch { }
        # PS 5.1 / WebResponse: Headers is a NameValueCollection
        if ($result.RetryAfter -eq 0) {
            try {
                $v = $resp.Headers['Retry-After']
                if ($v) { $result.RetryAfter = [int]$v }
            } catch { }
        }
    } catch { }
    return $result
}

function Invoke-WithRetry {
    <# Retries 429 / 408 / 5xx and bare network faults with exponential backoff,
       honouring Retry-After when the server sends one. Anything else rethrows. #>
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [string] $Label = 'request'
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $Action
        } catch {
            $f = Get-HttpFailure $_
            $transient = ($f.Status -eq 429 -or $f.Status -eq 408 -or $f.Status -eq 0 -or
                          ($f.Status -ge 500 -and $f.Status -le 599))
            if (-not $transient -or $attempt -ge $MaxAttempts) {
                if ($f.Status -eq 429) {
                    Write-Log "$Label : rate limited (429) and out of retries after $attempt attempts" 'ERROR'
                }
                throw
            }
            $wait = if ($f.RetryAfter -gt 0) { $f.RetryAfter } else { [int][math]::Min(120, [math]::Pow(2, $attempt)) }
            $what = if ($f.Status -gt 0) { "HTTP $($f.Status)" } else { 'network fault' }
            Write-Log "$Label : $what on attempt $attempt of $MaxAttempts -- waiting $wait s" 'WARN'
            Start-Sleep -Seconds $wait
        }
    }
}

# ============================================================================
#  HELPERS
# ============================================================================

function Convert-HtmlToText {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $t = $Html
    $t = [regex]::Replace($t, '(?is)<(script|style).*?</\1>', ' ')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>|</p>|</li>|</div>|</tr>', "`n")
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '[ \t\r\f\v]+', ' ')
    $t = [regex]::Replace($t, ' ?\n ?', "`n")
    $t = [regex]::Replace($t, '\n{3,}', "`n`n")
    return $t.Trim()
}

function Invoke-Json {
    param([string]$Uri, [string]$Method = 'Get', $Body, [string]$Label)
    if (-not $Label) { $Label = ($Uri -split '\?')[0] }
    $p = @{ Uri = $Uri; Method = $Method; UserAgent = $UserAgent; TimeoutSec = 45 }
    if ($null -ne $Body) {
        $p['Body']        = ($Body | ConvertTo-Json -Depth 6 -Compress)
        $p['ContentType'] = 'application/json'
    }
    return Invoke-WithRetry -Label $Label -Action { Invoke-RestMethod @p }
}

function Invoke-Html {
    param([string]$Uri)
    return (Invoke-WithRetry -Label (($Uri -split '\?')[0]) -Action {
        Invoke-WebRequest -Uri $Uri -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 45
    }).Content
}

function Get-DegreeFlag {
    <# Returns: none | equivalency | hard | unknown #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    $deg = '(?i)(bachelor|b\.?s\.?/b\.?a\.?|\bBA/BS\b|\bBS/BA\b|four[- ]year degree|undergraduate degree)'
    if ($Text -notmatch $deg) { return 'none' }
    $equiv = '(?i)(or equivalent|equivalent (work )?experience|equivalent combination|' +
             'in lieu of|may be substituted|or a combination of education)'
    if ($Text -match $equiv) { return 'equivalency' }
    return 'hard'
}

function Test-LicenceRequired {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match "(?i)(driver'?s?\s+licen[sc]e|valid\s+licen[sc]e\s+to\s+drive|driving\s+record|driving\s+history|reliable\s+transportation)")
}

function Test-PhysicalDemand {
    <# Screens out postings whose physical requirements exceed a threshold you set.

       TWO SEPARATE GATES:
         1. a stated lifting figure above $LiftingLimitLb
         2. unambiguous physically-demanding-environment language
       A single clause can fail both -- "Ability to lift and rack equipment up to 50 lbs.
       and work in physically demanding data center environments" is the canonical case.

       WHY A STATED FIGURE MUST EXCEED THE LIMIT BEFORE IT COUNTS: accessibility boilerplate
       rides along on plenty of ordinary desk jobs ("must be able to lift up to 10 pounds",
       "lift up to 20 lbs occasionally"). Screening those out would cost real leads for
       nothing, so only a number ABOVE the limit is a hit.

       SET YOUR OWN THRESHOLD in your local profile: LiftingLimitLb = <n>. The shipped
       default is deliberately permissive, because a limit that is too HIGH over-includes
       and sends a borderline posting to you, while one that is too LOW silently bins real
       leads. Failing open is the safe direction here.

       Returns objects, not a bool, so the caller can hard-screen the unambiguous ones and
       merely CHECK-flag the phrases that are often boilerplate -- the same treatment the
       degree flag gets, and for the same reason: a wrongly screened lead costs more than
       a wrongly kept one. #>
    param([string]$Text, [int]$LiftingLimitLb = 0)
    $hits = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $hits }

    # Resolve the threshold HERE, not in the param default. A param default that
    # reaches for $Config throws when $Config is out of scope -- and a thrown
    # default leaves the limit at 0, which screens out EVERY stated figure. That is
    # a silent wrong answer, the failure class this toolset exists to avoid. Fall
    # back to a permissive default instead, so a missing profile over-includes.
    if ($LiftingLimitLb -le 0) {
        $LiftingLimitLb =
            if ($Config -and $Config.ContainsKey('LiftingLimitLb') -and [int]$Config.LiftingLimitLb -gt 0) {
                [int]$Config.LiftingLimitLb
            } else { 50 }
    }

    foreach ($m in [regex]::Matches($Text, "(?i)\b(?:lift|carry|move|push|pull)\w*\b[^.;`r`n]{0,60}?(\d{2,3})\s*\+?\s*(?:lbs?\b|pounds?\b)")) {
        $w = 0
        if ([int]::TryParse($m.Groups[1].Value, [ref]$w) -and $w -gt $LiftingLimitLb) {
            $hits += [pscustomobject]@{ Level='out'; Why=("lifting {0} lb stated, limit is {1}" -f $w, $LiftingLimitLb) }
        }
    }
    # Unambiguous environment language -- these are not ADA boilerplate.
    foreach ($p in @('physically demanding','physically-demanding',
                     'rack(?:ing)?\s+and\s+stack(?:ing)?','rack\s+and\s+cable')) {
        if ($Text -match "(?i)$p") { $hits += [pscustomobject]@{ Level='out'; Why=("physical environment: '{0}'" -f $Matches[0].Trim()) } }
    }
    # Often boilerplate, sometimes real. Flag, do not drop.
    foreach ($p in @('climb(?:ing)?\s+(?:a\s+)?ladders?','work(?:ing)?\s+at\s+heights',
                     'confined\s+spaces','stand(?:ing)?\s+for\s+(?:long|extended|prolonged)',
                     'on\s+your\s+feet\s+for')) {
        if ($Text -match "(?i)$p") { $hits += [pscustomobject]@{ Level='check'; Why=("possible physical demand: '{0}'" -f $Matches[0].Trim()) } }
    }
    return $hits
}

function Get-PayRange {
    <# Two branches, tried in order. Widened 2026-09-20 after the Sept 18 run left the Pay
       column BLANK on two hourly rows ($34.35-$46.20/hr) while matching a monthly-salary
       band of $8,960-$12,120 fine.

       WHY IT MISSED THEM: branch 1 requires [\d,]{3,} -- three or more digit characters --
       on BOTH sides, so every hourly band under $100 fell through. $32-$46/hr, $60-70/hr
       and $34.35 to $46.20 are all two-digit figures. It only ever UNDER-reported, never
       reported a wrong number, which is why it went unnoticed for the whole search.

       WHY BRANCH 1 KEEPS ITS WIDTH REQUIREMENT: it is what stops prose matching. A posting
       that says "a $5 to $10 copay" or "$10 copays" must not produce a pay range. So the
       narrow figures are allowed ONLY in branch 2, and only when an HOURLY UNIT follows --
       the unit is mandatory there, not optional as it is in branch 1. #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $patterns = @(
        # 1. salary scale: three or more digits a side, unit optional
        '\$\s?[\d,]{3,}(\.\d{2})?\s*(-|\u2013|to)\s*\$?\s?[\d,]{3,}(\.\d{2})?\s*(per hour|hourly|/ ?hr|annually|per year|/ ?yr)?',
        # 2. hourly band: one to three digits a side, UNIT REQUIRED
        '\$\s?\d{1,3}(\.\d{2})?\s*(-|\u2013|to)\s*\$?\s?\d{1,3}(\.\d{2})?\s*(/ ?hr\b|/ ?hour\b|per hour\b|an hour\b|hourly\b)'
    )

    foreach ($p in $patterns) {
        $m = [regex]::Match($Text, $p)
        if ($m.Success) {
            # trailing comma: [\d,] can swallow the one after "$180,000," in running prose
            return (($m.Value -replace '\s+', ' ').Trim() -replace '[,\s]+$', '')
        }
    }
    return ''
}

function Test-TitleMatch {
    param([string]$Title)
    foreach ($p in $Config.TitleProtect) { if ($Title -match "(?i)$p") { return @{ Ok=$true;  Reason="title protected: $p" } } }
    foreach ($p in $Config.TitleExclude) { if ($Title -match "(?i)$p") { return @{ Ok=$false; Reason="title excluded: $p" } } }
    foreach ($p in $Config.TitleInclude) { if ($Title -match "(?i)$p") { return @{ Ok=$true;  Reason="title matched: $p" } } }
    return @{ Ok=$false; Reason='title did not match any target keyword' }
}

function Test-IsRemote {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return $false }
    foreach ($p in $Config.RemotePatterns) { if ($Location -match "(?i)$p") { return $true } }
    return $false
}

function Test-IsRemoteTitle {
    <# True when the TITLE states a remote arrangement. See RemoteTitlePatterns
       for why that list is narrower than RemotePatterns. Added 2026-09-21. #>
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    foreach ($p in $Config.RemoteTitlePatterns) { if ($Title -match "(?i)$p") { return $true } }
    return $false
}

function Test-IsRequisitionId {
    <# True when a Workday bulletField actually looks like a requisition id rather
       than a location list, a posting date or a time type. See Get-WorkdayJobs for
       why the first bullet cannot be trusted. Added 2026-09-25. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    if ($v.Length -gt 40) { return $false }
    if ($v -match '[,|]') { return $false }
    if ($v -notmatch '\d') { return $false }
    if (@($v -split '\s+').Count -gt 3) { return $false }
    # "5 Days Ago", "2 Locations", "Posted Today" all carry a digit and fit in three
    # words, so the shape test alone is not enough to tell them from JR78095.
    if ($v -match '(?i)\b(days?|hours?|weeks?|months?|ago|posted|locations?|remote|onsite|hybrid|full|part|time)\b') { return $false }
    return $true
}

function Test-LooksLikeLocationList {
    <# True when a Workday bulletField is carrying place names. Deliberately narrow:
       a bullet that is neither a requisition id nor a location is dropped rather
       than folded into either field. Added 2026-09-25. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    if ($v -match '(?i)^\s*\d+\s+locations?\s*$') { return $true }
    if ($v -match '\|') { return $true }
    if ($v -match ',\s*[A-Za-z]{2}\b') { return $true }
    if ($v -match '(?i),\s*(United States|USA|Canada)\b') { return $true }
    if ($v -match '(?i)^\s*(remote|hybrid|on-?site)\s*$') { return $true }
    return $false
}

function Resolve-WorkdayBullets {
    <# Splits a Workday bulletFields array into the requisition id and any location
       text it is carrying, given the locationsText already read from the row.
       Returns @{ ReqId=<string or ''>; Location=<string> }. Added 2026-09-25.

       Kept as its own function so the filter suite can test the real mapping rather
       than a copy of it -- this is the code path that lost Jackson Lewis. #>
    param([object[]]$Bullets, [string]$Location)
    $out = @{ ReqId = ''; Location = $Location }
    $clean = @($Bullets |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { ([string]$_).Trim() })
    if ($clean.Count -eq 0) { return $out }

    $ids = @($clean | Where-Object { Test-IsRequisitionId $_ })
    if ($ids.Count -gt 0) { $out.ReqId = $ids[0] }

    $places = @($clean | Where-Object {
        -not (Test-IsRequisitionId $_) -and (Test-LooksLikeLocationList $_) })
    if ($places.Count -gt 0) {
        $extra = ($places -join ' | ')
        if ([string]::IsNullOrWhiteSpace($out.Location)) { $out.Location = $extra }
        elseif ($out.Location -ne $extra) { $out.Location = "$($out.Location) | $extra" }
    }
    return $out
}

function Test-LocationMatch {
    param([string]$Location, [string]$Title)
    if ([string]::IsNullOrWhiteSpace($Location)) { return @{ Ok=$true; Reason='location not stated'; Check='' } }

    # A MALFORMED LOCATION IS UNKNOWN, NOT OUT OF AREA. Added 2026-09-25.
    #
    # iCIMS served Cayuse Holdings' Sr Microsoft Engineer with the literal stub "US-".
    # That is not null and not whitespace, so it fell past every check below to the
    # out-of-scope return at the bottom and the req was screened out as though it named
    # a city in another state. It was remote, $75-85/hr, and dead centre on the
    # requirements -- the best lead of that week, lost to a punctuation artefact.
    #
    # A string that names no place cannot disqualify one. Bare-country and placeholder
    # values go to the Remote flag and the posting body with a CHECK attached, the same
    # way a blank field already did.
    $bare = ($Location -replace '[^A-Za-z]', '').ToUpperInvariant()
    if ($bare -in @('', 'US', 'USA', 'UNITEDSTATES', 'NA', 'TBD', 'VARIOUS', 'MULTIPLE', 'ANY', 'NATIONWIDE')) {
        return @{ Ok=$true; Reason="location field unusable -- kept for judgement: $Location"
                  Check='CHECK: the location field was a stub; confirm the worksite from the posting body' }
    }

    # Always disqualifying, remote or not. Checked BEFORE the title, so a title
    # that says Remote cannot rescue a req filed against Bengaluru or London.
    foreach ($p in $Config.LocationExclude) {
        if ($Location -match "(?i)$([regex]::Escape($p))") { return @{ Ok=$false; Reason="location excluded: $p"; Check='' } }
    }

    # Remote skips the commute rules entirely -- Test-RemoteFlags screens it instead
    if (Test-IsRemote $Location) { return @{ Ok=$true; Reason='remote'; Check='' } }
    if (Test-IsRemoteTitle $Title) {
        return @{ Ok=$true; Reason="remote stated in title -- location field says $Location"; Check='' }
    }

    # MULTI-LOCATION REQS ARE UNKNOWN, NOT DISQUALIFIED. Added 2026-09-19.
    #
    # The loops below return on the FIRST disqualifying city anywhere in the string, so
    # a req posted to every office -- "Atlanta, GA | Washington, DC | Chicago, IL |
    # New York, NY" -- died on the DC in the middle. That is how a REMOTE req on a
    # multi-office listing was dropped on 2026-09-18, on a day it was worth reading.
    # An earlier note had predicted this and called it latent; it was not latent, it
    # was live and costing real leads.
    #
    # A list of cities tells us the employer will place this somewhere, not that it is
    # out of reach, so it goes to THE READER rather than to the screened pile. Single-city
    # postings are unaffected: "Palo Alto, CA" is still correctly dropped.
    $cityCount = @($Location -split '\s*\|\s*' | Where-Object { $_.Trim() }).Count
    if ($cityCount -gt 1 -or $Location -match '^\s*\d+\s+Locations?\s*$') {
        return @{ Ok=$true; Reason="multiple locations -- kept for judgement: $Location"; Check='' }
    }

    foreach ($p in $Config.CommuteExclude) {
        if ($Location -match "(?i)$([regex]::Escape($p))") { return @{ Ok=$false; Reason="not commutable: $p"; Check='' } }
    }
    # A REGION IS A QUESTION, NOT AN ANSWER. Added 2026-10-12 after measuring the
    # real filter against real strings rather than reasoning about it.
    #
    # "Greater Seattle Area" matched LocationInclude on the substring 'seattle'
    # and sailed through with NO FLAG -- while CommuteExclude correctly rejects
    # Everett and Tacoma, which are INSIDE that region. An employer naming the
    # city got screened; the same employer naming the region got waved through.
    # The mirror case was worse: "Eastside, WA" matched nothing and was DROPPED
    # outright -- by a filter that was at the time called EastsideCheck.
    #
    # Two silent failures in opposite directions, which is the class this toolset
    # exists to prevent. Ordering is load-bearing: AFTER CommuteExclude, because a
    # region phrase naming an excluded city is fairly dropped; BEFORE
    # LocationInclude, so a substring match cannot pre-empt the question.
    foreach ($r in $Config.RegionCheck) {
        if ($Location -match "(?i)$([regex]::Escape($r))") {
            $note = if ($Config.RegionCheckNote) { $Config.RegionCheckNote }
                    else { 'a region was named instead of a city -- confirm the worksite' }
            return @{ Ok=$true; Reason="region named, not a city -- kept for judgement: $Location"
                      Check="CHECK: $note" }
        }
    }

    foreach ($p in $Config.LocationInclude) {
        if ($Location -match "(?i)$([regex]::Escape($p))") {
            # A CITY CAN BE TOO COARSE TO DECIDE FROM. These are in scope on paper,
            # but only part of each is reachable and the worksite address settles
            # it, so they travel with a question rather than a verdict.
            foreach ($e in $Config.WorksiteCheck) {
                if ($Location -match "(?i)\b$([regex]::Escape($e))\b") {
                    $note = if ($Config.WorksiteCheckNote) { $Config.WorksiteCheckNote }
                            else { 'this city is only partly in scope -- confirm the worksite street address' }
                    return @{ Ok=$true; Reason='location in scope'; Check="CHECK: $note" }
                }
            }
            return @{ Ok=$true;  Reason='location in scope'; Check='' }
        }
    }
    return @{ Ok=$false; Reason="location out of scope: $Location"; Check='' }
}

function Test-ComplianceTitleOnly {
    <# True when the ONLY reason a posting matched TitleInclude is the compliance
       title family. Those reqs have to show IT context in the body to survive.
       Added 2026-09-30. #>
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $compliance = @('compliance analyst','controls analyst','\bgrc\b')
    $matchedCompliance = $false
    foreach ($p in $compliance) { if ($Title -match "(?i)$p") { $matchedCompliance = $true; break } }
    if (-not $matchedCompliance) { return $false }
    # The TITLE itself can carry the context -- "IT Compliance Analyst",
    # "Information Security Compliance Analyst". TitleInclude has no bare 'IT'
    # pattern (only 'it audit', 'it analyst' and siblings), so without this check
    # a title that announces IT context would still be judged compliance-only.
    if (@(Test-ItContext $Title).Count -gt 0) { return $false }
    # If any OTHER target keyword also matches, the posting stands on its own.
    foreach ($p in $Config.TitleInclude) {
        if ($compliance -contains $p) { continue }
        if ($Title -match "(?i)$p") { return $false }
    }
    return $true
}

function Test-ItContext {
    <# Returns the IT-context signals found in posting text. One is enough: unlike
       Test-DeveloperRole, which hunts a job in disguise and wants corroboration,
       this only has to establish the posting is about computers. Added 2026-09-30. #>
    param([string]$Text)
    $hits = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $hits }
    foreach ($p in $Config.ItContextSignals) {
        if ($Text -match "(?i)$p") { $hits += $p }
    }
    return $hits
}

function Test-DeveloperRole {
    <# Returns the matched signal names when a posting reads like a software
       engineering job wearing a systems title. Two or more is the threshold. #>
    param([string]$Text)
    $hits = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $hits }
    foreach ($label in $Config.DeveloperSignals.Keys) {
        if ($Text -match $Config.DeveloperSignals[$label]) { $hits += $label }
    }
    if ($hits.Count -lt 2) { return @() }
    return $hits
}

function Test-RemoteFlags {
    <# Screens the posting TEXT of a remote req. Returns @{ Block=<string or ''>;
       Flags=@(<string>...) }. Block is absolute; Flags are appended to Reason so
       the warning travels with the lead instead of killing it. #>
    param([string]$Text)
    $result = @{ Block = ''; Flags = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result }

    foreach ($p in $Config.RemoteBlock) {
        if ($Text -match "(?is)$p") { $result.Block = 'remote role excludes Washington residents'; return $result }
    }
    foreach ($label in $Config.RemoteFlag.Keys) {
        foreach ($p in $Config.RemoteFlag[$label]) {
            if ($Text -match "(?is)$p") { $result.Flags += $label; break }
        }
    }
    return $result
}

function New-Posting {
    param($Source,$Company,$Title,$Location,$Url,$ReqId,$Posted,$Content)
    [pscustomobject][ordered]@{
        Key         = "$Source|$ReqId"
        Source      = $Source
        Company     = $Company
        Title       = ($Title -replace '\s+',' ').Trim()
        Location    = ($Location -replace '\s+',' ').Trim()
        ReqId       = "$ReqId"
        Posted      = "$Posted"
        Url         = $Url
        Pay         = Get-PayRange $Content
        Degree      = Get-DegreeFlag $Content
        NeedsLicence= [bool](Test-LicenceRequired $Content)
        Remote      = $false
        Screen      = ''
        Reason      = ''
        Content     = $Content
    }
}

# ============================================================================
#  PROVIDERS -- each returns a list of postings; failures are reported, not fatal
# ============================================================================

function Get-GreenhouseJobs {
    param($Src)
    $uri = "https://boards-api.greenhouse.io/v1/boards/$($Src.Token)/jobs?content=true"
    $r = Invoke-Json $uri
    $out = @()
    foreach ($j in $r.jobs) {
        $loc = ''
        if ($j.PSObject.Properties.Name -contains 'location' -and $j.location -and
            $j.location.PSObject.Properties.Name -contains 'name') { $loc = $j.location.name }
        $body = ''
        if ($j.PSObject.Properties.Name -contains 'content') { $body = Convert-HtmlToText $j.content }
        $out += New-Posting -Source 'Greenhouse' -Company $Src.Company -Title $j.title `
                    -Location $loc -Url $j.absolute_url -ReqId $j.id -Posted $j.updated_at -Content $body
    }
    return $out
}

function Get-LeverJobs {
    param($Src)
    $uri = "https://api.lever.co/v0/postings/$($Src.Token)?mode=json"
    $r = Invoke-Json $uri
    $out = @()
    foreach ($j in $r) {
        $loc = ''
        if ($j.PSObject.Properties.Name -contains 'categories' -and $j.categories -and
            $j.categories.PSObject.Properties.Name -contains 'location') { $loc = $j.categories.location }
        $body = ''
        if ($j.PSObject.Properties.Name -contains 'descriptionPlain' -and $j.descriptionPlain) { $body = $j.descriptionPlain }
        elseif ($j.PSObject.Properties.Name -contains 'description') { $body = Convert-HtmlToText $j.description }
        if ($j.PSObject.Properties.Name -contains 'lists') {
            foreach ($l in $j.lists) { $body += "`n`n" + $l.text + "`n" + (Convert-HtmlToText $l.content) }
        }
        $out += New-Posting -Source 'Lever' -Company $Src.Company -Title $j.text `
                    -Location $loc -Url $j.hostedUrl -ReqId $j.id -Posted $j.createdAt -Content $body
    }
    return $out
}

function Get-WorkdayJobs {
    param($Src)
    $base   = "$($Src.WdHost)/wday/cxs/$($Src.Tenant)/$($Src.Site)"
    $out    = @()
    $offset = 0
    $limit  = 20
    $total  = 0          # OUTSIDE the loop -- see the paging note below
    $seenPaths  = @{}
    $skippedNoPath = 0
    $stopReason = 'ran out of pages'

    # PAGING, rewritten 2026-09-10. The previous loop declared $total INSIDE the do
    # block and terminated on `$offset -lt $total`, so the moment any single page came
    # back without a usable `total` the whole tenant stopped -- silently, mid-board.
    # That is what produced "exactly 40 postings" from six different tenants, and a
    # logged total=0 alongside 40 collected rows: the FIRST page reported a total, a
    # later page did not, and the loop read the reset value.
    #
    # `total` is now ADVISORY ONLY. Termination is driven by what actually arrived:
    # a short page means the end of the board, and a page that adds no NEW requisition
    # means the tenant is ignoring offset and re-serving page one, which would
    # otherwise spin until the cap.
    do {
        $page = Invoke-Json "$base/jobs" -Method Post -Body @{ appliedFacets = @{}; limit = $limit; offset = $offset; searchText = '' }
        if ($page -and $page.PSObject.Properties.Name -contains 'total') {
            $claimed = [int]$page.total
            if ($claimed -gt $total) { $total = $claimed }
        }
        $postings = @()
        if ($page -and $page.PSObject.Properties.Name -contains 'jobPostings' -and $page.jobPostings) { $postings = @($page.jobPostings) }
        if ($postings.Count -eq 0) { $stopReason = 'empty page'; break }

        $newThisPage = 0
        foreach ($j in $postings) {
            # externalPath is BOTH the dedupe key and the URL. A bare access throws under
            # StrictMode, and on 2026-09-17 NVIDIA served a posting with no externalPath
            # roughly 1,700 rows in -- one bad row killed the ENTIRE tenant with
            # "The property 'externalPath' cannot be found on this object."
            # A posting with no path cannot be linked or deduped, so skip the row and
            # keep collecting. Count the skips so this can never be invisible.
            $path = ''
            if ($j.PSObject.Properties.Name -contains 'externalPath' -and $null -ne $j.externalPath) {
                $path = [string]$j.externalPath
            }
            if ([string]::IsNullOrWhiteSpace($path)) { $skippedNoPath++; continue }
            $loc = ''
            if ($j.PSObject.Properties.Name -contains 'locationsText') { $loc = $j.locationsText }
            # One large health-system tenant returns an EMPTY locationsText on all 1,454
            # of its reqs, so the
            # location screen never ran for them at all and Puyallup clinical roles sailed
            # through. The location is in the URL: /job/Puyallup-Washington/<slug>_JR78095.
            # Recover it from there whenever the field itself is blank.
            if ([string]::IsNullOrWhiteSpace($loc)) {
                $segs = @($path -split '/' | Where-Object { $_ -ne '' })
                $ji = [array]::IndexOf($segs, 'job')
                if ($ji -ge 0 -and $segs.Count -gt ($ji + 1)) {
                    $loc = ($segs[$ji + 1] -replace '-', ' ').Trim()
                }
            }
            # bulletFields IS NOT ALWAYS THE REQUISITION ID. Added 2026-09-25.
            #
            # On a multi-location req a tenant can put the additional-locations list in the
            # first bullet. Taking bulletFields[0] on faith wrote that list into ReqId and
            # left locationsText holding the primary city alone: Jackson Lewis posted to
            # twelve cities INCLUDING SEATTLE and the req was screened on New York. Second
            # time that employer's location list has gone missing -- the first was the
            # WebFetch summary that dropped the Washington band and 12 of 13 locations.
            #
            # Take the first bullet that actually looks like an id, and fold the ones that
            # look like places back into the location string so the multi-location branch of
            # Test-LocationMatch can see them. Bullets that are neither are dropped.
            $req = $path
            if ($j.PSObject.Properties.Name -contains 'bulletFields' -and $j.bulletFields) {
                $mapped = Resolve-WorkdayBullets @($j.bulletFields) $loc
                if (-not [string]::IsNullOrWhiteSpace($mapped.ReqId)) { $req = $mapped.ReqId }
                $loc = $mapped.Location
            }
            $posted = ''
            if ($j.PSObject.Properties.Name -contains 'postedOn') { $posted = $j.postedOn }
            if ($seenPaths.ContainsKey($path)) { continue }
            $seenPaths[$path] = $true
            $newThisPage++
            # PUBLIC URL SHAPE DIFFERS BY WORKDAY HOSTING MODEL, and getting it wrong ships a
            # dead link on every card. A dedicated tenant host (<tenant>.wdN.myworkdayjobs.com)
            # serves /<Site>/job/... , but the SHARED host (wdN.myworkdaysite.com, which is what
            # UW uses) serves /recruiting/<tenant>/<site-lowercase>/job/... and 404s to a
            # maintenance page otherwise. Found 2026-09-18 when every UW card on the board
            # turned out to be unclickable.
            if ($Src.WdHost -match 'myworkdaysite\.com') {
                $publicUrl = "$($Src.WdHost)/recruiting/$($Src.Tenant.ToLower())/$($Src.Site.ToLower())" + $path
            } else {
                $publicUrl = "$($Src.WdHost)/$($Src.Site)" + $path
            }
            $out += New-Posting -Source 'Workday' -Company $Src.Company -Title $j.title `
                        -Location $loc -Url $publicUrl `
                        -ReqId $req -Posted $posted -Content '' |
                    Add-Member -NotePropertyName DetailPath -NotePropertyValue "$base$path" -PassThru
        }

        if ($newThisPage -eq 0) { $stopReason = 'tenant ignoring offset -- page repeated'; break }

        $offset += $limit
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds $script:Throttle

        if ($postings.Count -lt $limit)      { $stopReason = 'short page -- end of board'; break }
        if ($offset -ge $WorkdayMaxPostings) { $stopReason = "hit the $WorkdayMaxPostings safety cap"; break }
    } while ($true)
    if ($offset -gt $limit) { Write-Host '' }

    # Claimed vs collected, so under-collection can never be invisible again.
    $msg = "   Workday $($Src.Company): collected $($out.Count), stopped because $stopReason"
    if ($total -gt 0) { $msg += "; board claims total=$total" }
    if ($skippedNoPath -gt 0) { $msg += "; skipped $skippedNoPath with no externalPath" }
    Write-Log $msg
    if ($total -gt 0 -and $out.Count -lt $total) {
        Write-Log ("   UNDER-COLLECTED $($Src.Company): board claims $total, collected $($out.Count)") 'WARN'
    }
    return $out
}

function Add-WorkdayDetail {
    param($Posting)
    try {
        $d = Invoke-Json $Posting.DetailPath
        $html = ''
        if ($d.jobPostingInfo -and $d.jobPostingInfo.PSObject.Properties.Name -contains 'jobDescription') {
            $html = $d.jobPostingInfo.jobDescription
        }
        $Posting.Content      = Convert-HtmlToText $html
        $Posting.Pay          = Get-PayRange $Posting.Content
        $Posting.Degree       = Get-DegreeFlag $Posting.Content
        $Posting.NeedsLicence = [bool](Test-LicenceRequired $Posting.Content)
    } catch {
        Write-Log "  detail fetch failed for $($Posting.Company) / $($Posting.Title): $($_.Exception.Message)" 'WARN'
    }
    Start-Sleep -Milliseconds $script:Throttle
}

function Get-AdpJobs {
    param($Src)
    $base = 'https://workforcenow.adp.com/mascsr/default/careercenter/public/events/staffing/v1/job-requisitions'
    $qs   = "cid=$($Src.Cid)&ccId=$($Src.CcId)&lang=en_US"
    $out  = @()
    $ids  = @{}
    $skip = 0
    $page = 0
    while ($page -lt 20) {
        $page++
        $resp = Invoke-Json ("$base" + "?" + $qs + '&$top=50&$skip=' + $skip)
        $reqs = @()
        if ($resp.PSObject.Properties.Name -contains 'jobRequisitions' -and $resp.jobRequisitions) {
            $reqs = @($resp.jobRequisitions)
        }
        if ($reqs.Count -eq 0) { break }
        $added = 0
        foreach ($j in $reqs) {
            $ext = ''
            if ($j.PSObject.Properties.Name -contains 'customFieldGroup' -and $j.customFieldGroup -and
                $j.customFieldGroup.PSObject.Properties.Name -contains 'stringFields' -and
                $j.customFieldGroup.stringFields) {
                $sf = @($j.customFieldGroup.stringFields)
                if ($sf.Count -gt 0 -and $sf[0].PSObject.Properties.Name -contains 'stringValue') {
                    $ext = "$($sf[0].stringValue)"
                }
            }
            if (-not $ext -or $ids.ContainsKey($ext)) { continue }
            $ids[$ext] = $true
            $added++

            $loc = ''
            $rl  = @()
            if ($j.PSObject.Properties.Name -contains 'requisitionLocations' -and $j.requisitionLocations) {
                $rl = @($j.requisitionLocations)
            }
            if ($rl.Count -gt 0 -and $rl[0].PSObject.Properties.Name -contains 'address' -and $rl[0].address) {
                $addr  = $rl[0].address
                $parts = @()
                if ($addr.PSObject.Properties.Name -contains 'cityName' -and $addr.cityName) { $parts += $addr.cityName }
                if ($addr.PSObject.Properties.Name -contains 'countrySubdivisionLevel1' -and
                    $addr.countrySubdivisionLevel1) { $parts += $addr.countrySubdivisionLevel1.codeValue }
                $loc = ($parts | Where-Object { $_ }) -join ', '
            }
            $reqNo = $ext
            if ($j.PSObject.Properties.Name -contains 'clientRequisitionID' -and $j.clientRequisitionID) {
                $reqNo = "$($j.clientRequisitionID)"
            }
            $posted = ''
            if ($j.PSObject.Properties.Name -contains 'postDate') { $posted = $j.postDate }
            $title = ''
            if ($j.PSObject.Properties.Name -contains 'requisitionTitle') { $title = $j.requisitionTitle }
            if (-not $title) { continue }
            $url = "https://workforcenow.adp.com/mascsr/default/mdf/recruitment/recruitment.html?$qs&jobId=$ext"

            $out += New-Posting -Source 'ADP' -Company $Src.Company -Title $title `
                        -Location $loc -Url $url -ReqId $reqNo -Posted $posted -Content '' |
                    Add-Member -NotePropertyName DetailPath -NotePropertyValue ("$base/$ext" + "?" + $qs) -PassThru
        }
        # the server caps the page size itself; stop when a page brings nothing new
        if ($added -eq 0) { break }
        $skip += $reqs.Count
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds $script:Throttle
    }
    if ($page -gt 1) { Write-Host '' }
    return $out
}

function Add-AdpDetail {
    param($Posting)
    try {
        $d = Invoke-Json $Posting.DetailPath
        if ($d.PSObject.Properties.Name -contains 'jobRequisitions' -and $d.jobRequisitions) {
            $d = @($d.jobRequisitions)[0]
        }
        $html = ''
        if ($d.PSObject.Properties.Name -contains 'requisitionDescription') { $html = $d.requisitionDescription }
        $Posting.Content      = Convert-HtmlToText $html
        $Posting.Pay          = Get-PayRange $Posting.Content
        $Posting.Degree       = Get-DegreeFlag $Posting.Content
        $Posting.NeedsLicence = [bool](Test-LicenceRequired $Posting.Content)

        # ADP publishes the range as structured data, which beats parsing it out of prose
        if (-not $Posting.Pay -and $d.PSObject.Properties.Name -contains 'payGradeRange' -and $d.payGradeRange) {
            $mn = $null; $mx = $null
            if ($d.payGradeRange.PSObject.Properties.Name -contains 'minimumRate' -and $d.payGradeRange.minimumRate) {
                if ($d.payGradeRange.minimumRate.PSObject.Properties.Name -contains 'amountValue') {
                    $mn = $d.payGradeRange.minimumRate.amountValue
                }
            }
            if ($d.payGradeRange.PSObject.Properties.Name -contains 'maximumRate' -and $d.payGradeRange.maximumRate) {
                if ($d.payGradeRange.maximumRate.PSObject.Properties.Name -contains 'amountValue') {
                    $mx = $d.payGradeRange.maximumRate.amountValue
                }
            }
            if ($mn -and $mx) { $Posting.Pay = ('${0:N0} - ${1:N0}' -f [double]$mn, [double]$mx) }
        }
    } catch {
        Write-Log "  detail fetch failed for $($Posting.Company) / $($Posting.Title): $($_.Exception.Message)" 'WARN'
    }
    Start-Sleep -Milliseconds $script:Throttle
}

function Get-IcimsSitemapUrl {
    <# Only enumerate a sitemap the site itself advertises. robots.txt is the site's own
       statement of what it will serve; if it will not serve that, or advertises nothing,
       we skip rather than probe. #>
    param($Src)
    $robots = $null
    try { $robots = Invoke-Html "$($Src.BaseUrl)/robots.txt" }
    catch {
        Write-Log "  robots.txt unreachable for $($Src.Company): $($_.Exception.Message) -- skipping" 'WARN'
        return $null
    }
    if ($robots -match '(?im)^\s*Disallow:\s*/\s*$') {
        Write-Log "  $($Src.Company) robots.txt disallows everything -- skipping" 'WARN'
        return $null
    }
    $m = [regex]::Match($robots, '(?im)^\s*Sitemap:\s*(\S+)\s*$')
    if (-not $m.Success) {
        Write-Log "  $($Src.Company) advertises no sitemap in robots.txt -- skipping" 'WARN'
        return $null
    }
    return $m.Groups[1].Value
}

function Repair-TitleCase {
    <# ToTitleCase turns IT into It and III into Iii. Put the acronyms back. #>
    param([string]$Title)
    $acr = 'IT','HR','QA','QE','SME','II','III','IV','VI','AI','ML','SQL','AWS','GCP','ERP','CRM',
           'API','UI','UX','VP','US','EMEA','APAC','PC','EDI','GIS','HVAC','RN','CNC','SAP','O365','M365'
    foreach ($a in $acr) {
        $Title = [regex]::Replace($Title, "(?i)\b$a\b", $a)
    }
    return $Title
}

function Get-IcimsJobs {
    param($Src)
    $out = @()
    $sitemap = Get-IcimsSitemapUrl $Src
    if (-not $sitemap) { return $out }
    $raw = $null
    try { $raw = Invoke-Html $sitemap }
    catch {
        Write-Log "  sitemap unreachable for $($Src.Company): $($_.Exception.Message)" 'WARN'
        return $out
    }
    $doc = $null
    try { $doc = [xml]$raw } catch {
        Write-Log "  sitemap did not parse as XML for $($Src.Company)" 'WARN'
        return $out
    }
    $urls = @()
    if ($doc.PSObject.Properties.Name -contains 'urlset' -and $doc.urlset -and
        $doc.urlset.PSObject.Properties.Name -contains 'url' -and $doc.urlset.url) {
        $urls = @($doc.urlset.url)
    }
    foreach ($u in $urls) {
        $loc = "$($u.loc)"
        if ($loc -notmatch '/jobs/(\d+)/([^/]+)/job') { continue }
        $id   = $Matches[1]
        $slug = $Matches[2]
        # the slug is percent-encoded -- %26 for &, %2C for , -- and screening on the
        # encoded form silently mis-matches titles, so decode BEFORE anything reads it
        $slug = [System.Uri]::UnescapeDataString($slug)
        $title = ((($slug -replace '-+', ' ')).Trim())
        if (-not $title) { continue }
        $title = Repair-TitleCase ((Get-Culture).TextInfo.ToTitleCase($title))
        $posted = ''
        if ($u.PSObject.Properties.Name -contains 'lastmod') { $posted = "$($u.lastmod)" }
        # Location is left blank on purpose: it is not in the sitemap, and a blank
        # location passes the cheap screen so the posting reaches the detail fetch,
        # where the real location is read and the re-screen applies it.
        $out += New-Posting -Source 'iCIMS' -Company $Src.Company -Title $title `
                    -Location '' -Url $loc -ReqId $id -Posted $posted -Content '' |
                Add-Member -NotePropertyName DetailPath -NotePropertyValue ($loc + '?in_iframe=1') -PassThru
    }
    Start-Sleep -Milliseconds $script:Throttle
    return $out
}

function Add-IcimsDetail {
    param($Posting)
    try {
        $text = Convert-HtmlToText (Invoke-Html $Posting.DetailPath)
        $Posting.Content = $text
        # iCIMS renders locations either as "US-WA-Seattle" or as "Seattle, Washington".
        # If neither matches, the location stays blank and the posting survives the screen
        # for a human to judge -- a wrongly screened lead costs more than a wrongly kept one.
        if ($text -match 'US-([A-Z]{2})-([A-Za-z .''\-]+)') {
            $Posting.Location = "$($Matches[2].Trim()), $($Matches[1])"
        } elseif ($text -match '(?m)^\s*([A-Z][A-Za-z .''\-]{2,30}),\s*(Washington|Oregon|California|Idaho|Alaska|WA|OR|CA|ID|AK)\s*$') {
            $Posting.Location = "$($Matches[1].Trim()), $($Matches[2])"
        } elseif ($text -match '(?ms)^\s*Location\s*\r?\n\s*([^\r\n]{2,60}?)\s*$') {
            # iCIMS renders a bare "Location" label with the value on the next line --
            # this is what catches "Remote" and "Madison Valley, Seattle"
            $Posting.Location = $Matches[1].Trim()
        }
        $Posting.Pay          = Get-PayRange $text
        $Posting.Degree       = Get-DegreeFlag $text
        $Posting.NeedsLicence = [bool](Test-LicenceRequired $text)
    } catch {
        Write-Log "  detail fetch failed for $($Posting.Company) / $($Posting.Title): $($_.Exception.Message)" 'WARN'
    }
    Start-Sleep -Milliseconds $script:Throttle
}


function Get-UltiProJobs {
    param($Src)
    # UKG/UltiPro. The search endpoint is a POST and pages on Skip. Termination follows the
    # same rule the Workday paging bug taught us: totalCount is ADVISORY ONLY. We stop on a
    # short page, on a page that adds no new requisition, or at a hard safety cap -- never
    # on a server-reported total, because a single page omitting it must not end the board.
    # The HOST is per-tenant, not constant. UKG spreads job boards across
    # recruiting.ultipro.com, recruiting2.ultipro.com and numbered siblings; the path shape
    # is identical on all of them. This is the same trap as the Workday two-URL-shape bug
    # fixed 2026-09-17, so it gets the same treatment -- a per-source field with a default,
    # never a hardcoded host. Confirmed live 2026-09-19 against a tenant on the
    # recruiting2 host, which returned 43 opportunities from the identical
    # LoadSearchResults POST.
    $ukgHost = 'https://recruiting.ultipro.com'
    if ($Src.ContainsKey('UkgHost') -and $Src.UkgHost) { $ukgHost = [string]$Src.UkgHost }
    $base = "$ukgHost/$($Src.Tenant)/JobBoard/$($Src.BoardId)"
    $uri  = "$base/JobBoardView/LoadSearchResults"
    $out  = @()
    $seenIds = @{}
    $skip = 0
    $page = 200
    $cap  = 1000
    $advisedTotal = 0
    $stopReason = 'ran out of pages'

    while ($true) {
        $body = @{ opportunitySearch = @{
            Top = $page; Skip = $skip; QueryString = ''
            OrderBy = @(); Filters = @()
        } }
        $r = Invoke-Json -Uri $uri -Method 'Post' -Body $body -Label "$($Src.Company) UltiPro search"

        $batch = @()
        if ($r -and $r.PSObject.Properties.Name -contains 'opportunities' -and $r.opportunities) {
            $batch = @($r.opportunities)
        }
        if ($r -and $r.PSObject.Properties.Name -contains 'totalCount' -and $r.totalCount) {
            $advisedTotal = [int]$r.totalCount
        }
        if ($batch.Count -eq 0) { break }

        $newThisPage = 0
        foreach ($j in $batch) {
            $id = ''
            if ($j.PSObject.Properties.Name -contains 'Id' -and $j.Id) { $id = [string]$j.Id }
            if (-not $id) { continue }
            if ($seenIds.ContainsKey($id)) { continue }
            $seenIds[$id] = $true
            $newThisPage++

            $title = ''
            if ($j.PSObject.Properties.Name -contains 'Title' -and $j.Title) { $title = [string]$j.Title }

            $req = $id
            if ($j.PSObject.Properties.Name -contains 'RequisitionNumber' -and $j.RequisitionNumber) {
                $req = [string]$j.RequisitionNumber
            }

            $posted = ''
            if ($j.PSObject.Properties.Name -contains 'PostedDate' -and $j.PostedDate) {
                $posted = [string]$j.PostedDate
            }

            # Locations is an array of objects; prefer "City, ST" and fall back to the
            # tenant's own label. Several offices on one req is normal -- keep them all so
            # the location screen sees every city rather than only the first.
            $locs = @()
            if ($j.PSObject.Properties.Name -contains 'Locations' -and $j.Locations) {
                foreach ($L in @($j.Locations)) {
                    $city = ''; $st = ''
                    if ($L.PSObject.Properties.Name -contains 'Address' -and $L.Address) {
                        if ($L.Address.PSObject.Properties.Name -contains 'City' -and $L.Address.City) {
                            $city = [string]$L.Address.City
                        }
                        if ($L.Address.PSObject.Properties.Name -contains 'State' -and $L.Address.State -and
                            $L.Address.State.PSObject.Properties.Name -contains 'Code' -and $L.Address.State.Code) {
                            $st = [string]$L.Address.State.Code
                        }
                    }
                    $one = ''
                    if ($city -and $st) { $one = "$city, $st" }
                    elseif ($city)      { $one = $city }
                    elseif ($L.PSObject.Properties.Name -contains 'LocalizedDescription' -and $L.LocalizedDescription) {
                        $one = [string]$L.LocalizedDescription
                    }
                    if ($one -and ($locs -notcontains $one)) { $locs += $one }
                }
            }
            $loc = ($locs -join ' | ')

            # Content is deliberately left EMPTY so the detail pass picks this up --
            # BriefDescription is a teaser and screening on it would be screening on nothing.
            $url = "$base/OpportunityDetail?opportunityId=$id"
            $out += (New-Posting -Source 'UltiPro' -Company $Src.Company -Title $title `
                        -Location $loc -Url $url -ReqId $req -Posted $posted -Content '' |
                     Add-Member -NotePropertyName DetailPath -NotePropertyValue $url -PassThru)
        }

        if ($batch.Count -lt $page) { $stopReason = 'short page'; break }
        if ($newThisPage -eq 0)     { $stopReason = 'page repeated -- tenant ignoring Skip'; break }
        $skip += $page
        if ($out.Count -ge $cap)    { $stopReason = "safety cap $cap reached"; break }
        Start-Sleep -Milliseconds $script:Throttle
    }

    Write-Log ("   UltiPro {0}: {1} collected (advised total {2}) -- {3}" -f `
               $Src.Company, $out.Count, $advisedTotal, $stopReason)
    return $out
}

function Add-UltiProDetail {
    param($Posting)
    try {
        # There is no JSON detail endpoint -- both LoadOpportunity and LoadOpportunityDetail
        # return 404. The OpportunityDetail page embeds the whole opportunity as a JSON
        # literal, and "Description" appears exactly once as a key, so pulling that one
        # value out is safer than trying to brace-match the whole object.
        $html = Invoke-Html $Posting.DetailPath
        $m = [regex]::Match($html, '"Description":"((?:[^"\\]|\\.)*)"')
        $text = ''
        if ($m.Success) {
            # Re-wrap as a JSON string so ConvertFrom-Json does the unescaping -- \u, \", \n
            # and the rest -- rather than hand-rolling a replace chain that gets it wrong.
            $decoded = ('"' + $m.Groups[1].Value + '"') | ConvertFrom-Json
            $text = Convert-HtmlToText $decoded
        } else {
            Write-Log "  no Description found in UltiPro detail for $($Posting.Company) / $($Posting.Title)" 'WARN'
        }
        $Posting.Content      = $text
        $Posting.Pay          = Get-PayRange $text
        $Posting.Degree       = Get-DegreeFlag $text
        $Posting.NeedsLicence = [bool](Test-LicenceRequired $text)
    } catch {
        Write-Log "  detail fetch failed for $($Posting.Company) / $($Posting.Title): $($_.Exception.Message)" 'WARN'
    }
    Start-Sleep -Milliseconds $script:Throttle
}

function Get-MicrosoftJobs {
    param($Src)
    # apply.careers.microsoft.com/api/pcsx/search -> { data: { positions: [ ... ] } }
    $base = 'https://apply.careers.microsoft.com'
    $out  = @()
    $seen = @{}
    foreach ($q in $Src.Queries) {
        foreach ($loc in $Src.Locations) {
            $startAt  = 0
            $newHere  = 0
            $lastFirst = ''
            Write-Host "   query '$q'" -NoNewline -ForegroundColor DarkGray
            do {
                $uri = "$base/api/pcsx/search?domain=microsoft.com" +
                       "&query=$([uri]::EscapeDataString($q))" +
                       "&location=$([uri]::EscapeDataString($loc))" +
                       "&start=$startAt"
                try { $r = Invoke-Json $uri }
                catch { Write-Host ''; Write-Log "  Microsoft '$q' failed: $($_.Exception.Message)" 'WARN'; break }

                $positions = @()
                if ($r.PSObject.Properties.Name -contains 'data' -and $r.data -and
                    $r.data.PSObject.Properties.Name -contains 'positions' -and $r.data.positions) {
                    $positions = @($r.data.positions)
                }
                if ($positions.Count -eq 0) { break }
                Write-Host '.' -NoNewline -ForegroundColor DarkGray

                # If 'start' is being ignored we will keep receiving the same first row. Stop.
                $thisFirst = "$($positions[0].id)"
                if ($thisFirst -eq $lastFirst) {
                    Write-Host ''
                    Write-Log "  Microsoft '$q': paging is not advancing (start ignored) -- stopping this query" 'WARN'
                    break
                }
                $lastFirst = $thisFirst

                foreach ($j in $positions) {
                    $id = "$($j.atsJobId)"
                    if (-not $id) { $id = "$($j.id)" }
                    if ($seen.ContainsKey($id)) { continue }
                    $seen[$id] = $true

                    $locText = ''
                    if ($j.PSObject.Properties.Name -contains 'standardizedLocations' -and $j.standardizedLocations) {
                        $locText = (@($j.standardizedLocations) -join '; ')
                    } elseif ($j.PSObject.Properties.Name -contains 'locations' -and $j.locations) {
                        $locText = (@($j.locations) -join '; ')
                    }

                    $posted = ''
                    if ($j.PSObject.Properties.Name -contains 'postedTs' -and $j.postedTs) {
                        $posted = ([datetimeoffset]::FromUnixTimeSeconds([int64]$j.postedTs)).ToString('yyyy-MM-dd')
                    }

                    $title = "$($j.name)"
                    if ($j.PSObject.Properties.Name -contains 'department' -and $j.department) {
                        $title = "$title [$($j.department)]"
                    }

                    $out += New-Posting -Source 'Microsoft' -Company 'Microsoft' -Title $title `
                                -Location $locText -Url "$base$($j.positionUrl)" -ReqId $id `
                                -Posted $posted -Content '' |
                            Add-Member -NotePropertyName DetailPath `
                                -NotePropertyValue "$base/api/pcsx/position_details?position_id=$($j.id)&domain=microsoft.com&hl=en" -PassThru
                }
                $startAt += $positions.Count
                $newHere += $positions.Count
                Start-Sleep -Milliseconds $script:Throttle
            } while ($positions.Count -gt 0 -and $newHere -lt $MaxPerQuery)
            Write-Host " $newHere seen" -ForegroundColor DarkGray
        }
    }
    return $out
}

function Add-MicrosoftDetail {
    param($Posting)
    try {
        $d = Invoke-Json $Posting.DetailPath
        $data = $null
        if ($d.PSObject.Properties.Name -contains 'data') { $data = $d.data }
        if (-not $data) { return }

        $html = ''
        if ($data.PSObject.Properties.Name -contains 'jobDescription' -and $data.jobDescription) { $html = $data.jobDescription }
        $Posting.Content = Convert-HtmlToText $html

        # Microsoft states these as structured fields -- use them rather than guessing from prose.
        $extra = @()
        foreach ($f in 'efcustomTextWorkSite','efcustomTextRoletype','efcustomTextEmploymentType','efcustomTextRequiredTravel') {
            if ($data.PSObject.Properties.Name -contains $f -and $data.$f) { $extra += "$($f -replace '^efcustomText','') : $((@($data.$f)) -join ', ')" }
        }
        if ($extra.Count -gt 0) { $Posting.Content = ($extra -join "`n") + "`n`n" + $Posting.Content }

        $Posting.Pay          = Get-PayRange $Posting.Content
        $Posting.Degree       = Get-DegreeFlag $Posting.Content
        $Posting.NeedsLicence = [bool](Test-LicenceRequired $Posting.Content)

        # Honour the no-people-management rule at the source: Microsoft tags this explicitly.
        if ($data.PSObject.Properties.Name -contains 'efcustomTextRoletype' -and $data.efcustomTextRoletype) {
            if ((@($data.efcustomTextRoletype) -join ' ') -match '(?i)people manager') {
                $Posting.Screen = 'out'; $Posting.Reason = 'Microsoft tags this role type as people manager'
            }
        }
    } catch {
        Write-Log "  detail fetch failed for Microsoft $($Posting.ReqId): $($_.Exception.Message)" 'WARN'
    }
    Start-Sleep -Milliseconds $script:Throttle
}

# ============================================================================
#  MAIN
# ============================================================================

function Complete-Run {
    <# Writes the closing summary. Exit code is what Task Scheduler shows as
       Last Run Result: 0 clean, 1 completed with warnings or provider failures,
       2 aborted. #>
    param([switch]$Fatal)
    $mins = [math]::Round(((Get-Date) - $script:RunStart).TotalMinutes, 1)
    Write-Log ('-' * 62)
    Write-Log "Finished in $mins min. Warnings: $($script:RunWarnings). Errors: $($script:RunErrors)."
    Write-Log "Log: $($script:LogFile)"
    $script:ExitCode = if ($Fatal) { 2 }
                       elseif ($script:RunErrors -gt 0) { 1 }
                       elseif ($script:RunWarnings -gt 0) { 1 }
                       else { 0 }
    Write-Log "Exit code $($script:ExitCode)  (0 clean, 1 completed with warnings or provider failures, 2 aborted)"
}

# Any terminating error not already handled lands here: it gets logged, the run is
# closed properly, and Task Scheduler sees exit code 2 rather than a silent stop.
trap {
    Write-Log "UNHANDLED: $($_.Exception.Message)" 'ERROR'
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }
    Complete-Run -Fatal
    exit $script:ExitCode
}

# --- resolve the output root FIRST, and never depend on the working directory ---
# A scheduled task with a bad "Start in", or one running under a profile where
# USERPROFILE differs, must fail loudly here rather than quietly writing a Sweeps
# folder somewhere nobody looks.
$rootOk   = $false
try { $rootOk = Test-Path -LiteralPath $OutputRoot -PathType Container } catch { }

if (-not $rootOk) {
    Open-FallbackLog $logStamp
    Write-Log ('=' * 62)
    Write-Log "OutputRoot does not exist or is not a folder: $OutputRoot" 'ERROR'
    Write-Log "Current directory is $((Get-Location).Path) -- note the script does not use it." 'ERROR'
    Write-Log "Pass -OutputRoot explicitly, or check the scheduled task's Start in value." 'ERROR'
    Complete-RunEarly
    exit 2
}

$sweepDir = Join-Path $OutputRoot 'Sweeps'
if (-not (Test-Path $sweepDir)) { New-Item -ItemType Directory -Path $sweepDir -Force | Out-Null }
$stateFile = Join-Path $sweepDir '_seen.json'

# --- logging ---------------------------------------------------------------
$logDir = Join-Path $sweepDir 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("sweep-{0}.log" -f $logStamp)


Write-Log ('=' * 62)
Write-Log "Job sweep $JobSweepVersion starting. Host PS $($PSVersionTable.PSVersion). DryRun=$($DryRun.IsPresent) SkipDetail=$($SkipDetail.IsPresent) Source=$(if($Source){$Source}else{'all'})"
Write-Log "Output root: $OutputRoot"

# prune old logs so the folder does not grow without bound
try {
    Get-ChildItem -Path $logDir -Filter 'sweep-*.log' -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

$seen = @{}
if (Test-Path $stateFile) {
    try {
        $raw = Get-Content $stateFile -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $seen[$p.Name] = $p.Value }
    } catch { Write-Log "Could not read state file; treating every posting as new. $($_.Exception.Message)" 'WARN' }
}
Write-Log "State: $($seen.Count) requisitions previously seen."

$sources = $Config.Sources
if ($Source) { $sources = $sources | Where-Object { $_.Provider -eq $Source } }

$all = @()
foreach ($src in $sources) {
    Write-Log "-> $($src.Provider) : $($src.Company)" 'STEP'
    $script:Throttle = if ($src.ContainsKey('ThrottleMs')) { [int]$src.ThrottleMs } else { $PolitenessMs }
    try {
        $got = @()
        switch ($src.Provider) {
            'Greenhouse' { $got = @(Get-GreenhouseJobs $src) }
            'Lever'      { $got = @(Get-LeverJobs      $src) }
            'Workday'    { $got = @(Get-WorkdayJobs    $src) }
            'Microsoft'  { $got = @(Get-MicrosoftJobs  $src) }
            'ADP'        { $got = @(Get-AdpJobs        $src) }
            'iCIMS'      { $got = @(Get-IcimsJobs      $src) }
            'UltiPro'    { $got = @(Get-UltiProJobs    $src) }
        }
        Write-Log "   $($got.Count) postings"
        $all += $got
    } catch {
        Write-Log "   FAILED $($src.Company): $($_.Exception.Message)" 'ERROR'
    }
    Start-Sleep -Milliseconds $script:Throttle
}

if ($all.Count -eq 0) { Write-Log 'No postings retrieved. Nothing to do.' 'WARN'; Complete-Run; exit $script:ExitCode }

# --- new only -------------------------------------------------------------
$new = @($all | Where-Object { -not $seen.ContainsKey($_.Key) })
Write-Log "$($all.Count) postings retrieved, $($new.Count) not seen before." 'OK'
if ($new.Count -eq 0) { Write-Log 'Nothing new since the last run.' 'OK'; Complete-Run; exit $script:ExitCode }

# --- title and location screen (cheap, runs before detail fetches) --------
foreach ($p in $new) {
    $t = Test-TitleMatch $p.Title
    if (-not $t.Ok) { $p.Screen = 'out'; $p.Reason = $t.Reason; continue }
    $l = Test-LocationMatch $p.Location $p.Title
    if (-not $l.Ok) { $p.Screen = 'out'; $p.Reason = $l.Reason; continue }
    $p.Screen = 'keep'; $p.Reason = $t.Reason
    # Appended here and nowhere else: the re-screen pass below calls
    # Test-LocationMatch again and would duplicate the note.
    if ($l.Check) { $p.Reason = ($p.Reason + ' | ' + $l.Check).Trim(' |') }
}

# --- detail fetch only for survivors -------------------------------------
$keepers = @($new | Where-Object { $_.Screen -eq 'keep' })
if (-not $SkipDetail) {
    $needDetail = @($keepers | Where-Object { $_.PSObject.Properties.Name -contains 'DetailPath' -and -not $_.Content })
    if ($needDetail.Count -gt 0) {
        Write-Log "Fetching detail for $($needDetail.Count) postings..." 'STEP'
        $i = 0
        foreach ($p in $needDetail) {
            $i++
            Write-Log "   [$i/$($needDetail.Count)] $($p.Company) - $($p.Title)"
            switch ($p.Source) {
                'Workday'   { Add-WorkdayDetail   $p }
                'Microsoft' { Add-MicrosoftDetail $p }
                'ADP'       { Add-AdpDetail       $p }
                'iCIMS'     { Add-IcimsDetail     $p }
                'UltiPro'   { Add-UltiProDetail   $p }
            }
        }
    }
    # re-screen now that detail text is in hand
    foreach ($p in $keepers) {
        if ($p.Screen -eq 'out') { continue }
        $l = Test-LocationMatch $p.Location $p.Title
        if (-not $l.Ok) { $p.Screen = 'out'; $p.Reason = $l.Reason; continue }
        if ($p.NeedsLicence) { $p.Screen = 'out'; $p.Reason = "requires a driver's licence"; continue }
        # Physical-demand gate, added 2026-09-24. Computed here rather than on the posting
        # object because Content is only guaranteed populated after detail fetch.
        $phys    = @(Test-PhysicalDemand $p.Content)
        $physOut = @($phys | Where-Object { $_.Level -eq 'out' })
        if ($physOut.Count -gt 0) {
            $p.Screen = 'out'
            $p.Reason = 'physical requirement: ' + (($physOut | ForEach-Object { $_.Why }) -join '; ')
            continue
        }
        $physChk = @($phys | Where-Object { $_.Level -eq 'check' })
        if ($physChk.Count -gt 0) {
            $p.Reason = ($p.Reason + ' | CHECK physical: ' + (($physChk | ForEach-Object { $_.Why }) -join '; ')).Trim(' |')
        }
        # A degree flag NO LONGER DROPS the lead. Get-DegreeFlag reads prose and can be
        # wrong, and the one it killed on 2026-09-09 -- an IT Contracts &
        # Licensing Specialist III, in-region and in the target title family -- is exactly
        # the lead that must not disappear into screened.csv. Flag it and let a human read it.
        if ($p.Degree -eq 'hard') { $p.Reason = ($p.Reason + ' | CHECK: degree stated with no equivalency clause').Trim(' |') }

        # Developer-in-disguise, added 2026-09-10 after UW's REQ-0000134242-1
        # "Senior Systems Engineer" turned out to be a developer post -- the second
        # in a fortnight after Overland AI's "Junior Systems Administrator".
        $dev = @(Test-DeveloperRole $p.Content)
        if ($dev.Count -gt 0) {
            $p.Reason = ($p.Reason + ' | CHECK: reads like a software engineering role (' + ($dev -join '; ') + ')').Trim(' |')
        }

        # Compliance-title IT-context gate, added 2026-09-30. 'compliance analyst'
        # and its siblings measured 2-for-2 noise. The title alone no longer carries
        # a posting: when it is the ONLY match, the body has to show IT context.
        if (Test-ComplianceTitleOnly $p.Title) {
            $itc = @(Test-ItContext $p.Content)
            if ([string]::IsNullOrWhiteSpace($p.Content)) {
                # No detail fetched -- flag, never drop. An empty body is a fetch
                # failure, not evidence the req is out of scope. Same reasoning that
                # stopped Get-DegreeFlag killing the licensing req on 2026-09-09.
                $p.Reason = ($p.Reason + ' | CHECK: compliance title, no description retrieved').Trim(' |')
            }
            elseif ($itc.Count -eq 0) {
                $p.Screen = 'out'
                $p.Reason = 'compliance title with no IT context in the description'
                continue
            }
            else {
                $p.Reason = ($p.Reason + ' | IT context: ' + (($itc | Select-Object -First 4) -join '; ')).Trim(' |')
            }
        }

        # Remote vetting, added 2026-09-10 when national remote came back in scope.
        # Runs on postings whose LOCATION or TITLE reads remote (title added
        # 2026-09-21) -- an onsite Seattle req that happens to mention Eastern time
        # is not a remote-hours problem, but a req titled "- Remote" and filed
        # against a head office is, and needs the same residency screen.
        if ((Test-IsRemote $p.Location) -or (Test-IsRemoteTitle $p.Title)) {
            $p.Remote = $true
            $rf = Test-RemoteFlags $p.Content
            if ($rf.Block) { $p.Screen = 'out'; $p.Reason = $rf.Block; continue }
            foreach ($f in $rf.Flags) { $p.Reason = ($p.Reason + ' | ' + $f).Trim(' |') }
            if (-not $p.Pay) { $p.Reason = ($p.Reason + ' | CHECK: remote with no published range -- ask before investing time').Trim(' |') }
        }
    }
}

$candidates = @($new | Where-Object { $_.Screen -eq 'keep' })
$screened   = @($new | Where-Object { $_.Screen -eq 'out'  })

# --- write outputs --------------------------------------------------------
# Filenames carry the TIME as well as the date. On 2026-09-09 two runs an hour apart
# both wrote sweep-2026-09-09-candidates.json and the second destroyed the first --
# and because the first had already updated _seen.json, its candidates were gone for good.
$stamp   = Get-Date -Format 'yyyy-MM-dd-HHmm'
$candCsv = Join-Path $sweepDir "sweep-$stamp-candidates.csv"
$candJson= Join-Path $sweepDir "sweep-$stamp-candidates.json"
$outCsv  = Join-Path $sweepDir "sweep-$stamp-screened.csv"

$summaryCols = 'Company','Title','Location','Remote','Pay','Degree','NeedsLicence','Posted','ReqId','Source','Url'

if ($candidates.Count -gt 0) {
    $candidates | Select-Object $summaryCols | Export-Csv -Path $candCsv -NoTypeInformation -Encoding UTF8
    $candidates | Select-Object ($summaryCols + 'Reason','Content') | ConvertTo-Json -Depth 4 |
        Out-File -FilePath $candJson -Encoding UTF8
}
if ($screened.Count -gt 0) {
    $screened | Select-Object ($summaryCols + 'Reason') | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
}

Write-Host ''
Write-Log "CANDIDATES: $($candidates.Count)" 'OK'
$candidates | Select-Object Company,Title,Location,Remote,Pay,Degree | Format-Table -AutoSize
Write-Log "SCREENED OUT: $($screened.Count)  (see $([IO.Path]::GetFileName($outCsv)))"

if ($candidates.Count -gt 0) {
    Write-Log "Wrote $candCsv"
    Write-Log "Wrote $candJson  <- hand this one to Claude" 'OK'
}

# --- update state ---------------------------------------------------------
if ($DryRun) {
    Write-Log 'DryRun: state file NOT updated.'
} else {
    try {
        foreach ($p in $new) { $seen[$p.Key] = $stamp }
        $seen | ConvertTo-Json -Depth 3 | Out-File -FilePath $stateFile -Encoding UTF8
        Write-Log "State updated: $($seen.Count) requisitions now tracked."
    } catch {
        Write-Log "Could not write the state file -- the next run will re-report these postings. $($_.Exception.Message)" 'ERROR'
    }
}

Complete-Run
exit $script:ExitCode
