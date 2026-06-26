extends Control
## Game controller: builds the board + sidebar + bottom-left chains table and
## drives the turn through its phases (place -> found/merge -> buy -> end). It
## is the bridge between the pure rules engine (core/) and the themed view
## (ui/).
##
## All GameState mutation goes through a GameSession (net/session.gd) — this
## controller only ever builds an Action and calls session.send_action(); the
## session's event_applied signal (-> _on_event_applied below) is the single
## place state actually gets mutated and the UI reacts. By default _ready()
## wires up a solo host-only session over a one-peer LoopbackTransport with
## hotseat_mode = true, which reproduces today's hotseat behaviour exactly
## (every seat can always act) while already running every mutation through
## the same Action/Event path real networked play (M4) will use.

const NUM_PLAYERS := 3
const Phase = AcqEnums.GamePhase
const Kind = AcqEnums.PlacementKind
const Chain = AcqEnums.ChainId

var state: GameState
var session: GameSession
var _theme: ThemeDef

# UI nodes built in _build_layout().
var _board_grid: GridContainer
var _cells := {}                 # Vector2i -> BoardCell
var _header_lbl: Label
var _phase_lbl: Label
var _rack_box: HFlowContainer
var _stock_box: HFlowContainer
var _chains_grid: GridContainer  # bottom-left chains table
var _action_box: VBoxContainer
var _msg_lbl: Label

# Transient turn state.
var _drag_coord := Vector2i(-1, -1)
var _pending_coord := Vector2i(-1, -1)   # the tile being resolved (found/merge)
var _merge_mode := ""                     # "" | "tie" | "dispose"
var _merge_candidates: Array = []         # tied survivor choices
var _merge_survivor: int = Chain.NONE
var _disposal_queue: Array = []           # [{ "defunct", "player" }]
var _buy_counts := {}                     # chain -> shares queued this buy phase
var _final_scores: Array = []

# Networking lobby (Stage B). _is_networked is false until Host/Join is
# clicked; the dev-tooling row (Generate Mid-Game/Reset) is only visible while
# it's false or no remote peer has joined yet, since either button mutates
# state without going through an Action and would desync any connected peer.
var _is_networked := false
var _lobby_peers: Array[int] = []         # remote peer ids, host-side, join order
var _dev_row: HBoxContainer
var _net_status_lbl: Label
var _host_port_edit: LineEdit
var _join_addr_edit: LineEdit
var _join_port_edit: LineEdit
var _start_net_btn: Button


func _ready() -> void:
	_theme = load("res://theme/default_theme.tres")
	_build_layout()
	_init_default_session()
	_start_new_game()

## Solo-play default: one host session over a one-peer loopback transport.
## Stage B's lobby will replace this with a real ENet transport and
## hotseat_mode = false once a second peer actually connects.
func _init_default_session() -> void:
	var hub := LoopbackHub.new()
	var transport := LoopbackTransport.new(hub, true)
	session = GameSession.new(transport, true, 0)
	session.hotseat_mode = true
	session.event_applied.connect(_on_event_applied)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		end_drag()


# ===========================================================================
#  Layout construction
# ===========================================================================

func _build_layout() -> void:
	var bg := ColorRect.new()
	bg.color = _theme.color_background
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Guard against the window being resized so small that controls overlap
	# unusably — everything below this size scrolls instead of squashing.
	get_window().min_size = Vector2i(1000, 620)

	# Top-level vertical stack: a row of (board | sidebar) that takes all
	# available space, plus a slim footer pinned at the very bottom of the
	# window. The footer is a DIRECT sibling here — never inside a scroll
	# container — so the test buttons stay visible no matter how much the
	# board/sidebar content overflows and has to scroll.
	var main_vbox := VBoxContainer.new()
	add_child(main_vbox)
	main_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_vbox.offset_left = 14
	main_vbox.offset_top = 10
	main_vbox.offset_right = -14
	main_vbox.offset_bottom = -10
	main_vbox.add_theme_constant_override("separation", 8)

	var content_row := HBoxContainer.new()
	content_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_row.add_theme_constant_override("separation", 14)
	main_vbox.add_child(content_row)

	# --- Left column (scrollable): title, board, message, chains + prices ---
	var left_scroll := ScrollContainer.new()
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_row.add_child(left_scroll)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left)

	var title := Label.new()
	title.text = "ACQUIRE"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", _theme.color_label)
	left.add_child(title)

	_board_grid = GridContainer.new()
	_board_grid.columns = _theme.board_width
	_board_grid.add_theme_constant_override("h_separation", 3)
	_board_grid.add_theme_constant_override("v_separation", 3)
	left.add_child(_board_grid)
	for r in _theme.board_height:
		for c in _theme.board_width:
			var cellnode := BoardCell.new()
			_board_grid.add_child(cellnode)
			cellnode.setup(c, r, _theme, self)
			_cells[Vector2i(c, r)] = cellnode

	_msg_lbl = Label.new()
	_msg_lbl.add_theme_color_override("font_color", _theme.color_placed)
	_msg_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_msg_lbl)

	# Bottom-left: chains table (left half) + always-visible price chart (right half).
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	var chains_box := _build_chains_table_box()
	chains_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(chains_box)
	var price_box := _build_price_chart_box()
	price_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(price_box)
	left.add_child(bottom)

	# --- Right column (scrollable): sidebar ---
	var right_scroll := ScrollContainer.new()
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_scroll.custom_minimum_size = Vector2(424, 0)
	content_row.add_child(right_scroll)

	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.custom_minimum_size = Vector2(396, 0)
	side.add_theme_constant_override("separation", 8)
	right_scroll.add_child(side)

	_header_lbl = Label.new()
	_header_lbl.add_theme_font_size_override("font_size", 22)
	side.add_child(_header_lbl)

	_phase_lbl = Label.new()
	_phase_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_phase_lbl.add_theme_color_override("font_color", _theme.color_label.darkened(0.15))
	side.add_child(_phase_lbl)

	side.add_child(_section_label("Your Tiles"))
	_rack_box = HFlowContainer.new()
	side.add_child(_rack_box)

	side.add_child(_section_label("Your Stock"))
	_stock_box = HFlowContainer.new()
	side.add_child(_stock_box)

	side.add_child(_section_label("Actions"))
	_action_box = VBoxContainer.new()
	_action_box.add_theme_constant_override("separation", 6)
	side.add_child(_action_box)

	# --- Footer (pinned, always visible — never inside a scroll container) ---
	main_vbox.add_child(_build_test_footer())

