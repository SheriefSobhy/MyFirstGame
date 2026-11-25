extends SceneTree
## Automated check of the persistent progression (progress.gd,
## progression_config.gd), partly against the real scenes:
##   godot --headless --path . --script res://tools/test_progression.gd
## XP and levels, unlocks (shop weapons, maps), coins, the Armory (permanent
## upgrades, skins), daily missions and their midnight reset, the login
## streak, map stars, achievements, saving and loading, the menus and
## "Debug: reset progress".
## Uses its own save file (Progress does that under a tool script), and puts
## the best scores back afterwards. Prints PASS/FAIL per check and exits
## with code 1 if anything failed. With `-- --shots <folder>` (and without
## --headless) it also saves screenshots of the new screens.

const Config := preload("res://progression_config.gd")
const Weapons := preload("res://weapon_stats.gd")
const Maps := preload("res://maps.gd")
const Economy := preload("res://economy.gd")
const REAL_SAVE := "user://progress.cfg"

var progress: Node
var settings: Node
var failures := 0
var shots_dir := ""
var _saved_bests: Variant = null
var _real_save_time := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size():
		shots_dir = args[i + 1]
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _run() -> void:
	progress = root.get_node("Progress")
	settings = root.get_node("Settings")
	var debug_unlock: bool = settings.debug_unlock_all
	settings.debug_unlock_all = false
	_saved_bests = FileAccess.get_file_as_bytes(settings.SAVE_PATH) if FileAccess.file_exists(settings.SAVE_PATH) else null
	_real_save_time = FileAccess.get_modified_time(REAL_SAVE) if FileAccess.file_exists(REAL_SAVE) else 0
	check(progress.save_path == progress.TEST_SAVE_PATH, "tests save to their own file (%s)" % progress.save_path)

	_test_config()
	_test_levels()
	_test_unlocks()
	_test_armory_logic()
	_test_daily_missions()
	_test_login()
	_test_achievements()
	_test_save_load()
	await _test_match()
	await _test_permanent_upgrades_in_game()
	await _test_main_menu()
	await _test_armory_screen()
	await _test_achievements_screen()
	await _test_map_select()
	await _test_debug_reset()

	var now := FileAccess.get_modified_time(REAL_SAVE) if FileAccess.file_exists(REAL_SAVE) else 0
	check(now == _real_save_time, "the real progress save was not touched")
	settings.debug_unlock_all = debug_unlock
	progress.date_override = ""
	_restore_bests()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


# --- Pure logic ----------------------------------------------------------------

func _test_config() -> void:
	print("--- Config")
	check(Config.xp_for_level(1) == 0 and Config.xp_for_level(2) == Config.XP_BASE
			and Config.xp_for_level(3) == 2 * Config.XP_BASE + Config.XP_STEP, "XP curve: 0, 300, 750...")
	var rising := true
	for lv in range(1, Config.MAX_LEVEL):
		rising = rising and Config.xp_to_next(lv + 1) > Config.xp_to_next(lv)
		rising = rising and Config.level_for_xp(Config.xp_for_level(lv)) == lv
		rising = rising and Config.level_for_xp(Config.xp_for_level(lv + 1) - 1) == lv
	check(rising, "every level needs more XP than the last, levels 1-50 line up")
	check(Config.level_for_xp(100000000) == 50, "level is capped at 50")
	var expected := {"SMG": 2, "Shotgun": 3, "Revolver": 5, "AK Rifle": 7, "Sniper": 10, "LMG": 15}
	check(Config.WEAPON_UNLOCK_LEVEL == expected, "weapon unlock levels %s" % [Config.WEAPON_UNLOCK_LEVEL])
	var names := Weapons.LIST.map(func(w: Dictionary) -> String: return w.name)
	var known := true
	for n: String in Config.WEAPON_UNLOCK_LEVEL:
		known = known and n in names
	for w: String in Economy.START_WEAPONS:
		known = known and Config.weapon_unlock_level(w) == 1
	check(known, "unlock table names real weapons; start weapons are level 1")
	check(Config.map_unlock_level("yard") == 1 and Config.map_unlock_level("town") == 4
			and Config.map_unlock_level("warehouse") == 8, "maps unlock at 1 / 4 / 8")
	var ids := {}
	for a: Dictionary in Config.ACHIEVEMENTS:
		ids[a.id] = true
	check(ids.size() == Config.ACHIEVEMENTS.size() and ids.size() >= 15, "%d achievements, unique ids" % ids.size())
	var pool_ok := true
	for t: Dictionary in Config.MISSION_POOL:
		pool_ok = pool_ok and t.targets.size() == t.rewards.size()
	check(pool_ok and Config.MISSION_POOL.size() >= Config.DAILY_MISSIONS, "mission pool: one reward per target")
	check(Config.stars_for_wave(4) == 0 and Config.stars_for_wave(5) == 1 and Config.stars_for_wave(14) == 2
			and Config.stars_for_wave(15) == 3, "stars at waves 5 / 10 / 15")
	check(Config.match_coins(8, 100) > Config.match_coins(4, 40) and Config.match_coins(0, 0) == 0, "coins grow with waves and kills")
	check(Config.SKINS.has("desert") and Config.SKINS.has("black") and Config.SKINS.has("gold")
			and Config.SKINS.has("camo"), "Desert, Black, Gold and Camo skins")
	check(Config.PERM_PRICES.size() == Config.PERM_LEVELS and Config.PERM_LEVELS == 5, "5 permanent upgrade levels")


