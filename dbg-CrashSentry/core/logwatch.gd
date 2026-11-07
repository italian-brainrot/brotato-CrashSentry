extends Node
# Follows the engine log (user://logs/godot.log) and the ModLoader log while the
# game runs, so that every error the engine prints gets a second copy in the
# flight recorder - with scene / wave / mod context attached.

const LOG_NAME := "CrashSentry"

var paths := []
var interval_ms := 250
var max_lines_per_pass := 400
var capture_all := false
var recent_max := 40

# live log masking: Brotato's crash reporter disables every mod when a rotated
# engine log has an "ERROR:" line that (also) contains the literal text
# "mods-unpacked". Occurrences that have already been read by this tailer are
# overwritten in place with a same-length mask, so the file keeps its size, the
# engine's own append cursor is untouched, and the rotated copy the reporter reads
# at the next startup has nothing to blame. The unmasked text is already in
# trail.log because _read_new_lines() copies every error line out first.
var sanitize_enabled := false
var sanitize_token := "mods-unpacked"
var sanitize_mask := "mods_unpacked"
var sanitize_max_per_pass := 256
var sanitize_masked_total := 0

var errors_total := 0
var warnings_total := 0
var captured_total := 0
var recent := []
var per_mod := {}
var last_error := ""

var host = null
var mirrors := {}

var _offsets := {}
var _sanitize_offsets := {}
var _accum_ms := 0
var _regex_mod := RegEx.new()
var _regex_error := RegEx.new()
var _regex_warning := RegEx.new()
var _regex_stack := RegEx.new()
var _storm_times := []


func _init() -> void:
	# mods[-_]unpacked so the mask keeps being attributed to its mod even after masking
	var _e1 = _regex_mod.compile("mods[-_]unpacked/([A-Za-z0-9_.-]+)")
	var _e2 = _regex_error.compile("(SCRIPT ERROR|FATAL:|^ERROR:|Program crashed with signal|handle_crash:|END OF BACKTRACE|Attempt to .*freed instance|Stack overflow)")
	var _e3 = _regex_warning.compile("^WARNING:")
	var _e4 = _regex_stack.compile("^\\s+at: ")


func add_file(path: String, mirror_all_lines: bool = false) -> void:
	if not path in paths:
		paths.append(path)
	mirrors[path] = mirror_all_lines


func mods_in_line(line: String) -> Array:
	var found := []
	for m in _regex_mod.search_all(line):
		var mod_id: String = m.get_string(1)
		if mod_id.length() > 0 and not mod_id in found:
			found.append(mod_id)
	return found


func _process(delta: float) -> void:
	_accum_ms += int(delta * 1000.0)
	if _accum_ms < interval_ms:
		return
	_accum_ms = 0
	var new_lines := 0
	for path in paths:
		new_lines += _read_new_lines(path)
	if new_lines > 0:
		_detect_storm()
	if sanitize_enabled:
		var masked := 0
		for path in paths:
			masked += _sanitize_file(path)
		if masked > 0:
			sanitize_masked_total += masked
			if host != null and is_instance_valid(host) and host.has_method("on_sanitized"):
				host.call("on_sanitized", masked)


# ------------------------------------------------------------- log masking


# used once at shutdown: read everything that is still pending, then mask it, so a
# storm at the very end of a session cannot reach the next launch unmasked
func final_pass(max_lines := 4000) -> int:
	var read_lines := 0
	for path in paths:
		var guard := 0
		while guard < 40:
			var got := _read_new_lines_with_cap(path, max_lines)
			read_lines += got
			guard += 1
			if got == 0:
				break
	var patched := 0
	for path in paths:
		patched += _sanitize_file(path)
	return patched


func _read_new_lines_with_cap(path: String, cap: int) -> int:
	var saved := max_lines_per_pass
	max_lines_per_pass = cap
	var got := _read_new_lines(path)
	max_lines_per_pass = saved
	return got




