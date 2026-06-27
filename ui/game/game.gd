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

# Theme toggle (bottom-of-screen footer button): purely cosmetic, swaps which
# ThemeDef resource is loaded and rebuilds the UI from it. Never touches
# GameState, so it's safe to use mid-game and even while networked.
const THEME_PATHS := {
	"default": "res://theme/default_theme.tres",
	"fantasy": "res://theme/fantasy_theme.tres",
}
const THEME_DISPLAY_NAMES := {
	"default": "Classic",
	"fantasy": "Fantasy",
}
var _theme_key := "default"
var _theme_toggle_btn: Button

# UI nodes built in _build_layout().
var _ui_root: Control          # wraps everything _build_layout() creates, so a
								# theme-toggle rebuild can free just this and
								# leave any networking Node (EnetTransport)
								# added directly under `self` untouched.
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
var _drag_tile_node: RackTile = null     # the rack tile currently lifted out of the hand
var _drag_origin_pos := Vector2.ZERO     # its hand slot's global position, for the slide-back
var _drag_drop_succeeded := false        # set by drop_tile() right before its own end_drag() call
var _pending_coord := Vector2i(-1, -1)   # the tile being resolved (found/merge)
var _merge_mode := ""                     # "" | "tie" | "dispose"
var _merge_candidates: Array = []         # tied survivor choices
var _merge_survivor: int = Chain.NONE
var _disposal_queue: Array = []           # [{ "defunct", "player" }]
## Snapshot of each absorbed cell's pre-merge displayed color, taken right
## before MERGER_STARTED's own _refresh_all() repaints them -- the dispose
## phase's STOCK_DISPOSED events each call _refresh_all() too (to keep the
## board accurate while shareholders resolve), which would otherwise have
## already overwritten every cell with the survivor's color long before
## MERGER_FINISHED's animation gets a chance to read a "before" value. See
## _animate_merger_finished().
var _merge_pre_colors: Dictionary = {}    # Vector2i -> Color
var _buy_counts := {}                     # chain -> shares queued this buy phase
var _final_scores: Array = []

# Animation layer (Stage 2). Events are queued and drained one at a time so
# a burst of events from one action (e.g. a merger's PENDING/STARTED/
# dispose/FINISHED sequence, all emitted synchronously in net/session.gd's
# _process_action loop) never animates out of order or overlaps — see
# _drain_event_queue()'s header comment.
var _pending_events: Array = []
var _draining_events := false
var _animating := false             # true while an event's animation plays; blocks input
var _animations_enabled := true     # headless scripts set this false for fast, sync tests
var _fx_layer: Control              # transient animated visuals render here, above everything

# Networking lobby (Stage B). _is_networked is false until Host/Join is
# clicked; the dev-tooling row (Generate Mid-Game/Reset) is only visible while
# it's false or no remote peer has joined yet, since either button mutates
# state without going through an Action and would desync any connected peer.
var _is_networked := false
var _lobby_peers: Array[int] = []         # remote peer ids, host-side, join order
var _dev_row: HBoxContainer
var _net_status_lbl: Label
var _start_net_btn: Button

# Carried from ui/menu/menu.gd via the NetConfig autoload (see _ready()).
# Used as this seat's display name instead of the "Player N" default.
var _my_player_name := ""


func _ready() -> void:
	_theme = load(THEME_PATHS[_theme_key])
	_sync_music_for_theme()
	_build_layout()
	if NetConfig.has_pending:
		_my_player_name = NetConfig.player_name
		var mode: String = NetConfig.mode
		var host_port: int = NetConfig.host_port
		var join_addr: String = NetConfig.join_address
		var join_port: int = NetConfig.join_port
		NetConfig.clear()
		match mode:
			"host":
				_host_networked_game(host_port)
			"join":
				_join_networked_game(join_addr, join_port)
			_:
				_init_default_session()
				_start_new_game()
	else:
		# Headless test scripts (sim/check_midgame.gd, sim/check_near_endgame.gd)
		# instance Game.tscn directly without going through the menu, so
		# NetConfig.has_pending is false here and this is their path too.
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
	# Rebuilding (theme toggle): tear down the previous UI tree in one shot.
	# free() (not queue_free()) so the old tree is gone before we add the new
	# one this same frame — otherwise both would briefly coexist and overlap.
	if _ui_root:
		_ui_root.free()
		_cells.clear()
	_ui_root = Control.new()
	_ui_root.name = "UiRoot"
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_ui_root)

	var bg := ColorRect.new()
	bg.color = _theme.color_background
	_ui_root.add_child(bg)
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
	_ui_root.add_child(main_vbox)
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

	side.add_child(_section_label("Your %s" % _theme.term_stock))
	_stock_box = HFlowContainer.new()
	side.add_child(_stock_box)

	side.add_child(_section_label("Actions"))
	_action_box = VBoxContainer.new()
	_action_box.add_theme_constant_override("separation", 6)
	side.add_child(_action_box)

	# --- Footer (pinned, always visible — never inside a scroll container) ---
	main_vbox.add_child(_build_test_footer())

	# --- FX overlay (Stage 2): transient animated visuals (tile/stock slides,
	# merge flashes) render here, above everything else since it's the last
	# child of _ui_root. Lives outside both ScrollContainers so a tween on its
	# children's global_position isn't distorted by scrolling.
	_fx_layer = Control.new()
	_fx_layer.name = "FxLayer"
	_fx_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.add_child(_fx_layer)

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
	head.text = "STOCK PRICE CHART  (%s per %s)" % [_theme.currency_symbol, _theme.term_stock.to_lower()]
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
			pl.text = "%s%d" % [_theme.currency_symbol, StockMarket.price(rep, int(row[1]))]
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
	var gen2 := _bordered_button("Generate Near-Endgame")
	gen2.pressed.connect(_generate_near_endgame)
	_dev_row.add_child(gen2)
	var reset := _bordered_button("Reset (Empty)")
	reset.pressed.connect(_start_new_game)
	_dev_row.add_child(reset)
	footer.add_child(_dev_row)

	footer.add_child(_build_theme_row())
	footer.add_child(_build_network_status_row())
	return footer

