extends RefCounted
class_name NetworkTransport
## Abstract transport interface used by net/session.gd. GDScript has no formal
## interfaces, so this base class documents the contract and fails loudly if a
## subclass forgets to override a method. net/loopback_transport.gd (no
## sockets, headlessly testable) and net/enet_transport.gd (real LAN play) are
## the two implementations; a future steam_transport.gd (M6) is a third,
## interchangeable behind this same surface.

signal action_received(action: Dictionary, from_peer_id: int)  # host-side: a client sent an action
signal event_received(event: Dictionary)                        # every peer: an event is ready to apply
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

func host(_port: int) -> Error:
	assert(false, "NetworkTransport.host() is abstract")
	return ERR_UNCONFIGURED

func join(_address: String, _port: int) -> Error:
	assert(false, "NetworkTransport.join() is abstract")
	return ERR_UNCONFIGURED

## Client -> host.
func send_action(_action: Dictionary) -> void:
	assert(false, "NetworkTransport.send_action() is abstract")

## Host -> every other peer.
func broadcast_event(_event: Dictionary) -> void:
	assert(false, "NetworkTransport.broadcast_event() is abstract")

## Host -> one specific peer (used for ACTION_REJECTED replies).
func send_event_to(_peer_id: int, _event: Dictionary) -> void:
	assert(false, "NetworkTransport.send_event_to() is abstract")

func is_host() -> bool:
	assert(false, "NetworkTransport.is_host() is abstract")
	return false

func local_peer_id() -> int:
	assert(false, "NetworkTransport.local_peer_id() is abstract")
	return -1