func _test_levels() -> void:
	print("--- Levels")
	progress.reset_all()
	var ups := []
	var on_up := func(lv: int, unlocks: Array) -> void: ups.append([lv, unlocks])
	progress.leveled_up.connect(on_up)
	check(progress.level() == 1 and progress.level_xp() == Vector2i(0, 300), "a new player is level 1 (0 / 300 XP)")
	progress.add_xp(Config.xp_for_level(3) + 10)
	check(progress.level() == 3 and progress.level_xp() == Vector2i(10, Config.xp_to_next(3)), "XP for two levels: level 3")
	check(ups.size() == 2 and ups[0][0] == 2 and ups[0][1] == ["SMG"] and ups[1][1] == ["Shotgun"],
			"level-up signal per level, with its unlocks %s" % [ups])
	check(progress.coins == 2 * Config.LEVEL_UP_COINS, "level-ups pay %d coins each" % Config.LEVEL_UP_COINS)
	check(progress.unlocks_at(4) == ["Abandoned Town"] and progress.unlocks_at(8) == ["Warehouse Night"], "maps unlock at 4 and 8")
	progress.leveled_up.disconnect(on_up)


func _test_unlocks() -> void:
	print("--- Unlocks")
	progress.reset_all()
	check(progress.is_weapon_unlocked("Pistol") and progress.is_weapon_unlocked("Assault Rifle")
			and not progress.is_weapon_unlocked("SMG"), "level 1: only the start weapons")
	check(progress.is_map_unlocked("yard") and not progress.is_map_unlocked("town"), "level 1: only the yard")
	progress.xp = Config.xp_for_level(5)
	check(progress.is_weapon_unlocked("Revolver") and not progress.is_weapon_unlocked("AK Rifle")
			and progress.is_map_unlocked("town") and not progress.is_map_unlocked("warehouse"), "level 5: revolver and the town")
	settings.debug_unlock_all = true
	check(progress.is_weapon_unlocked("LMG") and progress.is_map_unlocked("warehouse"), "Debug: all weapons unlocks everything")
	settings.debug_unlock_all = false


func _test_armory_logic() -> void:
	print("--- Armory")
	progress.reset_all()
	progress.coins = 10000
	check(not progress.buy_upgrade("SMG", "damage") and progress.coins == 10000, "can't upgrade a locked weapon")
	var spent := 0
	var bought := true
	for i in Config.PERM_LEVELS:
		bought = bought and progress.buy_upgrade("Pistol", "damage")
		spent += Config.PERM_PRICES[i]
	check(bought and progress.upgrade_level("Pistol", "damage") == 5 and progress.coins == 10000 - spent + _reward("gunsmith"),
			"5 levels cost %d coins in all" % spent)
	check(not progress.buy_upgrade("Pistol", "damage"), "maxed at 5")
	check(progress.is_achieved("gunsmith"), "maxing an upgrade unlocks Gunsmith")
	var coins: int = progress.coins
	check(progress.buy_skin("Pistol", "gold") and progress.skin_of("Pistol") == "gold"
			and progress.coins == coins - Config.SKINS.gold.price + _reward("fashion"),
			"buying a skin equips it (and the first one is an achievement)")
	check(not progress.buy_skin("Pistol", "gold"), "can't buy a skin twice")
	check(progress.equip_skin("Pistol", "standard") and progress.skin_of("Pistol") == "standard", "back to standard")
	check(progress.equip_skin("Pistol", "gold"), "owned skins can be put back on")
	check(not progress.equip_skin("Pistol", "camo"), "can't wear a skin you don't own")
	progress.coins = 10
	check(not progress.buy_skin("Assault Rifle", "desert") and progress.coins == 10, "not enough coins: no skin")


