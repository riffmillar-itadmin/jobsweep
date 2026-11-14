# --------------------------------------------------------------------------
# JobSweep.local.example.psd1 -- a starting point for your own geography
# --------------------------------------------------------------------------
# Copy to JobSweep.local.psd1 and edit. THE REAL FILE IS GITIGNORED AND SHOULD
# STAY THAT WAY: it says where you are willing to travel to and which employers
# you are watching. Both are private, and a published Sources list is a map of
# your job search.
#
# Any key omitted here falls back to the built-in default in the script.

@{

# Where Sweeps\ is written. Optional: omit it and output goes beside the script.
# The folder must already exist. %VAR% references are expanded; -OutputRoot on
# the command line overrides this.
# OutputRoot = '%USERPROFILE%\Documents\JobSweep'

# Hard out, wherever the posting claims to be. Country and region names.
LocationExclude = @(
    'canada','ontario','toronto','vancouver, bc',
    'united kingdom','england','london, uk','ireland','dublin',
    'india','philippines','singapore',
    'australia','mexico','costa rica','colombia','brazil','germany','france',
    'spain','poland','romania','netherlands','israel','japan','china','korea',
    'emea','apac','latam'
)

# Onsite only -- a genuinely remote posting filed under one of these still passes.
# This is your commute boundary. Name the suburbs and satellite cities you will
# NOT travel to; a bare state or metro name in LocationInclude lets everything
# else through.
CommuteExclude = @(
    # NAMESAKES. If your state shares its name with a city elsewhere, a bare state
    # name in LocationInclude lets that city through -- Washington and Washington,
    # DC are the classic pair. Name the namesake HERE rather than in
    # LocationExclude, because a genuinely remote posting filed under it is still
    # a remote posting. Keep the US-xx- form too: several ATS platforms emit
    # location that way. Harmless if your state has no namesake.
    'washington, dc','washington dc','district of columbia','us-dc-',
    # Replace the rest with the suburbs and satellite cities YOU will not travel
    # to. A bare state name in LocationInclude lets every city through unless it
    # is named here -- one large health system can put 1,400 reqs through that gap.
    'springfield','rivertown','north fork','lakeside','fairview',
    'westbrook','eastvale','pineburg','harbor city'
)

# An ONSITE posting must match one of these. Keep it tight: a bare state name
# means any city in that state passes unless CommuteExclude names it.
#
# Worked example: Westmark (WM) is a FICTIONAL state, and every town in this
# file is invented. Replace them all with your own. Harborview is the core
# city; Brookfield and Millbrook are only partly in reach (see WorksiteCheck).
LocationInclude = @(
    'harborview','brookfield','millbrook','westmark','wm,'
)

# ---- WORKSITE CHECK: cities too coarse to decide from (optional) ----
#
# A posting carries a city, never a street address. If part of a city is in
# scope for you and part is not, you cannot screen it -- so FLAG it instead of
# dropping it. Cities named here get "CHECK:" appended to the reason, so the
# posting reaches you with the question attached rather than disappearing.
#
# WorksiteCheckNote is the question you want asked. Leave it blank for a generic
# one. Leave the list empty if your whole metro is either in or out.
WorksiteCheck = @('brookfield','millbrook')
WorksiteCheckNote = 'confirm the worksite is within reach of your usual transit route'

# ---- REGION CHECK: strings that name no city at all (optional) ----
#
# "Greater Harborview Area" is not a city, and no city rule can judge it. Left
# alone it either matches LocationInclude on a substring and passes with no
# flag, or matches nothing and is dropped -- both silently wrong, in opposite
# directions. Phrases listed here are flagged instead, whichever way they lean.
#
# This runs AFTER CommuteExclude (a region naming an excluded city is fairly
# dropped) and BEFORE LocationInclude (so a substring cannot pre-empt it).
RegionCheck = @(
    'greater harborview','harborview metropolitan','harborview metro','harbor bay',
    'eastshore','greater eastshore','harbor county','western westmark',
    'north coast'
)
RegionCheckNote = 'a region was named instead of a city -- confirm which office this role sits at'

# What makes a remote posting's text read as "not in your state after all".
# These are regexes run against the posting body. Replace 'westmark' with the
# state you live in -- this is the clause that hides inside a Remote listing.
RemoteBlock = @(
    'not\s+(?:currently\s+)?(?:able\s+to\s+)?(?:hire|employ|consider)[^.]{0,80}westmark',
    '(?:excluding|except|not\s+available\s+in|unable\s+to\s+hire\s+in)[^.]{0,80}\bwestmark\b',
    'westmark[^.]{0,40}(?:not\s+eligible|are\s+excluded|is\s+excluded)',
    'residents?\s+of[^.]{0,60}westmark[^.]{0,40}(?:not|ineligible)'
)

# ---- PHYSICAL REQUIREMENTS ----
#
# Postings stating a lifting figure ABOVE this are screened out; a figure at or
# below it is treated as the accessibility boilerplate that rides along on plenty
# of ordinary desk jobs. Raise it to switch the screen off in practice, lower it
# to tighten. Unambiguous "physically demanding" language screens out regardless.
LiftingLimitLb = 50

# ---- SECURITY CLEARANCE ----
#
# A QUESTION ONLY YOU CAN ANSWER: will you take a job that needs an active Secret,
# Top Secret or TS/SCI clearance you do not already hold? Contractor and agency
# boards can carry hundreds of these, so decide before your first sweep.
#
#   'drop'  -- screen out postings that REQUIRE one
#   'check' -- keep them, with a CHECK note in the reason (the default)
#   'off'   -- no clearance screening at all
#
# Whatever you choose, a posting that offers a PATH to a clearance ("ability to
# obtain", "must obtain within 90 days") or only prefers one is kept with a CHECK
# note, because that is a door rather than a wall. Public Trust is not covered.
ClearanceScreen = 'check'

# ---- THE EMPLOYER LIST ----
#
# Every entry is one applicant-tracking-system tenant. The Token, Tenant, Cid,
# CcId and BoardId values below are PLACEHOLDERS -- replace them with real ones.
#
# Where to find each:
#   Greenhouse  boards.greenhouse.io/<Token>            -- Token is in the URL
#   Lever       jobs.lever.co/<Token>                   -- Token is in the URL
#   Workday     <Tenant>.<Dc>.myworkdayjobs.com/<Site>  -- all three in the URL
#   iCIMS       careers-<Token>.icims.com               -- Token is in the host
#   UltiPro     <Tenant>.ultipro.com, BoardId is the opportunity GUID
#   ADP         Cid and CcId are query parameters on the careers URL
#   Dayforce    jobs.dayforcehcm.com/en-US/<Namespace>/<Board>/jobs -- both in the URL
#   Rippling    ats.rippling.com/<Board>/jobs           -- Board is in the URL, case and all
#   Paylocity   recruiting.paylocity.com/recruiting/jobs/All/<BoardId> -- the GUID in the board URL
#
# Start with five or six employers you would actually work for, confirm the
# sweep returns their postings, then grow the list.
Sources = @(

    # ---- Greenhouse: boards-api.greenhouse.io/v1/boards/<Token>/jobs?content=true
    @{ Provider='Greenhouse'; Company='Example Biotech';     Token='example-biotech' }
    @{ Provider='Greenhouse'; Company='Example Cloud Co';    Token='example-cloud' }

    # ---- Lever: api.lever.co/v0/postings/<Token>?mode=json
    @{ Provider='Lever';      Company='Example Fintech';     Token='example-fintech' }

    # ---- Workday: <WdHost>/wday/cxs/<Tenant>/<Site>/jobs. WdHost is the tenant host
    #      (https://<tenant>.wdN.myworkdayjobs.com) or the shared https://wdN.myworkdaysite.com
    @{ Provider='Workday';    Company='Example Health';      WdHost='https://examplehealth.wd1.myworkdayjobs.com'; Tenant='examplehealth'; Site='External' }

    # ---- iCIMS: BaseUrl is the careers host -- read the sitemap, the title is in the slug
    @{ Provider='iCIMS';      Company='Example Bank';        BaseUrl='https://careers-examplebank.icims.com' }

    # ---- UltiPro: recruiting.ultipro.com, BoardId is the opportunity GUID
    @{ Provider='UltiPro';    Company='Example Legal';       Tenant='EXA1001EXAMP'
       BoardId='00000000-0000-0000-0000-000000000000' }

    # ---- ADP WorkforceNow: Cid and CcId come off the careers URL
    @{ Provider='ADP';        Company='Example Manufacturing'
       Cid='00000000-0000-0000-0000-000000000000'; CcId='19000101_000001' }

    # ---- Dayforce: jobs.dayforcehcm.com/api/geo/<Namespace>/jobposting/search
    # Board defaults to CANDIDATEPORTAL, the name most employers use.
    @{ Provider='Dayforce';   Company='Example Logistics';   Namespace='examplelogistics'; Board='CANDIDATEPORTAL' }

    # ---- Rippling: api.rippling.com/platform/api/ats/v2/board/<Board>/jobs
    # The slug is case-sensitive; copy it from the careers URL as it appears.
    @{ Provider='Rippling';   Company='Example Robotics';    Board='example-robotics-careers' }

    # ---- Paylocity: the public board page recruiting.paylocity.com/recruiting/jobs/All/<BoardId>
    # A posting URL (/Recruiting/Jobs/Details/<id>) does not name the board; open the
    # employer's careers page or the posting's "view all jobs" link to find it.
    @{ Provider='Paylocity';  Company='Example Clinic';      BoardId='00000000-0000-0000-0000-000000000000' }
)

}
