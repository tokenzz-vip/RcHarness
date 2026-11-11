#!/usr/bin/env python3
"""Redact local identities from text logs using only the Python standard library."""

import argparse
import os
from pathlib import Path
import re
import stat
import tempfile


ROOT = Path(__file__).resolve().parent.parent
LOG_SUFFIXES = {".log", ".txt", ".jsonl", ".ndjson", ".ips"}
SKIP_DIRECTORIES = {".git", "out", "checkouts", "repositories", "artifacts", "node_modules"}
SKIP_BUNDLES = (".app", ".driver", ".xctest", ".trace")
RULES = (
    # Preserve the rest of each path so stack traces remain useful.
    (re.compile(r"(/(?:Users|home)/)(?!\[REDACTED_USER\])[^/\s\"'<>\\]+"),
     r"\1[REDACTED_USER]"),
    (re.compile(r"(?<![\w.])[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}"),
     "[REDACTED_EMAIL]"),
    (re.compile(r"((?:Developer ID (?:Application|Installer)|Apple (?:Development|Distribution)|"
                r"Mac Developer|3rd Party Mac Developer (?:Application|Installer)):\s*)"
                r"[^\r\n\"]+?\([A-Z0-9]{10}\)"),
     r"\1[REDACTED_IDENTITY] ([REDACTED_TEAM_ID])"),
    (re.compile(r"(\b(?:TeamIdentifier|TeamID|APPLE_TEAM_ID)[\"']?\s*[=:]\s*[\"']?)[A-Z0-9]{10}\b"),
     r"\1[REDACTED_TEAM_ID]"),
    (re.compile(r'(?m)^(\s*\d+\)\s*)[A-Fa-f0-9]{40}(?=\s+")'),
     r"\1[REDACTED_CERTIFICATE_HASH]"),
)


def redact(text):
    for pattern, replacement in RULES:
        text = pattern.sub(replacement, text)
    return text


def log_files(paths):
    for path in paths:
        if path.is_symlink():
            continue
        if any(part in SKIP_DIRECTORIES or part.endswith(SKIP_BUNDLES) for part in path.parts):
            continue
        if path.is_file():
            yield path
            continue
        for directory, children, names in os.walk(path):
            children[:] = [name for name in children
                           if name not in SKIP_DIRECTORIES and not name.endswith(SKIP_BUNDLES)
                           and not (Path(directory) / name).is_symlink()]
            for name in sorted(names):
                file = Path(directory) / name
                if not file.is_symlink() and (file.suffix in LOG_SUFFIXES or name.endswith(".log.previous")):
                    yield file


def replace_file(path, data):
    mode = stat.S_IMODE(path.stat().st_mode)
    temporary = None
    try:
        # Keep the original untouched if writing fails; retain no unredacted backup.
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".redacted-", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="report counts without writing (default); exit 1 if redaction is needed")
    modes.add_argument("--in-place", action="store_true", help="redact existing logs in place, without keeping original copies")
    parser.add_argument("paths", nargs="*", type=Path, help="files or log directories; defaults to .build and docs/audits")
    args = parser.parse_args()
    paths = args.paths or [path for path in (ROOT / ".build", ROOT / "docs/audits") if path.exists()]
    for path in paths:
        if not path.exists() or path.is_symlink():
            parser.error("Each input must be an existing file or directory, not a symbolic link.")
    scanned = changed = skipped = 0
    seen = set()
    try:
        for path in log_files(paths):
            identity = path.resolve()
            if identity in seen:
                continue
            seen.add(identity)
            data = path.read_bytes()
            try:
                if b"\0" in data:
                    skipped += 1
                    continue
                original = data.decode("utf-8")
            except UnicodeDecodeError:
                skipped += 1
                continue
            scanned += 1
            redacted = redact(original)
            if redacted != original:
                changed += 1
                if args.in_place:
                    replace_file(path, redacted.encode("utf-8"))
    except OSError:
        parser.exit(2, "Could not read or replace a log file; redaction is incomplete.\n")
    # Never echo matching values or paths from user-supplied logs.
    print(f"Text files checked: {scanned}; {'redacted' if args.in_place else 'needing redaction'}: {changed}; binary/non-UTF-8 skipped: {skipped}.")
    return 0 if args.in_place or changed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
