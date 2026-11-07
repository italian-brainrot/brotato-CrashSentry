extends Node
# Flight recorder. Writes a trail + heartbeat that keep surviving hard crashes,
# and owns the "session marker" used to detect a session that never shut down.

const LOG_NAME := "CrashSentry"

const MAX_TRAIL_BYTES := 700000
const TRAIL_KEEP_BYTES := 220000
const MAX_REPORTS := 12
const TAIL_WINDOW_BYTES := 220000

var root_dir := "user://logs/sentry"
var reports_dir := "user://logs/sentry/reports"
var trail_path := "user://logs/sentry/trail.log"
var heartbeat_path := "user://logs/sentry/heartbeat.json"
var marker_path := "user://logs/sentry/session.marker"
var freeze_path := "user://logs/sentry/freeze.log"

var max_memory_lines := 400
var flush_interval_ms := 200
var freeze_ms := 5000
var warmup_ms := 15000
var use_thread := true

var session_id := ""
var lines := []
var sequence := 0
var previous_heartbeat := ""
var trail_start_size := 0

var host = null

var _pending := ""
var _started_unix := 0
var _last_main_tick := 0
var _last_flush_tick := 0
var _last_heartbeat_ms := 0
var _heartbeat_text := "{}"
var _thread = null
var _mutex = null
var _thread_alive := false
var _thread_is_running := false
var _closed := false


func setup() -> void:
	session_id = "%s-%s" % [str(OS.get_process_id()), Time.get_unix_time_from_system()]
	_started_unix = Time.get_unix_time_from_system()
	_ensure_dir(root_dir)
	_ensure_dir(reports_dir)
	_rotate_trail_if_needed()
	trail_start_size = _file_size(trail_path)
	previous_heartbeat = _slurp(heartbeat_path)
	sequence = 0
	_last_main_tick = Time.get_ticks_msec()
	_last_flush_tick = Time.get_ticks_msec()


# ---------------------------------------------------------------- public API


func trail(message: String, level: String = "INFO") -> void:
	if _closed:
		return
	sequence += 1
	var context := ""
	if host != null and is_instance_valid(host) and host.has_method("context_string"):
		context = str(host.call("context_string"))
	var entry := "%06d %s %s %s | %s" % [
		sequence,
		Time.get_time_string_from_system() + "." + _millis_string(),
		_lpad(level, 7),
		context,
		message,
	]
	lines.append(entry)
	while lines.size() > max_memory_lines:
		lines.pop_front()
	# Written straight away from the calling thread. An event that only lives in
	# RAM is useless after a crash, and this is the whole point of the recorder.
	_append_text_locked(trail_path, entry + "\n")


# only used for lines produced by the watchdog thread itself
func flush(force: bool = false) -> void:
	var now := Time.get_ticks_msec()
	if not force and now - _last_flush_tick < flush_interval_ms:
		return
	_last_flush_tick = now
	var chunk := _take_pending()
	if chunk.length() > 0:
		_append_text_locked(trail_path, chunk)


func set_heartbeat(text: String) -> void:
	_heartbeat_text = text


func note_main_tick() -> void:
	_last_main_tick = Time.get_ticks_msec()


func last_main_tick_age_ms() -> int:
	return Time.get_ticks_msec() - _last_main_tick


func ensure_dir(path: String) -> void:
	_ensure_dir(path)


func file_exists(path: String) -> bool:
	return File.new().file_exists(path)


func remove_file(path: String) -> void:
	if file_exists(path):
		var d := Directory.new()
		var _e = d.remove(path)


func marker_exists() -> bool:
	return File.new().file_exists(marker_path)


