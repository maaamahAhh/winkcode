module tui

import term.ui as termui

// C interop declarations for Windows console API.
// Only compiled on Windows; on other platforms these declarations are omitted.
$if windows {
	fn C.GetStdHandle(n_std_handle int) voidptr
	fn C.SetConsoleMode(h_console_input voidptr, dw_mode u32) bool
}

// patch_console_mode fixes the console input mode after term.ui init.
// term.ui's Windows init overwrites ENABLE_EXTENDED_FLAGS and omits
// ENABLE_PROCESSED_INPUT, which breaks IME composition.
pub fn patch_console_mode() {
	$if windows {
		hstdin := C.GetStdHandle(-10)
		if hstdin == unsafe { nil } {
			return
		}
		mode := u32(0x0001 | 0x0080 | 0x0008 | 0x0010)
		C.SetConsoleMode(hstdin, mode)
	}
}

// is_cjk_event detects fake key events produced by CJK IME input.
// term.ui maps the low byte of a Unicode CJK character to a KeyCode,
// which can incorrectly trigger .escape or other control keys.
pub fn is_cjk_event(e &termui.Event) bool {
	$if windows {
		return e.typ == .key_down && e.utf8.len > 1
	} $else {
		return false
	}
}
