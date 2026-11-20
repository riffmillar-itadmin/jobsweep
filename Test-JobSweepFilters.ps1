<#
.SYNOPSIS
    Regression tests for Invoke-JobSweep.ps1's screening filters.

.DESCRIPTION
    Every silent-screening bug this toolset has had looked like "nothing was
    posted this week": \bmanager\b killing Software Asset Manager, a bare 'entra'
    matching CENTRAl Kitchen, a namesake city passing on a bare state name, a degree flag
    dropping a licensing req on a degree flag. None of them threw an error. A green
    exit code says the plumbing worked, not that the filter is right.

    This script pulls the $Config block and the pure Test-*/Get-* functions out of
    Invoke-JobSweep.ps1 using the PowerShell AST -- so it tests the real filter, not
    a copy that can drift -- and asserts on the cases that have actually bitten,
    plus the titles the profile most wants to survive.

    No network, no state, no output files. Run it after ANY change to the title,
    location or remote lists.

.EXAMPLE
    .\Test-JobSweepFilters.ps1

.EXAMPLE
    .\Test-JobSweepFilters.ps1 -BothEditions
    Runs the suite under Windows PowerShell 5.1 and PowerShell 7. Exits 1 if
    either fails or is not installed. Run this before every commit.
#>

[CmdletBinding()]
param(
    [string]   $SweepScript = "$PSScriptRoot\Invoke-JobSweep.ps1",
    # Profiles to merge onto the defaults before testing. Defaults to the pair
    # beside the sweep script -- point this at another profile to test it.
    [string[]] $ProfilePath,
    # Re-run this suite, with the same arguments, under powershell.exe AND pwsh.
    [switch]   $BothEditions,
    # Where a run writes its counts as JSON. -BothEditions sets this for each
    # edition so the summary table can show them; you never need to.
    [string]   $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The collector claims 5.1 and 7, and the two differ in ways that bite: web error
# shapes, default encodings, what -File does with an array argument. A green run
# on one edition says nothing about the other, so -BothEditions runs each in its
# own process and fails if either fails -- or is missing, since a skipped edition
# is exactly the silent pass this suite exists to prevent.
if ($BothEditions) {
    # -Command rather than -File: -File passes an array as one string, which
    # would break -ProfilePath.
    $q    = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $call = "& $(& $q $PSCommandPath) -SweepScript $(& $q $SweepScript)"
    if ($ProfilePath) { $call += ' -ProfilePath ' + (($ProfilePath | ForEach-Object { & $q $_ }) -join ',') }

    # Each edition writes its counts and profile to its own temp file, so the
    # summary is one table that holds the whole result. A run that dies before
    # writing it shows '-' in those columns and fails on its exit code.
    $results = foreach ($exe in 'powershell.exe', 'pwsh') {
        Write-Host "`n==== $exe ====" -ForegroundColor Cyan
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            Write-Host "$exe not found -- cannot test this edition." -ForegroundColor Red
            [pscustomobject][ordered]@{ Edition = $exe; Version = '-'; Profile = '-'; Pass = '-'; Fail = '-'; Skipped = '-'; Result = 'MISSING' }
            continue
        }
        $out = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-result-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $ver = & $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        & $exe -NoProfile -ExecutionPolicy Bypass -Command ($call + ' -ResultPath ' + (& $q $out) + '; exit $LASTEXITCODE') | Out-Host
        $code = $LASTEXITCODE
        $r = $null
        if (Test-Path -LiteralPath $out) {
            try { $r = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json }
            catch { Write-Host "Could not read the $exe result file: $($_.Exception.Message)" -ForegroundColor Red }
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
        [pscustomobject][ordered]@{
            Edition = $exe
            Version = "$ver"
            Profile = $(if ($r) { $r.Profile } else { '-' })
            Pass    = $(if ($r) { $r.Pass } else { '-' })
            Fail    = $(if ($r) { $r.Fail } else { '-' })
            Skipped = $(if ($r) { $r.Skipped } else { '-' })
            Result  = $(if ($code -eq 0 -and $r) { 'PASS' } elseif ($code -eq 0) { 'FAIL (no counts written)' } else { "FAIL (exit $code)" })
        }
    }

    $results = @($results)
    $num = { param($v) if ("$v" -match '^\d+$') { [int]$v } else { 0 } }
    $sumPass = 0; $sumFail = 0; $sumSkip = 0
    foreach ($r in $results) { $sumPass += & $num $r.Pass; $sumFail += & $num $r.Fail; $sumSkip += & $num $r.Skipped }
    # An edition that is missing or died counts as a failure even with no FAIL rows.
    $bad = @($results | Where-Object { $_.Result -ne 'PASS' }).Count
    if ($bad -gt 0 -and $sumFail -eq 0) { $sumFail = $bad }
    . (Join-Path $PSScriptRoot 'JobSweep.Summary.ps1')
    Write-JobSweepSummary -Script 'Test-JobSweepFilters.ps1 -BothEditions' -Target $SweepScript `
        -Rows $results -Pass $sumPass -Fail $sumFail -Skip $sumSkip
    if ($bad -gt 0) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $SweepScript)) { throw "Sweep script not found: $SweepScript" }

# ---- extract the config and the pure functions, straight from the real script ----
$src = Get-Content -Raw -LiteralPath $SweepScript
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    $parseErrors | ForEach-Object { Write-Host "PARSE ERROR line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    throw 'Sweep script does not parse. Fix that before testing filters.'
}

$want = @('Test-TitleMatch','Test-LocationMatch','Test-IsRemote','Test-IsRemoteTitle','Test-RemoteFlags',
          'Test-LicenceRequired','Get-DegreeFlag','Get-PayRange','Repair-TitleCase','Test-DeveloperRole',
          'Test-PhysicalDemand','Test-IsRequisitionId','Test-LooksLikeLocationList','Resolve-WorkdayBullets',
          'Test-ComplianceTitleOnly','Test-ItContext','Merge-JobSweepProfile',
          'ConvertFrom-DayforcePosting','Get-DayforcePay','Test-ClearanceRequired',
          'Get-JsonValue','Get-WorkdayShortfall','ConvertFrom-RetryAfter','Get-RetryWait',
          'New-Posting','Convert-HtmlToText','Get-WorkdayJobs','Get-GreenhouseJobs','Get-LeverJobs',
          'ConvertFrom-RipplingListItem','Merge-RipplingRow','Get-RipplingPay','ConvertTo-IsoText',
          'Get-RipplingJobs','Add-RipplingDetail',
          'Get-PaylocityPageData','ConvertFrom-PaylocityJob','ConvertFrom-PaylocityDetail',
          'Get-PaylocityJobs','Add-PaylocityDetail',
          'Get-ApplicantProDomainId','ConvertTo-ApplicantProPay','ConvertFrom-ApplicantProJob',
          'ConvertFrom-ApplicantProDetail','Get-ApplicantProSitemapId','Get-ApplicantProJobs','Add-ApplicantProDetail',
          'Get-MicrosoftQuery','Get-MicrosoftGapText','Get-MicrosoftJobs','Get-RetryCoolOffWait',
          'Invoke-MicrosoftRetryPass','Get-WebTimeoutParameter','Get-GiveUpLevel',
          'Get-HttpFailure','Test-HttpNotFound','Get-AdpHost','Get-AdpOtherHost','Get-AdpJobs')
$parts = @()

$assign = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$Config' }, $true))
if ($assign.Count -eq 0) { throw 'Could not find the $Config assignment in the sweep script.' }
$parts += $assign[0].Extent.Text

# The search profile moved out of the script on 2026-10-06, so extracting $Config
# alone now yields the generic defaults only. Re-apply the real merge -- the same
# function the collector calls -- so these cases still test what actually runs.
# Pass -ProfilePath to point the whole suite at a different profile.
if (-not $ProfilePath) {
    $scriptDir   = Split-Path -Parent $SweepScript
    # Defaults to the SHIPPED pair so a fresh clone runs green with no setup:
    # the real targeting list (published deliberately -- it describes a search,
    # not a person) plus the EXAMPLE geography. Your own JobSweep.local.psd1 is
    # gitignored and is NOT the default -- point -ProfilePath at it to test it,
    # which is what Test-JobSweepProfile.ps1 does.
    $ProfilePath = @(
        (Join-Path $scriptDir 'JobSweep.targeting.psd1')
        (Join-Path $scriptDir 'JobSweep.local.example.psd1')
    )
}

$fns = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $want -contains $n.Name }, $true))
foreach ($f in $fns) { $parts += $f.Extent.Text }

$missing = @($want | Where-Object { $fns.Name -notcontains $_ })
if ($missing.Count -gt 0) { Write-Host "NOTE: not found in the sweep, skipped: $($missing -join ', ')" -ForegroundColor Yellow }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-filters-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $tmp -Value ($parts -join "`n`n") -Encoding utf8
try { . $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

# Overlay the profile exactly as the collector does, using the collector's own
# merge function. Without this every title and location case below would be
# asserting against the bare defaults.
$Config = Merge-JobSweepProfile -Defaults $Config -ProfilePath $ProfilePath
Write-Host ("Profile: {0}" -f ($ProfilePath -join ' + ')) -ForegroundColor DarkGray

$pass = 0; $fail = 0; $skipped = 0
function Check {
    param([string]$What, $Got, $Want)
    if ("$Got" -eq "$Want") { $script:pass++ }
    else { $script:fail++; Write-Host ("  FAIL  {0}`n        got  '{1}'`n        want '{2}'" -f $What, $Got, $Want) -ForegroundColor Red }
}

# EXAMPLE-GEOGRAPHY CHECKS name the FICTIONAL region in JobSweep.local.example.psd1
# (Westmark, Harborview, Brookfield...). They hold only against that profile, so
# against your own they are skipped and COUNTED, never silently passed. Your own
# places belong in Test-JobSweepProfile.ps1, the private suite beside your profile.
$exampleGeo = @($ProfilePath | Where-Object { (Split-Path $_ -Leaf) -eq 'JobSweep.local.example.psd1' }).Count -gt 0
function CheckGeo {
    param([string]$What, $Got, $Want)
    if ($script:exampleGeo) { Check $What $Got $Want } else { $script:skipped++ }
}

# A check that throws stops the cases after it, but never the summary: the throw
# is counted as a FAIL and named, and the summary below still prints.
$stoppedBy = ''
try {

Write-Host "`n-- LOCATION: onsite still screened as before --"
CheckGeo 'Harborview onsite'        (Test-LocationMatch 'Harborview, WM').Ok            $true
CheckGeo 'Brookfield onsite'       (Test-LocationMatch 'Brookfield, WM').Ok           $true
Check 'Southgate onsite DROPS'   (Test-LocationMatch 'Southgate, WM').Ok             $false
Check 'Port Allen onsite DROPS'   (Test-LocationMatch 'Port Allen, WM').Ok             $false
Check 'Washington DC DROPS'   (Test-LocationMatch 'Washington, DC').Ok         $false
Check 'US-DC- form DROPS'     (Test-LocationMatch 'US-DC-Washington').Ok       $false
Check 'Austin onsite DROPS'   (Test-LocationMatch 'Austin, TX').Ok             $false
Check 'blank passes'          (Test-LocationMatch '').Ok                       $true

Write-Host "`n-- LOCATION: national remote now IN --"
Check 'Remote - US'           (Test-LocationMatch 'Remote - US').Ok            $true
Check 'Remote Texas'          (Test-LocationMatch 'Remote, Austin TX').Ok      $true
Check 'USA-Remote'            (Test-LocationMatch 'USA-Remote').Ok             $true
Check 'Work from home'        (Test-LocationMatch 'Work From Home').Ok         $true
Check 'remote beats commute'  (Test-LocationMatch 'Remote - Southgate, WM').Ok    $true
Check 'remote beats DC'       (Test-LocationMatch 'Remote - Washington, DC').Ok $true

Write-Host "`n-- LOCATION: outside the US still out, remote or not --"
Check 'Toronto DROPS'         (Test-LocationMatch 'Toronto, Ontario').Ok       $false
Check 'Remote India DROPS'    (Test-LocationMatch 'Remote - Bengaluru, India').Ok $false
Check 'Remote UK DROPS'       (Test-LocationMatch 'Remote, London, UK').Ok     $false

Write-Host "`n-- LOCATION: multi-city reqs go to judgement, not the bin (added 2026-09-19) --"
# Every one of these is a real string from sweep-2026-09-18-1923.
Check '4-city req KEPT'       (Test-LocationMatch 'Atlanta, GA | Washington, DC | Chicago, IL | New York, NY').Ok $true
Check 'multi-city req KEPT'    (Test-LocationMatch 'Main Campus | Austin, TX | Boston, MA | Washington, DC | Harborview, WM').Ok $true
Check 'N Locations KEPT'       (Test-LocationMatch '3 Locations').Ok               $true
Check 'single DC still DROPS'  (Test-LocationMatch 'Washington, DC').Ok            $false
Check 'single PaloAlto DROPS'  (Test-LocationMatch 'Palo Alto, CA').Ok             $false
Check 'multi-city non-US DROPS' (Test-LocationMatch 'Toronto, Ontario | London, UK').Ok $false

Write-Host "`n-- REMOTE VETTING --"
CheckGeo 'state excluded BLOCKS' (Test-RemoteFlags 'This role is remote. We are not able to hire in the following states: Westmark, Colorado.').Block 'remote role excludes your state of residence'
CheckGeo 'state ineligible BLOCKS' (Test-RemoteFlags 'Residents of California and Westmark are not eligible for this position.').Block 'remote role excludes your state of residence'
Check 'clean posting no block' (Test-RemoteFlags 'Fully remote across the United States. Competitive pay.').Block ''
$et = Test-RemoteFlags 'Candidates must provide coverage during Eastern Time business hours.'
Check 'ET flagged'  ($et.Flags -join '|')  'CHECK: Eastern-hours coverage stated -- confirm the start time in your time zone'
$hy = Test-RemoteFlags 'Remote, but must reside within commuting distance of our Chicago office.'
Check 'fake remote flagged' ($hy.Flags -join '|') 'CHECK: remote in name only -- requires living near an office'
Check 'blank text safe' (Test-RemoteFlags '').Block ''

Write-Host "`n-- TITLE: the regressions that have bitten before --"
Check 'Software Asset Manager KEPT'   (Test-TitleMatch 'Software Asset Manager').Ok        $true
Check 'IT Asset Manager KEPT'         (Test-TitleMatch 'Senior IT Asset Manager').Ok       $true
Check 'ITAM Governance Manager KEPT'  (Test-TitleMatch 'ITAM Governance Manager').Ok       $true
Check 'Service Desk Manager DROPS'    (Test-TitleMatch 'Service Desk Manager').Ok          $false
Check 'Supervisor DROPS'              (Test-TitleMatch 'Supervisor, Systems Support').Ok   $false
Check 'QA Analyst DROPS'              (Test-TitleMatch 'Quality Assurance Analyst').Ok     $false
Check 'Central Kitchen DROPS'         (Test-TitleMatch 'Central Kitchen Helper Clerk').Ok  $false
Check 'Williams name DROPS'           (Test-TitleMatch 'Williams Account Executive').Ok    $false
Check 'Endpoint Engineer KEPT'        (Test-TitleMatch 'Endpoint Engineer').Ok             $true
Check 'HW Asset Mgmt Developer KEPT'  (Test-TitleMatch 'Hardware Asset Management Technical Developer').Ok $true
Check 'SAM ServiceNow Dev KEPT'       (Test-TitleMatch 'ServiceNow Developer - Software Asset Management').Ok $true
Check 'Sr IT Asset Mgmt Analyst KEPT' (Test-TitleMatch 'Senior IT Asset Management Analyst').Ok $true
Check 'plain Developer still DROPS'   (Test-TitleMatch 'Senior Software Developer').Ok        $false
Check 'Engineering Manager DROPS'     (Test-TitleMatch 'Engineering Manager').Ok              $false

Write-Host "`n-- CLINICAL AND LICENSING: the Sept 10 sweep's false positives --"
Check 'Licensed Therapist DROPS'      (Test-TitleMatch 'Licensed Child, Youth & Family Therapist').Ok        $false
Check 'Mental Health Prof DROPS'      (Test-TitleMatch 'Mental Health Professional Licensed - CSS Adult').Ok $false
Check 'MH Therapist DROPS'            (Test-TitleMatch 'Mental Health Therapist (Licensed or Associate)').Ok $false
Check 'Peer Support Spec DROPS'       (Test-TitleMatch 'Certified Peer Support Specialist').Ok               $false
Check 'ORSA DROPS'                    (Test-TitleMatch 'Operations Research Systems Analyst (Orsa) Mid').Ok  $false
Check 'IT Contracts+Licensing KEPT'   (Test-TitleMatch 'IT Contracts & Licensing Specialist III').Ok         $true
Check 'Cust Licensing Mgr KEPT'       (Test-TitleMatch 'Customer Licensing Alignment Manager').Ok            $true
Check 'License Compliance Anly KEPT'  (Test-TitleMatch 'License Compliance Analyst').Ok                      $true
Check 'Software Licensing Anly KEPT'  (Test-TitleMatch 'Software Licensing Analyst').Ok                      $true

Write-Host "`n-- TITLE: the three reqs the sweep threw away on 2026-09-18 --"
Check 'IT Infra Administrator KEPT'   (Test-TitleMatch 'IT Infrastructure Administrator').Ok                 $true
Check 'Cloud Platform Engineer KEPT'  (Test-TitleMatch 'Cloud Platform Engineer - Azure').Ok                 $true
Check 'IT Engineer Apps KEPT'         (Test-TitleMatch 'IT Engineer Applications').Ok                        $true
Check 'Solutions Architect KEPT'      (Test-TitleMatch 'Senior Solutions Architect-Cloud').Ok                $true
Check 'Cloud Engineer KEPT'           (Test-TitleMatch 'Cloud Engineer II').Ok                               $true

Write-Host "`n-- TITLE: Microsoft Service Engineering and datacenter, added 2026-09-24 --"
# The sweep collected and discarded this exact title on 2026-09-23.
Check 'Platform Service Eng KEPT'     (Test-TitleMatch 'Platform Service Engineer [Service Engineering]').Ok $true
Check 'Service Engineer II KEPT'      (Test-TitleMatch 'Service Engineer II - Ads Platform').Ok              $true
Check 'Site Reliability Eng KEPT'     (Test-TitleMatch 'Senior Site Reliability Engineer').Ok                $true
Check 'Cloud Ops Engineer KEPT'       (Test-TitleMatch 'Cloud Operations Engineer').Ok                       $true
# ...and the exclude list must still win over every one of the five new patterns.
Check 'DC Program Manager DROPS'      (Test-TitleMatch 'Data Center IT Program Manager').Ok                  $false
Check 'SRE Manager DROPS'             (Test-TitleMatch 'Site Reliability Engineering Manager').Ok            $false
Check 'Service Eng Internship DROPS'  (Test-TitleMatch 'Service Engineer Internship').Ok                     $false
Check 'DC Sales Exec DROPS'           (Test-TitleMatch 'Data Center Account Executive').Ok                   $false
# 'data\s?cent' was removed again on 2026-09-24 -- datacenter-floor roles are gated on
# physical grounds now, so the keyword had nothing left to justify it.
Check 'Datacenter Eng no longer kept'  (Test-TitleMatch 'Datacenter Engineer').Ok                            $false

Write-Host "`n-- TITLE: aerospace engineering, added 2026-11-19 (1.8.5) --"
# A space company's board put these on the candidate list on 'systems engineer'
# week after week. Generic aerospace vocabulary drops them.
Check 'Avionics Systems Eng DROPS'      (Test-TitleMatch 'Avionics Systems Engineer III').Ok                         $false
Check 'Aerospace Systems Eng DROPS'     (Test-TitleMatch 'Aerospace Systems Engineer II').Ok                         $false
Check 'Spacecraft Verification DROPS'   (Test-TitleMatch 'Systems Engineer, Spacecraft Verification').Ok             $false
Check 'Safety and Reliability DROPS'    (Test-TitleMatch 'Program Safety and Reliability Senior Systems Engineer').Ok $false
Check 'Safety & Reliability DROPS'      (Test-TitleMatch 'Sr. System Safety & Reliability Systems Engineer').Ok      $false
Check 'Fluid Systems Eng DROPS'         (Test-TitleMatch 'Fluid Systems Engineer III - Third Stage').Ok              $false
Check 'Fluids Systems Eng DROPS'        (Test-TitleMatch 'Fluids Systems Engineer II').Ok                            $false
Check 'GN&C Systems Eng DROPS'          (Test-TitleMatch 'GN&C Systems Engineer II').Ok                              $false
Check 'GNC Systems Eng DROPS'           (Test-TitleMatch 'GNC Systems Engineer III').Ok                              $false
Check 'Propulsion Systems Eng DROPS'    (Test-TitleMatch 'Propulsion Systems Engineer').Ok                           $false
Check 'RF Systems Eng DROPS'            (Test-TitleMatch 'RF Systems Engineer III').Ok                               $false
Check 'Electrical Systems Eng DROPS'    (Test-TitleMatch 'Senior Electrical Systems Engineer').Ok                    $false
Check 'Electrical Power Eng DROPS'      (Test-TitleMatch 'Senior Systems Engineer - Electrical Power System').Ok     $false
Check 'Embedded Systems Eng DROPS'      (Test-TitleMatch 'Senior Embedded Systems Engineer').Ok                      $false
Check 'Mission Systems Eng DROPS'       (Test-TitleMatch 'Senior Mission Systems Engineer').Ok                       $false
Check 'Ground Systems Eng DROPS'        (Test-TitleMatch 'Sr. Ground Systems Engineer').Ok                           $false
Check 'Lunar Systems Eng DROPS'         (Test-TitleMatch 'Systems Engineer III - Fault Management, Lunar Lander').Ok $false
Check 'Autonomy Systems Eng DROPS'      (Test-TitleMatch 'Autonomy Software Systems Engineer II').Ok                 $false
Check 'Orbital platform eng DROPS'      (Test-TitleMatch 'Customer Platform Engineer III - Orbital Data Centers').Ok  $false
Check 'Avionics drop names the rule'    ((Test-TitleMatch 'Avionics Systems Engineer III').Reason -like '*avionics*') $true
# Left out on purpose: each of these is an IT title the same board posted.
Check 'Launch IT Support Analyst KEPT'  (Test-TitleMatch 'Launch Communications IT Support Analyst II').Ok            $true
Check 'Lunar Systems Admin KEPT'        (Test-TitleMatch 'Lunar Systems Administrator - Level 1').Ok                  $true
Check 'Identity Verification KEPT'      (Test-TitleMatch 'Identity Verification Analyst').Ok                          $true
Check 'Site Reliability Eng still KEPT' (Test-TitleMatch 'Senior Site Reliability Engineer').Ok                       $true
Check 'Endpoint Security Eng KEPT'      (Test-TitleMatch 'Endpoint Security Engineer III').Ok                         $true
Check 'M365 and Identity Admin KEPT'    (Test-TitleMatch 'Systems Administrator - M365 & Identity').Ok                $true
Check 'plain Systems Engineer KEPT'     (Test-TitleMatch 'Senior Systems Engineer').Ok                                $true
Check 'IT Systems Engineer KEPT'        (Test-TitleMatch 'IT Systems Engineer').Ok                                    $true

Write-Host "`n-- TITLE: well-being and wellness support roles, added 2026-11-19 (1.8.4) --"
# A hospital's "Well-being Support Specialist" reached the candidate list on
# 'support specialist' on 2026-11-18. It is a patient and staff support role.
Check 'Well-being Support Spec DROPS'  (Test-TitleMatch 'Well-being Support Specialist - Harborview Medical Center').Ok $false
Check 'Wellbeing (no hyphen) DROPS'    (Test-TitleMatch 'Wellbeing Support Specialist').Ok                    $false
Check 'Well being (space) DROPS'       (Test-TitleMatch 'Employee Well Being Support Analyst').Ok              $false
Check 'Wellness Support Spec DROPS'    (Test-TitleMatch 'Wellness Program Support Specialist').Ok              $false
Check 'Well-being drop names the rule' ((Test-TitleMatch 'Well-being Support Specialist').Reason -like '*well*being*') $true
# The plain target title is untouched.
Check 'IT Support Specialist still KEPT' (Test-TitleMatch 'IT Support Specialist II').Ok                       $true
Check 'Desktop Support Spec still KEPT'  (Test-TitleMatch 'Desktop Support Specialist').Ok                     $true

Write-Host "`n-- TITLE: client-care support specialists, added 2026-11-20 (1.11.1) --"
# The first dry run of the finder's new boards put these on the candidate list
# on 'support specialist'. Each is a human-services or branch role.
Check 'Crisis Support Spec DROPS'       (Test-TitleMatch 'Crisis Support Specialist (Day & Swing Shifts)').Ok  $false
Check 'Client Support Spec DROPS'       (Test-TitleMatch 'Client Support Specialist (On-Call)').Ok             $false
Check 'Family Support Spec DROPS'       (Test-TitleMatch 'Family Support Specialist').Ok                       $false
Check 'Resident Support Spec DROPS'     (Test-TitleMatch 'Bilingual Resident Support Specialist').Ok           $false
Check 'Clinical Support Spec DROPS'     (Test-TitleMatch 'Clinical Support Specialist - Day').Ok               $false
Check 'Member Support Spec DROPS'       (Test-TitleMatch 'Member Support Specialist (Harborview Branch)').Ok   $false
Check 'Crisis drop names the rule'      ((Test-TitleMatch 'Crisis Support Specialist').Reason -like '*crisis*') $true
# Client support with an IT word in the title is a help-desk role and stays.
Check 'IT Client Support Spec KEPT'     (Test-TitleMatch 'IT Client Support Specialist').Ok                    $true
Check 'Technical Client Support KEPT'   (Test-TitleMatch 'Technical Client Support Specialist II').Ok          $true
Check 'Desktop Client Support KEPT'     (Test-TitleMatch 'Client Support Specialist - Desktop').Ok             $true
# Clinical applications support is EHR work and is not a clinical support role.
Check 'Clinical Apps Support KEPT'      (Test-TitleMatch 'Clinical Applications Support Specialist').Ok        $true
Check 'Tech Support Spec still KEPT'    (Test-TitleMatch 'Tech Support Specialist I').Ok                       $true
Check 'Service Desk Support Spec KEPT'  (Test-TitleMatch 'Service Desk Support Specialist').Ok                 $true

Write-Host "`n-- TITLE: Microsoft customer support engineers, added 2026-11-18 (1.8.3) --"
# Three of these reached the candidate list on 'support engineer' on 2026-11-18.
# They are Microsoft's Customer Service & Support organisation: customer-facing.
Check 'MS Technical Support Eng DROPS'    (Test-TitleMatch 'Technical Support Engineer [Technical Support Engineering]').Ok        $false
Check 'MS Sr Technical Support Eng DROPS' (Test-TitleMatch 'Senior Technical Support Engineer [Technical Support Engineering]').Ok $false
Check 'MS TSE drop names the rule'        ((Test-TitleMatch 'Technical Support Engineer [Technical Support Engineering]').Reason -like '*technical support engineer*') $true
# Scoped to that title in that discipline. Elsewhere the title is still a target.
Check 'Technical Support Eng elsewhere KEPT' (Test-TitleMatch 'Technical Support Engineer II').Ok                               $true
Check 'MS Platform Service Eng still KEPT'   (Test-TitleMatch 'Platform Service Engineer [Service Engineering]').Ok             $true
Check 'IT support engineer still KEPT'       (Test-TitleMatch 'IT Support Engineer').Ok                                         $true

Write-Host "`n-- TITLE: the seven 'it ' patterns are word-anchored, added 2026-10-06 --"
# Found when a bank's "Senior Credit Analyst - CRE" reached the candidate list with
# Reason "title matched: it analyst" -- matching inside the word CredIT ANALYST.
# These must KEEP matching: the boundary sits before it, not inside the role word.
Check 'IT Analyst KEPT'               (Test-TitleMatch 'IT Analyst').Ok                                     $true
Check 'Senior IT Analyst KEPT'        (Test-TitleMatch 'Senior IT Analyst').Ok                              $true
Check 'IT Operations Analyst KEPT'    (Test-TitleMatch 'IT Operations Analyst').Ok                          $true
Check 'IT Specialist II KEPT'         (Test-TitleMatch 'IT Specialist II').Ok                               $true
Check 'IT Administrator KEPT'         (Test-TitleMatch 'IT Administrator').Ok                               $true
Check 'Lead IT Engineer KEPT'         (Test-TitleMatch 'Lead IT Engineer').Ok                               $true
Check 'IT Auditor II KEPT'            (Test-TitleMatch 'IT Auditor II').Ok                                  $true
Check 'Internal IT Audit Lead KEPT'   (Test-TitleMatch 'Internal IT Audit Lead').Ok                         $true
# ...and these must now DROP. Every one is a real financial-services title shape, which is
# why the bug only surfaced once a bank and an insurer were added to the Sources block.
Check 'Credit Analyst DROPS'          (Test-TitleMatch 'Senior Credit Analyst Cre').Ok                      $false
Check 'Credit Operations Spec DROPS'  (Test-TitleMatch 'Credit Operations Specialist').Ok                   $false
Check 'Deposit Operations Anly DROPS' (Test-TitleMatch 'Deposit Operations Analyst').Ok                     $false
Check 'Audit Analyst DROPS'           (Test-TitleMatch 'Audit Analyst').Ok                                  $false
Check 'Credit Administrator DROPS'    (Test-TitleMatch 'Credit Administrator').Ok                           $false
Check 'Credit Specialist DROPS'       (Test-TitleMatch 'Credit Specialist').Ok                              $false
Check 'Credit Audit Manager DROPS'    (Test-TitleMatch 'Credit Audit Manager').Ok                           $false
Check 'Credit Auditor DROPS'          (Test-TitleMatch 'Credit Auditor').Ok                                 $false
Check 'Summit Engineer DROPS'         (Test-TitleMatch 'Summit Engineer').Ok                                $false
Check 'Permit Specialist DROPS'       (Test-TitleMatch 'Permit Specialist').Ok                              $false

Write-Host "`n-- PHYSICAL DEMAND: threshold behaviour, and the boilerplate it must not eat --"
# Every case below passes -LiftingLimitLb EXPLICITLY. The function reads its default
# from the profile, so asserting against the default would make these cases depend on
# whoever's profile is loaded -- and the same assertion would then pass or fail purely
# on configuration. Pin the threshold here and the cases test the FUNCTION.
$lim = 25
$physCanonical = 'Ability to lift and rack equipment up to 50 lbs. and work in physically demanding data center environments'
Check 'canonical clause SCREENS OUT'   (@(Test-PhysicalDemand $physCanonical -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count -ge 1) $true
Check '50 lb lift SCREENS OUT'         (@(Test-PhysicalDemand 'Must be able to lift up to 50 pounds.' -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count) 1
Check '75 lbs+ SCREENS OUT'            (@(Test-PhysicalDemand 'Lifting 75 lbs+ required' -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count) 1
Check 'physically demanding SCREENS'   (@(Test-PhysicalDemand 'This is a physically demanding role.' -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count) 1
Check 'rack and stack SCREENS OUT'     (@(Test-PhysicalDemand 'Rack and stack servers on the floor.' -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count) 1
# Accessibility boilerplate on an ordinary desk job must NOT cost a lead.
Check '10 lb boilerplate PASSES'       (@(Test-PhysicalDemand 'Must be able to lift up to 10 pounds occasionally.' -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count) 0
Check 'a small figure PASSES'          (@(Test-PhysicalDemand 'Occasionally lift up to 20 lbs.' -LiftingLimitLb $lim | Where-Object { $_.Level -eq 'out' }).Count) 0
# THE THRESHOLD IS CONFIGURABLE, and that is the point of the parameter: the same
# posting screens out at one limit and passes at another.
Check 'same clause passes at 60'       (@(Test-PhysicalDemand 'Must be able to lift up to 50 pounds.' -LiftingLimitLb 60 | Where-Object { $_.Level -eq 'out' }).Count) 0
Check 'and screens out at 40'          (@(Test-PhysicalDemand 'Must be able to lift up to 50 pounds.' -LiftingLimitLb 40 | Where-Object { $_.Level -eq 'out' }).Count) 1
Check 'desk job PASSES'                (@(Test-PhysicalDemand 'Prolonged periods sitting at a desk and working on a computer.' -LiftingLimitLb $lim).Count) 0
Check 'empty text PASSES'              (@(Test-PhysicalDemand '').Count)                                     0
# Softer phrases flag for a human rather than dropping the lead.
Check 'ladders FLAG not drop'          (@(Test-PhysicalDemand 'May require climbing ladders.' | Where-Object { $_.Level -eq 'check' }).Count) 1
Check 'ladders does NOT screen out'    (@(Test-PhysicalDemand 'May require climbing ladders.' | Where-Object { $_.Level -eq 'out' }).Count)   0
# The new keywords must not reopen anything the exclude list already closed.
Check 'Infra Manager still DROPS'     (Test-TitleMatch 'Infrastructure Manager').Ok                          $false
Check 'Infra Director still DROPS'    (Test-TitleMatch 'Director of Infrastructure').Ok                      $false
Check 'Platform SWE still DROPS'      (Test-TitleMatch 'Platform Software Engineer').Ok                      $false

# The commute-geography cases moved to Test-JobSweepProfile.ps1 on 2026-10-12.
# They asserted on the author's own suburb boundary, which lives in the gitignored
# JobSweep.local.psd1 -- so they could only ever pass against that one profile.
# Point -ProfilePath at your own local profile and assert your own cities there.

Write-Host "`n-- DEVELOPER IN DISGUISE: a systems title over an engineering job --"
$sysadmin = @'
Senior Systems Engineer. Administer Windows Server and Linux infrastructure, manage
patching and configuration, support end users, write PowerShell scripts to automate
routine tasks, and maintain documentation and runbooks. On-call rotation.
'@
$devrole = @'
Senior Systems Engineer. You will design and develop software services for our research
platform. 5+ years of software engineering experience. Proficiency in Python and C++.
Participate in code reviews and pull requests, write unit tests, and own features through
the software development lifecycle. Degree in Computer Science or equivalent.
'@
$borderline = @'
Systems Administrator. Automate provisioning with PowerShell and Python. You will
participate in code reviews for infrastructure-as-code changes.
'@
Check 'real sysadmin NOT flagged'   (@(Test-DeveloperRole $sysadmin).Count)                    0
Check 'developer role IS flagged'   ([bool](@(Test-DeveloperRole $devrole).Count -ge 2))       $true
Check 'borderline needs 2 signals'  (@(Test-DeveloperRole $borderline).Count -eq 1)            $false
Check 'blank text safe'             (@(Test-DeveloperRole '').Count)                           0
Check 'C++ proficiency detected'    ([bool](@(Test-DeveloperRole "Proficiency in Python and C++. Write unit tests.") -contains 'compiled-language proficiency')) $true
Check 'C# proficiency detected'     ([bool](@(Test-DeveloperRole "Proficiency in C#. Participate in code reviews.")     -contains 'compiled-language proficiency')) $true
$sig = @(Test-DeveloperRole $devrole)
Write-Host ("        signals on the developer posting: {0}" -f ($sig -join '; '))

Write-Host "`n-- LICENCE / DEGREE --"
Check 'licence required'  ([bool](Test-LicenceRequired 'Valid driver''s license and reliable transportation required.')) $true
Check 'no licence'        ([bool](Test-LicenceRequired 'Fully remote role.')) $false
Check 'hard degree'       (Get-DegreeFlag 'MINIMUM QUALIFICATIONS: Bachelor''s degree in Information Technology.') 'hard'
Check 'equivalency'       (Get-DegreeFlag 'Bachelor''s degree or equivalent combination of education and experience.') 'equivalency'
Check 'no degree asked'   (Get-DegreeFlag 'Three years of professional experience.') 'none'
Check 'blank unknown'     (Get-DegreeFlag '') 'unknown'

Write-Host "`n-- PAY RANGE: salary scale still works, hourly bands now do too (added 2026-09-20) --"
# Salary scale -- the behaviour that already worked and must not regress.
Check 'annual with en dash'   (Get-PayRange ('Salary range is $78,000 ' + [char]0x2013 + ' $180,000 per year')) ('$78,000 ' + [char]0x2013 + ' $180,000 per year')
Check 'monthly band'          (Get-PayRange 'Salary range of $8,960-$12,120 per month (dependent upon experience)') '$8,960-$12,120'
Check 'annual hyphen'         (Get-PayRange 'Base is $73,000-$81,580 and BCG says') '$73,000-$81,580'
Check 'trailing comma gone'   (Get-PayRange 'Salary range is $78,000 to $180,000, with a midpoint') '$78,000 to $180,000'
# Hourly bands under $100 -- every one of these returned EMPTY before today.
Check 'hourly no dollar 2nd'  (Get-PayRange 'The rate is $60-70/hr for this engagement') '$60-70/hr'
Check 'hourly en dash'        (Get-PayRange ('band is $32' + [char]0x2013 + '$46/hr and you were submitted')) ('$32' + [char]0x2013 + '$46/hr')
Check 'hourly with cents'     (Get-PayRange 'Pay is $34.35 - $46.20 per hour depending on experience') '$34.35 - $46.20 per hour'
Check 'hourly spelled out'    (Get-PayRange '$25 to $32 an hour') '$25 to $32 an hour'
# Prose that must NOT be read as pay. This is what branch 1's width requirement protects.
Check 'copay not pay'         (Get-PayRange 'a $5 to $10 copay applies') ''
Check 'single figure not pay' (Get-PayRange 'zero-dollar premiums with $10 copays, dental, vision') ''
Check 'percentage not pay'    (Get-PayRange 'Add the bonus of up to 12% and a retirement contribution') ''
Check 'lone rate not a range' (Get-PayRange 'and $46/hr on W-2 with benefits') ''
Check 'tuition cap not pay'   (Get-PayRange 'will pay up to $5,000 annually for approved tuition') ''
Check 'blank text safe'       (Get-PayRange '') ''

Write-Host "`n-- PAY RANGE: shapes real sweeps left blank (added 2026-11-03) --"
# A check of every real sweep found Pay blank on 47 postings that stated pay. Each case is
# one shape that was missed; none of them ever produced a wrong figure, only an empty one.
Check 'html em dash spans'    (Get-PayRange '<div class="pay-range"><span>$150,000</span><span class="divider">&mdash;</span><span>$190,000 USD</span></div>') ('$150,000 ' + [char]0x2014 + ' $190,000')
Check 'k figures'             (Get-PayRange 'Salary range is $70k to $150k, with a midpoint of $110k.') '$70k to $150k'
Check 'min max labelled yr'   (Get-PayRange "Pay Range Minimum:`n`$64,500.00 annual Pay Range Maximum:`n`$91,200.00 annual Other Compensation") '$64,500.00 - $91,200.00 per year'
Check 'min max short hourly'  (Get-PayRange "Min`n`nUSD `$24.10/Hr.`n`nMax`n`nUSD `$29.90/Hr.`n`nQualifications") '$24.10 - $29.90 per hour'
Check 'hourly unit first'     (Get-PayRange 'The hourly pay range for this position is from $31.10 to $44.60 and pay offered') '$31.10 to $44.60 per hour'
Check 'pay range cents only'  (Get-PayRange 'Pay Range is $21.40-$33.80') '$21.40-$33.80'
Check 'USD before each side'  (Get-PayRange 'Pay Range USD $18.00 - USD $21.00 /Hr. Overview') '$18.00 - USD $21.00 /Hr'
# Still not pay: these sat in the same real postings and must stay blank.
Check 'sign-on bonus not pay' (Get-PayRange 'Potentially up to $5,000 sign on bonus for qualified external candidates!') ''
Check 'revenue not pay'       (Get-PayRange 'the platform processes over 110M transactions and $40B annually.') ''
Check 'placeholder band'      (Get-PayRange '<span>$1</span><span class="divider">&mdash;</span><span>$2 USD</span>') ''
Check 'open-ended figure'     (Get-PayRange 'The range for this position is from $120,000+ with offers contingent') ''
Check 'copay still not pay'   (Get-PayRange 'Pay Range: a $5.00 to $10.00 copay applies') ''

Write-Host "`n-- DAYFORCE: search postings and detail pay (added 2026-11-03) --"
# Shapes from a live board, with every value invented. The search gives text and
# locations; pay comes only from the detail call's jobPostingAttributes.
$dfJson = @'
[
  { "jobPostingId": 9101, "jobReqId": 4402, "jobTitle": "Endpoint Engineer",
    "postingStartTimestampUTC": "2026-10-30T16:00:00Z", "hasVirtualLocation": false,
    "jobDescription": "<p>Manage <b>Intune</b>.</p>",
    "postingLocations": [ { "cityName": "Harborview", "stateCode": "WM", "formattedAddress": "1 Dock St, Harborview, WM" },
                          { "cityName": "Brookfield", "stateCode": "WM" },
                          { "cityName": "Harborview", "stateCode": "WM" } ] },
  { "jobPostingId": 9102, "jobTitle": "Desktop Support Analyst", "hasVirtualLocation": true,
    "postingLocations": [ { "cityName": "Harborview", "stateCode": "WM" } ] },
  { "jobPostingId": 9103, "jobTitle": "Systems Administrator", "hasVirtualLocation": true, "postingLocations": [] },
  { "jobPostingId": 9104, "jobTitle": "IT Technician", "postingLocations": [ { "formattedAddress": "Millbrook Campus" } ] }
]
'@ | ConvertFrom-Json
$df = @($dfJson | ForEach-Object { ConvertFrom-DayforcePosting $_ })
Check 'df id'                   $df[0].Id        '9101'
Check 'df req # from jobReqId'  $df[0].ReqId     '4402'
Check 'df req # falls back'     $df[1].ReqId     '9102'
Check 'df title'                $df[0].Title     'Endpoint Engineer'
Check 'df posted'               $df[0].Posted    '2026-10-30T16:00:00Z'
Check 'df locations deduped'    $df[0].Location  'Harborview, WM | Brookfield, WM'
Check 'df onsite not remote'    $df[0].Remote    $false
Check 'df virtual + office'     $df[1].Location  'Remote | Harborview, WM'
Check 'df virtual only'         $df[2].Location  'Remote'
Check 'df address fallback'     $df[3].Location  'Millbrook Campus'
Check 'df no description'       $df[1].Html      ''
Check 'df virtual reads remote' (Test-LocationMatch $df[1].Location).Ok $true
Check 'df virtual is remote'    (Test-IsRemote $df[2].Location) $true

$dfAttr = { param($pairs) @($pairs.GetEnumerator() | ForEach-Object { [pscustomobject]@{ name = $_.Key; value = $_.Value } }) }
Check 'df pay salary'           (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '85000'; HiringMaxRate = '105000'; PayType = 'Salary' })) '$85,000 - $105,000'
Check 'df pay hourly by type'   (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '24.1'; HiringMaxRate = '29.9'; PayType = 'Hourly' })) '$24.10 - $29.90 per hour'
Check 'df pay hourly by size'   (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '31.10'; HiringMaxRate = '44.60' })) '$31.10 - $44.60 per hour'
Check 'df pay commas and $'     (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '$70,000.00'; HiringMaxRate = '$90,000.00' })) '$70,000 - $90,000'
Check 'df lone min not pay'     (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '85000'; PayType = 'Salary' })) ''
Check 'df max below min'        (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '90000'; HiringMaxRate = '80000' })) ''
Check 'df zero not pay'         (Get-DayforcePay (& $dfAttr @{ HiringMinRate = '0'; HiringMaxRate = '0' })) ''
Check 'df no attributes'        (Get-DayforcePay @()) ''
Check 'df other value key'      (Get-DayforcePay @([pscustomobject]@{ name = 'HiringMinRate'; attributeValue = '60000' },
                                                  [pscustomobject]@{ name = 'HiringMaxRate'; attributeValue = '75000' })) '$60,000 - $75,000'

