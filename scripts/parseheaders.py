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
#
# The same option name can legitimately appear more than once in one
# header, in two distinct ways, and emitting an entry for each occurrence
# produced duplicate options in the UI -- two checkboxes sharing one DOM
# id, showing contradictory defaults, with no deterministic answer to
# "which one does a saved config (or a preset) refer to":
#
#   1. A platform-guarded redefinition. Headers declare a general default
#      at the top level and then adjust it inside a conditional block --
#      e.g. console.h defines CONSOLE_FRAMEBUFFER, then #undefs it under
#      "#if defined ( PLATFORM_pcbios )". The top-level declaration is the
#      general default, so that is the one kept.
#
#   2. A commented-out alternative value. dhcp.h carries
#      "#define DHCP_DISC_START_TIMEOUT_SEC 1" immediately followed by
#      "//#define DHCP_DISC_START_TIMEOUT_SEC 4 /* as per PXE spec */" --
#      documentation of another value to use, not a second option. The
#      active line wins; without that, the inactive spec value shadowed
#      the real default both in the UI and in known_int_values.
#
# Note the limitation this does NOT solve: which platform-guarded branch
# actually applies depends on the build target, and this runs once for
# every target. An option whose default differs per platform is therefore
# shown at its general (top-level) default even when building for a
# platform that overrides it. The value submitted for such an option is
# still correct -- build.fcgi writes overrides into config/local/*.h,
# which the headers include last -- but the *displayed* default can be
# wrong for BIOS builds specifically. Making that exact would mean
# parsing per-platform and teaching options.php to cache one list per
# target.

import argparse
import ast
import json
import operator
import os
import re

# "#   define NAME" is as valid as "#define NAME", and appears elsewhere in
# the iPXE tree even though config/*.h happens not to use it today. Matching
# the conditional pattern below in tolerating that whitespace matters because
# the failure is silent: an unmatched directive is treated as an unrelated
# line, so the option simply disappears from the UI.
DIRECTIVE_RE = re.compile(
    r'^(?P<commented>//)?#\s*(?P<directive>define|undef)\s+(?P<name>\w+)(?P<rest>.*)$'
)

# Preprocessor conditionals. "ifndef"/"ifdef"/"elif" must precede "if" in
# the alternation, otherwise "if" matches their leading substring first.
CONDITIONAL_RE = re.compile(
    r'^#\s*(?P<kind>ifndef|ifdef|elif|else|endif|if)\b'
)