func _build_chains_table_box() -> PanelContainer:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _theme.color_empty.darkened(0.2)
	sb.border_color = _theme.color_placed
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	box.add_child(v)
	var head := Label.new()
	head.text = "CHAINS ON THE BOARD"
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", _theme.color_placed)
	v.add_child(head)

	_chains_grid = GridContainer.new()
	_chains_grid.columns = 4
	_chains_grid.add_theme_constant_override("h_separation", 16)
	_chains_grid.add_theme_constant_override("v_separation", 5)
	v.add_child(_chains_grid)
	return box

## A static reference card showing the Acquire stock price chart (price per share
## for each chain-size bracket, by price tier). Built once — prices never change.
func _build_price_chart_box() -> PanelContainer:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _theme.color_empty.darkened(0.2)
	sb.border_color = _theme.color_placed
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	box.add_child(v)
	var head := Label.new()
	head.text = "STOCK PRICE CHART  ($ per share)"
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", _theme.color_placed)
	v.add_child(head)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 3)
	v.add_child(grid)

	# Header: "Size" + one column per price tier, labelled with that tier's chains.
	grid.add_child(_table_head("Size"))
	var tier_chains := [
		[Chain.TOWER, Chain.LUXOR],
		[Chain.AMERICAN, Chain.WORLDWIDE, Chain.FESTIVAL],
		[Chain.IMPERIAL, Chain.CONTINENTAL],
	]
	for reps in tier_chains:
		var names: Array = []
		for ch in reps:
			names.append(_theme.chain_name(ch))
		var h := Label.new()
		h.text = "\n".join(names)
		h.add_theme_font_size_override("font_size", 10)
		h.add_theme_color_override("font_color", _theme.chain_color(reps[0]).lightened(0.25))
		grid.add_child(h)

	# Rows: one per size bracket; price computed from a representative chain.
	var rep_for_tier := [Chain.TOWER, Chain.AMERICAN, Chain.IMPERIAL]
	var rows := [
		["2", 2], ["3", 3], ["4", 4], ["5", 5], ["6–10", 6],
		["11–20", 11], ["21–30", 21], ["31–40", 31], ["41+", 41],
	]
	for row in rows:
		var label := Label.new()
		label.text = str(row[0])
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", _theme.color_lone_tile)
		grid.add_child(label)
		for rep in rep_for_tier:
			var pl := Label.new()
			pl.text = "$%d" % StockMarket.price(rep, int(row[1]))
			pl.add_theme_font_size_override("font_size", 11)
			pl.add_theme_color_override("font_color", _theme.color_label)
			grid.add_child(pl)

	var note := Label.new()
	note.text = "Majority bonus = 10 × price     Minority = 5 × price"
	note.add_theme_font_size_override("font_size", 10)
	note.add_theme_color_override("font_color", _theme.color_lone_tile)
	v.add_child(note)
	return box

func _build_test_footer() -> VBoxContainer:
	var footer := VBoxContainer.new()
	footer.add_theme_constant_override("separation", 6)

	_dev_row = HBoxContainer.new()
	_dev_row.alignment = BoxContainer.ALIGNMENT_END
	_dev_row.add_theme_constant_override("separation", 8)
	var gen := _bordered_button("Generate Mid-Game")
	gen.pressed.connect(_generate_midgame)
	_dev_row.add_child(gen)
	var reset := _bordered_button("Reset (Empty)")
	reset.pressed.connect(_start_new_game)
	_dev_row.add_child(reset)
	footer.add_child(_dev_row)

	footer.add_child(_build_lobby_row())
	return footer