# ---- REMOTE STATED IN THE TITLE, added 2026-09-21 ------------------------
# An employer filing a fully remote req against its out-of-state head office.
Check 'head-office title rescue' (Test-LocationMatch 'Springfield, IL' 'Engineer, Endpoint - Remote').Ok $true
Check 'title Remote, Sr SysAdmin' (Test-LocationMatch 'Chicago, IL' 'Sr Systems Administrator (Remote)').Ok $true
Check 'title WFH'                (Test-LocationMatch 'Dallas, TX' 'Desktop Engineer - Work From Home').Ok $true
# The narrowness of RemoteTitlePatterns is the point -- these must NOT be rescued.
Check 'Distributed NOT remote'   (Test-LocationMatch 'Austin, TX' 'Distributed Systems Engineer').Ok      $false
Check 'Virtual Desktop NOT rem'  (Test-LocationMatch 'Austin, TX' 'Virtual Desktop Infrastructure Engineer').Ok $false
Check 'plain title unaffected'   (Test-LocationMatch 'Palo Alto, CA' 'Systems Administrator').Ok          $false
# LocationExclude still wins over a remote title.
Check 'India beats remote title' (Test-LocationMatch 'Bengaluru, India' 'Endpoint Engineer - Remote').Ok  $false
Check 'UK beats remote title'    (Test-LocationMatch 'London, UK' 'Systems Engineer (Remote)').Ok         $false
# No title supplied -- every existing call path must behave exactly as before.
CheckGeo 'no title, Harborview KEPT'   (Test-LocationMatch 'Harborview, WM').Ok                                    $true
Check 'no title, PaloAlto DROPS' (Test-LocationMatch 'Palo Alto, CA').Ok                                  $false
Check 'blank title safe'         (Test-IsRemoteTitle '')                                                  $false
Check 'null title safe'          (Test-IsRemoteTitle $null)                                               $false

