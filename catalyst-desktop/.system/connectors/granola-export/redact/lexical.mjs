/**
 * Lexical screening: keyword and regex, local, synchronous, no network, no LLM.
 *
 * This layer runs first and is authoritative -- the semantic layer may add
 * redactions but never reverses one. Everything here is deterministic so the
 * same note screens the same way on every machine and in every test.
 *
 * The rules are tiered, and the tiering is the whole design. A flat keyword list
 * built from the requirements fires constantly on ordinary engineering notes:
 * "rate abuse", "terminate the instance", "investigate the regression", "audit
 * finding", "a discrepancy in the numbers", "$40,000 of budget". A screener that
 * eats normal work notes gets switched off within a week, and then it protects
 * nothing at all. So ambiguous terms only match alongside a qualifier that
 * establishes the sensitive reading.
 */

// Declaration order is precedence order. When two spans overlap, the category
// declared earliest wins, so a chunk hitting both `abuse` and `criminal` always
// reports the same label instead of depending on match order.
export const CATEGORIES = ["pii", "abuse", "discipline", "criminal", "financial", "hardship", "employment"];

// Proximity for the one rule that needs it, measured in whitespace tokens.
// Named once rather than inlined per rule so it can be tuned in a single place.
const PROXIMITY_TOKENS = 12;

const rx = (src, flags = "gi") => new RegExp(src, flags);

// --- Tier A: PII. Fires standalone, replaces the matched span only. ----------
//
// Card and SSN patterns are ordered before phone because a 13-19 digit run can
// swallow a phone-shaped substring; span merging resolves the overlap either
// way, but matching the more specific pattern first keeps the category right.
const TIER_A = [
  { category: "pii", re: rx("\\b\\d{3}[- ]\\d{2}[- ]\\d{4}\\b") },
  // A bare nine-digit run is far more often an order or account id than an SSN,
  // so it only counts when something nearby says otherwise.
  { category: "pii", re: rx("\\b(?:ssn|social security(?:\\s+number)?)\\b[^\\n]{0,24}?\\b\\d{9}\\b") },
  { category: "pii", re: rx("\\b\\d(?:[ -]?\\d){12,18}\\b"), guard: luhn },
  { category: "pii", re: rx("\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b") },
  { category: "pii", re: rx("(?:\\+1[ .-]?)?\\(?\\b\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b") },
  { category: "pii", re: rx("\\+\\d{1,3}[ .-]?\\d{2,4}(?:[ .-]?\\d{2,4}){1,3}\\b") },
];

// The Luhn check is what separates a real card from an order number, an invoice
// id, or a long ticket reference -- all of which a bare 13-19 digit regex
// matches and all of which appear in ordinary meeting notes.
function luhn(s) {
  const digits = s.replace(/\D/g, "");
  if (digits.length < 13 || digits.length > 19) return false;
  let sum = 0;
  let dbl = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = digits.charCodeAt(i) - 48;
    if (dbl) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    dbl = !dbl;
  }
  return sum % 10 === 0;
}