func _test_daily_missions() -> void:
	print("--- Daily missions")
	progress.reset_all()
	progress.date_override = "2026-11-25"
	progress.refresh_daily()
	var ms: Array = progress.missions()
	var ids := {}
	for m: Dictionary in ms:
		ids[m.id] = true
	check(ms.size() == 3 and ids.size() == 3, "3 different missions a day (%s)" % [ms.map(func(m: Dictionary) -> String: return m.text)])
	var again: Array = progress.make_missions("2026-11-25")
	check(again.map(func(m: Dictionary) -> String: return m.text) == ms.map(func(m: Dictionary) -> String: return m.text),
			"the same date gives the same missions")
	var texts := {}
	for d in 10:
		for m: Dictionary in progress.make_missions("2026-12-%02d" % (d + 1)):
			texts[m.id] = true
			if m.type == "reach_wave":
				check(m.map == "yard", "reach-wave missions only use unlocked maps (%s)" % m.text)
	check(texts.size() >= 6, "different days draw different missions (%d kinds in 10 days)" % texts.size())

	# Known missions, to count them up.
	progress.daily.missions = [
		{"id": "kills", "type": "kills", "kind": "", "map": "", "text": "Kill 3 enemies", "target": 3, "reward": 100, "progress": 0, "done": false},
		{"id": "brutes", "type": "kill_kind", "kind": "brute", "map": "", "text": "Kill 2 Brutes", "target": 2, "reward": 150, "progress": 0, "done": false},
		{"id": "reach", "type": "reach_wave", "kind": "", "map": "yard", "text": "Reach wave 4 on Yard", "target": 4, "reward": 120, "progress": 0, "done": false},
		{"id": "headshots", "type": "headshots", "kind": "", "map": "", "text": "Get 2 headshots", "target": 2, "reward": 90, "progress": 0, "done": false},
	]
	var done := []
	var on_done := func(text: String, reward: int) -> void: done.append([text, reward])
	progress.mission_completed.connect(on_done)
	progress.start_match("yard")
	progress.on_kill("normal", true)
	progress.on_kill("brute", false)
	progress.end_match(1, 2, 100)
	check(progress.daily.missions[0].progress == 2 and not progress.daily.missions[0].done, "progress carries over after a match (2 / 3)")
	progress.start_match("town")
	progress.on_wave_started(6)
	check(progress.daily.missions[2].progress == 0, "reaching wave 6 on another map doesn't count")
	var coins: int = progress.coins
	progress.on_kill("boss", true)
	check(progress.daily.missions[0].done and progress.daily.missions[1].done and progress.daily.missions[3].done,
			"the next match finishes them (the Boss counts as a Brute)")
	check(progress.coins - coins >= 100 + 150 + 90, "completed missions pay their coins (+%d)" % (progress.coins - coins))
	check(done.size() == 3 and done[0][0] == "Kill 3 enemies", "mission complete signal %s" % [done])
	progress.end_match(6, 1, 0)
	progress.start_match("yard")
	progress.on_wave_started(4)
	check(progress.daily.missions[2].done, "reach wave 4 on the yard")
	progress.end_match(3, 0, 0)
	check(progress.stats.missions_done == 4, "missions done are counted (%d)" % progress.stats.missions_done)
	progress.mission_completed.disconnect(on_done)

	# Midnight: new missions, progress back to zero.
	progress.date_override = "2026-11-26"
	progress.refresh_daily()
	var fresh := true
	for m: Dictionary in progress.missions():
		fresh = fresh and m.progress == 0 and not m.done
	check(progress.daily.date == "2026-11-26" and fresh, "a new day: new missions, nothing done yet")


