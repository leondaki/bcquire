extends Node
class_name RelayTransport
## Internet-play transport: relays Action/Event packets through a small
## WebSocket relay server (see relay-server/) instead of connecting peers
## directly. Every peer — including the host — only ever makes an outbound
## connection to the relay, so this works through any home router/NAT/CGNAT
## with no port-forwarding, at the cost of an extra server hop (irrelevant
## for this turn-based game's tiny, infrequent messages).
##
## Exposes the same duck-typed method/signal surface as net/enet_transport.gd
## so net/session.gd and ui/game/game.gd's lobby code don't need to know
## which transport they're holding. Unlike EnetTransport, this does not use
## Godot's high-level multiplayer/@rpc system at all — it's a self-contained
## WebSocket client speaking the relay's own small JSON protocol (see
## relay-server/server.js's wire format), so there's no NodePath/scene-tree
## naming requirement.

signal action_received(action: Dictionary, from_peer_id: int)
signal event_received(event: Dictionary)
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

## Lobby-feedback signals — see net/enet_transport.gd for why these exist
## outside the core Action/Event contract.
signal join_succeeded
signal join_failed(reason: String)
signal peer_hello(peer_id: int, name: String)

## Host-only: fired once the relay confirms room creation, with the short
## code the host should share with other players.
signal room_code_ready(code: String)

var _socket: WebSocketPeer
var _is_host_flag: bool = false
var _local_peer_id: int = -1
var _pending_join_code: String = ""
var _sent_initial_request: bool = false

func host_relay(relay_url: String) -> Error:
	_is_host_flag = true
	return _connect(relay_url)

func join_relay(relay_url: String, code: String) -> Error:
	_is_host_flag = false
	_pending_join_code = code
	return _connect(relay_url)

func _connect(relay_url: String) -> Error:
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(relay_url)
	if err != OK:
		join_failed.emit("Could not start connecting to relay (error %d)." % err)
	return err

func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not _sent_initial_request:
		_sent_initial_request = true
		if _is_host_flag:
			_send_raw({"type": "create_room"})
		else:
			_send_raw({"type": "join_room", "code": _pending_join_code})
	elif state == WebSocketPeer.STATE_CLOSED:
		# Distinguish "never finished joining" from "was already in a
		# session and the relay connection dropped" — the latter, for a
		# non-host peer, has the same observable effect as the host
		# disconnecting (every message flows through the relay), so it
		# reuses EnetTransport's peer_left(1) convention.
		if _sent_initial_request and not _is_host_flag and _local_peer_id != -1:
			peer_left.emit(1)
		elif _sent_initial_request and _local_peer_id == -1:
			join_failed.emit("Lost connection to relay.")
		set_process(false)
		return

	while _socket.get_available_packet_count() > 0:
		var raw := _socket.get_packet().get_string_from_utf8()
		var msg: Variant = JSON.parse_string(raw)
		if msg is Dictionary:
			_handle_message(msg)

func _handle_message(msg: Dictionary) -> void:
	match msg.get("type", ""):
		"room_created":
			_local_peer_id = 1
			room_code_ready.emit(msg.get("code", ""))
		"joined":
			_local_peer_id = msg.get("peer_id", -1)
			join_succeeded.emit()
		"join_failed":
			join_failed.emit(msg.get("reason", "Join failed."))
		"peer_joined":
			peer_joined.emit(msg.get("peer_id", -1))
		"peer_left":
			peer_left.emit(msg.get("peer_id", -1))
		"deliver":
			_handle_deliver(msg)

func _handle_deliver(msg: Dictionary) -> void:
	var from_peer: int = msg.get("from", -1)
	var kind: String = msg.get("kind", "")
	var payload: Variant = _decode(msg.get("payload", ""))
	match kind:
		"action":
			action_received.emit(payload, from_peer)
		"event":
			event_received.emit(payload)
		"hello":
			peer_hello.emit(from_peer, payload.get("name", ""))

func _send_raw(msg: Dictionary) -> void:
	if _socket != null:
		_socket.send_text(JSON.stringify(msg))

func _encode(v: Variant) -> String:
	return Marshalls.raw_to_base64(var_to_bytes(v))

func _decode(s: String) -> Variant:
	return bytes_to_var(Marshalls.base64_to_raw(s))

## Closing the socket must happen here, not just at the call site that frees
## this node, for the same reason EnetTransport closes its socket in
## _exit_tree() — this is the one place that reliably runs on every teardown
## path (queue_free, scene change, app quit).
func _exit_tree() -> void:
	if _socket != null:
		_socket.close()
		_socket = null

## Host-only: forcibly drop a peer, e.g. when the lobby is already full.
## Mirrors EnetTransport.kick_peer's signature so ui/game/game.gd's lobby
## code can call it without knowing which transport it's holding.
func kick_peer(peer_id: int) -> void:
	_send_raw({"type": "kick", "peer_id": peer_id})


# ===========================================================================
#  NetworkTransport contract
# ===========================================================================

func send_action(action: Dictionary) -> void:
	_send_raw({"type": "send", "to": "host", "kind": "action", "payload": _encode(action)})

func broadcast_event(event: Dictionary) -> void:
	_send_raw({"type": "send", "to": "all", "kind": "event", "payload": _encode(event)})

func send_event_to(peer_id: int, event: Dictionary) -> void:
	_send_raw({"type": "send", "to": peer_id, "kind": "event", "payload": _encode(event)})

func is_host() -> bool:
	return _is_host_flag

func local_peer_id() -> int:
	return _local_peer_id

## Lobby-only: announce this peer's chosen display name to the host. Always
## sent to peer id 1, same convention as send_action.
func send_hello(name: String) -> void:
	_send_raw({"type": "send", "to": "host", "kind": "hello", "payload": _encode({"name": name})})
