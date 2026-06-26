extends Button
class_name BoardCell
## One square of the playing board. It is purely a *view* of GameState plus a
## drop target: it never mutates game state itself. Colour comes entirely from
## ThemeDef (empty / lone / chain colour), so the board re-skins with the theme.
##
## Drag-and-drop: a rack tile may only be dropped on the single board cell whose
## coordinate matches the tile (tile "7C" -> cell 7C), which is how we guarantee
## tiles are placed in the correct position. The controller validates the drop.

var col: int
var row: int
var highlight := false          # glowing border while it is the active drop target
var playable := false           # current player can legally place a tile here (yellow hint)

var _theme: ThemeDef
var _ctrl                        # the game controller (ui/game/game.gd)

func setup(c: int, r: int, theme_def: ThemeDef, controller) -> void:
	col = c
	row = r
	_theme = theme_def
	_ctrl = controller
	text = AcqEnums.tile_label(c, r)
	custom_minimum_size = _theme.tile_size
	focus_mode = Control.FOCUS_NONE
	clip_text = true
	add_theme_font_size_override("font_size", 12)
	# Note: do NOT refresh() here — cells are built before GameState exists.
	# The controller's _refresh_all() paints every cell once the game starts.

## Repaint from the current board state.
func refresh() -> void:
	var v: int = _ctrl.state.cell(col, row)
	var empty := v == AcqEnums.CELL_EMPTY
	var bg: Color
	if empty:
		bg = _theme.color_empty
		if playable:
			# Lightly shade legal squares yellow for the current player.
			bg = bg.lerp(_theme.color_playable, 0.30)
	elif v == AcqEnums.ChainId.NONE:
		bg = _theme.color_lone_tile
	else:
		bg = _theme.chain_color(v)

	var border: Color
	var width: int
	if highlight:
		border = _theme.color_placed
		width = 3
	elif playable and empty:
		border = _theme.color_playable
		width = 2
	else:
		border = _theme.color_label
		width = 1
	add_theme_stylebox_override("normal", _box(bg, border, width))
	add_theme_stylebox_override("hover", _box(bg.lightened(0.08), border, width))
	add_theme_stylebox_override("pressed", _box(bg, border, width))
	# Keep label readable on light chain colours.
	var fg := Color.BLACK if (v >= 0 and bg.get_luminance() > 0.5) else _theme.color_label
	add_theme_color_override("font_color", fg)
	add_theme_color_override("font_hover_color", fg)
	add_theme_color_override("font_pressed_color", fg)

func _box(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(4)
	return s

# --- drag-and-drop target ---------------------------------------------------
func _can_drop_data(_pos: Vector2, data) -> bool:
	return _ctrl.can_drop_tile(col, row, data)

func _drop_data(_pos: Vector2, data) -> void:
	_ctrl.drop_tile(col, row, data)
