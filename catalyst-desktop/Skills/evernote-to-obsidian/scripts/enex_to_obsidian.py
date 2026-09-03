#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "html2text",
# ]
# ///
"""
enex_to_obsidian.py

Convert Evernote .enex export files into an Obsidian-ready vault of
Markdown notes, with embedded resources (PDFs, images, audio, etc.)
extracted to an attachments folder and linked with Obsidian embed syntax.

Usage (with uv - recommended, no manual venv/install step needed):
    # uv reads the inline metadata block above and auto-installs html2text
    # into an ephemeral environment the first time you run it.
    uv run enex_to_obsidian.py --input /path/to/enex_folder --output /path/to/vault

    # Single file:
    uv run enex_to_obsidian.py --input notebook.enex --output /path/to/vault

Usage (plain pip, if you don't have uv):
    pip install html2text --break-system-packages
    python enex_to_obsidian.py --input /path/to/enex_folder --output /path/to/vault

Notes:
- Resources are matched to their in-body <en-media hash="..."/> placeholders
  via MD5 hash, per the ENEX spec.
- Attachments are named using their original filename when available,
  de-duplicated with a short hash suffix on collision.
- PDFs and images are embedded with ![[filename]] (Obsidian embed syntax);
  everything else is linked with [[filename]].

Windows:
The converter itself runs unchanged -- stdlib plus html2text, pathlib
throughout, no shell-outs. Only the invocation differs:

    # uv (recommended, as on macOS)
    uv run enex_to_obsidian.py --input C:\enex_folder --output C:\path\to\vault

    # plain pip
    py -m pip install html2text
    py enex_to_obsidian.py --input C:\enex_folder --output C:\path\to\vault

Quote any path containing spaces, and do not leave a trailing backslash inside
the quotes in PowerShell -- it escapes the closing quote. Write
"C:\my notes\vault", not "C:\my notes\vault\".

Three Windows-specific things to know:

- Converted notes get CRLF endings, because write_text() uses text mode and
  Python translates \n to os.linesep. Obsidian reads them fine and the wiki
  pipeline normalises newlines before hashing, so this causes no re-tag churn.
  Pass newline="\n" to write_text if you want output identical to the Mac's.

- MAX_PATH. Filenames are capped at 150 characters, so a long note title under a
  deep output path can cross the 260-character limit and fail with OSError.
  Either enable long paths (LongPathsEnabled, via Group Policy or the registry)
  or convert into a short directory such as C:\vault and move the results after.

- Reserved device names are NOT guarded by sanitize_filename(). A note titled
  NUL, CON, AUX, PRN, or COM1..LPT9 yields a path Windows resolves to a device
  rather than a file -- and the extension does not save it, since NUL.md is
  still the null device. The write then succeeds while producing no file. Rename
  those notes in Evernote before exporting, or add a device-name check to
  sanitize_filename(). Rare, but silent, which is why it is worth knowing.
"""

import argparse
import base64
import hashlib
import html
import mimetypes
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime

import html2text


def sanitize_filename(name: str, max_len: int = 150) -> str:
    """Strip characters that are unsafe across filesystems / Obsidian links."""
    name = re.sub(r'[\\/:*?"<>|#^\[\]]', "-", name).strip()
    name = re.sub(r"\s+", " ", name)
    return name[:max_len] if name else "untitled"


def normalize_tag(tag: str) -> str:
    """Evernote tags may contain spaces; Obsidian tags cannot.
    Lowercase and replace whitespace runs with dashes:
    "3rd Year Review" -> "3rd-year-review"."""
    return re.sub(r"\s+", "-", tag.strip()).lower()


def parse_enex_date(raw: str):
    """Evernote dates look like 20230115T182233Z."""
    if not raw:
        return None
    try:
        dt = datetime.strptime(raw.strip(), "%Y%m%dT%H%M%SZ")
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return raw


def yaml_escape(value: str) -> str:
    value = value.replace('"', '\\"')
    return f'"{value}"'


def extract_resources(note_el, attachments_dir: Path, note_slug: str):
    """
    Decode all <resource> blocks in a note. Returns a dict mapping
    md5-hash-hex -> relative attachment path (as used in the vault).
    """
    hash_to_path = {}
    used_names = set()

    for idx, res in enumerate(note_el.findall("resource")):
        data_el = res.find("data")
        if data_el is None or not data_el.text:
            continue

        raw_b64 = re.sub(r"\s+", "", data_el.text)
        try:
            decoded = base64.b64decode(raw_b64)
        except Exception as e:
            print(f"  ! Skipping unreadable resource in '{note_slug}': {e}", file=sys.stderr)
            continue

        md5_hash = hashlib.md5(decoded).hexdigest()

        mime_el = res.find("mime")
        mime_type = mime_el.text.strip() if mime_el is not None and mime_el.text else "application/octet-stream"

        # Prefer the original filename if Evernote recorded one
        file_name = None
        attrs_el = res.find("resource-attributes")
        if attrs_el is not None:
            fn_el = attrs_el.find("file-name")
            if fn_el is not None and fn_el.text:
                file_name = sanitize_filename(fn_el.text)

        if not file_name:
            ext = mimetypes.guess_extension(mime_type) or ""
            file_name = f"{note_slug}-attachment-{idx}{ext}"

        # De-duplicate names within this run
        final_name = file_name
        if final_name in used_names:
            stem = Path(file_name).stem
            ext = Path(file_name).suffix
            final_name = f"{stem}-{md5_hash[:6]}{ext}"
        used_names.add(final_name)

        out_path = attachments_dir / final_name
        out_path.write_bytes(decoded)

        hash_to_path[md5_hash] = final_name

    return hash_to_path


