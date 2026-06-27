extends SceneTree
## Headless check for Stage 1 (main menu + NetConfig plumbing): confirms
## MainMenu.tscn builds its controls, that the NetConfig autoload correctly
## carries a menu choice across to Game.tscn's _ready() (hotseat/host paths,
## and the no-pending-intent fallback used by other headless scripts), and
## that the game-over screen offers a "Main Menu" button. Run with:
##   godot --headless --path <proj> --script sim/check_menu_flow.gd
##
## We do the work in _process (not _initialize) so each instanced scene's
## _ready() has fully run before we inspect it — same reasoning as
## sim/check_midgame.gd's file-header comment.

const Phase = AcqEnums.GamePhase

var passed := 0
var failed := 0
var _ran := false

func _process(_dt: float) -> bool:
	if _ran:
		return true
	_ran = true

	# Fetched dynamically (not referenced as a bare "NetConfig" identifier):
	# a --script entry point compiles before autoloads are registered as
	# global identifiers, so a direct reference fails to compile here even
	# though it resolves fine inside game.gd (loaded later, at runtime,
	# after autoloads are live).
	var net_config := get_root().get_node("NetConfig")

	# --- MainMenu.tscn builds its controls -------------------------------
	var menu = load("res://ui/menu/MainMenu.tscn").instantiate()
	get_root().add_child(menu)
	eq(menu._name_edit != null, true, "menu has a name field")
	eq(menu._host_port_edit != null, true, "menu has a host-port field")
	eq(menu._join_addr_edit != null, true, "menu has a join-address field")
	eq(menu._join_port_edit != null, true, "menu has a join-port field")
	get_root().remove_child(menu)
	menu.queue_free()

	# --- Hotseat path: NetConfig carries the chosen name into Game.tscn --
	net_config.set_hotseat("Alice")
	eq(net_config.has_pending, true, "hotseat intent recorded")
	var game1 = load("res://ui/game/Game.tscn").instantiate()
	get_root().add_child(game1)
	eq(net_config.has_pending, false, "Game.tscn consumed and cleared the pending intent")
	eq(game1._is_networked, false, "hotseat path is not networked")
	eq(game1.state.players[0].pname, "Alice", "hotseat seat 0 uses the carried name")
	get_root().remove_child(game1)
	game1.queue_free()

	# --- Host path: NetConfig carries name+port, game.gd auto-hosts ------
	net_config.set_host("Bob", 8930)
	var game2 = load("res://ui/game/Game.tscn").instantiate()
	get_root().add_child(game2)
	eq(net_config.has_pending, false, "host intent consumed and cleared")
	eq(game2._is_networked, true, "host path is networked")
	eq(game2.session.is_host, true, "host path creates a host session")
	eq(game2._my_player_name, "Bob", "host path carries the chosen name")
	eq(game2.state, null, "host is frozen waiting for Start Networked Game")
	get_root().remove_child(game2)
	game2.queue_free()

	# --- No pending intent: behaves exactly like today (solo hotseat) ----
	var game3 = load("res://ui/game/Game.tscn").instantiate()
	get_root().add_child(game3)
	eq(game3._is_networked, false, "no-NetConfig fallback is not networked")
	eq(game3.state.players[0].pname, "Player 1", "no-NetConfig fallback uses default names")
	get_root().remove_child(game3)
	game3.queue_free()

	# --- Game-over screen offers a "Main Menu" button alongside New Game --
	var game4 = load("res://ui/game/Game.tscn").instantiate()
	get_root().add_child(game4)
	game4._animations_enabled = false   # keep session.send_action() below synchronous
	game4._generate_near_endgame()
	game4.session.send_action(Action.make_place_tile(0, Vector2i(10, 4)))
	game4.session.send_action(Action.make_buy_stock(0, {}, true))
	eq(game4.state.phase, Phase.GAME_OVER, "drove the demo state to GAME_OVER")
	eq(_has_button(game4._action_box, "New Game"), true, "game-over screen has New Game")
	eq(_has_button(game4._action_box, "Main Menu"), true, "game-over screen has Main Menu")
	get_root().remove_child(game4)
	game4.queue_free()

	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)
	return true

func _has_button(container: Node, text: String) -> bool:
	for child in container.get_children():
		if child is Button and (child as Button).text == text:
			return true
	return false

func eq(got, expected, msg: String) -> void:
	if got == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s (got %s, expected %s)" % [msg, str(got), str(expected)])
