/**
 * Shared fixture loading for the redaction suite.
 *
 * Each fixture in notes/ declares its own expectation in frontmatter, so adding
 * a case to the bank is adding one file -- no test has to be edited to cover it.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const NOTES_DIR = path.join(HERE, "notes");

export function loadBank() {
  return fs
    .readdirSync(NOTES_DIR)
    .filter((f) => f.endsWith(".md"))
    .sort()
    .map((file) => {
      const text = fs.readFileSync(path.join(NOTES_DIR, file), "utf8");
      const scalar = (key) => {
        const m = text.match(new RegExp(`^${key}:[ \\t]*(.*)$`, "m"));
        return m ? m[1].trim() : null;
      };
      const cats = (scalar("expect_categories") || "[]").replace(/^\[|\]$/g, "").trim();
      return {
        file,
        text,
        case: scalar("case") || file,
        url: (scalar("granola_url") || "").replace(/^"|"$/g, "") || null,
        id: scalar("granola_id"),
        expectCategories: cats ? cats.split(",").map((c) => c.trim()).filter(Boolean) : [],
        expectMinRedactions: Number(scalar("expect_min_redactions") || 0),
      };
    });
}

export const isNegative = (fx) => fx.case.startsWith("neg-");
