extends Node
## Autoload singleton (registered in project.godot as "SfxManager"). Central
## place to play one-shot sound effects so call sites never touch file paths
## directly. To add or replace a sound: drop the .ogg in audio/ and add (or
## edit) one line in SOUNDS below -- no other code needs to change.

const SOUNDS := {
	"tile": preload("res://audio/tile-played.ogg"),
	"merger": preload("res://audio/merger-played.ogg"),
	"stepper": preload("res://audio/stepper.ogg"),
	"button": preload("res://audio/button-click.ogg"),
}

const POOL_SIZE := 8

## Background music lives on its own bus (created at runtime below, not via
## an editor-authored bus layout resource -- this project has never had one
## and adding it programmatically means there's nothing extra to import or
## keep in sync). Routing music separately from one-shot SFX is what makes
## "don't let it play too loudly" a one-line bus-volume change instead of
## something that also has to scale every SFX call.
const MUSIC_BUS := "Music"
const MUSIC_DEFAULT_VOLUME_DB := -14.0

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music_player: AudioStreamPlayer
## A preloaded resource bound to a const can't have its properties
## reassigned at runtime ("Cannot assign a new value to a constant") -- a
## `var` here, not `const`, is what lets `loop = true` be set below.
var _music_stream: AudioStreamMP3 = preload("res://audio/The_Closing_Bell.mp3")

func _ready() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

	_ensure_music_bus()
	_music_stream.loop = true
	_music_player = AudioStreamPlayer.new()
	_music_player.stream = _music_stream
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)

func _ensure_music_bus() -> void:
	if AudioServer.get_bus_index(MUSIC_BUS) != -1:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, MUSIC_BUS)
	AudioServer.set_bus_volume_db(idx, MUSIC_DEFAULT_VOLUME_DB)

## Plays `key` on the next free pooled player (round-robin if all are busy,
## which is all a board game's sparse, rarely-overlapping SFX calls for).
func play(key: String) -> void:
	var stream: AudioStream = SOUNDS.get(key)
	if not stream:
		return
	var p := _next_player()
	p.stream = stream
	p.play()

func _next_player() -> AudioStreamPlayer:
	for p in _players:
		if not p.playing:
			return p
	_next = (_next + 1) % POOL_SIZE
	return _players[_next]

func play_tile() -> void: play("tile")
func play_merger() -> void: play("merger")
func play_stepper() -> void: play("stepper")
func play_button() -> void: play("button")

func play_music() -> void:
	if not _music_player.playing:
		_music_player.play()

func stop_music() -> void:
	_music_player.stop()

## Volume in dB (negative = quieter, 0 = unity gain, this is what
## MUSIC_DEFAULT_VOLUME_DB above sets out of the box). Affects only the
## Music bus, never the SFX one-shots.
func set_music_volume_db(db: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(MUSIC_BUS), db)

## Convenience for a future volume slider: 0.0 (silent) .. 1.0 (unity gain).
func set_music_volume_linear(v: float) -> void:
	set_music_volume_db(linear_to_db(clampf(v, 0.0, 1.0)))