## Minimal host/join controls for real LAN play (Stage B). Hosting opens an
## ENet server and waits for "Start Networked Game"; joining connects and
## waits for the host's GAME_STARTED broadcast. See net/enet_transport.gd.
func _build_lobby_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_host_port_edit = LineEdit.new()
	_host_port_edit.text = "8910"
	_host_port_edit.custom_minimum_size = Vector2(56, 0)
	_host_port_edit.tooltip_text = "Port to host on"
	row.add_child(_host_port_edit)
	var host_btn := _bordered_button("Host")
	host_btn.pressed.connect(_on_host_pressed)
	row.add_child(host_btn)

	_join_addr_edit = LineEdit.new()
	_join_addr_edit.text = "127.0.0.1"
	_join_addr_edit.custom_minimum_size = Vector2(110, 0)
	_join_addr_edit.tooltip_text = "Host address"
	row.add_child(_join_addr_edit)
	_join_port_edit = LineEdit.new()
	_join_port_edit.text = "8910"
	_join_port_edit.custom_minimum_size = Vector2(56, 0)
	_join_port_edit.tooltip_text = "Host port"
	row.add_child(_join_port_edit)
	var join_btn := _bordered_button("Join")
	join_btn.pressed.connect(_on_join_pressed)
	row.add_child(join_btn)

	_start_net_btn = _bordered_button("Start Networked Game")
	_start_net_btn.disabled = true
	_start_net_btn.pressed.connect(_on_start_networked_game_pressed)
	row.add_child(_start_net_btn)

	_net_status_lbl = Label.new()
	_net_status_lbl.text = "Not networked — playing solo/hotseat."
	_net_status_lbl.add_theme_color_override("font_color", _theme.color_lone_tile)
	row.add_child(_net_status_lbl)
	return row

func _on_host_pressed() -> void:
	var port := int(_host_port_edit.text) if _host_port_edit.text.is_valid_int() else 8910
	var transport := EnetTransport.new()
	# A fixed name is required: Godot's high-level RPC system routes by exact
	# NodePath, and add_child() without one assigns an auto-generated name
	# (e.g. "@Node@209") that differs per process — the receiving peer then
	# can't find the matching node ("Node not found: Game/@Node@209").
	transport.name = "EnetTransport"
	add_child(transport)
	var err := transport.host(port)
	if err != OK:
		_net_status_lbl.text = "Failed to host on port %d (error %d)." % [port, err]
		transport.queue_free()
		return

	_is_networked = true
	_lobby_peers = []
	session = GameSession.new(transport, true, 0)
	session.hotseat_mode = false
	session.event_applied.connect(_on_event_applied)
	transport.peer_joined.connect(_on_lobby_peer_joined)
	transport.peer_left.connect(_on_lobby_peer_left)
	state = null   # frozen board until "Start Networked Game" deals a real GameState
	_start_net_btn.disabled = false
	_net_status_lbl.text = "Hosting on port %d — 0 player(s) joined." % port
	_refresh_all()

func _on_join_pressed() -> void:
	var addr := _join_addr_edit.text if not _join_addr_edit.text.is_empty() else "127.0.0.1"
	var port := int(_join_port_edit.text) if _join_port_edit.text.is_valid_int() else 8910
	var transport := EnetTransport.new()
	transport.name = "EnetTransport"   # must match the host's NodePath exactly — see _on_host_pressed
	add_child(transport)
	var err := transport.join(addr, port)
	if err != OK:
		_net_status_lbl.text = "Failed to start connecting to %s:%d (error %d)." % [addr, port, err]
		transport.queue_free()
		return

	_is_networked = true
	session = GameSession.new(transport, false, -1)   # seat unknown until GAME_STARTED arrives
	session.hotseat_mode = false
	session.event_applied.connect(_on_event_applied)
	transport.join_succeeded.connect(func(): _net_status_lbl.text = "Connected — waiting for host to start.")
	transport.join_failed.connect(func(reason): _net_status_lbl.text = "Join failed: %s" % reason)
	transport.peer_left.connect(func(_id): _msg("Disconnected from host."))
	state = null   # frozen board until the host's GAME_STARTED deals a real GameState
	_net_status_lbl.text = "Connecting to %s:%d..." % [addr, port]
	_refresh_all()

func _on_lobby_peer_joined(peer_id: int) -> void:
	if not _lobby_peers.has(peer_id):
		_lobby_peers.append(peer_id)
	_net_status_lbl.text = "Hosting — %d player(s) joined." % _lobby_peers.size()

func _on_lobby_peer_left(peer_id: int) -> void:
	_lobby_peers.erase(peer_id)
	_msg("A player disconnected.")
	_net_status_lbl.text = "Hosting — %d player(s) joined." % _lobby_peers.size()

## Host-only: deal the real game once every expected player has joined.
## Seat 0 is always the host; remote joiners get seats 1, 2, ... in the order
## they connected — see Event.make_game_started's peer_seats payload.
func _on_start_networked_game_pressed() -> void:
	var names := ["Host"]
	var peer_seats := {}
	for i in _lobby_peers.size():
		names.append("Player %d" % (i + 2))
		peer_seats[_lobby_peers[i]] = i + 1
	_start_net_btn.disabled = true
	_net_status_lbl.text = "Game started (%d player%s)." % [names.size(), "" if names.size() == 1 else "s"]
	session.host_start_game(names, 0, peer_seats)

## Dev tooling (Generate Mid-Game/Reset) pokes GameState directly, bypassing
## Actions entirely — safe only while nobody else's UI is mirroring this state.
func _dev_tools_visible() -> bool:
	return not _is_networked or (session.is_host and _lobby_peers.is_empty())

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", _theme.color_placed)
	return l


# ===========================================================================
#  Game lifecycle
# ===========================================================================

func _start_new_game() -> void:
	var names := []
	for i in NUM_PLAYERS:
		names.append("Player %d" % (i + 1))
	session.host_start_game(names)

## True if the local seat may act for whoever's turn it currently is (always
## true in hotseat_mode; otherwise only the matching seat).
func _is_my_turn() -> bool:
	return session.hotseat_mode or state.current_player == session.local_player_index

func _is_my_seat(player: int) -> bool:
	return session.hotseat_mode or player == session.local_player_index

