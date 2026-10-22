# Build a job tracking board from your sweeps

A prompt for Claude. It reads the `sweep-*-candidates.json` files that
`Invoke-JobSweep.ps1` writes, judges every posting against **your** criteria,
and builds a board you use to track applications.

**How to use it**

1. Fill in **Part 1** below. Leave a line blank to skip it.
2. Give Claude this file and your `Sweeps\` folder:
   - **Claude Code** (or any Claude with file access): run it from the folder
     that holds `Sweeps\`, or say where that folder is.
   - **claude.ai or the Claude app**: attach this file and the
     `sweep-*-candidates.json` files you want on the board.
3. After the next sweep, run it again. New postings are added; nothing you
   have already moved is touched.

Use the `.json` files, not the `.csv`. Only the `.json` carries the full
posting text, and a title alone is the least reliable thing to judge a job by.

---

## Part 1 — Your criteria (fill this in)

```yaml
# Where the board lives: ask | local | artifact
#   ask      -> Claude walks you through the decision tree in Part 2
board_location: ask

# A posting missing ANY of these scores 0 and is flagged, not hidden.
must_haves:
  - "<a skill, duty or condition the role must have>"
  -

# Each one present raises the score.
nice_to_haves:
  - "<something that makes a role more attractive>"
  -

# Any one of these puts the card straight into Passed, with the reason quoted.
deal_breakers:
  - "<something that rules a role out>"
  -

# Annual equivalent, in your currency. Leave blank for no floor.
# Postings with no pay stated still show.
minimum_pay:

# Hours in a working year, used to turn an hourly rate into an annual one.
#   2080  40 h x 52 weeks. Every week paid, as for a salaried or permanent
#         role with paid leave and holidays. Most employers and pay scales
#         convert this way, so hourly and salaried bands compare like-for-like.
#   2000  40 h x 50 weeks. Allows for about two weeks you are NOT paid, as for
#         contract or temp work with no paid leave. More honest for those
#         roles, and easy arithmetic: $50/hr is roughly $100,000.
# The higher the number, the better hourly roles look against salaried ones.
annual_hours: 2080

# remote | hybrid | onsite -- keep every arrangement you would accept.
work_arrangement: [remote, hybrid, onsite]

companies_to_prioritise: []
companies_to_skip: []

# How the 0-100 score splits. A posting with every must-have starts at this
# baseline; the nice-to-haves share the rest (100 - baseline) evenly.
#   60 (the default) keeps must-haves dominant -- a role you could do outranks
#   one that merely sounds good -- while 40 points still separate a bare match
#   from a strong one. Lower it if your nice-to-haves are what really decide
#   between roles; raise it if they are minor. Before changing it, ask your
#   AI to score a few of your recent postings both ways and compare.
score_baseline: 60

# Score at or above which "Strong match" is shown on the card (0-100).
strong_match_threshold: 70

# Extra filter buttons, in plain English: "Label: rule".
custom_filters:
  - "<Label>: <which postings it should match>"
```

---

## Part 2 — Where the board lives

If `board_location` is `local` or `artifact`, use that and skip this part.
If it is `ask`, put these questions to the user one at a time and follow the
answers:

```
Q1. Are you running this in Claude Code, or another tool that can write
    files to your computer?
    ├─ Yes ──> Q2
    └─ No (claude.ai or the Claude app) ──> Q3

Q2. Do you want the board to keep working without Claude --
    open it from a folder, any time, offline?
    ├─ Yes ──> LOCAL
    └─ No  ──> Q3

Q3. Do you need to see the board on more than one device, or share it?
    ├─ Yes ──> ARTIFACT (with saved state, if the artifact supports it)
    └─ No  ──> ARTIFACT if you are in claude.ai; otherwise LOCAL