# ---- LEGAL TITLES, added 2026-09-21 --------------------------------------
# The 'infrastructure' keyword's first false positive, on its first live run.
Check 'Infra Counsel DROPS'   (Test-TitleMatch 'Compute & Infrastructure Counsel, Real Estate').Ok $false
Check 'Attorney DROPS'        (Test-TitleMatch 'Attorney, Technology Transactions').Ok             $false
Check 'Paralegal DROPS'       (Test-TitleMatch 'Senior Paralegal, Infrastructure').Ok              $false
# 'counsel' must not eat the counselling exclusions' neighbours or any target title.
Check 'Infra Engineer KEPT'   (Test-TitleMatch 'Infrastructure Engineer').Ok                       $true
Check 'Cloud Engineer KEPT'   (Test-TitleMatch 'Cloud Engineer').Ok                                $true

# ---- WORKSITE CHECK, added 2026-09-22, renamed 2026-10-12 ----
# Brookfield and Millbrook stay IN SCOPE -- the check rides along as a question.
# Asserted on the CHECK: prefix, never the note text: the note comes from the
# profile, so the shipped suite and the private one see different wording.
CheckGeo 'Brookfield still KEPT'    (Test-LocationMatch 'Brookfield, WM').Ok                         $true
CheckGeo 'Millbrook still KEPT'     (Test-LocationMatch 'Millbrook, WM').Ok                          $true
CheckGeo 'Brookfield carries check' ((Test-LocationMatch 'Brookfield, WM').Check -like 'CHECK:*')    $true
CheckGeo 'Millbrook carries check'  ((Test-LocationMatch 'Millbrook, WM').Check -like 'CHECK:*')     $true
# Harborview and plain-state matches must NOT carry it.
Check 'Harborview no check'       ([bool](Test-LocationMatch 'Harborview, WM').Check)               $false
Check 'bare state no check'       ([bool](Test-LocationMatch 'Elmwood Westmark').Check)        $false
# Remote returns before the include loop, so no worksite question applies.
Check 'Remote Brookfield no chk' ([bool](Test-LocationMatch 'Remote - Brookfield, WM').Check)     $false
Check 'Remote Brookfield KEPT'   (Test-LocationMatch 'Remote - Brookfield, WM').Ok                $true
# Multi-city already goes to judgement, so it returns before the check too.
Check 'multi-city no check'    ([bool](Test-LocationMatch 'Harborview, WM | Brookfield, WM').Check) $false
# The nearby cities that were ALREADY out of scope must stay out.
Check 'Northbay still DROPS'   (Test-LocationMatch 'Northbay, WM').Ok                         $false
Check 'Cedarton still DROPS'    (Test-LocationMatch 'Cedarton, WM').Ok                          $false
Check 'Pinecrest still DROPS'   (Test-LocationMatch 'Pinecrest, WM').Ok                         $false
Check 'Southgate still DROPS'     (Test-LocationMatch 'Southgate, WM').Ok                           $false
# Substring safety: no false trigger on an unrelated string.
Check 'no check on Palo Alto'  ([bool](Test-LocationMatch 'Palo Alto, CA').Check)             $false

# ---- REGION CHECK, added 2026-10-12 --------------------------------------
# A string that names a REGION names no city, so no city rule can judge it.
# MEASURED before the fix, against both the example and the real profile:
#   "Greater Harborview Area"  -> in scope, NO FLAG   (matched LocationInclude on
#                              the substring 'harborview', while Maplewood and Port Allen
#                              sit inside that region and are out of scope)
#   "Eastshore, WM"          -> DROPPED outright    (by an earlier check that
#                              matched only city names)
# Two silent failures in opposite directions. Both are now questions.
CheckGeo 'Greater Harborview KEPT'   (Test-LocationMatch 'Greater Harborview Area').Ok                 $true
CheckGeo 'Greater Harborview flags'  ((Test-LocationMatch 'Greater Harborview Area').Check -like 'CHECK:*') $true
CheckGeo 'Harborview Metro flags'    ((Test-LocationMatch 'Harborview Metropolitan Area').Check -like 'CHECK:*') $true
CheckGeo 'Harbor Bay KEPT'       (Test-LocationMatch 'Harbor Bay Region').Ok                   $true
CheckGeo 'Harbor Bay flags'      ((Test-LocationMatch 'Harbor Bay Region').Check -like 'CHECK:*') $true
CheckGeo 'Eastshore KEPT not drop' (Test-LocationMatch 'Eastshore, WM').Ok                         $true
CheckGeo 'Eastshore flags'         ((Test-LocationMatch 'Eastshore, WM').Check -like 'CHECK:*')    $true
CheckGeo 'Harbor County flags'      ((Test-LocationMatch 'Harbor County, WM').Check -like 'CHECK:*') $true
CheckGeo 'North Coast KEPT'        (Test-LocationMatch 'North Coast').Ok                    $true

# ORDERING IS LOAD-BEARING, so assert it rather than trusting the line order.
# Before LocationInclude: 'Greater Harborview Area' contains 'harborview', which is in
# LocationInclude. If the region loop ran second this would read 'location in
# scope' and carry no flag -- exactly the bug being fixed.
CheckGeo 'region beats include'   ((Test-LocationMatch 'Greater Harborview Area').Reason -like 'region named*') $true
# After CommuteExclude: a region phrase that also names an excluded city is still
# dropped. Synthetic string -- 'washington dc' is in CommuteExclude in both the
# example and the real profile, which is what makes this assertion portable.
Check 'commute beats region'   (Test-LocationMatch 'Harbor Bay / Washington DC').Ok          $false
# A plain city must not pick up a region flag.
Check 'Harborview no region flag' ([bool](Test-LocationMatch 'Harborview, WM').Check)               $false
CheckGeo 'Brookfield reason intact' ((Test-LocationMatch 'Brookfield, WM').Reason)        'location in scope'

# ---- AN UNKNOWN PROFILE KEY STOPS THE RUN, added 2026-10-12 --------------
# Merging is replace-by-key, so before this a stale key was carried into $Config
# and never read. Renaming a key (as WorksiteCheck was, on 2026-10-12) without
# updating the profile would have silently switched that filter off. This is the
# guard that makes any future rename fail loudly instead.
$badProfile = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-badkey-{0}.psd1" -f ([guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $badProfile -Value "@{ OldCityCheck = @('brookfield') }" -Encoding utf8
$threw = $false; $msg = ''
try   { Merge-JobSweepProfile -Defaults $Config -ProfilePath @($badProfile) | Out-Null }
catch { $threw = $true; $msg = "$_" }
Remove-Item -LiteralPath $badProfile -Force -ErrorAction SilentlyContinue
Check 'stale key throws'       $threw                                                         $true
Check 'error names the key'    ($msg -like '*OldCityCheck*')                                  $true
Check 'error lists valid keys' ($msg -like '*WorksiteCheck*')                                 $true

Write-Host "`n-- CLEARANCE: required, path, preferred, and the words that only look like it (added 2026-11-03) --"
# Every case passes -Mode, so the result does not depend on the profile under test.
$clr = { param($t, $m) $h = @(Test-ClearanceRequired $t $m); if ($h.Count) { "$($h[0].Level): $($h[0].Why)" } else { 'none' } }
Check 'active Secret drops'       (& $clr 'Candidates must have an active Secret clearance.' 'drop')            'out: requires an active Secret clearance'
Check 'TS/SCI alone drops'        (& $clr 'TS/SCI with polygraph.' 'drop')                                       'out: requires an active TS/SCI clearance'
Check 'TS-SCI spelling drops'     (& $clr 'Requires TS-SCI.' 'drop')                                             'out: requires an active TS/SCI clearance'
Check 'Top Secret named'          (& $clr 'A current Top Secret clearance is required.' 'drop')                  'out: requires an active Top Secret clearance'
Check 'check mode keeps it'       (& $clr 'Candidates must have an active Secret clearance.' 'check')           'check: requires an active Secret clearance'
Check 'off mode ignores it'       (& $clr 'Candidates must have an active Secret clearance.' 'off')             'none'
Check 'ability to obtain is path' (& $clr 'Must be able to obtain a Secret clearance.' 'drop')                   'check: Secret, with a path to obtain it'
Check 'obtain within 90 days'     (& $clr 'You will be required to obtain a Secret clearance within 90 days of hire.' 'drop') 'check: Secret, with a path to obtain it'
Check 'or ability to obtain'      (& $clr 'Active Secret clearance or the ability to obtain one.' 'drop')       'check: Secret, with a path to obtain it'
Check 'active plus path drops'    (& $clr 'Active Secret clearance and the ability to obtain TS/SCI.' 'drop')    'out: requires an active TS/SCI clearance'
Check 'preferred is not required' (& $clr 'An active Secret clearance is preferred.' 'drop')                     'check: Secret preferred, not required'
Check 'must beats preferred'      (& $clr 'Must hold TS/SCI; CISSP preferred.' 'drop')                          'out: requires an active TS/SCI clearance'
Check 'trade secrets not a hit'   (& $clr 'You will protect trade secrets and confidential data.' 'drop')        'none'
Check 'secret sauce not a hit'    (& $clr 'Our secret is great people.' 'drop')                                  'none'
Check 'no clearance needed'       (& $clr 'No security clearance is required for this role.' 'drop')             'none'
Check 'public trust not covered'  (& $clr 'Must be able to pass a Public Trust investigation.' 'drop')            'none'
Check 'blank text'                (& $clr '' 'drop')                                                              'none'
Check 'line break splits'         (& $clr "Requirements`nActive TS/SCI`nBenefits: 401k" 'drop')                  'out: requires an active TS/SCI clearance'
# With no -Mode the profile's ClearanceScreen decides, and with none set the default is check.
# Set-Variable makes a local $Config that the function reads through dynamic scope.
Check 'default mode is check'     (& { Set-Variable -Name Config -Value @{}; @(Test-ClearanceRequired 'Active Secret clearance.')[0].Level }) 'check'
Check 'profile drop is read'      (& { Set-Variable -Name Config -Value @{ ClearanceScreen = 'drop' }; @(Test-ClearanceRequired 'Active Secret clearance.')[0].Level }) 'out'

# A misspelt ClearanceScreen value stops the run rather than falling back quietly.
$badMode = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-badmode-{0}.psd1" -f ([guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $badMode -Value "@{ ClearanceScreen = 'dorp' }" -Encoding utf8
$threw = $false; $msg = ''
try   { Merge-JobSweepProfile -Defaults $Config -ProfilePath @($badMode) | Out-Null }
catch { $threw = $true; $msg = "$_" }
Remove-Item -LiteralPath $badMode -Force -ErrorAction SilentlyContinue
Check 'bad ClearanceScreen throws'  $threw                    $true
Check 'error names the value'       ($msg -like "*'dorp'*")   $true

# ---- MALFORMED LOCATION IS NOT A SCREEN-OUT, added 2026-09-25 ------------
# iCIMS served a remote engineering req with the literal stub "US-". It is
# neither null nor whitespace, so it fell through to the out-of-scope return
# and a strong remote lead was screened out.
Check 'US- stub KEPT'          (Test-LocationMatch 'US-').Ok                              $true
Check 'US- carries check'      ((Test-LocationMatch 'US-').Check -like 'CHECK: the location*') $true
Check 'bare US KEPT'           (Test-LocationMatch 'US').Ok                               $true
Check 'bare USA KEPT'          (Test-LocationMatch 'USA').Ok                              $true
Check 'United States KEPT'     (Test-LocationMatch 'United States').Ok                    $true
Check 'US, punctuated KEPT'    (Test-LocationMatch 'U.S.').Ok                             $true
Check 'TBD KEPT'               (Test-LocationMatch 'TBD').Ok                              $true
Check 'Various KEPT'           (Test-LocationMatch 'Various').Ok                          $true
Check 'Nationwide KEPT'        (Test-LocationMatch 'Nationwide').Ok                       $true
# The blank branch is untouched and must still carry NO check.
Check 'blank still KEPT'       (Test-LocationMatch '').Ok                                 $true
Check 'blank carries no check' ([bool](Test-LocationMatch '').Check)                      $false
# A stub must not swallow a real location that happens to start with a country code.
Check 'US-DC- still DROPS'     (Test-LocationMatch 'US-DC-Washington').Ok                 $false
CheckGeo 'US-WM-Harborview KEPT'     (Test-LocationMatch 'US-WM-Harborview').Ok                    $true
Check 'US-TX-Austin DROPS'     (Test-LocationMatch 'US-TX-Austin').Ok                     $false
Check 'PaloAlto no stub check' ([bool](Test-LocationMatch 'Palo Alto, CA').Check)         $false
Check 'Harborview no stub check'  ([bool](Test-LocationMatch 'Harborview, WM').Check)           $false
# A non-US stub is still a stub, not an exclusion -- the body decides.
Check 'India NOT a stub'       (Test-LocationMatch 'Bengaluru, India').Ok                 $false

# ---- WORKDAY bulletFields MAPPING, added 2026-09-25 ----------------------
# An employer posted to twelve cities including one in scope. The tenant put the
# additional-locations list in bulletFields[0], the sweep wrote it into ReqId,
# and the req was scored on New York alone. Second loss of this employer's
# location list; the first was a WebFetch summary.
Check 'reqid REQ- form'        (Test-IsRequisitionId 'REQ-0000100001')                    $true
Check 'reqid JR form'          (Test-IsRequisitionId 'JR10001')                           $true
Check 'reqid R- form'          (Test-IsRequisitionId 'R-12345')                           $true
Check 'reqid year-seq form'    (Test-IsRequisitionId '2026-4572')                         $true
Check 'city is NOT a reqid'    (Test-IsRequisitionId 'Harborview, WM')                       $false
Check 'city list NOT a reqid'  (Test-IsRequisitionId 'Atlanta, GA | Harborview, WM')         $false
Check 'N Locations NOT a reqid' (Test-IsRequisitionId '12 Locations')                     $false
Check 'posted-ago NOT a reqid' (Test-IsRequisitionId '5 Days Ago')                        $false
Check 'time type NOT a reqid'  (Test-IsRequisitionId 'Full time')                         $false
Check 'bare city NOT a reqid'  (Test-IsRequisitionId 'New York')                          $false
Check 'empty NOT a reqid'      (Test-IsRequisitionId '')                                  $false

Check 'city,ST is a location'  (Test-LooksLikeLocationList 'Harborview, WM')                 $true
Check 'piped list is location' (Test-LooksLikeLocationList 'Atlanta, GA | Harborview, WM')   $true
Check 'N Locations is location' (Test-LooksLikeLocationList '12 Locations')               $true
Check 'Remote is location'     (Test-LooksLikeLocationList 'Remote')                      $true
Check 'reqid NOT a location'   (Test-LooksLikeLocationList 'REQ-0000100001')              $false
Check 'time type NOT location' (Test-LooksLikeLocationList 'Full time')                   $false