## Whose hand/cash/stock this window's sidebar shows. In hotseat_mode that's
## whoever's turn it is (one local window cycling through every seat, by
## design); in real networked play it's always this window's own seat,
## regardless of whose turn it currently is — a player needs to see their own
## rack and cash even while waiting for someone else's move.
func _viewer_seat() -> int:
	return state.current_player if session.hotseat_mode else session.local_player_index

## rules.txt step 8: announce each player's drawn starting tile and who goes
## first (closest to 1A) — makes the new setup phase visible, not just silent
## bookkeeping.
func _starting_draw_summary() -> String:
	var parts: Array = []
	for i in state.players.size():
		var t: Vector2i = state.starting_draws[i]
		parts.append("%s drew %s" % [state.players[i].pname, AcqEnums.tile_label(t.x, t.y)])
	return "%s. %s goes first!" % [", ".join(parts), state.players[state.current_player].pname]

func _reset_turn_state() -> void:
	_pending_coord = Vector2i(-1, -1)
	_merge_mode = ""
	_disposal_queue = []
	_buy_counts = {}

## The single place GameState mutation is reacted to. Every Action this
## controller sends eventually round-trips back here (synchronously, in
## hotseat/loopback mode) via session.event_applied — see net/session.gd and
## net/event.gd for what each event type means and carries.
func _on_event_applied(event: Dictionary) -> void:
	var p: Dictionary = event.payload
	match event.type:
		Event.GAME_STARTED:
			state = session.state
			_reset_turn_state()
			_msg(_starting_draw_summary())
			_refresh_all()
		Event.TILE_PLACED:
			if p.kind == Kind.ISOLATED:
				_msg("Placed %s." % AcqEnums.tile_label(p.coord.x, p.coord.y))
			else:
				_msg("Placed %s — %s grows to %d." % [
					AcqEnums.tile_label(p.coord.x, p.coord.y), _theme.chain_name(p.chain),
					state.chain_size_of(p.chain)])
			_refresh_all()
		Event.CHAIN_FOUND_PENDING:
			_pending_coord = p.coord
			_refresh_all()
		Event.CHAIN_FOUNDED:
			_msg("Founded %s! You receive 1 founder's share." % _theme.chain_name(p.chain))
			_refresh_all()
		Event.MERGER_PENDING:
			_pending_coord = p.coord
			_merge_candidates = p.survivor_candidates
			_merge_mode = "tie" if _merge_candidates.size() > 1 else ""
			_refresh_all()
		Event.MERGER_STARTED:
			_merge_survivor = p.survivor
			_disposal_queue = p.disposal_queue.duplicate(true)
			_merge_mode = "dispose"
			var names: Array = []
			for d in p.defuncts:
				names.append(_theme.chain_name(d))
			_msg("%s survives. Defunct: %s. Majority/minority bonuses paid." % [
				_theme.chain_name(p.survivor), ", ".join(names)])
			_refresh_all()
		Event.STOCK_DISPOSED:
			if not _disposal_queue.is_empty():
				_disposal_queue.pop_front()
			_refresh_all()
		Event.MERGER_FINISHED:
			_merge_mode = ""
			_refresh_all()
		Event.STOCK_BOUGHT:
			_refresh_all()
		Event.TURN_ENDED:
			_buy_counts = {}
			_msg("%s's turn." % state.players[state.current_player].pname)
			_refresh_all()
		Event.TILE_REDRAWN:
			_msg("Redrew dead tile %s." % AcqEnums.tile_label(p.tile.x, p.tile.y))
			_refresh_all()
		Event.GAME_OVER:
			_final_scores = p.final_scores
			_refresh_all()
		Event.ACTION_REJECTED:
			_msg(p.reason)

func _refresh_all() -> void:
	if _dev_row:
		_dev_row.visible = _dev_tools_visible()
	if state == null:
		return   # joined a networked lobby; waiting for the host's GAME_STARTED
	_update_playable_hints()
	for cellnode in _cells.values():
		cellnode.refresh()
	_refresh_header()
	_refresh_rack()
	_refresh_stock()
	_refresh_chains_table()
	_rebuild_action_area()

## Mark the current player's legal placement squares so the board can shade them.
## Temporarily-unplayable squares (e.g. would-be 8th chain) and permanently-dead
## squares (would merge two safe chains) are intentionally NOT marked.
func _update_playable_hints() -> void:
	for cellnode in _cells.values():
		cellnode.playable = false
	if state.phase != Phase.PLACE_TILE or not _is_my_turn():
		return
	for tile in state.players[state.current_player].rack:
		var kind: int = state.classify_placement(tile.x, tile.y).kind
		if kind != Kind.ILLEGAL_DEAD and kind != Kind.ILLEGAL_TEMP:
			if _cells.has(tile):
				_cells[tile].playable = true

func _refresh_header() -> void:
	var p: GameState.PlayerState = state.players[_viewer_seat()]
	_header_lbl.text = "%s   —   $%d" % [p.pname, p.cash]
	_header_lbl.add_theme_color_override("font_color", _theme.color_label)
	_phase_lbl.text = _phase_instruction()

func _phase_instruction() -> String:
	match state.phase:
		Phase.PLACE_TILE:
			return "Drag one of your tiles (yellow squares) onto its matching spot on the board."
		Phase.FOUND_CHAIN:
			return "You founded a new chain — pick which company it becomes."
		Phase.RESOLVE_MERGER:
			if _merge_mode == "tie":
				return "Merger tie! The two largest chains are equal — choose which one survives."
			return "Merger! Each shareholder of the defunct chain decides what to do with their stock."
		Phase.BUY_STOCK:
			return "Optionally buy up to %d shares, then end your turn." % AcqEnums.MAX_BUY_PER_TURN
		Phase.GAME_OVER:
			return "Game over — final standings below."
	return ""

