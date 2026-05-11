@tool
extends EditorPlugin

const ClaudePanel = preload("res://addons/claude_code_godot/claude_panel.gd")

var _panel: Control
var _server_pid: int = -1


func _enter_tree() -> void:
	_panel = ClaudePanel.new()
	_panel.plugin = self
	_panel.name = "GoClau"  # shown as the dock tab label
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)


func _exit_tree() -> void:
	if _panel:
		remove_control_from_docks(_panel)
		_panel.queue_free()
		_panel = null
	_stop_server()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_stop_server()


func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


# Called by the panel when the user clicks "Start Server".
func start_server(port: int) -> int:
	if _server_pid > 0:
		return _server_pid

	var script := ProjectSettings.globalize_path(
		"res://addons/claude_code_godot/server/claude_server.py"
	)
	var python := "python" if OS.get_name() == "Windows" else "python3"
	_server_pid = OS.create_process(python, [script, str(port)])
	return _server_pid
