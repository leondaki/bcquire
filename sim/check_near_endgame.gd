extends SceneTree
## Headless check that the "Generate Near-Endgame" test button produces a
## state one grow away from can_end_game(), and that playing that grow then
## declaring the end actually drives the real session/UI flow through to the
## ranked summary screen. Run with:
##   godot --headless --path <proj> --script sim/check_near_endgame.gd
##
## We do the work in _process (not _initialize) so the instanced scene's _ready
## — which builds the board + sidebar — has fully run before we drive it.

const Kind = AcqEnums.PlacementKind
const Chain = AcqEnums.ChainId
const Phase = AcqEnums.GamePhase

var passed := 0
var failed := 0
var _ran := false
var _scene

func _process(_dt: float) -> bool:
	if _ran:
		return true
	_ran = true

	var scene = load("res://ui/game/Game.tscn").instantiate()
	_scene = scene
	get_root().add_child(scene)   # runs _ready -> builds full UI
	scene._animations_enabled = false   # keep session.send_action() below synchronous
	scene._generate_near_endgame()
	var st: GameState = scene.state

	# Two safe chains, one chain one tile short of safe -> cannot end yet.
	eq(st.chain_size_of(Chain.TOWER), 12, "TOWER size 12")
	eq(st.is_safe(Chain.TOWER), true, "TOWER safe")
	eq(st.chain_size_of(Chain.AMERICAN), 12, "AMERICAN size 12")
	eq(st.is_safe(Chain.AMERICAN), true, "AMERICAN safe")
	eq(st.chain_size_of(Chain.LUXOR), 10, "LUXOR size 10")
	eq(st.is_safe(Chain.LUXOR), false, "LUXOR not yet safe")
	eq(st.can_end_game(), false, "cannot end game yet")
	eq(_has_action_label("Declare Game End"), false, "no Declare Game End button yet")

	# Grow LUXOR to safe via the real session/Action path (not a direct mutation).
	eq(st.classify_placement(10, 4).kind, Kind.GROW, "(10,4) grows LUXOR")
	scene.session.send_action(Action.make_place_tile(0, Vector2i(10, 4)))

	eq(st.chain_size_of(Chain.LUXOR), 11, "LUXOR grew to size 11")
	eq(st.is_safe(Chain.LUXOR), true, "LUXOR now safe")
	eq(st.phase, Phase.BUY_STOCK, "phase advanced to BUY_STOCK")
	eq(st.can_end_game(), true, "every active chain is now safe -> can end")
	eq(_has_action_label("Declare Game End"), true, "Declare Game End button now shown")

	# Declare the end via the real session/Action path.
	scene.session.send_action(Action.make_buy_stock(0, {}, true))

	eq(st.phase, Phase.GAME_OVER, "phase advanced to GAME_OVER")
	eq(scene._final_scores.size(), 3, "final scores has one row per player")
	var prev_cash: int = scene._final_scores[0].cash
	for row in scene._final_scores:
		eq(row.cash <= prev_cash, true, "final scores sorted high to low")
		prev_cash = row.cash
	eq(_has_action_label("New Game"), true, "summary screen offers New Game")

	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)
	return true

func _has_action_label(text: String) -> bool:
	for child in _scene._action_box.get_children():
		if child is Button and (child as Button).text == text:
			return true
	return false

func eq(got, expected, msg: String) -> void:
	if got == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s (got %s, expected %s)" % [msg, str(got), str(expected)])
