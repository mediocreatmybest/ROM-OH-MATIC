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
import ast
import json
import operator
import os
import re

DIRECTIVE_RE = re.compile(
    r'^(?P<commented>//)?#(?P<directive>define|undef)\s+(?P<name>\w+)(?P<rest>.*)$'
)

# A handful of value-bearing options (e.g. general.h's
# `ROM_BANNER_TIMEOUT ( 2 * BANNER_TIMEOUT )`, crypto.h's
# `TIMESTAMP_ERROR_MARGIN ( ( 12 * 60 + 30 ) * 60 )`) are C integer constant
# *expressions*, not plain literals -- showing the raw expression in an
# editable text box reads as if it were the value to keep or edit, when
# it's actually unevaluated source syntax. _SAFE_BINOPS/_eval_c_int below
# implement a deliberately narrow, safe evaluator (AST-based, not eval())
# for exactly this: digits, +-*/, parentheses, and references to other
# already-known integer macros. Anything outside that -- an unknown
# identifier, an operator this doesn't handle, a genuine syntax error --
# returns None, and the caller falls back to showing the original
# expression rather than ever guessing at a wrong number.
def _c_div(a, b):
    """C-style integer division: truncates toward zero (Python's `//`
    instead floors toward negative infinity, e.g. -3 // 2 == -2, not -1)."""
    q = a // b
    r = a - q * b
    if r and (a < 0) != (b < 0):
        q += 1
    return q


_SAFE_BINOPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: _c_div,
    ast.FloorDiv: operator.floordiv,
}
_SAFE_UNARYOPS = {
    ast.USub: operator.neg,
    ast.UAdd: operator.pos,
}


def eval_c_int_expression(expr, known_values):
    """Safely evaluate a simple C integer constant expression, substituting
    already-known integer macro values for bare identifiers. Returns an
    int, or None if the expression uses anything this doesn't understand."""
    try:
        node = ast.parse(expr, mode='eval').body
    except SyntaxError:
        return None

    def _eval(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, int) and not isinstance(n.value, bool):
            return n.value
        if isinstance(n, ast.BinOp) and type(n.op) in _SAFE_BINOPS:
            left, right = _eval(n.left), _eval(n.right)
            if left is None or right is None:
                return None
            try:
                result = _SAFE_BINOPS[type(n.op)](left, right)
            except ZeroDivisionError:
                return None
            return int(result) if isinstance(result, float) and result.is_integer() else result
        if isinstance(n, ast.UnaryOp) and type(n.op) in _SAFE_UNARYOPS:
            operand = _eval(n.operand)
            return None if operand is None else _SAFE_UNARYOPS[type(n.op)](operand)
        if isinstance(n, ast.Name):
            return known_values.get(n.id)
        return None

    result = _eval(node)
    return result if isinstance(result, int) else None


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


_INT_LITERAL_RE = re.compile(r'^-?[0-9]+$')
_HEX_LITERAL_RE = re.compile(r'^0[xX][0-9a-fA-F]+$')


def parse_file(path, filename, known_int_values=None):
    if known_int_values is None:
        known_int_values = {}

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

        # Skip function-like macros: `#define NAME(param) ...`, with no
        # space before the `(` (a space there would make it an ordinary
        # object-like macro whose value happens to start with "("). These
        # are C preprocessor plumbing -- e.g. config/named.h's
        # NAMED_CONFIG(_header), used to build #include paths -- not a
        # value or boolean a user would ever set through the UI. Left
        # unhandled, the parameter list and macro body (e.g.
        # "(_header) <config/CONFIG/_header>") were being captured as if
        # they were a real option's value, and since named.h defines each
        # of these twice under #ifdef/#else with no preprocessor
        # evaluation here, both definitions showed up as duplicate entries.
        if match.group('rest').startswith('('):
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
            was_quoted = len(value) >= 2 and value[0] == '"' and value[-1] == '"'
            # C string literals (e.g. branding.h's PRODUCT_NAME "") are
            # captured with their surrounding quotes as part of `rest`
            # above; strip exactly one matching pair so this carries the
            # bare value, not the C source syntax around it. build.fcgi's
            # config_local() already re-adds quotes itself for PRODUCT*
            # fields when a submitted value comes back (and rejects literal
            # quote characters in submitted values outright) -- it expects
            # the bare form, not "".
            final_value = value[1:-1] if was_quoted else value

            if not was_quoted:
                if _INT_LITERAL_RE.match(final_value):
                    known_int_values[name] = int(final_value)
                elif not _HEX_LITERAL_RE.match(final_value):
                    # Not already a plain literal -- e.g. general.h's
                    # `ROM_BANNER_TIMEOUT ( 2 * BANNER_TIMEOUT )` or
                    # crypto.h's `TIMESTAMP_ERROR_MARGIN
                    # ( ( 12 * 60 + 30 ) * 60 )`. Showing the raw C
                    # expression in an editable box reads as if it were the
                    # value to keep, when it's actually unevaluated source
                    # syntax. Try to compute it; if that's not possible
                    # (unknown identifier, unsupported syntax), fall back to
                    # the original expression rather than ever guessing.
                    computed = eval_c_int_expression(final_value, known_int_values)
                    if computed is not None:
                        description = (description + ' (computed from: ' + final_value + ')').strip()
                        final_value = str(computed)
                        known_int_values[name] = computed

            entries.append({
                'file': filename,
                'type': 'input',
                'name': name,
                'value': final_value,
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
    # Shared across every file, in the same processing order, so a value
    # expression can reference a macro from a file processed earlier --
    # matching C's actual global macro namespace, not scoping known values
    # to a single header.
    known_int_values = {}
    for filename in sorted(os.listdir(args.directory)):
        if filename.startswith('.') or not filename.endswith('.h') or 'colour' in filename:
            continue
        entries.extend(parse_file(os.path.join(args.directory, filename), filename, known_int_values))

    print(json.dumps(entries, indent=4))


if __name__ == '__main__':
    main()
