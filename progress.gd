extends Node
## Persistent progression, autoloaded as "Progress" and saved to
## user://progress.cfg (in the browser's storage on the web build):
## XP and level, coins, the Armory's permanent upgrades and skins, daily
## missions, the daily login streak, the highest wave reached on each map
## (map stars), lifetime stats and achievements.
## Every balance number is in progression_config.gd.
##
## main.gd reports the match: start_match(), on_kill(), on_wave_started(),
## on_wave_cleared() and end_match() (which pays the coins and returns a
## summary for the Game Over screen). XP counts the moment it is earned, so
## you can level up mid-match. Saved after every wave, at the end of a match,
## after each Armory purchase and when the app is closed or sent to the
## background.
##
## Run from a tool script (the tests in tools/), it starts from nothing and
## saves to user://progress_test.cfg instead, so tests never touch your
## real progress.

## Anything changed (menus refresh).
signal changed
## Reached `level`. unlocks: names of the weapons and maps it unlocks.
signal leveled_up(level: int, unlocks: Array)
signal mission_completed(text: String, reward: int)
signal achievement_unlocked(title: String, reward: int)
## A new star on a map (stars = how many it has now).
signal star_earned(map_id: String, stars: int)

const Config := preload("res://progression_config.gd")
const Weapons := preload("res://weapon_stats.gd")
const Maps := preload("res://maps.gd")
const Missions := preload("res://missions/missions_config.gd")
const SAVE_PATH := "user://progress.cfg"
const TEST_SAVE_PATH := "user://progress_test.cfg"
const SAVE_VERSION := 1
const UPGRADE_STATS := ["damage", "mag", "reload"]
const STAT_KEYS := ["kills", "headshots", "kills_brute", "kills_boss", "matches",
		"waves_cleared", "missions_done", "skins_bought", "coins_earned"]

var save_path := SAVE_PATH
## Total XP earned (the level comes from it).
var xp := 0
var coins := 0
## Permanent upgrade levels: weapon name -> {"damage": n, "mag": n, "reload": n}.
var upgrades := {}
## Skins bought: weapon name -> [skin ids] ("standard" is always owned).
var skins_owned := {}
## Skin in use: weapon name -> skin id.
var skins_equipped := {}
## Lifetime counters (STAT_KEYS).
var stats := {}
## Achievement id -> true once unlocked.
var achievements := {}
## Highest wave reached on each map (map id -> wave): the map's stars.
var best_wave := {}
## Matches played on each map (map id -> count).
var maps_played := {}
## Combat missions: best stars per mission id (0-3; cleared = 1 or more).
var mission_stars := {}
## Today's missions: {"date": "YYYY-MM-DD", "missions": [mission, ...]}.
## mission: {id, type, kind, map, text, target, reward, progress, done}.
var daily := {}
## Daily login: last day claimed, the streak day it was (1-7), best streak.
var login := {"last": "", "streak": 0, "best": 0}
## Tests set this to pretend it's another day ("YYYY-MM-DD"; "" = the real date).
var date_override := ""

## The match being played ({} when none): map, xp, coins, start_level,
## stars_before, missions (texts completed), ended.
var current := {}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	if get_tree().get_script() != null:
		# Running a tool script (tests): a fresh, separate save.
		save_path = TEST_SAVE_PATH
		DirAccess.remove_absolute(TEST_SAVE_PATH)
	load_progress()
	refresh_daily()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		save()


# --- Level and XP ------------------------------------------------------------

func level() -> int:
	return Config.level_for_xp(xp)


## XP into the current level and XP that level needs (both 0 at the max level).
func level_xp() -> Vector2i:
	var lv := level()
	if lv >= Config.MAX_LEVEL:
		return Vector2i.ZERO
	return Vector2i(xp - Config.xp_for_level(lv), Config.xp_to_next(lv))


func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	var before := level()
	xp += amount
	if in_match():
		current.xp += amount
	for lv in range(before + 1, level() + 1):
		add_coins(Config.LEVEL_UP_COINS)
		leveled_up.emit(lv, unlocks_at(lv))
	if level() > before:
		_check_achievements()
	changed.emit()


