extends SceneTree
## Headless check that the "Generate Mid-Game" test button produces exactly the
## board/rack scenario the UI features need to demonstrate, AND that a full UI
## refresh over that state runs without errors. Run with:
##   godot --headless --path <proj> --script sim/check_midgame.gd
##
## We do the work in _process (not _initialize) so the instanced scene's _ready
## — which builds the board + sidebar — has fully run before we drive it.

const Kind = AcqEnums.PlacementKind
const Chain = AcqEnums.ChainId

var passed := 0
var failed := 0
var _ran := false

func _process(_dt: float) -> bool:
	if _ran:
		return true
	_ran = true

	var scene = load("res://ui/game/Game.tscn").instantiate()
	get_root().add_child(scene)   # runs _ready -> builds full UI
	scene._generate_midgame()     # also runs a full _refresh_all over the UI
	var st: GameState = scene.state

	# Two safe chains exist; all seven are on the board.
	eq(st.chain_size_of(Chain.TOWER), 11, "TOWER size 11")
	eq(st.is_safe(Chain.TOWER), true, "TOWER safe")
	eq(st.chain_size_of(Chain.AMERICAN), 12, "AMERICAN size 12")
	eq(st.is_safe(Chain.AMERICAN), true, "AMERICAN safe")
	eq(st.available_active_chains().size(), 7, "all seven chains on board")

	# Demonstration rack classifications.
	eq(st.classify_placement(5, 1).kind, Kind.ILLEGAL_DEAD, "(5,1) is a DEAD tile")
	eq(st.classify_placement(8, 6).kind, Kind.ILLEGAL_TEMP, "(8,6) is TEMP-unplayable (8th chain)")
	eq(st.classify_placement(11, 0).kind, Kind.GROW, "(11,0) grows TOWER")
	eq(st.classify_placement(4, 4).kind, Kind.MERGE, "(4,4) is a merge")
	eq(st.classify_placement(11, 8).kind, Kind.ISOLATED, "(11,8) is isolated")
	var tie := st.merger_info(7, 4)
	eq(tie.survivor_candidates.size(), 2, "(7,4) is a TIE merge")

	# Board cells: dead/temp tiles must NOT be shaded playable; the others must.
	eq(scene._cells[Vector2i(5, 1)].playable, false, "DEAD square not highlighted")
	eq(scene._cells[Vector2i(8, 6)].playable, false, "TEMP square not highlighted")
	eq(scene._cells[Vector2i(11, 0)].playable, true, "grow square highlighted")
	eq(scene._cells[Vector2i(7, 4)].playable, true, "tie-merge square highlighted")

	# Shares/bank distributed; rack is full.
	eq(st.players[0].shares[Chain.TOWER], 4, "P1 holds 4 TOWER")
	eq(st.bank_shares[Chain.TOWER], 16, "bank has 16 TOWER")
	eq(st.players[0].rack.size(), 6, "current player has a full rack")

	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)
	return true

func eq(got, expected, msg: String) -> void:
	if got == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s (got %s, expected %s)" % [msg, str(got), str(expected)])
