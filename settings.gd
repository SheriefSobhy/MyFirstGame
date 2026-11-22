extends Node
## Player settings and the best score, autoloaded as "Settings".
## Settings are saved to user://settings.cfg and the best score to
## user://save.cfg (on the web build these live in the browser's storage).
##
## To change a setting: Settings.set_value("music_volume", 0.5), then
## Settings.save_settings() once the player is done (the settings screen does
## this when it closes). `changed` lets the game re-apply graphics settings.

signal changed

const SETTINGS_PATH := "user://settings.cfg"
const SAVE_PATH := "user://save.cfg"
const MUSIC_BUS := "Music"

enum Quality { LOW, MEDIUM, HIGH }
const QUALITY_NAMES := ["Low", "Medium", "High"]

const MIN_SENSITIVITY := 0.2
const MAX_SENSITIVITY := 3.0

var master_volume := 1.0     # 0..1
var music_volume := 0.6      # 0..1
var look_sensitivity := 1.0  # multiplier on mouse and touch look speed
var quality: int = Quality.HIGH

var best_score := 0
var best_wave := 0


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	if AudioServer.get_bus_index(MUSIC_BUS) == -1:
		AudioServer.add_bus()
		var bus := AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, MUSIC_BUS)
		AudioServer.set_bus_send(bus, &"Master")
	# The Android app and phones start on Medium (the old phone settings),
	# computers on High.
	var phone := OS.has_feature("android") or DisplayServer.is_touchscreen_available()
	quality = Quality.MEDIUM if phone else Quality.HIGH
	_load()
	_apply_audio()


func set_value(key: String, value: Variant) -> void:
	set(key, value)
	_apply_audio()
	changed.emit()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.set_value("controls", "look_sensitivity", look_sensitivity)
	cfg.set_value("graphics", "quality", quality)
	cfg.save(SETTINGS_PATH)


## Records a finished run. Returns true if it is a new best score.
func submit_score(score: int, waves: int) -> bool:
	best_wave = maxi(best_wave, waves)
	var new_best := score > best_score
	if new_best:
		best_score = score
	var cfg := ConfigFile.new()
	cfg.set_value("best", "score", best_score)
	cfg.set_value("best", "wave", best_wave)
	cfg.save(SAVE_PATH)
	return new_best


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		master_volume = clampf(cfg.get_value("audio", "master_volume", master_volume), 0.0, 1.0)
		music_volume = clampf(cfg.get_value("audio", "music_volume", music_volume), 0.0, 1.0)
		look_sensitivity = clampf(cfg.get_value("controls", "look_sensitivity", look_sensitivity),
				MIN_SENSITIVITY, MAX_SENSITIVITY)
		quality = clampi(cfg.get_value("graphics", "quality", quality), Quality.LOW, Quality.HIGH)
	var save := ConfigFile.new()
	if save.load(SAVE_PATH) == OK:
		best_score = save.get_value("best", "score", 0)
		best_wave = save.get_value("best", "wave", 0)


func _apply_audio() -> void:
	_set_bus_volume(0, master_volume)
	_set_bus_volume(AudioServer.get_bus_index(MUSIC_BUS), music_volume)


func _set_bus_volume(bus: int, volume: float) -> void:
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(bus, volume <= 0.001)