func _test_login() -> void:
	print("--- Login reward")
	progress.reset_all()
	progress.date_override = "2026-11-01"
	check(progress.login_reward_ready() and progress.login_day() == 1, "first day: reward ready, day 1")
	check(progress.claim_login_reward() == Config.LOGIN_REWARDS[0] and progress.coins == Config.LOGIN_REWARDS[0], "day 1 pays %d" % Config.LOGIN_REWARDS[0])
	check(not progress.login_reward_ready() and progress.claim_login_reward() == 0, "only once a day")
	progress.date_override = "2026-11-02"
	check(progress.login_day() == 2 and progress.claim_login_reward() == Config.LOGIN_REWARDS[1], "next day: day 2")
	progress.date_override = "2026-11-04"
	check(progress.login_day() == 1, "a missed day starts the streak again")
	var rewards := []
	for d in 8:
		progress.date_override = "2026-11-%02d" % (10 + d)
		rewards.append(progress.claim_login_reward())
	check(rewards == Config.LOGIN_REWARDS + [Config.LOGIN_REWARDS[0]], "7-day streak, then round again %s" % [rewards])
	check(progress.login.best == 7 and progress.is_achieved("dedicated"), "a 7-day streak is the Dedicated achievement")
	progress.date_override = "2026-11-30"
	progress.daily = {}
	progress.login.last = "2026-11-29"
	progress.login.streak = 7
	check(progress.login_day() == 1, "after day 7 comes day 1")


func _test_achievements() -> void:
	print("--- Achievements")
	progress.reset_all()
	var got := []
	var on_got := func(title: String, reward: int) -> void: got.append(title)
	progress.achievement_unlocked.connect(on_got)
	progress.start_match("yard")
	progress.on_kill("normal", false)
	check(progress.is_achieved("first_blood") and got == ["First Blood"], "first kill: First Blood")
	progress.on_wave_started(5)
	check(progress.is_achieved("survivor") and progress.stars("yard") == 1, "wave 5: Survivor and a star")
	progress.on_kill("boss", false)
	check(progress.is_achieved("boss_slayer"), "the Boss: Boss Slayer")
	progress.end_match(5, 2, 0)
	for m: Dictionary in Maps.LIST:
		progress.start_match(m.id)
		progress.end_match(0, 0, 0)
	check(progress.is_achieved("globetrotter"), "every map played: Globetrotter")
	progress.best_wave = {"yard": 15, "town": 15, "warehouse": 15}
	progress._check_achievements()
	check(progress.total_stars() == 9 and progress.is_achieved("star_collector"), "9 stars: Star Collector")
	check(not progress.is_achieved("legend") and progress.stat_value("level") == progress.level(), "Legend needs level 50")
	progress.achievement_unlocked.disconnect(on_got)


func _test_save_load() -> void:
	print("--- Saving")
	progress.reset_all()
	progress.xp = 12345
	progress.coins = 678
	progress.upgrades = {"Pistol": {"mag": 3}}
	progress.skins_owned = {"Pistol": ["camo"]}
	progress.skins_equipped = {"Pistol": "camo"}
	progress.best_wave = {"town": 11}
	progress.achievements = {"first_blood": true}
	progress.stats.kills = 99
	progress.login = {"last": "2026-11-20", "streak": 3, "best": 4}
	progress.save()
	var copy: Node = load("res://progress.gd").new()
	copy.save_path = progress.save_path
	copy.load_progress()
	check(copy.xp == 12345 and copy.coins == 678 and copy.level() == progress.level(), "XP, level and coins load back")
	check(copy.upgrade_level("Pistol", "mag") == 3 and copy.skin_of("Pistol") == "camo"
			and copy.owns_skin("Pistol", "camo"), "upgrades and skins load back")
	check(copy.stars("town") == 2 and copy.is_achieved("first_blood") and copy.stats.kills == 99, "stars, achievements, stats load back")
	check(copy.login.streak == 3 and copy.daily.date == progress.daily.date
			and copy.daily.missions.size() == 3, "login streak and today's missions load back")
	copy.free()
	# A broken file is ignored.
	var f := FileAccess.open(progress.save_path, FileAccess.WRITE)
	f.store_string("[player]\nxp=\"lots\"\ncoins=-5\n[armory]\nupgrades=7\n")
	f.close()
	copy = load("res://progress.gd").new()
	copy.save_path = progress.save_path
	copy.load_progress()
	check(copy.coins == 0 and copy.upgrades.is_empty(), "a damaged save loads as a fresh start")
	copy.free()


