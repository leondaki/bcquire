extends SceneTree
## Headless check that game.gd's seat-gating (_is_my_turn/_is_my_seat) actually
## disables the right seat's controls once hotseat_mode is false, across every
## phase _rebuild_action_area() handles, including the per-shareholder dispose
## special case. Run with:
##   godot --headless --path <proj> --script sim/check_seat_gating.gd
##
## We do the work in _process (not _initialize) so each instanced scene's
## _ready() -- which builds the board + sidebar -- has fully run before we
## drive it. Two independent Game.tscn instances are used (ctrl_a = seat 0
## local, ctrl_b = seat 1 local), sharing ONE hand-authored GameState object
## assigned directly to both controllers' `state` and `session.state` fields,
## exactly like the existing dev-harness pattern (_generate_midgame()). Both
## controllers only ever READ `state` (see _refresh_all()/BoardCell.refresh()/
## RackTile.setup(), all pure views keyed by each controller's own
## session.local_player_index via _viewer_seat()), so sharing one object
## across two simultaneously-live controllers is safe by construction.

const Phase = AcqEnums.GamePhase
const Chain = AcqEnums.ChainId

var passed := 0
var failed := 0
var _ran := false
var ctrl_a
var ctrl_b
var state: GameState

func _process(_dt: float) -> bool:
	if _ran:
		return true
	_ran = true

	ctrl_a = load("res://ui/game/Game.tscn").instantiate()
	ctrl_b = load("res://ui/game/Game.tscn").instantiate()
	get_root().add_child(ctrl_a)   # runs _ready -> builds full UI, default solo session
	get_root().add_child(ctrl_b)
	ctrl_a._animations_enabled = false
	ctrl_b._animations_enabled = false

	_build_shared_scenario()
	_wire_sessions()

	_check_place_tile_gating()
	_check_found_chain_gating()
	_check_buy_stock_gating()
	_check_dispose_gating()
	_check_can_drop_tile_invariant()

	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)
	return true

## One shared hand-authored GameState, mutated phase-to-phase rather than
## rebuilt per phase: PLACE_TILE/FOUND_CHAIN/BUY_STOCK are all gated by the
## exact same _is_my_turn() check at the top of _rebuild_action_area(), so
## there's no per-phase gating logic to re-prove, only that flipping
## state.phase/state.current_player produces the right controls for the
## right seat.
func _build_shared_scenario() -> void:
	state = GameState.new()
	state.setup_blank(2)
	state.players[0].pname = "Player 1"
	state.players[1].pname = "Player 2"

	state.set_cell(0, 0, Chain.TOWER)
	state.set_cell(1, 0, Chain.TOWER)
	state.chain_size[Chain.TOWER] = 2

	for p in state.players:
		p.shares.fill(0)
	state.players[0].shares[Chain.TOWER] = 3
	state.players[1].shares[Chain.TOWER] = 2
	state.bank_shares = PackedInt32Array([20, 25, 25, 25, 25, 25, 25])
	state.players[0].cash = 6000
	state.players[1].cash = 6000

	# Match the existing dev-harness convention (_generate_midgame) of
	# clear()+append() rather than reassigning the typed Array[Vector2i]
	# field directly.
	state.players[0].rack.clear()
	for t in [Vector2i(2, 0), Vector2i(5, 5)]:
		state.players[0].rack.append(t)
	state.players[1].rack.clear()
	for t in [Vector2i(3, 0), Vector2i(6, 5)]:
		state.players[1].rack.append(t)

	state.current_player = 0
	state.phase = Phase.PLACE_TILE

## Each Game.tscn instance's _ready() already auto-built its own default
## solo GameSession and dealt a real random game; we overwrite `state` and
## `session.state` with the shared scenario above, exactly like
## _generate_midgame() already does to its own freshly-dealt state. No
## second LoopbackHub/LoopbackTransport pair is needed since this test never
## calls session.send_action() -- see the file-level header comment.
func _wire_sessions() -> void:
	ctrl_a.state = state
	ctrl_a.session.state = state
	ctrl_a.session.hotseat_mode = false
	ctrl_a.session.local_player_index = 0

	ctrl_b.state = state
	ctrl_b.session.state = state
	ctrl_b.session.hotseat_mode = false
	ctrl_b.session.local_player_index = 1

func _check_place_tile_gating() -> void:
	state.phase = Phase.PLACE_TILE
	state.current_player = 0
	ctrl_a._refresh_all(); ctrl_b._refresh_all()
	eq(ctrl_a.can_drag_tiles(), true, "seat 0 can drag on its own PLACE_TILE turn")
	eq(_has_waiting_label(ctrl_a), false, "seat 0 sees real place-tile instructions")
	eq(ctrl_b.can_drag_tiles(), false, "seat 1 cannot drag while it's seat 0's turn")
	eq(_has_waiting_label(ctrl_b), true, "seat 1 sees the waiting label")

	state.current_player = 1
	ctrl_a._refresh_all(); ctrl_b._refresh_all()
	eq(ctrl_a.can_drag_tiles(), false, "seat 0 cannot drag once it's seat 1's turn")
	eq(_has_waiting_label(ctrl_a), true, "seat 0 now sees the waiting label")
	eq(ctrl_b.can_drag_tiles(), true, "seat 1 can drag on its own PLACE_TILE turn")
	eq(_has_waiting_label(ctrl_b), false, "seat 1 sees real place-tile instructions")

	state.current_player = 0   # reset for subsequent phase checks

