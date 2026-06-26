extends RefCounted
class_name LoopbackHub
## The shared "wire" for a set of LoopbackTransport instances in one process.
## Index in `transports` is the peer id; index 0 is always the host.

var transports: Array[LoopbackTransport] = []

func register(transport: LoopbackTransport) -> void:
	transports.append(transport)
