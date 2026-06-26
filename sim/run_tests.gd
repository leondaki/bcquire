extends SceneTree
## Headless rules-engine test suite. Run with:
##   godot --headless --path <proj> --import           (once, registers globals)
##   godot --headless --path <proj> --script sim/run_tests.gd
## Expected output: "==== N passed, 0 failed ====" and exit code 0.
##
## These tests exercise the pure GameState engine only — no UI, no networking.

var passed := 0
var failed := 0

const Chain = AcqEnums.ChainId
const Kind = AcqEnums.PlacementKind

func _initialize() -> void:
	test_pricing()
	test_found_and_grow()
	test_grow_absorbs_lone()
	test_merger_excludes_new_tile()
	test_merger_tie()
	test_bonuses_unique()
	test_bonuses_majority_tie()
	test_disposal_trade()
	test_disposal_sell()
	test_safe_chains_dead_tile()
	test_safe_plus_small_merges()
	test_buy_stock()
	test_end_game()
	test_starting_draw_phase()
	test_found_with_zero_bank_stock()

	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)

# --- tiny assertion helpers -------------------------------------------------
func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + msg)

func eq(got, expected, msg: String) -> void:
	check(got == expected, "%s (got %s, expected %s)" % [msg, str(got), str(expected)])

# --- test setup helpers -----------------------------------------------------
func _zero_shares(gs: GameState) -> void:
	for p in gs.players:
		p.shares.fill(0)

# Build a vertical chain in column `col`, rows 0..size-1.
func _build_column_chain(gs: GameState, chain: int, col: int, size: int) -> void:
	gs.do_isolated(col, 0)
	gs.do_found(col, 1, chain)          # founds from (col,0)+(col,1) -> size 2
	for r in range(2, size):
		gs.do_grow(col, r, chain)

# ===========================================================================

func test_pricing() -> void:
	eq(StockMarket.price(Chain.TOWER, 2), 200, "cheap size2")
	eq(StockMarket.price(Chain.AMERICAN, 2), 300, "medium size2")
	eq(StockMarket.price(Chain.CONTINENTAL, 2), 400, "expensive size2")
	eq(StockMarket.price(Chain.TOWER, 6), 600, "cheap 6-10 bracket low")
	eq(StockMarket.price(Chain.TOWER, 10), 600, "cheap 6-10 bracket high")
	eq(StockMarket.price(Chain.TOWER, 11), 700, "cheap 11-20 bracket")
	eq(StockMarket.price(Chain.TOWER, 41), 1000, "cheap 41+")
	eq(StockMarket.price(Chain.CONTINENTAL, 41), 1200, "expensive 41+")
	eq(StockMarket.majority_bonus(Chain.TOWER, 2), 2000, "majority = 10x")
	eq(StockMarket.minority_bonus(Chain.TOWER, 2), 1000, "minority = 5x")

func test_found_and_grow() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	eq(gs.classify_placement(0, 0).kind, Kind.ISOLATED, "lone in open is isolated")
	gs.do_isolated(0, 0)
	eq(gs.classify_placement(1, 0).kind, Kind.FOUND, "tile next to lone founds")
	gs.do_found(1, 0, Chain.TOWER)
	eq(gs.chain_size_of(Chain.TOWER), 2, "founded chain size 2")
	eq(gs.cell(0, 0), Chain.TOWER, "lone absorbed into chain")
	eq(gs.players[0].shares[Chain.TOWER], 1, "founder gets free share")
	eq(gs.bank_shares[Chain.TOWER], 24, "founder share leaves bank")
	eq(gs.classify_placement(2, 0).kind, Kind.GROW, "tile next to chain grows")
	gs.do_grow(2, 0, Chain.TOWER)
	eq(gs.chain_size_of(Chain.TOWER), 3, "grown chain size 3")

