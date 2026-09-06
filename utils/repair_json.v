module utils

import strings

fn is_hex_digit(b u8) bool {
	return (b >= `0` && b <= `9`) || (b >= `a` && b <= `f`) || (b >= `A` && b <= `F`)
}

fn is_valid_escape(b u8) bool {
	return b == `"` || b == `\\` || b == `/` || b == `b` || b == `f` || b == `n` || b == `r`
		|| b == `t`
}

// repair_json repairs malformed JSON string literals (aligned with pi's repairJson) by:
// - doubling backslashes before invalid escape characters (e.g. Windows paths like E:\test\hyper.html)
// - escaping raw control characters inside string literals
// - auto-closing unclosed string quotes and unclosed curly braces
pub fn repair_json(input string) string {
	mut s := input.trim_space()
	if s.len == 0 {
		return '{}'
	}
	first_c := if s.len > 0 { s[0] } else { u8(0) }
	if first_c != `{` && first_c != `[` && first_c != `"` {
		if s.contains(':') {
			s = '{' + s
		}
	}

	mut repaired := strings.new_builder(s.len + 64)
	mut in_string := false
	mut i := 0

	for i < s.len {
		ch := s[i]
		if !in_string {
			repaired.write_u8(ch)
			if ch == `"` {
				in_string = true
			}
			i++
			continue
		}

		if ch == `"` {
			repaired.write_u8(ch)
			in_string = false
			i++
			continue
		}

		if ch == `\\` {
			if i + 1 >= s.len {
				repaired.write_string('\\\\')
				i++
				continue
			}
			next := s[i + 1]
			if next == `u` {
				if i + 5 < s.len && is_hex_digit(s[i + 2]) && is_hex_digit(s[i + 3])
					&& is_hex_digit(s[i + 4]) && is_hex_digit(s[i + 5]) {
					repaired.write_string(s[i..i + 6])
					i += 6
					continue
				}
			}
			if is_valid_escape(next) {
				repaired.write_u8(`\\`)
				repaired.write_u8(next)
				i += 2
				continue
			}
			// Invalid escape (e.g. \h or \d in Windows path / regex): double the backslash
			repaired.write_string('\\\\')
			i++
			continue
		}

		// Handle raw unescaped control characters inside string literals
		if ch < 0x20 {
			match ch {
				`\n` {
					repaired.write_string('\\n')
				}
				`\r` {
					repaired.write_string('\\r')
				}
				`\t` {
					repaired.write_string('\\t')
				}
				else {
					hex := '${ch:02x}'
					repaired.write_string('\\u00${hex}')
				}
			}
			i++
			continue
		}

		repaired.write_u8(ch)
		i++
	}

	if in_string {
		repaired.write_u8(`"`)
	}

	mut str_result := repaired.str()

	// Balance open braces and brackets
	mut open_braces := 0
	mut open_brackets := 0
	mut in_str := false
	for j := 0; j < str_result.len; j++ {
		c := str_result[j]
		if c == `"` {
			mut backslashes := 0
			mut k := j - 1
			for k >= 0 && str_result[k] == `\\` {
				backslashes++
				k--
			}
			if backslashes % 2 == 0 {
				in_str = !in_str
			}
		} else if !in_str {
			match c {
				`{` { open_braces++ }
				`}` { open_braces-- }
				`[` { open_brackets++ }
				`]` { open_brackets-- }
				else {}
			}
		}
	}

	if open_braces > 0 {
		str_result += '}'.repeat(open_braces)
	}
	if open_brackets > 0 {
		str_result += ']'.repeat(open_brackets)
	}

	return str_result
}
