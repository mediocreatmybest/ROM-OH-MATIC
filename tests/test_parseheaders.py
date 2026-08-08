#!/usr/bin/env python3
"""Unit tests for scripts/parseheaders.py's iPXE config-header parsing."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

from parseheaders import (  # noqa: E402
    eval_c_int_expression,
    is_include_guard,
    parse_file,
    scan_directives,
    strip_comment_markers,
)


class EvalCIntExpressionTests(unittest.TestCase):

    def test_plain_literal(self):
        self.assertEqual(eval_c_int_expression('42', {}), 42)

    def test_arithmetic(self):
        self.assertEqual(eval_c_int_expression('2 * 21', {}), 42)

    def test_parentheses(self):
        self.assertEqual(eval_c_int_expression('(1 + 2) * 3', {}), 9)

    def test_unary_minus(self):
        self.assertEqual(eval_c_int_expression('-5', {}), -5)

    def test_known_macro_reference(self):
        self.assertEqual(
            eval_c_int_expression('2 * BANNER_TIMEOUT', {'BANNER_TIMEOUT': 5}), 10
        )

    def test_unknown_identifier_returns_none(self):
        self.assertIsNone(eval_c_int_expression('UNKNOWN_MACRO', {}))

    def test_c_style_truncating_division_negative(self):
        # C truncates toward zero: -7 / 2 == -3, not Python floor's -4.
        self.assertEqual(eval_c_int_expression('-7 / 2', {}), -3)

    def test_division_by_zero_returns_none(self):
        self.assertIsNone(eval_c_int_expression('1 / 0', {}))

    def test_unsupported_operator_returns_none(self):
        self.assertIsNone(eval_c_int_expression('2 ** 3', {}))

    def test_syntax_error_returns_none(self):
        self.assertIsNone(eval_c_int_expression('2 *', {}))

    def test_nested_crypto_h_style_expression(self):
        # crypto.h's TIMESTAMP_ERROR_MARGIN ( ( 12 * 60 + 30 ) * 60 )
        self.assertEqual(
            eval_c_int_expression('( ( 12 * 60 + 30 ) * 60 )', {}),
            (12 * 60 + 30) * 60,
        )


class StripCommentMarkersTests(unittest.TestCase):

    def test_single_line(self):
        self.assertEqual(strip_comment_markers('/* hello */'), 'hello')

    def test_doc_comment_markers(self):
        self.assertEqual(strip_comment_markers('/** hello */'), 'hello')

    def test_multiline_with_star_continuations(self):
        text = '/*\n * line one\n * line two\n */'
        self.assertEqual(strip_comment_markers(text), 'line one line two')


class ParseFileTests(unittest.TestCase):

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)

    def _write(self, name, content):
        path = os.path.join(self._tmpdir.name, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return path

    def test_boolean_on_by_default(self):
        path = self._write('general.h', '#define FOO\n')
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries, [{
            'file': 'general.h', 'type': 'define', 'name': 'FOO', 'description': 'FOO',
        }])

    def test_boolean_off_by_default(self):
        path = self._write('general.h', '#undef FOO\n')
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['type'], 'undef')

    def test_commented_out_boolean_is_off(self):
        path = self._write('general.h', '//#define FOO\n')
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['type'], 'undef')

    def test_quoted_string_value_strips_quotes(self):
        path = self._write('branding.h', '#define PRODUCT_NAME "iPXE"\n')
        entries = parse_file(path, 'branding.h')
        self.assertEqual(entries[0]['value'], 'iPXE')

    def test_integer_literal_value_is_tracked(self):
        path = self._write('general.h', '#define COUNT 5\n')
        known = {}
        entries = parse_file(path, 'general.h', known)
        self.assertEqual(entries[0]['value'], '5')
        self.assertEqual(known['COUNT'], 5)

    def test_hex_literal_left_as_is_and_not_tracked(self):
        path = self._write('general.h', '#define FLAGS 0x10\n')
        known = {}
        entries = parse_file(path, 'general.h', known)
        self.assertEqual(entries[0]['value'], '0x10')
        self.assertNotIn('FLAGS', known)

    def test_computed_expression_from_literals(self):
        path = self._write('general.h', '#define TIMEOUT ( 2 * 21 )\n')
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['value'], '42')
        self.assertIn('computed from: ( 2 * 21 )', entries[0]['description'])

    def test_macro_reference_chain_across_directives(self):
        content = (
            '#define BASE 5\n'
            '#define DOUBLED ( BASE * 2 )\n'
            '#define QUADRUPLED ( DOUBLED * 2 )\n'
        )
        path = self._write('general.h', content)
        entries = parse_file(path, 'general.h')
        values = {e['name']: e['value'] for e in entries}
        self.assertEqual(values['DOUBLED'], '10')
        self.assertEqual(values['QUADRUPLED'], '20')

    def test_unresolvable_expression_falls_back_to_source(self):
        path = self._write('general.h', '#define TIMEOUT ( 2 * UNKNOWN )\n')
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['value'], '( 2 * UNKNOWN )')

    def test_known_values_shared_across_separate_parse_file_calls(self):
        # main() shares one known_int_values dict across every file in
        # processing order, so a later file can reference an earlier
        # file's macro -- exercise that same cross-file sharing here.
        known = {}
        first = self._write('a.h', '#define BASE 5\n')
        second = self._write('b.h', '#define DOUBLED ( BASE * 2 )\n')
        parse_file(first, 'a.h', known)
        entries_b = parse_file(second, 'b.h', known)
        self.assertEqual(entries_b[0]['value'], '10')

    def test_include_guard_is_skipped(self):
        content = '#ifndef CONFIG_GENERAL_H\n#define CONFIG_GENERAL_H\n#define FOO\n'
        path = self._write('general.h', content)
        entries = parse_file(path, 'general.h')
        names = [e['name'] for e in entries]
        self.assertNotIn('CONFIG_GENERAL_H', names)
        self.assertEqual(names, ['FOO'])

    def test_whitespace_between_hash_and_directive(self):
        # "#   define NAME" is valid C and appears elsewhere in the iPXE
        # tree. An unmatched directive is silently treated as an unrelated
        # line, so failing to match here loses the option altogether.
        content = '#  ifdef SOMETHING\n#   define SPACED\n#  endif\n#\tundef TABBED\n'
        path = self._write('general.h', content)
        entries = parse_file(path, 'general.h')
        self.assertEqual([(e['name'], e['type']) for e in entries],
                         [('SPACED', 'define'), ('TABBED', 'undef')])

    def test_include_guard_with_trailing_comment_is_skipped(self):
        content = ('#ifndef CONFIG_GENERAL_H /* guard */\n'
                   '#define CONFIG_GENERAL_H /* guard */\n'
                   '#define FOO\n#endif\n')
        path = self._write('general.h', content)
        names = [e['name'] for e in parse_file(path, 'general.h')]
        self.assertNotIn('CONFIG_GENERAL_H', names)
        self.assertEqual(names, ['FOO'])

    def test_include_guard_with_blank_line_is_skipped(self):
        content = '#ifndef CONFIG_GENERAL_H\n\n#define CONFIG_GENERAL_H\n#define FOO\n#endif\n'
        path = self._write('general.h', content)
        names = [e['name'] for e in parse_file(path, 'general.h')]
        self.assertNotIn('CONFIG_GENERAL_H', names)
        self.assertEqual(names, ['FOO'])

    def test_function_like_macro_is_skipped(self):
        content = '#define NAMED_CONFIG(_header) <config/CONFIG/_header>\n'
        path = self._write('named.h', content)
        entries = parse_file(path, 'named.h')
        self.assertEqual(entries, [])

    def test_trailing_inline_comment_is_description(self):
        content = '#define TIMEOUT 5 /* how long to wait */\n'
        path = self._write('general.h', content)
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['description'], 'how long to wait')

    def test_multiline_trailing_comment(self):
        content = '#define TIMEOUT 5 /* how long\n   to wait */\n'
        path = self._write('general.h', content)
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['description'], 'how long to wait')

    def test_sticky_preceding_comment_applies_to_consecutive_directives(self):
        content = (
            '/* Product identification strings */\n'
            '#define PRODUCT_NAME ""\n'
            '#define PRODUCT_SHORT_NAME ""\n'
        )
        path = self._write('branding.h', content)
        entries = parse_file(path, 'branding.h')
        self.assertEqual(entries[0]['description'], 'Product identification strings')
        self.assertEqual(entries[1]['description'], 'Product identification strings')

    def test_unrelated_line_resets_pending_comment(self):
        content = (
            '/* Comment for something else */\n'
            '#include <ipxe/foo.h>\n'
            '#define FOO\n'
        )
        path = self._write('general.h', content)
        entries = parse_file(path, 'general.h')
        self.assertEqual(entries[0]['description'], 'FOO')


class ConditionalDepthTests(unittest.TestCase):
    """Directives are tagged with the conditional-block depth they sit at,
    ignoring the file's own include guard."""

    def test_include_guard_recognised(self):
        lines = ['#ifndef CONFIG_FOO_H', '#define CONFIG_FOO_H', '#define BAR']
        self.assertTrue(is_include_guard(lines, 0))

    def test_include_guard_recognised_across_blank_line(self):
        lines = ['#ifndef CONFIG_FOO_H', '', '#define CONFIG_FOO_H']
        self.assertTrue(is_include_guard(lines, 0))

    def test_plain_ifndef_is_not_an_include_guard(self):
        lines = ['#ifndef SOMETHING', '#define OTHER_NAME']
        self.assertFalse(is_include_guard(lines, 0))

    def test_include_guard_does_not_count_as_depth(self):
        lines = ['#ifndef CONFIG_FOO_H', '#define CONFIG_FOO_H',
                 '#define BAR', '#endif']
        records = scan_directives(lines)
        self.assertEqual([r['name'] for r in records], ['BAR'])
        self.assertEqual(records[0]['depth'], 0)

    def test_include_guard_define_skipped_across_blank_line(self):
        # The guard test tolerates a blank line before the #define, so the
        # skip has to as well -- otherwise the guard symbol itself is
        # reported as a build option.
        lines = ['#ifndef CONFIG_FOO_H', '', '#define CONFIG_FOO_H',
                 '#define BAR', '#endif']
        self.assertEqual([r['name'] for r in scan_directives(lines)], ['BAR'])

    def test_nested_ifndef_define_is_not_treated_as_a_file_guard(self):
        # "#ifndef NAME / #define NAME" nested inside a conditional is the
        # ordinary way a header supplies a default without overriding a
        # value already set. Mistaking it for the file's include guard
        # dropped the option entirely and undercounted the depth.
        lines = ['#ifndef CONFIG_FOO_H', '#define CONFIG_FOO_H',
                 '#if defined ( PLATFORM_pcbios )',
                 '#ifndef NEEDS_DEFAULT', '#define NEEDS_DEFAULT', '#endif',
                 '#endif',
                 '#define REAL', '#endif']
        records = scan_directives(lines)
        self.assertEqual([r['name'] for r in records], ['NEEDS_DEFAULT', 'REAL'])
        self.assertEqual(records[0]['depth'], 2)
        self.assertEqual(records[1]['depth'], 0)

    def test_define_matching_a_non_guard_ifndef_is_kept(self):
        # "#ifndef SOMETHING" followed by a define of a DIFFERENT name is
        # ordinary conditional code, and that define is a real option.
        lines = ['#ifndef SOMETHING', '#define OTHER_NAME', '#endif']
        self.assertEqual([r['name'] for r in scan_directives(lines)],
                         ['OTHER_NAME'])

    def test_conditional_block_increases_depth(self):
        lines = ['#define TOP', '#if defined ( PLATFORM_pcbios )',
                 '#define INNER', '#endif', '#define AFTER']
        depths = {r['name']: r['depth'] for r in scan_directives(lines)}
        self.assertEqual(depths, {'TOP': 0, 'INNER': 1, 'AFTER': 0})

    def test_nested_conditionals(self):
        lines = ['#if defined ( A )', '#if defined ( B )', '#define DEEP',
                 '#endif', '#endif']
        self.assertEqual(scan_directives(lines)[0]['depth'], 2)

    def test_else_keeps_same_depth(self):
        lines = ['#if defined ( A )', '#define ONE', '#else',
                 '#define TWO', '#endif']
        depths = {r['name']: r['depth'] for r in scan_directives(lines)}
        self.assertEqual(depths, {'ONE': 1, 'TWO': 1})

    def test_ifdef_counts_as_conditional(self):
        lines = ['#ifdef SOMETHING', '#define INNER', '#endif']
        self.assertEqual(scan_directives(lines)[0]['depth'], 1)