func test_grow_absorbs_lone() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	_build_column_chain(gs, Chain.TOWER, 0, 3)   # (0,0),(0,1),(0,2)
	gs.do_isolated(0, 4)                          # a lone tile two below the chain
	# (0,3) touches chain TOWER at (0,2) and lone at (0,4): grows, absorbing both.
	eq(gs.classify_placement(0, 3).kind, Kind.GROW, "grow toward chain")
	gs.do_grow(0, 3, Chain.TOWER)
	eq(gs.chain_size_of(Chain.TOWER), 5, "grew by new tile + absorbed lone")
	eq(gs.cell(0, 4), Chain.TOWER, "lone tile joined the chain")

func test_merger_excludes_new_tile() -> void:
	var gs := GameState.new()
	gs.setup_blank(3)
	_build_column_chain(gs, Chain.TOWER, 0, 4)   # size 4
	_build_column_chain(gs, Chain.LUXOR, 2, 3)   # size 3
	# (1,0) bridges TOWER@(0,0) and LUXOR@(2,0).
	eq(gs.classify_placement(1, 0).kind, Kind.MERGE, "two chains -> merge")
	var info := gs.merger_info(1, 0)
	eq(info.sizes[Chain.TOWER], 4, "TOWER counted at 4, NOT 5 (new tile excluded)")
	eq(info.sizes[Chain.LUXOR], 3, "LUXOR counted at 3")
	eq(info.max_size, 4, "max pre-merge size is 4")
	eq(info.survivor_candidates, [Chain.TOWER], "TOWER is sole survivor")
	gs.resolve_merger(1, 0, Chain.TOWER)
	eq(gs.chain_size_of(Chain.TOWER), 8, "survivor = 4 + 3 + 1 new tile")
	eq(gs.is_on_board(Chain.LUXOR), false, "defunct chain left the board")
	eq(gs.cell(1, 0), Chain.TOWER, "connecting tile is now survivor")
	eq(gs.cell(2, 1), Chain.TOWER, "former LUXOR tile is now survivor")

func test_merger_tie() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	_build_column_chain(gs, Chain.TOWER, 0, 3)
	_build_column_chain(gs, Chain.LUXOR, 2, 3)
	var info := gs.merger_info(1, 0)
	eq(info.survivor_candidates.size(), 2, "equal sizes -> tie, UI must ask")
	check(Chain.TOWER in info.survivor_candidates and Chain.LUXOR in info.survivor_candidates,
		"both chains are survivor candidates")

func test_bonuses_unique() -> void:
	var gs := GameState.new()
	gs.setup_blank(3)
	_build_column_chain(gs, Chain.TOWER, 0, 4)   # survivor
	_build_column_chain(gs, Chain.LUXOR, 2, 3)   # defunct, price 300
	_zero_shares(gs)
	gs.players[0].shares[Chain.LUXOR] = 5
	gs.players[1].shares[Chain.LUXOR] = 3
	gs.players[2].shares[Chain.LUXOR] = 1
	gs.resolve_merger(1, 0, Chain.TOWER)         # keep all shares
	eq(gs.players[0].cash, 6000 + 3000, "majority holder gets 10x price")
	eq(gs.players[1].cash, 6000 + 1500, "minority holder gets 5x price")
	eq(gs.players[2].cash, 6000, "third holder gets nothing")
	eq(gs.players[0].shares[Chain.LUXOR], 5, "kept defunct shares remain")

func test_bonuses_majority_tie() -> void:
	var gs := GameState.new()
	gs.setup_blank(3)
	_build_column_chain(gs, Chain.TOWER, 0, 4)
	_build_column_chain(gs, Chain.LUXOR, 2, 3)   # price 300
	_zero_shares(gs)
	gs.players[0].shares[Chain.LUXOR] = 5
	gs.players[1].shares[Chain.LUXOR] = 5
	gs.players[2].shares[Chain.LUXOR] = 2
	gs.resolve_merger(1, 0, Chain.TOWER)
	# (3000 + 1500) / 2 = 2250 -> rounded up to 2300 each; no separate minority.
	eq(gs.players[0].cash, 6000 + 2300, "tied majority split, rounded up")
	eq(gs.players[1].cash, 6000 + 2300, "tied majority split, rounded up")
	eq(gs.players[2].cash, 6000, "no minority paid when majority tied")