## Display order only — sorted left to right by column number, then by row
## letter for ties (e.g. 9A sits left of 9C). The underlying rack array order
## is untouched since nothing in the engine depends on it.
func _sorted_rack(rack: Array) -> Array:
	var sorted: Array = rack.duplicate()
	sorted.sort_custom(func(a: Vector2i, b: Vector2i):
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	return sorted

func _refresh_rack() -> void:
	_clear(_rack_box)
	var p: GameState.PlayerState = state.players[_viewer_seat()]
	for tile in _sorted_rack(p.rack):
		var is_dead := state.is_dead_tile(tile.x, tile.y)
		if is_dead:
			# Permanently-dead tile: red, with its own redraw button beneath it.
			# Only usable on the viewer's own turn — the engine only accepts a
			# redraw from state.current_player, and outside hotseat_mode the
			# rack shown here may belong to a seat whose turn it isn't.
			var col := VBoxContainer.new()
			col.add_theme_constant_override("separation", 2)
			var rt := RackTile.new()
			col.add_child(rt)
			rt.setup(tile, _theme, self, true)
			if _is_my_turn():
				var redraw := Button.new()
				redraw.text = "Redraw"
				redraw.add_theme_font_size_override("font_size", 11)
				redraw.pressed.connect(_redraw_tile.bind(tile))
				col.add_child(redraw)
			_rack_box.add_child(col)
		else:
			var rt := RackTile.new()
			_rack_box.add_child(rt)
			rt.setup(tile, _theme, self, false)

func _refresh_stock() -> void:
	_clear(_stock_box)
	var p: GameState.PlayerState = state.players[_viewer_seat()]
	var any := false
	for ch in AcqEnums.CHAIN_COUNT:
		if p.shares[ch] > 0:
			var card := StockCard.new()
			_stock_box.add_child(card)
			card.setup(ch, p.shares[ch], state.current_price(ch), _theme)
			any = true
	if not any:
		var l := Label.new()
		l.text = "(no shares yet)"
		l.add_theme_color_override("font_color", _theme.color_lone_tile)
		_stock_box.add_child(l)

func _refresh_chains_table() -> void:
	_clear(_chains_grid)
	var active := state.available_active_chains()
	if active.is_empty():
		var l := Label.new()
		l.text = "(none founded yet)"
		l.add_theme_color_override("font_color", _theme.color_lone_tile)
		_chains_grid.add_child(l)
		# pad the row so the single label sits in column 0
		for _i in 3:
			_chains_grid.add_child(Control.new())
		return

	# Header row.
	_chains_grid.add_child(_table_head("Company"))
	_chains_grid.add_child(_table_head("Size"))
	_chains_grid.add_child(_table_head("Price"))
	_chains_grid.add_child(_table_head("In Bank"))

	for ch in active:
		# Company name (+ SAFE tag).
		var name_lbl := Label.new()
		name_lbl.text = _theme.chain_name(ch) + ("  • SAFE" if state.is_safe(ch) else "")
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", _theme.chain_color(ch).lightened(0.25))
		_chains_grid.add_child(name_lbl)

		# Size as a small tile icon + "x N".
		var size_cell := HBoxContainer.new()
		size_cell.add_theme_constant_override("separation", 4)
		var icon := ColorRect.new()
		icon.color = _theme.chain_color(ch)
		icon.custom_minimum_size = Vector2(14, 14)
		size_cell.add_child(icon)
		var size_lbl := Label.new()
		size_lbl.text = "x %d" % state.chain_size_of(ch)
		size_lbl.add_theme_font_size_override("font_size", 12)
		size_lbl.add_theme_color_override("font_color", _theme.color_label)
		size_cell.add_child(size_lbl)
		_chains_grid.add_child(size_cell)

		# Price.
		var price_lbl := Label.new()
		price_lbl.text = "$%d" % state.current_price(ch)
		price_lbl.add_theme_font_size_override("font_size", 12)
		price_lbl.add_theme_color_override("font_color", _theme.color_label)
		_chains_grid.add_child(price_lbl)

		# Remaining bank stock, as a mini stock-card.
		_chains_grid.add_child(_mini_stock_indicator(ch, state.bank_shares[ch]))

func _table_head(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", _theme.color_lone_tile)
	return l

func _mini_stock_indicator(chain: int, count: int) -> PanelContainer:
	var card := PanelContainer.new()
	var col := _theme.chain_color(chain)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.55)
	sb.border_color = col
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(3)
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(46, 22)
	var l := Label.new()
	l.text = "x %d" % count
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", _theme.color_label)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(l)
	return card


# ===========================================================================
#  Drag-and-drop bridge (called by RackTile / BoardCell)
# ===========================================================================

func can_drag_tiles() -> bool:
	return state != null and state.phase == Phase.PLACE_TILE and _is_my_turn()

func begin_drag(coord: Vector2i) -> void:
	_drag_coord = coord
	if _cells.has(coord):
		_cells[coord].highlight = true
		_cells[coord].refresh()

func end_drag() -> void:
	if _drag_coord.x >= 0 and _cells.has(_drag_coord):
		_cells[_drag_coord].highlight = false
		_cells[_drag_coord].refresh()
	_drag_coord = Vector2i(-1, -1)

## A tile may only drop on the board cell matching its own coordinate, and only
## if that placement is currently legal.
func can_drop_tile(col: int, row: int, data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or data.get("type") != "tile":
		return false
	if state == null or state.phase != Phase.PLACE_TILE:
		return false
	if data.get("coord") != Vector2i(col, row):
		return false
	var kind: int = state.classify_placement(col, row).kind
	return kind != Kind.ILLEGAL_DEAD and kind != Kind.ILLEGAL_TEMP

func drop_tile(col: int, row: int, _data) -> void:
	end_drag()
	session.send_action(Action.make_place_tile(state.current_player, Vector2i(col, row)))


# ===========================================================================
#  Founding
# ===========================================================================

func _on_found_chosen(chain: int) -> void:
	session.send_action(Action.make_choose_found(state.current_player, _pending_coord, chain))


# ===========================================================================
#  Merger resolution
# ===========================================================================

func _on_survivor_chosen(chain: int) -> void:
	session.send_action(Action.make_choose_survivor(state.current_player, _pending_coord, chain))

func _on_dispose_confirm(defunct: int, player: int, sell: int, trade: int) -> void:
	session.send_action(Action.make_dispose_stock(player, defunct, sell, trade))


# ===========================================================================
#  Buying / ending the turn
# ===========================================================================

func _buy_total() -> int:
	var t := 0
	for ch in _buy_counts:
		t += _buy_counts[ch]
	return t

func _buy_cost() -> int:
	var c := 0
	for ch in _buy_counts:
		c += _buy_counts[ch] * state.current_price(ch)
	return c

func _set_buy(chain: int, count: int) -> void:
	_buy_counts[chain] = maxi(count, 0)
	_rebuild_action_area()

func _commit_buy(declare_end: bool) -> void:
	var order := {}
	for ch in _buy_counts:
		if _buy_counts[ch] > 0:
			order[ch] = _buy_counts[ch]
	session.send_action(Action.make_buy_stock(state.current_player, order, declare_end))


# ===========================================================================
#  Dead-tile redraw
# ===========================================================================

func _redraw_tile(tile: Vector2i) -> void:
	session.send_action(Action.make_redraw_tile(state.current_player, tile))


# ===========================================================================
#  Action area (rebuilt every refresh based on phase)
# ===========================================================================

func _rebuild_action_area() -> void:
	_clear(_action_box)

	# Disposal is gated per-shareholder, not per-current-player — a different
	# seat than state.current_player may need to act here.
	if state.phase == Phase.RESOLVE_MERGER and _merge_mode == "dispose":
		if _disposal_queue.is_empty():
			return
		var entry: Dictionary = _disposal_queue[0]
		if not _is_my_seat(entry.player):
			_build_waiting_label("Waiting for %s to resolve their stock..." % state.players[entry.player].pname)
			return
		_build_dispose_actions()
		return

	if state.phase != Phase.GAME_OVER and not _is_my_turn():
		_build_waiting_label("Waiting for %s's move..." % state.players[state.current_player].pname)
		return

	match state.phase:
		Phase.PLACE_TILE:
			_build_place_actions()
		Phase.FOUND_CHAIN:
			_build_found_actions()
		Phase.RESOLVE_MERGER:
			_build_tie_actions()
		Phase.BUY_STOCK:
			_build_buy_actions()
		Phase.GAME_OVER:
			_build_gameover_actions()

## Shown in the action area for any seat whose turn it currently isn't: their
## own identity (so a networked player always knows which seat they're
## looking at, even on a phase that isn't theirs) plus a note on who is
## active right now.
func _build_waiting_label(active_text: String) -> void:
	var mine := Label.new()
	mine.text = _my_seat_label()
	mine.add_theme_font_size_override("font_size", 22)
	mine.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(mine)

	var active := Label.new()
	active.text = active_text
	active.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	active.add_theme_color_override("font_color", _theme.color_lone_tile)
	_action_box.add_child(active)

## "Player N" for whichever seat the local viewer is sitting in. Only called
## when gating has already determined this isn't the local seat's turn, which
## can't happen in hotseat_mode (it bypasses the gate entirely), so
## local_player_index is always the real seat here.
func _my_seat_label() -> String:
	return "Player %d" % (session.local_player_index + 1)

func _build_place_actions() -> void:
	var l := Label.new()
	l.text = "Drag a yellow-highlighted tile onto the board to begin your turn."
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(l)

func _build_found_actions() -> void:
	var l := Label.new()
	l.text = "Choose a company to found:"
	l.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(l)
	for ch in state.available_chains():
		_action_box.add_child(_chain_button(ch, _on_found_chosen))

func _build_tie_actions() -> void:
	var l := Label.new()
	l.text = "Tie — choose the surviving chain:"
	l.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(l)
	for ch in _merge_candidates:
		var size := state.chain_size_of(ch)
		_action_box.add_child(_chain_button(ch, _on_survivor_chosen, "  (size %d)" % size))

func _build_dispose_actions() -> void:
	var entry: Dictionary = _disposal_queue[0]
	var defunct: int = entry.defunct
	var player: int = entry.player
	var held: int = state.players[player].shares[defunct]
	var price: int = state.current_price(defunct)
	var survivor := _merge_survivor

	var title := Label.new()
	title.text = "%s — your %s stock (defunct)" % [state.players[player].pname, _theme.chain_name(defunct)]
	title.add_theme_color_override("font_color", _theme.chain_color(defunct).lightened(0.3))
	title.add_theme_font_size_override("font_size", 16)
	_action_box.add_child(title)

	var detail := Label.new()
	detail.text = "You hold %d shares @ $%d. Trade 2-for-1 into %s (bank %d)." % [
		held, price, _theme.chain_name(survivor), state.bank_shares[survivor]]
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(detail)

	var sell := SpinBox.new()
	sell.min_value = 0
	sell.max_value = held
	sell.prefix = "Sell "
	_action_box.add_child(sell)

	var trade := SpinBox.new()
	trade.min_value = 0
	trade.step = 2                                   # 2-for-1 needs an even count
	trade.max_value = mini(held - (held % 2), state.bank_shares[survivor] * 2)
	trade.prefix = "Trade "
	_action_box.add_child(trade)

	var keep := Label.new()
	keep.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(keep)
	var update_keep := func(_v = 0):
		var k := held - int(sell.value) - int(trade.value)
		keep.text = "Keep: %d   (sells @ $%d = $%d)" % [maxi(k, 0), price, int(sell.value) * price]
	sell.value_changed.connect(update_keep)
	trade.value_changed.connect(update_keep)
	update_keep.call()

	var confirm := Button.new()
	confirm.text = "Confirm"
	confirm.pressed.connect(func(): _on_dispose_confirm(defunct, player, int(sell.value), int(trade.value)))
	_action_box.add_child(confirm)

func _build_buy_actions() -> void:
	var active := state.available_active_chains()
	var total := _buy_total()
	if active.is_empty():
		var l := Label.new()
		l.text = "No chains on the board to buy into."
		l.add_theme_color_override("font_color", _theme.color_label)
		_action_box.add_child(l)
	else:
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		_action_box.add_child(flow)
		for ch in active:
			flow.add_child(_build_buy_card(ch, total))

		var summary := Label.new()
		summary.text = "Selected %d / %d shares — cost $%d" % [total, AcqEnums.MAX_BUY_PER_TURN, _buy_cost()]
		summary.add_theme_color_override("font_color", _theme.color_placed)
		_action_box.add_child(summary)

	# End-turn button: only mentions buying when something is queued.
	var end := _bordered_button("Buy & End Turn" if total > 0 else "End Turn")
	end.pressed.connect(func(): _commit_buy(false))
	_action_box.add_child(end)

	if state.can_end_game():
		var ge := _bordered_button("Buy & Declare Game End" if total > 0 else "Declare Game End")
		ge.pressed.connect(func(): _commit_buy(true))
		_action_box.add_child(ge)

## A "buy option" styled like a stock card, with a minus/value/plus stepper.
func _build_buy_card(chain: int, total: int) -> PanelContainer:
	var count: int = _buy_counts.get(chain, 0)
	var price := state.current_price(chain)
	var cash := state.players[state.current_player].cash
	var can_inc := total < AcqEnums.MAX_BUY_PER_TURN \
		and count < state.bank_shares[chain] \
		and _buy_cost() + price <= cash
	var can_dec := count > 0

	var card := PanelContainer.new()
	var col := _theme.chain_color(chain)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.55)
	sb.border_color = col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(118, 0)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)

	var name_lbl := Label.new()
	name_lbl.text = _theme.chain_name(chain)
	name_lbl.add_theme_color_override("font_color", col.lightened(0.4))
	name_lbl.add_theme_font_size_override("font_size", 14)
	v.add_child(name_lbl)

	var price_lbl := Label.new()
	price_lbl.text = "$%d  (bank %d)" % [price, state.bank_shares[chain]]
	price_lbl.add_theme_color_override("font_color", _theme.color_label)
	price_lbl.add_theme_font_size_override("font_size", 11)
	v.add_child(price_lbl)

	var stepper := HBoxContainer.new()
	stepper.alignment = BoxContainer.ALIGNMENT_CENTER
	stepper.add_theme_constant_override("separation", 8)
	var minus := Button.new()
	minus.text = "−"
	minus.disabled = not can_dec
	minus.custom_minimum_size = Vector2(30, 28)
	minus.pressed.connect(_set_buy.bind(chain, count - 1))
	stepper.add_child(minus)
	var count_lbl := Label.new()
	count_lbl.text = str(count)
	count_lbl.add_theme_font_size_override("font_size", 18)
	count_lbl.add_theme_color_override("font_color", _theme.color_label)
	stepper.add_child(count_lbl)
	var plus := Button.new()
	plus.text = "+"
	plus.disabled = not can_inc
	plus.custom_minimum_size = Vector2(30, 28)
	plus.pressed.connect(_set_buy.bind(chain, count + 1))
	stepper.add_child(plus)
	v.add_child(stepper)

	return card