# Rewrites already-consumed bytes of a log file, so this can never race with the
# engine's own write cursor: the scan window stops at the offset _read_new_lines()
# has already read past.
func _sanitize_file(path: String) -> int:
	var f := File.new()
	if f.open(path, File.READ_WRITE) != OK:
		return 0
	var length := f.get_len()
	# only bytes the tailer has already read and copied into the flight recorder:
	# this can never collide with the engine's own append cursor
	var safe_end: int = min2(int(_offsets.get(path, 0)), length)
	if length < int(_offsets.get(path, 0)):
		# the file rotated under us
		_sanitize_offsets.erase(path)
	var pos: int = min2(int(_sanitize_offsets.get(path, 0)), safe_end)
	var token := sanitize_token.to_utf8()
	# Godot 3 has no File.store_raw(); store_string of an ASCII mask writes exactly the
	# same bytes, and the mask is deliberately the same length as the token so the file
	# keeps its size and every other offset stays valid
	if sanitize_token.length() != sanitize_mask.length() or token.size() == 0:
		f.close()
		return 0
	var patched := 0
	var window := 65536
	var rounds := 0
	while pos < safe_end and patched < sanitize_max_per_pass and rounds < 64:
		rounds += 1
		var want: int = min2(window, safe_end - pos)
		if want < token.size():
			# the tail is too short to hold a whole token, pick it up on the next pass
			break
		f.seek(pos)
		var data := f.get_buffer(want)
		var i := 0
		while i + token.size() <= data.size() and patched < sanitize_max_per_pass:
			var hit := true
			for k in range(token.size()):
				if data[i + k] != token[k]:
					hit = false
					break
			if hit:
				f.seek(pos + i)
				f.store_string(sanitize_mask)
				patched += 1
				i += token.size()
			else:
				i += 1
		# step back by token-1 bytes so a token straddling the window border is caught
		# next round (masking is idempotent, rescanning costs nothing)
		var advanced := pos + i - (token.size() - 1)
		if advanced <= pos:
			advanced = pos + 1
		pos = min2(advanced, safe_end)
	_sanitize_offsets[path] = pos
	f.close()
	return patched

func _read_new_lines(path: String) -> int:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return 0
	var length := f.get_len()
	var offset: int = int(_offsets.get(path, 0))
	if length < offset:
		# the engine rotated the log, start over
		offset = 0
		_sanitize_offsets.erase(path)
	f.seek(offset)
	var count := 0
	var pending_stack := ""
	while not f.eof_reached() and count < max_lines_per_pass:
		var line := f.get_line()
		count += 1
		if pending_stack.length() > 0:
			if _regex_stack.search(line) != null:
				pending_stack += " <- " + line.strip_edges()
				continue
			_flush_error(pending_stack)
			pending_stack = ""
		if line.length() == 0:
			continue
		var is_error := _regex_error.search(line) != null
		var is_warning := _regex_warning.search(line) != null
		if is_error:
			pending_stack = line
			_register_error(line)
		elif is_warning:
			warnings_total += 1
			captured_total += 1
			_emit(line, mods_in_line(line))
		elif bool(mirrors.get(path, false)) or capture_all:
			captured_total += 1
			_emit_line(line, mods_in_line(line))
	if pending_stack.length() > 0:
		_flush_error(pending_stack)
	_offsets[path] = f.get_position()
	f.close()
	return count


func _register_error(line: String) -> void:
	errors_total += 1
	captured_total += 1
	last_error = line
	recent.append(line)
	while recent.size() > recent_max:
		recent.pop_front()
	for mod_id in mods_in_line(line):
		per_mod[mod_id] = int(per_mod.get(mod_id, 0)) + 1
	_storm_times.append(Time.get_ticks_msec())


func _flush_error(text: String) -> void:
	_emit(text, mods_in_line(text))


func _emit(text: String, mod_ids: Array) -> void:
	if host != null and is_instance_valid(host) and host.has_method("on_captured_error"):
		host.call("on_captured_error", text, mod_ids)


func _emit_line(text: String, mod_ids: Array) -> void:
	if host != null and is_instance_valid(host) and host.has_method("on_captured_line"):
		host.call("on_captured_line", text, mod_ids)


func _detect_storm() -> void:
	var now := Time.get_ticks_msec()
	var cutoff := now - 5000
	var kept := []
	for t in _storm_times:
		if int(t) > cutoff:
			kept.append(t)
	_storm_times = kept
	if _storm_times.size() >= 120:
		_storm_times.clear()
		_emit("ERROR STORM: %s error lines in the last 5 seconds" % str(errors_total), [])


func top_offenders(count: int) -> Array:
	var pairs := []
	for mod_id in per_mod.keys():
		pairs.append([mod_id, per_mod[mod_id]])
	pairs.sort_custom(SortByCount, "sort")
	var out := []
	for i in range(min2(pairs.size(), count)):
		out.append(pairs[i])
	return out


func min2(a: int, b: int) -> int:
	return a if a < b else b


class SortByCount:
	static func sort(a, b) -> bool:
		return int(a[1]) > int(b[1])
