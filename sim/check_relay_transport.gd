extends SceneTree
## Real-socket smoke test for net/relay_transport.gd: runs a host and a
## joiner RelayTransport in this SAME process, both talking to a real
## relay-server/ instance over an actual WebSocket connection (no mocking) —
## possible because, unlike EnetTransport, RelayTransport doesn't depend on
## Godot's per-process multiplayer singleton, so two instances can coexist.
## Exercises the full handshake + Action/Event round trip, including a
## Vector2i-bearing payload, to confirm var_to_bytes/bytes_to_var encoding
## survives the relay's JSON envelope untouched.
##
## Prerequisite: a relay-server/ instance must already be running locally
## (`node relay-server/server.js`) before this script starts.
##
## Run with:
##   godot --headless --path <proj> --script sim/check_relay_transport.gd
## Expected output: "==== N passed, 0 failed ====" and exit code 0.

const RELAY_URL := "ws://127.0.0.1:8080"

var passed := 0
var failed := 0
var _done := false

var _room_code := ""
var _join_ok := false
var _join_err := ""
var _host_saw_peer := -1
var _host_saw_hello_id := -1
var _host_saw_hello_name := ""
var _received_action: Variant = null
var _received_from := -1
var _received_event: Variant = null
var _host_saw_left := -1

func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + msg)

func eq(got, expected, msg: String) -> void:
	check(got == expected, "%s (got %s, expected %s)" % [msg, str(got), str(expected)])

func _initialize() -> void:
	_watchdog()
	_run()

func _watchdog() -> void:
	await create_timer(10.0).timeout
	if not _done:
		print("FAIL: test timed out after 10s (is relay-server/server.js running on 127.0.0.1:8080?)")
		quit(1)

func _on_room_code_ready(code: String) -> void:
	_room_code = code

func _on_join_succeeded() -> void:
	_join_ok = true

func _on_join_failed(reason: String) -> void:
	_join_err = reason

func _on_host_peer_joined(pid: int) -> void:
	_host_saw_peer = pid

func _on_host_peer_hello(pid: int, name: String) -> void:
	_host_saw_hello_id = pid
	_host_saw_hello_name = name

func _on_host_action_received(action: Dictionary, from_peer: int) -> void:
	_received_action = action
	_received_from = from_peer

func _on_joiner_event_received(event: Dictionary) -> void:
	_received_event = event

func _on_host_peer_left(pid: int) -> void:
	_host_saw_left = pid

func _run() -> void:
	var host := RelayTransport.new()
	var joiner := RelayTransport.new()
	root.add_child(host)
	root.add_child(joiner)

	# All signal handlers are wired up-front, exactly as ui/game/game.gd does
	# right after constructing a transport — events can arrive the instant a
	# request is sent, so connecting "just before" the matching wait loop
	# below would miss anything that already fired.
	host.room_code_ready.connect(_on_room_code_ready)
	host.peer_joined.connect(_on_host_peer_joined)
	host.peer_hello.connect(_on_host_peer_hello)
	host.action_received.connect(_on_host_action_received)
	host.peer_left.connect(_on_host_peer_left)
	joiner.join_succeeded.connect(_on_join_succeeded)
	joiner.join_failed.connect(_on_join_failed)
	joiner.event_received.connect(_on_joiner_event_received)

	host.host_relay(RELAY_URL)
	while _room_code == "":
		await process_frame
	check(_room_code.length() == 6, "host received a 6-char room code (got '%s')" % _room_code)

	joiner.join_relay(RELAY_URL, _room_code)
	while not _join_ok and _join_err == "":
		await process_frame
	check(_join_ok, "joiner connected with the host's code (err: %s)" % _join_err)

	while _host_saw_peer == -1:
		await process_frame
	eq(_host_saw_peer, joiner.local_peer_id(), "host's peer_joined id matches joiner's assigned peer id")
	eq(host.local_peer_id(), 1, "host is always peer id 1")

	joiner.send_hello("Remote Player")
	while _host_saw_hello_id == -1:
		await process_frame
	eq(_host_saw_hello_name, "Remote Player", "host received the joiner's hello name")

	var sent_action := {"type": "place_tile", "player": 1, "payload": {"coord": Vector2i(5, 3)}}
	joiner.send_action(sent_action)
	while _received_action == null:
		await process_frame
	eq(_received_action, sent_action, "host received the exact Action dict, Vector2i intact")
	eq(_received_from, joiner.local_peer_id(), "action's from_peer_id matches the joiner")

	var sent_event := {"type": "tile_placed", "payload": {"coord": Vector2i(5, 3), "kind": 1}}
	host.broadcast_event(sent_event)
	while _received_event == null:
		await process_frame
	eq(_received_event, sent_event, "joiner received the exact Event dict broadcast by host")

	joiner.queue_free()
	while _host_saw_left == -1:
		await process_frame
	eq(_host_saw_left, _received_from, "host saw peer_left for the joiner that disconnected")

	host.queue_free()
	_done = true
	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)
