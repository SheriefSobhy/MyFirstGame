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

## AUTO measures the frame rate in the first seconds of a match and picks
## Low, Medium or High (auto_quality.gd); `auto_quality` remembers the pick.
enum Quality { LOW, MEDIUM, HIGH, AUTO }
const QUALITY_NAMES := ["Low", "Medium", "High", "Auto"]
## Frame rate cap choices (battery saving). Not applied in headless tests.
const FPS_CAPS := [30, 60]
## Touch button size and opacity limits (Customize Controls).
const MIN_BUTTON_SCALE := 0.6
const MAX_BUTTON_SCALE := 1.6
const MIN_TOUCH_OPACITY := 0.2

const MIN_SENSITIVITY := 0.2
const MAX_SENSITIVITY := 3.0

var master_volume := 1.0     # 0..1
var music_volume := 0.6      # 0..1
var look_sensitivity := 1.0  # multiplier on mouse and touch look speed
var quality: int = Quality.AUTO
## What Auto picked last (-1 = not measured yet: the next match measures).
var auto_quality := -1
var fps_cap := 60
var damage_numbers := true   # floating damage numbers on hits
var haptics := true          # phone vibration on shots, kills, explosions and damage
var aim_assist := true       # touch only: slower look over enemies, pull when aiming
var debug_unlock_all := false # testing: every weapon from the start, every level unlock (weapons, maps)
var left_handed := false     # touch controls mirrored: joystick right, buttons left
var touch_opacity := 1.0     # touch buttons and joystick
## Moved / resized touch buttons: name -> {"pos": Vector2, "scale": float}.
## pos.x >= 0 is measured from the left edge, < 0 from the right edge;
## pos.y (< 0) from the bottom edge. Buttons not in here use their default
## spot and size (touch_controls.gd BUTTONS). Saved unmirrored.
var touch_layout := {}
var tutorial_done := false   # the first-match tutorial was finished or skipped

## Best score and wave per map id (see maps.gd): {id: {"score": int, "wave": int}}.
var bests := {}
## The best score over all maps (shown on the main menu).
var best_score := 0
var best_wave := 0
## Training Arena challenge bests (training_config.gd CHALLENGES): id -> value
## (seconds for Target Practice, headshots, accuracy %). Saved with the bests.
var training_bests := {}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	if AudioServer.get_bus_index(MUSIC_BUS) == -1:
		AudioServer.add_bus()
		var bus := AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, MUSIC_BUS)
		AudioServer.set_bus_send(bus, &"Master")
	# Tests (tool scripts) skip the tutorial unless they ask for it.
	if _under_test():
		tutorial_done = true
	else:
		_migrate_old_saves()
	_load()
	_apply_audio()
	_apply_fps_cap()


## The game was renamed (Last Stand -> Ashline -> Dead Perimeter) and Windows
## keeps saves in a folder named after the project. If this folder has no
## saves, copy them once from the old folder.
func _migrate_old_saves() -> void:
	if not OS.has_feature("windows"):
		return
	var files := ["settings.cfg", "save.cfg", "progress.cfg"]
	for f in files:
		if FileAccess.file_exists("user://" + f):
			return
	var base := ProjectSettings.globalize_path("user://").trim_suffix("/").get_base_dir()
	for old in ["Last Stand", "Ashline"]:
		var found := false
		for f in files:
			var src: String = base.path_join(old).path_join(f)
			if FileAccess.file_exists(src):
				if DirAccess.copy_absolute(src, ProjectSettings.globalize_path("user://" + f)) == OK:
					found = true
		if found:
			return


func _under_test() -> bool:
	return get_tree().get_script() != null


## True on phones and tablets (and the Android app). Desktop builds ("pc")
## always count as computers, even on touchscreen laptops.
static func is_phone() -> bool:
	return not OS.has_feature("pc") and (OS.has_feature("android")
			or DisplayServer.is_touchscreen_available())


## The quality actually used: the chosen one, or what Auto picked. Before Auto
## has measured anything: Medium on phones, High on computers.
func effective_quality() -> int:
	if quality != Quality.AUTO:
		return quality
	if auto_quality >= 0:
		return auto_quality
	return Quality.MEDIUM if is_phone() else Quality.HIGH


func set_value(key: String, value: Variant) -> void:
	if key == "quality" and value == Quality.AUTO and quality != Quality.AUTO:
		auto_quality = -1  # choosing Auto again measures again
	set(key, value)
	_apply_audio()
	_apply_fps_cap()
	changed.emit()


## A touch button's saved layout ({} = its default spot and size).
func button_layout(button_name: String) -> Dictionary:
	return touch_layout.get(button_name, {})


func set_button_layout(button_name: String, pos: Vector2, scale: float) -> void:
	touch_layout[button_name] = {"pos": pos, "scale": clampf(scale, MIN_BUTTON_SCALE, MAX_BUTTON_SCALE)}
	changed.emit()


## Customize Controls' "Reset to default": default spots, sizes and opacity.
func reset_touch_layout() -> void:
	touch_layout.clear()
	touch_opacity = 1.0
	changed.emit()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.set_value("controls", "look_sensitivity", look_sensitivity)
	cfg.set_value("controls", "left_handed", left_handed)
	cfg.set_value("controls", "touch_opacity", touch_opacity)
	cfg.set_value("controls", "touch_layout", touch_layout)
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "auto_quality", auto_quality)
	cfg.set_value("graphics", "fps_cap", fps_cap)
	cfg.set_value("gameplay", "damage_numbers", damage_numbers)
	cfg.set_value("gameplay", "haptics", haptics)
	cfg.set_value("gameplay", "aim_assist", aim_assist)
	cfg.set_value("gameplay", "tutorial_done", tutorial_done)
	cfg.set_value("debug", "unlock_all", debug_unlock_all)
	cfg.save(SETTINGS_PATH)


