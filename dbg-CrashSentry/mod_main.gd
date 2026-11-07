extends Node
# CrashSentry - crash forensics and debug helpers for Brotato mods.
#
# What it does, in one paragraph: it keeps a flight recorder (user://logs/sentry)
# that survives hard crashes, follows the engine / mod-loader / Brotato logs while
# you play, tags every error with the mod that owns the file in the message, and
# writes a full post-mortem report the next time the game starts if the previous
# session never ran its shutdown code.

const MOD_ID := "dbg-CrashSentry"
const LOG_NAME := "CrashSentry"

# Every step of the startup path prints one of these *before* it runs. print() lands
# on stdout (so it shows up in Steam's console-linux.txt) and in user://logs/godot.log,
# and it is the only thing that survives a hard crash: the last "csentry step" line in
# the log is where the process died. 1.2.1 had no breadcrumbs, which is why a crash
# inside the log neutralizing code looked like an unexplained startup crash.
const STEP_TAG := "csentry step: "
const MAX_LOGS_MOVED_PER_SESSION := 6
const MAX_LOG_SCAN_BYTES := 4000000

const Recorder = preload("res://mods-unpacked/dbg-CrashSentry/core/recorder.gd")
const LogWatch = preload("res://mods-unpacked/dbg-CrashSentry/core/logwatch.gd")
const Reports = preload("res://mods-unpacked/dbg-CrashSentry/core/reports.gd")
const Overlay = preload("res://mods-unpacked/dbg-CrashSentry/core/overlay.gd")

const PAUSE_ALWAYS := 2  # Node.PAUSE_MODE_ALWAYS, kept as a number for engine-build safety

const DEFAULTS := {
	"boost_mod_log_level": true,
	"tail_engine_log": true,
	"watchdog_thread": true,
	"freeze_ms": 5000,
	"frame_hitch_ms": 500,
	"freed_watchdog": true,
	"overlay_enabled": false,
	"report_errors_in_overlay": true,
	"alert_on_crash_found": true,
	"memory_log_seconds": 20,
	"keep_mods_enabled": true,
	"sanitize_engine_log": true,
}

var opts := {}
var config_source := "built-in defaults"

var recorder = null
var logwatch = null
var reports = null
var overlay = null

var started_ticks := 0
var crash_report_path := ""
var masked_total := 0
var _steps_written := 0

var _scene_name := "?"
var _last_wave := -1
var _last_danger := -1
var _last_endless = null
var _last_mem_ms := 0
var _last_heartbeat_ms := 0
var _last_overlay_ms := 0
var _last_watch_ms := 0
var _previous_marker := {}
var _cached_tree = null
var _watched := {}
var _watch_log := []
var _config_warning := false


# ---------------------------------------------------------------- lifecycle


func _init() -> void:
	_pre_step("_init enter")
	started_ticks = Time.get_ticks_msec()
	_pre_step("read_options begin")
	_read_options()
	_pre_step("options from %s" % config_source)
	if bool(opts.boost_mod_log_level) and ModLoaderStore != null:
		# ModLoaderStore.ml_options is a plain Dictionary, this takes effect at once.
		_pre_step("boost mod log level begin")
		ModLoaderStore.ml_options.log_level = 3
		_pre_step("boost mod log level done")

	_pre_step("recorder new/setup begin")
	recorder = Recorder.new()
	recorder.name = "Recorder"
	recorder.freeze_ms = int(opts.freeze_ms)
	recorder.warmup_ms = 15000
	recorder.setup()
	recorder.host = self
	_pre_step("recorder setup done")

	# the marker of a session that never shut down is kept until _ready(), when
	# the scene tree exists and the report can actually be built
	_pre_step("read previous marker begin")
	_previous_marker = _read_previous_marker()
	_pre_step("write marker begin")
	recorder.write_marker()
	_pre_step("write marker done, _init leave")
	# 1.2.1 did the log neutralizing here, inside the mod's _init(), and that is
	# the worst possible place: it is deep inside the mod loader's init loop, and
	# if it dies there the game dies with it and nothing at all gets logged.
	# It now runs from _ready() instead, with a breadcrumb around every file op.


