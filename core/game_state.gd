extends RefCounted
class_name GameState
## The complete, pure Acquire rules engine: board, chains, stock bank, players,
## and every state mutation (found / grow / merge / buy / draw / score).
##
## This file has NO knowledge of UI, theming, or networking. It is driven by
## explicit method calls (the "apply an action" primitives) and is fully
## deterministic, which is what lets us:
##   * play and test entire games headlessly (sim/run_tests.gd), and
##   * later route the same mutations across the network (M4) unchanged.
##
## Coordinate convention: col 0..11, row 0..8. Cells store CELL_EMPTY, a lone
## marker (ChainId.NONE), or a chain id (0..6). See AcqEnums.

const W := AcqEnums.BOARD_WIDTH
const H := AcqEnums.BOARD_HEIGHT
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## One player's mutable state.
class PlayerState extends RefCounted:
	var pname: String
	var cash: int
	var shares: PackedInt32Array      # shares[chain_id] = number held
	var rack: Array[Vector2i]         # tiles currently in hand

	func _init(display_name: String) -> void:
		pname = display_name
		cash = AcqEnums.STARTING_CASH
		shares = PackedInt32Array()
		shares.resize(AcqEnums.CHAIN_COUNT)  # zero-filled
		rack = []

# --- Game state -------------------------------------------------------------
var board: PackedInt32Array          # size W*H; CELL_EMPTY / lone / chain id
var chain_size: Dictionary = {}      # chain_id -> tile count; absent => not on board
var bank_shares: PackedInt32Array    # bank_shares[chain] = shares left to buy
var bag: Array[Vector2i] = []        # face-down tiles still to be drawn
var players: Array[PlayerState] = []
var current_player: int = 0
var phase: int = AcqEnums.GamePhase.SETUP
var rng := RandomNumberGenerator.new()

## The single tile each player drew during setup to determine turn order
## (index-aligned with `players`). Kept around so the UI can show "who drew
## what" after the game starts; rules.txt step 8.
var starting_draws: Array[Vector2i] = []

# Scratch state for a merger that is being resolved step-by-step by the UI.
var _pending_merger: Dictionary = {}


# ===========================================================================
#  Construction
# ===========================================================================

## A fully dealt game ready to play. `seed` makes the shuffle reproducible.
func setup_new_game(player_names: Array, game_seed: int = 0) -> void:
	_init_empty_board()
	bank_shares = PackedInt32Array()
	bank_shares.resize(AcqEnums.CHAIN_COUNT)
	bank_shares.fill(AcqEnums.STOCK_PER_CHAIN)
	chain_size = {}
	players = []
	for n in player_names:
		players.append(PlayerState.new(str(n)))

	rng.seed = game_seed if game_seed != 0 else randi()
	_fill_and_shuffle_bag()

	current_player = _deal_starting_tiles()
	for p in players:
		for _i in AcqEnums.RACK_SIZE:
			_draw_into_rack(p)

	phase = AcqEnums.GamePhase.PLACE_TILE

## rules.txt step 8: each player draws one tile and places it face up on its
## matching space — even tiles that land adjacent to each other stay
## independent at this point, no chain forms. The player whose tile is
## closest to 1A goes first. "Closest" is row-major reading order from 1A
## (scan row A across all columns, then row B, ...) — rules.txt's own example
## confirms this: "9A is closer to 1A than 1B is," i.e. row dominates and
## column only breaks ties within the same row. Returns that player's index.
func _deal_starting_tiles() -> int:
	starting_draws = []
	var best_player := 0
	var best_rank := -1
	for i in players.size():
		var tile: Vector2i = bag.pop_back()
		set_cell(tile.x, tile.y, AcqEnums.ChainId.NONE)   # independent placement, never a chain
		starting_draws.append(tile)
		var rank := tile.y * W + tile.x   # row dominates, column breaks ties within a row
		if best_rank == -1 or rank < best_rank:
			best_rank = rank
			best_player = i
	return best_player

## A blank board with players but no tiles dealt — handy for unit tests that
## build exact board positions by hand.
func setup_blank(num_players: int) -> void:
	_init_empty_board()
	bank_shares = PackedInt32Array()
	bank_shares.resize(AcqEnums.CHAIN_COUNT)
	bank_shares.fill(AcqEnums.STOCK_PER_CHAIN)
	chain_size = {}
	players = []
	for i in num_players:
		players.append(PlayerState.new("P%d" % (i + 1)))
	current_player = 0
	phase = AcqEnums.GamePhase.PLACE_TILE

# ===========================================================================
#  Snapshot — full-state resync for a reconnecting network peer (M4 gap fix)
# ===========================================================================

