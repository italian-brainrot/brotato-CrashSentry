extends Node
# Builds the text of the two report kinds: post-mortem crash reports and manual
# state dumps.
#
# Two rules matter here, because these functions run right after a crash:
#   * the file is written incrementally (the FLUSH_GROUP sentinel marks a flush
#     point) so that even if report generation itself dies, everything gathered
#     so far is already on disk;
#   * a marker file (.attempt) is removed only when a report finished writing.
#     If the next launch finds it, the previous attempt crashed and the report is
#     built in minimal mode instead of crashing the game again.

const LOG_NAME := "CrashSentry"
const FLUSH_GROUP := "<<<flush-group-thread-safe>>>"

var main = null
var recorder = null
var logwatch = null


func init(p_main, p_recorder, p_logwatch) -> void:
	main = p_main
	recorder = p_recorder
	logwatch = p_logwatch


# ------------------------------------------------------------------ the fuse
func attempt_path() -> String:
	return recorder.reports_dir + "/.attempt"


func mark_attempt() -> void:
	var f = File.new()
	if f.open(attempt_path(), File.WRITE) == OK:
		f.store_string(str(recorder.session_id) + "\n")
		f.close()


func clear_attempt() -> void:
	recorder.remove_file(attempt_path())


func check_previous_attempt() -> bool:
	if not recorder.file_exists(attempt_path()):
		return false
	recorder.trail("the PREVIOUS attempt to write a report never finished - that code path is the suspect", "ERROR")
	recorder.trail("a report may be incomplete in %s" % recorder.reports_dir, "ERROR")
	clear_attempt()
	return true


# ------------------------------------------------------------------ reports
func crash_report(marker: Dictionary, heartbeat_text: String, previous_log_tails: Array, previous_trail_lines: Array, freeze_lines: Array, minimal: bool = false) -> String:
	var out := []
	_step("crash report: begin")
	out.append(_line("CrashSentry post-mortem report"))
	out.append("generated: %s" % Time.get_datetime_string_from_system())
	out.append("reason: the previous session left its session marker behind, so the game never ran")
	out.append("        its shutdown code (crash, freeze then kill, or SIGKILL).")
	out.append("")
	_step("crash report: marker")
	out.append(_line("previous session"))
	out.append(JSON.print(marker, "  "))
	if marker.get("started_unix", 0) != null:
		var started = int(marker.get("started_unix", 0))
		out.append("running until this report: %s s" % str(Time.get_unix_time_from_system() - started))
	out.append("")
	_step("crash report: heartbeat")
	out.append(_line("last heartbeat (the last state that existed)"))
	out.append(heartbeat_text)
	out.append("")
	_step("crash report: trail")
	out.append(FLUSH_GROUP)
	out.append(_line("last flight-recorder entries of that session"))
	for l in previous_trail_lines:
		out.append(str(l))
	out.append("")
	_step("crash report: freezes")
	out.append(FLUSH_GROUP)
	out.append(_line("freeze markers"))
	if freeze_lines.empty():
		out.append("  no freeze markers - the main loop was responsive until the end")
	else:
		for l in freeze_lines:
			out.append(str(l))
	out.append("")
	_step("crash report: log tails")
	out.append(FLUSH_GROUP)
	for tail in previous_log_tails:
		var tail_path := str(tail[0])
		out.append(_line("log tail: %s" % tail_path))
		if int(tail[1]) != 0:
			out.append("  (the file was last modified %s s before the report - it may be from an older session)" % str(int(tail[1])))
		for entry in recorder.read_tail(tail_path, 120):
			out.append(str(entry))
		out.append(_line("suspects: mods mentioned in that log"))
		out.append(_suspects_from_file(tail_path))
		out.append("")
	if minimal:
		out.append(_line("the rest of the report is skipped"))
		out.append("The previous attempt to build a report never finished, so the heavy sections")
		out.append("(mod tables, run snapshot, game log) are skipped to avoid crashing again.")
		out.append("")
	else:
		_append_common(out)
	_step("crash report: writing")
	var report_path := path_for("crash")
	_write_file(report_path, out)
	clear_attempt()
	_step("crash report: done")
	return report_path


func state_dump(reason: String) -> String:
	var out := []
	_step("dump: begin")
	out.append(_line("CrashSentry state dump"))
	out.append("generated: %s" % Time.get_datetime_string_from_system())
	out.append("reason: %s" % reason)
	out.append("")
	_step("dump: live state")
	out.append(_line("live state"))
	out.append(main.context_string())
	out.append(JSON.print(main.heartbeat_dict(), "  "))
	out.append("")
	_step("dump: trail")
	out.append(FLUSH_GROUP)
	out.append(_line("recent flight-recorder entries"))
	for l in recorder.trail_tail(60):
		out.append(str(l))
	out.append("")
	_step("dump: errors")
	out.append(FLUSH_GROUP)
	out.append(_line("errors captured this session"))
	out.append("errors: %s   warnings: %s   captured lines: %s" % [
		str(logwatch.errors_total), str(logwatch.warnings_total), str(logwatch.captured_total)
	])
	for entry in logwatch.recent:
		out.append(str(entry))
	out.append("")
	_step("dump: suspects")
	out.append(FLUSH_GROUP)
	out.append(_line("suspects: error count per mod this session"))
	for pair in logwatch.top_offenders(12):
		out.append("  %s: %s errors" % [pair[0], str(pair[1])])
	out.append("")
	_step("dump: freed watchdog")
	out.append(FLUSH_GROUP)
	out.append(_line("freed-reference watchdog"))
	out.append(main.watch_log_tail(20))
	out.append("")
	_step("dump: log tails")
	out.append(FLUSH_GROUP)
	for path in logwatch.paths:
		if File.new().file_exists(path):
			out.append("  ## %s" % path)
			for entry in recorder.read_tail(path, 40):
				out.append(str(entry))
	_append_common(out)
	_step("dump: writing")
	var path = new_dump_file_name()
	_write_file(path, out)
	_step("dump: done")
	return path