## Cosmetic-only theme switcher. Always visible (unlike the dev-tools row,
## which hides once a remote peer has joined) since swapping ThemeDef never
## touches GameState — every connected peer can flip their own local skin
## independently without desyncing anyone.
func _build_theme_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = "Theme: %s" % THEME_DISPLAY_NAMES[_theme_key]
	lbl.add_theme_color_override("font_color", _theme.color_lone_tile)
	row.add_child(lbl)

	_theme_toggle_btn = _bordered_button(_theme_toggle_label())
	_theme_toggle_btn.pressed.connect(_on_theme_toggle_pressed)
	row.add_child(_theme_toggle_btn)
	_sync_theme_toggle_enabled()
	return row

func _theme_toggle_label() -> String:
	var other_key := "default" if _theme_key == "fantasy" else "fantasy"
	return "Switch to %s Theme" % THEME_DISPLAY_NAMES[other_key]

## Disabled once networked: a rebuild would reset the network-status row's
## live text (e.g. "Hosting on port X — N joined") back to its just-built
## default, since that text is set ad hoc by the hosting/joining/lobby
## handlers rather than recomputed from a single source of truth each
## refresh. Re-synced from _refresh_all() so the button disables itself the
## moment _is_networked flips true, without needing a rebuild of its own.
func _sync_theme_toggle_enabled() -> void:
	if not _theme_toggle_btn:
		return
	_theme_toggle_btn.disabled = _is_networked
	_theme_toggle_btn.tooltip_text = "Disabled while playing a networked game." if _is_networked else ""

## Swaps the active ThemeDef and rebuilds the UI from it. Ignored mid-
## animation, since _build_layout() would free _fx_layer nodes a running
## tween still holds references to. Safe to call with state == null (e.g. a
## solo lobby before any game has started) — the rebuilt UI just stays in
## its empty/frozen state; _refresh_all() only runs once there's a real
## GameState to read from.
##
## The actual rebuild is deferred (_rebuild_themed_ui, via call_deferred)
## rather than run inline here: this function runs INSIDE the toggle
## button's own "pressed" signal emission, and _build_layout() frees the
## entire _ui_root tree the button itself lives under — freeing a node
## while it's still mid-emission of its own signal crashes the engine
## (Godot's own error for this points at exactly this fix: defer it so the
## free happens only after the signal has finished propagating).
func _on_theme_toggle_pressed() -> void:
	if _animating or _is_networked:
		return
	_theme_key = "default" if _theme_key == "fantasy" else "fantasy"
	_theme = load(THEME_PATHS[_theme_key])
	_sync_music_for_theme()
	call_deferred("_rebuild_themed_ui")

## The Closing Bell only fits the default theme's tone -- silence it in
## Fantasy mode and resume it on switching back. Called both on first
## _ready() (in case the scene starts in default theme) and from the
## toggle handler above.
func _sync_music_for_theme() -> void:
	if _theme_key == "fantasy":
		SfxManager.stop_music()
	else:
		SfxManager.play_music()

func _rebuild_themed_ui() -> void:
	_build_layout()
	if state:
		_refresh_all()

## Host-only "Start Networked Game" button + a live status label. Address/
## port entry now happens in ui/menu/menu.gd, before this scene is even
## loaded — _ready() reads that choice from NetConfig and calls
## _host_networked_game()/_join_networked_game() automatically, so this row
## only needs to show what's happening, not collect input.
func _build_network_status_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_start_net_btn = _bordered_button("Start Networked Game")
	_start_net_btn.disabled = true
	_start_net_btn.visible = false
	_start_net_btn.pressed.connect(_on_start_networked_game_pressed)
	row.add_child(_start_net_btn)

	_net_status_lbl = Label.new()
	_net_status_lbl.text = "Not networked — playing solo/hotseat."
	_net_status_lbl.add_theme_color_override("font_color", _theme.color_lone_tile)
	row.add_child(_net_status_lbl)
	return row