# The defect itself: the twelve-city bullet must reach Location, not ReqId.
$multi = Resolve-WorkdayBullets @('New York, NY | Boston, MA | Harborview, WM | Chicago, IL') 'New York, NY'
Check '12-city reqid clean'    ($multi.ReqId -like '*Harborview*')                           $false
Check '12-city city recovered' ($multi.Location -like '*Harborview, WM*')                    $true
Check '12-city to judgement'   (Test-LocationMatch $multi.Location).Ok                       $true
Check '12-city DROPPED before' (Test-LocationMatch 'New York, NY').Ok                        $false

# The ordinary single-location shape must be completely unchanged.
$one = Resolve-WorkdayBullets @('JR10001') 'Harborview, WM'
Check 'single reqid kept'      $one.ReqId                                                 'JR10001'
Check 'single location kept'   $one.Location                                              'Harborview, WM'

# Mixed bullets: take the id, fold the places, drop everything else.
$mix = Resolve-WorkdayBullets @('JR10001','Atlanta, GA | Harborview, WM','Full time','5 Days Ago') 'New York, NY'
Check 'mixed picks the reqid'  $mix.ReqId                                                 'JR10001'
Check 'mixed folds the places' $mix.Location                        'New York, NY | Atlanta, GA | Harborview, WM'
Check 'mixed drops the noise'  ($mix.Location -like '*Full time*')                        $false

# Nothing usable, and no duplication of a location the row already had.
$none = Resolve-WorkdayBullets @() 'Harborview, WM'
Check 'empty bullets no reqid' ([bool]$none.ReqId)                                        $false
Check 'empty bullets keep loc' $none.Location                                             'Harborview, WM'
$dup = Resolve-WorkdayBullets @('Harborview, WM') 'Harborview, WM'
Check 'no duplicated location' $dup.Location                                              'Harborview, WM'
$blank = Resolve-WorkdayBullets @('Fernhill, WM') ''
Check 'blank loc takes bullet' $blank.Location                                            'Fernhill, WM'
Check 'recovered loc screens'  (Test-LocationMatch $blank.Location).Ok                    $false

# ---- COMPLIANCE TITLE NEEDS IT CONTEXT, added 2026-09-30 -----------------
# 'compliance analyst', 'controls analyst' and '\bgrc\b' sit in TitleInclude
# because the family is sometimes in scope. They measured 2-for-2 noise, so the
# title now only keeps a posting ALIVE -- the description has to earn it. The
# gate runs in the post-detail re-screen loop, beside Test-PhysicalDemand.
Write-Host "`n-- COMPLIANCE TITLE: only the compliance keyword matched --"
Check 'plain Compliance Analyst'    (Test-ComplianceTitleOnly 'Compliance Analyst')              $true
Check 'Controls Analyst'            (Test-ComplianceTitleOnly 'Controls Analyst')                $true
Check 'GRC Analyst'                 (Test-ComplianceTitleOnly 'GRC Analyst')                     $true
Check 'Regulatory Compliance Anlyst'(Test-ComplianceTitleOnly 'Regulatory Compliance Analyst')   $true
Check 'blank title safe'            (Test-ComplianceTitleOnly '')                                $false
Check 'Systems Administrator'       (Test-ComplianceTitleOnly 'Systems Administrator')           $false

Write-Host "`n-- COMPLIANCE TITLE: the title itself can carry the context --"
# TitleInclude has no bare 'IT' pattern, only 'it audit', 'it analyst' and
# siblings, so without reading the title for IT context these were dropped.
# This is the defect the fixtures caught on 2026-09-30 before it shipped.
Check 'IT Compliance Analyst'       (Test-ComplianceTitleOnly 'IT Compliance Analyst')           $false
Check 'InfoSec Compliance Analyst'  (Test-ComplianceTitleOnly 'Information Security Compliance Analyst') $false
Check 'Identity and Compliance'     (Test-ComplianceTitleOnly 'Identity and Compliance Analyst') $false
Check 'Cyber GRC Analyst'           (Test-ComplianceTitleOnly 'Cyber GRC Analyst')               $false

Write-Host "`n-- IT CONTEXT: one signal is enough, unlike the developer test --"
$finreg = 'Monitor adherence to lending regulations, prepare filings for the Consumer Financial Protection Bureau, and maintain the policy library.'
$itreq  = 'Perform quarterly access reviews across Active Directory and Azure, and track NIST 800-171 control evidence for the annual assessment.'
$pharma = 'Pharmacovigilance submissions, labelling review and adverse event reporting.'
Check 'financial body has none'     (@(Test-ItContext $finreg).Count)                            0
Check 'pharma body has none'        (@(Test-ItContext $pharma).Count)                            0
Check 'IT body has signals'         ([bool](@(Test-ItContext $itreq).Count -gt 0))               $true
Check 'blank body safe'             (@(Test-ItContext '').Count)                                 0
Check 'NIST detected'               ([bool](@(Test-ItContext $itreq) -contains 'NIST'))          $true

Write-Host "`n-- THE GATE AS THE RE-SCREEN LOOP APPLIES IT --"
# out = compliance-only title AND a body with no IT context.
Check 'finreg compliance DROPS'  ([bool]((Test-ComplianceTitleOnly 'Compliance Analyst') -and @(Test-ItContext $finreg).Count -eq 0))  $true
Check 'IT-bodied compliance KEPT'([bool]((Test-ComplianceTitleOnly 'Compliance Analyst') -and @(Test-ItContext $itreq).Count -eq 0))   $false
Check 'IT-titled never gated'    (Test-ComplianceTitleOnly 'IT Compliance Analyst')                                                    $false


# ---- LEVEL AND HARDWARE EXCLUSIONS, added 2026-10-01 ---------------------
# Microsoft's "Principal Hardware Systems Engineer" reached the candidate list
# on 'systems engineer' and had to be declined by hand on three gates at once.
Write-Host "`n-- LEVEL: Principal and above are excluded by the profile --"
Check 'Principal HW Sys Eng DROPS' (Test-TitleMatch 'Principal Hardware Systems Engineer').Ok   $false
Check 'Principal SW Eng DROPS'     (Test-TitleMatch 'Principal Software Engineer').Ok           $false
Check 'Principal SysAdmin DROPS'   (Test-TitleMatch 'Principal Systems Administrator').Ok       $false
Check 'Distinguished Eng DROPS'    (Test-TitleMatch 'Distinguished Engineer').Ok                $false
Check 'Technical Fellow DROPS'     (Test-TitleMatch 'Technical Fellow').Ok                      $false
# The level words must not catch the tiers the profile DOES want.
Check 'Senior Sys Eng still KEPT'  (Test-TitleMatch 'Senior Systems Engineer').Ok               $true
Check 'Staff Sys Admin still KEPT' (Test-TitleMatch 'Staff Systems Administrator').Ok           $true
Check 'Lead Endpoint Eng KEPT'     (Test-TitleMatch 'Lead Endpoint Engineer').Ok                $true

Write-Host "`n-- HARDWARE: engineering senses only, asset management untouched --"
Check 'Hardware Engineer DROPS'    (Test-TitleMatch 'Hardware Engineer').Ok                      $false
Check 'Firmware Engineer DROPS'    (Test-TitleMatch 'Firmware Engineer II').Ok                   $false
Check 'Hardware Design Eng DROPS'  (Test-TitleMatch 'Hardware Design Engineer').Ok               $false
# TitleProtect runs first, so the asset-management senses survive. These are real
# real titles in the target family and must never die on 'hardware'.
Check 'HW Asset Mgmt KEPT'         (Test-TitleMatch 'Hardware Asset Management Technical Developer').Ok $true
Check 'IT Asset Manager KEPT'      (Test-TitleMatch 'IT Hardware Asset Manager').Ok              $true
# "Hardware Deployment Engineer" drops, but on 'title did not match any target
# keyword' rather than on the hardware rule -- there is no 'deployment' pattern in
# TitleInclude. The drop is right either way: field hardware deployment is the
# family the physical-demand screen excludes, so dropping it at the title stage is
# cheaper than a detail fetch that reaches the same answer.
Check 'HW Deployment Eng DROPS'    (Test-TitleMatch 'Hardware Deployment Engineer').Ok           $false
Check 'and not via the HW rule'    (Test-TitleMatch 'Hardware Deployment Engineer').Reason       'title did not match any target keyword'

Write-Host "`n-- STARTUP: a profile error reports itself, not 'Write-Log is not recognized' (added 2026-10-20) --"
# Script functions exist only once execution reaches them, and the trap in MAIN
# covers the whole script. If the merge throws before Write-Log is defined, the
# trap's own Write-Log call fails and the real error is lost. Checked from the AST
# so the suite stays free of network, state and output files.
$writeLogDef = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-Log' }, $true))
$mergeCall = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and
    $n.GetCommandName() -eq 'Merge-JobSweepProfile' }, $true))
Check 'Write-Log defined once'           $writeLogDef.Count 1
Check 'collector calls the merge once'   $mergeCall.Count   1
if ($writeLogDef.Count -eq 1 -and $mergeCall.Count -eq 1) {
    Check 'Write-Log defined before merge' ($writeLogDef[0].Extent.StartOffset -lt $mergeCall[0].Extent.StartOffset) $true
    $p = $mergeCall[0].Parent; $inTry = $false
    while ($p) { if ($p -is [System.Management.Automation.Language.TryStatementAst]) { $inTry = $true; break }; $p = $p.Parent }
    Check 'merge runs inside a try'        $inTry $true
}

# ---- APPLICATION ANALYST, added 2026-11-09 ------------------------------
Write-Host "`n-- TITLE: application analyst is a target title --"
Check 'Application Analyst III KEPT'  (Test-TitleMatch 'Application Analyst III').Ok             $true
Check 'Applications Analyst 2 KEPT'   (Test-TitleMatch 'Applications Analyst 2').Ok              $true
Check 'Enterprise App Analyst KEPT'   (Test-TitleMatch 'Enterprise Application Analyst III').Ok  $true

# ---- ONE BAD ROW MUST NOT LOSE A SOURCE, added 2026-11-09 ----------------
# A Workday tenant served a first-page row with no title. The bare $j.title threw
# under StrictMode and the whole tenant (~155 postings) was lost for the run. The
# provider functions run here against a fake Invoke-Json, so the real loop is tested.
Write-Host "`n-- ROW GUARDS: a row missing a field is skipped and counted, the rest kept --"
$script:testLog = @()
function Write-Log {
    # The analyzer lists a Write-Log cmdlet for PowerShell 6.1 on Windows; the
    # collector carries the same suppression on its own Write-Log.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Test stand-in for the collector''s own Write-Log; records lines instead of printing them.')]
    param([string]$Message, [string]$Level = 'INFO')
    $script:testLog += "[$Level] $Message"
}
$script:Throttle = 0
Set-Variable -Name WorkdayMaxPostings -Value 2000   # read by Get-WorkdayJobs through dynamic scope
$script:wdRows = @(
    [pscustomobject]@{ title = 'Systems Administrator'; externalPath = '/job/Harborview/Systems-Administrator_R1'; locationsText = 'Harborview, WM'; postedOn = 'Posted Today'; bulletFields = @('R1') }
    [pscustomobject]@{ externalPath = '/job/Harborview/Untitled_R2'; locationsText = 'Harborview, WM' }
    [pscustomobject]@{ title = 'Endpoint Engineer'; externalPath = '/job/Brookfield/Endpoint-Engineer_R3'; bulletFields = @('R3') }
)
# Only -Uri is declared; the other named arguments the providers pass land in $args.
function Invoke-Json { param([string]$Uri)
    if ($Uri -like '*/wday/cxs/*') { return [pscustomobject]@{ total = 3; jobPostings = $script:wdRows } }
    if ($Uri -like '*greenhouse*') { return [pscustomobject]@{ jobs = @([pscustomobject]@{ title = 'IT Analyst'; id = 1; absolute_url = 'https://example.test/1'; updated_at = '2026-11-09' }; [pscustomobject]@{ id = 2 }) } }
    if ($Uri -like '*lever*')      { return @([pscustomobject]@{ text = 'Help Desk Lead'; id = 'a'; hostedUrl = 'https://example.test/a'; createdAt = 1 }; [pscustomobject]@{ id = 'b' }) }
    throw "unexpected URI $Uri"
}
$wd = @(Get-WorkdayJobs @{ Company = 'Example Health'; WdHost = 'https://examplehealth.wd1.myworkdayjobs.com'; Tenant = 'examplehealth'; Site = 'External' })
Check 'Workday keeps rows around a titleless one' (($wd | ForEach-Object Title) -join ', ') 'Systems Administrator, Endpoint Engineer'
Check 'Workday counts the skipped row'       (@($script:testLog | Where-Object { $_ -like '*skipped 1 with no title*' }).Count) 1
Check 'Workday: skipped row is not a shortfall' (@($script:testLog | Where-Object { $_ -like '*UNDER-COLLECTED*' }).Count) 0
$gh = @(Get-GreenhouseJobs @{ Company = 'Example Biotech'; Token = 'example-biotech' })
Check 'Greenhouse skips a titleless row'      (($gh | ForEach-Object Title) -join ', ') 'IT Analyst'
$lv = @(Get-LeverJobs @{ Company = 'Example Fintech'; Token = 'example-fintech' })
Check 'Lever skips a titleless row'           (($lv | ForEach-Object Title) -join ', ') 'Help Desk Lead'
Remove-Item Function:\Invoke-Json

# ---- RIPPLING, added 2026-11-10 (1.7.0) ------------------------------------
# Fictional board shapes. v2 is paged and grouped by posting; v1 repeats a
# posting once per location under the same uuid. The fake API serves both.
Write-Host "`n-- RIPPLING: v2 paging, v1 failover, one posting per id, detail and pay --"
$script:ripCalls = @()
$script:ripV2Fails = $false
$script:ripV2 = @(
    [pscustomobject]@{ totalPages = 2; items = @(
        [pscustomobject]@{ id = 'r-1'; name = 'Systems Administrator'; url = 'https://ats.rippling.com/example-robotics/jobs/r-1'
            locations = @([pscustomobject]@{ name = 'Harborview, Westmark'; city = 'Harborview'; stateCode = 'WM'; workplaceType = 'HYBRID' },
                          [pscustomobject]@{ name = 'Brookfield, Westmark'; city = 'Brookfield'; stateCode = 'WM'; workplaceType = 'ON_SITE' }) }
        [pscustomobject]@{ id = 'r-2'; name = ''; locations = @() }) }
    [pscustomobject]@{ totalPages = 2; items = @(
        [pscustomobject]@{ id = 'r-3'; name = 'IT Support Specialist'
            locations = @([pscustomobject]@{ name = 'United States'; workplaceType = 'REMOTE' }) }) }
)
$script:ripV1 = @(
    [pscustomobject]@{ uuid = 'r-1'; name = 'Systems Administrator'; url = 'https://ats.rippling.com/example-robotics/jobs/r-1'; workLocation = [pscustomobject]@{ label = 'Harborview, WM' } }
    [pscustomobject]@{ uuid = 'r-1'; name = 'Systems Administrator'; url = 'https://ats.rippling.com/example-robotics/jobs/r-1'; workLocation = [pscustomobject]@{ label = 'Brookfield, WM' } }
    [pscustomobject]@{ uuid = 'r-3'; name = 'IT Support Specialist'; workLocation = [pscustomobject]@{ label = 'Remote (Westmark)' } }
)
function Invoke-Json { param([string]$Uri)
    $script:ripCalls += $Uri
    if ($Uri -like '*/v2/board/*') {
        if ($script:ripV2Fails) { throw 'HTTP 500 from the fake v2 list' }
        $pg = [int]([regex]::Match($Uri, 'page=(\d+)').Groups[1].Value)
        return $script:ripV2[$pg]
    }
    if ($Uri -like '*/v1/board/*/jobs/r-1') {
        return [pscustomobject]@{ createdOn = '2026-11-02T09:15:00.123456-08:00'
            description = [pscustomobject]@{ role = '<p>Run <b>Intune</b> and Entra ID.</p>'; company = '<p>Example Robotics builds things.</p>' }
            payRangeDetails = @([pscustomobject]@{ location = 'Harborview'; currency = 'USD'; frequency = 'YEAR'; rangeStart = 80000.0; rangeEnd = 95000.0; isRemote = $false },
                                [pscustomobject]@{ location = 'Brookfield'; currency = 'USD'; frequency = 'YEAR'; rangeStart = 76000.0; rangeEnd = 90000.0; isRemote = $false }) }
    }
    if ($Uri -like '*/v1/board/*/jobs/r-3') { throw 'HTTP 404 from the fake detail' }
    if ($Uri -like '*/v1/board/*/jobs')     { return $script:ripV1 }
    throw "unexpected URI $Uri"
}
$ripSrc = @{ Company = 'Example Robotics'; Board = 'example-robotics' }
$rp = @(Get-RipplingJobs $ripSrc)
Check 'Rippling v2: both pages read'          (@($script:ripCalls | Where-Object { $_ -like '*/v2/*' }).Count) 2
Check 'Rippling v2: titleless row skipped'    (($rp | ForEach-Object Title) -join ', ') 'Systems Administrator, IT Support Specialist'
Check 'Rippling v2: skipped row counted'      (@($script:testLog | Where-Object { $_ -like '*Rippling Example Robotics: skipped 1 row*' }).Count) 1
Check 'Rippling v2: locations joined'         $rp[0].Location 'Harborview, WM | Brookfield, WM'
Check 'Rippling v2: remote location'          $rp[1].Location 'Remote | United States'
Check 'Rippling v2: remote passes screen'     (Test-LocationMatch $rp[1].Location).Ok $true
Check 'Rippling: url built when missing'      $rp[1].Url 'https://ats.rippling.com/example-robotics/jobs/r-3'
Check 'Rippling: key by id'                   $rp[0].Key 'Rippling|r-1'
Check 'Rippling: detail path'                 $rp[0].DetailPath 'https://api.rippling.com/platform/api/ats/v1/board/example-robotics/jobs/r-1'
Check 'Rippling: no text before detail'       $rp[0].Content ''