## Everything needed to rebuild an equivalent GameState elsewhere, covering
## exactly the fields sim/run_network_tests.gd's _assert_converged() already
## treats as the convergence contract. `starting_draws`/`rng` are cosmetic
## history, not gameplay-affecting, so they're intentionally omitted.
func to_snapshot() -> Dictionary:
	var player_snaps := []
	for p in players:
		player_snaps.append({"pname": p.pname, "cash": p.cash, "shares": p.shares, "rack": p.rack.duplicate()})
	return {
		"board": board,
		"chain_size": chain_size.duplicate(),
		"bank_shares": bank_shares,
		"bag": bag.duplicate(),
		"current_player": current_player,
		"phase": phase,
		"players": player_snaps,
	}

## Rebuilds this GameState from a Dictionary produced by to_snapshot() on
## another instance — used to resync a reconnecting client mid-game.
func apply_snapshot(snapshot: Dictionary) -> void:
	board = snapshot.board.duplicate()
	chain_size = snapshot.chain_size.duplicate()
	bank_shares = snapshot.bank_shares.duplicate()
	bag = snapshot.bag.duplicate()
	current_player = snapshot.current_player
	phase = snapshot.phase
	players = []
	for ps in snapshot.players:
		var p := PlayerState.new(ps.pname)
		p.cash = ps.cash
		p.shares = ps.shares.duplicate()
		p.rack = ps.rack.duplicate()
		players.append(p)


func _init_empty_board() -> void:
	board = PackedInt32Array()
	board.resize(W * H)
	board.fill(AcqEnums.CELL_EMPTY)