## Names of the weapons and maps that unlock at exactly `lv`.
func unlocks_at(lv: int) -> Array:
	var names := []
	for w: Dictionary in Weapons.LIST:
		if Config.weapon_unlock_level(w.name) == lv and lv > 1:
			names.append(w.name)
	for m: Dictionary in Maps.LIST:
		if Config.map_unlock_level(m.id) == lv and lv > 1:
			names.append(m.name)
	return names


# --- Coins ------------------------------------------------------------------------

func add_coins(amount: int) -> void:
	if amount <= 0:
		return
	coins += amount
	stats.coins_earned += amount
	if in_match():
		current.coins += amount
	changed.emit()


func spend(amount: int) -> bool:
	if amount < 0 or coins < amount:
		return false
	coins -= amount
	changed.emit()
	return true


# --- Unlocks ------------------------------------------------------------------------

## In the in-match shop. "Debug: all weapons" unlocks everything.
func is_weapon_unlocked(weapon_name: String) -> bool:
	return Settings.debug_unlock_all or level() >= Config.weapon_unlock_level(weapon_name)


func is_map_unlocked(map_id: String) -> bool:
	return Settings.debug_unlock_all or level() >= Config.map_unlock_level(map_id)


# --- Armory: permanent upgrades and skins --------------------------------------------

## Permanent level (0..PERM_LEVELS) of `stat` ("damage", "mag", "reload").
func upgrade_level(weapon_name: String, stat: String) -> int:
	return upgrades.get(weapon_name, {}).get(stat, 0)


func buy_upgrade(weapon_name: String, stat: String) -> bool:
	var lv := upgrade_level(weapon_name, stat)
	var price := Config.perm_price(lv)
	if price < 0 or not is_weapon_unlocked(weapon_name) or not spend(price):
		return false
	if not upgrades.has(weapon_name):
		upgrades[weapon_name] = {}
	upgrades[weapon_name][stat] = lv + 1
	_check_achievements()
	save()
	changed.emit()
	return true


func owns_skin(weapon_name: String, skin: String) -> bool:
	return skin == "standard" or skin in skins_owned.get(weapon_name, [])


func skin_of(weapon_name: String) -> String:
	var skin: String = skins_equipped.get(weapon_name, "standard")
	return skin if Config.SKINS.has(skin) else "standard"


## Buys a skin and puts it on.
func buy_skin(weapon_name: String, skin: String) -> bool:
	if not Config.SKINS.has(skin) or owns_skin(weapon_name, skin) \
			or not is_weapon_unlocked(weapon_name) or not spend(Config.SKINS[skin].price):
		return false
	if not skins_owned.has(weapon_name):
		skins_owned[weapon_name] = []
	skins_owned[weapon_name].append(skin)
	stats.skins_bought += 1
	skins_equipped[weapon_name] = skin
	_check_achievements()
	save()
	changed.emit()
	return true


func equip_skin(weapon_name: String, skin: String) -> bool:
	if not owns_skin(weapon_name, skin):
		return false
	skins_equipped[weapon_name] = skin
	save()
	changed.emit()
	return true


# --- The match ----------------------------------------------------------------------

func in_match() -> bool:
	return not current.is_empty() and not current.ended


func start_match(map_id: String) -> void:
	refresh_daily()
	current = {"map": map_id, "xp": 0, "coins": 0, "start_level": level(),
			"stars_before": stars(map_id), "missions": [], "ended": false}


## An enemy the player killed (not nuked, not an exploder blowing itself up).
func on_kill(kind: String, headshot: bool) -> void:
	stats.kills += 1
	if headshot:
		stats.headshots += 1
	if kind == "brute" or kind == "boss":
		stats.kills_brute += 1
	if kind == "boss":
		stats.kills_boss += 1
	add_xp(Config.kill_xp(kind, headshot))
	for m: Dictionary in _missions():
		match m.type:
			"kills":
				_mission_progress(m, 1)
			"headshots":
				if headshot:
					_mission_progress(m, 1)
			"kill_kind":
				if kind == m.kind or (m.kind == "brute" and kind == "boss"):
					_mission_progress(m, 1)
	_check_achievements()