# --- In the game -----------------------------------------------------------------

func _load_scene(path: String) -> Node:
	paused = false
	change_scene_to_file(path)
	await frames(10)
	return current_scene


func _spawn(main: Node, kind: String, pos: Vector3) -> Node3D:
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.kind = kind
	e.position = pos
	e.died.connect(main._on_enemy_died.bind(e))
	main.get_node("Enemies").add_child(e)
	e.speed_scale = 0.0
	return e


func _test_match() -> void:
	print("--- A match")
	progress.reset_all()
	progress.date_override = "2026-11-25"
	progress.refresh_daily()
	var main := await _load_scene("res://main.tscn")
	var hud: Node = main.hud
	var player: Node = main.player
	main.get_node("SpawnTimer").stop()
	for e in main.get_node("Enemies").get_children():
		e.free()
	check(progress.in_match() and progress.current.map == "yard" and progress.best_wave.get("yard", 0) == 1,
			"the match counts (wave 1 reached on the yard)")

	# A headshot kill: XP.
	var xp: int = progress.xp
	var e := _spawn(main, "normal", player.global_position + Vector3(0, 0, -6))
	await frames(2)
	e.take_damage(100, e.global_position + Vector3.UP * 1.5, Vector3(0, 0, 1), true)
	check(progress.xp - xp == Config.kill_xp("normal", true), "headshot kill: +%d XP" % (progress.xp - xp))
	check(progress.stats.kills == 1 and progress.stats.headshots == 1, "kills and headshots counted")
	check(progress.is_achieved("first_blood"), "First Blood in a real match")
	await frames(1)
	check(hud._toast_box.get_child_count() > 0 and (hud._toast_box.get_child(0) as Label).text.contains("First Blood"),
			"the achievement pops up on the HUD")

	# Shop: weapons above your level are locked and show the level.
	var shop: Node = hud.shop
	main.economy.cash = 99999
	shop.show_tab(1)
	var smg := 4
	check(Weapons.LIST[smg].name == "SMG", "SMG is weapon 5")
	check(shop._weapon_buttons[smg].disabled and shop._weapon_buttons[smg].text.contains("Level 2"),
			"locked SMG in the shop: '%s'" % shop._weapon_buttons[smg].text.replace("\n", " / "))
	check(not main.economy.buy_weapon(smg) and not player.has_weapon(smg), "a locked weapon can't be bought")
	await _screenshot("shop_locked")

	# Level up mid-match: popup, and the SMG unlocks.
	progress.add_xp(Config.xp_for_level(2) - progress.xp)
	await frames(2)
	check(hud.level_up_panel.visible and hud._level_up_title.text.contains("2") and hud._level_up_sub.text.contains("SMG"),
			"level-up popup: '%s' / '%s'" % [hud._level_up_title.text, hud._level_up_sub.text.replace("\n", " / ")])
	await _screenshot("level_up")
	shop.refresh()
	check(not shop._weapon_buttons[smg].disabled and main.economy.buy_weapon(smg) and player.has_weapon(smg),
			"after the level-up the SMG can be bought")

	# Clear wave 1: wave XP.
	main._to_spawn = 0
	main._alive = 1
	xp = progress.xp
	var e2 := _spawn(main, "runner", player.global_position + Vector3(2, 0, -6))
	await frames(2)
	e2.take_damage(100, e2.global_position + Vector3.UP, Vector3(0, 0, 1))
	await frames(2)
	check(main.phase == main.Phase.BREAK and progress.xp - xp == Config.kill_xp("runner", false) + Config.wave_xp(1),
			"wave 1 cleared: kill + wave XP (+%d)" % (progress.xp - xp))

	# Wave 5: a star.
	main.start_wave(5)
	main.get_node("SpawnTimer").stop()
	await frames(1)
	check(progress.stars("yard") == 1, "reaching wave 5 earns the yard's first star")
	var star_toast := false
	for t: Label in hud._toast_box.get_children():
		star_toast = star_toast or t.text.contains("star")
	check(star_toast, "the star pops up on the HUD")

	# Game Over: XP and coins for the match.
	var coins_before: int = progress.coins
	var start_xp: int = progress.current.xp
	main.waves_survived = 4
	player.take_damage(1000)
	await frames(3)
	var summary: Dictionary = progress.end_match(4, main.kills, 0)
	check(not progress.in_match() and summary.match_coins == Config.match_coins(4, main.kills),
			"Game Over pays %d coins for 4 waves, %d kills" % [summary.match_coins, main.kills])
	check(progress.coins - coins_before >= summary.match_coins, "the coins are added (+%d)" % (progress.coins - coins_before))
	check(summary.xp >= start_xp + Config.match_xp(4), "match-end XP added (%d)" % summary.xp)
	check(hud.game_over_progress_label.text.contains("+%d XP" % summary.xp)
			and hud.game_over_progress_label.text.contains("+%d coins" % summary.coins),
			"Game Over shows the XP and coins ('%s')" % hud.game_over_progress_label.text.replace("\n", " / "))
	check(hud.game_over_level_label.text.begins_with("Level %d" % progress.level()) and hud.game_over_level_label.text.contains("LEVEL UP"),
			"and the level ('%s')" % hud.game_over_level_label.text)
	check(hud.game_over_progress_label.text.contains("Unlocked: SMG"), "and what the level-up unlocked")
	check(not hud.level_up_panel.visible, "the LEVEL UP popup doesn't cover the Game Over screen")
	check(hud.game_over_progress_label.is_visible_in_tree() and hud.game_over_level_bar.is_visible_in_tree(), "on screen")
	var panel: Control = hud.game_over_panel.get_node("Box")
	var vp: Vector2 = hud.get_viewport().get_visible_rect().size
	check(Rect2(Vector2.ZERO, vp).encloses(panel.get_global_rect()), "Game Over fits on screen")
	await _screenshot("game_over")
	var matches: int = progress.stats.matches
	progress.end_match(4, 10, 0)
	check(progress.stats.matches == matches, "the same match isn't paid twice")
	paused = false


