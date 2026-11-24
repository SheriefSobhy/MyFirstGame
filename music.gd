extends Node
## Background music, autoloaded as "Music" so it keeps playing across scene
## changes and while the game is paused. Plays on the "Music" audio bus, whose
## volume is set in the settings screen. Switching tracks fades between them.
## Every track loops (set in their .import files). Each map can have its
## own gameplay track (main.gd's `music`); GAME_TRACK is the default.

const MENU_TRACK := preload("res://assets/music/menu_menace.ogg")
const GAME_TRACK := preload("res://assets/music/game_zombies_march.ogg")
const FADE_TIME := 1.0
const SILENT_DB := -40.0
const TRACK_DB := -6.0   # leaves room for the gunshots

var _player: AudioStreamPlayer
var _tween: Tween


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.bus = Settings.MUSIC_BUS
	add_child(_player)


func play_menu() -> void:
	_play(MENU_TRACK)


func play_game(track: AudioStream = null) -> void:
	_play(track if track != null else GAME_TRACK)


func current_track() -> AudioStream:
	return _player.stream if _player.playing else null


func _play(track: AudioStream) -> void:
	if _player.stream == track and _player.playing:
		return
	if _tween:
		_tween.kill()
	_tween = create_tween()
	if _player.playing:
		_tween.tween_property(_player, "volume_db", SILENT_DB, FADE_TIME * 0.5)
	_tween.tween_callback(_start.bind(track))
	_tween.tween_property(_player, "volume_db", TRACK_DB, FADE_TIME)


func _start(track: AudioStream) -> void:
	_player.stream = track
	_player.volume_db = SILENT_DB
	_player.play()