func path_for(kind: String) -> String:
	var stamp := "%s-%s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system().replace(":", ".")]
	return "%s/%s-%s.txt" % [recorder.reports_dir, kind, stamp]


func new_dump_file_name() -> String:
	return recorder.new_report_file_name("dump")


func read_report(path: String) -> String:
	return _slurp(path, 400)


# ------------------------------------------------------------------ sections
func _append_common(out: Array) -> void:
	_step("common: mods")
	out.append(_line("loaded mods"))
	out.append(main.mods_table())
	out.append("")
	_step("common: extensions")
	out.append(FLUSH_GROUP)
	out.append(_line("installed script extensions"))
	out.append(main.extensions_table())
	out.append("")
	_step("common: crash reporter verdict")
	out.append(_line("what Brotato's own crash reporter thought"))
	out.append(main.game_crash_reporter_table())
	out.append("")
	_step("common: run snapshot")
	out.append(_line("run snapshot"))
	out.append(main.run_snapshot())
	out.append("")
	_step("common: environment")
	out.append(FLUSH_GROUP)
	out.append(_line("environment"))
	out.append("engine: %s" % Engine.get_version_info().get("string", "unknown"))
	out.append("game: %s" % main.game_version_string())
	out.append("os: %s (%s)" % [OS.get_name(), OS.get_model_name()])
	out.append("pid: %s   processors: %s" % [str(OS.get_process_id()), str(OS.get_processor_count())])
	out.append("user data dir: %s" % ProjectSettings.globalize_path("user://"))
	out.append("game dir: %s" % OS.get_executable_path().get_base_dir())
	out.append("cmdline: %s" % " ".join(PoolStringArray(OS.get_cmdline_args())))
	var log_path := str(_setting("logging/file_logging/log_path", "user://logs/godot.log"))
	out.append("engine log: %s   file logging: %s   max_log_files: %s" % [
		ProjectSettings.globalize_path(log_path),
		str(_setting("logging/file_logging/enable_file_logging", false)),
		str(_setting("logging/file_logging/max_log_files", 1))
	])
	out.append("")
	_step("common: brotato log")
	out.append(_line("game log (user://<profile>/log.txt, written by Brotato itself)"))
	out.append(_slurp(main.brotato_internal_log_path(), 40))
	out.append("")
	out.append(_line("how to capture a native backtrace too"))
	out.append("Godot's crash handler writes its backtrace to stderr. When Steam starts the game")
	out.append("stderr is thrown away, so the log only shows the last scripted errors. Launch once")
	out.append("with this Steam launch option to capture it:")
	out.append("  %command% 2>>/tmp/brotato_stderr.log -vvv")


# ------------------------------------------------------------------ helpers
func _step(name: String) -> void:
	if recorder != null:
		recorder.trail("report step: %s" % name, "TRACE")


func _write_file(path: String, out: Array) -> void:
	var f = File.new()
	var err = f.open(path, File.WRITE)
	if err != OK:
		if recorder != null:
			recorder.trail("cannot open %s (%s)" % [path, str(err)], "ERROR")
		return
	for line in out:
		if line == FLUSH_GROUP:
			f.flush()
			continue
		f.store_string(str(line) + "\n")
	f.flush()
	f.close()
	recorder.prune_reports()


func _suspects_from_file(path: String) -> String:
	var counts := {}
	var regex := RegEx.new()
	var _e = regex.compile("mods[-_]unpacked/([A-Za-z0-9_.-]+)")
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return "  (could not open)"
	var interesting := 0
	while not f.eof_reached():
		var line := f.get_line()
		if not ("ERROR" in line or "SCRIPT ERROR" in line or "mods-unpacked" in line or "mods_unpacked" in line):
			continue
		interesting += 1
		var source = logwatch if logwatch != null else LocalAttribution.new(regex)
		for mod_id in source.mods_in_line(line):
			counts[mod_id] = int(counts.get(mod_id, 0)) + 1
	f.close()
	if counts.empty():
		return "  no mod paths (res://mods-unpacked/...) in that log, %s error-ish lines" % str(interesting)
	var pairs := []
	for mod_id in counts.keys():
		pairs.append([mod_id, counts[mod_id]])
	pairs.sort_custom(SortByCount, "sort")
	var text := ""
	for pair in pairs:
		text += "  %s: %s mentions\n" % [pair[0], str(pair[1])]
	return text.strip_edges()


func _slurp(path: String, max_lines: int = 0) -> String:
	if path.length() == 0:
		return "  (path unknown)"
	var lines = recorder.read_tail(path, max_lines if max_lines > 0 else 100000)
	if lines.empty():
		return "  (empty or missing: %s)" % path
	return "\n".join(PoolStringArray(lines))


class LocalAttribution:
	var regex: RegEx

	func _init(p_regex: RegEx) -> void:
		regex = p_regex

	func mods_in_line(line: String) -> Array:
		var found := []
		for m in regex.search_all(line):
			var mod_id: String = m.get_string(1)
			if mod_id.length() > 0 and not mod_id in found:
				found.append(mod_id)
		return found


func _setting(name: String, fallback):
	if ProjectSettings.has_setting(name):
		return ProjectSettings.get_setting(name)
	return fallback


func _line(title: String) -> String:
	return "\n== %s %s" % [title, "=".repeat(max2(0, 60 - title.length()))]


func max2(a: int, b: int) -> int:
	return a if a > b else b


class SortByCount:
	static func sort(a, b) -> bool:
		return int(a[1]) > int(b[1])
