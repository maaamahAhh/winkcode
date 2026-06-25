module tui

// Selector state management
// Generic selectable list with fuzzy filter

pub struct SelectorItem {
	value      string
	label      string
	badge      string
	is_current bool
}

struct SelectorState {
mut:
	items      []SelectorItem
	filtered   []SelectorItem
	selected   int
	filter     []rune
	on_confirm fn (SelectorItem) = unsafe { nil }
	on_toggle  fn () = unsafe { nil }
	title      string
}

pub const selector_max_visible = 8

pub fn (mut s SelectorState) open(items []SelectorItem, title string, on_confirm fn (SelectorItem), on_toggle fn ()) {
	s.items = items
	s.filtered = items.clone()
	s.filter = []rune{}
	s.selected = 0
	s.on_confirm = on_confirm
	s.on_toggle = on_toggle
	s.title = title
	for i, item in s.filtered {
		if item.is_current {
			s.selected = i
			break
		}
	}
}

pub fn (mut s SelectorState) close() {
	s.items = []SelectorItem{}
	s.filtered = []SelectorItem{}
	s.filter = []rune{}
	s.selected = 0
	s.on_confirm = unsafe { nil }
	s.on_toggle = unsafe { nil }
	s.title = ''
}

pub fn (mut s SelectorState) toggle() {
	if s.filtered.len == 0 || s.on_toggle == unsafe { nil } {
		return
	}
	s.on_toggle()
}

pub fn (mut s SelectorState) update_filter(query string) {
	mut filtered := []SelectorItem{}
	for item in s.items {
		if fuzzy_match(query, item.value) || fuzzy_match(query, item.label) || fuzzy_match(query, item.badge) {
			filtered << item
		}
	}
	s.filtered = filtered
	if s.selected >= filtered.len {
		s.selected = if filtered.len > 0 { filtered.len - 1 } else { 0 }
	}
}

pub fn (mut s SelectorState) confirm() {
	if s.filtered.len == 0 || s.on_confirm == unsafe { nil } {
		return
	}
	item := s.filtered[s.selected]
	s.on_confirm(item)
}

// === Fuzzy matching ===

pub fn fuzzy_match(query string, text string) bool {
	if query.len == 0 {
		return true
	}
	ql := query.to_lower()
	tl := text.to_lower()
	mut qi := 0
	for ti := 0; ti < tl.len && qi < ql.len; ti++ {
		if tl[ti] == ql[qi] {
			qi++
		}
	}
	return qi >= ql.len
}