func test_disposal_trade() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	_build_column_chain(gs, Chain.TOWER, 0, 4)   # survivor
	_build_column_chain(gs, Chain.LUXOR, 2, 3)   # defunct, price 300
	_zero_shares(gs)
	gs.players[0].shares[Chain.LUXOR] = 4
	gs.bank_shares[Chain.LUXOR] = 21
	gs.bank_shares[Chain.TOWER] = 10
	gs.resolve_merger(1, 0, Chain.TOWER, {Chain.LUXOR: {0: {"sell": 0, "trade": 4}}})
	eq(gs.players[0].shares[Chain.LUXOR], 0, "all defunct shares traded away")
	eq(gs.players[0].shares[Chain.TOWER], 2, "4 defunct -> 2 survivor (2-for-1)")
	eq(gs.bank_shares[Chain.LUXOR], 25, "traded shares returned to bank")
	eq(gs.bank_shares[Chain.TOWER], 8, "survivor shares drawn from bank")
	eq(gs.players[0].cash, 6000 + 4500, "sole holder still got both bonuses")

func test_disposal_sell() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	_build_column_chain(gs, Chain.TOWER, 0, 4)
	_build_column_chain(gs, Chain.LUXOR, 2, 3)   # price 300
	_zero_shares(gs)
	gs.players[0].shares[Chain.LUXOR] = 4
	gs.bank_shares[Chain.LUXOR] = 21
	gs.resolve_merger(1, 0, Chain.TOWER, {Chain.LUXOR: {0: {"sell": 2, "trade": 0}}})
	eq(gs.players[0].shares[Chain.LUXOR], 2, "kept 2 of 4 shares")
	eq(gs.bank_shares[Chain.LUXOR], 23, "2 sold shares returned to bank")
	eq(gs.players[0].cash, 6000 + 4500 + 600, "bonus 4500 + 2 sold @ 300")

func test_safe_chains_dead_tile() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	# Two SAFE chains placed so a single cell would bridge them.
	gs.set_cell(0, 0, Chain.TOWER)
	gs.chain_size[Chain.TOWER] = 11
	gs.set_cell(2, 0, Chain.LUXOR)
	gs.chain_size[Chain.LUXOR] = 11
	eq(gs.classify_placement(1, 0).kind, Kind.ILLEGAL_DEAD, "merging two safe chains is dead")
	eq(gs.is_dead_tile(1, 0), true, "tile flagged permanently dead")

func test_safe_plus_small_merges() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	gs.set_cell(0, 0, Chain.TOWER)
	gs.chain_size[Chain.TOWER] = 11   # safe
	gs.set_cell(2, 0, Chain.LUXOR)
	gs.chain_size[Chain.LUXOR] = 3    # not safe
	eq(gs.classify_placement(1, 0).kind, Kind.MERGE, "safe + small is a legal merge")
	var info := gs.merger_info(1, 0)
	eq(info.survivor_candidates, [Chain.TOWER], "safe/larger chain survives")

func test_buy_stock() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	_build_column_chain(gs, Chain.TOWER, 0, 2)   # price 200
	_zero_shares(gs)
	gs.bank_shares[Chain.TOWER] = 25
	gs.players[0].cash = 6000
	eq(gs.buy_stock(0, {Chain.TOWER: 3}), true, "buy 3 shares ok")
	eq(gs.players[0].cash, 5400, "paid 3 x 200")
	eq(gs.players[0].shares[Chain.TOWER], 3, "received 3 shares")
	eq(gs.bank_shares[Chain.TOWER], 22, "bank reduced by 3")
	eq(gs.buy_stock(0, {Chain.TOWER: 4}), false, "cannot buy more than 3/turn")
	gs.players[0].cash = 100
	eq(gs.buy_stock(0, {Chain.TOWER: 1}), false, "cannot buy without funds")
	eq(gs.buy_stock(0, {Chain.LUXOR: 1}), false, "cannot buy a chain not on board")

