# JobSweep

A PowerShell job-board sweep. It polls applicant-tracking-system APIs across a
list of employers, screens the results against your own title and geography
rules, and writes a candidate list — so the reading you do each morning is a
dozen postings worth judging rather than four hundred worth skimming.

It is a screening tool, not a matching tool. **Every rule is designed to hand a
borderline posting to a human rather than bin it**, because the failure that
costs you a job is the one that looks like a quiet week.

## Why the filters are shaped the way they are

Every silent-screening bug this project has had looked identical from the
outside: *nothing was posted this week.* None of them threw an error.

- `\bmanager\b` in the exclude list killed **Software Asset Manager** — a
  target title — so `TitleProtect` now wins outright over `TitleExclude`.
- A bare `entra` matched **CENTRAl Kitchen**; a bare `iam` matches **Williams**.
  Stems that are also substrings are anchored with `\b`.
- A bare `licens` matched five clinical reqs — *Licensed Child, Youth & Family
  Therapist* — so it is anchored to the software sense.
- `washington` in the include list passed **Washington, DC**, which is why DC
  is a *commute* exclusion rather than a country one.
- A malformed location field, the literal string `US-`, fell past every check
  to "location out of scope" and dropped the best lead of that week.

**A green exit code says the plumbing worked, not that the filter is right.**
That is what the test suite is for.

## Layout

| File | Ships | What it is |
|---|---|---|
| `Invoke-JobSweep.ps1` | ✅ | The collector. Providers, paging, retry, screening, output. |
| `JobSweep.targeting.psd1` | ✅ | **What counts as a job worth looking at.** Title rules only — this describes a search, not a person. |
| `JobSweep.local.psd1` | ⛔ **gitignored** | **Where you will go and who you are watching.** Geography, commute boundary, remote rules, and the employer list. |
| `JobSweep.targeting.example.psd1` | ✅ | A simpler starting point if you are retargeting the sweep. |
| `JobSweep.local.example.psd1` | ✅ | A worked geography with placeholder employers. Copy it. |
| `Test-JobSweepFilters.ps1` | ✅ | The regression suite. 236 cases, no network. |

`JobSweep.local.psd1` is the file that must never be published. It is first in
`.gitignore` for that reason. Before making a repository public, read
`git status` and the full diff and confirm it is **absent from the commit**,
not merely present-and-ignored.

## Getting started

```powershell
git clone git@github.com:<you>/jobsweep.git
cd jobsweep

# 1. The suite runs green immediately, against the shipped example geography.
.\Test-JobSweepFilters.ps1

# 2. Make your own geography and employer list.
Copy-Item JobSweep.local.example.psd1 JobSweep.local.psd1
#    ...edit it: LocationInclude, CommuteExclude, and real ATS tokens in Sources.

# 3. Point the suite at your profile to see what your own rules do.
.\Test-JobSweepFilters.ps1 -ProfilePath @('.\JobSweep.targeting.psd1', '.\JobSweep.local.psd1')

# 4. Sweep.
.\Invoke-JobSweep.ps1
```

The collector defaults to the two real profile files beside it and **throws if
either is missing**, by design — a profile that fails to load leaves the title
list empty, matches nothing, and reports a normal-looking quiet day.

## How screening works

**Titles**, in this precedence and the order matters:

1. `TitleProtect` — wins outright. Use it for titles your exclusions would
   otherwise eat.
2. `TitleExclude` — excludes the posting.
3. `TitleInclude` — a posting must match one of these to survive.

**Locations**: a posting reading as remote is screened against `LocationExclude`
and the `RemoteBlock` patterns, which catch the *"we cannot hire in your state"*
clause buried in an otherwise-remote listing. An onsite posting must match
`LocationInclude` and must not match `CommuteExclude`.

Two escape hatches handle geography a city rule cannot settle, and both **flag**
with `CHECK:` rather than deciding. `WorksiteCheck` covers a city that is only
partly in scope: a posting carries a city and never a street address, so when
half a city is reachable and half is not, the question travels with the posting
instead of the posting disappearing. `RegionCheck` covers a string that names no
city at all — *"Greater Seattle Area"*, *"Puget Sound"*. Left alone those either
match `LocationInclude` on a substring and pass unflagged, or match nothing and
are dropped; either way the screening is silently wrong, so they are flagged in
both directions.

## Supported providers

Greenhouse, Lever, Workday, iCIMS, UltiPro, ADP WorkforceNow, and the Microsoft
careers API. `JobSweep.local.example.psd1` documents where to find the token,
tenant or board ID for each.

## Profiles

Profiles are **replace-by-key, not deep-merged**: a key present in a profile
replaces the built-in default wholesale, so a list can be shortened as well as
extended. Files apply in order, so a later one wins. They are read with
`Import-PowerShellDataFile`, which parses data and will not execute code — which
is the point.

The merge fails loudly if `TitleInclude`, `TitleExclude`, `LocationInclude` or
`Sources` ends up missing or empty.

## Tests

```powershell
.\Test-JobSweepFilters.ps1
```

No network, no state, no output files. It pulls the config block and the pure
`Test-*` / `Get-*` functions out of `Invoke-JobSweep.ps1` with the PowerShell
AST, so it tests the real filter rather than a copy that can drift. Run it
after any change to the title, location or remote lists.

## Requirements

Windows PowerShell 5.1 or PowerShell 7. No modules.

## Changelog

- **1.1.0** (2026-10-20): default `-OutputRoot` is now
  `%USERPROFILE%\OneDrive\Employment\Claude workspace`.
- **1.0.0**: initial release.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
