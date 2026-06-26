extends Control
## M1 sandbox: builds the 12x9 Acquire board from ThemeDef and lets you click
## cells to place/remove a highlighted tile. Proves the grid, coordinate math,
## and input plumbing before the real rules engine (M2) and theming pass (M5).

const TileScene := preload("res://ui/board/Tile.tscn")
const DefaultTheme := preload("res://theme/default_theme.tres")

@onready var _background: ColorRect = %Background
@onready var _grid: GridContainer = %Grid
@onready var _status: Label = %Status

var _theme: ThemeDef
var _placed_count: int = 0

func _ready() -> void:
	_theme = DefaultTheme
	_background.color = _theme.color_background
	_build_board()
	_set_status("Click any cell to place a tile.")

func _build_board() -> void:
	_grid.columns = _theme.board_width
	for r in _theme.board_height:
		for c in _theme.board_width:
			var tile := TileScene.instantiate()
			_grid.add_child(tile)
			tile.setup(c, r, _theme)
			tile.tile_clicked.connect(_on_tile_clicked)

func _on_tile_clicked(col: int, row: int, placed: bool) -> void:
	var label := AcqEnums.tile_label(col, row)
	_placed_count += 1 if placed else -1
	var verb := "Placed" if placed else "Removed"
	print("%s %s" % [verb, label])
	_set_status("%s %s    (tiles on board: %d)" % [verb, label, _placed_count])

func _set_status(text: String) -> void:
	_status.text = text