## Host an ENet server on `port` and wait in the lobby for joiners; the host
## clicks "Start Networked Game" once everyone expected has connected.
func _host_networked_game(port: int) -> void:
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
	_start_net_btn.visible = true
	_net_status_lbl.text = "Hosting on port %d — 0 player(s) joined." % port
	_refresh_all()

## Connect to a host at addr:port and wait for its GAME_STARTED broadcast.
func _join_networked_game(addr: String, port: int) -> void:
	var transport := EnetTransport.new()
	transport.name = "EnetTransport"   # must match the host's NodePath exactly — see _host_networked_game
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
	var names := [_my_player_name if not _my_player_name.is_empty() else "Host"]
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
	if not _my_player_name.is_empty():
		names[0] = _my_player_name
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
##
## Events are queued rather than handled inline: GameSession can emit several
## events back-to-back for one action (e.g. a merger's PENDING/STARTED/
## dispose/FINISHED sequence, all emitted synchronously in net/session.gd's
## _process_action loop). If this handler awaited an animation directly, a
## second event's emit() would re-enter it before the first one's await
## resumed — Godot's emit() does not block on an awaiting signal handler — so
## animations could overlap or run out of order. Queueing and draining one at
## a time guarantees they never do, even when several events land in one frame.
func _on_event_applied(event: Dictionary) -> void:
	_pending_events.append(event)
	if not _draining_events:
		_drain_event_queue()

func _drain_event_queue() -> void:
	_draining_events = true
	while not _pending_events.is_empty():
		var event: Dictionary = _pending_events.pop_front()
		await _apply_one_event(event)
	_draining_events = false

## Plays that event's animation (if any), with input locked for its duration,
## then applies the same UI reaction the pre-animation code always has.
func _apply_one_event(event: Dictionary) -> void:
	_animating = true
	_lock_action_box()
	if _animations_enabled:
		await _play_event_animation(event)
	_animating = false
	_apply_event_ui(event)

## Per-event UI reaction: status messages + the state-derived UI rebuild.
## Unchanged in substance from before the animation layer landed — this is
## exactly the old _on_event_applied() body, just renamed and moved behind
## the (optional) animation step above.
func _apply_event_ui(event: Dictionary) -> void:
	var p: Dictionary = event.payload
	match event.type:
		Event.GAME_STARTED:
			state = session.state
			_reset_turn_state()
			_msg(_starting_draw_summary())
			_refresh_all()
		Event.TILE_PLACED:
			SfxManager.play_tile()
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
			SfxManager.play_chain_founded()
			_msg("Founded %s! You receive 1 founder's %s." % [_theme.chain_name(p.chain), _theme.term_stock.to_lower()])
			_refresh_all()
		Event.MERGER_PENDING:
			_pending_coord = p.coord
			_merge_candidates = p.survivor_candidates
			_merge_mode = "tie" if _merge_candidates.size() > 1 else ""
			_refresh_all()
		Event.MERGER_STARTED:
			SfxManager.play_merger()
			_merge_survivor = p.survivor
			_disposal_queue = p.disposal_queue.duplicate(true)
			_merge_mode = "dispose"
			# state.merger_begin() (already run server-side, before this event
			# was even emitted) only pays bonuses and records who owes a
			# disposal decision -- it does NOT reassign any cells yet. Real
			# cell ownership only flips inside state.merger_finish(), which
			# net/session.gd's _apply_dispose_stock() runs once every
			# shareholder has resolved, right before broadcasting
			# MERGER_FINISHED. So right now, every defunct chain's cells still
			# show their own original color -- the last moment that's true --
			# which is exactly what _animate_merger_finished() needs as its
			# "before" picture once the takeover is actually final.
			_snapshot_merge_pre_colors(p.survivor, p.defuncts)
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
			# _apply_one_event() unconditionally calls _lock_action_box()
			# before dispatching here, on the assumption every event leads to
			# a _refresh_all() that rebuilds the action box with fresh,
			# enabled controls. A rejection is the one event type where
			# nothing about state actually changed, so without this
			# _refresh_all() call the buttons _lock_action_box() just
			# disabled (e.g. "End Turn") would stay disabled forever —
			# looking to the player like the option vanished.
			_msg(p.reason)
			_refresh_all()

# ===========================================================================
#  Animation layer (Stage 2)
# ===========================================================================

## Disables every Button still showing in the action box while an animation
## plays. The action box itself isn't rebuilt until _apply_event_ui()'s
## _refresh_all() runs (after the animation finishes), so without this its
## stale, pre-event buttons would stay clickable and could send an action for
## a phase/turn that's already moved on.
func _lock_action_box() -> void:
	if _action_box:
		for child in _action_box.get_children():
			_disable_buttons_recursive(child)

