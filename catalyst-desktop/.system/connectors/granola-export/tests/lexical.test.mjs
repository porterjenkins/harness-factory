import assert from "node:assert/strict";
import test from "node:test";

import { CATEGORIES, merge, redact, scan } from "../redact/lexical.mjs";

const mk = (category) => `[R:${category}]`;
const cats = (s) => redact(s, mk).hits;
const hit = (s) => cats(s).length > 0;

test("every Tier B term fires on its own", () => {
  const strong = {
    abuse: [
      "he was molested as a boy", "grooming behaviour", "we are a mandated reporter",
      "the failure to report", "CPS has a file", "DCFS called back",
      "the perpetrator moved away", "she called the hotline",
      "law enforcement was notified", "the victim is doing better",
    ],
    discipline: [
      "a disciplinary council", "the membership council", "an old court of love",
      "he was disfellowshipped", "excommunication followed", "his membership records",
      "formal action was taken", "restricted from his callings",
    ],
    criminal: [
      "the indictment landed", "a prior conviction", "a felony count",
      "two misdemeanors", "an arrest warrant", "on the docket", "out on parole",
      "served a subpoena", "he was arrested", "entered a plea",
    ],
    financial: [
      "embezzlement of funds", "misappropriated the money", "misuse of funds",
      "an unauthorized transaction", "he offered restitution", "wire fraud",
    ],
    hardship: [
      "moved to hospice", "talk of suicide", "an overdose", "a relapse",
      "after the miscarriage", "his addiction", "filed for bankruptcy",
      "the divorce is final", "the death of a child",
    ],
    employment: [
      "a performance improvement plan", "the PIP runs 60 days", "on administrative leave",
      "placed on leave", "a separation agreement", "a non-disclosure clause",
      "the demotion stuck", "released from employment",
    ],
  };
  for (const [category, phrases] of Object.entries(strong)) {
    for (const phrase of phrases) {
      assert.deepEqual(cats(phrase), [category], `"${phrase}" should be ${category}`);
    }
  }
});

test("Tier C terms stay silent without their qualifier", () => {
  const benign = [
    "we are seeing API abuse from one client",
    "terminate the instance and redeploy",
    "reassign the ticket to the platform board",
    "separation of concerns between the two services",
    "the investigation into the checkout regression",
    "a SOC 2 audit finding on log retention",
    "the budget is $40,000 for the half",
    "1.2 million dollars of cloud spend",
    "a discrepancy between the two dashboards",
    "a probationary period for new hires",
    "the terminal prints the wrong colour",
    "the charges on the invoice look right",
    "this warrants a follow-up next week",
  ];
  for (const s of benign) assert.equal(hit(s), false, `false positive: "${s}"`);
});

test("Tier C terms fire once their qualifier is present", () => {
  const cases = [
    ["a minor disclosed the abuse to her teacher", "abuse"],
    ["misconduct involving a 15-year-old student", "abuse"],
    ["the court placed him on probation", "criminal"],
    ["the bishop put him on probation pending the council", "discipline"],
    ["a police investigation is open", "criminal"],
    ["he was charged after the arrest", "criminal"],
    ["the shortfall matched the audit finding", "financial"],
    ["$18,400 was embezzled from the account", "financial"],
    ["HR is terminating his employment on Friday", "employment"],
    ["their marital separation is recent", "hardship"],
    ["a terminal diagnosis, weeks not months", "hardship"],
  ];
  for (const [s, category] of cases) {
    assert.ok(cats(s).includes(category), `"${s}" should include ${category}, got ${cats(s)}`);
  }
});

test("an age reference near a relationship term fires with no abuse keyword", () => {
  assert.deepEqual(cats("a 14-year-old and the relationship with a volunteer"), ["abuse"]);
  // Same age reference, nothing relational nearby.
  assert.equal(hit("the 14-year-old cohort grew 3% this quarter"), false);
});

test("proximity is bounded, not chunk-wide", () => {
  const filler = "and ".repeat(40);
  assert.equal(hit(`a 14-year-old ${filler} relationship`), false);
});

test("Luhn separates cards from order and ticket ids", () => {
  assert.deepEqual(cats("card 4111 1111 1111 1111"), ["pii"]);
  assert.equal(hit("order 4111111111111112"), false);
  assert.equal(hit("ticket reference 9876543210980"), false);
});

test("PIP and CPS are acronyms, not lowercase words", () => {
  assert.equal(hit("run pip install -r requirements.txt"), false);
  assert.deepEqual(cats("the PIP runs sixty days"), ["employment"]);
  assert.equal(hit("the cps value dropped overnight"), false);
});