func _fill_and_shuffle_bag() -> void:
	bag = []
	for r in H:
		for c in W:
			bag.append(Vector2i(c, r))
	# Fisher-Yates using our seeded rng so games are reproducible.
	for i in range(bag.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := bag[i]
		bag[i] = bag[j]
		bag[j] = tmp


# ===========================================================================
#  Board helpers
# ===========================================================================

func idx(col: int, row: int) -> int:
	return row * W + col

func in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < W and row >= 0 and row < H

func cell(col: int, row: int) -> int:
	return board[idx(col, row)]

func set_cell(col: int, row: int, value: int) -> void:
	board[idx(col, row)] = value

func is_empty_cell(col: int, row: int) -> bool:
	return cell(col, row) == AcqEnums.CELL_EMPTY

func neighbors(col: int, row: int) -> Array:
	var out: Array = []
	for d in DIRS:
		var c := col + d.x
		var r := row + d.y
		if in_bounds(c, r):
			out.append(Vector2i(c, r))
	return out

## Unique chain ids (>= 0) orthogonally adjacent to a cell.
func neighbor_chains(col: int, row: int) -> Array:
	var seen := {}
	for n in neighbors(col, row):
		var v := cell(n.x, n.y)
		if v >= 0:
			seen[v] = true
	return seen.keys()

## True if any orthogonal neighbour is a placed-but-unchained (lone) tile.
func has_lone_neighbor(col: int, row: int) -> bool:
	for n in neighbors(col, row):
		if cell(n.x, n.y) == AcqEnums.ChainId.NONE:
			return true
	return false


# ===========================================================================
#  Chain queries
# ===========================================================================

func chain_size_of(chain: int) -> int:
	return chain_size.get(chain, 0)

func is_on_board(chain: int) -> bool:
	return chain_size_of(chain) > 0

func is_safe(chain: int) -> bool:
	return chain_size_of(chain) >= AcqEnums.SAFE_SIZE

## Chains not currently on the board — i.e. the ones a new chain can be founded as.
func available_chains() -> Array:
	var out: Array = []
	for ch in AcqEnums.CHAIN_COUNT:
		if not is_on_board(ch):
			out.append(ch)
	return out

func current_price(chain: int) -> int:
	return StockMarket.price(chain, chain_size_of(chain))


# ===========================================================================
#  Placement classification
# ===========================================================================

## Decide what placing a tile at (col,row) would do, WITHOUT mutating anything.
## Returns a dictionary { "kind": PlacementKind, ... } with extra fields:
##   GROW  -> "chain"  (the chain that grows)
##   MERGE -> "chains" (all chains involved)
##   ILLEGAL_DEAD -> "chains"
func classify_placement(col: int, row: int) -> Dictionary:
	if not in_bounds(col, row) or not is_empty_cell(col, row):
		return {"kind": AcqEnums.PlacementKind.ILLEGAL_TEMP}

	var nchains := neighbor_chains(col, row)
	if nchains.size() == 0:
		if has_lone_neighbor(col, row):
			# Would found a new chain — only legal if a chain slot is free.
			if available_chains().size() > 0:
				return {"kind": AcqEnums.PlacementKind.FOUND}
			return {"kind": AcqEnums.PlacementKind.ILLEGAL_TEMP}
		return {"kind": AcqEnums.PlacementKind.ISOLATED}
	elif nchains.size() == 1:
		return {"kind": AcqEnums.PlacementKind.GROW, "chain": nchains[0]}
	else:
		# Two or more chains touch: a merger — unless two of them are safe.
		var safe_count := 0
		for ch in nchains:
			if is_safe(ch):
				safe_count += 1
		if safe_count >= 2:
			return {"kind": AcqEnums.PlacementKind.ILLEGAL_DEAD, "chains": nchains}
		return {"kind": AcqEnums.PlacementKind.MERGE, "chains": nchains}

## A tile in a rack is "permanently dead" if it could never be legally placed:
## it would merge two safe chains. (Temporarily-illegal tiles are NOT dead.)
func is_dead_tile(col: int, row: int) -> bool:
	return classify_placement(col, row).get("kind") == AcqEnums.PlacementKind.ILLEGAL_DEAD


# ===========================================================================
#  Connectivity (flood fills)
# ===========================================================================

## All placed lone tiles connected to (and including) a lone start cell.
func _connected_lone(col: int, row: int) -> Array:
	var start := Vector2i(col, row)
	var seen := {start: true}
	var stack: Array = [start]
	var out: Array = [start]
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for n in neighbors(c.x, c.y):
			if not seen.has(n) and cell(n.x, n.y) == AcqEnums.ChainId.NONE:
				seen[n] = true
				out.append(n)
				stack.append(n)
	return out

## All placed tiles (any kind) connected to a start cell. Because distinct
## chains are never adjacent, flooding from a freshly placed merging tile
## yields exactly: that tile + connected lone tiles + every involved chain.
func _flood_all_placed(col: int, row: int) -> Array:
	var start := Vector2i(col, row)
	var seen := {start: true}
	var stack: Array = [start]
	var out: Array = [start]
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for n in neighbors(c.x, c.y):
			if not seen.has(n) and cell(n.x, n.y) != AcqEnums.CELL_EMPTY:
				seen[n] = true
				out.append(n)
				stack.append(n)
	return out


# ===========================================================================
#  Placement mutations
# ===========================================================================

## Place a tile that touches nothing — it just sits as a lone tile.
func do_isolated(col: int, row: int) -> void:
	set_cell(col, row, AcqEnums.ChainId.NONE)

## Found `chain` at the placed cell, absorbing all connected lone tiles. The
## founder (current player) receives one free share if the bank has any.
##
## Rare case (rules.txt "Founding a Hotel Chain with Zero Stock Available"):
## if every share of this chain is already out in players' hands — possible
## when a chain was previously dissolved by a merger and its shareholders
## chose to keep their stock — the bank has none left to hand over, so the
## founder is paid cash equal to the share's value instead.
func do_found(col: int, row: int, chain: int) -> void:
	set_cell(col, row, AcqEnums.ChainId.NONE)            # mark placed, then claim
	var group := _connected_lone(col, row)
	for c in group:
		set_cell(c.x, c.y, chain)
	chain_size[chain] = group.size()
	if bank_shares[chain] > 0:
		bank_shares[chain] -= 1
		players[current_player].shares[chain] += 1
	else:
		players[current_player].cash += StockMarket.price(chain, chain_size_of(chain))

## Grow an existing `chain` by the placed tile plus any connected lone tiles.
func do_grow(col: int, row: int, chain: int) -> void:
	set_cell(col, row, AcqEnums.ChainId.NONE)
	var group := _connected_lone(col, row)              # new tile + lone neighbours
	for c in group:
		set_cell(c.x, c.y, chain)
	chain_size[chain] = chain_size_of(chain) + group.size()


# ===========================================================================
#  Merger resolution
#
#  Sizes used to pick the survivor and pay bonuses are the chains' sizes
#  BEFORE the connecting tile is added (the tile is not committed to the board
#  until merger_finish()). This is the rule that the newly placed tile is not
#  counted toward either chain's length at the moment of merger.
# ===========================================================================

## Describe a pending merger without mutating anything.
##   "chains"              -> all chains touching the cell
##   "sizes"               -> { chain: pre-merger size }
##   "max_size"            -> the largest pre-merger size
##   "survivor_candidates" -> chains tied at max_size (more than one => UI must ask)
func merger_info(col: int, row: int) -> Dictionary:
	var chains := neighbor_chains(col, row)
	var sizes := {}
	var max_size := 0
	for ch in chains:
		var s := chain_size_of(ch)
		sizes[ch] = s
		max_size = max(max_size, s)
	var candidates: Array = []
	for ch in chains:
		if sizes[ch] == max_size:
			candidates.append(ch)
	return {
		"chains": chains,
		"sizes": sizes,
		"max_size": max_size,
		"survivor_candidates": candidates,
	}

## Begin a merger with the chosen `survivor`. Pays every defunct chain's
## majority/minority bonuses immediately and returns the defunct chains in the
## order they must be resolved (largest first). Tiles are NOT yet repainted.
func merger_begin(col: int, row: int, survivor: int) -> Array:
	var info := merger_info(col, row)
	var defuncts: Array = []
	for ch in info.chains:
		if ch != survivor:
			defuncts.append(ch)
	# Resolve larger defunct chains first; break ties by chain id for determinism.
	var sizes: Dictionary = info.sizes
	defuncts.sort_custom(func(a, b):
		if sizes[a] == sizes[b]:
			return a < b
		return sizes[a] > sizes[b])

	var bonuses := {}
	for d in defuncts:
		bonuses[d] = _pay_bonuses(d, chain_size_of(d))

	_pending_merger = {
		"col": col,
		"row": row,
		"survivor": survivor,
		"involved": info.chains,
		"defuncts": defuncts,
		"bonuses": bonuses,
	}
	return defuncts

## Apply one player's choice for a defunct chain during the active merger.
## `sell` shares are cashed out at the defunct price; `trade` shares (rounded
## down to an even number, capped by available survivor stock) become survivor
## shares 2-for-1; the rest are kept.
func merger_dispose(player: int, defunct: int, sell: int, trade: int) -> void:
	var price := StockMarket.price(defunct, chain_size_of(defunct))
	_apply_disposal(player, defunct, _pending_merger.survivor, price, sell, trade)

## Finish the active merger: repaint every connected tile to the survivor and
## free the defunct chains for future re-founding.
func merger_finish() -> void:
	var col: int = _pending_merger.col
	var row: int = _pending_merger.row
	var survivor: int = _pending_merger.survivor
	var involved: Array = _pending_merger.involved
	set_cell(col, row, AcqEnums.ChainId.NONE)           # commit the connecting tile
	var blob := _flood_all_placed(col, row)
	for ch in involved:
		chain_size.erase(ch)                            # defuncts leave the board
	for c in blob:
		set_cell(c.x, c.y, survivor)
	chain_size[survivor] = blob.size()
	_pending_merger = {}

## One-shot merger resolution used by tests. `disposals` is
## { defunct_chain: { player_index: {"sell": int, "trade": int} } }; anything
## unspecified is kept.
func resolve_merger(col: int, row: int, survivor: int, disposals: Dictionary = {}) -> void:
	var defuncts := merger_begin(col, row, survivor)
	for d in defuncts:
		for pi in _turn_order_from_current():
			var plan: Dictionary = disposals.get(d, {}).get(pi, {})
			merger_dispose(pi, d, int(plan.get("sell", 0)), int(plan.get("trade", 0)))
	merger_finish()

func _apply_disposal(player: int, defunct: int, survivor: int, price: int, sell: int, trade: int) -> void:
	var held := players[player].shares[defunct]
	sell = clampi(sell, 0, held)
	trade = clampi(trade, 0, held - sell)
	if trade % 2 == 1:
		trade -= 1                                      # 2-for-1 needs an even count
	var survivor_gain := trade / 2
	survivor_gain = mini(survivor_gain, bank_shares[survivor])  # can't exceed bank
	trade = survivor_gain * 2

	if sell > 0:
		players[player].shares[defunct] -= sell
		bank_shares[defunct] += sell
		players[player].cash += sell * price
	if trade > 0:
		players[player].shares[defunct] -= trade
		bank_shares[defunct] += trade
		players[player].shares[survivor] += survivor_gain
		bank_shares[survivor] -= survivor_gain
	# Remaining shares are simply kept.

## Pay a chain's majority and minority bonuses to its shareholders and return a
## log of [{ "player", "amount", "role" }]. Handles sole-holder and tie cases.
func _pay_bonuses(chain: int, size_for_price: int) -> Array:
	var majority := StockMarket.majority_bonus(chain, size_for_price)
	var minority := StockMarket.minority_bonus(chain, size_for_price)

	var holders: Array = []
	for i in players.size():
		var sh := players[i].shares[chain]
		if sh > 0:
			holders.append({"player": i, "shares": sh})
	var payouts: Array = []
	if holders.is_empty():
		return payouts
	holders.sort_custom(func(a, b): return a.shares > b.shares)

	var top_shares: int = holders[0].shares
	var top: Array = []
	for h in holders:
		if h.shares == top_shares:
			top.append(h)

	if top.size() >= 2:
		# Tie for largest shareholder: combine both bonuses, split evenly,
		# round each share up to the nearest $100. No separate minority.
		var each := _round_up_100(float(majority + minority) / top.size())
		for h in top:
			payouts.append({"player": h.player, "amount": each, "role": "majority-tie"})
	else:
		payouts.append({"player": top[0].player, "amount": majority, "role": "majority"})
		var rest: Array = holders.slice(1)
		if rest.is_empty():
			# Sole shareholder also collects the minority bonus.
			payouts.append({"player": top[0].player, "amount": minority, "role": "minority-sole"})
		else:
			var second_shares: int = rest[0].shares
			var seconds: Array = []
			for h in rest:
				if h.shares == second_shares:
					seconds.append(h)
			if seconds.size() >= 2:
				var each2 := _round_up_100(float(minority) / seconds.size())
				for h in seconds:
					payouts.append({"player": h.player, "amount": each2, "role": "minority-tie"})
			else:
				payouts.append({"player": seconds[0].player, "amount": minority, "role": "minority"})

	for p in payouts:
		players[p.player].cash += p.amount
	return payouts

static func _round_up_100(amount: float) -> int:
	return int(ceil(amount / 100.0)) * 100


# ===========================================================================
#  Stock buying, drawing, and turn order
# ===========================================================================

## Buy shares this turn. `order` is { chain: count }. Validates the per-turn
## limit, bank availability, and the player's cash. Returns true if applied.
func buy_stock(player: int, order: Dictionary) -> bool:
	var total := 0
	var cost := 0
	for chain in order:
		var count: int = order[chain]
		if count <= 0:
			continue
		if not is_on_board(chain):
			return false
		if count > bank_shares[chain]:
			return false
		total += count
		cost += count * current_price(chain)
	if total > AcqEnums.MAX_BUY_PER_TURN:
		return false
	if cost > players[player].cash:
		return false
	for chain in order:
		var count: int = order[chain]
		if count <= 0:
			continue
		players[player].cash -= count * current_price(chain)
		players[player].shares[chain] += count
		bank_shares[chain] -= count
	return true

func _draw_into_rack(p: PlayerState) -> void:
	if not bag.is_empty():
		p.rack.append(bag.pop_back())

## Draw a replacement tile for a player (end of their turn), if any remain.
func draw_tile(player: int) -> void:
	_draw_into_rack(players[player])

func remove_from_rack(player: int, tile: Vector2i) -> void:
	players[player].rack.erase(tile)

func advance_turn() -> void:
	current_player = (current_player + 1) % players.size()
	phase = AcqEnums.GamePhase.PLACE_TILE

func _turn_order_from_current() -> Array:
	var order: Array = []
	for i in players.size():
		order.append((current_player + i) % players.size())
	return order

## Public turn order starting at the current player (used by the UI to walk
## players for merger stock disposal).
func turn_order() -> Array:
	return _turn_order_from_current()


# ===========================================================================
#  End game
# ===========================================================================

## True if the current player is allowed to end the game: any chain has reached
## END_GAME_SIZE, or every chain on the board is safe.
func can_end_game() -> bool:
	var active := available_active_chains()
	if active.is_empty():
		return false
	for ch in active:
		if chain_size_of(ch) >= AcqEnums.END_GAME_SIZE:
			return true
	for ch in active:
		if not is_safe(ch):
			return false
	return true

func available_active_chains() -> Array:
	var out: Array = []
	for ch in AcqEnums.CHAIN_COUNT:
		if is_on_board(ch):
			out.append(ch)
	return out

## Compute final net worth per player: cash + end-of-game bonuses + value of all
## shares sold at current prices. Mutates state (the game is over) and returns
## an array of { "player", "name", "cash" } sorted high to low.
func compute_final_scores() -> Array:
	for ch in available_active_chains():
		var size := chain_size_of(ch)
		_pay_bonuses(ch, size)
		var price := StockMarket.price(ch, size)
		for i in players.size():
			var sh := players[i].shares[ch]
			if sh > 0:
				players[i].cash += sh * price
				players[i].shares[ch] = 0
				bank_shares[ch] += sh
	var results: Array = []
	for i in players.size():
		results.append({"player": i, "name": players[i].pname, "cash": players[i].cash})
	results.sort_custom(func(a, b): return a.cash > b.cash)
	return results
