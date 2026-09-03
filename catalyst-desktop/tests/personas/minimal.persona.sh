# shellcheck shell=bash
# Persona: deliberately small. Two projects, one area, one recurring meeting.
#
# For smoke tests and CI, where the question is "does the harness still produce a
# structurally valid vault?" rather than "does retrieval rank sensibly across a
# realistic corpus?". A full spin-up at --size small runs in well under a minute.

PERSONA_ID="wren"
PERSONA_NAME="Wren Halloway"
PERSONA_PRONOUNS="they/them"
PERSONA_EMAIL="wren@fieldnote.dev"
PERSONA_VAULT="wren-notes"
PERSONA_LOCATION="Asheville, NC"
PERSONA_TZ="America/New_York"
PERSONA_TZ_OFFSET="-04:00"

PERSONA_HEADLINE="Solo developer building Fieldnote, a note-taking app for field biologists"

PERSONA_SEED="Wren Halloway is a solo developer. They are building Fieldnote, an
offline-first note-taking app for field biologists, and take one contract at a
time to fund it -- currently a data-cleanup engagement for a watershed nonprofit.
Former GIS analyst. Works in long uninterrupted blocks, plans weekly on Sunday,
and keeps a short daily list. Deeply reluctant to add features."

PERSONA_TAG_ROOTS="fieldnote, fieldnote/sync, contracts, watershed, planning"

PERSONA_PROJECTS=(
  "Fieldnote|product|Offline-first field notes app. Current focus: conflict-free sync and the species-list importer."
  "Watershed Contract|consulting|Data-cleanup engagement for the Blue Ridge Watershed Alliance: twelve years of volunteer sampling records."
)

PERSONA_AREAS=(
  "Business Admin|Invoicing, quarterly taxes, and the one-person-company paperwork."
)

PERSONA_RESOURCES=(
  "CRDT Notes|Working reference on conflict-free replicated data types and which ones suit an append-mostly note store."
  "Species Data Formats|Darwin Core, taxonomic identifier schemes, and the mess in practice."
)

PERSONA_MEETINGS=(
  "Watershed Alliance Check-In|biweekly|Wren Halloway, Marguerite Sole, Ada Whitcomb"
  "Fieldnote Beta Feedback|monthly|Wren Halloway, Dr. Ines Barbosa"
)

PERSONA_PEOPLE=(
  "Marguerite Sole|Blue Ridge Watershed Alliance, program director"
  "Ada Whitcomb|Watershed Alliance volunteer coordinator"
  "Dr. Ines Barbosa|Field biologist, Fieldnote beta user"
)

PERSONA_SHORTHAND=(
  "FN|Fieldnote"
  "BRWA|Blue Ridge Watershed Alliance"
)

PERSONA_SOURCES=(
  "vault|local filesystem|this vault; always available"
  "meetings|Resources/Meetings/|simulated exports; no live connector in a sandbox"
  "calendar|none|not connected in the sandbox"
  "chat|none|not connected in the sandbox"
  "issues|none|not connected in the sandbox"
  "second-vault|none|not connected in the sandbox"
)
