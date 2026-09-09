#!/usr/bin/env python3
"""Rewrite RELEASENOTES.md for a release.

Repo mode (the default, run by the release workflow after a build): the
"Unreleased" section becomes the released version's section, and a fresh empty
"Unreleased" section is inserted above it.

Bundle mode (``--for-bundle``, run by scripts/build-app.sh): the same promotion
is written to ``--output`` without opening a fresh "Unreleased" section — the
copy embedded in the app only ever describes what actually shipped, and the
source file is left untouched.
"""
import argparse
import re
import sys
from datetime import date

PATH = "RELEASENOTES.md"
HEADING = "## Unreleased"
PLACEHOLDER = "\n\nWork in progress on the current branch, not yet committed or released:"


def section_body(content, heading):
    """Everything between `heading` and the next `## ` heading (or EOF)."""
    start = content.index(heading) + len(heading)
    rest = content[start:]
    end = rest.find("\n## ")
    return rest if end == -1 else rest[:end]


def promote(content, version, release_date, keep_unreleased):
    """Turn the "Unreleased" section into `## <version> — <date>`.

    With `keep_unreleased`, a fresh empty "Unreleased" heading is left above the
    promoted section. Without it (the bundle copy), an Unreleased section with
    nothing under it is dropped rather than promoted — a build off a
    just-released tree would otherwise ship an empty version section.
    """
    released_heading = f"## {version} — {release_date}"

    # Drop the unreleased-branch placeholder sentence, if still present.
    content = content.replace(HEADING + PLACEHOLDER, HEADING, 1)

    if not keep_unreleased and not section_body(content, HEADING).strip():
        content = content.replace(HEADING + section_body(content, HEADING), "", 1)
        return re.sub(r"\n{3,}", "\n\n", content)

    # Rename the (now placeholder-free) Unreleased heading to the release
    # heading, optionally inserting a fresh empty Unreleased section above it.
    replacement = f"{HEADING}\n\n{released_heading}" if keep_unreleased else released_heading
    return content.replace(HEADING, replacement, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="released version, e.g. 1.2.3")
    parser.add_argument("release_date", nargs="?", help="ISO date; defaults to today")
    parser.add_argument("--input", default=PATH, help=f"source file (default: {PATH})")
    parser.add_argument("--output", help="destination file (default: rewrite --input in place)")
    parser.add_argument(
        "--for-bundle",
        action="store_true",
        help="promote without opening a fresh Unreleased section (app-bundle copy)",
    )
    args = parser.parse_args()

    release_date = args.release_date or date.today().isoformat()
    destination = args.output or args.input

    with open(args.input) as f:
        content = f.read()

    if HEADING not in content:
        if not args.for_bundle:
            print(f"no '{HEADING}' section found in {args.input}", file=sys.stderr)
            sys.exit(1)
        # Nothing to promote — the notes are already release-shaped, so the
        # bundled copy is a verbatim copy. Not worth failing a build over.
        print(f"no '{HEADING}' section in {args.input}, copying verbatim", file=sys.stderr)
    elif f"## {args.version} —" in content:
        # Re-running against a tree whose notes were already rewritten (a
        # rebuilt tag, or a local build stamped with an older version).
        # Promoting again would produce two sections for one version.
        print(f"{args.input} already has a '{args.version}' section, leaving Unreleased as is", file=sys.stderr)
    else:
        content = promote(content, args.version, release_date, keep_unreleased=not args.for_bundle)

    with open(destination, "w") as f:
        f.write(content)

    print(f"{destination}: release notes written for {args.version}")


if __name__ == "__main__":
    main()
