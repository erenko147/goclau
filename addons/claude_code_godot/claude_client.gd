## Thin async wrapper around the claude_server.py HTTP API.
## Emits response_received(payload: Dictionary) on success,
## or request_failed(error: String) on error.
@tool
extends Node

signal response_received(payload: Dictionary)
signal request_failed(error: String)

var base_url: String = "http://127.0.0.1:9876"

var _http: HTTPRequest
var _busy: bool = false


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func is_busy() -> bool:
	return _busy


func check_status() -> void:
	_do_get("/status")


func send_message(message: String, context: String = "") -> void:
	_do_post("/chat", {"message": message, "context": context})


func reset_conversation() -> void:
	_do_post("/reset", {})


func run_command(command: String, cwd: String = "") -> void:
	var body := {"command": command}
	if not cwd.is_empty():
		body["cwd"] = cwd
	_do_post("/run", body)


# ------------------------------------------------------------------
func _do_get(path: String) -> void:
	if _busy:
		return  # silently drop; caller should guard with is_busy()
	_busy = true
	var err := _http.request(base_url + path)
	if err != OK:
		_busy = false
		request_failed.emit("HTTPRequest error: %d" % err)


func _do_post(path: String, payload: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var body := JSON.stringify(payload)
	var headers := ["Content-Type: application/json"]
	var err := _http.request(base_url + path, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_busy = false
		request_failed.emit("HTTPRequest error: %d" % err)


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("Network error (result=%d)" % result)
		return

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		request_failed.emit("Invalid JSON response")
		return

	if response_code >= 400:
		request_failed.emit(parsed.get("error", "Server error %d" % response_code))
		return

	response_received.emit(parsed)
