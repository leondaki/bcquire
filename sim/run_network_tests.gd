extends SceneTree
## Headless host/client convergence test for the multiplayer Action/Event
## layer (net/). Two GameSessions (host = seat 0, client = seat 1) share a
## LoopbackHub — no sockets, no Node, no real networking — and play a full
## game purely through session.send_action() calls, exactly as a real client
## or the host's own UI would. After every single action this asserts the two
## sessions' GameState mirrors are deep-equal, which is the convergence
## guarantee net/session.gd's host-authoritative design rests on: the host
## always re-simulates against its own GameState and broadcasts an Event the
## client replays via the identical underlying state.* calls.
##
## Run with:
##   godot --headless --path <proj> --script sim/run_network_tests.gd
## Expected output: "==== N passed, 0 failed ====" and exit code 0.

const Phase = AcqEnums.GamePhase
const Kind = AcqEnums.PlacementKind

var passed := 0
var failed := 0

# Test-side bookkeeping mirroring what ui/game/game.gd tracks locally, fed by
# the host's event_applied signal (the host emits it for every event, whether
# the action that caused it originated locally or from the client).
var _pending_coord := Vector2i(-1, -1)
var _merge_candidates: Array = []
var _awaiting_survivor_choice := false
var _disposal_queue: Array = []

func _initialize() -> void:
	test_full_game_convergence()
	print("==== %d passed, %d failed ====" % [passed, failed])
	quit(1 if failed > 0 else 0)

# --- tiny assertion helpers (same convention as sim/run_tests.gd) ----------
func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + msg)

func eq(got, expected, msg: String) -> void:
	check(got == expected, "%s (got %s, expected %s)" % [msg, str(got), str(expected)])

# ===========================================================================

func test_full_game_convergence() -> void:
	var hub := LoopbackHub.new()
	var host_transport := LoopbackTransport.new(hub, true)
	var client_transport := LoopbackTransport.new(hub, false)
	var host := GameSession.new(host_transport, true, 0)
	var client := GameSession.new(client_transport, false, 1)
	host.event_applied.connect(_track_pending_state)

	host.host_start_game(["Host", "Client"], 12345)
	check(host.state != null and client.state != null, "both sessions have a GameState after GAME_STARTED")
	_assert_converged(host, client, "after GAME_STARTED")

	var iter := 0
	var stalled := false
	const MAX_ITERS := 3000
	while host.state.phase != Phase.GAME_OVER and iter < MAX_ITERS:
		iter += 1
		var pi: int = host.state.current_player
		var actor: GameSession = host if pi == 0 else client

		match host.state.phase:
			Phase.PLACE_TILE:
				var rack: Array = host.state.players[pi].rack
				if rack.is_empty():
					check(false, "iter %d: current player's rack is unexpectedly empty — auto-play stalled" % iter)
					break
				# A tile may be permanently dead (merges two safe chains) or only
				# temporarily blocked (would found an 8th chain) — both are
				# illegal to place; only dead tiles are eligible for redraw.
				var legal_tile := Vector2i(-1, -1)
				var dead_tile := Vector2i(-1, -1)
				for t in rack:
					var kind: int = host.state.classify_placement(t.x, t.y).kind
					if kind == Kind.ILLEGAL_DEAD:
						dead_tile = t
					elif kind != Kind.ILLEGAL_TEMP:
						legal_tile = t
						break
				if legal_tile.x >= 0:
					actor.send_action(Action.make_place_tile(pi, legal_tile))
				elif dead_tile.x >= 0:
					actor.send_action(Action.make_redraw_tile(pi, dead_tile))
				else:
					# Every rack tile is only temporarily blocked (would found an
					# 8th chain) — a real rare edge case this project's engine
					# doesn't yet have a rule for (rules.txt's discard-and-redraw
					# clause isn't implemented). Bail out cleanly rather than
					# spinning forever; this isn't a convergence failure.
					print("STALL at iter %d: player %d's whole rack is temporarily unplayable." % [iter, pi])
					stalled = true
					break
			Phase.FOUND_CHAIN:
				var chain: int = host.state.available_chains()[0]
				actor.send_action(Action.make_choose_found(pi, _pending_coord, chain))
			Phase.RESOLVE_MERGER:
				if _awaiting_survivor_choice:
					actor.send_action(Action.make_choose_survivor(pi, _pending_coord, _merge_candidates[0]))
				elif not _disposal_queue.is_empty():
					var entry: Dictionary = _disposal_queue[0]
					var dactor: GameSession = host if entry.player == 0 else client
					dactor.send_action(Action.make_dispose_stock(entry.player, entry.defunct, 0, 0))
				else:
					check(false, "iter %d: RESOLVE_MERGER phase with nothing pending — stalled" % iter)
					break
			Phase.BUY_STOCK:
				var order := {}
				var active: Array = host.state.available_active_chains()
				if not active.is_empty():
					var ch: int = active[0]
					var price := host.state.current_price(ch)
					if host.state.bank_shares[ch] > 0 and host.state.players[pi].cash >= price:
						order[ch] = 1
				var declare_end := host.state.can_end_game()
				actor.send_action(Action.make_buy_stock(pi, order, declare_end))
			_:
				check(false, "iter %d: unexpected phase %d" % [iter, host.state.phase])
				break

		_assert_converged(host, client, "iter %d (phase now %d)" % [iter, host.state.phase])

	if not stalled:
		check(host.state.phase == Phase.GAME_OVER, "game reached GAME_OVER within %d iterations" % MAX_ITERS)
	if host.state.phase == Phase.GAME_OVER:
		var total_cash := 0
		for p in host.state.players:
			check(p.cash >= 0, "%s ends with non-negative cash" % p.pname)
			total_cash += p.cash
		check(total_cash > 2 * AcqEnums.STARTING_CASH, "total cash grew over the game (sanity check)")

