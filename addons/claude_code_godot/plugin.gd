@tool
extends EditorPlugin

const ClaudePanel = preload("res://addons/claude_code_godot/claude_panel.gd")

var _panel: Control
var _server_pid: int = -1


func _enter_tree() -> void:
	_panel = ClaudePanel.new()
	add_control_to_bottom_panel(_panel, "Claude")
	_try_start_server()


func _exit_tree() -> void:
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	_stop_server()


func _try_start_server() -> void:
	# Only auto-start if user has opted in via the panel setting.
	# The panel handles the auto-start toggle; this is a no-op hook.
	pass


func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


# Called by the panel when the user clicks "Start Server".
func start_server(port: int) -> int:
	if _server_pid > 0:
		return _server_pid

	var server_script := _find_server_script()
	if server_script.is_empty():
		return -1

	var args := ["python3", server_script, str(port)]
	# On Windows use "python" instead of "python3".
	if OS.get_name() == "Windows":
		args[0] = "python"

	_server_pid = OS.create_process(args[0], args.slice(1))
	return _server_pid


func _find_server_script() -> String:
	# Try path relative to the addon first, then relative to project root.
	var candidates := [
		ProjectSettings.globalize_path("res://addons/claude_code_godot/../../server/claude_server.py"),
		ProjectSettings.globalize_path("res://server/claude_server.py"),
	]
	for path in candidates:
		if FileAccess.file_exists(path):
			return path
	return ""