```

**LOCAL** — write a single self-contained `job-board.html` beside the
`Sweeps\` folder (not inside it). No external requests except an optional
font. Card state is kept in the browser's `localStorage`, with **Export** and
**Import** buttons that save and load the state as a `.json` file, because
browser storage is per-browser and can be cleared.

**ARTIFACT** — publish the board as a claude.ai artifact. If the artifact
can save state that persists, use that for card state. If not, fall back to
`localStorage` with the same Export and Import buttons.

Either way, the posting data (everything from the sweep files) is embedded in
the page. Only the user's own changes -- stage, notes, dates and card edits --
are state.

---

## Part 3 — Instructions for Claude

### Reading the sweeps

- Read every `sweep-<date>-candidates.json`. Each holds an array of postings
  with `Company`, `Title`, `Location`, `Remote`, `Pay`, `Degree`,
  `NeedsLicence`, `Posted`, `ReqId`, `Source`, `Url`, `Reason` and `Content`
  (the full posting text).
- A card's identity is **`Source` + `ReqId`**. The sweep never reports the
  same requisition twice, but if two files contain one, keep the earlier.
- **Date added** is the `<date>` in the file name the posting came from.
- When the board already exists, read its current state first (the embedded
  data, or an Export file the user supplies) and only **add** cards that are
  not on it. Never move, re-score or delete an existing card, and never
  replace a user's edit.

### Judging each posting

Read `Content`, not just the title. For every posting record:

- **Score** 0-100. All must-haves present is `score_baseline` (default 60);
  each nice-to-have raises it, spread evenly over the remaining points. A
  missing must-have scores 0.
- **Reasons**: one line per criterion that decided the score, each quoting
  the posting text it relied on. No quote, no claim.
- **Needs review**: set it when the text is ambiguous, contradicts the sweep's
  `Remote` flag, or a must-have can only be guessed at. Say what is unclear.
  Never guess to avoid setting it.
- **Deal-breaker found**: create the card in **Passed**, with the quote as
  its note. It stays visible there, so a wrong call can be moved back.

### Pay, normalised for sorting

`Pay` is raw text copied from the posting, for example `$78,000 – $180,000 per
year`, `$34.35 - $46.20 per hour`, `$60-70/hr`, or `$8,960-$12,120` -- a
monthly band whose unit was not captured. Convert every value to one
**annual-equivalent number** for sorting and for the `minimum_pay` check, and
show the original text on the card unchanged.

Normalise both ends of a range; a single figure is both ends.

- **Find the unit first.** The sweep only captures hourly and yearly units,
  so when `Pay` has none, look for the same figures in `Content` and read the
  unit stated beside them ("per month", "weekly", "daily rate"). A unit found
  there counts as stated.
- **Stated unit:** convert with these, so the `annual_hours` choice carries
  through every unit (2080 gives 52 weeks or 260 days; 2000 gives 50 or 250):

  | Unit | Wording | Annual equivalent |
  |---|---|---|
  | hourly | `/hr`, `per hour`, `hourly`, `an hour` | × `annual_hours` |
  | daily | `per day`, `daily`, `day rate`, `/day` | × (`annual_hours` ÷ 8) |
  | weekly | `per week`, `weekly`, `/wk` | × (`annual_hours` ÷ 40) |
  | monthly | `per month`, `monthly`, `/mo` | × 12 |
  | yearly | `per year`, `annually`, `/yr`, `salary` | as stated |

- **No unit anywhere:** infer it from the size of the figures, in the
  posting's currency. Public-sector postings often state monthly bands, so
  this case is common:
  - both figures under 200: **hourly**, × `annual_hours`
  - both from 2,000 to 25,000: **monthly**, × 12
  - both 25,000 or more: **yearly**, as stated
- **Show the assumption:** an inferred unit is labelled on the card beside
  the original text, e.g. `$8,960-$12,120 (assumed monthly)`, so the user can
  see it was not stated.
- **Cannot place it:** unitless figures between 200 and 2,000, or two figures
  that land in different bands, are **unknown**: no annual equivalent, and the
  card is marked **Needs review** saying why. That gap is deliberate -- weekly
  pay and day rates live there, and guessing between them is a factor of five.

### Stages

The progress track, in order:

**New → Applied → Shortlisted → Interviewing → Offer**

- Every card starts in **New** (unless a deal-breaker sent it to Passed).
- Moving a card to **Applied** records **Date applied** as today. The user can
  edit it. Moving a card back before Applied keeps the date unless the user
  clears it.
- Cards move by drag and drop and by a stage menu on the card, so the board
  works with a keyboard and on a phone.

### Ended: Passed, Rejected, Closed

A second, separate track of three columns sits below the progress track.
These are where a card goes when it **stops progressing**, from any stage:

| Column | Meaning | Who decided |
|---|---|---|
| **Passed** | You chose not to pursue it, or withdrew | you |
| **Rejected** | The employer said no | the employer |
| **Closed** | The posting closed, was filled or expired | nobody -- it ended |

- A card moved into the Ended track **remembers the stage it left**, and shows
  it: *Passed — from New*, *Rejected — from Interviewing*. That is the useful
  history: how far each application got.
- **Move back** returns a card to the stage it left, not to New.
- Moving into Ended offers an optional note (why you passed, what the
  rejection said).
- The Ended track is collapsible and collapsed by default, with a count of
  cards in each column visible even when collapsed.

### Editing a card

Every card is **locked by default**. Moving it between stages and writing
Notes work while it is locked; changing what Claude judged does not.

- An **Edit** button on the card unlocks it. **Save** applies the changes and
  locks it again; **Cancel** discards them.
- Editable when unlocked -- the fields Claude decided, which are the ones it
  can get wrong:
  - pay: the unit and the annual equivalent (low and high)
  - work arrangement: remote, hybrid or onsite
  - degree required, licence required
  - score
  - each custom-filter match
  - **Needs review**: clear it once you have checked the card
- Not editable: company, title, location, link and posting text. They are
  what the employer published, and the reasons quote them.
- An edit is stored as the user's **override**, never by changing the
  embedded data. An edited field shows a small *edited* mark, and each one
  has **Revert** to restore Claude's value.
- Sorting and filtering use the override when there is one.
- A card marked **Needs review** shows an **Edit to review** prompt beside the
  badge, so the way to resolve it is obvious.

### Sorting

One sort control applies within every column:

| Sort | Order | Cards without the value |
|---|---|---|
| **Date added** (default) | newest first | — |
| **Pay** | highest annual equivalent first; a range sorts by its top | last |
| **Date applied** | most recent first | last |
| **Score** | highest first | — |
| **Company** | A–Z | — |

Ties fall back to Date added, newest first. The chosen sort is remembered.

### Filters

A row of toggle buttons above the board. Active buttons combine with AND,
the count of matching cards shows on the board, and the choice is remembered.

Default set:

- **Remote** — the sweep's `Remote` flag, or the posting says so
- **Pay stated**
- **Meets minimum pay** — hidden when `minimum_pay` is blank. A range meets
  it when its top does. Unknown pay never meets the minimum, but still shows
  when the filter is off.
- **Strong match** — score at or above `strong_match_threshold`
- **Needs review**
- **No degree required**
- **Show ended** — off by default; when on, the Ended track opens

Then one button per `custom_filters` entry. Decide each card's match when
you build the board, from the posting text, and store it with the card -- the
page does not re-judge. Also add a text search over company, title and
location.

The user can hide any default button they do not use; hidden buttons are
remembered and listed under a **More filters** menu so they can come back.

### Each card shows

Company · title · location · original pay text · score, with *Strong match*
or *Needs review* badges · date added · date applied (once set) · a link to
the posting · a **Details** toggle with the reasons and the posting text ·
a free-text **Notes** field that is saved · an **Edit** button.

### Finish

Tell the user where the board is, how many cards were added and how many are
flagged Needs review, and remind them that LOCAL state lives in one browser
until they Export it.
