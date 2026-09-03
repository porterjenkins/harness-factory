# shellcheck shell=bash
# Persona: the fictional owner of a generated sandbox vault.
#
# This file is the ONLY place a sandbox's identity is defined. Nothing downstream
# -- not the scaffolder, not a prompt, not CLAUDE.md, not USER.md -- contains a
# real name, employer, project or path. Swap this file and you get a completely
# different vault with the same structure, which is what makes the environment
# useful for testing personalisation.
#
# Every record below is pipe-delimited. Copy this file to make a new persona.

PERSONA_ID="maya"
PERSONA_NAME="Maya Okonkwo"
PERSONA_PRONOUNS="they/them"
PERSONA_EMAIL="maya@northbeam.io"
PERSONA_VAULT="maya-work"          # vault folder basename; obsidian CLI keys off it
PERSONA_LOCATION="Portland, OR"
PERSONA_TZ="America/Los_Angeles"
PERSONA_TZ_OFFSET="-07:00"

PERSONA_HEADLINE="VP of Engineering at Northbeam Logistics; adjunct lecturer; runs a small ML advisory practice on the side"

# Free-text brief. The only input to USER.md, so put anything the skills under
# test should be able to personalise on here -- and nothing they should not.
PERSONA_SEED="Maya Okonkwo is VP of Engineering at Northbeam Logistics, a
mid-sized freight-visibility company (about 190 people, Series C). They own
platform, data and the four-person ML team. Before Northbeam they spent six years
at a payments company building fraud models, and they hold a master's in
operations research from Georgia Tech.

Outside Northbeam: an adjunct lecturer for one graduate course a year at Portland
State (Applied Forecasting), a co-founder stake in Tidewater Analytics -- a
two-person consultancy doing demand forecasting for regional grocers -- and an
advisory seat at a seed-stage warehouse-robotics company called Palletgeist.

How they work: writes decision memos rather than slide decks, deeply suspicious
of dashboards nobody reads, keeps a running log of architectural decisions. Blunt
in writing, allergic to status theatre. Runs a Sunday-evening weekly planning
session and a short daily triage every weekday morning. Cares most about whether
a forecast is calibrated, not whether it is accurate on average.

Family: partner Devi, two kids in elementary school. Volunteers as a Little
League coach in the spring, which reliably collides with quarter-end."

# Tag roots the auto-tagger should converge on for this vault.
PERSONA_TAG_ROOTS="northbeam, northbeam/atlas, northbeam/ml, northbeam/platform, tidewater, psu, palletgeist, forecasting, hiring, planning"

# Projects -- active work with an outcome and an end.
#   path (under Projects/) | kind | one-line description
PERSONA_PROJECTS=(
  "Northbeam/Atlas|migration|Replatforming the shipment-tracking pipeline off the legacy Kafka+Redshift stack onto a streaming lakehouse. The company's biggest engineering bet this year."
  "Northbeam/ML|team|The four-person ML team: ETA prediction models, calibration work, on-call for model regressions, and the quarterly roadmap."
  "Northbeam/Platform|product|Core platform and API surface -- tenancy, rate limits, the partner integration program, and the SOC 2 Type II audit."
  "Northbeam/Hiring|hiring|Open reqs, interview loop design, and the staff-engineer leveling rubric."
  "Tidewater|consulting|Two-person demand-forecasting consultancy. Current engagements: Alderwood Grocers and a scoping call with Cascade Foods."
  "PSU/Applied Forecasting|teaching|Graduate course taught each spring. Syllabus, assignments, and guest lecturers."
  "Palletgeist|advisory|Seed-stage warehouse robotics. Advisory seat; quarterly technical review and fundraising diligence support."
)

# Areas -- ongoing responsibility, no finish line.
#   name (under Areas/) | description
PERSONA_AREAS=(
  "Engineering Management|Standing responsibilities as a VP: 1:1 cadence, performance cycles, org design, budget, on-call health."
  "Family|Household logistics, kids' school calendar, Little League coaching, trip planning."
  "Health|Marathon training block, sleep, and the standing PT routine for a bad left knee."
)

