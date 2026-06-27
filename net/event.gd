extends RefCounted
class_name Event
## An Event is the host's broadcast of what actually happened to GameState:
## { "type": String, "payload": Dictionary }. Every peer (including the host,
## for code-path symmetry) applies events through the same dispatcher
## (net/session.gd's _apply_event_to_state / ui/game/game.gd's
## _on_event_applied) so host and client GameState mirrors stay convergent by
## construction — see net/session.gd's header comment for why clients never
## re-derive outcomes themselves.

const GAME_STARTED := "game_started"
const TILE_PLACED := "tile_placed"               # isolated or grow (terminal -> buy phase)
const CHAIN_FOUND_PENDING := "chain_found_pending"
const CHAIN_FOUNDED := "chain_founded"
const MERGER_PENDING := "merger_pending"         # placement set aside; may or may not be a tie
const MERGER_STARTED := "merger_started"         # survivor decided, bonuses paid, disposal queue built
const STOCK_DISPOSED := "stock_disposed"
const MERGER_FINISHED := "merger_finished"
const STOCK_BOUGHT := "stock_bought"
const TURN_ENDED := "turn_ended"
const TILE_REDRAWN := "tile_redrawn"
const GAME_OVER := "game_over"
const ACTION_REJECTED := "action_rejected"        # sent only to the offending peer, never broadcast
const GAME_STATE_SYNC := "game_state_sync"        # sent only to one reconnecting peer, never broadcast

## `peer_seats` maps transport peer id -> seat index (state.players index), so
## every client can look up its own seat from one broadcast event instead of
## needing a separate private message. Empty/omitted in solo hotseat play,
## where every peer (there is only one) already knows it owns every seat.
static func make_game_started(player_names: Array, game_seed: int, peer_seats: Dictionary = {}) -> Dictionary:
	return {
		"type": GAME_STARTED,
		"payload": {"player_names": player_names, "seed": game_seed, "peer_seats": peer_seats},
	}

static func make_tile_placed(player: int, coord: Vector2i, kind: int, chain: int) -> Dictionary:
	return {
		"type": TILE_PLACED,
		"payload": {"player": player, "coord": coord, "kind": kind, "chain": chain},
	}

static func make_chain_found_pending(player: int, coord: Vector2i, available_chains: Array) -> Dictionary:
	return {
		"type": CHAIN_FOUND_PENDING,
		"payload": {"player": player, "coord": coord, "available_chains": available_chains},
	}

static func make_chain_founded(player: int, coord: Vector2i, chain: int) -> Dictionary:
	return {"type": CHAIN_FOUNDED, "payload": {"player": player, "coord": coord, "chain": chain}}

static func make_merger_pending(player: int, coord: Vector2i, survivor_candidates: Array) -> Dictionary:
	return {
		"type": MERGER_PENDING,
		"payload": {"player": player, "coord": coord, "survivor_candidates": survivor_candidates},
	}

static func make_merger_started(coord: Vector2i, survivor: int, defuncts: Array, disposal_queue: Array) -> Dictionary:
	return {
		"type": MERGER_STARTED,
		"payload": {
			"coord": coord,
			"survivor": survivor,
			"defuncts": defuncts,
			"disposal_queue": disposal_queue,
		},
	}

static func make_stock_disposed(player: int, defunct: int, sell: int, trade: int) -> Dictionary:
	return {
		"type": STOCK_DISPOSED,
		"payload": {"player": player, "defunct": defunct, "sell": sell, "trade": trade},
	}

static func make_merger_finished() -> Dictionary:
	return {"type": MERGER_FINISHED, "payload": {}}

static func make_stock_bought(player: int, order: Dictionary) -> Dictionary:
	return {"type": STOCK_BOUGHT, "payload": {"player": player, "order": order}}

static func make_turn_ended(player: int) -> Dictionary:
	return {"type": TURN_ENDED, "payload": {"player": player}}

static func make_tile_redrawn(player: int, tile: Vector2i) -> Dictionary:
	return {"type": TILE_REDRAWN, "payload": {"player": player, "tile": tile}}

static func make_game_over(final_scores: Array) -> Dictionary:
	return {"type": GAME_OVER, "payload": {"final_scores": final_scores}}

static func make_action_rejected(reason: String, original_action: Dictionary) -> Dictionary:
	return {"type": ACTION_REJECTED, "payload": {"reason": reason, "original_action": original_action}}

## Full GameState resync for one reconnecting peer (see net/session.gd's
## send_state_sync). `peer_seats` reuses GAME_STARTED's pattern so the
## reconnecting peer can look up its own seat from this one message.
static func make_game_state_sync(snapshot: Dictionary, peer_seats: Dictionary) -> Dictionary:
	return {"type": GAME_STATE_SYNC, "payload": {"snapshot": snapshot, "peer_seats": peer_seats}}