Add-RipplingDetail $rp[0]
Check 'Rippling detail: role text first'      ($rp[0].Content -like 'Run Intune and Entra ID.*Example Robotics builds things.') $true
Check 'Rippling detail: pay across tiers'     $rp[0].Pay '$76,000 - $95,000'
Check 'Rippling detail: posted date'          ($rp[0].Posted -like '2026-11-0*') $true
Add-RipplingDetail $rp[1]
Check 'Rippling detail: failure is a warning' (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*detail fetch failed for Example Robotics / IT Support Specialist*' }).Count) 1
Check 'Rippling detail: failure keeps row'    $rp[1].Title 'IT Support Specialist'

$script:ripV2Fails = $true; $script:ripCalls = @()
$rv1 = @(Get-RipplingJobs $ripSrc)
Check 'Rippling failover: v1 list used'       (@($script:ripCalls | Where-Object { $_ -like '*/v1/board/example-robotics/jobs' }).Count) 1
Check 'Rippling failover: logged as WARN'     (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*v2 list failed*trying the v1 list' }).Count) 1
Check 'Rippling v1: one posting per uuid'     $rv1.Count 2
Check 'Rippling v1: locations joined'         $rv1[0].Location 'Harborview, WM | Brookfield, WM'
Remove-Item Function:\Invoke-Json, Function:\Write-Log

Check 'Rippling: no second Remote'      (@(Merge-RipplingRow @(@{ Id = 'x'; Title = 'A'; Url = ''; Locations = @('Remote (United States)'); Remote = $true }))[0].Location) 'Remote (United States)'
Check 'Rippling item: v1 uuid read'      (ConvertFrom-RipplingListItem ([pscustomobject]@{ uuid = 'u'; name = 'Analyst' })).Id 'u'
Check 'Rippling item: no id is null'     ($null -eq (ConvertFrom-RipplingListItem ([pscustomobject]@{ name = 'Analyst' }))) $true
Check 'Rippling item: city without state' (ConvertFrom-RipplingListItem ([pscustomobject]@{ id = 'x'; name = 'A'; locations = @([pscustomobject]@{ name = 'Westmark'; city = 'Harborview' }) })).Locations[0] 'Westmark'
$rr = { param($a, $b, $f, $c) [pscustomobject]@{ rangeStart = $a; rangeEnd = $b; frequency = $f; currency = $c } }
Check 'Rippling pay: one range'          (Get-RipplingPay @(& $rr 70000.0 90000.0 'YEAR' 'USD')) '$70,000 - $90,000'
Check 'Rippling pay: hourly'             (Get-RipplingPay @(& $rr 24.5 31.0 'HOUR' 'USD')) '$24.50 - $31.00 per hour'
Check 'Rippling pay: other currency'     (Get-RipplingPay @(& $rr 60000.0 70000.0 'YEAR' 'CAD')) 'CAD 60,000 - CAD 70,000'
Check 'Rippling pay: mixed units, first kind' (Get-RipplingPay @((& $rr 80000.0 90000.0 'YEAR' 'USD'), (& $rr 30.0 40.0 'HOUR' 'USD'))) '$80,000 - $90,000'
Check 'Rippling pay: end below start'    (Get-RipplingPay @(& $rr 90000.0 80000.0 'YEAR' 'USD')) ''
Check 'Rippling pay: zero'               (Get-RipplingPay @(& $rr 0.0 0.0 'YEAR' 'USD')) ''
Check 'Rippling pay: missing end'        (Get-RipplingPay @([pscustomobject]@{ rangeStart = 50000.0; currency = 'USD'; frequency = 'YEAR' })) ''
Check 'Rippling pay: empty list'         (Get-RipplingPay @()) ''
Check 'Rippling pay: null'               (Get-RipplingPay $null) ''
Check 'ISO text from a DateTime'         (ConvertTo-IsoText ([datetime]::new(2026, 11, 2, 17, 15, 0, [DateTimeKind]::Utc))) '2026-11-02T17:15:00Z'
Check 'ISO text from a string'           (ConvertTo-IsoText '2026-11-02T09:15:00-08:00') '2026-11-02T09:15:00-08:00'

# ---- PAYLOCITY, added 2026-11-13 (1.8.0) ----------------------------------
# Fictional board and posting pages in the shape recruiting.paylocity.com serves:
# the list as JSON in window.pageData (its descriptions carry semicolons, so the
# match must end at ";" plus a line break), the full text and the employer's
# Salary Description only on each posting's own page.
Write-Host "`n-- PAYLOCITY: board pageData, detail sections, pay from Salary Description --"
$plcBoard = @'
<html><head><script>var other = { a: 1 };
</script></head><body><div id="app"></div>
<script>
    window.pageData = {"ModuleTitle":"Example Clinic","Jobs":[
      {"JobId":9000101,"JobTitle":"Endpoint Systems Administrator","LocationName":"REMOTE WORKER","PublishedDate":"2026-10-20T09:34:26-07:00","Description":"We support clinics; you support us","IsInternal":false,"IsRemote":true,"JobLocation":{"City":null,"State":null,"Country":"USA"}},
      {"JobId":9000102,"JobTitle":"IT Support Specialist","LocationName":"Harborview Office","PublishedDate":"2026-11-01T08:00:00-07:00","IsInternal":false,"IsRemote":false,"JobLocation":{"City":"Harborview","State":"WM","Country":"USA"}},
      {"JobId":9000103,"JobTitle":"Network Analyst","LocationName":"Brookfield Campus","IsInternal":false,"IsRemote":true,"JobLocation":{"City":"Brookfield","State":"WM"}},
      {"JobId":9000104,"JobTitle":"Help Desk Lead","LocationName":"Main Office","IsInternal":true,"IsRemote":false,"JobLocation":{"City":"Harborview","State":"WM"}},
      {"JobId":9000105,"JobTitle":"","LocationName":"Main Office","IsInternal":false},
      {"JobId":9000106,"JobTitle":"Systems Engineer","LocationName":"Millbrook Site","IsInternal":false,"IsRemote":false,"JobLocation":null}
    ]};
    window.other = 2;
</script></body></html>
'@
$plcDetail = @'
<div class="job-preview-details">
  <div class="vertical-padding">
    <div class="job-listing-header">Job Type</div>
    <div>Full-time</div>
  </div>
  <div class="job-listing-header">Description</div>
  <div><p>Run <strong>Intune</strong> and Autopilot; keep endpoints healthy.</p><ul><li>Entra ID</li></ul></div>
  <div class="job-listing-header">Requirements</div>
  <div data-bind="html: Job.Requirements"><p>2+ years of endpoint support.</p></div>
  <div class="job-listing-header">Salary Description</div>
  <div>$80,000 - $92,000</div>
  <div style="padding-top: 10px;"><p>Notice: a $5,000 sign-on bonus is not base pay.</p></div>
</div>
<div class="preview-bottom-apply-btn"><a href="/Recruiting/Jobs/Apply/9000101">Apply</a></div>
'@
$pd = Get-PaylocityPageData $plcBoard
Check 'Paylocity pageData read'             (@($pd.Jobs).Count) 6
Check 'Paylocity pageData ends at ;newline' $pd.ModuleTitle 'Example Clinic'
Check 'Paylocity no pageData is null'       ($null -eq (Get-PaylocityPageData '<html>no data</html>')) $true
$pj = @(@($pd.Jobs) | ForEach-Object { ConvertFrom-PaylocityJob $_ })
Check 'Paylocity remote label only'         $pj[0].Location 'Remote'
Check 'Paylocity city and state'            $pj[1].Location 'Harborview, WM'
Check 'Paylocity remote plus city'          $pj[2].Location 'Remote | Brookfield, WM'
Check 'Paylocity internal flagged'          $pj[3].Internal $true
Check 'Paylocity no title is null'          ($null -eq $pj[4]) $true
Check 'Paylocity site label fallback'       $pj[5].Location 'Millbrook Site'
Check 'Paylocity posted kept as ISO'        ($pj[0].Posted -like '2026-10-20T*') $true
Check 'Paylocity id is text'                $pj[0].Id '9000101'

$pdt = ConvertFrom-PaylocityDetail $plcDetail
Check 'Paylocity detail: description first' ($pdt.Content -like 'Run Intune and Autopilot; keep endpoints healthy.*2+ years of endpoint support.') $true
Check 'Paylocity detail: salary block only' $pdt.Salary '$80,000 - $92,000'
Check 'Paylocity detail: job type'          $pdt.JobType 'Full-time'
Check 'Paylocity detail: notice left out'   ($pdt.Content -like '*sign-on*') $false
$pdn = ConvertFrom-PaylocityDetail '<div class="job-listing-header">Description</div><div>Hourly role.</div>'
Check 'Paylocity detail: no salary section' $pdn.Salary ''
Check 'Paylocity detail: empty page'        (ConvertFrom-PaylocityDetail '').Content ''

$script:testLog = @()
function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Test stand-in for the collector''s own Write-Log; records lines instead of printing them.')]
    param([string]$Message, [string]$Level = 'INFO')
    $script:testLog += "[$Level] $Message"
}
$script:plcNoData = $false
function Invoke-Html { param([string]$Uri)
    if ($Uri -like '*/recruiting/jobs/All/*') { if ($script:plcNoData) { return '<html>maintenance</html>' } else { return $plcBoard } }
    if ($Uri -like '*/Recruiting/Jobs/Details/9000101') { return $plcDetail }
    if ($Uri -like '*/Recruiting/Jobs/Details/9000102') { return '<div class="job-listing-header">Description</div><div>Desk support. Pay is $24.00 - $28.00 per hour.</div>' }
    throw "HTTP 404 from the fake detail $Uri"
}
$plcSrc = @{ Company = 'Example Clinic'; BoardId = '00000000-0000-0000-0000-0000000000aa' }
$pl = @(Get-PaylocityJobs $plcSrc)
Check 'Paylocity: internal and titleless left out' (($pl | ForEach-Object Title) -join ', ') 'Endpoint Systems Administrator, IT Support Specialist, Network Analyst, Systems Engineer'
Check 'Paylocity: titleless row counted'     (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*Paylocity Example Clinic: skipped 1 row*' }).Count) 1
Check 'Paylocity: internal noted in log'     (@($script:testLog | Where-Object { $_ -like '*1 internal-only posting(s) left out*' }).Count) 1
Check 'Paylocity: key by job id'             $pl[0].Key 'Paylocity|9000101'
Check 'Paylocity: url is the posting page'   $pl[0].Url 'https://recruiting.paylocity.com/Recruiting/Jobs/Details/9000101'
Check 'Paylocity: no text before detail'     $pl[0].Content ''
$plH = @(Get-PaylocityJobs @{ Company = 'Example Clinic'; BoardId = '00000000-0000-0000-0000-0000000000aa'; PlcHost = 'https://2000recruiting.paylocity.com/' })
Check 'Paylocity: PlcHost used'              $plH[0].DetailPath 'https://2000recruiting.paylocity.com/Recruiting/Jobs/Details/9000101'
Add-PaylocityDetail $pl[0]
Check 'Paylocity detail: pay from Salary Description' $pl[0].Pay '$80,000 - $92,000'
Check 'Paylocity detail: content filled'     ($pl[0].Content -like 'Run Intune*') $true
Add-PaylocityDetail $pl[1]
Check 'Paylocity detail: pay from text'      ($pl[1].Pay -like '*24*28*') $true
Add-PaylocityDetail $pl[2]
Check 'Paylocity detail: failure is a warning' (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*detail fetch failed for Example Clinic / Network Analyst*' }).Count) 1
Check 'Paylocity detail: failure keeps row'  $pl[2].Title 'Network Analyst'
$script:plcNoData = $true
$plcErr = ''
try { $null = Get-PaylocityJobs $plcSrc } catch { $plcErr = $_.Exception.Message }
Check 'Paylocity: missing pageData is an error, not a quiet week' ($plcErr -like '*no window.pageData*') $true
Remove-Item Function:\Invoke-Html, Function:\Write-Log

# ---- MICROSOFT RETRY PASS, added 2026-11-16 (1.8.1) ----------------------
# On 16 Nov 2026 two Microsoft queries ran out of 429 retries part-way and their
# tail was lost. The fake API here fails a page on demand; the retry pass must
# pick the query up from the row where it stopped, without repeating rows.
Write-Host "`n-- MICROSOFT: a query that runs out of retries is queued and resumed --"
$script:testLog = @()
function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Test stand-in for the collector''s own Write-Log; records lines instead of printing them.')]
    param([string]$Message, [string]$Level = 'INFO')
    $script:testLog += "[$Level] $Message"
}
$script:Throttle = 0
Set-Variable -Name PolitenessMs -Value 0   # read by Invoke-MicrosoftRetryPass through dynamic scope
Set-Variable -Name MaxPerQuery -Value 60   # read by Get-MicrosoftQuery through dynamic scope
$script:msFailAt = @{}    # "query|start" -> remaining failures
$script:msCalls  = @()
function Invoke-Json { param([string]$Uri)
    $script:msCalls += $Uri
    $q  = [uri]::UnescapeDataString([regex]::Match($Uri, 'query=([^&]+)').Groups[1].Value)
    $st = [int]([regex]::Match($Uri, 'start=(\d+)').Groups[1].Value)
    $k  = "$q|$st"
    if ($script:msFailAt.ContainsKey($k) -and $script:msFailAt[$k] -gt 0) {
        $script:msFailAt[$k]--
        throw 'Response status code does not indicate success: 429 (Too Many Requests).'
    }
    if ($st -ge 30) { return [pscustomobject]@{ data = [pscustomobject]@{ positions = @() } } }
    $rows = @(0..9 | ForEach-Object {
        $n = $st + $_
        [pscustomobject]@{ id = "$q-p$n"; atsJobId = "$q-$n"; name = "Systems Engineer $n"; positionUrl = "/careers/job/$n"; locations = @('Harborview, Westmark') } })
    return [pscustomobject]@{ data = [pscustomobject]@{ positions = $rows } }
}
$msSrc = @{ Company = 'Example Corp'; Queries = @('systems', 'endpoint'); Locations = @('Westmark'); ThrottleMs = 0; RetryCoolOffSec = 1 }

$script:MicrosoftRetry = @()
$script:msFailAt = @{ 'systems|10' = 5 }
$ms = @(Get-MicrosoftJobs $msSrc)
Check 'Microsoft: rows before the failure kept'   (@($ms | Where-Object { $_.ReqId -like 'systems-*' }).Count) 10
Check 'Microsoft: other query unaffected'         (@($ms | Where-Object { $_.ReqId -like 'endpoint-*' }).Count) 30
Check 'Microsoft: failed query queued'            @($script:MicrosoftRetry).Count 1
Check 'Microsoft: queued at the row it stopped'   $script:MicrosoftRetry[0].StartAt 10
Check 'Microsoft: queue noted in the log'         (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like "*'systems' (Westmark) stopped at 10 rows*queued for a retry*" }).Count) 1

$script:msFailAt = @{}
$script:msCalls  = @()
$msR = @(Invoke-MicrosoftRetryPass $script:MicrosoftRetry)
Check 'Retry pass: resumes at start=10'           ($script:msCalls[0] -like '*query=systems*start=10') $true
Check 'Retry pass: recovers the missing rows'     (($msR | ForEach-Object ReqId | Sort-Object { [int]($_ -split '-')[1] }) -join ',') ((10..29 | ForEach-Object { "systems-$_" }) -join ',')
Check 'Retry pass: no row repeated'               (@($ms + $msR | ForEach-Object ReqId | Sort-Object -Unique).Count) 60
Check 'Retry pass: recovery logged as OK'         (@($script:testLog | Where-Object { $_.StartsWith('[OK]') -and $_ -like "*'systems' (Westmark) recovered on retry: 30 rows*" }).Count) 1
Check 'Retry pass: all recovered ends complete'   (@($script:testLog | Where-Object { $_.StartsWith('[OK]') -and $_ -like '*Microsoft complete: all 1 queued query recovered on retry*' }).Count) 1
Check 'Retry pass: cool-off from the profile'    (@($script:testLog | Where-Object { $_ -match "retrying 1 query that did not finish \(waiting [01] s first\)" }).Count) 1

# Still failing on the retry: named the way a lost query always was.
$script:testLog = @(); $script:MicrosoftRetry = @()
$script:msFailAt = @{ 'endpoint|0' = 10 }
$null = @(Get-MicrosoftJobs $msSrc)
$msR2 = @(Invoke-MicrosoftRetryPass $script:MicrosoftRetry)
Check 'Retry pass: nothing gained is no rows'     $msR2.Count 0
Check 'Retry pass: still lost is NOT COLLECTED'   (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like "*'endpoint' (Westmark) NOT COLLECTED this run after the retry*" }).Count) 1
Check 'Retry pass: empty queue does nothing'      @(Invoke-MicrosoftRetryPass @()).Count 0
# 1.8.3: one closing line says whether Microsoft ended complete.
Check 'Retry pass: lost query ends INCOMPLETE'    (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*Microsoft INCOMPLETE: 1 of 1 queued query still missing*' }).Count) 1
Check 'Get-MicrosoftJobs: RetryLater reset after' $script:RetryLater $false

# 1.8.3: a give-up that will be retried is a WARN; an ERROR only when nothing will.
Check 'give-up queued for retry is WARN'          (Get-GiveUpLevel -RetryLater $true) 'WARN'
Check 'give-up with no retry is ERROR'            (Get-GiveUpLevel -RetryLater $false) 'ERROR'
Check 'gap text: none read'                       (Get-MicrosoftGapText 0) 'NOT COLLECTED this run'
Check 'gap text: some read'                       (Get-MicrosoftGapText 40) 'only partly collected (40 rows)'
$t0 = [datetime]::new(2026, 11, 16, 13, 20, 43)
Check 'cool-off: full wait right after a failure' (Get-RetryCoolOffWait -CoolOffSec 120 -LastFailure $t0 -Now $t0) 120
Check 'cool-off: time already passed counts'      (Get-RetryCoolOffWait -CoolOffSec 120 -LastFailure $t0 -Now $t0.AddSeconds(100)) 20
Check 'cool-off: long past is no wait'            (Get-RetryCoolOffWait -CoolOffSec 120 -LastFailure $t0 -Now $t0.AddMinutes(10)) 0
Remove-Item Function:\Invoke-Json, Function:\Write-Log

Write-Host "`n-- WEB TIMEOUT: a stalled response body is bounded on PowerShell 7.4+ --"
$wt7 = Get-WebTimeoutParameter -HasOperationTimeout $true
$wt5 = Get-WebTimeoutParameter -HasOperationTimeout $false
Check 'timeout: 7.4+ bounds the body read'        $wt7['OperationTimeoutSeconds'] 45
Check 'timeout: 7.4+ keeps the connect limit'     $wt7['TimeoutSec'] 45
Check 'timeout: 5.1 has no operation timeout'     $wt5.ContainsKey('OperationTimeoutSeconds') $false
Check 'timeout: this host matches its cmdlet'     ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) ($PSVersionTable.PSVersion -ge [version]'7.4')

# ---- SUMMARY BANNER (JobSweep.Summary.ps1), added 2026-11-13 ------------
Write-Host "`n-- SUMMARY BANNER: status from the counts --"
$sumPath = Join-Path (Split-Path -Parent $SweepScript) 'JobSweep.Summary.ps1'
Check 'summary helper ships beside the sweep' (Test-Path -LiteralPath $sumPath) $true
if (Test-Path -LiteralPath $sumPath) {
    . $sumPath
    Check 'status: all pass'        (Get-JobSweepStatus -Fail 0 -Skip 0) 'PASS'
    Check 'status: skips'           (Get-JobSweepStatus -Fail 0 -Skip 21) 'PASS WITH SKIPS'
    Check 'status: a fail wins'     (Get-JobSweepStatus -Fail 1 -Skip 21) 'FAIL'
}

Check 'Get-JsonValue: missing is null'   ($null -eq (Get-JsonValue ([pscustomobject]@{ a = 1 }) 'title')) $true
Check 'Get-JsonValue: null object'       ($null -eq (Get-JsonValue $null 'title')) $true
Check 'Get-JsonValue: present'           (Get-JsonValue ([pscustomobject]@{ title = 'x' }) 'title') 'x'

Write-Host "`n-- UNDER-COLLECTED: warn only when rows are really missing --"
Check 'gap equal to skipped is not missing' (Get-WorkdayShortfall -Claimed 1878 -Collected 1876 -Skipped 2) 0
Check 'gap beyond skipped is missing'       (Get-WorkdayShortfall -Claimed 601 -Collected 599 -Skipped 0) 2
Check 'no claimed total, no shortfall'      (Get-WorkdayShortfall -Claimed 0 -Collected 40 -Skipped 0) 0
Check 'over-collected is not negative'      (Get-WorkdayShortfall -Claimed 40 -Collected 45 -Skipped 0) 0

Write-Host "`n-- RETRY: 429 backs off longer, Retry-After is read in both forms --"
Check '429 waits 15 then 30, 60, 60'  ((1..4 | ForEach-Object { Get-RetryWait -Status 429 -RetryAfter 0 -Attempt $_ }) -join ',') '15,30,60,60'
Check '5xx keeps 2, 4, 8, 16'         ((1..4 | ForEach-Object { Get-RetryWait -Status 503 -RetryAfter 0 -Attempt $_ }) -join ',') '2,4,8,16'
Check 'Retry-After wins'              (Get-RetryWait -Status 429 -RetryAfter 45 -Attempt 1) 45
Check 'Retry-After capped at 300'     (Get-RetryWait -Status 429 -RetryAfter 3600 -Attempt 1) 300
Check 'Retry-After seconds'           (ConvertFrom-RetryAfter '120') 120
Check 'Retry-After HTTP-date'         (ConvertFrom-RetryAfter 'Mon, 09 Nov 2026 20:01:30 GMT' -Now ([datetime]::new(2026, 11, 9, 20, 0, 0, [DateTimeKind]::Utc))) 90
Check 'Retry-After past date is 0'    (ConvertFrom-RetryAfter 'Mon, 09 Nov 2026 19:00:00 GMT' -Now ([datetime]::new(2026, 11, 9, 20, 0, 0, [DateTimeKind]::Utc))) 0
Check 'Retry-After junk is 0'         (ConvertFrom-RetryAfter 'soon') 0