func _disable_buttons_recursive(node: Node) -> void:
	if node is Button:
		(node as Button).disabled = true
	for child in node.get_children():
		_disable_buttons_recursive(child)

## Dispatches to a per-event-type animation. Events with no animation yet
## just resolve immediately (no-op), which is also the bootstrap state this
## whole layer shipped in before any concrete animation was added.
func _play_event_animation(event: Dictionary) -> void:
	match event.type:
		Event.TILE_PLACED:
			await _animate_tile_placed(event)
		Event.STOCK_BOUGHT:
			await _animate_stock_bought(event)
		Event.MERGER_FINISHED:
			await _animate_merger_finished(event)
		Event.CHAIN_FOUNDED:
			await _animate_chain_founded(event)
		_:
			pass

## On a successful placement, the tile snaps into place instantly (no slide)
## because it was already hidden from the hand during the drag gesture. On a
## failed drop, no event fires, so this never runs. The hand's reflow animation
## when the tile reappears is sufficient visual feedback for that part.
##
## When the placement grows an existing chain (Kind.GROW), the single newly-
## placed cell also gets the color-fade below, since it's the one cell whose
## color is actually changing -- the rest of the chain already shows the
## right color and doesn't need to animate.
func _animate_tile_placed(event: Dictionary) -> void:
	var coord: Vector2i = event.payload.coord
	var dst: BoardCell = _cells.get(coord)
	var src := _find_rack_tile_node(coord)
	# If the source tile is not visible, it was lifted in a successful drag.
	# Skip the slide animation — the tile is already gone from the hand and will
	# appear on the board after the next refresh — but still run the color fade
	# below if applicable.
	if src != null and dst != null and src.visible:
		await _slide_visual(AcqEnums.tile_label(coord.x, coord.y), src.global_position, dst.global_position, src.size)
	if dst != null and event.payload.kind == Kind.GROW:
		await _animate_chain_color_fade([dst], event.payload.chain)

## Slides a duplicate-styled card from the buy-stepper card the player just
## used into the stock sidebar. The new StockCard doesn't exist yet (that's
## built by _refresh_all() after this animation finishes), so the whole
## stock box is used as the landing target rather than one specific card.
func _animate_stock_bought(event: Dictionary) -> void:
	var order: Dictionary = event.payload.order
	if order.is_empty():
		return
	var chain: int = order.keys()[0]
	var src := _find_buy_card_node(chain)
	if src == null:
		return
	await _slide_visual(_theme.chain_name(chain), src.global_position, _stock_box.global_position, src.size)

## Color-fade over every cell the just-finished merger's survivor chain now
## occupies (queried off _merge_survivor, which _apply_event_ui's earlier
## MERGER_STARTED handling already populated and won't clear until after
## this animation runs). Deliberately tied to MERGER_FINISHED rather than
## MERGER_STARTED: the takeover isn't real to the player until every
## shareholder has actually resolved their defunct stock (sell/trade/keep),
## so animating any earlier showed the board "absorbing" the defunct chain
## before that resolution even began.
##
## Uses _merge_pre_colors (snapshotted at MERGER_STARTED, before its own
## _refresh_all() ran) as each cell's starting color instead of whatever the
## cell is showing right now -- by MERGER_FINISHED, one or more STOCK_DISPOSED
## events have already called _refresh_all() themselves (to keep the board
## accurate while shareholders resolve their disposal), which already
## repainted every absorbed cell to the survivor's color. Reading "current"
## color at this point would just be fading the target color into itself.
func _animate_merger_finished(event: Dictionary) -> void:
	if _merge_survivor == Chain.NONE:
		return
	await _animate_chain_color_fade(_chain_cellnodes(_merge_survivor), _merge_survivor, _merge_pre_colors)
	_merge_pre_colors = {}

## Same color-fade, played over the newly-founded chain's cells (queried
## post-mutation, same as the merger-finished animation above). No pre-color
## snapshot needed here -- chain founding has no intervening events/refreshes
## between the mutation and this animation, so each cell's live displayed
## color (read inside _animated_stylebox()) is still the real "before".
func _animate_chain_founded(event: Dictionary) -> void:
	var chain: int = event.payload.chain
	await _animate_chain_color_fade(_chain_cellnodes(chain), chain)

func _chain_cellnodes(chain: int) -> Array:
	var cellnodes: Array = []
	for coord in _cells.keys():
		if state.cell(coord.x, coord.y) == chain:
			cellnodes.append(_cells[coord])
	return cellnodes

## Captures every cell that will end up belonging to `survivor` once the
## merger actually finishes -- its own existing cells plus every `defuncts`
## chain's cells -- along with whatever color each is showing right now
## (still each chain's own real color; state.merger_finish() hasn't reassigned
## any of them yet at this point, see the MERGER_STARTED case above). Read by
## _animate_merger_finished() once the merger is actually fully resolved.
func _snapshot_merge_pre_colors(survivor: int, defuncts: Array) -> void:
	_merge_pre_colors = {}
	for chain in [survivor] + defuncts:
		for cellnode in _chain_cellnodes(chain):
			var sb := cellnode.get_theme_stylebox("normal") as StyleBoxFlat
			_merge_pre_colors[Vector2i(cellnode.col, cellnode.row)] = sb.bg_color if sb else _theme.color_empty