class DedupeTests(unittest.TestCase):
    """The same option name can appear more than once in one header; only
    one entry should reach the UI."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)

    def _parse(self, name, content, known=None):
        path = os.path.join(self._tmpdir.name, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return parse_file(path, name, known)

    def test_top_level_beats_platform_guarded_undef(self):
        # console.h's real shape: a general default, then a pcbios block
        # that turns it off again.
        content = (
            '#define CONSOLE_FRAMEBUFFER\n'
            '#if defined ( PLATFORM_pcbios )\n'
            '#undef CONSOLE_FRAMEBUFFER\n'
            '#endif\n'
        )
        entries = self._parse('console.h', content)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['type'], 'define')

    def test_all_guarded_uses_first_occurrence(self):
        # CONSOLE_SERIAL: off inside one guard, on inside a narrower one.
        content = (
            '#if ! defined ( SERIAL_NULL )\n'
            '//#define CONSOLE_SERIAL\n'
            '#endif\n'
            '#if defined ( CONSOLE_SBI )\n'
            '#define CONSOLE_SERIAL\n'
            '#endif\n'
        )
        entries = self._parse('console.h', content)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['type'], 'undef')

    def test_active_value_beats_commented_alternative(self):
        # dhcp.h documents an alternative value on a commented-out line.
        content = (
            '#define DHCP_DISC_START_TIMEOUT_SEC\t1\n'
            '//#define DHCP_DISC_START_TIMEOUT_SEC\t4\t/* as per PXE spec */\n'
        )
        entries = self._parse('dhcp.h', content)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['value'], '1')

    def test_commented_alternative_does_not_poison_known_values(self):
        content = (
            '#define TIMEOUT\t1\n'
            '//#define TIMEOUT\t4\t/* as per PXE spec */\n'
        )
        known = {}
        self._parse('dhcp.h', content, known)
        self.assertEqual(known['TIMEOUT'], 1)

    def test_lone_commented_value_is_still_offered(self):
        # No active counterpart: keep it, so the option stays settable.
        content = '//#define OPTIONAL_THING\t42\n'
        entries = self._parse('general.h', content)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['value'], '42')

    def test_last_top_level_definition_wins(self):
        content = '#define THING\t1\n#define THING\t2\n'
        entries = self._parse('general.h', content)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['value'], '2')

    def test_deduped_option_keeps_first_occurrence_position(self):
        # The UI inserts section headings by walking entries in order, so
        # collapsing a later duplicate must not move the option.
        content = (
            '#define ALPHA\n'
            '#define BETA\n'
            '#if defined ( PLATFORM_pcbios )\n'
            '#undef ALPHA\n'
            '#endif\n'
            '#define GAMMA\n'
        )
        entries = self._parse('general.h', content)
        self.assertEqual([e['name'] for e in entries], ['ALPHA', 'BETA', 'GAMMA'])

    def test_distinct_options_are_untouched(self):
        content = '#define ONE\n#undef TWO\n//#define THREE\n'
        entries = self._parse('general.h', content)
        self.assertEqual([e['name'] for e in entries], ['ONE', 'TWO', 'THREE'])
        self.assertEqual([e['type'] for e in entries],
                         ['define', 'undef', 'undef'])


if __name__ == '__main__':
    unittest.main()