test("non-disclosure is employment, not an abuse disclosure", () => {
  assert.deepEqual(cats("a non-disclosure agreement"), ["employment"]);
});

test("each PII pattern matches", () => {
  assert.deepEqual(cats("SSN 123-45-6789"), ["pii"]);
  assert.deepEqual(cats("ssn 123456789"), ["pii"]);
  assert.deepEqual(cats("reach me at a.b@example.com"), ["pii"]);
  assert.deepEqual(cats("call (801) 555-0134"), ["pii"]);
  assert.deepEqual(cats("call +44 20 7946 0958"), ["pii"]);
});

test("overlapping spans merge and the earliest-declared category wins", () => {
  const merged = merge([
    { start: 0, end: 10, category: "criminal" },
    { start: 5, end: 20, category: "abuse" },
    { start: 40, end: 45, category: "hardship" },
  ]);
  assert.equal(merged.length, 2);
  assert.deepEqual({ ...merged[0] }, { start: 0, end: 20, category: "abuse" });
  assert.equal(CATEGORIES.indexOf("abuse") < CATEGORIES.indexOf("criminal"), true);
});

test("redact replaces only the matched span and leaves the rest intact", () => {
  const { text } = redact("Bishop raised the disciplinary council for Brother Hale.", mk);
  assert.equal(text, "Bishop raised the [R:discipline] for Brother Hale.");
});

test("scan returns sorted, non-overlapping spans", () => {
  const spans = scan("the felony count is on the docket after the arrest");
  for (let i = 1; i < spans.length; i++) {
    assert.ok(spans[i].start >= spans[i - 1].end, "spans overlap or are unsorted");
  }
});

test("clean text is returned unchanged and allocates no hits", () => {
  const s = "Standup: shipped the retry fix, picking up the cache bug next.";
  assert.deepEqual(redact(s, mk), { text: s, hits: [] });
});

test("a dollar figure alone is never a redaction, at any magnitude", () => {
  // Budget notes are the most common benign meeting note there is. If money
  // alone fired, the screener would eat every planning note in the vault.
  for (const amt of ["$5k", "$50k", "$100k", "$250k", "$1.2M", "$250,000", "$18,400.50"]) {
    assert.equal(hit(`Tooling budget came in at ${amt} for the quarter.`), false, amt);
  }
});

test("salary tied to a named person is not redacted — compensation is out of scope", () => {
  // Documents current behaviour, not an endorsement of it. Salary is personal
  // but it is not misconduct, and the requirements scoped `financial` to
  // misconduct. If compensation is brought into scope, this test should flip.
  for (const amt of ["$5k", "$50k", "$100k", "$250k"]) {
    assert.equal(hit(`Dana Okafor's salary is ${amt} plus equity.`), false, amt);
  }
});

test("a figure with misconduct context redacts whole, suffix and decimals included", () => {
  // The bug this pins: anchored at two decimals, "$1.5M" redacted to
  // "[REDACTED].5M" and "$250k" to "[REDACTED]k", leaking the fraction and the
  // order of magnitude. A half-redacted number still reads as screened.
  const cases = [
    ["Embezzlement of $5k from the account.", "$5k"],
    ["Embezzlement of $250k from the account.", "$250k"],
    ["Embezzlement of $250,000 from the account.", "$250,000"],
    ["Fraud totalling $1.5M was found.", "$1.5M"],
    ["Fraud totalling $2.4bn was found.", "$2.4bn"],
    ["Fraud totalling $18,400.50 was found.", "$18,400.50"],
    ["Embezzlement of $100 million from the fund.", "$100 million"],
  ];
  for (const [sentence, amount] of cases) {
    const { text, hits } = redact(sentence, mk);
    assert.ok(hits.includes("financial"), `${amount}: not flagged`);
    assert.equal(text.includes("$"), false, `${amount}: a dollar sign survived -> ${text}`);
    // No orphaned magnitude suffix or decimal tail left behind the marker.
    assert.equal(/\]\s*(?:k|m|mm|bn?|\.\d)/i.test(text), false, `${amount}: leaked remainder -> ${text}`);
  }
});

test("the amount ladder needs misconduct context, not just a bigger number", () => {
  for (const amt of ["$5k", "$50k", "$100k", "$250k"]) {
    assert.equal(hit(`The line item is ${amt}.`), false, `${amt} alone`);
    assert.ok(cats(`Embezzlement of ${amt}.`).includes("financial"), `${amt} with misconduct`);
  }
});