# Trailing comments are allowed on both halves of the guard: without that,
# "#ifndef CONFIG_FOO_H /* guard */" is not recognised and the guard's own
# symbol is reported as though it were a build option.
_INCLUDE_GUARD_RE = re.compile(
    r'^#\s*ifndef\s+(?P<name>\w+)\s*(?:/\*.*)?$'
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


def is_include_guard(lines, index):
    """True if lines[index] is the `#ifndef NAME` of a standard include
    guard -- i.e. the next non-blank line is `#define NAME`. That guard
    wraps the entire file, so counting it as a conditional block would
    leave nothing at top level for dedupe_records() to prefer."""
    match = _INCLUDE_GUARD_RE.match(lines[index].strip())
    if not match:
        return False
    guard = match.group('name')
    j = index + 1
    while j < len(lines) and not lines[j].strip():
        j += 1
    if j >= len(lines):
        return False
    return re.match(r'^#\s*define\s+' + re.escape(guard) + r'\s*(?:/\*.*)?$',
                    lines[j].strip()) is not None


def scan_directives(lines):
    """Walk a header and return one raw record per #define/#undef, in file
    order, each tagged with the conditional-block depth it sits at (0 =
    top level) and whether it was commented out. Values are left as
    written; dedupe and evaluation happen afterwards."""
    records = []
    pending_comment = ''
    # One entry per open conditional; True marks the file's include guard,
    # which is not a real conditional for our purposes.
    guard_stack = []
    # Name of an include guard whose matching "#define NAME" has not been
    # consumed yet, so it can be skipped rather than reported as an option.
    pending_guard_define = None
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

        conditional = CONDITIONAL_RE.match(line)
        if conditional:
            kind = conditional.group('kind')
            if kind in ('if', 'ifdef', 'ifndef'):
                # Only the file's own guard is exempt, and that one wraps
                # everything, so it can only appear at the top level.
                # Without the depth test any nested "#ifndef NAME /
                # #define NAME" -- the ordinary way a header gives an
                # option a default without overriding one already set --
                # looked like a guard, which both left the block out of
                # the depth count and dropped NAME from the output
                # entirely.
                guard = (kind == 'ifndef' and not guard_stack
                         and is_include_guard(lines, i))
                guard_stack.append(guard)
                if guard:
                    # Remember the name so the guard's own "#define NAME"
                    # is skipped below. Recorded here, from the same
                    # detection that decided this is a guard, rather than
                    # re-testing the previous line down there: the two
                    # tests disagreed about a blank line between the
                    # "#ifndef" and the "#define", which let the guard
                    # symbol through as though it were an option.
                    pending_guard_define = _INCLUDE_GUARD_RE.match(line).group('name')
            elif kind == 'endif' and guard_stack:
                guard_stack.pop()
            # #else/#elif keep the same depth, but like any other
            # non-directive line they break a preceding comment's
            # association with whatever follows.
            pending_comment = ''
            i += 1
            continue

        match = DIRECTIVE_RE.match(line)
        if not match:
            # Anything else (an #include, code) breaks the association
            # between a preceding comment and whatever directive comes
            # after it.
            pending_comment = ''
            i += 1
            continue

        commented_out = bool(match.group('commented'))
        directive = match.group('directive')
        name = match.group('name')

        # Skip standard C header include-guards: the `#define NAME` that
        # pairs with the `#ifndef NAME` opening the file is boilerplate,
        # not a real option.
        if (directive == 'define' and not commented_out
                and name == pending_guard_define):
            pending_guard_define = None
            pending_comment = ''
            i += 1
            continue
        # Any other directive means the guard's define is not coming.
        pending_guard_define = None

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

        records.append({
            'name': name,
            'directive': directive,
            'commented': commented_out,
            'value': value,
            'description': description,
            'depth': sum(1 for is_guard in guard_stack if not is_guard),
        })

    return records


def dedupe_records(records):
    """Collapse repeated definitions of the same option to one record.

    A top-level definition beats one inside a conditional block (the
    former is the general default, the latter a platform-specific
    adjustment). Among top-level definitions an active line beats a
    commented-out alternative, and the last active one wins, matching a
    linear read of the file. When every occurrence is guarded there is no
    general default to prefer, so the first -- the option's primary
    declaration -- is used.

    Each option keeps the position of its first occurrence, so the
    section ordering the UI relies on is unchanged."""
    order = []
    groups = {}
    for record in records:
        if record['name'] not in groups:
            order.append(record['name'])
            groups[record['name']] = []
        groups[record['name']].append(record)

    chosen = []
    for name in order:
        group = groups[name]
        if len(group) == 1:
            chosen.append(group[0])
            continue
        top_level = [r for r in group if r['depth'] == 0]
        if top_level:
            active = [r for r in top_level if not r['commented']]
            chosen.append((active or top_level)[-1])
        else:
            chosen.append(group[0])
    return chosen


def parse_file(path, filename, known_int_values=None):
    if known_int_values is None:
        known_int_values = {}

    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()

    entries = []

    # Evaluate values only after dedupe: a commented-out alternative
    # (dhcp.h's "//#define DHCP_DISC_START_TIMEOUT_SEC 4") would otherwise
    # overwrite the active value in known_int_values purely by being
    # parsed later, corrupting any expression that references it.
    for record in dedupe_records(scan_directives(lines)):
        name = record['name']
        value = record['value']
        description = record['description']
        commented_out = record['commented']
        directive = record['directive']

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
