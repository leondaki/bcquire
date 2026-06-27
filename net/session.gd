extends RefCounted
class_name GameSession
## Host-authoritative routing layer between a GameState mirror and a
## NetworkTransport. This is the entire surface ui/game/game.gd talks to:
##   session.send_action(action)        — every seat, host or client alike
##   session.event_applied(event)       — connect once; re-render on each event
##   session.state                      — the (mirrored) GameState to read from
##   session.local_player_index         — "is it this seat's turn"
##
## Host authority: a client's Action carries only minimal intent (a coord, a
## chain id, a sell/trade count) — never a precomputed classification. The
## host always independently re-runs the same GameState query/mutation calls
## ui/game/game.gd used to call directly, and broadcasts an Event built from
## the *actual* result. Clients never re-derive an outcome — their handler
## (_apply_event_to_state) replays the identical underlying state.* calls using
## the event's payload, which is what guarantees host/client convergence by
## construction. See sim/run_network_tests.gd for the convergence assertions.
##
## `transport` is deliberately untyped rather than `NetworkTransport`:
## net/enet_transport.gd must extend Node (Godot's high-level RPC system
## requires it) and so can't also extend the RefCounted NetworkTransport base
## that net/loopback_transport.gd uses. Both expose the identical method/
## signal surface NetworkTransport documents; GDScript has no formal
## interfaces to enforce that statically, so it's a duck-typed contract here.

const Phase = AcqEnums.GamePhase
const Kind = AcqEnums.PlacementKind
const Chain = AcqEnums.ChainId

signal event_applied(event: Dictionary)

var state: GameState
var transport
var local_player_index: int
var is_host: bool

## True when there is exactly one human seat driving every player locally
## (today's hotseat mode). Seat-gating in the UI is bypassed while this is
## set; Stage B's lobby flips it off once a second peer actually connects.
var hotseat_mode: bool = false

# Host-only bookkeeping for the merger currently being resolved.
var _disposal_queue: Array = []   # [{ "defunct": int, "player": int }]
var _merge_survivor: int = Chain.NONE
var _last_reject_reason: String = ""


func _init(p_transport, p_is_host: bool, p_local_player_index: int) -> void:
	transport = p_transport
	is_host = p_is_host
	local_player_index = p_local_player_index
	if is_host:
		transport.action_received.connect(_on_action_received_as_host)
	else:
		transport.event_received.connect(_on_event_received_as_client)


# ===========================================================================
#  Host-only: starting a new game
# ===========================================================================

## Deal a fresh game and broadcast the seed so every peer can deal identically
## via the same already-tested seeded shuffle (GameState._fill_and_shuffle_bag).
## Sending the seed, not the dealt result, is the deliberate choice: cheaper on
## the wire and reuses 100% of existing, regression-tested code.
##
## `peer_seats` (transport peer id -> seat index) lets every client learn its
## own seat from this one broadcast event — see Event.make_game_started.
## Pass {} for solo hotseat play (the default loopback session never needs it,
## since hotseat_mode bypasses seat checks anyway).
func host_start_game(player_names: Array, game_seed: int = 0, peer_seats: Dictionary = {}) -> void:
	assert(is_host, "Only the host deals a new game.")
	var seed_to_use := game_seed if game_seed != 0 else randi()
	state = GameState.new()
	state.setup_new_game(player_names, seed_to_use)
	_disposal_queue = []
	var event := Event.make_game_started(player_names, seed_to_use, peer_seats)
	transport.broadcast_event(event)
	event_applied.emit(event)

## Host-only: resync one reconnecting peer to the in-progress GameState
## (rather than waiting for a fresh GAME_STARTED, which only ever fires once).
## Sent privately, not broadcast — every other peer's mirror is already
## current. `peer_seats` reuses the GAME_STARTED convention so the
## reconnecting peer learns its own (unchanged) seat from this one message.
func send_state_sync(peer_id: int, peer_seats: Dictionary) -> void:
	assert(is_host, "Only the host can resync a client.")
	transport.send_event_to(peer_id, Event.make_game_state_sync(state.to_snapshot(), peer_seats))


# ===========================================================================
#  Sending actions (every seat calls this uniformly)
# ===========================================================================

func send_action(action: Dictionary) -> void:
	if is_host:
		_process_action(action, transport.local_peer_id())
	else:
		transport.send_action(action)

func _on_action_received_as_host(action: Dictionary, from_peer_id: int) -> void:
	_process_action(action, from_peer_id)

func _process_action(action: Dictionary, from_peer_id: int) -> void:
	var events = _validate_and_apply(action)
	if events == null:
		var rejection := Event.make_action_rejected(_last_reject_reason, action)
		if from_peer_id == transport.local_peer_id():
			event_applied.emit(rejection)
		else:
			transport.send_event_to(from_peer_id, rejection)
		return
	for event in events:
		transport.broadcast_event(event)
		event_applied.emit(event)


# ===========================================================================
#  Client-side: applying a broadcast event to the local mirror
# ===========================================================================

