# --------------------------------------------------------------------------
# JobSweep.targeting.example.psd1 -- a starting point for your own search
# --------------------------------------------------------------------------
# Copy to JobSweep.targeting.psd1 and edit. This file describes WHAT COUNTS AS
# A JOB WORTH LOOKING AT -- title screening only, no geography and no employers.
#
# PRECEDENCE, and the order matters: TitleProtect wins outright, then
# TitleExclude, then TitleInclude. A title caught by TitleProtect survives even
# if TitleExclude would have killed it.
#
# Matching is case-insensitive regex against the posting title, so 'licens'
# matches "licensing" and "licensed" alike -- which is exactly the kind of
# over-match that costs real leads. Anchor a stem when you mean one sense of it.
#
# Any key omitted here falls back to the built-in default in the script.

@{

# A posting must match one of these to survive.
TitleInclude = @(
    # Endpoint and client platform
    'endpoint','desktop','client system','deskside','device management',
    'intune','sccm','mecm','configuration manager','autopilot',
    # Systems and infrastructure
    'systems administrator','system administrator','sysadmin',
    'systems engineer','infrastructure engineer','platform engineer',
    # Identity and cloud
    # ANCHOR STEMS THAT ARE ALSO SUBSTRINGS. Bare 'entra' matched "CENTRAl
    # Kitchen" and bare 'iam' matches "Williams" -- both cost real screening time.
    'identity','\biam\b','\bentra\b','active directory','microsoft 365','\bm365\b','azure',
    # Support tiers
    'support engineer','support analyst','technical support','service desk',
    # Asset and licensing -- anchored so it does not match clinical "licensed" titles
    'software asset','asset manag',
    'licens\w*\s+(analyst|specialist|manager|administrat|complian|coordinat)'
)

# Survives TitleExclude. Use this for the titles your exclusions would otherwise
# eat -- here, the asset and licensing family, which carries 'manager' legitimately.
TitleProtect = @(
    'asset manag','\bitam\b','software licens','configuration manager'
)

# Any match here excludes the posting outright, unless TitleProtect caught it first.
TitleExclude = @(
    # Software development -- a systems title over an engineering job
    'software engineer','software development engineer','\bsde\b','developer',
    'data scientist','machine learning','research scientist',
    # Test and QA
    'quality assurance','\bqa\b','\bsdet\b','test engineer','tester','test analyst',
    # People management and seniority above an individual contributor
    'supervisor','manager,','\bmanager\b','director','head of','vp,','vice president',
    'principal','distinguished','fellow',
    # Entry level
    'intern\b','internship','apprentice',
    # Other functions entirely
    'sales','account executive','account manager','recruiter','marketing',
    # Clinical -- health systems post these in volume and they match on 'support'
    'nurse','clinician','therapist','phlebotom','peer support'
)

}
