## Bottom-panel UI for the Claude Code Godot plugin.
## Builds its own scene tree programmatically so no .tscn file is needed.
@tool
extends VBoxContainer

const _ClientScript = preload("res://addons/goclau/claude_client.gd")

# ── Colours ──────────────────────────────────────────────────────────────────
const C_USER       := Color(0.60, 0.85, 1.00)
const C_ASSISTANT  := Color(0.85, 1.00, 0.70)
const C_ERROR      := Color(1.00, 0.50, 0.50)
const C_SYSTEM     := Color(0.75, 0.75, 0.75)
const C_STATUS_OK  := Color(0.40, 0.90, 0.40)
const C_STATUS_ERR := Color(0.90, 0.40, 0.40)

# ── Nodes ─────────────────────────────────────────────────────────────────────
var _client: Node  # instance of claude_client.gd

# Server box
var _server_box:      PanelContainer
var _status_dot:      Label
var _status_label:    Label
var _port_spin:       SpinBox
var _server_btn:      Button
var _stop_btn:        Button
var _server_hint:     Label
var _placement_btn:   Button

# Chat
var _chat_log:       RichTextLabel
var _context_script: CheckBox
var _context_scene:  CheckBox
var _input:          TextEdit
var _send_btn:       Button
var _clear_btn:      Button
var _run_input:      LineEdit
var _run_btn:        Button

# Diff review (run task bar)
var _diff_box:       PanelContainer
var _diff_log:       RichTextLabel
var _accept_btn:     Button
var _reject_btn:     Button
var _pending_cwd:    String = ""

# Proposal box (chat file proposals)
var _proposal_box:     PanelContainer
var _proposal_log:     RichTextLabel
var _apply_btn:        Button
var _cancel_btn:       Button
var _pending_proposal: Array = []

# State
var _server_running: bool = false
var _waiting:        bool = false
var _starting_up:   bool = true   # suppresses the initial connection error

## Set by the EditorPlugin immediately after instantiation.
var plugin: Node = null


func _ready() -> void:
	_build_ui()
	_client = _ClientScript.new()
	add_child(_client)
	_client.response_received.connect(_on_response)
	_client.request_failed.connect(_on_error)
	_sync_placement_btn()
	# Delay first check so the auto-started Python server has time to bind the port.
	get_tree().create_timer(3.0).timeout.connect(_on_startup_check)


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 4)
	add_child(_build_server_box())
	add_child(_build_chat_area())
	add_child(_build_proposal_box())
	add_child(_build_diff_box())
	add_child(_build_context_bar())
	add_child(_build_input_bar())
	add_child(_build_run_bar())


func _build_server_box() -> PanelContainer:
	_server_box = PanelContainer.new()

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_server_box.add_child(vbox)

	# ── Row 1: status indicator ──────────────────────────────────────────────
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	vbox.add_child(row1)

	_status_dot = Label.new()
	_status_dot.text = "●"
	_status_dot.add_theme_color_override("font_color", C_STATUS_ERR)
	row1.add_child(_status_dot)

	_status_label = Label.new()
	_status_label.text = "Bridge server offline"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.clip_text = true
	row1.add_child(_status_label)

	_placement_btn = Button.new()
	_placement_btn.text = "⇄ Dock"
	_placement_btn.tooltip_text = "Move to side dock"
	_placement_btn.flat = true
	_placement_btn.pressed.connect(_on_placement_btn_pressed)
	row1.add_child(_placement_btn)

	# ── Row 2: controls ───────────────────────────────────────────────────────
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	vbox.add_child(row2)

	var port_label := Label.new()
	port_label.text = "Port:"
	row2.add_child(port_label)

	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.value = 9876
	_port_spin.custom_minimum_size.x = 80
	_port_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_port_spin.value_changed.connect(func(_v): _update_server_box())
	row2.add_child(_port_spin)

	_server_btn = Button.new()
	_server_btn.text = "Start"
	_server_btn.pressed.connect(_on_start_server_pressed)
	row2.add_child(_server_btn)

	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.visible = false
	_stop_btn.pressed.connect(_on_stop_server_pressed)
	row2.add_child(_stop_btn)

	var check_btn := Button.new()
	check_btn.text = "↺"
	check_btn.tooltip_text = "Check server connection"
	check_btn.pressed.connect(_check_server)
	row2.add_child(check_btn)

	# ── Row 2: hint text ──────────────────────────────────────────────────────
	_server_hint = Label.new()
	_server_hint.text = "Starts  python3 server/claude_server.py  in the background. Requires Python 3 and the claude CLI in your PATH."
	_server_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_server_hint.add_theme_color_override("font_color", C_SYSTEM)
	vbox.add_child(_server_hint)

	return _server_box