func _on_event_received_as_client(event: Dictionary) -> void:
	if event.type != Event.ACTION_REJECTED:
		_apply_event_to_state(event)
		if event.type == Event.GAME_STARTED or event.type == Event.GAME_STATE_SYNC:
			var peer_seats: Dictionary = event.payload.get("peer_seats", {})
			if peer_seats.has(transport.local_peer_id()):
				local_player_index = peer_seats[transport.local_peer_id()]
	event_applied.emit(event)

## Mirrors one event onto `state` by calling the exact same GameState methods
## the host already called — never re-deriving an outcome.
func _apply_event_to_state(event: Dictionary) -> void:
	var p: Dictionary = event.payload
	match event.type:
		Event.GAME_STARTED:
			state = GameState.new()
			state.setup_new_game(p.player_names, p.seed)
		Event.GAME_STATE_SYNC:
			state = GameState.new()
			state.apply_snapshot(p.snapshot)
		Event.TILE_PLACED:
			state.remove_from_rack(p.player, p.coord)
			if p.kind == Kind.ISOLATED:
				state.do_isolated(p.coord.x, p.coord.y)
			else:
				state.do_grow(p.coord.x, p.coord.y, p.chain)
			state.phase = Phase.BUY_STOCK
		Event.CHAIN_FOUND_PENDING:
			state.remove_from_rack(p.player, p.coord)
			state.set_cell(p.coord.x, p.coord.y, Chain.NONE)
			state.phase = Phase.FOUND_CHAIN
		Event.CHAIN_FOUNDED:
			state.do_found(p.coord.x, p.coord.y, p.chain)
			state.phase = Phase.BUY_STOCK
		Event.MERGER_PENDING:
			state.remove_from_rack(p.player, p.coord)
			state.set_cell(p.coord.x, p.coord.y, Chain.NONE)
			state.phase = Phase.RESOLVE_MERGER
		Event.MERGER_STARTED:
			state.merger_begin(p.coord.x, p.coord.y, p.survivor)
			_disposal_queue = p.disposal_queue.duplicate(true)
			_merge_survivor = p.survivor
			state.phase = Phase.RESOLVE_MERGER
		Event.STOCK_DISPOSED:
			state.merger_dispose(p.player, p.defunct, p.sell, p.trade)
			if not _disposal_queue.is_empty():
				_disposal_queue.pop_front()
		Event.MERGER_FINISHED:
			state.merger_finish()
			state.phase = Phase.BUY_STOCK
		Event.STOCK_BOUGHT:
			state.buy_stock(p.player, p.order)
		Event.TURN_ENDED:
			state.draw_tile(p.player)
			state.advance_turn()
		Event.TILE_REDRAWN:
			state.remove_from_rack(p.player, p.tile)
			state.draw_tile(p.player)
		Event.GAME_OVER:
			state.compute_final_scores()
			state.phase = Phase.GAME_OVER


# ===========================================================================
#  Host-only: validating + applying an action, building the resulting events
# ===========================================================================

## Returns an Array[Dictionary] of events on success, or null (with
## _last_reject_reason set) if the action is illegal/stale/out of turn.
func _validate_and_apply(action: Dictionary) -> Variant:
	match action.type:
		Action.PLACE_TILE:
			return _apply_place_tile(action)
		Action.CHOOSE_FOUND:
			return _apply_choose_found(action)
		Action.CHOOSE_SURVIVOR:
			return _apply_choose_survivor(action)
		Action.DISPOSE_STOCK:
			return _apply_dispose_stock(action)
		Action.BUY_STOCK:
			return _apply_buy_stock(action)
		Action.REDRAW_TILE:
			return _apply_redraw_tile(action)
	_last_reject_reason = "Unknown action type."
	return null

func _apply_place_tile(action: Dictionary) -> Variant:
	var player: int = action.player
	var coord: Vector2i = action.payload.coord
	if state.phase != Phase.PLACE_TILE or player != state.current_player:
		_last_reject_reason = "Not your turn to place a tile."
		return null
	if not state.players[player].rack.has(coord):
		_last_reject_reason = "That tile is not in your rack."
		return null
	var info := state.classify_placement(coord.x, coord.y)
	if info.kind == Kind.ILLEGAL_DEAD or info.kind == Kind.ILLEGAL_TEMP:
		_last_reject_reason = "That placement is not currently legal."
		return null

	state.remove_from_rack(player, coord)
	match info.kind:
		Kind.ISOLATED:
			state.do_isolated(coord.x, coord.y)
			state.phase = Phase.BUY_STOCK
			return [Event.make_tile_placed(player, coord, Kind.ISOLATED, Chain.NONE)]
		Kind.GROW:
			state.do_grow(coord.x, coord.y, info.chain)
			state.phase = Phase.BUY_STOCK
			return [Event.make_tile_placed(player, coord, Kind.GROW, info.chain)]
		Kind.FOUND:
			state.set_cell(coord.x, coord.y, Chain.NONE)
			state.phase = Phase.FOUND_CHAIN
			return [Event.make_chain_found_pending(player, coord, state.available_chains())]
		_:  # Kind.MERGE
			state.set_cell(coord.x, coord.y, Chain.NONE)
			var minfo := state.merger_info(coord.x, coord.y)
			state.phase = Phase.RESOLVE_MERGER
			var events := [Event.make_merger_pending(player, coord, minfo.survivor_candidates)]
			if minfo.survivor_candidates.size() == 1:
				events.append_array(_begin_merger(coord, minfo.survivor_candidates[0]))
			return events