## Wave `wave` starts on the current map: the highest wave reached (stars).
func on_wave_started(wave: int) -> void:
	if not in_match():
		return
	var map_id: String = current.map
	var before := stars(map_id)
	best_wave[map_id] = maxi(best_wave.get(map_id, 0), wave)
	var now := stars(map_id)
	if now > before:
		star_earned.emit(map_id, now)
	for m: Dictionary in _missions():
		if m.type == "reach_wave" and m.map == map_id:
			_mission_progress(m, wave, true)
	_check_achievements()


func on_wave_cleared(wave: int) -> void:
	stats.waves_cleared += 1
	add_xp(Config.wave_xp(wave))
	for m: Dictionary in _missions():
		if m.type == "waves":
			_mission_progress(m, 1)
	save()


## The match is over (Game Over, or left through the pause menu): the match
## XP and coins. Returns the summary for the Game Over screen:
## {xp, coins, match_coins, start_level, level, stars_before, stars, missions}.
## Calling it again for the same match only returns the summary.
func end_match(waves: int, kills: int, cash_earned: int) -> Dictionary:
	if current.is_empty():
		return {}
	if not current.ended:
		var map_id: String = current.map
		add_xp(Config.match_xp(waves))
		var match_coins := Config.match_coins(waves, kills)
		add_coins(match_coins)
		current.match_coins = match_coins
		stats.matches += 1
		var played := Maps.base_id(map_id)  # either mode counts as playing the map
		maps_played[played] = maps_played.get(played, 0) + 1
		for m: Dictionary in _missions():
			match m.type:
				"matches":
					_mission_progress(m, 1)
				"cash":
					_mission_progress(m, cash_earned)
		_check_achievements()
		current.ended = true
		save()
	return {
		"xp": current.xp, "coins": current.coins, "match_coins": current.get("match_coins", 0),
		"start_level": current.start_level, "level": level(),
		"stars_before": current.stars_before, "stars": stars(current.map),
		"missions": current.missions.duplicate(),
	}


# --- Map stars ------------------------------------------------------------------------

## A map's stars in a mode: `map_id` is a save key (maps.gd save_key:
## "town" for Zombies, "combat_town" for Combat).
func stars(map_id: String) -> int:
	return Config.stars_for_wave(best_wave.get(map_id, 0))


## Stars on every map in every mode.
func total_stars() -> int:
	var total := 0
	for mode: Dictionary in Maps.MODES:
		for m: Dictionary in Maps.LIST:
			total += stars(Maps.save_key(m.id, mode.id))
	return total


# --- Daily missions ---------------------------------------------------------------------

## Today's date (local time), "YYYY-MM-DD".
func today() -> String:
	return date_override if date_override != "" else Time.get_date_string_from_system()


## Days since 1970 for a "YYYY-MM-DD" date.
static func day_number(date: String) -> int:
	return int(Time.get_unix_time_from_datetime_string(date + "T00:00:00") / 86400)


## New missions when the day has changed (local midnight).
func refresh_daily() -> void:
	var date := today()
	if daily.get("date", "") == date:
		return
	daily = {"date": date, "missions": make_missions(date)}
	save()
	changed.emit()


func missions() -> Array:
	refresh_daily()
	return daily.missions


func _missions() -> Array:
	return daily.get("missions", [])