func test_end_game() -> void:
	var a := GameState.new()
	a.setup_blank(2)
	eq(a.can_end_game(), false, "no chains -> cannot end")
	a.chain_size[Chain.TOWER] = 41
	eq(a.can_end_game(), true, "a 41-tile chain can end the game")

	var b := GameState.new()
	b.setup_blank(2)
	b.chain_size[Chain.TOWER] = 11
	b.chain_size[Chain.LUXOR] = 5
	eq(b.can_end_game(), false, "an unsafe active chain blocks ending")

	var c := GameState.new()
	c.setup_blank(2)
	c.chain_size[Chain.TOWER] = 11
	c.chain_size[Chain.LUXOR] = 12
	eq(c.can_end_game(), true, "all chains safe -> can end")

## rules.txt step 8: each player draws one tile (placed independently, even if
## adjacent — no chain forms), and whoever is closest to 1A goes first.
func test_starting_draw_phase() -> void:
	var gs := GameState.new()
	gs.setup_new_game(["A", "B", "C", "D"], 12345)

	eq(gs.starting_draws.size(), 4, "one starting tile recorded per player")
	eq(gs.bag.size(), AcqEnums.TILE_COUNT - 4 - 4 * AcqEnums.RACK_SIZE, "bag shrank by draws + racks")

	# Every starting tile must be a lone (NONE) marker on the board, and no
	# chain should have formed even if two land adjacent to each other.
	var lone_count := 0
	for r in AcqEnums.BOARD_HEIGHT:
		for c in AcqEnums.BOARD_WIDTH:
			if gs.cell(c, r) == Chain.NONE:
				lone_count += 1
	eq(lone_count, 4, "exactly the 4 starting tiles are lone, no chains formed")
	eq(gs.available_active_chains().size(), 0, "no chains exist yet")

	# The current player must hold the lowest (row, then column) starting tile
	# — row-major reading order from 1A.
	var best_rank := 999999
	var best_i := -1
	for i in gs.starting_draws.size():
		var t: Vector2i = gs.starting_draws[i]
		var rank := t.y * AcqEnums.BOARD_WIDTH + t.x
		if rank < best_rank:
			best_rank = rank
			best_i = i
	eq(gs.current_player, best_i, "player with the tile closest to 1A goes first")

	for p in gs.players:
		eq(p.rack.size(), AcqEnums.RACK_SIZE, "every player still gets a full 6-tile rack")

	# Closest-to-1A comparison itself: row dominates column (9A beats 1B).
	var rank_9A := AcqEnums.tile_label(8, 0)   # just sanity-checking the helper exists
	check(rank_9A == "9A", "tile_label helper sane")
	var row_dominates := (Vector2i(8, 0).y * AcqEnums.BOARD_WIDTH + Vector2i(8, 0).x) \
		< (Vector2i(0, 1).y * AcqEnums.BOARD_WIDTH + Vector2i(0, 1).x)
	check(row_dominates, "9A ranks closer to 1A than 1B, as rules.txt specifies")

## rules.txt "Founding a Hotel Chain with Zero Stock Available": if all 25
## shares of the re-founded chain are already in players' hands, the founder
## gets cash equal to the share's value instead of a free share.
func test_found_with_zero_bank_stock() -> void:
	var gs := GameState.new()
	gs.setup_blank(2)
	gs.do_isolated(0, 0)
	# Drain the bank entirely, as if every share had previously been kept by
	# players after some earlier merger dissolved this same chain.
	gs.bank_shares[Chain.TOWER] = 0
	gs.players[0].cash = 6000
	gs.do_found(1, 0, Chain.TOWER)
	eq(gs.chain_size_of(Chain.TOWER), 2, "chain still founds normally")
	eq(gs.players[0].shares[Chain.TOWER], 0, "no share to give — bank is empty")
	eq(gs.bank_shares[Chain.TOWER], 0, "bank remains at zero")
	eq(gs.players[0].cash, 6000 + StockMarket.price(Chain.TOWER, 2), "founder paid cash instead")