func _test_permanent_upgrades_in_game() -> void:
	print("--- Armory upgrades in a match")
	progress.reset_all()
	progress.coins = 100000
	for i in 5:
		progress.buy_upgrade("Pistol", "damage")
	progress.buy_upgrade("Pistol", "mag")
	progress.buy_upgrade("Pistol", "mag")
	progress.buy_upgrade("Pistol", "reload")
	progress.buy_skin("Pistol", "gold")
	var main := await _load_scene("res://main.tscn")
	var player: Node = main.player
	main.get_node("SpawnTimer").stop()
	var w: Dictionary = Weapons.LIST[0]
	check(is_equal_approx(player.stat_value(0, "damage"), w.damage * (1.0 + 5 * Config.PERM_DAMAGE)),
			"pistol damage %.2f (+40%%)" % player.stat_value(0, "damage"))
	var rolls := {}
	var total := 0
	for i in 400:
		var d: int = player.roll_damage(0)
		rolls[d] = true
		total += d
	var mean := total / 400.0
	check(rolls.keys().all(func(d: int) -> bool: return d == 2 or d == 3) and absf(mean - 2.8) < 0.15,
			"fractional damage: 2 or 3, average %.2f" % mean)
	check(player.mag_size(0) == ceili(w.mag_size * (1.0 + 2 * Config.PERM_MAG)) and player.ammo() == player.mag_size(0),
			"magazine %d and the match starts with it full" % player.mag_size(0))
	check(is_equal_approx(player.reload_time(0), w.reload_time * (1.0 - Config.PERM_RELOAD)), "reload %.2f s" % player.reload_time(0))
	# The shop's upgrades stack on top.
	player.upgrade(0, "damage")
	check(is_equal_approx(player.stat_value(0, "damage"), Economy.upgraded_damage(w.damage, 1) * 1.4), "shop upgrades stack on top")
	var shop: Node = main.hud.shop
	shop.upgrade_weapon = 0
	shop.show_tab(2)
	check(shop._upgrade_buttons.damage.text.contains("4.2 →"), "the shop shows the real numbers ('%s')" % shop._upgrade_buttons.damage.text.replace("\n", " / "))
	# The gold skin is on the first-person pistol.
	var gold := false
	for mi: MeshInstance3D in player._views[0].find_children("*", "MeshInstance3D", true, false):
		var m := mi.get_surface_override_material(0)
		gold = gold or (m is StandardMaterial3D and is_equal_approx((m as StandardMaterial3D).metallic, 1.0))
	check(gold, "the equipped Gold skin is on the pistol")
	var plain := true
	for mi: MeshInstance3D in player._views[1].find_children("*", "MeshInstance3D", true, false):
		plain = plain and mi.get_surface_override_material(0) == null
	check(plain, "the rifle keeps its standard look")
	progress.end_match(0, 0, 0)


