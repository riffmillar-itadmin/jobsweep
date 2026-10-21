<#
.SYNOPSIS
    Regression tests for Invoke-JobSweep.ps1's screening filters.

.DESCRIPTION
    Every silent-screening bug this toolset has had looked like "nothing was
    posted this week": \bmanager\b killing Software Asset Manager, a bare 'entra'
    matching CENTRAl Kitchen, Washington DC passing on 'washington', a degree flag
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
    [switch]   $BothEditions
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
    $call += '; exit $LASTEXITCODE'

    $results = foreach ($exe in 'powershell.exe', 'pwsh') {
        Write-Host "`n==== $exe ====" -ForegroundColor Cyan
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            Write-Host "$exe not found -- cannot test this edition." -ForegroundColor Red
            [pscustomobject]@{ Edition = $exe; Version = '-'; Result = 'MISSING' }
            continue
        }
        $ver = & $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        & $exe -NoProfile -ExecutionPolicy Bypass -Command $call | Out-Host
        $code = $LASTEXITCODE
        [pscustomobject]@{ Edition = $exe; Version = "$ver"; Result = $(if ($code -eq 0) { 'PASS' } else { "FAIL (exit $code)" }) }
    }

    Write-Host "`n==== summary ====" -ForegroundColor Cyan
    $results | Format-Table -AutoSize | Out-Host
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
          'Test-ComplianceTitleOnly','Test-ItContext','Merge-JobSweepProfile')
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

$pass = 0; $fail = 0
function Check {
    param([string]$What, $Got, $Want)
    if ("$Got" -eq "$Want") { $script:pass++ }
    else { $script:fail++; Write-Host ("  FAIL  {0}`n        got  '{1}'`n        want '{2}'" -f $What, $Got, $Want) -ForegroundColor Red }
}

Write-Host "`n-- LOCATION: onsite still screened as before --"
Check 'Seattle onsite'        (Test-LocationMatch 'Seattle, WA').Ok            $true
Check 'Bellevue onsite'       (Test-LocationMatch 'Bellevue, WA').Ok           $true
Check 'Renton onsite DROPS'   (Test-LocationMatch 'Renton, WA').Ok             $false
Check 'Tacoma onsite DROPS'   (Test-LocationMatch 'Tacoma, WA').Ok             $false
Check 'Washington DC DROPS'   (Test-LocationMatch 'Washington, DC').Ok         $false
Check 'US-DC- form DROPS'     (Test-LocationMatch 'US-DC-Washington').Ok       $false
Check 'Austin onsite DROPS'   (Test-LocationMatch 'Austin, TX').Ok             $false
Check 'blank passes'          (Test-LocationMatch '').Ok                       $true

Write-Host "`n-- LOCATION: national remote now IN --"
Check 'Remote - US'           (Test-LocationMatch 'Remote - US').Ok            $true
Check 'Remote Texas'          (Test-LocationMatch 'Remote, Austin TX').Ok      $true
Check 'USA-Remote'            (Test-LocationMatch 'USA-Remote').Ok             $true
Check 'Work from home'        (Test-LocationMatch 'Work From Home').Ok         $true
Check 'remote beats commute'  (Test-LocationMatch 'Remote - Renton, WA').Ok    $true
Check 'remote beats DC'       (Test-LocationMatch 'Remote - Washington, DC').Ok $true

Write-Host "`n-- LOCATION: outside the US still out, remote or not --"
Check 'Toronto DROPS'         (Test-LocationMatch 'Toronto, Ontario').Ok       $false
Check 'Remote India DROPS'    (Test-LocationMatch 'Remote - Bengaluru, India').Ok $false
Check 'Remote UK DROPS'       (Test-LocationMatch 'Remote, London, UK').Ok     $false

Write-Host "`n-- LOCATION: multi-city reqs go to judgement, not the bin (added 2026-09-19) --"
# Every one of these is a real string from sweep-2026-09-18-1923.
Check '4-city req KEPT'       (Test-LocationMatch 'Atlanta, GA | Washington, DC | Chicago, IL | New York, NY').Ok $true
Check 'multi-city req KEPT'    (Test-LocationMatch 'The Link | Austin, TX | Boston, MA | Washington, DC | Seattle, WA').Ok $true
Check 'N Locations KEPT'       (Test-LocationMatch '3 Locations').Ok               $true
Check 'single DC still DROPS'  (Test-LocationMatch 'Washington, DC').Ok            $false
Check 'single PaloAlto DROPS'  (Test-LocationMatch 'Palo Alto, CA').Ok             $false
Check 'multi-city non-US DROPS' (Test-LocationMatch 'Toronto, Ontario | London, UK').Ok $false