// --- Tier B: strong topical terms. Fire standalone, span-level replacement. --
//
// `cs: true` means the term is matched case-sensitively. That is not a detail:
// lowercase "pip" is `pip install` and lowercase "da" is a word fragment, so
// PIP, CPS, DCFS and DA only count in the shape an acronym actually takes.
const TIER_B = [
  ["abuse", "molest\\w*"],
  ["abuse", "grooming"],
  ["abuse", "mandat(?:ory|ed) reporter"],
  ["abuse", "fail(?:ure|ed) to report"],
  ["abuse", "CPS", true],
  ["abuse", "DCFS", true],
  ["abuse", "perpetrator"],
  ["abuse", "hotline"],
  ["abuse", "law enforcement (?:was |were |has been |been )?notified"],
  ["abuse", "victim"],

  ["discipline", "disciplinary council"],
  ["discipline", "membership council"],
  ["discipline", "court of love"],
  ["discipline", "disfellowship\\w*"],
  ["discipline", "excommunicat\\w*"],
  ["discipline", "membership record\\w*"],
  ["discipline", "formal action"],
  ["discipline", "restrict\\w* from (?:his |her |their |the )?(?:ordinance|calling|temple|serving)\\w*"],

  ["criminal", "indict\\w*"],
  ["criminal", "convict\\w*"],
  ["criminal", "felon(?:y|ies)"],
  ["criminal", "misdemeanor\\w*"],
  ["criminal", "(?:arrest|bench|search) warrant"],
  ["criminal", "docket"],
  ["criminal", "parole"],
  ["criminal", "subpoena\\w*"],
  ["criminal", "arrest\\w*"],
  ["criminal", "plea(?: deal| bargain| agreement)?"],

  ["financial", "embezzl\\w*"],
  ["financial", "misappropriat\\w*"],
  ["financial", "misuse of funds"],
  ["financial", "unauthorized transaction\\w*"],
  ["financial", "restitution"],
  ["financial", "fraud\\w*"],

  ["hardship", "hospice"],
  ["hardship", "suicid\\w*"],
  ["hardship", "overdos\\w*"],
  ["hardship", "relaps\\w*"],
  ["hardship", "miscarriage"],
  ["hardship", "addict\\w*"],
  ["hardship", "bankrupt\\w*"],
  ["hardship", "divorc\\w*"],
  ["hardship", "death of (?:a|his|her|their|the) (?:child|son|daughter|baby|infant)"],

  ["employment", "performance improvement plan"],
  ["employment", "PIP", true],
  ["employment", "administrative leave"],
  ["employment", "placed on leave"],
  ["employment", "separation agreement"],
  ["employment", "non-?disclosure(?: agreement)?"],
  ["employment", "demot(?:ion|ed)"],
  ["employment", "released from employment"],
].map(([category, src, cs]) => ({ category, re: rx(`\\b(?:${src})\\b`, cs ? "g" : "gi") }));

// --- Tier C qualifier vocabularies ------------------------------------------

const Q_MINOR = rx("\\bminor\\b|\\bchild\\w*\\b|\\byouth\\b|\\bstudent\\b|\\bteen\\w*\\b|\\bunderage\\b|\\bvictim\\b|\\d{1,2}[- ]year[- ]old|\\bmolest\\w*|\\bgrooming\\b|\\bmandat(?:ory|ed) reporter\\b|\\bCPS\\b|\\bDCFS\\b", "i");
const Q_LEGAL = rx("\\bcourt\\b|\\bjudge\\b|\\bfelon(?:y|ies)\\b|\\bmisdemeanor\\b|\\bplea\\b|\\bprosecut\\w*|\\bguilty\\b|\\bconvict\\w*|\\barrest\\w*|\\bjail\\b|\\bprison\\b|\\bsentenc\\w*|\\bparole\\b|\\bcharges? (?:were |was |have been )?filed", "i");
const Q_POLICE = rx("\\bpolice\\b|\\bdetective\\b|\\bsheriff\\b|\\bdistrict attorney\\b|\\bwarrant\\b|\\blaw enforcement\\b|\\bcriminal\\b|\\bprosecut\\w*|\\bfelon(?:y|ies)\\b", "i");
const Q_ECCLESIASTICAL = rx("\\bbishop\\b|\\bcouncil\\b|\\bmembership\\b|\\bstake\\b|\\bward\\b|\\becclesiastical\\b|\\bpresidency\\b", "i");
// Deliberately narrow. "team", "staff" and "manager" appear in every roadmap
// note ever written, and including them turned "Q3 separation of concerns" into
// an employment action.
const Q_EMPLOYMENT = rx("\\bHR\\b|\\bhuman resources\\b|\\bemployment\\b|\\bemployee\\b|\\bpersonnel file\\b|\\bseverance\\b|\\blast day\\b|\\bfinal paycheck\\b|\\bexit interview\\b|\\bplaced on leave\\b|\\bperformance (?:issue|problem|plan|review)\\w*", "i");
const Q_MARITAL = rx("\\bmarriage\\b|\\bmarital\\b|\\bspouse\\b|\\bhusband\\b|\\bwife\\b|\\bdivorc\\w*|\\btrial separation\\b", "i");
const Q_ILLNESS = rx("\\billness\\b|\\bdiagnos\\w*|\\bcancer\\b|\\bprognosis\\b|\\bterminally ill\\b|\\bhospice\\b|\\bpalliative\\b", "i");
const Q_FINANCIAL = rx("\\bembezzl\\w*|\\bmisappropriat\\w*|\\bmisuse of funds\\b|\\bunauthorized\\b|\\brestitution\\b|\\bfraud\\w*|\\bstolen\\b|\\btheft\\b|\\bmissing funds\\b", "i");
const Q_RELATIONSHIP = rx("\\brelationship\\b|\\bcontact\\b|\\bdating\\b|\\balone with\\b|\\btexting\\b|\\bmessaging\\b|\\bromantic\\b|\\bboyfriend\\b|\\bgirlfriend\\b|\\bgroomed?\\b", "i");