const COLOR_FADE_DURATION := 0.4

## Fades every cell in `cellnodes`'s displayed background to `chain`'s color,
## all in parallel -- no flash, no stagger, just the color change itself,
## made visible instead of an instant cut. Each cell's starting color is
## `from_colors[coord]` if given (see _snapshot_merge_pre_colors() above),
## otherwise whatever the cell is currently showing.
func _animate_chain_color_fade(cellnodes: Array, chain: int, from_colors: Dictionary = {}) -> void:
	if cellnodes.is_empty():
		return
	var target_color := _theme.chain_color(chain)
	var tween := create_tween()
	tween.set_parallel(true)
	for cellnode in cellnodes:
		var coord := Vector2i(cellnode.col, cellnode.row)
		var sb := _animated_stylebox(cellnode, from_colors.get(coord))
		tween.tween_property(sb, "bg_color", target_color, COLOR_FADE_DURATION) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished

## Installs one fresh, tweenable StyleBoxFlat as the cell's normal/hover/
## pressed override (board input is locked for the whole animation, so the
## three states never need to look different mid-animation) and returns it.
## Starting bg_color is `from_color_override` if given, otherwise whatever
## the cell's current "normal" override already shows (still the pre-
## mutation color when there's been no intervening refresh -- see the
## per-event-type comments above for which case applies when).
func _animated_stylebox(cellnode: BoardCell, from_color_override: Variant = null) -> StyleBoxFlat:
	var existing := cellnode.get_theme_stylebox("normal") as StyleBoxFlat
	var sb := StyleBoxFlat.new()
	if from_color_override != null:
		sb.bg_color = from_color_override
	else:
		sb.bg_color = existing.bg_color if existing else _theme.color_empty
	sb.border_color = existing.border_color if existing else _theme.color_label
	sb.set_border_width_all(existing.get_border_width(SIDE_LEFT) if existing else 1)
	sb.set_corner_radius_all(4)
	cellnode.add_theme_stylebox_override("normal", sb)
	cellnode.add_theme_stylebox_override("hover", sb)
	cellnode.add_theme_stylebox_override("pressed", sb)
	return sb

