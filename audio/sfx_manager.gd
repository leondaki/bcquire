extends Node
## Scene-based autoload (registered in project.godot as "SfxManager", pointing
## at audio/SfxManager.tscn rather than this script directly -- that's what
## gives the @export slots below an Inspector to live in). To replace a sound:
## select the SfxManager node in that scene and drag a new .ogg/.mp3 from the
## FileSystem dock onto the matching slot. No code edit required.

@export var sfx_tile: AudioStream
@export var sfx_merger: AudioStream
@export var sfx_chain_founded: AudioStream
@export var sfx_stepper: AudioStream
@export var sfx_button: AudioStream
## Background music lives on its own bus (created at runtime below, not via
## an editor-authored bus layout resource -- this project has never had one
## and adding it programmatically means there's nothing extra to import or
## keep in sync). Routing music separately from one-shot SFX is what makes
## "don't let it play too loudly" a one-line bus-volume change instead of
## something that also has to scale every SFX call.
@export var music: AudioStream

const MUSIC_BUS := "Music"
const MUSIC_DEFAULT_VOLUME_DB := -14.0
const POOL_SIZE := 8

var _sounds: Dictionary
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music_player: AudioStreamPlayer

func _ready() -> void:
	_sounds = {
		"tile": sfx_tile,
		"merger": sfx_merger,
		"chain_founded": sfx_chain_founded,
		"stepper": sfx_stepper,
		"button": sfx_button,
	}

	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

	_ensure_music_bus()
	if music:
		music.loop = true
	_music_player = AudioStreamPlayer.new()
	_music_player.stream = music
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
	var stream: AudioStream = _sounds.get(key)
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
func play_chain_founded() -> void: play("chain_founded")
func play_stepper() -> void: play("stepper")
func play_button() -> void: play("button")

func play_music() -> void:
	if _music_player and not _music_player.playing:
		_music_player.play()

func stop_music() -> void:
	if _music_player:
		_music_player.stop()

## Volume in dB (negative = quieter, 0 = unity gain, this is what
## MUSIC_DEFAULT_VOLUME_DB above sets out of the box). Affects only the
## Music bus, never the SFX one-shots.
func set_music_volume_db(db: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(MUSIC_BUS), db)

## Convenience for a future volume slider: 0.0 (silent) .. 1.0 (unity gain).
func set_music_volume_linear(v: float) -> void:
	set_music_volume_db(linear_to_db(clampf(v, 0.0, 1.0)))
