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

## A joining/reconnecting peer announcing its chosen display name to the
## host — also not part of the core Action/Event contract. ui/game/game.gd
## uses this both to label a fresh joiner's seat correctly (instead of
## "Player N") and, if the name matches a seat currently marked disconnected,
## to recognize a returning player and resync them.
signal peer_hello(peer_id: int, name: String)

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

## Closing the socket and dropping the high-level signal connections must
## happen here, not just at the call site that frees this node: the socket
## and `multiplayer.peer_connected`/etc connections live on the SceneTree's
## shared MultiplayerAPI, not on this Node, so freeing the node alone (e.g.
## a scene change back to the main menu) leaves the ENet socket open and the
## signal bindings pointing at a freed object. _exit_tree() fires on every
## teardown path (queue_free, scene change, app quit), so this is the one
## place that reliably closes things down before a second game can be
## hosted/joined in the same process.
func _exit_tree() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null

## Host-only: forcibly drop a peer, e.g. when the lobby is already full.
func kick_peer(peer_id: int) -> void:
	multiplayer.multiplayer_peer.disconnect_peer(peer_id)


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

## Lobby-only: announce this peer's chosen display name to the host. Always
## sent to peer id 1, same convention as send_action.
func send_hello(name: String) -> void:
	_rpc_hello.rpc_id(1, name)


# ===========================================================================
#  RPC wire methods — the only place packets actually move
# ===========================================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_send_action(action: Dictionary) -> void:
	action_received.emit(action, multiplayer.get_remote_sender_id())

@rpc("authority", "call_remote", "reliable")
func _rpc_deliver_event(event: Dictionary) -> void:
	event_received.emit(event)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(name: String) -> void:
	peer_hello.emit(multiplayer.get_remote_sender_id(), name)