# ---- APPLICANTPRO, added 2026-11-19 (1.9.0) -------------------------------
# Fictional pages in the shape <tenant>.applicantpro.com serves: the /jobs/ page
# holds no postings, only the board's domain id (after rootDomainId, which must
# not be taken for it); /core/jobs/<domainId>?getParams={} answers the list as
# JSON; each posting's page carries a schema.org JobPosting block; the sitemap
# names every open posting and is the failover.
Write-Host "`n-- APPLICANTPRO: domain id, JSON list, JobPosting detail, sitemap failover --"
$apPage = @'
<script>window.courierCurrentRouteData = {"domain_id":"9001","career_site_name":"Example CU","root_domain_title":"Example","root_domain_id":"4"};</script>
<job-listings v-bind="componentData"></job-listings>
<script>var componentData = { organizationId : 7001, rootDomainId : 4, domainId : 9001, domainName : "applicantpro.com", domainTitle : "Example Credit Union" };</script>
'@
Check 'ApplicantPro domain id, not the root one' (Get-ApplicantProDomainId $apPage) '9001'
Check 'ApplicantPro domain id from route data'   (Get-ApplicantProDomainId '<script>x = {"domain_id":"9002","root_domain_id":"4"};</script>') '9002'
Check 'ApplicantPro root id alone is no id'      (Get-ApplicantProDomainId '<script>a = { rootDomainId : 4 }; b = {"root_domain_id":"4"}</script>') ''
Check 'ApplicantPro no page, no id'              (Get-ApplicantProDomainId '') ''

Check 'ApplicantPro pay per hour'   (ConvertTo-ApplicantProPay '27.50' '33.25' 'per hour') '$27.50 - $33.25 per hour'
Check 'ApplicantPro pay per year'   (ConvertTo-ApplicantProPay '88000' '104000' 'per year') '$88,000 - $104,000'
Check 'ApplicantPro pay YEAR unit'  (ConvertTo-ApplicantProPay '76000' '91000' 'YEAR') '$76,000 - $91,000'
Check 'ApplicantPro pay other unit' (ConvertTo-ApplicantProPay '1' '250000' 'other') ''
Check 'ApplicantPro pay no figures' (ConvertTo-ApplicantProPay $null $null 'per hour') ''

$apList = @'
{"success":true,"message":"list","data":{"jobCount":4,"jobs":[
 {"id":9100001,"title":"Service Desk Technician","city":"Harborview","abbreviation":"WM","stateName":"Westmark","workplaceType":"Work from home flexibility","payType":"Hourly","payTypeFrame":"per hour","minSalary":"27.50","maxSalary":"33.25","startDateRef":"Oct 30, 2026","jobUrl":"https://examplecu.applicantpro.com/jobs/9100001"},
 {"id":9100002,"title":"IT Infrastructure Support Engineer ","city":"Harborview","abbreviation":"WM","workplaceType":"Fully remote","payTypeFrame":"per year","minSalary":"88000","maxSalary":"104000","startDateRef":"Jul 3, 2026","jobUrl":"https://examplecu.applicantpro.com/jobs/9100002"},
 {"id":9100003,"title":"","city":"Harborview","abbreviation":"WM"},
 {"id":9100004,"title":"Join Our Talent Network","city":null,"abbreviation":null,"stateName":"Westmark","workplaceType":null,"payType":"Other","payTypeFrame":"other","minSalary":"1","maxSalary":"250000","startDateRef":"Mar 15, 2025"}
]}}
'@ | ConvertFrom-Json
$aj = @(@($apList.data.jobs) | ForEach-Object { ConvertFrom-ApplicantProJob $_ })
Check 'ApplicantPro hybrid stays a place'   $aj[0].Location 'Harborview, WM'
Check 'ApplicantPro fully remote'           $aj[1].Location 'Remote | Harborview, WM'
Check 'ApplicantPro start date as ISO'      $aj[0].Posted '2026-10-30'
Check 'ApplicantPro one-digit day'          $aj[1].Posted '2026-07-03'
Check 'ApplicantPro title trimmed'          $aj[1].Title 'IT Infrastructure Support Engineer'
Check 'ApplicantPro pay from the list'      $aj[0].Pay '$27.50 - $33.25 per hour'
Check 'ApplicantPro no title is null'       ($null -eq $aj[2]) $true
Check 'ApplicantPro state name fallback'    $aj[3].Location 'Westmark'
Check 'ApplicantPro placeholder has no pay' $aj[3].Pay ''
Check 'ApplicantPro id is text'             $aj[0].Id '9100001'

$apDetail = @'
<html><head><script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"Example"}</script>
<script type="application/ld+json">{"@context":"http://schema.org/","@type":"JobPosting","title":"IT Infrastructure Support Engineer",
"description":"<p>Run <strong>Intune</strong> and Entra ID for 40 branches.</p><ul><li>3+ years of endpoint support</li></ul>",
"datePosted":"2026-07-03 00:00:00","validThrough":"2031-07-03 00:00:00T23:59","employmentType":"FULL_TIME",
"baseSalary":{"@type":"MonetaryAmount","currency":"USD","value":{"@type":"QuantitativeValue","unitText":"YEAR","minValue":"88000","maxValue":"104000"}},
"jobLocation":{"@type":"Place","address":{"@type":"PostalAddress","streetAddress":"1 Dock St","addressLocality":"Harborview","addressRegion":"WM","addressCountry":"US"}}}</script>
</head><body>...</body></html>
'@
$ad = ConvertFrom-ApplicantProDetail $apDetail
Check 'ApplicantPro detail: JobPosting found past other blocks' $ad.Title 'IT Infrastructure Support Engineer'
Check 'ApplicantPro detail: description as text' ($ad.Content -like 'Run Intune and Entra ID for 40 branches.*3+ years of endpoint support*') $true
Check 'ApplicantPro detail: place'               $ad.Location 'Harborview, WM'
Check 'ApplicantPro detail: posted date only'    $ad.Posted '2026-07-03'
Check 'ApplicantPro detail: pay from baseSalary' $ad.Pay '$88,000 - $104,000'
Check 'ApplicantPro detail: telecommute is Remote' (ConvertFrom-ApplicantProDetail '<script type="application/ld+json">{"@type":"JobPosting","title":"A","jobLocationType":"TELECOMMUTE","jobLocation":{"address":{"addressRegion":"WM"}}}</script>').Location 'Remote | WM'
Check 'ApplicantPro detail: no block is null'    ($null -eq (ConvertFrom-ApplicantProDetail '<html>none</html>')) $true
Check 'ApplicantPro detail: bad JSON is skipped' ($null -eq (ConvertFrom-ApplicantProDetail '<script type="application/ld+json">{ not json</script>')) $true

$apMap = @'
<?xml version='1.0' encoding='UTF-8'?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://www.applicantpro.com/openings/examplecu/jobs/9100002</loc><lastmod>2026-07-03</lastmod></url>
  <url><loc>https://www.applicantpro.com/openings/examplecu/jobs/9100005</loc><lastmod>2026-11-02</lastmod></url>
  <url><loc>https://www.applicantpro.com/openings/examplecu/jobs/9100002</loc><lastmod>2026-07-03</lastmod></url>
  <url><loc>https://www.applicantpro.com/openings/examplecu/jobs/</loc><lastmod>2026-11-19</lastmod></url>
</urlset>
'@
Check 'ApplicantPro sitemap ids, once each, no list page' ((Get-ApplicantProSitemapId $apMap) -join ',') '9100002,9100005'
Check 'ApplicantPro empty sitemap'                        (@(Get-ApplicantProSitemapId '<urlset></urlset>').Count) 0

$script:testLog = @()
function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Test stand-in for the collector''s own Write-Log; records lines instead of printing them.')]
    param([string]$Message, [string]$Level = 'INFO')
    $script:testLog += "[$Level] $Message"
}
$script:apCalls = @(); $script:apListFails = $false
function Invoke-Html { param([string]$Uri)
    $script:apCalls += $Uri
    if ($Uri -like '*/jobs/') { return $apPage }
    if ($Uri -like '*/job_site_map.xml') { return $apMap }
    if ($Uri -like '*/jobs/9100002.html') { return $apDetail }
    if ($Uri -like '*/jobs/9100001.html') { return '<script type="application/ld+json">{"@type":"JobPosting","title":"Service Desk Technician","description":"<p>Desk support for branches.</p>"}</script>' }
    throw "HTTP 404 from the fake page $Uri"
}
function Invoke-Json { param([string]$Uri)
    $script:apCalls += $Uri
    if ($Uri -like '*/core/jobs/9001?getParams=%7B%7D') { if ($script:apListFails) { throw 'HTTP 500 from the fake list' } else { return $apList } }
    throw "unexpected URI $Uri"
}
$apSrc = @{ Company = 'Example Credit Union'; Tenant = 'ExampleCU' }
$ap = @(Get-ApplicantProJobs $apSrc)
Check 'ApplicantPro: titleless left out'        (($ap | ForEach-Object Title) -join ', ') 'Service Desk Technician, IT Infrastructure Support Engineer, Join Our Talent Network'
Check 'ApplicantPro: titleless row counted'     (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*ApplicantPro Example Credit Union: skipped 1 row*' }).Count) 1
Check 'ApplicantPro: tenant lower-cased'        $script:apCalls[0] 'https://examplecu.applicantpro.com/jobs/'
Check 'ApplicantPro: list from the domain id'   $script:apCalls[1] 'https://examplecu.applicantpro.com/core/jobs/9001?getParams=%7B%7D'
Check 'ApplicantPro: key by job id'             $ap[0].Key 'ApplicantPro|9100001'
Check 'ApplicantPro: url is the posting page'   $ap[0].Url 'https://examplecu.applicantpro.com/jobs/9100001'
Check 'ApplicantPro: detail is the .html page'  $ap[0].DetailPath 'https://examplecu.applicantpro.com/jobs/9100001.html'
Check 'ApplicantPro: list pay on the posting'   $ap[0].Pay '$27.50 - $33.25 per hour'
Check 'ApplicantPro: no text before detail'     $ap[0].Content ''
Check 'ApplicantPro: count matches, no warning' (@($script:testLog | Where-Object { $_ -like '*the board says*' }).Count) 0
Check 'ApplicantPro: log names the list'        (@($script:testLog | Where-Object { $_ -like '*ApplicantPro Example Credit Union: 3 postings -- JSON list, domain 9001*' }).Count) 1

$script:apCalls = @()
$apPin = @(Get-ApplicantProJobs @{ Company = 'Example Credit Union'; Tenant = 'examplecu'; DomainId = '9001' })
Check 'ApplicantPro: DomainId skips the page'   (@($script:apCalls | Where-Object { $_ -like '*/jobs/' }).Count) 0
Check 'ApplicantPro: DomainId still lists'      $apPin.Count 3

$apList.data.jobCount = 9
$script:testLog = @()
$null = @(Get-ApplicantProJobs $apSrc)
Check 'ApplicantPro: short list is a warning'   (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*the board says 9 postings but the list gave 4*' }).Count) 1
$apList.data.jobCount = 4

Add-ApplicantProDetail $ap[1]
Check 'ApplicantPro detail: content filled'     ($ap[1].Content -like 'Run Intune*') $true
Check 'ApplicantPro detail: list pay kept'      $ap[1].Pay '$88,000 - $104,000'
$ap[0].ListPay = ''
Add-ApplicantProDetail $ap[0]
Check 'ApplicantPro detail: no pay anywhere'    $ap[0].Pay ''
Check 'ApplicantPro detail: page text read'     $ap[0].Content 'Desk support for branches.'
$script:testLog = @()
Add-ApplicantProDetail $ap[2]
Check 'ApplicantPro detail: failure is a warning' (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*detail fetch failed for Example Credit Union / Join Our Talent Network*' }).Count) 1
Check 'ApplicantPro detail: failure keeps row'  $ap[2].Title 'Join Our Talent Network'

# Failover: the list fails, so the sitemap and each posting's page stand in.
$script:apListFails = $true
$script:testLog = @()
$apF = @(Get-ApplicantProJobs $apSrc)
Check 'ApplicantPro failover: list failure warned'   (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*list failed (HTTP 500 from the fake list)*' }).Count) 1
Check 'ApplicantPro failover: postings from pages'   (($apF | ForEach-Object Title) -join ', ') 'IT Infrastructure Support Engineer'
Check 'ApplicantPro failover: unloadable page warned' (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like '*posting 9100005 did not load*' }).Count) 1
Check 'ApplicantPro failover: text already in'      ($apF[0].Content -like 'Run Intune*') $true
Check 'ApplicantPro failover: pay from the page'    $apF[0].Pay '$88,000 - $104,000'
Check 'ApplicantPro failover: place from the page'  $apF[0].Location 'Harborview, WM'
Check 'ApplicantPro failover: log says how'         (@($script:testLog | Where-Object { $_ -like '*1 postings -- sitemap and posting pages (failover), 2 listed, 1 did not load*' }).Count) 1
$script:apListFails = $false
Remove-Item Function:\Invoke-Html, Function:\Invoke-Json, Function:\Write-Log

# ---- ADP: TWO HOSTS, added 1.9.1 -------------------------------------------
# Some WorkforceNow employers live on workforcenow.cloud.adp.com and get a 404
# from workforcenow.adp.com. AdpHost picks the host; a 404 on the first page
# makes the collector try the other host once and say which one answered.
Write-Host "`n-- ADP: plain and .cloud. hosts --"
Check 'ADP host: default is the plain host'      (Get-AdpHost @{ Cid = 'x' }) 'https://workforcenow.adp.com'
Check 'ADP host: cloud host kept'                (Get-AdpHost @{ AdpHost = 'https://workforcenow.cloud.adp.com/' }) 'https://workforcenow.cloud.adp.com'
Check 'ADP host: bare host gets https'           (Get-AdpHost @{ AdpHost = 'WorkforceNow.Cloud.ADP.com' }) 'https://workforcenow.cloud.adp.com'
$adpBad = try { Get-AdpHost @{ AdpHost = 'https://example.org' }; 'accepted' } catch { 'refused' }
Check 'ADP host: other hosts refused'            $adpBad 'refused'
Check 'ADP other host: from plain'               (Get-AdpOtherHost 'https://workforcenow.adp.com') 'https://workforcenow.cloud.adp.com'
Check 'ADP other host: from cloud'               (Get-AdpOtherHost 'https://workforcenow.cloud.adp.com') 'https://workforcenow.adp.com'
Check 'ADP 404: PS 7 message'                    (Test-HttpNotFound ([Management.Automation.ErrorRecord]::new([Exception]::new('Response status code does not indicate success: 404 (Not Found).'), 'x', 'NotSpecified', $null))) $true
Check 'ADP 404: PS 5.1 message'                  (Test-HttpNotFound ([Management.Automation.ErrorRecord]::new([Exception]::new('The remote server returned an error: (404) Not Found.'), 'x', 'NotSpecified', $null))) $true
Check 'ADP 404: a 500 is not one'                (Test-HttpNotFound ([Management.Automation.ErrorRecord]::new([Exception]::new('Response status code does not indicate success: 500 (Internal Server Error).'), 'x', 'NotSpecified', $null))) $false

$adpPage = [pscustomobject]@{ jobRequisitions = @(
    [pscustomobject]@{ requisitionTitle = 'Systems Administrator'; postDate = '2026-11-02T00:00:00Z'; clientRequisitionID = 'R-101'
        customFieldGroup = [pscustomobject]@{ stringFields = @([pscustomobject]@{ stringValue = '9000000001' }) }
        requisitionLocations = @([pscustomobject]@{ address = [pscustomobject]@{ cityName = 'Harborview'; countrySubdivisionLevel1 = [pscustomobject]@{ codeValue = 'WM' } } }) }
    [pscustomobject]@{ requisitionTitle = 'Help Desk Analyst'; postDate = '2026-11-05T00:00:00Z'
        customFieldGroup = [pscustomobject]@{ stringFields = @([pscustomobject]@{ stringValue = '9000000002' }) } }
) }
$script:testLog = @()
function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Test stand-in for the collector''s own Write-Log; records lines instead of printing them.')]
    param([string]$Message, [string]$Level = 'INFO')
    $script:testLog += "[$Level] $Message"
}
$script:adpCalls = @(); $script:adpLive = 'https://workforcenow.cloud.adp.com'
function Invoke-Json { param([string]$Uri)
    $script:adpCalls += $Uri
    if (-not $Uri.StartsWith($script:adpLive + '/')) { throw 'Response status code does not indicate success: 404 (Not Found).' }
    if ($Uri -like '*$skip=0') { return $adpPage }
    return [pscustomobject]@{ jobRequisitions = @() }
}
$adpCloud = @{ Company = 'Example Clinic'; Cid = '00000000-0000-0000-0000-000000000000'; CcId = '19000101_000003' }

# set AdpHost: the cloud host answers straight away, no failover
$adpSet = @(Get-AdpJobs ($adpCloud + @{ AdpHost = 'https://workforcenow.cloud.adp.com' }))
Check 'ADP cloud: postings read'                 (($adpSet | ForEach-Object Title) -join ', ') 'Systems Administrator, Help Desk Analyst'
Check 'ADP cloud: first call on the cloud host'  ($script:adpCalls[0] -like 'https://workforcenow.cloud.adp.com/mascsr/*') $true
Check 'ADP cloud: no 404, no failover'           (@($script:testLog | Where-Object { $_ -like '*returned 404*' }).Count) 0
Check 'ADP cloud: posting url on the cloud host' $adpSet[0].Url 'https://workforcenow.cloud.adp.com/mascsr/default/mdf/recruitment/recruitment.html?cid=00000000-0000-0000-0000-000000000000&ccId=19000101_000003&lang=en_US&jobId=9000000001'
Check 'ADP cloud: detail on the cloud host'      ($adpSet[0].DetailPath -like 'https://workforcenow.cloud.adp.com/mascsr/default/careercenter/public/events/staffing/v1/job-requisitions/9000000001?cid=*') $true
Check 'ADP cloud: place and requisition'         ('{0} | {1}' -f $adpSet[0].Location, $adpSet[0].ReqId) 'Harborview, WM | R-101'

# no AdpHost: the plain host 404s, the cloud host answers, and the log says so
$script:adpCalls = @(); $script:testLog = @()
$adpFo = @(Get-AdpJobs $adpCloud)
Check 'ADP failover: postings still read'        $adpFo.Count 2
Check 'ADP failover: plain host tried first'     ($script:adpCalls[0] -like 'https://workforcenow.adp.com/mascsr/*') $true
Check 'ADP failover: then the cloud host'        ($script:adpCalls[1] -like 'https://workforcenow.cloud.adp.com/mascsr/*') $true
Check 'ADP failover: later pages stay on it'     (@($script:adpCalls | Select-Object -Skip 1 | Where-Object { $_ -notlike 'https://workforcenow.cloud.adp.com/*' }).Count) 0
Check 'ADP failover: url on the host that answered' ($adpFo[0].Url -like 'https://workforcenow.cloud.adp.com/*') $true
Check 'ADP failover: warns with the fix'         (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') -and $_ -like "*ADP Example Clinic: answered on https://workforcenow.cloud.adp.com -- set AdpHost='https://workforcenow.cloud.adp.com'*" }).Count) 1

# plain-host employers are unchanged: no failover, no warning
$script:adpLive = 'https://workforcenow.adp.com'; $script:adpCalls = @(); $script:testLog = @()
$adpPlain = @(Get-AdpJobs $adpCloud)
Check 'ADP plain: postings read'                 $adpPlain.Count 2
Check 'ADP plain: url on the plain host'         ($adpPlain[0].Url -like 'https://workforcenow.adp.com/mascsr/*') $true
Check 'ADP plain: no warning'                    (@($script:testLog | Where-Object { $_.StartsWith('[WARN]') }).Count) 0

# both hosts 404: the error still reaches the caller, after one try on each
$script:adpLive = 'https://nowhere.invalid'; $script:adpCalls = @()
$adpBoth = try { $null = Get-AdpJobs $adpCloud; 'no error' } catch { $_.Exception.Message }
Check 'ADP both 404: error not swallowed'        ($adpBoth -like '*404*') $true
Check 'ADP both 404: one try per host'           $script:adpCalls.Count 2
Remove-Item Function:\Invoke-Json, Function:\Write-Log

# ---- SOURCES CARRY THE KEYS THEIR PROVIDER READS, added 2026-11-03 -------
# The example profile shipped a Workday entry with Dc= and an iCIMS entry with
# Token=, but the collector reads WdHost and BaseUrl. Anyone copying them got a
# source that could never answer. This runs against whichever profile is loaded.
Write-Host "`n-- SOURCES: every entry has the keys its provider reads --"
$needs = @{
    Greenhouse = @('Token'); Lever = @('Token'); Workday = @('WdHost', 'Tenant', 'Site'); iCIMS = @('BaseUrl')
    UltiPro = @('Tenant', 'BoardId'); ADP = @('Cid', 'CcId'); Dayforce = @('Namespace'); Microsoft = @('Queries')
    Rippling = @('Board'); Paylocity = @('BoardId'); ApplicantPro = @('Tenant')
}
$badSrc = @()
foreach ($s in @($Config.Sources)) {
    if (-not $needs.ContainsKey([string]$s.Provider)) { $badSrc += "$($s.Company): unknown Provider '$($s.Provider)'"; continue }
    $miss = @($needs[[string]$s.Provider] | Where-Object { -not $s.ContainsKey($_) -or -not $s[$_] })
    if ($miss.Count -gt 0) { $badSrc += "$($s.Company) ($($s.Provider)): missing $($miss -join ', ')" }
    if ([string]$s.Provider -eq 'ADP') {
        try { $null = Get-AdpHost $s } catch { $badSrc += "$($s.Company) (ADP): $($_.Exception.Message)" }
    }
}
Check 'every source has its keys'  ($badSrc -join '; ')  ''

# ---- SOURCE SCOUT (Find-JobSweepSources.ps1), added 2026-11-03 ----------
# Pure helpers only: URL reading, slug guesses, dedupe keys, entry formatting.
# The network probes are left to a live run.
Write-Host "`n-- SCOUT: careers URLs, slug guesses, dedupe, entry text --"
$scoutPath = Join-Path (Split-Path -Parent $SweepScript) 'Find-JobSweepSources.ps1'
Check 'scout script ships beside the sweep' (Test-Path -LiteralPath $scoutPath) $true
if (Test-Path -LiteralPath $scoutPath) {
    $sAst = [System.Management.Automation.Language.Parser]::ParseFile($scoutPath, [ref]$null, [ref]$parseErrors)
    Check 'scout script parses' (@($parseErrors).Count) 0
    $scoutWant = @('ConvertFrom-CareersUrl', 'Get-SlugGuess', 'Get-SourceKey', 'Format-SourceEntry', 'Get-NameFromSource', 'ConvertFrom-ScoutLine')
    $sFns = @($sAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $scoutWant -contains $n.Name }, $true))
    Check 'scout helpers all found' $sFns.Count $scoutWant.Count
    . ([scriptblock]::Create((@($sFns | ForEach-Object { $_.Extent.Text }) -join "`n`n")))

    $u = { param($x) $e = ConvertFrom-CareersUrl $x; if ($e) { Format-SourceEntry $e } else { 'none' } }
    Check 'Greenhouse board'       (& $u 'https://boards.greenhouse.io/ExampleBiotech/jobs/123')           "@{ Provider='Greenhouse'; Token='examplebiotech' }"
    Check 'Greenhouse job-boards'  (& $u 'https://job-boards.greenhouse.io/example-cloud')                 "@{ Provider='Greenhouse'; Token='example-cloud' }"
    Check 'Greenhouse embed'       (& $u 'https://boards.greenhouse.io/embed/job_board?for=examplebio')    "@{ Provider='Greenhouse'; Token='examplebio' }"
    Check 'Greenhouse API URL'     (& $u 'https://boards-api.greenhouse.io/v1/boards/examplebio/jobs')     "@{ Provider='Greenhouse'; Token='examplebio' }"
    Check 'Lever board'            (& $u 'https://jobs.lever.co/example-fintech/abc-123')                  "@{ Provider='Lever'; Token='example-fintech' }"
    Check 'Lever EU not offered'   (& $u 'https://jobs.eu.lever.co/example-fintech')                       'none'
    Check 'Workday tenant host'    (& $u 'https://examplehealth.wd1.myworkdayjobs.com/en-US/External/job/Westmark/Analyst_R1') "@{ Provider='Workday'; WdHost='https://examplehealth.wd1.myworkdayjobs.com'; Tenant='examplehealth'; Site='External' }"
    Check 'Workday no locale'      (& $u 'https://examplehealth.wd5.myworkdayjobs.com/Careers')            "@{ Provider='Workday'; WdHost='https://examplehealth.wd5.myworkdayjobs.com'; Tenant='examplehealth'; Site='Careers' }"
    Check 'Workday shared host'    (& $u 'https://wd3.myworkdaysite.com/en-US/recruiting/examplecity/Jobs') "@{ Provider='Workday'; WdHost='https://wd3.myworkdaysite.com'; Tenant='examplecity'; Site='Jobs' }"
    Check 'iCIMS careers host'     (& $u 'https://careers-examplebank.icims.com/jobs/1234/analyst/job')    "@{ Provider='iCIMS'; BaseUrl='https://careers-examplebank.icims.com' }"
    Check 'iCIMS www not a board'  (& $u 'https://www.icims.com/products')                                 'none'
    Check 'UltiPro default host'   (& $u 'https://recruiting.ultipro.com/exa1001examp/JobBoard/0000000A-0000-0000-0000-000000000000/') "@{ Provider='UltiPro'; Tenant='EXA1001EXAMP'; BoardId='0000000a-0000-0000-0000-000000000000' }"
    Check 'UltiPro numbered host'  (& $u 'https://recruiting2.ultipro.com/EXA1001EXAMP/JobBoard/00000000-0000-0000-0000-000000000000/?q=') "@{ Provider='UltiPro'; Tenant='EXA1001EXAMP'; UkgHost='https://recruiting2.ultipro.com'; BoardId='00000000-0000-0000-0000-000000000000' }"
    Check 'ADP cid and ccId'       (& $u 'https://workforcenow.adp.com/mascsr/default/mdf/recruitment/recruitment.html?cid=00000000-0000-0000-0000-000000000000&ccId=19000101_000001&lang=en_US') "@{ Provider='ADP'; Cid='00000000-0000-0000-0000-000000000000'; CcId='19000101_000001' }"
    Check 'ADP without cid'        (& $u 'https://workforcenow.adp.com/mascsr/default/mdf/recruitment/recruitment.html') 'none'
    Check 'ADP cloud host kept'    (& $u 'https://workforcenow.cloud.adp.com/mascsr/default/mdf/recruitment/recruitment.html?cid=00000000-0000-0000-0000-000000000000&ccId=19000101_000003&lang=en_US&jobId=1') "@{ Provider='ADP'; Cid='00000000-0000-0000-0000-000000000000'; CcId='19000101_000003'; AdpHost='https://workforcenow.cloud.adp.com' }"
    Check 'Dayforce with board'    (& $u 'https://jobs.dayforcehcm.com/en-US/examplelogistics/CANDIDATEPORTAL/jobs/123') "@{ Provider='Dayforce'; Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }"
    Check 'Dayforce no board'      (& $u 'https://jobs.dayforcehcm.com/examplelogistics')                  "@{ Provider='Dayforce'; Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }"
    Check 'Rippling board keeps case' (& $u 'https://ats.rippling.com/Example-Robotics/jobs/00000000-0000-0000-0000-000000000001')   "@{ Provider='Rippling'; Board='Example-Robotics' }"
    Check 'Rippling with locale'   (& $u 'https://ats.rippling.com/en-GB/example-robotics-careers/jobs')   "@{ Provider='Rippling'; Board='example-robotics-careers' }"
    Check 'Rippling API URL'       (& $u 'https://api.rippling.com/platform/api/ats/v1/board/example-robotics/jobs') "@{ Provider='Rippling'; Board='example-robotics' }"
    Check 'Rippling bare host'     (& $u 'https://ats.rippling.com/')                                     'none'
    Check 'Paylocity board'        (& $u 'https://recruiting.paylocity.com/Recruiting/Jobs/All/00000000-0000-0000-0000-0000000000AA/Example-Clinic') "@{ Provider='Paylocity'; BoardId='00000000-0000-0000-0000-0000000000aa' }"
    Check 'Paylocity other host'   (& $u 'https://2000recruiting.paylocity.com/recruiting/jobs/All/00000000-0000-0000-0000-0000000000aa') "@{ Provider='Paylocity'; PlcHost='https://2000recruiting.paylocity.com'; BoardId='00000000-0000-0000-0000-0000000000aa' }"
    Check 'Paylocity posting only' (& $u 'https://recruiting.paylocity.com/Recruiting/Jobs/Details/9000101') 'none'
    Check 'ApplicantPro tenant host' (& $u 'https://ExampleCU.applicantpro.com/jobs/9100002.html') "@{ Provider='ApplicantPro'; Tenant='examplecu' }"
    Check 'ApplicantPro jobs list'   (& $u 'https://examplecu.applicantpro.com/jobs/')            "@{ Provider='ApplicantPro'; Tenant='examplecu' }"
    Check 'ApplicantPro openings'    (& $u 'https://www.applicantpro.com/openings/examplecu/jobs/9100002') "@{ Provider='ApplicantPro'; Tenant='examplecu' }"
    Check 'ApplicantPro www is not a tenant' (& $u 'https://www.applicantpro.com/pricing')         'none'
    Check 'ApplicantPro feeds is not a tenant' (& $u 'https://feeds.applicantpro.com/site_map_index.xml') 'none'
    Check 'unknown site'           (& $u 'https://www.example.com/careers')                                'none'
    Check 'blank URL'              (& $u '')                                                               'none'

    Check 'slug: suffix dropped'   ((Get-SlugGuess 'Example Logistics, Inc.') -join ',')  'examplelogistics,example-logistics'
    Check 'slug: one word'         ((Get-SlugGuess 'Examplecorp') -join ',')              'examplecorp'
    Check 'slug: ampersand'        ((Get-SlugGuess 'Smith & Example LLC') -join ',')      'smithandexample,smith-and-example'
    Check 'slug: leading The'      ((Get-SlugGuess 'The Example Company') -join ',')      'example'
    Check 'slug: blank'            (@(Get-SlugGuess '').Count)                            0

    Check 'key: Workday ignores case'  (Get-SourceKey @{ Provider='Workday'; Tenant='ExampleHealth'; Site='External' }) 'workday|examplehealth|external'
    Check 'key: Dayforce board default' (Get-SourceKey @{ Provider='Dayforce'; Namespace='examplelogistics' }) 'dayforce|examplelogistics|candidateportal'
    Check 'key: iCIMS trailing slash'  (Get-SourceKey @{ Provider='iCIMS'; BaseUrl='https://careers-examplebank.icims.com/' }) 'icims|https://careers-examplebank.icims.com'
    Check 'entry quotes apostrophes'   (Format-SourceEntry @{ Provider='Lever'; Company="Example's Bakery"; Token='examples' }) "@{ Provider='Lever'; Company='Example''s Bakery'; Token='examples' }"
    Check 'key: Rippling board'        (Get-SourceKey @{ Provider='Rippling'; Board='Example-Robotics' }) 'rippling|example-robotics'
    Check 'key: Paylocity board'       (Get-SourceKey @{ Provider='Paylocity'; BoardId='00000000-0000-0000-0000-0000000000AA' }) 'paylocity|00000000-0000-0000-0000-0000000000aa'
    Check 'name from Paylocity slug'   (Get-NameFromSource (ConvertFrom-CareersUrl 'https://recruiting.paylocity.com/recruiting/jobs/All/00000000-0000-0000-0000-0000000000aa/Example-Clinic-LLC')) 'Example Clinic LLC'
    Check 'key: ApplicantPro tenant'   (Get-SourceKey @{ Provider='ApplicantPro'; Tenant='ExampleCU' }) 'applicantpro|examplecu'
    Check 'name from Rippling board'   (Get-NameFromSource @{ Provider='Rippling'; Board='example-robotics' }) 'example-robotics'
    Check 'name from iCIMS host'       (Get-NameFromSource @{ Provider='iCIMS'; BaseUrl='https://careers-examplebank.icims.com' }) 'examplebank'

    $l = { param($x) $e = ConvertFrom-ScoutLine $x; if ($e) { '{0}|{1}' -f $e.Company, $e.Url } else { 'none' } }
    Check 'line: name and URL'     (& $l 'Example Health, https://examplehealth.wd1.myworkdayjobs.com/External') 'Example Health|https://examplehealth.wd1.myworkdayjobs.com/External'
    Check 'line: URL only'         (& $l '  https://jobs.lever.co/example-fintech ')  '|https://jobs.lever.co/example-fintech'
    Check 'line: name only'        (& $l 'Example Logistics')                         'Example Logistics|'
    Check 'line: comment skipped'  (& $l '# not this one')                            'none'
    Check 'line: blank skipped'    (& $l '   ')                                       'none'
}