Write-Host "`n-- REMOTE VETTING --"
Check 'WA excluded BLOCKS' (Test-RemoteFlags 'This role is remote. We are not able to hire in the following states: Washington, Colorado.').Block 'remote role excludes Washington residents'
Check 'WA ineligible BLOCKS' (Test-RemoteFlags 'Residents of California and Washington are not eligible for this position.').Block 'remote role excludes Washington residents'
Check 'clean posting no block' (Test-RemoteFlags 'Fully remote across the United States. Competitive pay.').Block ''
$et = Test-RemoteFlags 'Candidates must provide coverage during Eastern Time business hours.'
Check 'ET flagged'  ($et.Flags -join '|')  'CHECK: Eastern-hours coverage stated -- that is a 5-6am start here'
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

# ---- REMOTE STATED IN THE TITLE, added 2026-09-21 ------------------------
# The Option Care Health case: a fully remote req filed against the head office.
Check 'OptionCare title rescue' (Test-LocationMatch 'Springfield, IL' 'Engineer, Endpoint - Remote').Ok $true
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
Check 'no title, Seattle KEPT'   (Test-LocationMatch 'Seattle, WA').Ok                                    $true
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

# ---- WORKSITE CHECK, added 2026-09-22, renamed from EastsideCheck 2026-10-12 ----
# Bellevue and Redmond stay IN SCOPE -- the check rides along as a question.
# Asserted on the CHECK: prefix, never the note text: the note comes from the
# profile, so the shipped suite and the private one see different wording.
Check 'Bellevue still KEPT'    (Test-LocationMatch 'Bellevue, WA').Ok                         $true
Check 'Redmond still KEPT'     (Test-LocationMatch 'Redmond, WA').Ok                          $true
Check 'Bellevue carries check' ((Test-LocationMatch 'Bellevue, WA').Check -like 'CHECK:*')    $true
Check 'Redmond carries check'  ((Test-LocationMatch 'Redmond, WA').Check -like 'CHECK:*')     $true
# Seattle and plain-Washington matches must NOT carry it.
Check 'Seattle no check'       ([bool](Test-LocationMatch 'Seattle, WA').Check)               $false
Check 'bare WA no check'       ([bool](Test-LocationMatch 'Olympia Washington').Check)        $false
# Remote returns before the include loop, so no worksite question applies.
Check 'Remote Bellevue no chk' ([bool](Test-LocationMatch 'Remote - Bellevue, WA').Check)     $false
Check 'Remote Bellevue KEPT'   (Test-LocationMatch 'Remote - Bellevue, WA').Ok                $true
# Multi-city already goes to judgement, so it returns before the check too.
Check 'multi-city no check'    ([bool](Test-LocationMatch 'Seattle, WA | Bellevue, WA').Check) $false
# The Eastside cities that were ALREADY excluded must stay excluded.
Check 'Kirkland still DROPS'   (Test-LocationMatch 'Kirkland, WA').Ok                         $false
Check 'Bothell still DROPS'    (Test-LocationMatch 'Bothell, WA').Ok                          $false
Check 'Issaquah still DROPS'   (Test-LocationMatch 'Issaquah, WA').Ok                         $false
Check 'Renton still DROPS'     (Test-LocationMatch 'Renton, WA').Ok                           $false
# Substring safety: no false trigger on an unrelated string.
Check 'no check on Palo Alto'  ([bool](Test-LocationMatch 'Palo Alto, CA').Check)             $false