func _build_chat_area() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.selection_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_log.custom_minimum_size.y = 120
	scroll.add_child(_chat_log)

	_log_system("Starting bridge server…")
	return scroll


func _build_proposal_box() -> PanelContainer:
	_proposal_box = PanelContainer.new()
	_proposal_box.visible = false

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_proposal_box.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Claude wants to write these files — approve?"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2))
	header.add_child(title)

	_apply_btn = Button.new()
	_apply_btn.text = "✔ Apply"
	_apply_btn.pressed.connect(_on_apply_pressed)
	header.add_child(_apply_btn)

	_cancel_btn = Button.new()
	_cancel_btn.text = "✘ Cancel"
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	header.add_child(_cancel_btn)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 80
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_proposal_log = RichTextLabel.new()
	_proposal_log.bbcode_enabled = true
	_proposal_log.selection_enabled = true
	_proposal_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_proposal_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_proposal_log)

	return _proposal_box


func _build_diff_box() -> PanelContainer:
	_diff_box = PanelContainer.new()
	_diff_box.visible = false

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_diff_box.add_child(vbox)

	# Header row
	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Changes made by Claude  —  review before accepting:"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	header.add_child(title)

	_accept_btn = Button.new()
	_accept_btn.text = "✔ Accept"
	_accept_btn.pressed.connect(_on_accept_pressed)
	header.add_child(_accept_btn)

	_reject_btn = Button.new()
	_reject_btn.text = "✘ Reject"
	_reject_btn.pressed.connect(_on_reject_pressed)
	header.add_child(_reject_btn)

	# Diff viewer
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 100
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_diff_log = RichTextLabel.new()
	_diff_log.bbcode_enabled = true
	_diff_log.selection_enabled = true
	_diff_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diff_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_diff_log)

	return _diff_box


func _build_context_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()

	var lbl := Label.new()
	lbl.text = "Include:"
	bar.add_child(lbl)

	_context_script = CheckBox.new()
	_context_script.text = "Current Script"
	bar.add_child(_context_script)

	_context_scene = CheckBox.new()
	_context_scene.text = "Scene Info"
	bar.add_child(_context_scene)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var new_chat_btn := Button.new()
	new_chat_btn.text = "New Chat"
	new_chat_btn.pressed.connect(_on_new_chat_pressed)
	bar.add_child(new_chat_btn)

	return bar


func _build_input_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)

	_input = TextEdit.new()
	_input.placeholder_text = "Ask Claude anything about your Godot project… (Enter to send, Shift+Enter for newline)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size.y = 56
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.gui_input.connect(_on_input_gui_input)
	bar.add_child(_input)

	var btn_col := VBoxContainer.new()

	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.custom_minimum_size.x = 70
	_send_btn.pressed.connect(_on_send_pressed)
	btn_col.add_child(_send_btn)

	_clear_btn = Button.new()
	_clear_btn.text = "Clear"
	_clear_btn.custom_minimum_size.x = 70
	_clear_btn.pressed.connect(func(): _chat_log.clear())
	btn_col.add_child(_clear_btn)

	bar.add_child(btn_col)
	return bar