## The day's missions: DAILY_MISSIONS different ones from MISSION_POOL,
## the same all day (seeded by the date).
func make_missions(date: String) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(date)
	var pool: Array = Config.MISSION_POOL.duplicate()
	var list := []
	while list.size() < Config.DAILY_MISSIONS and not pool.is_empty():
		var t: Dictionary = pool.pop_at(rng.randi_range(0, pool.size() - 1))
		var i := rng.randi_range(0, t.targets.size() - 1)
		var m := {"id": t.id, "type": t.type, "kind": t.get("kind", ""), "map": "",
				"target": t.targets[i], "reward": t.rewards[i], "progress": 0, "done": false}
		if t.type == "reach_wave":
			# On one unlocked map in one mode (m.map is the save key:
			# "town" for Zombies, "combat_town" for Combat).
			var open := Maps.LIST.filter(func(map: Dictionary) -> bool: return is_map_unlocked(map.id))
			var map: Dictionary = open[rng.randi_range(0, open.size() - 1)]
			var mode: String = Maps.MODES[rng.randi_range(0, Maps.MODES.size() - 1)].id
			m.map = Maps.save_key(map.id, mode)
			var where: String = map.get("short", map.name)
			if mode != Maps.ZOMBIES:
				where += " (%s)" % Maps.mode_info(mode).name
			m.text = t.text % [m.target, where]
		else:
			m.text = t.text % m.target
		list.append(m)
	return list


func _mission_progress(m: Dictionary, amount: int, highest := false) -> void:
	if m.done:
		return
	m.progress = maxi(m.progress, amount) if highest else m.progress + amount
	if m.progress < m.target:
		return
	m.progress = m.target
	m.done = true
	stats.missions_done += 1
	add_coins(m.reward)
	if in_match():
		current.missions.append(m.text)
	mission_completed.emit(m.text, m.reward)
	_check_achievements()


# --- Daily login reward -------------------------------------------------------------------

func login_reward_ready() -> bool:
	return login.last != today()


## The streak day (1-7) today's reward is for (or was, once claimed).
func login_day() -> int:
	if login.last == "":
		return 1
	var gap := day_number(today()) - day_number(login.last)
	if gap <= 0:
		return maxi(login.streak, 1)
	if gap == 1:
		return login.streak % Config.LOGIN_REWARDS.size() + 1
	return 1


## Claims today's reward. Returns the coins (0 if already claimed today).
func claim_login_reward() -> int:
	if not login_reward_ready():
		return 0
	var day := login_day()
	login.streak = day
	login.last = today()
	login.best = maxi(login.best, day)
	var reward := Config.login_reward(day)
	add_coins(reward)
	_check_achievements()
	save()
	return reward


# --- Achievements -------------------------------------------------------------------------

## The lifetime number an achievement checks (see progression_config.gd).
func stat_value(stat: String) -> int:
	match stat:
		"best_wave":
			var best := 0
			for id: String in best_wave:
				best = maxi(best, best_wave[id])
			return best
		"maps_played":
			return Maps.LIST.filter(func(m: Dictionary) -> bool: return maps_played.get(m.id, 0) > 0).size()
		"stars":
			return total_stars()
		"level":
			return level()
		"max_upgrade":
			var best := 0
			for w: String in upgrades:
				for s: String in upgrades[w]:
					best = maxi(best, upgrades[w][s])
			return best
		"login_streak":
			return login.best
	return stats.get(stat, 0)


func is_achieved(id: String) -> bool:
	return achievements.has(id)


func _check_achievements() -> void:
	for a: Dictionary in Config.ACHIEVEMENTS:
		if not achievements.has(a.id) and stat_value(a.stat) >= a.target:
			achievements[a.id] = true
			add_coins(a.reward)
			achievement_unlocked.emit(a.name, a.reward)


# --- Combat missions (missions/missions_config.gd) ----------------------------

## Best stars on a mission (0 = never cleared).
func mission_best(id: String) -> int:
	return int(mission_stars.get(id, 0))


## Missions unlock in order per map: slot 1 once the map is unlocked, each
## next slot once the one before it is cleared.
func is_mission_unlocked(id: String) -> bool:
	var m := Missions.find(id)
	if m.is_empty() or not is_map_unlocked(m.map):
		return false
	if m.slot <= 1:
		return true
	var before := Missions.in_slot(m.map, m.slot - 1)
	return before.is_empty() or mission_best(before.id) > 0


