extends CanvasLayer
# Small always-on-top diagnostics panel. Deliberately ignores mouse input and
# keeps running while the tree is paused (the shop is a popular place to crash).

const LOG_NAME := "CrashSentry"
const PAUSE_ALWAYS := 2  # Node.PAUSE_MODE_ALWAYS, kept as a number for engine-build safety

var hotkey_lines := "F8 overlay · F9 dump state · F10 copy · F7 open reports"
var show_errors := true
var max_error_lines := 10

var _panel = null
var _label = null
var _toast = null
var _toast_remaining := 0.0
var _plain := ""


func _ready() -> void:
	layer = 128
	set_pause_mode(PAUSE_ALWAYS)

	_panel = PanelContainer.new()
	_panel.name = "CrashSentryPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.show_behind_parent = false
	add_child(_panel)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.04, 0.04, 0.06, 0.72)
	background.set_corner_radius_all(4)
	background.content_margin_left = 6
	background.content_margin_right = 6
	background.content_margin_top = 4
	background.content_margin_bottom = 4
	_panel.add_stylebox_override("panel", background)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_constant_override("margin_left", 8)
	margin.add_constant_override("margin_right", 8)
	margin.add_constant_override("margin_top", 6)
	margin.add_constant_override("margin_bottom", 6)
	_panel.add_child(margin)

	_label = RichTextLabel.new()
	_label.name = "Lines"
	_label.bbcode_enabled = true
	_label.fit_content_height = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.rect_min_size = Vector2(640, 0)
	margin.add_child(_label)

	var toast_panel := PanelContainer.new()
	toast_panel.name = "CrashSentryToast"
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_panel.margin_left = -320
	toast_panel.margin_right = 320
	toast_panel.margin_top = 40
	toast_panel.margin_bottom = 0
	add_child(toast_panel)

	_toast = RichTextLabel.new()
	_toast.name = "ToastLines"
	_toast.bbcode_enabled = true
	_toast.fit_content_height = true
	_toast.scroll_active = false
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.rect_min_size = Vector2(640, 0)
	toast_panel.add_child(_toast)
	toast_panel.visible = false

	position_panel()
	visible = false


func position_panel() -> void:
	if _panel == null:
		return
	_panel.rect_position = Vector2(12, 12)
	_panel.rect_size = Vector2(0, 0)


func set_content(title: String, stat_lines: Array, error_lines: Array) -> void:
	var bb := "[b][color=#ffd166]%s[/color][/b]\n" % title
	for line in stat_lines:
		bb += "[color=#cfd8dc]%s[/color]\n" % line
	if show_errors and error_lines.size() > 0:
		bb += "\n[b][color=#ef5350]last captured errors[/color][/b]\n"
		var start: int = error_lines.size() - max_error_lines
		if start < 0:
			start = 0
		for i in range(start, error_lines.size()):
			bb += "[color=#ef9a9a]%s[/color]\n" % _escape(str(error_lines[i]))
	_plain = title + "\n" + "\n".join(PoolStringArray(stat_lines))
	if error_lines.size() > 0:
		_plain += "\nerrors:\n" + "\n".join(PoolStringArray(error_lines))
	if _label != null:
		_label.bbcode_text = bb


func plain_text() -> String:
	return _plain


func toast(text: String, seconds: float = 10.0) -> void:
	if _toast == null or _toast.get_parent() == null:
		return
	_toast.bbcode_text = "[b][color=#ffd166]CrashSentry[/color][/b]\n%s" % text
	_toast.get_parent().visible = true
	_toast_remaining = seconds


func _process(delta: float) -> void:
	if _toast_remaining > 0.0:
		_toast_remaining -= delta
		if _toast_remaining <= 0.0 and _toast != null and _toast.get_parent() != null:
			_toast.get_parent().visible = false


func _escape(text: String) -> String:
	return text.replace("[", "").replace("]", "")