func _test_main_menu() -> void:
	print("--- Main menu")
	progress.reset_all()
	progress.date_override = "2026-11-25"
	progress.add_xp(Config.xp_for_level(3) + 40)
	var menu := await _load_scene("res://ui/main_menu.tscn")
	check(menu.login_popup.visible and menu.login_claim_button.text.contains("%d" % Config.LOGIN_REWARDS[0]),
			"first visit of the day: the login reward ('%s')" % menu.login_claim_button.text)
	await _screenshot("login_reward")
	var coins: int = progress.coins
	menu.login_claim_button.pressed.emit()
	await frames(2)
	check(not menu.login_popup.visible and progress.coins == coins + Config.LOGIN_REWARDS[0], "Claim pays and closes it")
	check(menu.level_label.text == "Level 3" and menu.xp_label.text == "40 / %d XP" % Config.xp_to_next(3)
			and is_equal_approx(menu.xp_bar.value, 40.0), "level bar: '%s' '%s'" % [menu.level_label.text, menu.xp_label.text])
	check(menu.coins_label.text == "%d coins" % progress.coins, "coins on the menu (%s)" % menu.coins_label.text)
	check(menu.mission_list.get_child_count() == 3, "three daily missions listed")
	check(menu.armory_button.visible and menu.achievements_button.visible, "Armory and Achievements buttons")
	var box: Control = menu.get_node("Box")
	check(Rect2(Vector2.ZERO, menu.get_viewport_rect().size).encloses(box.get_global_rect()), "menu fits on screen (%s)" % box.get_global_rect())
	await _screenshot("main_menu")
	# Coming back the same day: no popup.
	menu = await _load_scene("res://ui/main_menu.tscn")
	check(not menu.login_popup.visible, "no second login reward the same day")


func _test_armory_screen() -> void:
	print("--- Armory screen")
	var menu := current_scene
	progress.coins = 5000
	menu.armory_button.pressed.emit()
	await frames(2)
	var armory: Node = menu.armory
	check(armory.visible, "Armory opens from the main menu")
	armory.select_weapon(4)  # SMG: level 2, unlocked at level 3
	armory.select_weapon(6)  # LMG: level 15
	check(armory._upgrade_buttons.damage.disabled and armory._lock_label.text.contains("15"), "a locked weapon: '%s'" % armory._lock_label.text)
	armory.select_weapon(0)
	var coins: int = progress.coins
	armory._upgrade_buttons.damage.pressed.emit()
	check(progress.upgrade_level("Pistol", "damage") == 1 and progress.coins == coins - Config.PERM_PRICES[0],
			"buy a damage upgrade for %d coins" % Config.PERM_PRICES[0])
	check(armory._upgrade_buttons.damage.text.contains("1 / 5") and armory._coins_label.text == "%d coins" % progress.coins,
			"the screen updates ('%s')" % armory._upgrade_buttons.damage.text.replace("\n", " / "))
	await _screenshot("armory_upgrades")
	armory.show_tab(1)
	armory._skin_buttons.camo.pressed.emit()
	await frames(2)
	check(progress.skin_of("Pistol") == "camo" and armory._skin_buttons.camo.text.contains("Equipped"), "buy and wear Camo")
	var camo := false
	for mi: MeshInstance3D in armory.preview_model().find_children("*", "MeshInstance3D", true, false):
		var m := mi.get_surface_override_material(0)
		camo = camo or (m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture != null)
	check(camo, "the preview shows the camo")
	await _screenshot("armory_skins")
	armory._skin_buttons.standard.pressed.emit()
	check(progress.skin_of("Pistol") == "standard" and armory._skin_buttons.camo.text.contains("Owned"), "switch back; camo stays owned")
	var small := []
	for b: Node in armory.find_children("*", "Button", true, false):
		if (b as Control).is_visible_in_tree() and (b as Control).size.y < 48:
			small.append(b.text)
	check(small.is_empty(), "Armory buttons are touch-sized %s" % [small])
	var panel: Control = armory.get_child(1)
	check(Rect2(Vector2.ZERO, armory.get_viewport_rect().size).encloses(panel.get_global_rect()), "Armory fits on screen")
	armory._back_button.pressed.emit()
	check(not armory.visible, "Back closes the Armory")


