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
			# Drive into a merger on a fresh hand-authored mid-game state.
			# Kind.MERGE placements never emit a TILE_PLACED event (see
			# net/session.gd's _apply_place_tile) -- they go straight to
			# MERGER_PENDING/MERGER_STARTED, neither of which animates
			# anymore (game.gd's _play_event_animation), so nothing should be
			# animating the instant this resolves.
			_scene._generate_midgame()
			_scene.session.send_action(Action.make_place_tile(0, Vector2i(4, 4)))   # merge: LUXOR + WORLDWIDE
			eq(_scene._animating, false, "no animation plays for the merge placement itself (MERGER_STARTED no longer animates)")
			eq(_scene.state.phase, Phase.RESOLVE_MERGER, "merge landed in RESOLVE_MERGER as normal")
			eq(_scene._disposal_queue.size(), 1, "only player 0's 1 WORLDWIDE share is owed a disposal decision")
			_step = 4
		4:
			# Resolve the only pending disposal (keep the share). This empties
			# the queue, so the engine emits MERGER_FINISHED, whose animation
			# (game.gd's _animate_merger_finished) is the one this whole
			# scenario exists to exercise: the survivor chain's color-fade
			# should only start now, once the takeover is actually final.
			var entry: Dictionary = _scene._disposal_queue[0]
			_scene.session.send_action(Action.make_dispose_stock(entry.player, entry.defunct, 0, 0))
			eq(_scene._animating, true, "_animating is true immediately after the disposal that finishes the merger")
			# A defunct cell that was already showing WORLDWIDE's color before
			# this turn (unlike (4,4), the merge tile itself, which was freshly
			# placed and had no prior chain color to fade from) -- the bug this
			# guards against is the fade silently starting from its own target
			# color (a no-op) because an intervening _refresh_all() already
			# repainted it; this fails loudly if that regresses.
			var worldwide_cell: BoardCell = _scene._cells[Vector2i(5, 4)]
			var start_bg: Color = worldwide_cell.get_theme_stylebox("normal").bg_color
			eq(start_bg, _scene._theme.chain_color(Chain.WORLDWIDE),
				"absorbed cell still shows the defunct chain's color the instant the fade starts")
			_wait_until_msec = Time.get_ticks_msec() + 700
			_step = 5
		5:
			if Time.get_ticks_msec() >= _wait_until_msec:
				eq(_scene._animating, false, "_animating clears once the merger-finished color-fade completes")
				eq(_scene.state.phase, Phase.BUY_STOCK, "merger fully resolved into BUY_STOCK")
				var luxor_color: Color = _scene._theme.chain_color(Chain.LUXOR)
				var merge_tile_cell: BoardCell = _scene._cells[Vector2i(4, 4)]
				eq(merge_tile_cell.get_theme_stylebox("normal").bg_color, luxor_color,
					"the merge tile's own cell now actually shows LUXOR's color")
				var worldwide_cell: BoardCell = _scene._cells[Vector2i(5, 4)]
				eq(worldwide_cell.get_theme_stylebox("normal").bg_color, luxor_color,
					"the absorbed (formerly-WORLDWIDE) cell faded all the way to LUXOR's color")
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