## A mission ended: stars = 0 (failed) .. 3. Pays the first-clear reward the
## first time, the repeat reward after that (nothing for a fail), keeps the
## best stars and saves. Returns {coins, xp, first, stars, best, best_before}.
func complete_mission(id: String, stars: int) -> Dictionary:
	var m := Missions.find(id)
	var before := mission_best(id)
	var result := {"coins": 0, "xp": 0, "first": false, "stars": stars, "best": before, "best_before": before}
	if m.is_empty() or stars <= 0:
		return result
	var first := before == 0
	var reward: Dictionary = m.first if first else m.repeat
	mission_stars[id] = maxi(before, stars)
	result.first = first
	result.best = mission_stars[id]
	result.coins = reward.coins
	result.xp = reward.xp
	add_coins(reward.coins)
	add_xp(reward.xp)
	save()
	changed.emit()
	return result


## Stars over every mission on a map (map id): (got, out of).
func mission_stars_on(map_id: String) -> Vector2i:
	var got := 0
	var ms := Missions.for_map(map_id)
	for m: Dictionary in ms:
		got += mission_best(m.id)
	return Vector2i(got, ms.size() * 3)

# --- Saving -----------------------------------------------------------------------------

## Back to a brand new player (Settings "Debug: reset progress"). Also forgets
## the best scores, and saves.
func reset_all() -> void:
	_set_defaults()
	current = {}
	refresh_daily()
	Settings.clear_bests()
	Settings.save_bests()
	save()
	changed.emit()


func _set_defaults() -> void:
	xp = 0
	coins = 0
	upgrades = {}
	skins_owned = {}
	skins_equipped = {}
	stats = {}
	for k: String in STAT_KEYS:
		stats[k] = 0
	achievements = {}
	best_wave = {}
	maps_played = {}
	mission_stars = {}
	daily = {}
	login = {"last": "", "streak": 0, "best": 0}


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", SAVE_VERSION)
	cfg.set_value("player", "xp", xp)
	cfg.set_value("player", "coins", coins)
	cfg.set_value("armory", "upgrades", upgrades)
	cfg.set_value("armory", "skins_owned", skins_owned)
	cfg.set_value("armory", "skins_equipped", skins_equipped)
	cfg.set_value("stats", "stats", stats)
	cfg.set_value("stats", "achievements", achievements)
	cfg.set_value("stats", "best_wave", best_wave)
	cfg.set_value("stats", "maps_played", maps_played)
	cfg.set_value("missions", "stars", mission_stars)
	cfg.set_value("daily", "daily", daily)
	cfg.set_value("daily", "login", login)
	cfg.save(save_path)


func load_progress() -> void:
	_set_defaults()
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		return
	xp = maxi(int(cfg.get_value("player", "xp", 0)), 0)
	coins = maxi(int(cfg.get_value("player", "coins", 0)), 0)
	upgrades = _dict(cfg.get_value("armory", "upgrades", {}))
	skins_owned = _dict(cfg.get_value("armory", "skins_owned", {}))
	skins_equipped = _dict(cfg.get_value("armory", "skins_equipped", {}))
	var saved_stats := _dict(cfg.get_value("stats", "stats", {}))
	for k: String in STAT_KEYS:
		stats[k] = int(saved_stats.get(k, 0))
	achievements = _dict(cfg.get_value("stats", "achievements", {}))
	best_wave = _dict(cfg.get_value("stats", "best_wave", {}))
	maps_played = _dict(cfg.get_value("stats", "maps_played", {}))
	mission_stars = _dict(cfg.get_value("missions", "stars", {}))
	# The old "Soldiers (Test)" mode (the Yard) is now Combat on the Yard.
	if best_wave.has("soldiers"):
		best_wave["combat_yard"] = maxi(int(best_wave.get("combat_yard", 0)), int(best_wave["soldiers"]))
		best_wave.erase("soldiers")
	if maps_played.has("soldiers"):
		maps_played["yard"] = int(maps_played.get("yard", 0)) + int(maps_played["soldiers"])
		maps_played.erase("soldiers")
	daily = _dict(cfg.get_value("daily", "daily", {}))
	if not daily.get("missions", null) is Array:
		daily = {}
	var saved_login := _dict(cfg.get_value("daily", "login", {}))
	login = {"last": str(saved_login.get("last", "")), "streak": int(saved_login.get("streak", 0)),
			"best": int(saved_login.get("best", 0))}


static func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}