func _track_pending_state(event: Dictionary) -> void:
	var p: Dictionary = event.payload
	match event.type:
		Event.CHAIN_FOUND_PENDING:
			_pending_coord = p.coord
		Event.MERGER_PENDING:
			_pending_coord = p.coord
			_merge_candidates = p.survivor_candidates
			_awaiting_survivor_choice = _merge_candidates.size() > 1
		Event.MERGER_STARTED:
			_awaiting_survivor_choice = false
			_disposal_queue = p.disposal_queue.duplicate(true)
		Event.STOCK_DISPOSED:
			if not _disposal_queue.is_empty():
				_disposal_queue.pop_front()

## Deep-equality check between the host's and client's GameState mirrors —
## the core convergence guarantee this whole test exists to exercise.
func _assert_converged(host: GameSession, client: GameSession, label: String) -> void:
	var hs := host.state
	var cs := client.state
	check(hs.board == cs.board, "%s: board mismatch" % label)
	check(hs.chain_size == cs.chain_size, "%s: chain_size mismatch" % label)
	check(hs.bank_shares == cs.bank_shares, "%s: bank_shares mismatch" % label)
	check(hs.bag == cs.bag, "%s: bag mismatch" % label)
	check(hs.current_player == cs.current_player, "%s: current_player mismatch" % label)
	eq(hs.phase, cs.phase, "%s: phase mismatch" % label)
	eq(hs.players.size(), cs.players.size(), "%s: player count mismatch" % label)
	for i in hs.players.size():
		var hp: GameState.PlayerState = hs.players[i]
		var cp: GameState.PlayerState = cs.players[i]
		check(hp.cash == cp.cash, "%s: player %d cash mismatch (%d vs %d)" % [label, i, hp.cash, cp.cash])
		check(hp.shares == cp.shares, "%s: player %d shares mismatch" % [label, i])
		check(hp.rack == cp.rack, "%s: player %d rack mismatch" % [label, i])
