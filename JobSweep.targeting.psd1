# --------------------------------------------------------------------------
# JobSweep.targeting.psd1 -- what counts as a job worth looking at
# --------------------------------------------------------------------------
# Title screening only. TitleProtect wins outright, then TitleExclude, then
# TitleInclude -- the order matters and has cost real leads when changed.
#
# Shipped deliberately: these lists describe an IT operations and endpoint
# search, not a person. Edit them to retarget the sweep.
#
# Any key omitted here falls back to the built-in default in the script.

@{

TitleInclude = @(
    'endpoint','desktop','client system','client engineer','deskside',
    'systems administrator','system administrator','sysadmin',
    'application support','app support','production support',
    'service desk','help desk','helpdesk','support engineer','support technician',
    'support analyst','support specialist','technical support',
    'software asset','asset manag','software licensing',
    # 'licens' was BARE here until 2026-09-10 and matched five clinical
    # clinical reqs -- "Licensed Child, Youth & Family Therapist", "Mental Health
    # Professional Licensed". Anchored to the software sense instead. Both
    # "IT Contracts & Licensing Specialist III" and "Customer Licensing
    # Alignment Manager" still match on 'licensing'.
    'licensing','licens\w*\s+(analyst|specialist|manager|administrat|complian|coordinat)',
    '\bit audit','information systems audit','\bit auditor',   # \b added 2026-10-06, see above
    'compliance analyst','controls analyst','\bgrc\b',
    'business systems','systems analyst','systems engineer',
    'intune','sccm','mecm','configuration manager','device management',
    'identity','\biam\b','\bentra\b','active directory',   # anchored: 'entra' matched "CENTRAl Kitchen", 'iam' would match "Williams"
    # 2026-10-06: all seven patterns beginning "it " are anchored with \b. Unanchored
    # they matched INSIDE a longer word: it analyst kept a bank's Senior Credit
    # Analyst, it operations takes Credit Operations, it audit takes Credit Audit.
    # Same fix already carried by entra and iam two lines below. Replayed across
    # 2,080 distinct titles from nine screened runs: ONE row changes, the bad one.
    '\bit operations','\bit specialist','\bit administrator','\bit analyst','\bit engineer',
    # Added 2026-09-19 after the screened-list audit of sweep-2026-09-18-1923 found
    # the sweep had collected and then DISCARDED all three reqs that were acted on
    # that week. 'it administrator' is a literal substring and does NOT match
    # "IT Infrastructure Administrator", one of the three. 'platform engineer'
    # recovers "Cloud Platform Engineer - Azure", another. Measured cost against
    # that run: FOUR extra rows out of 195, two of them the reqs above.
    'infrastructure','platform engineer','cloud engineer','solutions architect',
    'workplace engineer','\beuc\b','end user computing','end-user computing',
    # Added 2026-09-24. The Microsoft provider QUERIES the careers API for
    # 'service engineer' (see the Sources block) and TitleInclude then discarded
    # every result -- Microsoft's Service Engineering discipline had no target
    # keyword at all. Proved on sweep-2026-09-23-0920, which collected and then
    # dropped "Platform Service Engineer [Service Engineering]" in Redmond -- a real
    # posting that then had to be found and read by hand. Same
    # failure shape as the 2026-09-19 additions: collected, then thrown away.
    # Measured over five runs (2026-09-18 to -24; 1022 screened rows, 397 of them
    # dropped for no target keyword) the five patterns below cost +6 rows, 0.6%:
    #   'service engineer'  +1  the Platform Service Engineer above
    #   'site reliability'  +1  Senior Site Reliability Engineer, Redmond
    #   'cloud operations'  +0  names the CO+I org; free insurance
    #   '\bsre\b'           +0  free insurance
    # 'data\s?cent' was added here the same day and REMOVED again hours later. It
    # measured +4 rows, all four noise, and its only justification was a recall bet
    # on bare-metal datacenter depth. That bet is retired, because datacenter-floor
    # roles are gated out by the physical-demand screen regardless of technical fit.
    # If that screen is not relevant to your search, raise LiftingLimitLb in your
    # local profile and consider adding 'data\s?cent' back here.
    'service engineer','site reliability','\bsre\b','cloud operations',
    # legal technology, added 2026-09-09
    'information governance','ediscovery','e-discovery','litigation support',
    'records manag','information lifecycle','legal hold'
)

# Checked BEFORE TitleExclude, and wins. Without this the \bmanager\b exclusion
# silently kills a target title -- Software Asset Manager -- along with
# IT Asset Manager and any licensing manager req. Added 2026-09-10 after the first
# full sweep showed the exclusion firing on manager titles indiscriminately.
TitleProtect = @(
    'asset manager','manager[, ].*asset','licens.*manager','manager.*licens',
    'configuration manager',
    # Added 2026-09-10. Found by test, not by a lost lead: "ITAM Governance
    # Manager" and "Hardware Asset Management Technical Developer" -- both real
    # titles in the target family -- were dying on \bmanager\b
    # and 'developer' in TitleExclude. Any title carrying ITAM, asset management
    # or software licensing survives to human judgement.
    '\bitam\b','asset manag','software licens'
)

# Any match here excludes the posting outright, unless TitleProtect caught it first.
TitleExclude = @(
    'quality assurance','\bqa\b','\bsdet\b','test engineer','tester','test analyst',
    'automation test','\bqe\b',
    'supervisor','manager,','\bmanager\b','director','head of','vp,','vice president',
    'intern\b','internship','apprentice',
    'software engineer','software development engineer','\bsde\b','developer',
    'data scientist','machine learning','research scientist','physicist',
    'sales','account executive','account manager','recruiter','marketing',
    'nurse','clinician','technologist i','phlebotom',
    # Clinical and behavioural-health titles, added 2026-09-10. One health-system
    # tenant alone carries 1,454 open reqs, so these arrive in volume and are never
    # an IT-operations lane. 'peer support' also kills "Certified Peer Support
    # Specialist", which was matching on 'support specialist'.
    'therapist','mental health','counselor','counsellor','social worker',
    'peer support','psychiatr','chaplain','pharmac','radiolog','sonograph',
    'respiratory','physician','surgical','caregiver','medical assistant',
    # Defense operations research -- Bluehawk's three ORSA reqs matched
    # 'systems analyst' and are a different profession entirely.
    'operations research',
    # Legal, added 2026-09-21. The 'infrastructure' keyword added two days
    # earlier produced its first false positive on its first live run:
    # Anthropic's "Compute & Infrastructure Counsel, Real Estate" is a lawyer.
    '\bcounsel\b','counsel,','attorney','paralegal',
    # LEVEL, added 2026-10-01. "Principal Hardware Systems Engineer" reached the
    # candidate list on 'systems engineer' and had to be declined by hand -- the
    # third Principal req to do so.
    # ADJUST THIS TO YOUR OWN LEVEL. These three words exclude the tiers above a
    # senior individual contributor; delete them if Principal is your target.
    # CAUTION: some employers use "Principal" as an HR naming convention rather
    # than a seniority grade, so a title alone does not settle what a req wants.
    '\bprincipal\b','\bdistinguished\b','\bfellow\b',
    # HARDWARE, added 2026-10-01, from the same req. Hardware engineering means
    # bench and rack work, which the physical-demand gates rule out independently,
    # so it is a decline twice over and belongs at the cheap title-level screen
    # rather than after a detail fetch. Scoped to the ENGINEERING senses only --
    # 'hardware asset management' is in TitleProtect and is a target title.
    'hardware engineer','hardware systems engineer','hardware design','firmware engineer'
)

# ---- LOCATION, restructured 2026-09-10 when national remote came back in scope.
#
# Three lists now, checked in this order by Test-LocationMatch:
#
#   LocationExclude   always disqualifies, remote or not. Outside the US.
#   CommuteExclude    disqualifies an ONSITE posting only. These are the
#                     Washington suburbs and the other-Washington traps; a
#                     genuinely remote req in Renton is a remote req, so the
#                     commute list must not touch it.
#   LocationInclude   an onsite posting must match one of these.
#
# A posting whose location says remote skips CommuteExclude and LocationInclude
# entirely. Test-RemoteFlags then does the real screening on the posting text.


}
