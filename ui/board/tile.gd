extends Button
class_name BoardTile
## A single clickable board cell. Knows its (col,row), shows its "1A".."12I"
## label, and toggles a placed/empty highlight on click. All colors come from
## ThemeDef so the cell re-skins with the theme. In later milestones the rules
## engine will drive the visual state (chain color, safe marker, etc.) instead
## of this local toggle.

signal tile_clicked(col: int, row: int, placed: bool)

var col: int = 0
var row: int = 0
var placed: bool = false
var _theme: ThemeDef

func setup(c: int, r: int, theme_def: ThemeDef) -> void:
	col = c
	row = r
	_theme = theme_def
	text = AcqEnums.tile_label(c, r)
	custom_minimum_size = _theme.tile_size
	clip_text = true
	focus_mode = Control.FOCUS_NONE
	pressed.connect(_on_pressed)
	_apply_style()

func _on_pressed() -> void:
	placed = not placed
	_apply_style()
	tile_clicked.emit(col, row, placed)

func _apply_style() -> void:
	var base: Color = _theme.color_placed if placed else _theme.color_empty
	add_theme_stylebox_override("normal", _make_box(base))
	add_theme_stylebox_override("hover", _make_box(_theme.color_hover))
	add_theme_stylebox_override("pressed", _make_box(_theme.color_hover))
	add_theme_color_override("font_color", _theme.color_label)
	add_theme_color_override("font_hover_color", _theme.color_label)
	add_theme_color_override("font_pressed_color", _theme.color_label)

func _make_box(c: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = c
	box.border_color = _theme.color_label
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	return box