func _build_run_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)

	var lbl := Label.new()
	lbl.text = "Run task:"
	bar.add_child(lbl)

	_run_input = LineEdit.new()
	_run_input.placeholder_text = "e.g. 'Review this script for bugs'"
	_run_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_run_input.text_submitted.connect(func(_t): _on_run_pressed())
	bar.add_child(_run_input)

	_run_btn = Button.new()
	_run_btn.text = "Run"
	_run_btn.pressed.connect(_on_run_pressed)
	bar.add_child(_run_btn)

	return bar


# ── Server management ─────────────────────────────────────────────────────────

func _check_server() -> void:
	if _client.is_busy():
		return  # a chat/run request is in flight; skip the status ping
	_client.base_url = "http://127.0.0.1:%d" % int(_port_spin.value)
	_client.check_status()


func _on_startup_check() -> void:
	_starting_up = false
	_check_server()


func _on_start_server_pressed() -> void:
	if _server_running:
		return

	if plugin == null:
		_log_system(
			"Plugin reference not set. Run server/start_server.sh manually.",
			C_ERROR
		)
		return

	_server_btn.disabled = true
	_server_btn.text = "…"
	_server_hint.text = "Launching bridge server…"

	var pid: int = plugin.call("start_server", int(_port_spin.value))

	if pid > 0:
		_log_system("Bridge server started (PID %d). Waiting for it to come online…" % pid)
		# Give Python a moment to bind the port, then check.
		await get_tree().create_timer(1.5).timeout
		_check_server()
	else:
		_server_btn.disabled = false
		_server_btn.text = "Start"
		_server_hint.text = "Auto-start failed. Check that Python 3 is in your PATH, or run  server/start_server.sh  manually."
		_log_system(
			"Could not launch server automatically. See hint above.",
			C_ERROR
		)


func _on_stop_server_pressed() -> void:
	if plugin != null:
		plugin.call("_stop_server")
	_server_running = false
	_update_server_box()
	_log_system("Server stopped.")


func _on_placement_btn_pressed() -> void:
	if plugin != null:
		plugin.call("toggle_placement")
		_sync_placement_btn()


func _sync_placement_btn() -> void:
	if plugin == null:
		return
	var docked: bool = EditorInterface.get_editor_settings().get_setting("goclau/use_side_dock")
	if docked:
		_placement_btn.text = "⇄ Bottom"
		_placement_btn.tooltip_text = "Move to bottom panel"
	else:
		_placement_btn.text = "⇄ Dock"
		_placement_btn.tooltip_text = "Move to side dock"


func _update_server_box() -> void:
	_status_dot.add_theme_color_override(
		"font_color", C_STATUS_OK if _server_running else C_STATUS_ERR
	)
	_status_label.text = (
		"Bridge server online  (http://127.0.0.1:%d)" % int(_port_spin.value)
		if _server_running else
		"Bridge server offline"
	)
	_server_btn.text    = "Start"
	_server_btn.visible = not _server_running
	_server_btn.disabled = false
	_stop_btn.visible   = _server_running
	_server_hint.text = "Server is running. Claude Code is ready to use." if _server_running else "Starts  python3 server/claude_server.py  in the background. Requires Python 3 and the claude CLI in your PATH."


# ── Sending messages ──────────────────────────────────────────────────────────

func _on_send_pressed() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty() or _waiting:
		return
	_send_message(text)


func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ENTER:
		if event.shift_pressed:
			pass  # let TextEdit insert a newline normally
		else:
			_on_send_pressed()
			_input.accept_event()


func _on_run_pressed() -> void:
	var cmd := _run_input.text.strip_edges()
	if cmd.is_empty() or _waiting:
		return

	_hide_diff_box()
	_set_waiting(true)
	_log_user("[Run] " + cmd)
	_pending_cwd = ProjectSettings.globalize_path("res://")
	_client.run_command(cmd, _pending_cwd, _gather_context())
	_run_input.clear()