# ---- REGION CHECK, added 2026-10-12 --------------------------------------
# A string that names a REGION names no city, so no city rule can judge it.
# MEASURED before the fix, against both the example and the real profile:
#   "Greater Seattle Area"  -> in scope, NO FLAG   (matched LocationInclude on
#                              the substring 'seattle', while Everett and Tacoma
#                              sit inside that region and are in CommuteExclude)
#   "Eastside, WA"          -> DROPPED outright    (by a filter then named
#                              EastsideCheck, which matched only city names)
# Two silent failures in opposite directions. Both are now questions.
Check 'Greater Seattle KEPT'   (Test-LocationMatch 'Greater Seattle Area').Ok                 $true
Check 'Greater Seattle flags'  ((Test-LocationMatch 'Greater Seattle Area').Check -like 'CHECK:*') $true
Check 'Seattle Metro flags'    ((Test-LocationMatch 'Seattle Metropolitan Area').Check -like 'CHECK:*') $true
Check 'Puget Sound KEPT'       (Test-LocationMatch 'Puget Sound Region').Ok                   $true
Check 'Puget Sound flags'      ((Test-LocationMatch 'Puget Sound Region').Check -like 'CHECK:*') $true
Check 'Eastside KEPT not drop' (Test-LocationMatch 'Eastside, WA').Ok                         $true
Check 'Eastside flags'         ((Test-LocationMatch 'Eastside, WA').Check -like 'CHECK:*')    $true
Check 'King County flags'      ((Test-LocationMatch 'King County, WA').Check -like 'CHECK:*') $true
Check 'PNW KEPT not dropped'   (Test-LocationMatch 'Pacific Northwest').Ok                    $true

# ORDERING IS LOAD-BEARING, so assert it rather than trusting the line order.
# Before LocationInclude: 'Greater Seattle Area' contains 'seattle', which is in
# LocationInclude. If the region loop ran second this would read 'location in
# scope' and carry no flag -- exactly the bug being fixed.
Check 'region beats include'   ((Test-LocationMatch 'Greater Seattle Area').Reason -like 'region named*') $true
# After CommuteExclude: a region phrase that also names an excluded city is still
# dropped. Synthetic string -- 'washington dc' is in CommuteExclude in both the
# example and the real profile, which is what makes this assertion portable.
Check 'commute beats region'   (Test-LocationMatch 'Puget Sound / Washington DC').Ok          $false
# A plain city must not pick up a region flag.
Check 'Seattle no region flag' ([bool](Test-LocationMatch 'Seattle, WA').Check)               $false
Check 'Bellevue reason intact' ((Test-LocationMatch 'Bellevue, WA').Reason)        'location in scope'

# ---- AN UNKNOWN PROFILE KEY STOPS THE RUN, added 2026-10-12 --------------
# Merging is replace-by-key, so before this a stale key was carried into $Config
# and never read. Renaming EastsideCheck -> WorksiteCheck without updating the
# profile would have silently switched the worksite flag off. This is the guard
# that makes any future rename fail loudly instead.
$badProfile = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-badkey-{0}.psd1" -f ([guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $badProfile -Value "@{ EastsideCheck = @('bellevue') }" -Encoding utf8
$threw = $false; $msg = ''
try   { Merge-JobSweepProfile -Defaults $Config -ProfilePath @($badProfile) | Out-Null }
catch { $threw = $true; $msg = "$_" }
Remove-Item -LiteralPath $badProfile -Force -ErrorAction SilentlyContinue
Check 'stale key throws'       $threw                                                         $true
Check 'error names the key'    ($msg -like '*EastsideCheck*')                                 $true
Check 'error lists valid keys' ($msg -like '*WorksiteCheck*')                                 $true

# ---- MALFORMED LOCATION IS NOT A SCREEN-OUT, added 2026-09-25 ------------
# iCIMS served Cayuse Holdings' Sr Microsoft Engineer with the literal stub
# "US-". It is neither null nor whitespace, so it fell through to the
# out-of-scope return and a remote req at $75-85/hr was screened out.
Check 'Cayuse US- KEPT'        (Test-LocationMatch 'US-').Ok                              $true
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
Check 'US-WA-Seattle KEPT'     (Test-LocationMatch 'US-WA-Seattle').Ok                    $true
Check 'US-TX-Austin DROPS'     (Test-LocationMatch 'US-TX-Austin').Ok                     $false
Check 'PaloAlto no stub check' ([bool](Test-LocationMatch 'Palo Alto, CA').Check)         $false
Check 'Seattle no stub check'  ([bool](Test-LocationMatch 'Seattle, WA').Check)           $false
# A non-US stub is still a stub, not an exclusion -- the body decides.
Check 'India NOT a stub'       (Test-LocationMatch 'Bengaluru, India').Ok                 $false