// Two distinct suspicion terms qualify each other: "a shortfall, and the audit
// finding" is misconduct-shaped even with no misconduct word in the note. A
// currency amount is deliberately NOT one of them, so "a $2,000 discrepancy in
// the invoice totals" -- one suspicion term plus money -- stays clean, and so
// does a budget note made entirely of dollar figures.
const SUSPICION = [
  rx("\\bshortfall\\b", "i"),
  rx("\\baudit finding\\w*\\b", "i"),
  rx("\\bdiscrepanc(?:y|ies)\\b", "i"),
  rx("\\bledger\\b", "i"),
  rx("\\baccount(?:ing)? (?:number|records?)\\b", "i"),
];

function financialContext(core) {
  if (Q_FINANCIAL.test(core)) return true;
  return SUSPICION.filter((re) => re.test(core)).length >= 2;
}

// --- Tier C: ambiguous terms, only match alongside a qualifier ---------------
//
// `scope: "chunk"` means the qualifier may appear anywhere in the same chunk;
// `scope: "near"` requires it within PROXIMITY_TOKENS tokens of the term.
const TIER_C = [
  {
    category: "abuse",
    re: rx("\\babus\\w*\\b|\\bassault\\w*\\b|\\bmisconduct\\b|\\binappropriate (?:contact|relationship|behaviou?r|touching)\\b|(?<!non-)\\bdisclos\\w*\\b"),
    qualifier: Q_MINOR,
    scope: "chunk",
  },
  {
    // The requirements call this one out explicitly: an age reference next to a
    // relationship term is reportable on its own, with no abuse keyword
    // anywhere in the note.
    category: "abuse",
    re: rx("\\b\\d{1,2}[- ]year[- ]old\\b|\\bminor\\b|\\bunderage\\b"),
    qualifier: Q_RELATIONSHIP,
    scope: "near",
  },
  // "Probation" is three different words. Legal and ecclesiastical both count;
  // a probationary employment period does not, and matches neither qualifier.
  { category: "criminal", re: rx("\\bprobation(?:ary)?\\b"), qualifier: Q_LEGAL, scope: "chunk" },
  { category: "discipline", re: rx("\\bprobation(?:ary)?\\b"), qualifier: Q_ECCLESIASTICAL, scope: "chunk" },
  { category: "criminal", re: rx("\\binvestigat\\w*\\b"), qualifier: Q_POLICE, scope: "chunk" },
  { category: "criminal", re: rx("\\bsentenc\\w*\\b|\\bcharged\\b|\\bcharges\\b"), qualifier: Q_LEGAL, scope: "chunk" },
  {
    // Currency and ledger references are only misconduct in context. Without
    // this, every budget line item in the vault is a redaction.
    category: "financial",
    // The currency pattern must swallow the magnitude suffix and ANY number of
    // decimal places, not just cents. Anchored at two decimals it redacted
    // "$1.5M" as "[REDACTED].5M" and "$250k" as "[REDACTED]k" -- leaking the
    // fraction and the order of magnitude, which is most of what the figure
    // said. A partial redaction of a number is worse than none: it reads as
    // screened.
    re: rx("\\bdiscrepanc(?:y|ies)\\b|\\bshortfall\\b|\\baudit finding\\w*\\b|\\$[\\d,]+(?:\\.\\d+)?(?:\\s*(?:k|m|mm|bn?|thousand|million|billion))?\\b|\\b\\d[\\d,.]*\\s+(?:thousand|million|billion)\\s+dollars\\b|\\bledger\\b|\\baccount(?:ing)? (?:number|records?)\\b"),
    qualifies: financialContext,
  },
  {
    category: "employment",
    re: rx("\\bterminat\\w*\\b|\\breassign\\w*\\b|\\bresignation\\b|\\bresigned\\b|\\bseparat(?:ion|ed|ing)\\b"),
    qualifier: Q_EMPLOYMENT,
    scope: "chunk",
  },
  { category: "hardship", re: rx("\\bseparat(?:ion|ed|ing)\\b"), qualifier: Q_MARITAL, scope: "chunk" },
  { category: "hardship", re: rx("\\bterminal\\b"), qualifier: Q_ILLNESS, scope: "chunk" },
];

