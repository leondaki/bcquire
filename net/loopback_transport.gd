extends NetworkTransport
class_name LoopbackTransport
## In-process fake transport: no sockets, no Node, no serialization — every
## "send" is a direct signal emission to the matching transport object(s) on
## the shared LoopbackHub. This lets net/session.gd's host-authoritative logic
## be exercised headlessly (sim/run_network_tests.gd) with the exact same code
## path real networking will use later, swapping in net/enet_transport.gd
## without touching net/session.gd at all.
##
## Peer id 0 is always the host (hub.transports[0]); joiners take 1, 2, ...

var hub: LoopbackHub
var peer_id: int
var _host: bool

## peer_id is assigned by registration order on the hub — the first transport
## created on a given hub is always peer 0 (the host).
func _init(p_hub: LoopbackHub, p_is_host: bool) -> void:
	hub = p_hub
	_host = p_is_host
	peer_id = hub.transports.size()
	hub.register(self)

func host(_port: int = 0) -> Error:
	return OK

func join(_address: String = "", _port: int = 0) -> Error:
	return OK

func send_action(action: Dictionary) -> void:
	var host_transport: LoopbackTransport = hub.transports[0]
	host_transport.action_received.emit(action, peer_id)

func broadcast_event(event: Dictionary) -> void:
	for t in hub.transports:
		if t != self:
			t.event_received.emit(event)

func send_event_to(target_peer_id: int, event: Dictionary) -> void:
	for t in hub.transports:
		if t.peer_id == target_peer_id:
			t.event_received.emit(event)
			return

func is_host() -> bool:
	return _host

func local_peer_id() -> int:
	return peer_id
