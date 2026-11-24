extends Node
## Player settings and the best scores, autoloaded as "Settings".
## Settings are saved to user://settings.cfg and the best score of each map
## to user://save.cfg (on the web build these live in the browser's storage).
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

## Best score and wave per map id (see maps.gd): {id: {"score": int, "wave": int}}.
var bests := {}
## The best score over all maps (shown on the main menu).
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
	# computers on High. Desktop builds ("pc") always count as computers, even
	# on touchscreen laptops.
	var phone := not OS.has_feature("pc") and (OS.has_feature("android")
			or DisplayServer.is_touchscreen_available())
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


## Records a finished run on a map. Returns true if it is a new best score
## for that map.
func submit_score(score: int, waves: int, map_id := "yard") -> bool:
	var b: Dictionary = bests.get(map_id, {"score": 0, "wave": 0})
	var new_best: bool = score > b.score
	b = {"score": maxi(b.score, score), "wave": maxi(b.wave, waves)}
	bests[map_id] = b
	_update_overall()
	var cfg := ConfigFile.new()
	for id: String in bests:
		cfg.set_value("best_" + id, "score", bests[id].score)
		cfg.set_value("best_" + id, "wave", bests[id].wave)
	cfg.save(SAVE_PATH)
	return new_best


func best_score_for(map_id: String) -> int:
	return bests.get(map_id, {"score": 0}).score


func best_wave_for(map_id: String) -> int:
	return bests.get(map_id, {"wave": 0}).wave


## Forgets every best score (tests use this; nothing is saved until the next run).
func clear_bests() -> void:
	bests.clear()
	_update_overall()


func _update_overall() -> void:
	best_score = 0
	best_wave = 0
	for id: String in bests:
		best_score = maxi(best_score, bests[id].score)
		best_wave = maxi(best_wave, bests[id].wave)


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
		for section in save.get_sections():
			if section.begins_with("best_"):
				bests[section.trim_prefix("best_")] = {
					"score": int(save.get_value(section, "score", 0)),
					"wave": int(save.get_value(section, "wave", 0)),
				}
		# Saves from before there were several maps: that score was the yard's.
		if save.has_section("best") and not bests.has("yard"):
			bests["yard"] = {"score": int(save.get_value("best", "score", 0)), "wave": int(save.get_value("best", "wave", 0))}
	_update_overall()


func _apply_audio() -> void:
	_set_bus_volume(0, master_volume)
	_set_bus_volume(AudioServer.get_bus_index(MUSIC_BUS), music_volume)


func _set_bus_volume(bus: int, volume: float) -> void:
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(bus, volume <= 0.001)