func _ready() -> void:
	set_pause_mode(PAUSE_ALWAYS)
	add_child(recorder)

	logwatch = LogWatch.new()
	logwatch.name = "LogWatch"
	logwatch.set_pause_mode(PAUSE_ALWAYS)
	logwatch.host = self
	add_child(logwatch)

	if bool(opts.tail_engine_log):
		var log_path := str(_setting("logging/file_logging/log_path", "user://logs/godot.log"))
		logwatch.add_file(log_path, false)
		logwatch.add_file("user://logs/modloader.log", false)
		if bool(opts.sanitize_engine_log):
			logwatch.sanitize_enabled = true
			_step("live log masking enabled (%s -> %s)" % [logwatch.sanitize_token, logwatch.sanitize_mask])

	reports = Reports.new()
	reports.name = "Reports"
	reports.init(self, recorder, logwatch)

	_previous_session_forensics()

	# now that the tree exists and the recorder is writing, deal with the logs the
	# game's own crash reporter would otherwise use to switch every mod off
	_neutralize_mod_disabling()

	overlay = Overlay.new()
	overlay.name = "Overlay"
	overlay.show_errors = bool(opts.report_errors_in_overlay)
	add_child(overlay)

	recorder.set_heartbeat(JSON.print(heartbeat_dict()))

	if bool(opts.watchdog_thread):
		if not recorder.start_thread():
			recorder.trail("watchdog thread unavailable, falling back to main-thread flushing", "WARN")

	recorder.start_session_entry("config(%s): %s" % [config_source, JSON.print(opts)])
	ModLoaderLog.info(
		"Flight recorder ready: %s | reports: %s | F8 overlay, F9 dump, F10 copy, F7 open reports"
		% [ProjectSettings.globalize_path(recorder.trail_path), ProjectSettings.globalize_path(recorder.reports_dir)],
		LOG_NAME
	)
	if crash_report_path.length() > 0:
		ModLoaderLog.warning(
			"The previous session did not shut down cleanly. Report: %s" % crash_report_path, LOG_NAME
		)
		if bool(opts.alert_on_crash_found):
			overlay.toast(
				"[color=#ef5350]the previous session did not shut down cleanly[/color]\nreport: %s\nF8 opens the overlay"
				% crash_report_path, 14.0
			)
	overlay.visible = bool(opts.overlay_enabled)


func _disable() -> void:
	ModLoaderLog.info("Disabling CrashSentry", LOG_NAME)


func _exit_tree() -> void:
	if recorder == null:
		return
	if logwatch != null and is_instance_valid(logwatch) and bool(opts.sanitize_engine_log):
		# make sure a storm that happened at the very end of the session is masked
		# before the engine rotates the log at the next startup
		var patched = int(logwatch.call("final_pass"))
		if patched > 0:
			masked_total += patched
			recorder.trail("masked %s more occurrence(s) during shutdown" % str(patched), "SENTRY")
	recorder.trail("exiting tree (clean shutdown path)", "SESSION")
	recorder.end_session_entry()
	recorder.close_marker_clean()
	recorder.shutdown()


# ------------------------------------------------------- previous session


func _is_true(value) -> bool:
	if value == null:
		return false
	if typeof(value) == TYPE_BOOL:
		return value
	return str(value) == "true"


func _read_previous_marker() -> Dictionary:
	if not recorder.marker_exists():
		return {}
	var marker = recorder.read_marker()
	if marker.empty() or bool(marker.get("clean", false)):
		return {}
	return marker


func _previous_session_forensics() -> void:
	var marker = _previous_marker
	if marker.empty():
		return
	recorder.trail(
		"PREVIOUS SESSION DID NOT SHUT DOWN CLEANLY (marker %s). Reconstructing what happened..."
		% str(marker.get("session", "?")), "CRASH"
	)
	var minimal := _is_true(reports.call("check_previous_attempt"))
	reports.mark_attempt()
	crash_report_path = reports.crash_report(
		marker,
		recorder.previous_heartbeat,
		_previous_log_tails(int(marker.get("started_unix", 0))),
		recorder.trail_tail_previous(150),
		recorder.read_tail(recorder.freeze_path, 60),
		minimal
	)
	recorder.trail("crash report written: %s" % ProjectSettings.globalize_path(crash_report_path), "CRASH")