# ---- WORKDAY bulletFields MAPPING, added 2026-09-25 ----------------------
# Jackson Lewis posted to twelve cities including Seattle. The tenant put the
# additional-locations list in bulletFields[0], the sweep wrote it into ReqId,
# and the req was scored on New York alone. Second loss of this employer's
# location list; the first was a WebFetch summary.
Check 'reqid REQ- form'        (Test-IsRequisitionId 'REQ-0000133378')                    $true
Check 'reqid JR form'          (Test-IsRequisitionId 'JR78095')                           $true
Check 'reqid R- form'          (Test-IsRequisitionId 'R-12345')                           $true
Check 'reqid year-seq form'    (Test-IsRequisitionId '2026-4572')                         $true
Check 'city is NOT a reqid'    (Test-IsRequisitionId 'Seattle, WA')                       $false
Check 'city list NOT a reqid'  (Test-IsRequisitionId 'Atlanta, GA | Seattle, WA')         $false
Check 'N Locations NOT a reqid' (Test-IsRequisitionId '12 Locations')                     $false
Check 'posted-ago NOT a reqid' (Test-IsRequisitionId '5 Days Ago')                        $false
Check 'time type NOT a reqid'  (Test-IsRequisitionId 'Full time')                         $false
Check 'bare city NOT a reqid'  (Test-IsRequisitionId 'New York')                          $false
Check 'empty NOT a reqid'      (Test-IsRequisitionId '')                                  $false

Check 'city,ST is a location'  (Test-LooksLikeLocationList 'Seattle, WA')                 $true
Check 'piped list is location' (Test-LooksLikeLocationList 'Atlanta, GA | Seattle, WA')   $true
Check 'N Locations is location' (Test-LooksLikeLocationList '12 Locations')               $true
Check 'Remote is location'     (Test-LooksLikeLocationList 'Remote')                      $true
Check 'reqid NOT a location'   (Test-LooksLikeLocationList 'REQ-0000133378')              $false
Check 'time type NOT location' (Test-LooksLikeLocationList 'Full time')                   $false

# The defect itself: the twelve-city bullet must reach Location, not ReqId.
$jl = Resolve-WorkdayBullets @('New York, NY | Boston, MA | Seattle, WA | Chicago, IL') 'New York, NY'
Check 'JL reqid not polluted'  ($jl.ReqId -like '*Seattle*')                              $false
Check 'JL Seattle recovered'   ($jl.Location -like '*Seattle, WA*')                       $true
Check 'JL goes to judgement'   (Test-LocationMatch $jl.Location).Ok                       $true
Check 'JL was DROPPED before'  (Test-LocationMatch 'New York, NY').Ok                     $false

# The ordinary single-location shape must be completely unchanged.
$one = Resolve-WorkdayBullets @('JR78095') 'Seattle, WA'
Check 'single reqid kept'      $one.ReqId                                                 'JR78095'
Check 'single location kept'   $one.Location                                              'Seattle, WA'

# Mixed bullets: take the id, fold the places, drop everything else.
$mix = Resolve-WorkdayBullets @('JR78095','Atlanta, GA | Seattle, WA','Full time','5 Days Ago') 'New York, NY'
Check 'mixed picks the reqid'  $mix.ReqId                                                 'JR78095'
Check 'mixed folds the places' $mix.Location                        'New York, NY | Atlanta, GA | Seattle, WA'
Check 'mixed drops the noise'  ($mix.Location -like '*Full time*')                        $false

# Nothing usable, and no duplication of a location the row already had.
$none = Resolve-WorkdayBullets @() 'Seattle, WA'
Check 'empty bullets no reqid' ([bool]$none.ReqId)                                        $false
Check 'empty bullets keep loc' $none.Location                                             'Seattle, WA'
$dup = Resolve-WorkdayBullets @('Seattle, WA') 'Seattle, WA'
Check 'no duplicated location' $dup.Location                                              'Seattle, WA'
$blank = Resolve-WorkdayBullets @('Puyallup, WA') ''
Check 'blank loc takes bullet' $blank.Location                                            'Puyallup, WA'
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

Write-Host ("`nPASS {0}   FAIL {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