// Token offsets, used only by the one `scope: "near"` rule.
function tokenIndexAt(tokens, charPos) {
  for (let i = 0; i < tokens.length; i++) if (tokens[i].end > charPos) return i;
  return tokens.length;
}

function nearQualifier(core, start, end, qualifier) {
  const tokens = [];
  for (const m of core.matchAll(/\S+/g)) tokens.push({ start: m.index, end: m.index + m[0].length });
  const from = tokenIndexAt(tokens, start);
  const to = tokenIndexAt(tokens, end - 1);
  const lo = Math.max(0, from - PROXIMITY_TOKENS);
  const hi = Math.min(tokens.length - 1, to + PROXIMITY_TOKENS);
  if (hi < lo) return false;
  const window = core.slice(tokens[lo].start, tokens[hi].end);
  return new RegExp(qualifier.source, "i").test(window);
}

/**
 * Find every sensitive span in one chunk's screenable core.
 * Returns merged, sorted spans: [{ start, end, category }].
 */
export function scan(core) {
  const spans = [];

  for (const rule of TIER_A) {
    for (const m of core.matchAll(rule.re)) {
      if (rule.guard && !rule.guard(m[0])) continue;
      spans.push({ start: m.index, end: m.index + m[0].length, category: rule.category });
    }
  }
  for (const rule of TIER_B) {
    for (const m of core.matchAll(rule.re)) {
      spans.push({ start: m.index, end: m.index + m[0].length, category: rule.category });
    }
  }
  for (const rule of TIER_C) {
    if (rule.qualifies) {
      if (!rule.qualifies(core)) continue;
    } else if (rule.scope === "chunk" && !new RegExp(rule.qualifier.source, "i").test(core)) {
      continue;
    }
    for (const m of core.matchAll(rule.re)) {
      const start = m.index;
      const end = start + m[0].length;
      if (rule.scope === "near" && !nearQualifier(core, start, end, rule.qualifier)) continue;
      spans.push({ start, end, category: rule.category });
    }
  }

  return merge(spans);
}

// Overlapping spans become one span. The surviving category is whichever is
// declared earliest in CATEGORIES, so the label does not depend on which rule
// happened to match first.
export function merge(spans) {
  if (spans.length === 0) return [];
  const rank = (c) => CATEGORIES.indexOf(c);
  const sorted = spans.slice().sort((a, b) => a.start - b.start || b.end - a.end);
  const out = [sorted[0]];
  for (const s of sorted.slice(1)) {
    const last = out[out.length - 1];
    if (s.start < last.end) {
      last.end = Math.max(last.end, s.end);
      if (rank(s.category) < rank(last.category)) last.category = s.category;
    } else {
      out.push({ ...s });
    }
  }
  return out;
}

/**
 * Replace every sensitive span with `marker(category)`.
 * Returns { text, hits: [category, ...] } -- one entry per replaced span.
 */
export function redact(core, marker) {
  const spans = scan(core);
  if (spans.length === 0) return { text: core, hits: [] };
  let out = "";
  let cursor = 0;
  for (const s of spans) {
    out += core.slice(cursor, s.start) + marker(s.category);
    cursor = s.end;
  }
  out += core.slice(cursor);
  return { text: out, hits: spans.map((s) => s.category) };
}