func _test_achievements_screen() -> void:
	print("--- Achievements screen")
	var menu := current_scene
	menu.achievements_button.pressed.emit()
	await frames(2)
	var screen: Node = menu.achievements
	check(screen.visible and screen.rows.size() == Config.ACHIEVEMENTS.size(), "one row per achievement")
	var done: int = screen.unlocked_count()
	check(screen._title.text.contains("%d / %d" % [done, Config.ACHIEVEMENTS.size()]), "header counts them ('%s')" % screen._title.text)
	check(screen.rows.rising_star.count.text == "%d / 10" % progress.level(), "progress shown (%s)" % screen.rows.rising_star.count.text)
	check(screen.rows.first_blood.reward.text == ("DONE" if progress.is_achieved("first_blood") else "+25 coins"), "reward or DONE")
	await _screenshot("achievements")
	screen.close()


func _test_map_select() -> void:
	print("--- Map select")
	progress.best_wave = {"yard": 11}
	var menu := current_scene
	menu.play_button.pressed.emit()
	await frames(5)
	var select := current_scene
	check(select.name == "MapSelect", "Play opens the map selection")
	var yard_stars: Node = select.play_buttons.yard.get_parent().find_child("Stars", true, false)
	check(yard_stars != null and yard_stars.filled == 2, "yard card: 2 stars for wave 11")
	var town_stars: Node = select.play_buttons.town.get_parent().find_child("Stars", true, false)
	check(town_stars.filled == 0, "town card: no stars yet")
	check(select.play_buttons.town.disabled and select.play_buttons.town.text == "Locked: Level 4"
			and select.play_buttons.warehouse.text == "Locked: Level 8", "locked maps show their level")
	await _screenshot("map_select")
	select.play_buttons.town.pressed.emit()
	await frames(3)
	check(current_scene == select, "a locked map doesn't load")
	progress.xp = Config.xp_for_level(4)
	select = await _load_scene("res://ui/map_select.tscn")
	check(not select.play_buttons.town.disabled and select.play_buttons.town.text == "Play", "level 4 opens the town")


func _test_debug_reset() -> void:
	print("--- Debug: reset progress")
	var menu := await _load_scene("res://ui/main_menu.tscn")
	progress.coins = 999
	progress.xp = 50000
	menu.settings_button.pressed.emit()
	await frames(1)
	var button: Button = menu.settings_menu.get_node("%DebugReset")
	check(button.is_visible_in_tree(), "the settings screen has Debug: reset progress")
	check(menu.settings_menu.get_node("%DebugUnlock").is_visible_in_tree(), "and still Debug: all weapons")
	button.pressed.emit()
	check(progress.coins == 999, "one press only asks ('%s')" % button.text)
	button.pressed.emit()
	await frames(1)
	check(progress.coins == 0 and progress.level() == 1 and progress.achievements.is_empty()
			and progress.missions().size() == 3, "the second press resets everything")
	check(menu.level_label.text == "Level 1" and menu.coins_label.text == "0 coins", "the menu updates")
	await _screenshot("settings")
	menu.settings_menu.close()


func _reward(id: String) -> int:
	for a: Dictionary in Config.ACHIEVEMENTS:
		if a.id == id:
			return a.reward
	return 0


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)


func _restore_bests() -> void:
	if _saved_bests == null:
		DirAccess.remove_absolute(settings.SAVE_PATH)
	else:
		var f := FileAccess.open(settings.SAVE_PATH, FileAccess.WRITE)
		f.store_buffer(_saved_bests)
		f.close()
	settings.clear_bests()
	settings._load()
