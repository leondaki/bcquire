extends Control
## Pre-game menu: every player starts here. Captures a display name and a
## mode (offline Hotseat, host a LAN game, or join one), stashes the choice
## into the NetConfig autoload, then hands off to ui/game/Game.tscn, whose
## _ready() reads NetConfig and kicks off the matching session automatically
## (see game.gd's _ready()/_host_networked_game()/_join_networked_game()).

var _name_edit: LineEdit
var _host_port_edit: LineEdit
var _join_addr_edit: LineEdit
var _join_port_edit: LineEdit
var _status_lbl: Label

func _ready() -> void:
	_build_layout()

func _build_layout() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(360, 0)
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var title := Label.new()
	title.text = "ACQUIRE"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var name_lbl := Label.new()
	name_lbl.text = "Your name"
	root.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.text = "Player 1"
	root.add_child(_name_edit)

	root.add_child(HSeparator.new())

	var hotseat_btn := Button.new()
	hotseat_btn.text = "Play Hotseat (offline, one device)"
	hotseat_btn.pressed.connect(_on_hotseat_pressed)
	root.add_child(hotseat_btn)

	root.add_child(HSeparator.new())

	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 8)
	var host_lbl := Label.new()
	host_lbl.text = "Port"
	host_row.add_child(host_lbl)
	_host_port_edit = LineEdit.new()
	_host_port_edit.text = "8910"
	_host_port_edit.custom_minimum_size = Vector2(70, 0)
	host_row.add_child(_host_port_edit)
	var host_btn := Button.new()
	host_btn.text = "Host Game"
	host_btn.pressed.connect(_on_host_pressed)
	host_row.add_child(host_btn)
	root.add_child(host_row)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	_join_addr_edit = LineEdit.new()
	_join_addr_edit.text = "127.0.0.1"
	_join_addr_edit.custom_minimum_size = Vector2(120, 0)
	_join_addr_edit.tooltip_text = "Host address"
	join_row.add_child(_join_addr_edit)
	_join_port_edit = LineEdit.new()
	_join_port_edit.text = "8910"
	_join_port_edit.custom_minimum_size = Vector2(70, 0)
	_join_port_edit.tooltip_text = "Host port"
	join_row.add_child(_join_port_edit)
	var join_btn := Button.new()
	join_btn.text = "Join Game"
	join_btn.pressed.connect(_on_join_pressed)
	join_row.add_child(join_btn)
	root.add_child(join_row)

	_status_lbl = Label.new()
	_status_lbl.text = ""
	root.add_child(_status_lbl)

func _player_name() -> String:
	return _name_edit.text if not _name_edit.text.is_empty() else "Player 1"

func _on_hotseat_pressed() -> void:
	NetConfig.set_hotseat(_player_name())
	get_tree().change_scene_to_file("res://ui/game/Game.tscn")

func _on_host_pressed() -> void:
	var port := int(_host_port_edit.text) if _host_port_edit.text.is_valid_int() else 8910
	NetConfig.set_host(_player_name(), port)
	get_tree().change_scene_to_file("res://ui/game/Game.tscn")

func _on_join_pressed() -> void:
	var addr := _join_addr_edit.text if not _join_addr_edit.text.is_empty() else "127.0.0.1"
	var port := int(_join_port_edit.text) if _join_port_edit.text.is_valid_int() else 8910
	NetConfig.set_join(_player_name(), addr, port)
	get_tree().change_scene_to_file("res://ui/game/Game.tscn")