# ---- EMPLOYER DISCOVERY (Find-JobSweepEmployers.ps1), added 1.10.0 ---------
# Readers for the public datasets, the zone, the already-in-profile check, the
# merge and robots.txt. All offline: fixtures stand in for the downloads.
Write-Host "`n-- DISCOVERY: dataset readers, zone, profile match, robots --"
$discPath = Join-Path (Split-Path -Parent $SweepScript) 'Find-JobSweepEmployers.ps1'
Check 'discovery script ships beside the sweep' (Test-Path -LiteralPath $discPath) $true
if (Test-Path -LiteralPath $discPath) {
    $dAst = [System.Management.Automation.Language.Parser]::ParseFile($discPath, [ref]$null, [ref]$parseErrors)
    Check 'discovery script parses' (@($parseErrors).Count) 0
    $discWant = @('Get-DiscoverySetting', 'ConvertTo-ZipFive', 'ConvertTo-NameCase', 'Test-EmployerInZone', 'Get-EmployerNameKey',
                  'Test-EmployerInProfile', 'Get-NteeIndustry', 'Assert-DatasetColumn', 'New-EmployerRow', 'ConvertFrom-IrsEoCsv',
                  'ConvertFrom-NcuaCallReport', 'Get-NcuaNewestZip', 'ConvertFrom-FdicInstitution', 'ConvertFrom-LocalEmployerCsv',
                  'Merge-EmployerRow', 'Test-RobotsAllowed', 'Get-EmployerNameExclusion',
                  'Get-EmployerIndustryExclusion', 'Resolve-EmployerInZone')
    $dFns = @($dAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $discWant -contains $n.Name }, $true))
    Check 'discovery helpers all found' $dFns.Count $discWant.Count
    . ([scriptblock]::Create((@($dFns | ForEach-Object { $_.Extent.Text }) -join "`n`n")))

    $dSet = Get-DiscoverySetting @{ Discovery = @{ State = 'wm'; ZoneZipPrefixes = @('000'); ZoneZips = @('00150'); ZoneCities = @('Harborview')
                                                   ZoneExcludeZips = @('00077'); ZoneExcludeCities = @('Eastgate'); NteeExclude = @('X') } }
    Check 'setting: state upper-cased'       $dSet.State 'WM'
    Check 'setting: default revenue floor'   $dSet.MinNonprofitRevenue 10000000
    Check 'setting: default datasets'        ($dSet.Datasets -join ',') 'IRS,NCUA,FDIC,Local'
    Check 'setting: no Discovery block'      ((Get-DiscoverySetting @{}).MinBankAssets) 500000000

    $nxSet = Get-DiscoverySetting @{ Discovery = @{ NameExclude = @('^(the )?harborview community fund$', 'hospital foundation$', '') } }
    Check 'setting: NameExclude default empty' (@((Get-DiscoverySetting @{}).NameExclude).Count) 0
    Check 'setting: NameExclude blank dropped' (@($nxSet.NameExclude).Count) 2
    Check 'name exclude: anchored, any case'  (Get-EmployerNameExclusion 'THE HARBORVIEW COMMUNITY FUND' $nxSet) '^(the )?harborview community fund$'
    Check 'name exclude: anchored, not longer' (Get-EmployerNameExclusion 'Harborview Community Fund Housing' $nxSet) ''
    Check 'name exclude: suffix pattern'      (Get-EmployerNameExclusion 'Example Hospital Foundation' $nxSet) 'hospital foundation$'
    Check 'name exclude: parent kept'         (Get-EmployerNameExclusion 'Example Hospital' $nxSet) ''
    Check 'name exclude: none set'            (Get-EmployerNameExclusion 'Example Hospital Foundation' $dSet) ''
    # IndustryExclude, added 2026-11-20 (1.12.0): kinds of employer to drop from any dataset.
    $ixSet = Get-DiscoverySetting @{ Discovery = @{ IndustryExclude = @('consult', '\bmsp\b|managed (it )?services', 'aerospace', '') } }
    Check 'setting: IndustryExclude default empty' (@((Get-DiscoverySetting @{}).IndustryExclude).Count) 0
    Check 'setting: IndustryExclude blank dropped' (@($ixSet.IndustryExclude).Count) 3
    Check 'industry exclude: consultancy'     (Get-EmployerIndustryExclusion 'IT Consulting' $ixSet) 'consult'
    Check 'industry exclude: MSP'             (Get-EmployerIndustryExclusion 'MSP' $ixSet) '\bmsp\b|managed (it )?services'
    Check 'industry exclude: managed services' (Get-EmployerIndustryExclusion 'Managed IT Services' $ixSet) '\bmsp\b|managed (it )?services'
    Check 'industry exclude: aerospace'       (Get-EmployerIndustryExclusion 'Aerospace and Defense' $ixSet) 'aerospace'
    Check 'industry exclude: data centre kept' (Get-EmployerIndustryExclusion 'data centre' $ixSet) ''
    Check 'industry exclude: blank kept'      (Get-EmployerIndustryExclusion '' $ixSet) ''
    Check 'industry exclude: none set'        (Get-EmployerIndustryExclusion 'IT Consulting' $dSet) ''
    $exNx = @()
    try {
        $exProf = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $SweepScript) 'JobSweep.local.example.psd1')
        $exNx = @((Get-DiscoverySetting $exProf).NameExclude)
    } catch { Write-Verbose "example profile not read: $($_.Exception.Message)" }
    Check 'example: NameExclude shipped'      ($exNx.Count -gt 0) $true
    $badNx = @($exNx | Where-Object { try { $null = [regex]::new([string]$_); $false } catch { $true } })
    Check 'example: NameExclude patterns compile' $badNx.Count 0

    Check 'zone: ZIP prefix'                 (Test-EmployerInZone '00012-3456' 'Lakeside' $dSet) $true
    Check 'zone: exact ZIP'                  (Test-EmployerInZone '00150' 'Northfield' $dSet) $true
    Check 'zone: city, any case'             (Test-EmployerInZone '' 'HARBORVIEW' $dSet) $true
    Check 'zone: excluded ZIP wins'          (Test-EmployerInZone '00077' 'Harborview' $dSet) $false
    Check 'zone: excluded city wins'         (Test-EmployerInZone '00012' 'Eastgate' $dSet) $false
    Check 'zone: outside'                    (Test-EmployerInZone '00199' 'Elsewhere' $dSet) $false
    Check 'zone: none set = all in'          (Test-EmployerInZone '00199' 'Elsewhere' (Get-DiscoverySetting @{})) $true
    Check 'ZIP+4 to five digits'             (ConvertTo-ZipFive '00012-3456') '00012'
    Check 'name case from capitals'          (ConvertTo-NameCase 'EXAMPLE  HEALTH SERVICES INC') 'Example Health Services Inc'
    Check 'name case left when mixed'        (ConvertTo-NameCase 'ExampleCU of Westmark') 'ExampleCU of Westmark'

    Check 'name key: suffix and The'         (Get-EmployerNameKey 'The Example Clinic, Inc.') 'example clinic'
    Check 'name key: ampersand'              (Get-EmployerNameKey 'Smith & Example LLC') 'smith and example'
    $pk = @{ (Get-EmployerNameKey 'Example Health') = 'Example Health'; (Get-EmployerNameKey 'Harborview Credit Union') = 'Harborview Credit Union' }
    Check 'profile: same name'               (Test-EmployerInProfile 'EXAMPLE HEALTH' $pk) 'Example Health'
    Check 'profile: longer dataset name'     (Test-EmployerInProfile 'Example Health Services' $pk) 'Example Health'
    Check 'profile: shorter dataset name'    (Test-EmployerInProfile 'Harborview' $pk) 'Harborview Credit Union'
    Check 'profile: no partial word'         (Test-EmployerInProfile 'Example Healthcare Partners' $pk) ''

    Check 'NTEE: health care'                (Get-NteeIndustry 'E220') 'health care'
    Check 'NTEE: H is a research institute'  (Get-NteeIndustry 'H120') 'research institute (medical)'
    Check 'NTEE: U is a research institute'  (Get-NteeIndustry 'U20') 'research institute (science and technology)'
    Check 'NTEE: blank'                      (Get-NteeIndustry '') 'nonprofit (unclassified)'

    $irs = @'