## Spawns a transient label-on-panel on the FX layer and tweens it from
## from_pos to to_pos (both global positions), freeing it when done.
func _slide_visual(label_text: String, from_pos: Vector2, to_pos: Vector2, sz: Vector2, duration := 0.28) -> void:
	var panel := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _theme.color_placed
	sb.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", sb)
	panel.size = sz
	panel.global_position = from_pos
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size = sz
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.BLACK)
	panel.add_child(lbl)
	_fx_layer.add_child(panel)
	var tween := create_tween()
	tween.tween_property(panel, "global_position", to_pos, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tween.finished
	panel.queue_free()

## Finds the RackTile currently shown for `coord`, whether it's a live tile or
## a dead one (wrapped in its own VBoxContainer alongside a Redraw button —
## see _refresh_rack()).
func _find_rack_tile_node(coord: Vector2i) -> RackTile:
	for child in _rack_box.get_children():
		if child is RackTile and (child as RackTile).coord == coord:
			return child
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is RackTile and (sub as RackTile).coord == coord:
					return sub
	return null

## Finds the buy-stepper card for `chain` (see _build_buy_card()'s set_meta
## tag), if the buy phase's action box is currently showing one.
func _find_buy_card_node(chain: int) -> Control:
	if not _action_box:
		return null
	for child in _action_box.get_children():
		if child is HFlowContainer:
			for card in child.get_children():
				if card.has_meta("chain") and card.get_meta("chain") == chain:
					return card
	return null

func _refresh_all() -> void:
	if _dev_row:
		_dev_row.visible = _dev_tools_visible()
	_sync_theme_toggle_enabled()
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
	_header_lbl.text = "%s   —   %s%d" % [p.pname, _theme.currency_symbol, p.cash]
	_header_lbl.add_theme_color_override("font_color", _theme.color_label)
	_phase_lbl.text = _phase_instruction()

func _phase_instruction() -> String:
	match state.phase:
		Phase.PLACE_TILE:
			return "Drag one of your tiles (yellow squares) onto its matching spot on the board."
		Phase.FOUND_CHAIN:
			return "You founded a new chain — pick which %s it becomes." % _theme.term_corporation.to_lower()
		Phase.RESOLVE_MERGER:
			if _merge_mode == "tie":
				return "%s tie! The two largest chains are equal — choose which one survives." % _theme.term_merger
			return "%s! Each %s of the defunct chain decides what to do with their %s." % [_theme.term_merger, _theme.term_stockholder.to_lower(), _theme.term_stock.to_lower()]
		Phase.BUY_STOCK:
			return "Optionally buy up to %d %s, then end your turn." % [AcqEnums.MAX_BUY_PER_TURN, _theme.term_stock.to_lower()]
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
			# Only usable on the viewer's own turn during PLACE_TILE — the
			# engine only accepts a redraw from state.current_player while
			# phase == PLACE_TILE (net/session.gd's _apply_redraw_tile), and
			# outside hotseat_mode the rack shown here may belong to a seat
			# whose turn it isn't. Gating on phase here too (not just
			# _is_my_turn()) avoids ever sending a redraw the engine will
			# reject just because the player already moved on to BUY_STOCK
			# with a stale dead tile still sitting in their rack.
			var col := VBoxContainer.new()
			col.add_theme_constant_override("separation", 2)
			var rt := RackTile.new()
			col.add_child(rt)
			rt.setup(tile, _theme, self, true)
			if _is_my_turn() and state.phase == Phase.PLACE_TILE:
				var redraw := Button.new()
				redraw.text = "Redraw"
				redraw.add_theme_font_size_override("font_size", 11)
				redraw.pressed.connect(SfxManager.play_button)
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
		l.text = "(no %s yet)" % _theme.term_stock.to_lower()
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
		price_lbl.text = "%s%d" % [_theme.currency_symbol, state.current_price(ch)]
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
	return state != null and state.phase == Phase.PLACE_TILE and _is_my_turn() and not _animating

func begin_drag(coord: Vector2i) -> void:
	_drag_coord = coord
	if _cells.has(coord):
		_cells[coord].highlight = true
		_cells[coord].refresh()
	_lift_rack_tile(coord)

## Called whenever a drag ends (success or not) — from drop_tile() right
## before it sends the action, and unconditionally from _notification()'s
## NOTIFICATION_DRAG_END (which fires for every drag regardless of outcome).
## drop_tile() marks _drag_drop_succeeded first so this can tell the two
## cases apart without depending on Viewport drag-state timing.
func end_drag() -> void:
	if _drag_coord.x >= 0 and _cells.has(_drag_coord):
		_cells[_drag_coord].highlight = false
		_cells[_drag_coord].refresh()
	_drag_coord = Vector2i(-1, -1)
	if not _drag_drop_succeeded and _drag_tile_node != null and is_instance_valid(_drag_tile_node):
		_return_lifted_tile(_drag_tile_node)
	_drag_tile_node = null
	_drag_drop_succeeded = false

## A tile may only drop on the board cell matching its own coordinate, and only
## if that placement is currently legal.
func can_drop_tile(col: int, row: int, data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or data.get("type") != "tile":
		return false
	if state == null or state.phase != Phase.PLACE_TILE or _animating:
		return false
	if data.get("coord") != Vector2i(col, row):
		return false
	var kind: int = state.classify_placement(col, row).kind
	return kind != Kind.ILLEGAL_DEAD and kind != Kind.ILLEGAL_TEMP

func drop_tile(col: int, row: int, _data) -> void:
	_drag_drop_succeeded = true
	end_drag()
	session.send_action(Action.make_place_tile(state.current_player, Vector2i(col, row)))

# --- "picked up by the mouse" hand affordance -------------------------------
# Pure presentation, independent of _animations_enabled (which only gates
# event-driven animations once an action's outcome is known): this is about
# how the hand reacts to the drag gesture itself, success or not.

## Hides the dragged tile (so the HFlowContainer reflows and the rest of the
## hand visibly slides over to close the gap) and remembers its slot's
## position for _return_lifted_tile() to slide back to on a failed drop.
func _lift_rack_tile(coord: Vector2i) -> void:
	var rt := _find_rack_tile_node(coord)
	if rt == null:
		return
	_drag_tile_node = rt
	_drag_origin_pos = rt.global_position
	var before := _rack_top_positions()
	rt.visible = false
	await get_tree().process_frame
	_tween_rack_to(before)

## Slides a ghost tile from wherever the mouse released it back to the hand
## slot it came from, then restores the real RackTile (sliding the rest of
## the hand back open to make room for it).
func _return_lifted_tile(rt: RackTile) -> void:
	var release_pos := get_viewport().get_mouse_position()
	await _slide_visual(rt.text, release_pos, _drag_origin_pos, rt.size)
	if not is_instance_valid(rt):
		return
	var before := _rack_top_positions()
	rt.visible = true
	await get_tree().process_frame
	_tween_rack_to(before)

## Tweens the *direct* children of _rack_box (a bare RackTile for a live tile,
## or its whole VBoxContainer for a dead tile + Redraw button) rather than
## digging into the RackTile alone — a dead tile's Redraw button has to slide
## along with it as one unit, or the wrapper's internal layout would visibly
## tear during the tween.
func _rack_top_positions() -> Dictionary:
	var out := {}
	for node in _rack_box.get_children():
		out[node] = node.global_position
	return out

## FLIP-style reflow animation: each visible rack slot is snapped back to its
## `before` position then tweened to wherever the container has now actually
## placed it, so a tile being lifted out (or returned) reads as the rest of
## the hand sliding over rather than an instant jump.
func _tween_rack_to(before: Dictionary) -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	for node in _rack_box.get_children():
		if not node.visible or not before.has(node):
			continue
		var old: Vector2 = before[node]
		var target: Vector2 = node.global_position
		if old.is_equal_approx(target):
			continue
		node.global_position = old
		tween.tween_property(node, "global_position", target, 0.16) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


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
	l.text = "Choose a %s to found:" % _theme.term_corporation.to_lower()
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

	# Reuse StockCard purely as an illustrative chain icon (count fixed to
	# 2/1, not the player's real holding) to diagram the 2-for-1 trade:
	# defunct stock on the left, an arrow, the surviving stock on the right.
	var diagram := HBoxContainer.new()
	diagram.alignment = BoxContainer.ALIGNMENT_CENTER
	diagram.add_theme_constant_override("separation", 10)
	_action_box.add_child(diagram)
	var from_card := StockCard.new()
	diagram.add_child(from_card)
	from_card.setup(defunct, 2, price, _theme)
	var arrow := Label.new()
	arrow.text = "→"
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.add_theme_font_size_override("font_size", 28)
	arrow.add_theme_color_override("font_color", _theme.color_label)
	diagram.add_child(arrow)
	var to_card := StockCard.new()
	diagram.add_child(to_card)
	to_card.setup(survivor, 1, state.current_price(survivor), _theme)

	var detail := Label.new()
	detail.text = "You hold %d %s @ %s%d. Bank has %d %s left." % [
		held, _theme.term_stock.to_lower(), _theme.currency_symbol, price,
		state.bank_shares[survivor], _theme.chain_name(survivor)]
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_color_override("font_color", _theme.color_label)
	_action_box.add_child(detail)

	# Three separate, clearly-labeled "tabs" — one per disposal option. All
	# three stay live simultaneously (Acquire's real rules let a player
	# split one holding across sell/trade/keep at once, e.g. trade 4, sell
	# 2, keep 2 of an 8-share holding); clicking a tab's header only
	# highlights it, as a focus aid for which action the player is
	# currently looking at — it doesn't hide or disable the other two.
	var sell := SpinBox.new()
	sell.min_value = 0
	sell.max_value = held
	var trade := SpinBox.new()
	trade.min_value = 0
	trade.step = 2                                   # 2-for-1 needs an even count
	trade.max_value = mini(held - (held % 2), state.bank_shares[survivor] * 2)
	var keep_lbl := Label.new()
	keep_lbl.add_theme_font_size_override("font_size", 20)
	keep_lbl.add_theme_color_override("font_color", _theme.color_label)

	var trade_tab := _build_dispose_tab("Trade", trade, "2-for-1 into %s" % _theme.chain_name(survivor))
	var sell_tab := _build_dispose_tab("Sell", sell, "@ %s%d each" % [_theme.currency_symbol, price])
	var keep_tab := _build_dispose_tab("Keep", null, "", keep_lbl)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	tabs.add_child(trade_tab.panel)
	tabs.add_child(sell_tab.panel)
	tabs.add_child(keep_tab.panel)
	_action_box.add_child(tabs)

	var all_tabs := [trade_tab, sell_tab, keep_tab]
	var select_tab := func(selected: Dictionary):
		for t in all_tabs:
			t.style.border_color = _theme.color_placed if t == selected else _theme.color_label.darkened(0.4)
	trade_tab.header.pressed.connect(select_tab.bind(trade_tab))
	sell_tab.header.pressed.connect(select_tab.bind(sell_tab))
	keep_tab.header.pressed.connect(select_tab.bind(keep_tab))
	select_tab.call(keep_tab)   # nothing chosen yet -> the whole holding is kept

	var update_keep := func(_v = 0):
		var k := held - int(sell.value) - int(trade.value)
		keep_lbl.text = "%d" % maxi(k, 0)
	sell.value_changed.connect(update_keep)
	trade.value_changed.connect(update_keep)
	sell.value_changed.connect(func(_v): SfxManager.play_stepper())
	trade.value_changed.connect(func(_v): SfxManager.play_stepper())
	update_keep.call()

	var confirm := Button.new()
	confirm.text = "Confirm"
	confirm.pressed.connect(func():
		SfxManager.play_button()
		_on_dispose_confirm(defunct, player, int(sell.value), int(trade.value)))
	_action_box.add_child(confirm)

## One Trade/Sell/Keep "tab" for _build_dispose_actions(): a bordered panel
## with a clickable header (purely a focus-highlight toggle — see the call
## site's comment) plus either a SpinBox (Trade/Sell) or a read-only value
## Label (Keep, which is just the auto-computed remainder, never a direct
## input). Returns the pieces the caller needs to wire up: the panel itself,
## the header button (to connect the highlight toggle), and the underlying
## StyleBoxFlat (to actually change the highlight color).
func _build_dispose_tab(title: String, spinbox: SpinBox, caption: String, value_lbl: Label = null) -> Dictionary:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _theme.color_empty.darkened(0.2)
	sb.border_color = _theme.color_label.darkened(0.4)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)

	var header := Button.new()
	header.text = title
	header.flat = true
	header.pressed.connect(SfxManager.play_button)
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", _theme.color_label)
	v.add_child(header)

	if spinbox:
		v.add_child(spinbox)
	elif value_lbl:
		value_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(value_lbl)

	if not caption.is_empty():
		var cap := Label.new()
		cap.text = caption
		cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.add_theme_font_size_override("font_size", 10)
		cap.add_theme_color_override("font_color", _theme.color_lone_tile)
		v.add_child(cap)

	return {"panel": panel, "header": header, "style": sb}

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
		summary.text = "Selected %d / %d %s — cost %s%d" % [total, AcqEnums.MAX_BUY_PER_TURN, _theme.term_stock.to_lower(), _theme.currency_symbol, _buy_cost()]
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
	card.set_meta("chain", chain)   # looked up by _find_buy_card_node() for the buy animation
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
	price_lbl.text = "%s%d  (bank %d)" % [_theme.currency_symbol, price, state.bank_shares[chain]]
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
	minus.pressed.connect(SfxManager.play_stepper)
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
	plus.pressed.connect(SfxManager.play_stepper)
	plus.pressed.connect(_set_buy.bind(chain, count + 1))
	stepper.add_child(plus)
	v.add_child(stepper)

	return card

func _build_gameover_actions() -> void:
	for i in _final_scores.size():
		var row: Dictionary = _final_scores[i]
		var l := Label.new()
		var crown := "  WINNER" if i == 0 else ""
		l.text = "%d.  %s — %s%d%s" % [i + 1, row.name, _theme.currency_symbol, row.cash, crown]
		l.add_theme_font_size_override("font_size", 18 if i == 0 else 15)
		l.add_theme_color_override("font_color", _theme.color_placed if i == 0 else _theme.color_label)
		_action_box.add_child(l)
	var again := _bordered_button("New Game")
	again.pressed.connect(_start_new_game)
	_action_box.add_child(again)
	var menu_btn := _bordered_button("Main Menu")
	menu_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/menu/MainMenu.tscn"))
	_action_box.add_child(menu_btn)


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

## Build a hand-authored near-endgame so the "Declare Game End" flow can be
## exercised without playing a full game by hand: two chains are already
## SAFE (TOWER, AMERICAN) and a third (LUXOR) sits one tile short of safe.
## Player 0's rack leads with the tile that grows LUXOR to safe size 11 —
## placing it flips can_end_game() from false to true, so "Declare Game End"
## appears on the very next buy-stock screen.
func _generate_near_endgame() -> void:
	state = GameState.new()
	session.state = state   # dev harness pokes the session's mirror directly, bypassing Actions
	state.setup_blank(NUM_PLAYERS)
	_reset_turn_state()

	_paint_chain(Chain.TOWER, _hcells(0, 11, 0))      # size 12, already safe
	_paint_chain(Chain.AMERICAN, _hcells(0, 11, 2))   # size 12, already safe
	_paint_chain(Chain.LUXOR, _hcells(0, 9, 4))       # size 10, one short of safe

	# Distribute shares and cash across the three active chains only.
	for p in state.players:
		p.shares.fill(0)
	_give(0, Chain.TOWER, 5); _give(0, Chain.AMERICAN, 3); _give(0, Chain.LUXOR, 4)
	_give(1, Chain.TOWER, 4); _give(1, Chain.AMERICAN, 6); _give(1, Chain.LUXOR, 2)
	_give(2, Chain.TOWER, 3); _give(2, Chain.AMERICAN, 2); _give(2, Chain.LUXOR, 1)
	state.bank_shares = PackedInt32Array([13, 18, 14, 25, 25, 25, 25])  # 25 minus the above
	state.players[0].cash = 3000
	state.players[1].cash = 4500
	state.players[2].cash = 5000

	# Current player's rack: the first tile grows LUXOR to safe; the rest are
	# unrelated isolated placements so the demo isn't a one-tile rack.
	var demo: Array[Vector2i] = [
		Vector2i(10, 4),  # grows LUXOR (10 -> 11): every active chain becomes safe
		Vector2i(1, 6),
		Vector2i(4, 6),
		Vector2i(7, 6),
		Vector2i(1, 8),
		Vector2i(7, 8),
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
	_msg("Generated near-endgame test state. Place the tile at 11E to grow Luxor to safe size 11 — every active chain will then be safe and \"Declare Game End\" will appear.")
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
	b.pressed.connect(SfxManager.play_button)
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
	b.pressed.connect(SfxManager.play_button)
	return b

func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()

func _msg(text: String) -> void:
	if _msg_lbl:
		_msg_lbl.text = text
