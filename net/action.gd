extends RefCounted
class_name Action
## An Action is a player's minimal intent, sent from a seat to the host:
## { "type": String, "player": int, "payload": Dictionary }. It never carries a
## precomputed outcome (e.g. a classification or a chain pick's downstream
## effect) — only the raw choice. The host (net/session.gd) is the only place
## that turns an Action into an actual GameState mutation; see Event for the
## resulting broadcast.

const PLACE_TILE := "place_tile"
const CHOOSE_FOUND := "choose_found"
const CHOOSE_SURVIVOR := "choose_survivor"
const DISPOSE_STOCK := "dispose_stock"
const BUY_STOCK := "buy_stock"
const REDRAW_TILE := "redraw_tile"

static func make_place_tile(player: int, coord: Vector2i) -> Dictionary:
	return {"type": PLACE_TILE, "player": player, "payload": {"coord": coord}}

static func make_choose_found(player: int, coord: Vector2i, chain: int) -> Dictionary:
	return {"type": CHOOSE_FOUND, "player": player, "payload": {"coord": coord, "chain": chain}}

static func make_choose_survivor(player: int, coord: Vector2i, chain: int) -> Dictionary:
	return {"type": CHOOSE_SURVIVOR, "player": player, "payload": {"coord": coord, "chain": chain}}

static func make_dispose_stock(player: int, defunct: int, sell: int, trade: int) -> Dictionary:
	return {
		"type": DISPOSE_STOCK,
		"player": player,
		"payload": {"defunct": defunct, "sell": sell, "trade": trade},
	}

static func make_buy_stock(player: int, order: Dictionary, declare_end: bool) -> Dictionary:
	return {
		"type": BUY_STOCK,
		"player": player,
		"payload": {"order": order, "declare_end": declare_end},
	}

static func make_redraw_tile(player: int, tile: Vector2i) -> Dictionary:
	return {"type": REDRAW_TILE, "player": player, "payload": {"tile": tile}}