# Brotato's own crash reporter (singletons/crash_reporter.gd, its constant pool was
# checked in 1.2.0.1) picks the newest rotated engine log whose name matches
# godot<YYYY-MM-DD>T<HH.MM.SS>.log and looks for an "ERROR:" line that itself, or
# the line before it, contains the literal text "mods-unpacked". When it finds one it
# names that mod as the crashed one and switches mods off for the launch
# ("Mods are currently disabled" / CRASH_RECOVERY_MESSAGE_*). A mod that merely fails
# to *compile* trips it, so a mod list can quietly empty itself after every run.
#
# Two defences, both with a breadcrumb around every file operation:
#  1. live masking (sanitize_engine_log, done by logwatch): every already-read
#     occurrence of "mods-unpacked" in the live logs is overwritten in place with
#     the same-length "mods_unpacked". The engine's own write cursor is never
#     touched, the file keeps its size, and when the engine rotates it at the next
#     startup the reporter has nothing to blame. The original text is preserved in
#     trail.log, because logwatch copies every error line there with mod attribution
#     *before* masking it.
#  2. evidence move (keep_mods_enabled): a rotated log that is already blamed (from a
#     session that ran before the masking, or before this mod was installed) gets
#     renamed into logs/sentry/evidence/. One rename() instead of 1.2.1's copy()+remove()
#     of a 200 KB file: atomic, cheap, and nothing is ever deleted.
func _neutralize_mod_disabling() -> void:
	if not bool(opts.keep_mods_enabled):
		_step("keep_mods_enabled off, rotated logs left alone")
		return
	_step("list rotated logs begin")
	var candidates := _rotated_logs(0)
	_step("scanning %s rotated logs" % str(candidates.size()))
	var dir := Directory.new()
	var moved := 0
	for path in candidates:
		if moved >= MAX_LOGS_MOVED_PER_SESSION:
			break
		_step("scan " + path)
		var verdict := _log_blames_mods(path)
		if not bool(verdict.blamed):
			continue
		_step("blamed: %s (%s error lines naming mods)" % [path, str(verdict.count)])
		_step("summary of " + path)
		recorder.trail("mods named in %s: %s" % [path, _mod_mentions_summary(path)], "WARN")
		_step("ensure evidence dir begin")
		recorder.ensure_dir("user://logs/sentry/evidence")
		var dest := "user://logs/sentry/evidence/".plus_file(
			path.get_file().get_basename() + "." + Time.get_time_string_from_system().replace(":", ".") + ".log"
		)
		_step("rename %s -> %s" % [path, dest])
		var err = dir.rename(path, dest)
		if err != OK:
			recorder.trail("would move %s aside, but renaming to %s failed (%s); leaving it in place" % [path, dest, str(err)], "ERROR")
			_step("rename failed (%s)" % str(err))
			continue
		if File.new().file_exists(path):
			recorder.trail("rename to %s reported OK but %s is still there" % [dest, path], "ERROR")
			_step("rename reported OK but source still exists")
			continue
		moved += 1
		recorder.trail(
			"the game's crash reporter would have disabled ALL mods because of %s (%s error lines naming mods); renamed it to %s so it is kept but out of the way" % [
				path, str(verdict.count), dest
			],
			"WARN"
		)
	_step("neutralizing done, moved %s log(s), masked %s occurrence(s) so far" % [str(moved), str(masked_total)])


# ------------------------------------------------------------- step breadcrumbs


# for the steps that run before the recorder exists
func _pre_step(text: String) -> void:
	_steps_written += 1
	print("%s%s" % [STEP_TAG, text])


func _step(text: String) -> void:
	_steps_written += 1
	print("%s%s" % [STEP_TAG, text])
	if recorder != null and is_instance_valid(recorder):
		recorder.trail(text, "STEP")


func on_sanitized(count: int) -> void:
	masked_total += count
	recorder.trail("masked %s more occurrence(s) of '%s' in the live logs (total %s)" % [
		str(count), logwatch.sanitize_token, str(masked_total)
	], "SENTRY")


func _mod_mentions_summary(path: String) -> String:
	var counts := {}
	var regex := RegEx.new()
	var _e = regex.compile("mods[-_]unpacked/([A-Za-z0-9_.-]+)")
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return "(unreadable)"
	var size := f.get_len()
	if size > 260000:
		f.seek(size - 260000)
		f.get_line()
	while not f.eof_reached():
		for m in regex.search_all(f.get_line()):
			var mod_id := str(m.get_string(1))
			counts[mod_id] = int(counts.get(mod_id, 0)) + 1
	f.close()
	var parts := []
	for mod_id in counts.keys():
		parts.append("%s (%s)" % [str(mod_id), str(counts[mod_id])])
	if parts.empty():
		return "(none)"
	return ", ".join(PoolStringArray(parts))


# exactly the game's rule: an "ERROR:" line whose own or next line contains the
# literal "mods-unpacked" (the mask "mods_unpacked" is deliberately not matched, that
# is the whole point of masking)
func _log_blames_mods(path: String) -> Dictionary:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return { "blamed": false, "count": 0, "masked": 0 }
	var size := f.get_len()
	if size > 260000:
		f.seek(size - 260000)
		f.get_line()
	var blamed := false
	var count := 0
	var masked := 0
	var previous := ""
	while not f.eof_reached():
		var line := f.get_line()
		if "ERROR:" in line and ("mods-unpacked" in line or "mods-unpacked" in previous):
			blamed = true
			count += 1
		if "mods_unpacked" in line:
			masked += 1
		previous = line
	f.close()
	return { "blamed": blamed, "count": count, "masked": masked }


