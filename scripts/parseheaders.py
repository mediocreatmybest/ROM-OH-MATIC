#!/usr/bin/env python3
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Parses iPXE's src/config/*.h headers into the JSON list of build
# options consumed by options.php / the advanced wizard.
#------------------------------------------------------------------------
#
# iPXE's config headers describe options two different ways:
#
#   #define NAME            /* boolean, on by default */
#   #undef  NAME            /* boolean, off by default */
#   //#define NAME          /* boolean, off by default, commented out */
#   #define NAME VALUE      /* value-bearing, e.g. a number or string */
#
# and the description for an entry comes from either a trailing comment
# on the same (possibly multi-line) directive, or -- when there isn't
# one -- from an immediately preceding /* ... */ or /** ... */ block
# comment. That preceding comment is treated as "sticky": several
# consecutive directives with no comment of their own (e.g. branding.h's
# PRODUCT_NAME/PRODUCT_SHORT_NAME/PRODUCT_URI trio, which share one
# comment above all three) inherit the same preceding description,
# until a new comment block or unrelated line resets it. That's a
# best-effort heuristic, not a guarantee -- the header format doesn't
# distinguish "this comment covers the next N directives" from "these
# directives just happen to be adjacent".
#
# A previous regex-based version of this script (and an earlier,
# unfinished Python port of it) silently dropped every option that used
# the preceding-comment style -- which is how crypto.h and branding.h
# ended up completely invisible in the advanced options UI.

import argparse
import json
import os
import re

DIRECTIVE_RE = re.compile(
    r'^(?P<commented>//)?#(?P<directive>define|undef)\s+(?P<name>\w+)(?P<rest>.*)$'
)


def strip_comment_markers(text):
    """Turn raw comment lines (with /*, */, and leading '*' continuation
    markers) into a single, plain description string."""
    cleaned = []
    for line in text.splitlines():
        line = line.strip()
        line = re.sub(r'^/\*+', '', line)
        line = re.sub(r'\*+/$', '', line)
        line = line.strip()
        line = re.sub(r'^\*\s?', '', line)
        if line:
            cleaned.append(line)
    return ' '.join(cleaned).strip()


def consume_comment(lines, index, inline_text=None):
    """Consume a /* ... */ comment that may span multiple lines. It either
    starts fresh at lines[index], or continues from inline_text (a
    fragment already split off the end of a directive line). Returns
    (description, index_of_next_unconsumed_line)."""
    if inline_text is None:
        buf = [lines[index]]
        closed = '*/' in lines[index]
    else:
        buf = [inline_text]
        closed = '*/' in inline_text

    i = index + 1
    while not closed and i < len(lines):
        buf.append(lines[i])
        closed = '*/' in lines[i]
        i += 1

    return strip_comment_markers('\n'.join(buf)), i


def parse_file(path, filename):
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()

    entries = []
    pending_comment = ''
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i].strip()

        if not line:
            i += 1
            continue

        if line.startswith('/*'):
            pending_comment, i = consume_comment(lines, i)
            continue

        match = DIRECTIVE_RE.match(line)
        if not match:
            # Anything else (an #include, an #ifndef guard, code) breaks
            # the association between a preceding comment and whatever
            # directive comes after it.
            pending_comment = ''
            i += 1
            continue

        commented_out = bool(match.group('commented'))
        directive = match.group('directive')
        name = match.group('name')

        # Skip standard C header include-guards: `#ifndef NAME` immediately
        # followed by `#define NAME` is boilerplate, not a real option.
        if (directive == 'define' and not commented_out and i > 0
                and lines[i - 1].strip() == '#ifndef ' + name):
            pending_comment = ''
            i += 1
            continue

        rest = match.group('rest').strip()

        comment_index = rest.find('/*')
        if comment_index != -1:
            value = rest[:comment_index].strip()
            trailing_comment, i = consume_comment(
                lines, i, inline_text=rest[comment_index:]
            )
        else:
            value = rest
            trailing_comment = ''
            i += 1

        description = trailing_comment or pending_comment or name
        if trailing_comment:
            pending_comment = ''

        if value:
            entries.append({
                'file': filename,
                'type': 'input',
                'name': name,
                'value': value,
                'description': description,
            })
        else:
            entry_type = 'undef' if (commented_out or directive == 'undef') else 'define'
            entries.append({
                'file': filename,
                'type': entry_type,
                'name': name,
                'description': description,
            })

    return entries


def main():
    parser = argparse.ArgumentParser(description='Parse iPXE config headers into a JSON option list')
    parser.add_argument('directory', nargs='?', default='/opt/rom-o-matic/ipxe/src/config',
                         help='directory containing the header files')
    args = parser.parse_args()

    entries = []
    for filename in sorted(os.listdir(args.directory)):
        if filename.startswith('.') or not filename.endswith('.h') or 'colour' in filename:
            continue
        entries.extend(parse_file(os.path.join(args.directory, filename), filename))

    print(json.dumps(entries, indent=4))


if __name__ == '__main__':
    main()