func _on_accept_pressed() -> void:
	_log_system("Changes accepted.")
	_hide_diff_box()


func _on_reject_pressed() -> void:
	_reject_btn.disabled = true
	_accept_btn.disabled = true
	_client.reject_changes(_pending_cwd)


func _hide_diff_box() -> void:
	_diff_box.visible = false
	_diff_log.clear()
	_pending_cwd = ""


func _show_diff(diff: String) -> void:
	_diff_log.clear()
	for line in diff.split("\n"):
		if line.begins_with("+") and not line.begins_with("+++"):
			_diff_log.append_text("[color=#78d97a]%s[/color]\n" % _escape(line))
		elif line.begins_with("-") and not line.begins_with("---"):
			_diff_log.append_text("[color=#e06c75]%s[/color]\n" % _escape(line))
		elif line.begins_with("@@"):
			_diff_log.append_text("[color=#c678dd]%s[/color]\n" % _escape(line))
		else:
			_diff_log.append_text("%s\n" % _escape(line))
	_diff_box.visible = true


func _on_apply_pressed() -> void:
	if _pending_proposal.is_empty():
		return
	_apply_btn.disabled = true
	_cancel_btn.disabled = true
	var cwd := ProjectSettings.globalize_path("res://")
	_client.apply_proposed(_pending_proposal, cwd)


func _on_cancel_pressed() -> void:
	_pending_proposal = []
	_proposal_box.visible = false
	_proposal_log.clear()
	_log_system("Proposed changes cancelled.")


func _show_proposal(proposed: Array) -> void:
	_pending_proposal = proposed
	_proposal_log.clear()
	for f in proposed:
		_proposal_log.append_text("[b]%s[/b]\n" % _escape(f.get("path", "?")))
		var preview: String = f.get("content", "")
		if preview.length() > 300:
			preview = preview.left(300) + "\n…"
		_proposal_log.append_text("[code]%s[/code]\n\n" % _escape(preview))
	_apply_btn.disabled = false
	_cancel_btn.disabled = false
	_proposal_box.visible = true


func _send_message(message: String) -> void:
	_set_waiting(true)
	_log_user(message)
	_input.clear()
	_client.send_message(message, _gather_context())


func _gather_context() -> String:
	var parts: Array[String] = []
	if _context_script.button_pressed:
		var s := _get_current_script_context()
		if not s.is_empty():
			parts.append(s)
	if _context_scene.button_pressed:
		var s := _get_current_scene_context()
		if not s.is_empty():
			parts.append(s)
	return "\n\n".join(parts)


func _get_current_script_context() -> String:
	if not Engine.is_editor_hint():
		return ""
	var editor := EditorInterface.get_script_editor()
	if not editor:
		return ""
	var current := editor.get_current_script()
	if not current:
		return ""
	var src := current.source_code
	if src.is_empty():
		return ""
	return "=== Current Script: %s ===\n```gdscript\n%s\n```" % [
		current.resource_path, src
	]


func _get_current_scene_context() -> String:
	if not Engine.is_editor_hint():
		return ""
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return ""
	return "=== Current Scene: %s ===\n%s" % [
		root.scene_file_path, _describe_node(root, 0)
	]


func _describe_node(node: Node, depth: int) -> String:
	var indent := "  ".repeat(depth)
	var line := "%s- %s (%s)" % [indent, node.name, node.get_class()]
	var lines := [line]
	if depth < 3:
		for child in node.get_children():
			lines.append(_describe_node(child, depth + 1))
	elif node.get_child_count() > 0:
		lines.append("%s  … (%d more children)" % [indent, node.get_child_count()])
	return "\n".join(lines)


func _on_new_chat_pressed() -> void:
	_client.reset_conversation()
	_log_system("Conversation reset.")


# ── Response handling ─────────────────────────────────────────────────────────