# Which log files hold the dead session's output? At report time the engine has
# already renamed the previous godot.log to godot<date>.log and started a fresh
# one, so the rotated files come first, the live ones last.
func _previous_log_tails(started_unix: int) -> Array:
	var tails := []
	var seen := {}
	for path in _evidence_logs():
		if not path in seen:
			seen[path] = true
			tails.append([path, "engine log kept by CrashSentry (the game would have thrown it away)"])
	for path in _rotated_logs(started_unix):
		if not path in seen:
			seen[path] = true
			tails.append([path, "rotated log of the session that died"])
	for path in logwatch.paths:
		if not File.new().file_exists(path) or path in seen:
			continue
		seen[path] = true
		tails.append([path, "live log (this is the new session, usually not the interesting one)"])
	if tails.size() > 4:
		tails.resize(4)
	return tails


func _evidence_logs() -> Array:
	var dir := Directory.new()
	if dir.open("user://logs/sentry/evidence") != OK:
		return []
	var paths := []
	var _e = dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry.length() > 0:
		if not dir.current_is_dir() and entry.get_extension() == "log":
			paths.append("user://logs/sentry/evidence/".plus_file(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths


func _rotated_logs(started_unix: int) -> Array:
	var dir := Directory.new()
	if dir.open("user://logs") != OK:
		_step("no user://logs folder")
		return []
	var candidates := []
	# deliberately NOT recursive: the game's own checker only looks directly in the
	# log folder, and recursing once made us archive our own evidence copies
	var _e = dir.list_dir_begin(false, true)
	var entry := dir.get_next()
	while entry.length() > 0:
		if not dir.current_is_dir() and entry.get_extension() == "log":
			if entry.begins_with("godot") or entry.begins_with("modloader"):
				if entry != "godot.log" and entry != "modloader.log":
					var path := "user://logs".plus_file(entry)
					var modified := int(File.new().get_modified_time(path))
					# Godot 3 has no DirAccess.get_size(), so measure through a File handle
					var size := _file_size(path)
					# a log older than the dead session cannot be its output
					if (started_unix == 0 or modified == 0 or modified >= started_unix - 5) and size <= MAX_LOG_SCAN_BYTES:
						candidates.append([modified, path])
		entry = dir.get_next()
	dir.list_dir_end()
	candidates.sort_custom(SortByModified, "sort")
	var paths := []
	for pair in candidates:
		paths.append(pair[1])
	return paths


class SortByModified:
	static func sort(a, b) -> bool:
		return int(a[0]) > int(b[0])


func _file_size(path: String) -> int:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return 0
	var size := f.get_len()
	f.close()
	return size


func _newest_rotated_log(prefix: String, current_name: String) -> String:
	var dir := Directory.new()
	var dir_path := "user://logs"
	if dir.open(dir_path) != OK:
		return ""
	var candidates := []
	var _e = dir.list_dir_begin(true, true)
	var fname := dir.get_next()
	while fname.length() > 0:
		if not dir.current_is_dir() and fname.begins_with(prefix) and fname.get_extension() == "log":
			if fname != current_name:
				candidates.append(dir_path.plus_file(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	if candidates.empty():
		return ""
	candidates.sort()
	return candidates[candidates.size() - 1]


# ------------------------------------------------------------------ process


func _process(delta: float) -> void:
	recorder.note_main_tick()
	var now := Time.get_ticks_msec()
	var delta_ms := int(delta * 1000.0)

	var scene := _current_scene_name()
	if scene != _scene_name:
		recorder.trail("scene changed: %s -> %s | nodes %s" % [
			_scene_name, scene, _node_count_string()
		], "SCENE")
		_scene_name = scene

	var wave = _run_value("current_wave", -1)
	if wave != _last_wave:
		var danger = _run_value("current_difficulty", -1)
		recorder.trail("run state: wave %s, danger %s, endless %s" % [
			str(wave), str(danger), str(_run_value("is_endless_run", false))
		], "RUN")
		_last_wave = wave
		_last_danger = danger

	if bool(opts.freed_watchdog) and now - _last_watch_ms > 500:
		_last_watch_ms = now
		_check_watched_objects()

	if int(opts.frame_hitch_ms) > 0 and delta_ms >= int(opts.frame_hitch_ms):
		recorder.trail("frame took %s ms (nodes %s, fps %.1f) | %s" % [
			str(delta_ms), _node_count_string(), Engine.get_frames_per_second(), run_snapshot()
		], "HITCH")

	var every_mem := int(opts.memory_log_seconds) * 1000
	if every_mem > 0 and now - _last_mem_ms > every_mem:
		_last_mem_ms = now
		recorder.trail("nodes %s | frames draw=%s process=%s physics=%s | mem %s" % [
			_node_count_string(),
			_engine_frame_string("get_frames_drawn"),
			_engine_frame_string("get_process_frames"),
			_engine_frame_string("get_physics_frames"),
			memory_line(),
		], "MEM")

	if now - _last_heartbeat_ms > 1000:
		_last_heartbeat_ms = now
		recorder.set_heartbeat(JSON.print(heartbeat_dict()))

	if overlay != null and overlay.visible and now - _last_overlay_ms > 250:
		_last_overlay_ms = now
		_refresh_overlay()

	_add_brotato_own_log_once()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo or key.scancode == 0:
		return
	var code := key.scancode
	var handled := true
	if code == KEY_F8:
		if overlay != null:
			overlay.visible = not overlay.visible
			_refresh_overlay()
	elif code == KEY_F9:
		var path = dump_state("hotkey F9")
		if overlay != null:
			overlay.toast("state dump written:\n%s" % ProjectSettings.globalize_path(path), 8.0)
	elif code == KEY_F10:
		copy_diagnostics_to_clipboard()
		if overlay != null:
			overlay.toast("diagnostics copied to clipboard", 5.0)
	elif code == KEY_F7:
		var _o = OS.shell_open(ProjectSettings.globalize_path(recorder.reports_dir))
	else:
		handled = false
	if handled and _tree() != null:
		_tree().set_input_as_handled()


# ------------------------------------------------------------- public API
# other mods can reach this node with
#   get_node("/ModLoader/dbg-CrashSentry")


func trail(message: String, level: String = "USER") -> void:
	recorder.trail(message, level)


func dump_state(reason: String) -> String:
	recorder.trail("dump_state('%s') requested" % reason, "TRACE")
	var path = recorder.new_report_file_name("dump")
	var text = reports.state_dump(reason)
	if recorder.write_report(path, text):
		recorder.trail("state dump written: %s" % ProjectSettings.globalize_path(path), "USER")
		return path
	recorder.trail("failed to write state dump to %s" % path, "ERROR")
	return ""


func set_overlay_visible(value: bool) -> void:
	if overlay != null:
		overlay.visible = value
		_refresh_overlay()


func copy_diagnostics_to_clipboard() -> void:
	var chunks := [
		"== CrashSentry diagnostics %s ==" % Time.get_datetime_string_from_system(),
		context_string(),
		run_snapshot(),
		"last errors:",
		"\n".join(PoolStringArray(logwatch.recent)),
		"last flight recorder entries:",
		"\n".join(PoolStringArray(recorder.trail_tail(40))),
		"mods:",
		mods_table(),
	]
	OS.set_clipboard("\n".join(PoolStringArray(chunks)))


func watch(object: Object, label := "") -> void:
	if object == null or not is_instance_valid(object):
		recorder.trail("watch() called with a null or already freed object", "WARN")
		return
	var id := object.get_instance_id()
	if label.length() == 0:
		label = _describe(object)
	_watched[id] = {
		"ref": weakref(object),
		"label": label,
		"class": object.get_class(),
		"connections": object.get_incoming_connections().size(),
		"signals": object.get_signal_list().size(),
		"scene": _node_path_or_none(object),
		"wave": _run_value("current_wave", -1),
	}


func unwatch(object: Object) -> void:
	if object == null or not is_instance_valid(object):
		return
	_watched.erase(object.get_instance_id())


## Wraps a risky call so that a failure is written to the flight recorder before
## the engine prints (and possibly dies on) it. Godot 3 has no try/catch, this is
## the closest thing: it validates the target, logs the call, then performs it.
func safe_call(target, method_name: String, args := [], label := "") -> Dictionary:
	var result := {"ok": false, "error": "", "value": null}
	var tag := label if label.length() > 0 else "%s.%s" % [_describe(target), method_name]
	if target == null:
		result.error = "target is null"
		recorder.trail("safe_call %s refused: %s" % [tag, result.error], "WARN")
		return result
	if not is_instance_valid(target):
		result.error = "target was freed (this is what usually crashes the game)"
		recorder.trail("safe_call %s refused: %s" % [tag, result.error], "WARN")
		return result
	if not target.has_method(method_name):
		result.error = "target has no method '%s'" % method_name
		recorder.trail("safe_call %s refused: %s" % [tag, result.error], "WARN")
		return result
	recorder.trail("safe_call %s(%s)" % [tag, str(args)], "CALL")
	var before := OS.get_ticks_msec()
	result.value = target.callv(method_name, Array(args))
	result.ok = true
	var took := OS.get_ticks_msec() - before
	if int(opts.frame_hitch_ms) > 0 and took >= int(opts.frame_hitch_ms):
		recorder.trail("safe_call %s took %s ms" % [tag, str(took)], "HITCH")
	return result


func mem_values() -> Array:
	# Brotato ships a release build: the engine memory counters report 0 there.
	var static_mem = OS.get_static_memory_usage()
	var peak_mem = OS.get_static_memory_peak_usage()
	var dynamic_mem = 0
	if OS.has_method("get_dynamic_memory_usage"):
		dynamic_mem = OS.call("get_dynamic_memory_usage")
	return [int(static_mem), int(peak_mem), int(dynamic_mem)]


func mem_available() -> bool:
	var values := mem_values()
	return values[0] > 0 or values[1] > 0 or values[2] > 0


func mem_string() -> String:
	var values := mem_values()
	if not mem_available():
		return "n/a"
	return "%.1f" % (float(values[0]) / 1048576.0)


func context_string() -> String:
	return "scene=%s wave=%s danger=%s nodes=%s fps=%.1f mem=%sMB" % [
		_current_scene_name(),
		str(_run_value("current_wave", -1)),
		str(_run_value("current_difficulty", -1)),
		_node_count_string(),
		Engine.get_frames_per_second(),
		mem_string(),
	]


func heartbeat_dict() -> Dictionary:
	return {
		"session": recorder.session_id,
		"pid": OS.get_process_id(),
		"unix": Time.get_unix_time_from_system(),
		"ticks": Time.get_ticks_msec(),
		"uptime_s": (Time.get_ticks_msec() - started_ticks) / 1000,
		"fps": stepify(Engine.get_frames_per_second(), 0.1),
		"scene": _current_scene_name(),
		"scene_path": _current_scene_path(),
		"nodes": _node_count_string(),
		"mem_static_mb": mem_string(),
		"mem_peak_mb": "%.1f" % (float(mem_values()[1]) / 1048576.0),
		"paused": _tree().paused if _tree() != null else false,
		"wave": _run_value("current_wave", -1),
		"danger": _run_value("current_difficulty", -1),
		"endless": _run_value("is_endless_run", false),
		"errors": logwatch.errors_total if logwatch != null else 0,
		"masked": masked_total,
		"trail_seq": recorder.sequence,
		"watched": _watched.size(),
	}


func mods_table() -> String:
	var out := ""
	if ModLoaderStore == null:
		return "  (mod loader store not available)"
	for mod_id in ModLoaderStore.mod_data.keys():
		var mod = ModLoaderStore.mod_data[mod_id]
		var version := "?"
		if mod.manifest != null:
			version = str(mod.manifest.version_number)
		out += "  %-34s v%-10s active=%s locked=%s dir=%s\n" % [
			str(mod_id), version, str(mod.is_active), str(mod.is_locked), str(mod.zip_name)
		]
	return out.strip_edges()


func extensions_table() -> String:
	var out := ""
	if ModLoaderStore == null:
		return "  (mod loader store not available)"
	for mod_id in ModLoaderStore.saved_extension_paths.keys():
		for path in ModLoaderStore.saved_extension_paths[mod_id]:
			out += "  %-34s -> %s\n" % [str(mod_id), str(path)]
	if out.length() == 0:
		out = "  (none)"
	return out.strip_edges()


func game_version_string() -> String:
	var version := str(_setting("application/config/version", "?"))
	var store_version := "?"
	if ModLoaderStore != null:
		store_version = str(ModLoaderStore.get("MODLOADER_VERSION"))
	var reporter := _autoload("CrashReporter")
	var reporter_version := ""
	if reporter != null:
		reporter_version = str(reporter.get("VERSION"))
	return "game version setting=%s crash_reporter=%s mod_loader=%s" % [version, reporter_version, store_version]


func game_crash_reporter_table() -> String:
	var reporter := _autoload("CrashReporter")
	if reporter == null:
		return "  (CrashReporter autoload not found)"
	return "  previous_crashed_mod: %s\n  previous_crash_message: %s" % [
		str(reporter.get("previous_crashed_mod")),
		str(reporter.get("previous_crash_message")).replace("\n", " "),
	]


func brotato_internal_log_path() -> String:
	var progress := _autoload("ProgressData")
	if progress != null:
		var path = progress.get("LOG_PATH")
		if typeof(path) == TYPE_STRING and path.length() > 0:
			return path
	# ProgressData has not run yet (our mod loads before it), so find
	# user://<profile>/log.txt the slow way: newest file wins.
	var dir := Directory.new()
	if dir.open("user://") != OK:
		return ""
	var best := ""
	var best_modified := -1
	var _e = dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry.length() > 0:
		if dir.current_is_dir() and not entry.begins_with("logs"):
			var candidate := "user://".plus_file(entry).plus_file("log.txt")
			if File.new().file_exists(candidate):
				var modified = int(File.new().get_modified_time(candidate))
				if modified > best_modified:
					best_modified = modified
					best = candidate
		entry = dir.get_next()
	dir.list_dir_end()
	return best


func watch_log_tail(count: int) -> String:
	var out := ""
	var start: int = _watch_log.size() - count
	if start < 0:
		start = 0
	for i in range(start, _watch_log.size()):
		out += "  %s\n" % str(_watch_log[i])
	if out.length() == 0:
		out = "  (nothing registered with watch() yet, or nothing disappeared)\n"
	return out.strip_edges()


func run_snapshot() -> String:
	var run = _autoload("RunData")
	if run == null:
		return "run: not in a run (RunData autoload missing)"
	if not run.has_method("get_player_count"):
		return "wave=%s danger=%s endless=%s" % [
			str(_run_value("current_wave", -1)),
			str(_run_value("current_difficulty", -1)),
			str(_run_value("is_endless_run", false)),
		]
	var player_count: int = int(run.call("get_player_count"))
	if player_count < 0:
		player_count = 0
	if player_count > 4:
		player_count = 4
	var out := "wave=%s danger=%s endless=%s zone=%s players=%s" % [
		str(_run_value("current_wave", -1)),
		str(_run_value("current_difficulty", -1)),
		str(_run_value("is_endless_run", false)),
		_zone_id(run),
		str(player_count),
	]
	for index in range(0, player_count):
		var character = null
		if run.has_method("get_player_character"):
			character = run.call("get_player_character", index)
		var weapons := []
		if run.has_method("get_player_weapons_ref"):
			for weapon in run.call("get_player_weapons_ref", index):
				weapons.append(_id_of(weapon))
		var items := []
		if run.has_method("get_player_items"):
			for item in run.call("get_player_items", index):
				items.append(_id_of(item))
		out += "\n  p%s char=%s lvl=%s gold=%s weapons=[%s] items=[%s]" % [
			str(index),
			_id_of(character),
			str(run.call("get_player_level", index)) if run.has_method("get_player_level") else "?",
			str(run.call("get_player_gold", index)) if run.has_method("get_player_gold") else "?",
			", ".join(PoolStringArray(weapons)),
			", ".join(PoolStringArray(items)),
		]
		if int(index) > 3:
			break
	return out


# ---------------------------------------------------------------- internals


func _read_options() -> void:
	opts = {}
	for key in DEFAULTS:
		opts[key] = DEFAULTS[key]
	var data = null
	if ModLoaderStore != null and ModLoaderStore.mod_data.has(MOD_ID):
		var mod = ModLoaderStore.mod_data[MOD_ID]
		if mod != null and mod.current_config != null and mod.current_config.data != null:
			data = mod.current_config.data
			config_source = "mod config"
	if data == null:
		var f := File.new()
		var path := "user://configs/%s/default.json" % MOD_ID
		if f.open(path, File.READ) == OK:
			var parsed = parse_json(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				data = parsed
				config_source = "config file"
	if data == null:
		return
	for key in DEFAULTS:
		if data.has(key):
			opts[key] = data[key]


func on_captured_error(text: String, mod_ids: Array) -> void:
	var suffix := ""
	if mod_ids.size() > 0:
		suffix = "  [mods: %s]" % ", ".join(PoolStringArray(mod_ids))
	recorder.trail("ENGINE LOG: %s%s" % [text, suffix], "ERR")


func on_captured_line(text: String, mod_ids: Array) -> void:
	recorder.trail("GAME LOG: %s" % text, "GAME")


func _check_watched_objects() -> void:
	var gone := []
	for id in _watched.keys():
		var ref = _watched[id].ref
		var alive = ref.get_ref()
		if alive == null or not is_instance_valid(alive):
			gone.append(id)
	for id in gone:
		var info = _watched[id]
		var message := "watched object '%s' (%s, scene %s, wave %s) DISAPPEARED; it had %s live incoming connections and %s signals" % [
			str(info.label), str(info.class), str(info.scene), str(info.wave), str(info.connections), str(info.signals)
		]
		_watch_log.append(message)
		while _watch_log.size() > 60:
			_watch_log.pop_front()
		recorder.trail(message, "FREED")
		_watched.erase(id)


func _add_brotato_own_log_once() -> void:
	if logwatch == null or not bool(opts.tail_engine_log):
		return
	if not is_inside_tree():
		return
	var path := brotato_internal_log_path()
	if path.length() == 0:
		return
	if path in logwatch.paths:
		return
	logwatch.add_file(path, true)
	recorder.trail("now also following Brotato's own log: %s" % path, "SENTRY")


func _refresh_overlay() -> void:
	if overlay == null:
		return
	var stats := [
		"scene %s   wave %s   danger %s   %s" % [
			_current_scene_name(), str(_run_value("current_wave", -1)),
			str(_run_value("current_difficulty", -1)),
			"paused" if (_tree() != null and _tree().paused) else "running",
		],
		"fps %.0f   nodes %s   mem %s   trail %s entries" % [
			Engine.get_frames_per_second(), _node_count_string(),
			memory_line(), str(recorder.sequence),
		],
		"errors %s   warnings %s   watched %s   masked %s" % [
			str(logwatch.errors_total), str(logwatch.warnings_total), str(_watched.size()), str(masked_total)
		],
		"trail: %s" % ProjectSettings.globalize_path(recorder.trail_path),
	]
	overlay.set_content("CrashSentry  (%s)" % hotkeys_hint(), stats, logwatch.recent)


func hotkeys_hint() -> String:
	return "F8 hide · F9 dump · F10 copy · F7 reports folder"


func _tree():
	if _cached_tree == null:
		var loop = Engine.get_main_loop()
		if loop != null and loop is SceneTree:
			_cached_tree = loop
	return _cached_tree


func _root():
	var tree = _tree()
	if tree == null:
		return null
	return tree.root


func _autoload(name: String) -> Node:
	var root = _root()
	if root == null:
		return null
	return root.get_node_or_null(name)


func _current_scene_name() -> String:
	var tree = _tree()
	if tree == null:
		return "(no tree)"
	var scene = tree.current_scene
	if scene == null:
		return "(no scene)"
	return str(scene.name)


func _current_scene_path() -> String:
	var tree = _tree()
	if tree == null:
		return ""
	var scene = tree.current_scene
	if scene == null:
		return ""
	var filename = scene.get("filename")
	return str(filename) if filename != null else ""


func _node_count_string() -> String:
	var tree = _tree()
	if tree.has_method("get_node_count"):
		return str(tree.call("get_node_count"))
	return "?"


func _run_value(property: String, fallback):
	var run = _autoload("RunData")
	if run == null:
		return fallback
	var value = run.get(property)
	if value == null:
		return fallback
	return value


func _zone_id(run) -> String:
	return _id_of(run.get("current_zone"))


# never call .get() on something that may already be freed: in this engine build
# that prints an error and aborts the whole function
func _id_of(instance) -> String:
	if instance == null:
		return "?"
	if typeof(instance) == TYPE_OBJECT:
		if not is_instance_valid(instance):
			return "(freed)"
		var value = instance.call("get", "my_id")
		return str(value) if value != null else "?"
	if typeof(instance) == TYPE_DICTIONARY:
		var value = instance.get("my_id")
		return str(value) if value != null else "?"
	return str(instance)


func _describe(object) -> String:
	if object == null:
		return "null"
	if object is Node:
		return "%s:%s" % [object.get_class(), str(object.get("name"))]
	return "%s:%s" % [object.get_class(), str(object.get_instance_id())]


func _node_path_or_none(object) -> String:
	if object is Node and (object as Node).is_inside_tree():
		return str((object as Node).get_path())
	return "(not in tree)"


func _setting(name: String, fallback):
	if ProjectSettings.has_setting(name):
		return ProjectSettings.get_setting(name)
	return fallback


func _engine_frame_string(method: String) -> String:
	if Engine.has_method(method):
		return str(Engine.call(method))
	return "?"


func memory_line() -> String:
	var values := mem_values()
	if not mem_available():
		return "not tracked in this engine build"
	return "static %s MB, peak %s MB, dynamic %s MB" % [
		_mb(values[0]), _mb(values[1]), _mb(values[2])
	]


func _mb(bytes: int) -> String:
	return "%.1f" % (float(bytes) / 1048576.0)