func _check_found_chain_gating() -> void:
	state.phase = Phase.FOUND_CHAIN
	state.current_player = 0
	ctrl_a._refresh_all(); ctrl_b._refresh_all()
	eq(_has_waiting_label(ctrl_a), false, "seat 0 (active) gets real found-chain buttons")
	eq(_has_waiting_label(ctrl_b), true, "seat 1 (inactive) waits during FOUND_CHAIN")

	state.current_player = 1
	ctrl_a._refresh_all(); ctrl_b._refresh_all()
	eq(_has_waiting_label(ctrl_a), true, "seat 0 now waits")
	eq(_has_waiting_label(ctrl_b), false, "seat 1 (now active) gets real buttons")

	state.current_player = 0

func _check_buy_stock_gating() -> void:
	state.phase = Phase.BUY_STOCK
	state.current_player = 0
	ctrl_a._refresh_all(); ctrl_b._refresh_all()
	eq(_has_waiting_label(ctrl_a), false, "seat 0 (active) gets real buy-stock controls")
	eq(_has_action_label(ctrl_a, "End Turn"), true, "seat 0 sees End Turn button")
	eq(_has_waiting_label(ctrl_b), true, "seat 1 (inactive) waits during BUY_STOCK")

	state.current_player = 1
	ctrl_a._refresh_all(); ctrl_b._refresh_all()
	eq(_has_waiting_label(ctrl_a), true, "seat 0 now waits")
	eq(_has_waiting_label(ctrl_b), false, "seat 1 (now active) gets real buy-stock controls")

	state.current_player = 0

## RESOLVE_MERGER's dispose sub-mode is gated per-shareholder via
## _is_my_seat() on _disposal_queue[0].player, NOT per-current-player --
## deliberately leave current_player at seat 0 while seat 1 is the one owed
## a disposal decision, to prove gating doesn't fall back to current_player.
## _merge_mode/_disposal_queue/_merge_survivor are controller-local fields,
## set independently on each controller (mirrors how the dev harnesses
## bypass the Action/Event path).
func _check_dispose_gating() -> void:
	state.phase = Phase.RESOLVE_MERGER
	state.current_player = 0
	var queue := [{"defunct": Chain.TOWER, "player": 1}]
	for ctrl in [ctrl_a, ctrl_b]:
		ctrl._merge_mode = "dispose"
		ctrl._disposal_queue = queue.duplicate(true)
		ctrl._merge_survivor = Chain.LUXOR   # any non-TOWER chain w/ bank stock
		ctrl._refresh_all()

	eq(_has_waiting_label(ctrl_a), true,
		"ctrl_a (seat 0) waits during dispose even though current_player==0")
	eq(_has_dispose_controls(ctrl_a), false, "ctrl_a gets no dispose controls")
	eq(_has_waiting_label(ctrl_b), false,
		"ctrl_b (seat 1) does not wait -- it's their disposal decision")
	eq(_has_dispose_controls(ctrl_b), true, "ctrl_b gets real dispose controls")

## can_drop_tile() has its own substantial guard (data-shape, phase/
## animating, coord-match, placement-legality) but no seat check of its own
## -- it relies entirely on can_drag_tiles() (via RackTile._get_drag_data())
## having already refused to start the drag for an inactive seat. Pin this
## as an explicit, executable contract: called directly, bypassing the
## drag-start gate, it returns true for seat 1's own legal tile even while
## seat 1 is inactive.
func _check_can_drop_tile_invariant() -> void:
	state.phase = Phase.PLACE_TILE
	state.current_player = 0   # seat 1 is NOT active
	eq(ctrl_b.can_drag_tiles(), false,
		"setup: seat 1 cannot start a drag while it's seat 0's turn")

	var data := {"type": "tile", "coord": Vector2i(3, 0)}   # seat 1's own rack tile
	eq(ctrl_b.can_drop_tile(3, 0, data), true,
		"can_drop_tile() has no seat check -- relies on can_drag_tiles() " +
		"having gated the drag start (pinning today's contract)")

func _has_action_label(ctrl, text: String) -> bool:
	for child in ctrl._action_box.get_children():
		if child is Button and (child as Button).text == text:
			return true
	return false

## _build_waiting_label() always adds a second Label whose text starts with
## "Waiting for " across every gating path this test exercises.
func _has_waiting_label(ctrl) -> bool:
	for child in ctrl._action_box.get_children():
		if child is Label and (child as Label).text.begins_with("Waiting for "):
			return true
	return false

func _has_dispose_controls(ctrl) -> bool:
	for child in ctrl._action_box.get_children():
		if child is SpinBox:
			return true
	return false

func eq(got, expected, msg: String) -> void:
	if got == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s (got %s, expected %s)" % [msg, str(got), str(expected)])
