module tests

import tui

fn test_selection_normalization_top_to_bottom() {
	mut sel := tui.SelectionState{}
	sel.start(2, 5)
	sel.drag(4, 12)
	sel.finish(4, 12)

	assert sel.has_sel == true
	norm := sel.normalized() or {
		assert false
		return
	}
	assert norm.top_line == 2
	assert norm.top_col == 5
	assert norm.bot_line == 4
	assert norm.bot_col == 12
}

fn test_selection_normalization_bottom_to_top() {
	mut sel := tui.SelectionState{}
	sel.start(4, 12)
	sel.drag(2, 5)
	sel.finish(2, 5)

	assert sel.has_sel == true
	norm := sel.normalized() or {
		assert false
		return
	}
	assert norm.top_line == 2
	assert norm.top_col == 5
	assert norm.bot_line == 4
	assert norm.bot_col == 12
}

fn test_single_click_clears_selection() {
	mut sel := tui.SelectionState{}
	sel.start(3, 10)
	sel.finish(3, 10)

	assert sel.has_sel == false
	assert sel.normalized() == none
}

fn test_col_range_for_single_line_and_multiline() {
	norm := tui.NormalizedSelection{
		top_line: 2
		top_col:  5
		bot_line: 4
		bot_col:  15
	}

	// Line before selection
	assert norm.col_range_for_line(1, 80) == none

	// First line of selection (from col 5 to end of line 80)
	c1 := norm.col_range_for_line(2, 80) or { tui.ColRange{0, 0} }
	assert c1.start == 5
	assert c1.end == 80

	// Middle line of selection (full line 1..80)
	c2 := norm.col_range_for_line(3, 80) or { tui.ColRange{0, 0} }
	assert c2.start == 1
	assert c2.end == 80

	// Last line of selection (from 1 to col 15)
	c3 := norm.col_range_for_line(4, 80) or { tui.ColRange{0, 0} }
	assert c3.start == 1
	assert c3.end == 15

	// Line after selection
	assert norm.col_range_for_line(5, 80) == none
}

fn test_extract_line_selection() {
	text := '  const answer = 42;'
	// Columns:
	// ' ' (1), ' ' (2), 'c' (3), 'o' (4), 'n' (5), 's' (6), 't' (7)
	// Select 'const': col 3 to 7
	extracted := tui.extract_line_selection(text, 3, 7)
	assert extracted == 'const'

	// Unicode / CJK handling
	cjk_text := '  你好世界 hello'
	// ' ' (1), ' ' (2), '你' (3-4), '好' (5-6), '世' (7-8), '界' (9-10), ' ' (11), 'h' (12)...
	cjk_extracted := tui.extract_line_selection(cjk_text, 3, 6)
	assert cjk_extracted == '你好'
}
