extends Button
class_name RackTile
## A tile in the current player's hand, shown in the sidebar. It is the drag
## *source*: dragging it begins a placement, and the only legal drop is the
## matching board cell. Dead tiles (which would merge two safe chains and can
## never be played) are shown greyed-out and cannot be dragged.

var coord: Vector2i
var dead := false

var _theme: ThemeDef
var _ctrl                        # the game controller (ui/game/game.gd)

func setup(tile: Vector2i, theme_def: ThemeDef, controller, is_dead: bool) -> void:
	coord = tile
	_theme = theme_def
	_ctrl = controller
	dead = is_dead
	text = AcqEnums.tile_label(coord.x, coord.y)
	custom_minimum_size = Vector2(60, 52)
	focus_mode = Control.FOCUS_NONE
	add_theme_font_size_override("font_size", 14)

	var bg := Color(0.32, 0.16, 0.16) if dead else _theme.color_empty
	add_theme_stylebox_override("normal", _box(bg))
	add_theme_stylebox_override("hover", _box(bg.lightened(0.10)))
	add_theme_stylebox_override("pressed", _box(bg))
	var fg := Color(0.80, 0.55, 0.55) if dead else _theme.color_label
	add_theme_color_override("font_color", fg)
	add_theme_color_override("font_hover_color", fg)
	if dead:
		tooltip_text = "Dead tile: it would merge two safe chains and can never be played."

func _box(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = _theme.color_label
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	return s

# --- drag source ------------------------------------------------------------
func _get_drag_data(_pos: Vector2):
	if dead or not _ctrl.can_drag_tiles():
		return null
	_ctrl.begin_drag(coord)
	set_drag_preview(_make_preview())
	return {"type": "tile", "coord": coord}

func _make_preview() -> Control:
	var panel := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _theme.color_placed
	sb.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(60, 52)
	panel.size = Vector2(60, 52)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color.BLACK)
	lbl.position = Vector2(10, 14)
	panel.add_child(lbl)
	return panel
