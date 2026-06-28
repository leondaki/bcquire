extends Node
## Autoload singleton (registered in project.godot as "NetConfig", which is
## what makes it globally accessible — no class_name here, since Godot 4
## treats a class_name matching an autoload's name as a conflict, not an
## alias). Carries a player's menu choice (name + Hotseat/Host/Join/online
## + address/port/relay code) across the scene swap from
## ui/menu/MainMenu.tscn to ui/game/Game.tscn — change_scene_to_file()
## destroys the old scene tree, so this is the only way to pass that intent
## along.
##
## `has_pending` defaults false: headless scripts that instance Game.tscn
## directly (sim/check_midgame.gd, sim/check_near_endgame.gd) never touch this
## autoload, so they keep getting today's default solo-hotseat session with no
## changes required on their end.

## Default address of the deployed relay-server/ instance (see that
## directory's README for deployment). Override at runtime if you're running
## your own relay elsewhere.
const DEFAULT_RELAY_URL := "ws://127.0.0.1:8080"

var has_pending := false
var mode := "hotseat"   # "hotseat" | "host" | "join" | "host_relay" | "join_relay"
var player_name := "Player 1"
var host_port := 8910
var join_address := "127.0.0.1"
var join_port := 8910
var relay_url := DEFAULT_RELAY_URL
var join_code := ""

func set_hotseat(p_name: String) -> void:
	has_pending = true
	mode = "hotseat"
	player_name = p_name

func set_host(p_name: String, port: int) -> void:
	has_pending = true
	mode = "host"
	player_name = p_name
	host_port = port

func set_join(p_name: String, address: String, port: int) -> void:
	has_pending = true
	mode = "join"
	player_name = p_name
	join_address = address
	join_port = port

func set_host_relay(p_name: String, p_relay_url: String = DEFAULT_RELAY_URL) -> void:
	has_pending = true
	mode = "host_relay"
	player_name = p_name
	relay_url = p_relay_url

func set_join_relay(p_name: String, p_relay_url: String, code: String) -> void:
	has_pending = true
	mode = "join_relay"
	player_name = p_name
	relay_url = p_relay_url
	join_code = code

func clear() -> void:
	has_pending = false
