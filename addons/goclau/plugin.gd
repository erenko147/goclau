@tool
extends EditorPlugin

const ClaudePanel = preload("res://addons/goclau/claude_panel.gd")
const SETTING_DOCKED = "goclau/use_side_dock"

var _panel: Control
var _server_pid: int = -1
var _docked: bool = false


func _enter_tree() -> void:
	_panel = ClaudePanel.new()
	_panel.plugin = self
	_panel.name = "GoClau"

	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_DOCKED):
		settings.set_setting(SETTING_DOCKED, false)
	_docked = settings.get_setting(SETTING_DOCKED)

	_add_panel()
	start_server(9876)  # auto-start; panel's delayed check will confirm it's ready


func _exit_tree() -> void:
	if _panel:
		_remove_panel()
		_panel.queue_free()
		_panel = null
	_stop_server()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_stop_server()


# ── Panel placement ───────────────────────────────────────────────────────────

func _add_panel() -> void:
	if _docked:
		add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)
	else:
		add_control_to_bottom_panel(_panel, "GoClau")


func _remove_panel() -> void:
	if _docked:
		remove_control_from_docks(_panel)
	else:
		remove_control_from_bottom_panel(_panel)


# Called by the panel's placement toggle button.
func toggle_placement() -> void:
	_remove_panel()
	# Detach from the scene tree parent before re-adding to a different location.
	if _panel.get_parent():
		_panel.get_parent().remove_child(_panel)
	_docked = not _docked
	EditorInterface.get_editor_settings().set_setting(SETTING_DOCKED, _docked)
	_add_panel()
	if not _docked:
		make_bottom_panel_item_visible(_panel)


# ── Server ────────────────────────────────────────────────────────────────────

func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


func start_server(port: int) -> int:
	if _server_pid > 0:
		return _server_pid

	var script := ProjectSettings.globalize_path(
		"res://addons/goclau/server/claude_server.py"
	)
	var python := "python" if OS.get_name() == "Windows" else "python3"
	_server_pid = OS.create_process(python, [script, str(port)])
	return _server_pid