func _apply_choose_found(action: Dictionary) -> Variant:
	var player: int = action.player
	var coord: Vector2i = action.payload.coord
	var chain: int = action.payload.chain
	if state.phase != Phase.FOUND_CHAIN or player != state.current_player:
		_last_reject_reason = "Not expecting a founding choice right now."
		return null
	if not state.available_chains().has(chain):
		_last_reject_reason = "That chain is not available to found."
		return null
	state.do_found(coord.x, coord.y, chain)
	state.phase = Phase.BUY_STOCK
	return [Event.make_chain_founded(player, coord, chain)]

func _apply_choose_survivor(action: Dictionary) -> Variant:
	var player: int = action.player
	var coord: Vector2i = action.payload.coord
	var chain: int = action.payload.chain
	if state.phase != Phase.RESOLVE_MERGER or player != state.current_player:
		_last_reject_reason = "Not expecting a survivor choice right now."
		return null
	return _begin_merger(coord, chain)

## Pays bonuses for `survivor` (merger_begin), builds the disposal queue, and
## immediately finishes the merger if nobody holds any defunct stock.
func _begin_merger(coord: Vector2i, survivor: int) -> Array:
	var defuncts := state.merger_begin(coord.x, coord.y, survivor)
	_merge_survivor = survivor
	_disposal_queue = []
	for d in defuncts:
		for pi in state.turn_order():
			if state.players[pi].shares[d] > 0:
				_disposal_queue.append({"defunct": d, "player": pi})

	var events := [Event.make_merger_started(coord, survivor, defuncts, _disposal_queue.duplicate(true))]
	if _disposal_queue.is_empty():
		state.merger_finish()
		state.phase = Phase.BUY_STOCK
		events.append(Event.make_merger_finished())
	return events

func _apply_dispose_stock(action: Dictionary) -> Variant:
	var player: int = action.player
	if state.phase != Phase.RESOLVE_MERGER or _disposal_queue.is_empty():
		_last_reject_reason = "No stock disposal is pending."
		return null
	var entry: Dictionary = _disposal_queue[0]
	var defunct: int = action.payload.defunct
	if player != entry.player or defunct != entry.defunct:
		_last_reject_reason = "It's not your turn to dispose of that stock."
		return null

	var sell: int = action.payload.sell
	var trade: int = action.payload.trade
	state.merger_dispose(player, defunct, sell, trade)
	_disposal_queue.pop_front()
	var events := [Event.make_stock_disposed(player, defunct, sell, trade)]
	if _disposal_queue.is_empty():
		state.merger_finish()
		state.phase = Phase.BUY_STOCK
		events.append(Event.make_merger_finished())
	return events

func _apply_buy_stock(action: Dictionary) -> Variant:
	var player: int = action.player
	if state.phase != Phase.BUY_STOCK or player != state.current_player:
		_last_reject_reason = "Not your turn to buy stock."
		return null
	var order: Dictionary = action.payload.order
	var declare_end: bool = action.payload.declare_end
	if declare_end and not state.can_end_game():
		_last_reject_reason = "Cannot declare the game over right now."
		return null

	var cleaned := {}
	for ch in order:
		if int(order[ch]) > 0:
			cleaned[ch] = int(order[ch])

	var events := []
	if not cleaned.is_empty():
		if not state.buy_stock(player, cleaned):
			_last_reject_reason = "Invalid purchase — at most %d shares total, and you must afford it." % AcqEnums.MAX_BUY_PER_TURN
			return null
		events.append(Event.make_stock_bought(player, cleaned))

	if declare_end:
		var final_scores := state.compute_final_scores()
		state.phase = Phase.GAME_OVER
		events.append(Event.make_game_over(final_scores))
	else:
		state.draw_tile(player)
		state.advance_turn()
		events.append(Event.make_turn_ended(player))
	return events

func _apply_redraw_tile(action: Dictionary) -> Variant:
	var player: int = action.player
	var tile: Vector2i = action.payload.tile
	if state.phase != Phase.PLACE_TILE or player != state.current_player:
		_last_reject_reason = "Not your turn to redraw a tile."
		return null
	if not state.players[player].rack.has(tile):
		_last_reject_reason = "That tile is not in your rack."
		return null
	if not state.is_dead_tile(tile.x, tile.y):
		_last_reject_reason = "That tile isn't dead — it can still be played."
		return null
	state.remove_from_rack(player, tile)
	state.draw_tile(player)
	return [Event.make_tile_redrawn(player, tile)]