def convert_content_to_markdown(content_xml: str, hash_to_path: dict) -> str:
    """
    content_xml is the raw ENML (XHTML-ish) string from <content><![CDATA[ ... ]]></content>.
    Replace <en-media> tags with placeholders, convert to markdown, then
    swap placeholders for real Obsidian embed/link syntax.
    """
    placeholders = {}

    def _stash_media(match):
        tag = match.group(0)
        hash_match = re.search(r'hash="([a-fA-F0-9]+)"', tag)
        type_match = re.search(r'type="([^"]+)"', tag)
        if not hash_match:
            return ""
        h = hash_match.group(1)
        mime = type_match.group(1) if type_match else ""
        key = f"OBSIDIAN_MEDIA_PLACEHOLDER_{len(placeholders)}"
        placeholders[key] = (h, mime)
        return f"<p>{key}</p>"

    # en-media tags are self-closing XML; strip them out before HTML parsing
    content_xml = re.sub(r"<en-media[^>]*/?>", _stash_media, content_xml)

    # Strip the outer <en-note> wrapper and XML/DOCTYPE declarations
    content_xml = re.sub(r"<\?xml[^>]*\?>", "", content_xml)
    content_xml = re.sub(r"<!DOCTYPE[^>]*>", "", content_xml)
    content_xml = content_xml.replace("<en-note>", "").replace("</en-note>", "")
    content_xml = re.sub(r"</?en-note[^>]*>", "", content_xml)

    converter = html2text.HTML2Text()
    converter.body_width = 0
    converter.ignore_images = False
    converter.unicode_snob = True
    markdown_body = converter.handle(content_xml)

    # Rewrite Evernote internal note links (evernote:///view/...) as Obsidian
    # wiki links. The link text is the target note's title; sanitize it the
    # same way note filenames are so the link resolves in the vault.
    def _evernote_link(match):
        return f"[[{sanitize_filename(match.group(1))}]]"

    markdown_body = re.sub(r"\[([^\]]+)\]\(evernote://[^)]*\)", _evernote_link, markdown_body)

    # Swap placeholders for real links now that html2text has run
    for key, (h, mime) in placeholders.items():
        rel_path = hash_to_path.get(h)
        if rel_path is None:
            replacement = f"*[missing attachment: {h}]*"
        elif mime.startswith("image/") or mime == "application/pdf":
            replacement = f"![[{rel_path}]]"
        else:
            replacement = f"[[{rel_path}]]"
        markdown_body = markdown_body.replace(key, replacement)

    return markdown_body.strip()


def convert_note(note_el, attachments_dir: Path, notes_dir: Path, existing_titles: set):
    title_el = note_el.find("title")
    title = title_el.text.strip() if title_el is not None and title_el.text else "Untitled Note"
    slug = sanitize_filename(title)

    # De-duplicate note filenames
    final_slug = slug
    counter = 2
    while final_slug in existing_titles:
        final_slug = f"{slug} ({counter})"
        counter += 1
    existing_titles.add(final_slug)

    created = parse_enex_date(note_el.findtext("created"))
    updated = parse_enex_date(note_el.findtext("updated"))
    tags = [normalize_tag(t.text) for t in note_el.findall("tag") if t.text]

    hash_to_path = extract_resources(note_el, attachments_dir, final_slug)

    content_el = note_el.find("content")
    content_raw = content_el.text if content_el is not None and content_el.text else ""
    body_md = convert_content_to_markdown(content_raw, hash_to_path)

    frontmatter_lines = ["---", f"title: {yaml_escape(title)}"]
    if created:
        frontmatter_lines.append(f"created: {created}")
    if updated:
        frontmatter_lines.append(f"updated: {updated}")
    if tags:
        frontmatter_lines.append("tags:")
        for t in tags:
            frontmatter_lines.append(f"  - {t}")
    frontmatter_lines.append("source: evernote")
    frontmatter_lines.append("---\n")

    full_md = "\n".join(frontmatter_lines) + "\n" + body_md + "\n"

    out_path = notes_dir / f"{final_slug}.md"
    out_path.write_text(full_md, encoding="utf-8")
    return out_path


def process_enex_file(enex_path: Path, output_dir: Path, existing_titles: set):
    notes_dir = output_dir
    attachments_dir = output_dir / "attachments"
    attachments_dir.mkdir(parents=True, exist_ok=True)

    tree = ET.parse(enex_path)
    root = tree.getroot()
    notes = root.findall("note")

    print(f"{enex_path.name}: {len(notes)} note(s)")
    for note_el in notes:
        out_path = convert_note(note_el, attachments_dir, notes_dir, existing_titles)
        print(f"  -> {out_path.relative_to(output_dir)}")


def main():
    parser = argparse.ArgumentParser(description="Convert Evernote .enex exports to an Obsidian vault.")
    parser.add_argument("--input", required=True, help="Path to a .enex file or a folder of .enex files")
    parser.add_argument("--output", required=True, help="Path to the output Obsidian vault folder")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    if input_path.is_dir():
        enex_files = sorted(input_path.glob("*.enex"))
    else:
        enex_files = [input_path]

    if not enex_files:
        print(f"No .enex files found at {input_path}", file=sys.stderr)
        sys.exit(1)

    existing_titles = set()
    for enex_path in enex_files:
        process_enex_file(enex_path, output_dir, existing_titles)

    print(f"\nDone. Vault written to: {output_dir}")


if __name__ == "__main__":
    main()
