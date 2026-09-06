module utils

// safe_truncate cuts text to at most max_bytes while keeping UTF-8
// multi-byte sequences intact (byte slicing a string can otherwise split
// a character in half, producing invalid UTF-8 that crashes rendering).
pub fn safe_truncate(text string, max_bytes int) string {
	if text.len <= max_bytes {
		return text
	}
	mut cut := max_bytes
	for cut > 0 && (text[cut] & 0xc0) == 0x80 {
		cut--
	}
	return text[..cut]
}