"EIN","NAME","ICO","CITY","STATE","ZIP","REVENUE_AMT","NTEE_CD"
"000000001","EXAMPLE MEDICAL CENTER","","HARBORVIEW","WM","00012-0001","250000000","E220"
"000000002","EXAMPLE CHAPEL","","HARBORVIEW","WM","00012-0002","40000000","X20"
"000000003","SMALL EXAMPLE FUND","","HARBORVIEW","WM","00012-0003","900000","T20"
"000000004","EXAMPLE TRAINING ALLIANCE","","ELSEWHERE","WM","00199-0004","15000000",""
'@
    $ir = @(ConvertFrom-IrsEoCsv $irs $dSet)
    Check 'IRS: floor and NTEE exclusion'    (($ir | ForEach-Object company) -join ', ') 'Example Medical Center, Example Training Alliance'
    Check 'IRS: revenue as size'             ('{0} {1}' -f $ir[0].size_measure, $ir[0].size_value) 'revenue 250000000'
    Check 'IRS: industry and note'           ('{0} | {1}' -f $ir[0].industry, $ir[0].notes) 'health care | NTEE E220'
    Check 'IRS: EIN and five-digit ZIP'      ('{0} {1}' -f $ir[0].source_id, $ir[0].zip) '000000001 00012'
    $irsSub = @'
"EIN","NAME","CITY","ZIP","SUBSECTION","REVENUE_AMT","NTEE_CD"
"000000005","EXAMPLE HOSPITAL","HARBORVIEW","00012","03","50000000","E22"
"000000006","EXAMPLE WELFARE TRUST","HARBORVIEW","00012","09","90000000",""
"000000007","EXAMPLE CREDIT UNION","HARBORVIEW","00012","14","60000000",""
'@
    $irsSubSet = Get-DiscoverySetting @{ Discovery = @{ State = 'WM'; IrsSubsections = @('3', '14') } }
    Check 'IRS: subsections kept, trust dropped' ((@(ConvertFrom-IrsEoCsv $irsSub $irsSubSet) | ForEach-Object company) -join ', ') 'Example Hospital, Example Credit Union'
    Check 'IRS: no subsection list keeps all'  (@(ConvertFrom-IrsEoCsv $irsSub $dSet).Count) 3
    $irsDrift = try { $null = ConvertFrom-IrsEoCsv ("`"EIN`",`"NAME`",`"CITY`",`"ZIP`"`n`"1`",`"A`",`"B`",`"00012`"") $dSet; 'read' } catch { $_.Exception.Message }
    Check 'IRS: column drift is loud'        $irsDrift 'IRS EO BMF : missing column(s) REVENUE_AMT, NTEE_CD'

    $foicu = @'
"CU_NUMBER","CYCLE_DATE","CU_NAME","CITY","STATE","ZIP_CODE"
101,6/30/2026 0:00:00,"HARBORVIEW EXAMPLE","Harborview","WM","00012"
102,6/30/2026 0:00:00,"TINY EXAMPLE","Harborview","WM","00012"
103,6/30/2026 0:00:00,"OTHER STATE EXAMPLE","Elsewhere","ZZ","00199"
'@
    $fs220 = @'
"CU_NUMBER","CYCLE_DATE","ACCT_007","ACCT_010"
101,6/30/2026 0:00:00,1,2500000000
102,6/30/2026 0:00:00,1,5000000
103,6/30/2026 0:00:00,1,9000000000
'@
    $cu = @(ConvertFrom-NcuaCallReport $foicu $fs220 $dSet)
    Check 'NCUA: state and asset floor'      (($cu | ForEach-Object company) -join ', ') 'Harborview Example Credit Union'
    Check 'NCUA: ACCT_010 as assets'         ('{0} {1} {2}' -f $cu[0].size_measure, $cu[0].size_value, $cu[0].industry) 'assets 2500000000 credit union'
    $cuKeep = @(ConvertFrom-NcuaCallReport ($foicu -replace '"HARBORVIEW EXAMPLE"', '"HARBORVIEW EXAMPLE CU"') $fs220 $dSet)
    Check 'NCUA: CU in the name kept as is'  $cuKeep[0].company 'Harborview Example Cu'
    $ncuaDrift = try { $null = ConvertFrom-NcuaCallReport $foicu "`"CU_NUMBER`",`"ACCT_999`"`n101,1" $dSet; 'read' } catch { $_.Exception.Message }
    Check 'NCUA: column drift is loud'       $ncuaDrift 'NCUA FS220 : missing column(s) ACCT_010'
    $ncuaPage = '<a href="/files/publications/analysis/call-report-data-2025-12.zip">Q4</a> <a href="/files/publications/analysis/call-report-data-2026-06.zip">Q2</a> <a href="/files/publications/analysis/call-report-data-2026-03.zip">Q1</a>'
    Check 'NCUA: newest zip by quarter'      (Get-NcuaNewestZip $ncuaPage) 'https://ncua.gov/files/publications/analysis/call-report-data-2026-06.zip'
    Check 'NCUA: no zip link'                (Get-NcuaNewestZip '<p>none</p>') ''

    $fdic = '{"meta":{"total":2},"data":[{"data":{"NAME":"Example Savings Bank","CITY":"Harborview","ZIP":"00012","ASSET":2500000,"WEBADDR":"www.examplesavings.example","CERT":"9001"}},{"data":{"NAME":"Tiny Example Bank","CITY":"Harborview","ZIP":"00012","ASSET":90000,"WEBADDR":"","CERT":"9002"}}]}'
    $bk = @(ConvertFrom-FdicInstitution $fdic $dSet)
    Check 'FDIC: asset floor'                $bk.Count 1
    Check 'FDIC: thousands to dollars'       $bk[0].size_value 2500000000
    Check 'FDIC: website gets https'         $bk[0].website 'https://www.examplesavings.example'

    $loc = @(ConvertFrom-LocalEmployerCsv "company,website,city,zip`nHarborview Port Authority,,Harborview,00012`n,,,`n" 'gov.csv')
    Check 'local CSV: blank company skipped' $loc.Count 1
    Check 'local CSV: dataset names file'    $loc[0].source_dataset 'local: gov.csv'
    $man = @(ConvertFrom-LocalEmployerCsv "company,industry,source_dataset`nExample Data Centre,data centre,manual`nExample Studio,gaming studio,`n" 'employers-manual.csv')
    Check 'local CSV: source_dataset kept'   $man[0].source_dataset 'manual'
    Check 'local CSV: blank source_dataset'  $man[1].source_dataset 'local: employers-manual.csv'
    # in_zone in your own CSV, added 2026-11-20 (1.12.0): it wins over ZIP and city.
    $izr = @(ConvertFrom-LocalEmployerCsv "company,city,zip,in_zone`nExample Port District,,,true`nExample Water District,Harborview,00012,no`nExample Library,Harborview,00012,`nExample Transit,Eastgate,,TRUE`n" 'gov.csv')
    Check 'in_zone: true with no address'    (Resolve-EmployerInZone $izr[0] $dSet) $true
    Check 'in_zone: no beats an in-zone ZIP' (Resolve-EmployerInZone $izr[1] $dSet) $false
    Check 'in_zone: blank falls to ZIP'      (Resolve-EmployerInZone $izr[2] $dSet) $true
    Check 'in_zone: TRUE beats excluded city' (Resolve-EmployerInZone $izr[3] $dSet) $true
    Check 'in_zone: dataset row uses ZIP'    (Resolve-EmployerInZone (New-EmployerRow -Company 'X' -Website '' -Industry '' -Dataset 'IRS EO BMF' -SourceId '' -City 'Eastgate' -Zip '00012' -SizeMeasure '' -SizeValue '' -Notes '') $dSet) $false
    $izm = @(Merge-EmployerRow @(
        (New-EmployerRow -Company 'Example Port District' -Website '' -Industry 'government' -Dataset 'IRS EO BMF' -SourceId '9' -City '' -Zip '' -SizeMeasure 'revenue' -SizeValue 5 -Notes ''),
        $izr[0]))
    Check 'in_zone: kept through a merge'    (Resolve-EmployerInZone $izm[0] $dSet) $true
    $locDrift = try { $null = ConvertFrom-LocalEmployerCsv "name,city`nA,B" 'x.csv'; 'read' } catch { $_.Exception.Message }
    Check 'local CSV: needs company'         $locDrift 'local CSV x.csv : missing column(s) company'

    $m = @(Merge-EmployerRow @(
        (New-EmployerRow -Company 'Example Medical Center' -Website '' -Industry 'health care' -Dataset 'IRS EO BMF' -SourceId '1' -City 'Harborview' -Zip '00012' -SizeMeasure 'revenue' -SizeValue 250000000 -Notes 'NTEE E220'),
        (New-EmployerRow -Company 'EXAMPLE MEDICAL CENTER INC' -Website 'https://emc.example' -Industry 'health care' -Dataset 'local: x.csv' -SourceId '' -City 'Harborview' -Zip '00012' -SizeMeasure '' -SizeValue '' -Notes ''),
        (New-EmployerRow -Company 'Example Savings Bank' -Website '' -Industry 'bank' -Dataset 'FDIC' -SourceId '9001' -City 'Harborview' -Zip '00012' -SizeMeasure 'assets' -SizeValue 2500000000 -Notes '')))
    Check 'merge: one row per employer'      $m.Count 2
    Check 'merge: larger row kept'           $m[0].source_dataset 'IRS EO BMF'
    Check 'merge: website carried over'      $m[0].website 'https://emc.example'
    Check 'merge: note names the other'      $m[0].notes 'NTEE E220; also in local: x.csv'

    $rbAll = "User-agent: Examplebot`nUser-agent: Otherbot`nAllow: /`n`nUser-agent: *`nDisallow: /"
    Check 'robots: named bots only, * blocked' (Test-RobotsAllowed $rbAll '/careers/example') $false
    Check 'robots: bare CR line endings'     (Test-RobotsAllowed "User-agent: Examplebot`rAllow: /`r`rUser-agent: *`rDisallow: /" '/') $false
    $rbMix = "User-agent: *`r`nAllow: /core/*.css`$`r`nDisallow: /core/`r`nDisallow: /search/`r`nDisallow: /*search=*"
    Check 'robots: path not listed'          (Test-RobotsAllowed $rbMix '/pub/data/eo_wm.csv') $true
    Check 'robots: disallowed prefix'        (Test-RobotsAllowed $rbMix '/search/thing') $false
    Check 'robots: longer Allow wins'        (Test-RobotsAllowed $rbMix '/core/site.css') $true
    Check 'robots: $ anchors the end'        (Test-RobotsAllowed $rbMix '/core/site.css?v=2') $false
    Check 'robots: * inside a pattern'       (Test-RobotsAllowed $rbMix '/list?x=1&search=a') $false
    Check 'robots: empty Disallow allows'    (Test-RobotsAllowed "User-agent: *`nDisallow:" '/anything') $true
    Check 'robots: no file allows'           (Test-RobotsAllowed '' '/anything') $true
}

# ---- CAREERS-PAGE FINDER (Find-JobSweepSources.ps1 -EmployerCsv), added 1.11.0 -
# Link reading, the careers-link pick, ATS detection, domain guesses and the
# namesake check. Offline: fixture pages stand in for employer sites.
Write-Host "`n-- FINDER: careers links, ATS detection, website guesses --"
if ((Test-Path -LiteralPath $scoutPath) -and (Get-Command Get-EmployerNameKey -ErrorAction SilentlyContinue)) {
    $finderWant = @('Get-UnsupportedAtsHost', 'Get-PageLink', 'Select-CareersLink', 'Find-AtsReference', 'Get-EmployerWord',
                    'Get-DomainGuess', 'Test-PageNamesEmployer', 'Test-PageNeedsBrowser')
    $fFns = @($sAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $finderWant -contains $n.Name }, $true))
    Check 'finder helpers all found' $fFns.Count $finderWant.Count
    . ([scriptblock]::Create((@($fFns | ForEach-Object { $_.Extent.Text }) -join "`n`n")))

    Check 'legacy Dayforce URL'      (& $u 'https://usr58.dayforcehcm.com/CandidatePortal/en-US/examplelogistics/Posting/View/123') "@{ Provider='Dayforce'; Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }"
    Check 'legacy Dayforce us host'  (& $u 'https://us62.dayforcehcm.com/CandidatePortal/examplelogistics') "@{ Provider='Dayforce'; Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }"

    $home1 = @'
<html><head><title>Harborview Example Clinic | Care close to home</title></head><body>
<a href="/about">About</a> <a href="/volunteer-opportunities/">Volunteer opportunities</a>
<a href="/careers/">Careers</a> <a href="https://www.example.org/donate">Donate</a>
<a href="mailto:hr@example.org">Email</a> <a href="#top">Top</a>
<footer>100 Example Way, Harborview, WM 00012</footer></body></html>
'@
    $lk = @(Get-PageLink $home1 'https://www.harborviewexampleclinic.org/')
    Check 'links: mailto and anchors dropped'  $lk.Count 4
    Check 'links: made absolute'               $lk[2].Url 'https://www.harborviewexampleclinic.org/careers/'
    Check 'careers: "Careers" beats volunteer' (Select-CareersLink $lk) 'https://www.harborviewexampleclinic.org/careers/'
    $volOnly = @([pscustomobject]@{ Url = 'https://x.example.org/volunteer-opportunities/'; Text = 'Volunteer opportunities' })
    Check 'careers: volunteer page refused'    (Select-CareersLink $volOnly) ''
    $pathOnly = @([pscustomobject]@{ Url = 'https://x.example.org/about/join-us/'; Text = 'Get involved' })
    Check 'careers: path alone counts'         (Select-CareersLink $pathOnly) 'https://x.example.org/about/join-us/'
    $res = @([pscustomobject]@{ Url = 'https://x.example.org/learn/career-resources'; Text = 'Career resources' })
    Check 'careers: career resources refused'  (Select-CareersLink $res) ''

    $a = Find-AtsReference '<iframe src="https://boards.greenhouse.io/embed/job_board?for=exampleclinic"></iframe>' 'https://x.example.org/careers'
    Check 'ATS: Greenhouse iframe'      ('{0} {1} {2}' -f $a.Kind, $a.Ats, $a.Src.Token) 'supported Greenhouse exampleclinic'
    $a = Find-AtsReference '<a href="https://recruiting.paylocity.com/recruiting/jobs/All/00000000-0000-0000-0000-0000000000aa/Example-Clinic">Openings</a>' 'https://x.example.org/careers'
    Check 'ATS: Paylocity link'         ('{0} {1}' -f $a.Kind, $a.Ats) 'supported Paylocity'
    $a = Find-AtsReference '<a href="https://jobs.jobvite.com/exampleclinic/jobs">Jobs</a> <a href="https://boards.greenhouse.io/exampleclinic">GH</a>' 'https://x.example.org/careers'
    Check 'ATS: supported wins'         $a.Ats 'Greenhouse'
    $a = Find-AtsReference '<a href="https://www.paycomonline.net/v4/ats/web.php/jobs?clientkey=EXAMPLE">Apply</a>' 'https://x.example.org/careers'
    Check 'ATS: unsupported named'      ('{0} {1}' -f $a.Kind, $a.Ats) 'unsupported Paycom'
    $a = Find-AtsReference '<script src="https://careers-content.clearcompany.com/js/v1/career-site.js?siteId=x"></script>' 'https://x.example.org/careers'
    Check 'ATS: script source counts'   $a.Ats 'ClearCompany'
    $a = Find-AtsReference '' 'https://usr58.dayforcehcm.com/CandidatePortal/en-US/exampleclinic'
    Check 'ATS: the page URL itself'    ('{0} {1}' -f $a.Ats, $a.Src.Namespace) 'Dayforce exampleclinic'
    Check 'ATS: none on a plain page'   ($null -eq (Find-AtsReference '<p>Email your resume to us.</p>' 'https://x.example.org/careers')) $true

    Check 'words: generic tail dropped' ((Get-EmployerWord 'Harborview Example Services Association') -join ',') 'harborview,example'
    $gs = @(Get-DomainGuess 'Harborview Example Clinic')
    Check 'guess: run together first'   $gs[0] 'https://www.harborviewexampleclinic.org/'
    Check 'guess: without generic tail' ($gs -contains 'https://www.harborviewexample.org/') $true
    Check 'guess: without place name'   ($gs -contains 'https://www.exampleclinic.org/') $true
    Check 'guess: capped'               (@(Get-DomainGuess 'Harborview Example Clinic Of Westmark' -Max 3).Count) 3
    Check 'guess: blank name'           (@(Get-DomainGuess '').Count) 0

    Check 'namesake: title and city'    (Test-PageNamesEmployer $home1 'HARBORVIEW EXAMPLE CLINIC' 'Harborview') $true
    $elsewhere = '<html><head><title>Example Clinic | Eastgate</title></head><body>Eastgate, ZZ</body></html>'
    Check 'namesake: other city refused' (Test-PageNamesEmployer $elsewhere 'Example Clinic' 'Harborview') $false
    Check 'namesake: other name refused' (Test-PageNamesEmployer $home1 'Lakeside Dental Group' 'Harborview') $false
    Check 'namesake: no city given'     (Test-PageNamesEmployer $elsewhere 'Example Clinic' '') $true

    Check 'browser: script shell'       (Test-PageNeedsBrowser '<div id="root"></div><noscript>Please enable JavaScript</noscript>' 1) $true
    Check 'browser: ordinary page'      (Test-PageNeedsBrowser $home1 4) $false
    Check 'browser: many links'         (Test-PageNeedsBrowser '<div id="app"></div>' 40) $false
    Check 'browser: no links at all'    (Test-PageNeedsBrowser '<html><body><script src="/bundle.js"></script></body></html>' 0) $true
    Check 'browser: a few links, no shell' (Test-PageNeedsBrowser '<p>Hello</p>' 6) $false
    Check 'unsupported list has names'  ((Get-UnsupportedAtsHost).Contains('Jobvite')) $true
} else {
    Check 'finder needs the scout and the employer script' $false $true
}

} catch {
    $fail++
    $stoppedBy = "suite stopped at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-Host "  FAIL  $stoppedBy" -ForegroundColor Red
}

$skipNote = if ($skipped -gt 0) { "   SKIPPED $skipped example-geography checks (not the example profile -- cover your own places in Test-JobSweepProfile.ps1)" } else { '' }
Write-Host ("`nPASS {0}   FAIL {1}{2}" -f $pass, $fail, $skipNote)
if ($ResultPath) {
    [ordered]@{
        Pass = $pass; Fail = $fail; Skipped = $skipped
        Profile = (($ProfilePath | ForEach-Object { Split-Path $_ -Leaf }) -join ' + ')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
if (-not $ResultPath) {
    # A -BothEditions child leaves the banner to the parent, which prints one for both.
    . (Join-Path $PSScriptRoot 'JobSweep.Summary.ps1')
    $row = [pscustomobject][ordered]@{
        Edition = $PSVersionTable.PSEdition; Version = "$($PSVersionTable.PSVersion)"
        Profile = (($ProfilePath | ForEach-Object { Split-Path $_ -Leaf }) -join ' + ')
        Pass = $pass; Fail = $fail; Skipped = $skipped
        Result = $(if ($fail -gt 0) { 'FAIL' } else { 'PASS' })
    }
    if ($stoppedBy) { $row | Add-Member -NotePropertyName Note -NotePropertyValue $stoppedBy }
    Write-JobSweepSummary -Script 'Test-JobSweepFilters.ps1' -Target $SweepScript -Rows @($row) -Pass $pass -Fail $fail -Skip $skipped
}
if ($fail -gt 0) { exit 1 }
