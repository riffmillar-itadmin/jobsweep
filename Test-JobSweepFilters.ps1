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

    Write-Host "`n==== summary ====" -ForegroundColor Cyan
    # Out-String with a wide line so a long profile list is not cut to the window.
    $results | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
    if (@($results | Where-Object { $_.Result -ne 'PASS' }).Count -gt 0) { exit 1 }
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
          'New-Posting','Convert-HtmlToText','Get-WorkdayJobs','Get-GreenhouseJobs','Get-LeverJobs')
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
Remove-Item Function:\Invoke-Json, Function:\Write-Log

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

# ---- SOURCES CARRY THE KEYS THEIR PROVIDER READS, added 2026-11-03 -------
# The example profile shipped a Workday entry with Dc= and an iCIMS entry with
# Token=, but the collector reads WdHost and BaseUrl. Anyone copying them got a
# source that could never answer. This runs against whichever profile is loaded.
Write-Host "`n-- SOURCES: every entry has the keys its provider reads --"
$needs = @{
    Greenhouse = @('Token'); Lever = @('Token'); Workday = @('WdHost', 'Tenant', 'Site'); iCIMS = @('BaseUrl')
    UltiPro = @('Tenant', 'BoardId'); ADP = @('Cid', 'CcId'); Dayforce = @('Namespace'); Microsoft = @('Queries')
}
$badSrc = @()
foreach ($s in @($Config.Sources)) {
    if (-not $needs.ContainsKey([string]$s.Provider)) { $badSrc += "$($s.Company): unknown Provider '$($s.Provider)'"; continue }
    $miss = @($needs[[string]$s.Provider] | Where-Object { -not $s.ContainsKey($_) -or -not $s[$_] })
    if ($miss.Count -gt 0) { $badSrc += "$($s.Company) ($($s.Provider)): missing $($miss -join ', ')" }
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
    Check 'Dayforce with board'    (& $u 'https://jobs.dayforcehcm.com/en-US/examplelogistics/CANDIDATEPORTAL/jobs/123') "@{ Provider='Dayforce'; Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }"
    Check 'Dayforce no board'      (& $u 'https://jobs.dayforcehcm.com/examplelogistics')                  "@{ Provider='Dayforce'; Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }"
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
    Check 'name from iCIMS host'       (Get-NameFromSource @{ Provider='iCIMS'; BaseUrl='https://careers-examplebank.icims.com' }) 'examplebank'

    $l = { param($x) $e = ConvertFrom-ScoutLine $x; if ($e) { '{0}|{1}' -f $e.Company, $e.Url } else { 'none' } }
    Check 'line: name and URL'     (& $l 'Example Health, https://examplehealth.wd1.myworkdayjobs.com/External') 'Example Health|https://examplehealth.wd1.myworkdayjobs.com/External'
    Check 'line: URL only'         (& $l '  https://jobs.lever.co/example-fintech ')  '|https://jobs.lever.co/example-fintech'
    Check 'line: name only'        (& $l 'Example Logistics')                         'Example Logistics|'
    Check 'line: comment skipped'  (& $l '# not this one')                            'none'
    Check 'line: blank skipped'    (& $l '   ')                                       'none'
}

$skipNote = if ($skipped -gt 0) { "   SKIPPED $skipped example-geography checks (not the example profile -- cover your own places in Test-JobSweepProfile.ps1)" } else { '' }
Write-Host ("`nPASS {0}   FAIL {1}{2}" -f $pass, $fail, $skipNote)
if ($ResultPath) {
    [ordered]@{
        Pass = $pass; Fail = $fail; Skipped = $skipped
        Profile = (($ProfilePath | ForEach-Object { Split-Path $_ -Leaf }) -join ' + ')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
if ($fail -gt 0) { exit 1 }