func _build_gameover_actions() -> void:
	for i in _final_scores.size():
		var row: Dictionary = _final_scores[i]
		var l := Label.new()
		var crown := "  WINNER" if i == 0 else ""
		l.text = "%d.  %s — $%d%s" % [i + 1, row.name, row.cash, crown]
		l.add_theme_font_size_override("font_size", 18 if i == 0 else 15)
		l.add_theme_color_override("font_color", _theme.color_placed if i == 0 else _theme.color_label)
		_action_box.add_child(l)
	var again := _bordered_button("New Game")
	again.pressed.connect(_start_new_game)
	_action_box.add_child(again)


# ===========================================================================
#  Test tooling: generate a representative mid-game position
# ===========================================================================

## Build a hand-authored mid-game so every UI case can be exercised at once:
## all seven chains on the board (two of them SAFE), distributed shares/cash,
## and a current-player rack containing a normal grow, a merge, a TIE merge,
## an isolated placement, a permanently-DEAD tile, and a TEMPORARILY-unplayable
## tile (would-be 8th chain).
func _generate_midgame() -> void:
	state = GameState.new()
	session.state = state   # dev harness pokes the session's mirror directly, bypassing Actions
	state.setup_blank(NUM_PLAYERS)
	_reset_turn_state()

	# Seven chains. TOWER (11) and AMERICAN (12) are SAFE; row 1 between them
	# holds the dead bridge cells.
	_paint_chain(Chain.TOWER, _hcells(0, 10, 0))
	_paint_chain(Chain.AMERICAN, _hcells(0, 11, 2))
	_paint_chain(Chain.LUXOR, _hcells(0, 3, 4))
	_paint_chain(Chain.WORLDWIDE, _hcells(5, 6, 4))
	_paint_chain(Chain.FESTIVAL, _hcells(8, 9, 4))
	_paint_chain(Chain.IMPERIAL, _hcells(0, 2, 6))
	_paint_chain(Chain.CONTINENTAL, _hcells(4, 5, 6))
	state.set_cell(7, 6, Chain.NONE)   # a lone tile (for the temp-unplayable demo)

	# Distribute shares and cash.
	for p in state.players:
		p.shares.fill(0)
	_give(0, Chain.TOWER, 4); _give(0, Chain.AMERICAN, 3); _give(0, Chain.LUXOR, 2); _give(0, Chain.WORLDWIDE, 1)
	_give(1, Chain.TOWER, 3); _give(1, Chain.AMERICAN, 5); _give(1, Chain.FESTIVAL, 2)
	_give(2, Chain.TOWER, 2); _give(2, Chain.LUXOR, 1); _give(2, Chain.IMPERIAL, 1); _give(2, Chain.CONTINENTAL, 2)
	state.bank_shares = PackedInt32Array([16, 22, 17, 24, 23, 24, 23])  # 25 minus the above
	state.players[0].cash = 4200
	state.players[1].cash = 5100
	state.players[2].cash = 3800

	# Current player's demonstration rack.
	var demo: Array[Vector2i] = [
		Vector2i(5, 1),   # DEAD: bridges safe TOWER + safe AMERICAN
		Vector2i(8, 6),   # TEMP: would found an 8th chain (all 7 already exist)
		Vector2i(11, 0),  # grows TOWER
		Vector2i(7, 4),   # TIE merge: WORLDWIDE (2) + FESTIVAL (2)
		Vector2i(4, 4),   # merge: LUXOR (4) + WORLDWIDE (2)
		Vector2i(11, 8),  # isolated placement
	]
	state.players[0].rack.clear()
	for t in demo:
		state.players[0].rack.append(t)

	# Deal the other players from the remaining empty cells.
	var taken := {}
	for r in AcqEnums.BOARD_HEIGHT:
		for c in AcqEnums.BOARD_WIDTH:
			if state.cell(c, r) != AcqEnums.CELL_EMPTY:
				taken[Vector2i(c, r)] = true
	for t in demo:
		taken[t] = true
	var bag: Array[Vector2i] = []
	for r in AcqEnums.BOARD_HEIGHT:
		for c in AcqEnums.BOARD_WIDTH:
			var v := Vector2i(c, r)
			if not taken.has(v):
				bag.append(v)
	bag.shuffle()
	state.bag = bag
	for i in range(1, NUM_PLAYERS):
		state.players[i].rack.clear()
		for _j in AcqEnums.RACK_SIZE:
			state.draw_tile(i)

	state.current_player = 0
	state.phase = Phase.PLACE_TILE
	_msg("Generated mid-game test state. Rack: grow/merge/tie + 1 dead + 1 temporarily-blocked tile.")
	_refresh_all()