func read_marker() -> Dictionary:
	var f := File.new()
	if f.open(marker_path, File.READ) != OK:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = parse_json(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func write_marker() -> void:
	_write_text(marker_path, JSON.print({
		"session": session_id,
		"pid": OS.get_process_id(),
		"started_unix": _started_unix,
		"engine": Engine.get_version_info().get("string", "unknown"),
		"clean": false,
	}, "\t"))


func close_marker_clean() -> void:
	_write_text(marker_path, JSON.print({
		"session": session_id,
		"pid": OS.get_process_id(),
		"started_unix": _started_unix,
		"ended_unix": Time.get_unix_time_from_system(),
		"clean": true,
	}, "\t"))


func remove_marker() -> void:
	var d := Directory.new()
	if d.file_exists(marker_path):
		var _e = d.remove(marker_path)


func start_session_entry(text: String) -> void:
	trail("=== session %s pid %s started ===" % [session_id, str(OS.get_process_id())], "SESSION")
	if text.length() > 0:
		trail(text, "SESSION")


func end_session_entry() -> void:
	trail("=== session %s ending (clean shutdown) ===" % session_id, "SESSION")
	flush(true)


func shutdown() -> void:
	if _closed:
		return
	_closed = true
	_stop_thread()
	flush(true)


func new_report_file_name(prefix: String) -> String:
	return reports_dir.plus_file("%s-%s-%05d.txt" % [
		prefix, Time.get_time_string_from_system().replace(":", "."), sequence
	])


func prune_reports() -> void:
	_prune_reports()


func write_report(path: String, text: String) -> bool:
	_ensure_dir(reports_dir)
	_write_text(path, text)
	_prune_reports()
	return File.new().file_exists(path)


func read_tail(path: String, max_lines: int) -> Array:
	var out := []
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return out
	# bounded: never read a whole multi-megabyte log into memory, only the tail
	var size := f.get_len()
	var window := TAIL_WINDOW_BYTES
	var skipped_partial := false
	if size > window:
		f.seek(size - window)
		f.get_line()
		skipped_partial = true
	var all := []
	while not f.eof_reached():
		all.append(f.get_line())
		if all.size() > max_lines * 4 + 200:
			# protect against a log made of one huge line
			all.resize(max_lines * 4 + 200)
			break
	f.close()
	var start_index: int = all.size() - max_lines
	if start_index < 0:
		start_index = 0
	for i in range(start_index, all.size()):
		var line := str(all[i])
		if line.length() == 0 or (skipped_partial and i == 0):
			continue
		out.append(line)
	return out


## The entries the *previous* session left in trail.log, i.e. everything that was
## on disk before this session appended a single byte.
func trail_tail_previous(max_lines: int) -> Array:
	var f := File.new()
	if f.open(trail_path, File.READ) != OK:
		return []
	var bytes := trail_start_size
	if bytes <= 0:
		f.close()
		return []
	if bytes > f.get_len():
		bytes = f.get_len()
	var text := f.get_buffer(bytes).get_string_from_utf8()
	f.close()
	var all := text.split("\n", false)
	var start_index: int = all.size() - max_lines
	if start_index < 0:
		start_index = 0
	var out := []
	for i in range(start_index, all.size()):
		out.append(all[i])
	return out


func trail_tail(max_lines: int) -> Array:
	var out := lines.duplicate()
	if out.size() > max_lines:
		out = out.slice(out.size() - max_lines, out.size())
	return out


# ------------------------------------------------------------------ thread


func start_thread() -> bool:
	if not use_thread or _thread != null:
		return false
	if not OS.can_use_threads():
		return false
	_mutex = Mutex.new()
	_thread = Thread.new()
	_thread_alive = true
	var err = _thread.start(self, "_thread_loop")
	if err != OK or not _thread.is_active():
		_thread = null
		_thread_alive = false
		use_thread = false
		return false
	_thread_is_running = true
	return true


func _stop_thread() -> void:
	_thread_alive = false
	if _thread != null and _thread.is_active():
		_thread.wait_to_finish()
	_thread_is_running = false
	_thread = null


func _thread_loop() -> void:
	# NOTE: only file IO and mutex-protected strings here. Never touch the scene tree.
	var counter := 0
	while _thread_alive:
		OS.delay_msec(50)
		counter += 1
		var age := Time.get_ticks_msec() - _last_main_tick_snapshot()
		var warm := Time.get_ticks_msec() > warmup_ms and _heartbeat_text != "{}"
		if age > freeze_ms and counter % 10 == 0 and warm:
			_pending_mutex_append(
				"WATCHDOG main loop unresponsive for %s ms. Last known state: %s" % [str(age), _heartbeat_text]
			)
			_append_text_locked(freeze_path, "%s FREEZE after %s ms | %s\n" % [
				Time.get_time_string_from_system(), str(age), _heartbeat_text
			])
		var chunk := _take_pending()
		if chunk.length() > 0:
			_append_text_locked(trail_path, chunk)
		if counter % 20 == 0:
			_write_text(heartbeat_path, _heartbeat_text)
	# final flush from the thread itself, so a clean quit also lands on disk
	var chunk := _take_pending()
	if chunk.length() > 0:
		_append_text_locked(trail_path, chunk)
	_write_text(heartbeat_path, _heartbeat_text)


func _last_main_tick_snapshot() -> int:
	if _mutex == null:
		return _last_main_tick
	_mutex.lock()
	var value: int = _last_main_tick
	_mutex.unlock()
	return value


func _pending_mutex_append(text: String) -> void:
	if _mutex != null:
		_mutex.lock()
	_pending += text + "\n"
	if _mutex != null:
		_mutex.unlock()


func _take_pending() -> String:
	if _mutex == null:
		var direct := _pending
		_pending = ""
		return direct
	_mutex.lock()
	var chunk := _pending
	_pending = ""
	_mutex.unlock()
	return chunk


func _process(_delta: float) -> void:
	if _thread_is_running:
		if _thread != null and not _thread.is_active():
			# the thread died for some reason: take over from the main thread
			_thread_is_running = false
		else:
			return
	flush(false)
	var now := Time.get_ticks_msec()
	if now - _last_heartbeat_ms > 1000:
		_last_heartbeat_ms = now
		_write_text(heartbeat_path, _heartbeat_text)


# -------------------------------------------------------------------- files


# Godot File objects are not thread safe: every write takes the same mutex, no
# call nests inside another one.
func _append_text_locked(path: String, text: String) -> void:
	if _mutex != null:
		_mutex.lock()
	_append_text(path, text)
	if _mutex != null:
		_mutex.unlock()


func _file_size(path: String) -> int:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return 0
	var size := f.get_len()
	f.close()
	return size


func _slurp(path: String) -> String:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _ensure_dir(path: String) -> void:
	var d := Directory.new()
	if not d.dir_exists(path):
		var _e = d.make_dir_recursive(path)


func _append_text(path: String, text: String) -> void:
	var f := File.new()
	var err := f.open(path, File.READ_WRITE)
	if err != OK:
		err = f.open(path, File.WRITE)
		if err != OK:
			return
	f.seek_end()
	f.store_string(text)
	f.close()


func _write_text(path: String, text: String) -> void:
	var f := File.new()
	if f.open(path, File.WRITE) != OK:
		return
	f.store_string(text)
	f.close()


func _rotate_trail_if_needed() -> void:
	var f := File.new()
	if f.open(trail_path, File.READ) != OK:
		return
	var size := f.get_len()
	if size < MAX_TRAIL_BYTES:
		f.close()
		return
	var text := f.get_as_text()
	f.close()
	if text.length() > TRAIL_KEEP_BYTES:
		text = text.right(TRAIL_KEEP_BYTES)
	_write_text(trail_path, "[...] older trail entries dropped [...]\n" + text)


func _prune_reports() -> void:
	var d := Directory.new()
	if d.open(reports_dir) != OK:
		return
	var names := []
	var _e = d.list_dir_begin(true, true)
	var fname := d.get_next()
	while fname.length() > 0:
		if not d.current_is_dir() and fname.get_extension() == "txt":
			names.append(fname)
		fname = d.get_next()
	d.list_dir_end()
	names.sort()
	while names.size() > MAX_REPORTS:
		var oldest: String = names.pop_front()
		var _r = d.remove(reports_dir.plus_file(oldest))


func _lpad(value: String, width: int) -> String:
	var out := value
	while out.length() < width:
		out = " " + out
	return out


func _millis_string() -> String:
	return "%03d" % (Time.get_ticks_msec() % 1000)
