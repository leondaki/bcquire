extends Node
class_name EnetTransport
## Real LAN transport, backed by Godot's built-in ENetMultiplayerPeer + the
## high-level multiplayer/RPC API. This is the ONE file in the project allowed
## to touch Node/multiplayer — Godot's high-level RPC system requires a Node
## in the scene tree (so a peer's RPC lands on the matching node at the same
## NodePath on every machine), which is incompatible with NetworkTransport's
## RefCounted base. EnetTransport therefore does not literally extend
## NetworkTransport — GDScript has no enforced interfaces, so it simply
## exposes the identical method names and signals net/session.gd already
## calls on net/loopback_transport.gd, making it a drop-in swap in practice.
## A future steam_transport.gd (M6) would follow the same pattern.
##
## Must be add_child()'d onto the same NodePath on every peer (ui/game/game.gd
## always adds it directly under itself) for RPC routing to find the matching
## node on the other side.
##
## Godot's high-level multiplayer always assigns the host/server peer id 1;
## client ids are assigned by ENet and are not sequential by join order, so
## (unlike LoopbackTransport) peer id is NOT a usable seat index here — seat
## assignment is handled separately via GAME_STARTED's peer_seats payload
## (see net/session.gd).

signal action_received(action: Dictionary, from_peer_id: int)
signal event_received(event: Dictionary)
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

## Lobby-feedback signals — not part of the core Action/Event contract (the
## loopback transport never fails to "connect"), but useful for the lobby UI
## to report success/failure of a join attempt.
signal join_succeeded
signal join_failed(reason: String)

var _is_host_flag: bool = false

func host(port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_is_host_flag = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return OK

func join(address: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		join_failed.emit("Could not start connecting (error %d)." % err)
		return err
	multiplayer.multiplayer_peer = peer
	_is_host_flag = false
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	return OK

func _on_peer_connected(id: int) -> void:
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	peer_left.emit(id)

func _on_connected_to_server() -> void:
	join_succeeded.emit()

func _on_connection_failed() -> void:
	join_failed.emit("Connection refused or timed out.")

func _on_server_disconnected() -> void:
	peer_left.emit(1)  # the server is always peer id 1


# ===========================================================================
#  NetworkTransport contract
# ===========================================================================

func send_action(action: Dictionary) -> void:
	_rpc_send_action.rpc_id(1, action)  # 1 = the server/host, always

func broadcast_event(event: Dictionary) -> void:
	_rpc_deliver_event.rpc(event)  # to every OTHER connected peer; not called locally

func send_event_to(peer_id: int, event: Dictionary) -> void:
	_rpc_deliver_event.rpc_id(peer_id, event)

func is_host() -> bool:
	return _is_host_flag

func local_peer_id() -> int:
	return multiplayer.get_unique_id()


# ===========================================================================
#  RPC wire methods — the only place packets actually move
# ===========================================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_send_action(action: Dictionary) -> void:
	action_received.emit(action, multiplayer.get_remote_sender_id())

@rpc("authority", "call_remote", "reliable")
func _rpc_deliver_event(event: Dictionary) -> void:
	event_received.emit(event)
