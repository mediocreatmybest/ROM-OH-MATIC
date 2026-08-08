#!/usr/bin/env python3
"""Unit tests for scripts/parseheaders.py's iPXE config-header parsing."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

from parseheaders import (  # noqa: E402
    eval_c_int_expression,
    parse_file,
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


if __name__ == '__main__':
    unittest.main()