# Resources -- reference material consulted across projects.
#   title | description
PERSONA_RESOURCES=(
  "Forecast Calibration Notes|Working reference on calibration for count and interval forecasts: reliability diagrams, CRPS, pinball loss, and when each one misleads."
  "Streaming Lakehouse Reference|Comparative notes on table formats, exactly-once semantics, and small-file compaction. Consulted by both Atlas and Tidewater work."
  "Interview Loop Playbook|The standard interview loop: stages, rubrics, calibration process, and the debrief script."
  "Decision Memo Template Notes|How to write a decision memo that survives contact with a skeptical staff engineer."
  "Vendor Evaluation Criteria|Reusable scoring rubric for data-infrastructure vendors, with the weightings actually used in past evaluations."
  "SOC 2 Evidence Map|Which control maps to which system of record, and who owns collecting the evidence."
)

# Recurring meetings. Feed the simulated Meetings/ folder.
#   title | cadence | attendees (comma-separated)
PERSONA_MEETINGS=(
  "Atlas Architecture Review|weekly|Maya Okonkwo, Devon Ruiz, Priya Anand, Tomas Lindqvist"
  "ML Team Sync|weekly|Maya Okonkwo, Priya Anand, Hana Sato, Wes Boateng"
  "Northbeam Leadership Staff|weekly|Maya Okonkwo, Ines Carvalho, Gordon Yeats, Renata Silva"
  "Platform + Partner Integrations|biweekly|Maya Okonkwo, Tomas Lindqvist, Renata Silva"
  "SOC 2 Audit Checkpoint|biweekly|Maya Okonkwo, Gordon Yeats, Louise Mbeki"
  "Alderwood Grocers Forecasting Sync|weekly|Maya Okonkwo, Jonah Petrov, Claire Aduba"
  "Palletgeist Technical Review|monthly|Maya Okonkwo, Sasha Kim, Ben Oyelaran"
  "Hiring Loop Calibration|biweekly|Maya Okonkwo, Ines Carvalho, Devon Ruiz"
  "Cascade Foods Scoping Call|once|Maya Okonkwo, Jonah Petrov, Marisol Vega"
  "1:1 with Priya|weekly|Maya Okonkwo, Priya Anand"
)

# People the notes may mention. Keeps names consistent across generated docs.
#   name | role
PERSONA_PEOPLE=(
  "Devon Ruiz|Principal engineer, Atlas tech lead"
  "Priya Anand|ML engineering manager, reports to Maya"
  "Hana Sato|Senior ML engineer, calibration and evaluation"
  "Wes Boateng|ML engineer, ETA models"
  "Tomas Lindqvist|Staff engineer, platform and API"
  "Ines Carvalho|VP People"
  "Gordon Yeats|CFO, owns the SOC 2 budget"
  "Renata Silva|Director of Partnerships"
  "Louise Mbeki|External SOC 2 auditor"
  "Jonah Petrov|Tidewater co-founder"
  "Claire Aduba|Alderwood Grocers, VP Supply Chain"
  "Marisol Vega|Cascade Foods, Director of Planning"
  "Sasha Kim|Palletgeist CTO"
  "Ben Oyelaran|Palletgeist CEO"
  "Devi Okonkwo|Maya's partner"
)

# Shorthand the assistant is expected to resolve.
#   term | expansion
PERSONA_SHORTHAND=(
  "Atlas|the shipment-pipeline replatform at Northbeam"
  "NB|Northbeam Logistics"
  "TW|Tidewater Analytics"
  "PG|Palletgeist"
  "AF|Applied Forecasting, the PSU graduate course"
)

# Connected sources, written into .system/sources.md.
#   role | source | notes
PERSONA_SOURCES=(
  "vault|local filesystem|this vault; always available"
  "meetings|Resources/Meetings/|simulated exports; no live connector in a sandbox"
  "calendar|none|not connected in the sandbox"
  "chat|none|not connected in the sandbox"
  "issues|none|not connected in the sandbox"
  "second-vault|none|not connected in the sandbox"
)
