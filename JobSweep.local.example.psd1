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
    # 'washington, dc' belongs HERE rather than in LocationExclude, because a
    # genuinely remote posting filed under DC is still a remote posting. Keep the
    # US-xx- form too: several ATS platforms emit location that way.
    'washington, dc','washington dc','district of columbia','us-dc-',
    # Replace the rest with the suburbs and satellite cities YOU will not travel
    # to. A bare state name in LocationInclude lets every city through unless it
    # is named here -- one large health system can put 1,400 reqs through that gap.
    'springfield','rivertown','north fork','lakeside','fairview',
    'westbrook','eastvale','pineburg','harbor city'
)

# An ONSITE posting must match one of these. Keep it tight: a bare state name
# means any city in that state passes unless CommuteExclude names it.
# Worked example: a Seattle-area search. A city name here is not sensitive --
# your commute boundary below and your employer list are the private parts.
LocationInclude = @(
    'seattle','bellevue','redmond','washington','wa,'
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
WorksiteCheck = @('bellevue','redmond')
WorksiteCheckNote = 'confirm the worksite is within reach of your usual transit route'

# ---- REGION CHECK: strings that name no city at all (optional) ----
#
# "Greater Seattle Area" is not a city, and no city rule can judge it. Left
# alone it either matches LocationInclude on a substring and passes with no
# flag, or matches nothing and is dropped -- both silently wrong, in opposite
# directions. Phrases listed here are flagged instead, whichever way they lean.
#
# This runs AFTER CommuteExclude (a region naming an excluded city is fairly
# dropped) and BEFORE LocationInclude (so a substring cannot pre-empt it).
RegionCheck = @(
    'greater seattle','seattle metropolitan','seattle metro','puget sound',
    'eastside','greater eastside','king county','western washington',
    'pacific northwest'
)
RegionCheckNote = 'a region was named instead of a city -- confirm which office this role sits at'

# What makes a remote posting's text read as "not in your state after all".
# These are regexes run against the posting body. Replace 'washington' with the
# state you live in -- this is the clause that hides inside a Remote listing.
RemoteBlock = @(
    'not\s+(?:currently\s+)?(?:able\s+to\s+)?(?:hire|employ|consider)[^.]{0,80}washington',
    '(?:excluding|except|not\s+available\s+in|unable\s+to\s+hire\s+in)[^.]{0,80}\bwashington\b',
    'washington[^.]{0,40}(?:not\s+eligible|are\s+excluded|is\s+excluded)',
    'residents?\s+of[^.]{0,60}washington[^.]{0,40}(?:not|ineligible)'
)

# ---- PHYSICAL REQUIREMENTS ----
#
# Postings stating a lifting figure ABOVE this are screened out; a figure at or
# below it is treated as the accessibility boilerplate that rides along on plenty
# of ordinary desk jobs. Raise it to switch the screen off in practice, lower it
# to tighten. Unambiguous "physically demanding" language screens out regardless.
LiftingLimitLb = 50

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
#
# Start with five or six employers you would actually work for, confirm the
# sweep returns their postings, then grow the list.
Sources = @(

    # ---- Greenhouse: boards-api.greenhouse.io/v1/boards/<Token>/jobs?content=true
    @{ Provider='Greenhouse'; Company='Example Biotech';     Token='example-biotech' }
    @{ Provider='Greenhouse'; Company='Example Cloud Co';    Token='example-cloud' }

    # ---- Lever: api.lever.co/v0/postings/<Token>?mode=json
    @{ Provider='Lever';      Company='Example Fintech';     Token='example-fintech' }

    # ---- Workday: <Tenant>.<Dc>.myworkdayjobs.com/wday/cxs/<Tenant>/<Site>/jobs
    @{ Provider='Workday';    Company='Example Health';      Tenant='examplehealth'; Dc='wd1'; Site='External' }

    # ---- iCIMS: careers-<Token>.icims.com -- read the sitemap, the title is in the slug
    @{ Provider='iCIMS';      Company='Example Bank';        Token='examplebank' }

    # ---- UltiPro: recruiting.ultipro.com, BoardId is the opportunity GUID
    @{ Provider='UltiPro';    Company='Example Legal';       Tenant='EXA1001EXAMP'
       BoardId='00000000-0000-0000-0000-000000000000' }

    # ---- ADP WorkforceNow: Cid and CcId come off the careers URL
    @{ Provider='ADP';        Company='Example Manufacturing'
       Cid='00000000-0000-0000-0000-000000000000'; CcId='19000101_000001' }
)

}
