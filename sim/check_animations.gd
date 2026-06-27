extends SceneTree
## Headless check for Stage 2 (animation layer): with animations left ON
## (the default), confirms an event that has a real animation locks input
## (_animating true, drag/drop refused) the instant the triggering action is
## sent, then unlocks once the animation finishes and leaves the model/UI in
## exactly the state the no-animation path already proves correct (see
## sim/check_near_endgame.gd). Also confirms the merge-flash path runs to
## completion without error. Run with:
##   godot --headless --path <proj> --script sim/check_animations.gd
##
## Unlike the other sim/check_*.gd scripts, this one must let _process() run
## across several real frames (animations are real Tweens with real
## durations), so it's a small state machine across ticks rather than a
## single deferred-to-next-frame check.

const Phase = AcqEnums.GamePhase
const Kind = AcqEnums.PlacementKind
const Chain = AcqEnums.ChainId

var passed := 0
var failed := 0
var _scene
var _step := 0
var _wait_until_msec := 0

func _process(_dt: float) -> bool:
	match _step:
		0:
			_scene = load("res://ui/game/Game.tscn").instantiate()
			get_root().add_child(_scene)   # runs _ready -> builds full UI
			_scene._generate_near_endgame()
			_step = 1
		1:
			# _animations_enabled defaults true: sending this action should
			# leave _animating true the instant send_action() returns, since
			# the tile-slide animation suspends mid-await before this line
			# resumes.
			_scene.session.send_action(Action.make_place_tile(0, Vector2i(10, 4)))
			eq(_scene._animating, true, "_animating is true immediately after the animated action")
			eq(_scene.can_drag_tiles(), false, "dragging is locked out while animating")
			eq(_scene.can_drop_tile(0, 0, {"type": "tile", "coord": Vector2i(0, 0)}), false,
				"dropping is locked out while animating")
			_wait_until_msec = Time.get_ticks_msec() + 600
			_step = 2
		2:
			if Time.get_ticks_msec() >= _wait_until_msec:
				eq(_scene._animating, false, "_animating clears once the tile-slide animation finishes")
				eq(_scene.state.chain_size_of(Chain.LUXOR), 11, "LUXOR grew to size 11 (model unaffected by animation)")
				eq(_scene.state.phase, Phase.BUY_STOCK, "phase advanced to BUY_STOCK")
				eq(_scene.state.can_end_game(), true, "every active chain is now safe -> can end")
				_step = 3
		3:
			# Drive into a merger so the merge-flash animation (MERGER_STARTED)
			# also gets exercised, on a fresh hand-authored mid-game state.
			_scene._generate_midgame()
			_scene.session.send_action(Action.make_place_tile(0, Vector2i(4, 4)))   # merge: LUXOR + WORLDWIDE
			eq(_scene._animating, true, "_animating is true immediately after the merge action")
			_wait_until_msec = Time.get_ticks_msec() + 600
			_step = 4
		4:
			if Time.get_ticks_msec() >= _wait_until_msec:
				eq(_scene._animating, false, "_animating clears once the merge-flash animation finishes")
				eq(_scene.state.phase, Phase.RESOLVE_MERGER, "merge landed in RESOLVE_MERGER as normal")
				get_root().remove_child(_scene)
				_scene.queue_free()
				print("==== %d passed, %d failed ====" % [passed, failed])
				quit(1 if failed > 0 else 0)
				return true
	return false

func eq(got, expected, msg: String) -> void:
	if got == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s (got %s, expected %s)" % [msg, str(got), str(expected)])