func _on_response(payload: Dictionary) -> void:
	_set_waiting(false)

	# /status ping or /reset confirmation
	if payload.has("status"):
		var ok: bool = payload.get("status") == "ok"
		if ok and not _server_running:
			_server_running = true
			_update_server_box()
		elif not ok:
			_server_running = false
			_update_server_box()

		if payload.get("reverted", false):
			_log_system("Changes reverted.")
			_hide_diff_box()
			return

		# /apply confirmation — proposed chat writes were applied
		if payload.get("written_files") != null and payload.get("diff") != null:
			_pending_proposal = []
			_proposal_box.visible = false
			_proposal_log.clear()
			var written: Array = payload.get("written_files", [])
			if written.size() > 0:
				_log_system("Applied: " + ", ".join(written))
			if payload.get("has_changes", false):
				_show_diff(payload.get("diff", ""))
				_accept_btn.disabled = false
				_reject_btn.disabled = false
				_pending_cwd = ProjectSettings.globalize_path("res://")
				_log_system("Review the diff above then Accept or Reject.")
		return

	# Run response — may include a diff for review
	if payload.get("type", "") == "run":
		var response: String = payload.get("response", "(empty response)")
		_log_assistant(response)
		var written: Array = payload.get("written_files", [])
		if written.size() > 0:
			_log_system("Files written: " + ", ".join(written))
		if payload.get("has_changes", false):
			_show_diff(payload.get("diff", ""))
			_accept_btn.disabled = false
			_reject_btn.disabled = false
			_log_system("Review the diff above then Accept or Reject.")
		elif not payload.get("has_git", true):
			_log_system("No git repo — changes already saved, cannot revert.", C_ERROR)
		else:
			_log_system("No file changes were made.")
		return

	# Regular chat response — may include proposed file writes
	var response: String = payload.get("response", "(empty response)")
	_log_assistant(response)
	var proposed: Array = payload.get("proposed_writes", [])
	if proposed.size() > 0:
		_show_proposal(proposed)


func _on_error(error: String) -> void:
	_set_waiting(false)
	if "Connection refused" in error or "Network error" in error or "Failed" in error:
		_server_running = false
		_update_server_box()
		if _starting_up:
			return  # expected during the 3 s startup window — don't log noise
	_log_system("Error: " + error, C_ERROR)


func _set_waiting(waiting: bool) -> void:
	_waiting = waiting
	_send_btn.disabled = waiting
	_run_btn.disabled = waiting
	_send_btn.text = "…" if waiting else "Send"


# ── Log helpers ───────────────────────────────────────────────────────────────

func _log_user(text: String) -> void:
	_chat_log.append_text(
		"\n[color=#%s][b]You:[/b][/color] %s\n" % [C_USER.to_html(false), _escape(text)]
	)


func _log_assistant(text: String) -> void:
	_chat_log.append_text(
		"\n[color=#%s][b]Claude:[/b][/color]\n%s\n" % [
			C_ASSISTANT.to_html(false), _format_markdown(text)
		]
	)


func _log_system(text: String, color: Color = C_SYSTEM) -> void:
	_chat_log.append_text(
		"\n[color=#%s][i]%s[/i][/color]\n" % [color.to_html(false), text]
	)


func _escape(text: String) -> String:
	return text.replace("[", "[[")


func _format_markdown(text: String) -> String:
	var result := text

	var re_code := RegEx.new()
	re_code.compile("```[a-z]*\\n([\\s\\S]*?)```")
	for m in re_code.search_all(result):
		var code := m.get_string(1).replace("[", "[[")
		result = result.replace(m.get_string(), "[code]%s[/code]" % code)

	var re_inline := RegEx.new()
	re_inline.compile("`([^`]+)`")
	for m in re_inline.search_all(result):
		result = result.replace(m.get_string(), "[code]%s[/code]" % m.get_string(1))

	var re_bold := RegEx.new()
	re_bold.compile("\\*\\*(.+?)\\*\\*")
	for m in re_bold.search_all(result):
		result = result.replace(m.get_string(), "[b]%s[/b]" % m.get_string(1))

	return result