func _paint_chain(chain: int, cells: Array) -> void:
	for c in cells:
		state.set_cell(c.x, c.y, chain)
	state.chain_size[chain] = cells.size()

func _give(player: int, chain: int, n: int) -> void:
	state.players[player].shares[chain] = n

## Horizontal run of cells from (x0,row) to (x1,row) inclusive.
func _hcells(x0: int, x1: int, row: int) -> Array:
	var out: Array = []
	for x in range(x0, x1 + 1):
		out.append(Vector2i(x, row))
	return out


# ===========================================================================
#  Small UI helpers
# ===========================================================================

## A button tinted with a chain's colour that calls `callback(chain_id)`.
func _chain_button(chain: int, callback: Callable, suffix := "") -> Button:
	var b := Button.new()
	b.text = _theme.chain_name(chain) + suffix
	var col := _theme.chain_color(chain)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.35)
	sb.border_color = col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(5)
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	b.add_theme_stylebox_override("normal", sb)
	var sb_hover := sb.duplicate()
	sb_hover.bg_color = col.darkened(0.2)
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_color_override("font_color", _theme.color_label)
	b.pressed.connect(callback.bind(chain))
	return b

## A neutral button with a clear, visible border.
func _bordered_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	var sb := StyleBoxFlat.new()
	sb.bg_color = _theme.color_empty
	sb.border_color = _theme.color_label
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	b.add_theme_stylebox_override("normal", sb)
	var sb_hover := sb.duplicate()
	sb_hover.bg_color = _theme.color_hover
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_color_override("font_color", _theme.color_label)
	return b

func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()

func _msg(text: String) -> void:
	if _msg_lbl:
		_msg_lbl.text = text
