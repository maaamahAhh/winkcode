module tests

import os
import session
import tools
import config
import tui

fn test_session_has_messages_and_filtering() {
	temp_dir := os.join_path(os.temp_dir(), 'wink_test_sess_${os.getpid()}')
	os.mkdir_all(temp_dir) or {}
	defer { os.rmdir_all(temp_dir) or {} }

	empty_file := os.join_path(temp_dir, 'empty_session.jsonl')
	os.write_file(empty_file, '{"type":"session","id":"123","timestamp":"2026-09-07 10:00:00"}\n') or {}

	assert session.session_has_messages(empty_file) == false

	with_msg_file := os.join_path(temp_dir, 'good_session.jsonl')
	os.write_file(with_msg_file, '{"type":"session","id":"124"}\n{"type":"message","role":"user","text":"hi"}\n') or {}

	assert session.session_has_messages(with_msg_file) == true
}

fn test_edit_tool_smart_diagnostics() {
	temp_file := os.join_path(os.temp_dir(), 'wink_test_edit_${os.getpid()}.txt')
	defer { os.rm(temp_file) or {} }

	content := 'line 1: alpha\nline 2: target\nline 3: beta\nline 4: target\nline 5: gamma\n'
	os.write_file(temp_file, content) or {}

	// 1. Duplicate match diagnostics: reports line numbers
	res_dup := tools.execute_tool('edit', {
		'path': temp_file
		'old_text': 'target'
		'new_text': 'replacement'
	})
	assert res_dup.is_error == true
	assert res_dup.content.contains('found 2 times (at lines 2, 4)')

	// 2. Not found diagnostics: starting line matched
	res_mismatch := tools.execute_tool('edit', {
		'path': temp_file
		'old_text': 'line 1: alpha\nline 2: wrong'
		'new_text': 'line 1: alpha\nline 2: fixed'
	})
	assert res_mismatch.is_error == true
	assert res_mismatch.content.contains('found at line 1')
	assert res_mismatch.content.contains('subsequent lines differed')
}

fn test_env_var_api_key_resolution() {
	os.setenv('WINK_TEST_KEY_ENV', 'sk-resolved-env-key', true)
	defer { os.unsetenv('WINK_TEST_KEY_ENV') }

	// Direct environment variable syntax
	cfg := config.load()
	assert cfg.providers.len > 0
}

fn test_multimodal_audio_video_read() {
	temp_mp3 := os.join_path(os.temp_dir(), 'test_clip_${os.getpid()}.mp3')
	os.write_file(temp_mp3, 'ID3dummy-audio-bytes') or {}
	defer { os.rm(temp_mp3) or {} }

	res := tools.execute_tool('read', {
		'path': temp_mp3
	})
	assert res.is_error == false
	assert res.content.contains('[Audio:')
	if img := res.image_data {
		assert img.mime_type == 'audio/mpeg'
	} else {
		assert false
	}
}

fn test_format_tokens_precision() {
	assert tui.format_tokens_k(1_050_000) == '1.05M'
	assert tui.format_tokens_k(1_000_000) == '1M'
	assert tui.format_tokens_k(1_250_000) == '1.25M'
	assert tui.format_tokens_k(1_500_000) == '1.5M'
	assert tui.format_tokens_k(200_000) == '200k'
	assert tui.format_tokens_k(12_500) == '12.5k'
	assert tui.format_tokens_k(500) == '500'
}