## Records a finished run on a map. Returns true if it is a new best score
## for that map.
func submit_score(score: int, waves: int, map_id := "yard") -> bool:
	var b: Dictionary = bests.get(map_id, {"score": 0, "wave": 0})
	var new_best: bool = score > b.score
	b = {"score": maxi(b.score, score), "wave": maxi(b.wave, waves)}
	bests[map_id] = b
	_update_overall()
	save_bests()
	return new_best


## Records a Training Arena challenge result. lower_is_better for times.
## Returns true if it is a new best.
func submit_training(challenge: String, value: float, lower_is_better := false) -> bool:
	var has_old := training_bests.has(challenge)
	var old: float = training_bests.get(challenge, 0.0)
	var better := not has_old or (value < old if lower_is_better else value > old)
	if better:
		training_bests[challenge] = value
		save_bests()
	return better


## The best result of a Training Arena challenge, or -1 if never done.
func training_best(challenge: String) -> float:
	return training_bests.get(challenge, -1.0)


## Writes the best scores to user://save.cfg.
func save_bests() -> void:
	var cfg := ConfigFile.new()
	for id: String in bests:
		cfg.set_value("best_" + id, "score", bests[id].score)
		cfg.set_value("best_" + id, "wave", bests[id].wave)
	for id: String in training_bests:
		cfg.set_value("training", id, training_bests[id])
	cfg.save(SAVE_PATH)


func best_score_for(map_id: String) -> int:
	return bests.get(map_id, {"score": 0}).score


func best_wave_for(map_id: String) -> int:
	return bests.get(map_id, {"wave": 0}).wave


## Forgets every best score (tests use this; nothing is saved until the next run).
func clear_bests() -> void:
	bests.clear()
	training_bests.clear()
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
		if not _under_test():  # tests expect the default touch layout
			left_handed = bool(cfg.get_value("controls", "left_handed", left_handed))
			touch_opacity = clampf(cfg.get_value("controls", "touch_opacity", touch_opacity), MIN_TOUCH_OPACITY, 1.0)
			touch_layout = _clean_layout(cfg.get_value("controls", "touch_layout", {}))
		quality = clampi(cfg.get_value("graphics", "quality", quality), Quality.LOW, Quality.AUTO)
		auto_quality = clampi(cfg.get_value("graphics", "auto_quality", auto_quality), -1, Quality.HIGH)
		fps_cap = int(cfg.get_value("graphics", "fps_cap", fps_cap))
		if not fps_cap in FPS_CAPS:
			fps_cap = 60
		damage_numbers = bool(cfg.get_value("gameplay", "damage_numbers", damage_numbers))
		haptics = bool(cfg.get_value("gameplay", "haptics", haptics))
		aim_assist = bool(cfg.get_value("gameplay", "aim_assist", aim_assist))
		if not _under_test():
			tutorial_done = bool(cfg.get_value("gameplay", "tutorial_done", tutorial_done))
		debug_unlock_all = bool(cfg.get_value("debug", "unlock_all", debug_unlock_all))
	var save := ConfigFile.new()
	if save.load(SAVE_PATH) == OK:
		for section in save.get_sections():
			if section.begins_with("best_"):
				bests[section.trim_prefix("best_")] = {
					"score": int(save.get_value(section, "score", 0)),
					"wave": int(save.get_value(section, "wave", 0)),
				}
		if save.has_section("training"):
			for id in save.get_section_keys("training"):
				training_bests[id] = float(save.get_value("training", id, 0.0))
		# Saves from before there were several maps: that score was the yard's.
		if save.has_section("best") and not bests.has("yard"):
			bests["yard"] = {"score": int(save.get_value("best", "score", 0)), "wave": int(save.get_value("best", "wave", 0))}
		# The old "Soldiers (Test)" mode (the Yard) is now Combat on the Yard.
		if bests.has("soldiers"):
			if not bests.has("combat_yard"):
				bests["combat_yard"] = bests["soldiers"]
			bests.erase("soldiers")
	_update_overall()


# Only well-formed entries from a saved touch layout.
func _clean_layout(layout: Variant) -> Dictionary:
	var out := {}
	if not layout is Dictionary:
		return out
	for key: Variant in layout:
		var b: Variant = layout[key]
		if b is Dictionary and b.get("pos") is Vector2:
			out[str(key)] = {"pos": b.pos,
					"scale": clampf(float(b.get("scale", 1.0)), MIN_BUTTON_SCALE, MAX_BUTTON_SCALE)}
	return out


## Battery saving: 30 or 60 frames per second. Headless runs (tests) stay
## uncapped so they don't slow down.
func _apply_fps_cap() -> void:
	Engine.max_fps = 0 if DisplayServer.get_name() == "headless" else fps_cap


func _apply_audio() -> void:
	_set_bus_volume(0, master_volume)
	_set_bus_volume(AudioServer.get_bus_index(MUSIC_BUS), music_volume)


func _set_bus_volume(bus: int, volume: float) -> void:
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(bus, volume <= 0.001)
