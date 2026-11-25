extends SceneTree
## Automated check of the in-match economy, run against the real main scene:
##   godot --headless --path . --script res://tools/test_economy.gd
## Cash, the shop (supplies, weapons, upgrades), armor, power-up drops,
## explosive barrels, the Game Over cash line and the debug unlock.
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## With `-- --shots <folder>` (and without --headless) it also saves
## screenshots of the HUD, the shop tabs, a power-up and a barrel blast.

const Economy := preload("res://economy.gd")
const Weapons := preload("res://weapon_stats.gd")

var main: Node
var player: Node
var hud: Node
var eco: Node
var shop: Node
var settings: Node
var failures := 0
var shots_dir := ""


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
		await process_frame  # power-ups and the HUD update in _process


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _run() -> void:
	settings = root.get_node("Settings")
	var debug_unlock: bool = settings.debug_unlock_all
	settings.debug_unlock_all = false
	# Every weapon unlocked for the shop (the level locks: test_progression.gd).
	# Progress uses a test save under a tool script.
	var progress: Node = root.get_node("Progress")
	progress.xp = preload("res://progression_config.gd").xp_for_level(15)
	await _load_main()

	_test_config()
	await _test_start()
	await _test_kill_cash()
	await _test_armor()
	await _test_wave_clear_and_shop()
	await _test_supplies()
	await _test_weapons_and_upgrades()
	await _test_ready_and_close()
	await _test_powerups()
	await _test_nuke()
	await _test_drops()
	await _test_barrels()
	await _test_game_over()
	await _test_debug_unlock()

	settings.debug_unlock_all = debug_unlock
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _load_main() -> void:
	paused = false
	change_scene_to_file("res://main.tscn")
	await frames(10)
	main = current_scene
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	eco = main.economy
	shop = hud.shop
	main.get_node("SpawnTimer").stop()
	_clear_enemies()
	await frames(5)


func _test_config() -> void:
	check(Economy.kill_cash("normal", false, 1) == Economy.KILL_CASH.normal, "a plain kill pays the type's cash")
	check(Economy.kill_cash("normal", true, 1) == Economy.KILL_CASH.normal + Economy.HEADSHOT_CASH, "headshots pay extra")
	check(Economy.kill_cash("normal", false, 3) == Economy.KILL_CASH.normal + 2 * Economy.STREAK_CASH, "streaks pay extra")
	check(Economy.kill_cash("normal", false, 20) == Economy.KILL_CASH.normal + Economy.STREAK_CASH_MAX, "streak bonus is capped")
	check(Economy.KILL_CASH.brute > Economy.KILL_CASH.normal and Economy.KILL_CASH.boss > Economy.KILL_CASH.brute, "big enemies pay more")
	check(Economy.upgraded_damage(1, 1) == 2 and Economy.upgraded_damage(2, 3) == 5, "damage upgrades add at least 1 a level")
	check(Economy.upgraded_mag(12, 1) == 15 and Economy.upgraded_reload(2.0, 3) < 1.2, "mag and reload upgrades")
	check(Economy.upgrade_price(0) < Economy.upgrade_price(1) and Economy.upgrade_price(1) < Economy.upgrade_price(2)
			and Economy.upgrade_price(3) == -1, "upgrade prices rise, 3 levels")
	for w: Dictionary in Weapons.LIST:
		check(w.name in Economy.START_WEAPONS or Economy.WEAPON_PRICES.has(w.name), "%s is a start weapon or sold" % w.name)


func _test_start() -> void:
	check(eco.cash == Economy.START_CASH and hud.cash_label.text == "$%d" % Economy.START_CASH,
			"starts with $%d on the HUD (%s)" % [Economy.START_CASH, hud.cash_label.text])
	check(player.has_weapon(0) and player.has_weapon(1) and not player.has_weapon(2), "starts with pistol + rifle")
	check(not hud.shop_button.visible, "no SHOP button during a wave")
	check(not hud.armor_bar.visible, "no armor bar without armor")
	await _screenshot("hud")


func _test_kill_cash() -> void:
	_put_player(Vector3(0, 0, 10))
	var e := _spawn("normal", player.global_position + Vector3(0, 0, -6))
	await frames(2)
	var before: int = eco.cash
	e.take_damage(10, e.global_position + Vector3.UP * 1.5, Vector3(0, 0, 1), true)
	check(eco.cash == before + Economy.KILL_CASH.normal + Economy.HEADSHOT_CASH,
			"headshot kill pays $%d (got $%d)" % [Economy.KILL_CASH.normal + Economy.HEADSHOT_CASH, eco.cash - before])
	check(hud._cash_pop.modulate.a > 0.5 and hud._cash_pop.text == "+$%d" % (eco.cash - before), "+$ popup shows (%s)" % hud._cash_pop.text)
	check(hud.cash_label.text == "$%d" % eco.cash, "HUD cash updates")
	# A second kill straight after: streak bonus.
	before = eco.cash
	var e2 := _spawn("brute", player.global_position + Vector3(2, 0, -6))
	await frames(2)
	e2.take_damage(100, e2.global_position + Vector3.UP, Vector3(0, 0, 1))
	check(eco.cash - before == Economy.KILL_CASH.brute + Economy.STREAK_CASH,
			"a quick second kill (a brute) pays its cash + the streak bonus (got $%d)" % (eco.cash - before))
	# Double Points.
	await seconds(3.0)  # streak over
	eco.active["double_points"] = 5.0
	before = eco.cash
	var e3 := _spawn("runner", player.global_position + Vector3(-2, 0, -6))
	await frames(2)
	e3.take_damage(100, e3.global_position + Vector3.UP, Vector3(0, 0, 1))
	check(eco.cash - before == Economy.KILL_CASH.runner * 2, "Double Points doubles kill cash ($%d)" % (eco.cash - before))
	eco.active.clear()
	check(eco.total_earned == eco.cash - Economy.START_CASH, "total earned adds up (%d)" % eco.total_earned)
	_clear_enemies()


func _test_armor() -> void:
	player.heal(100)
	player.add_armor(100)
	await frames(1)
	check(player.armor == Economy.MAX_ARMOR and hud.armor_bar.visible and hud.armor_bar.value == Economy.MAX_ARMOR,
			"armor shows as a full bar under health")
	check(hud.armor_bar.get_global_rect().position.y > hud.health_label.get_global_rect().position.y, "armor bar is under the health")
	player.take_damage(20)
	var absorbed := roundi(20 * Economy.ARMOR_ABSORB)
	check(player.armor == Economy.MAX_ARMOR - absorbed and player.health == 100 - (20 - absorbed),
			"armor absorbs %d of 20 (armor %d, health %d)" % [absorbed, player.armor, player.health])
	player.take_damage(500)  # through the rest of the armor
	await frames(1)
	check(player.armor == 0 and not hud.armor_bar.visible, "armor runs out and the bar hides")
	check(player.is_dead, "a big hit still kills through the armor")
	# Back to life for the rest of the tests.
	await _load_main()


func _test_wave_clear_and_shop() -> void:
	# Clear wave 1 by hand.
	main._to_spawn = 0
	main._alive = 1
	var before: int = eco.cash
	var e := _spawn("normal", Vector3(5, 0, 0))
	await frames(2)
	e.take_damage(100, e.global_position + Vector3.UP, Vector3(0, 0, 1))
	await frames(2)
	check(main.phase == main.Phase.BREAK, "wave cleared: break")
	check(eco.cash - before == Economy.KILL_CASH.normal + Economy.wave_cash(1),
			"wave 1 clear pays $%d bonus" % Economy.wave_cash(1))
	check(hud.shop_button.visible, "SHOP button shows during the break")
	var break_left: float = main._break_left
	hud.shop_button.pressed.emit()
	await frames(2)
	check(shop.visible and paused, "SHOP opens the shop and pauses the game")
	await seconds(1.0)
	check(is_equal_approx(main._break_left, break_left) or main._break_left >= break_left - 0.1,
			"the break countdown waits while the shop is open (%.2f -> %.2f)" % [break_left, main._break_left])
	await _screenshot("shop_supplies")
	# Touch-friendly: every shop button is big.
	var small := []
	for b: Node in shop.find_children("*", "Button", true, false):
		if (b as Control).is_visible_in_tree() and (b as Control).size.y < 54:
			small.append(b.text)
	check(small.is_empty(), "shop buttons are at least 54 px tall %s" % [small])
	var panel: Control = shop.get_child(1)
	var vp: Vector2 = shop.get_viewport_rect().size
	check(Rect2(Vector2.ZERO, vp).encloses(panel.get_global_rect()), "shop fits on screen (%s in %s)" % [panel.get_global_rect(), vp])


func _test_supplies() -> void:
	eco.cash = 10000
	shop.refresh()
	# Ammo: spend some first.
	player._mag[1] = 3
	player._reserve[1] = 10
	shop._supply_buttons.ammo.pressed.emit()
	check(player._mag[1] == player.mag_size(1) and player._reserve[1] == Weapons.LIST[1].max_reserve,
			"Ammo Refill fills the rifle (%d / %d)" % [player._mag[1], player._reserve[1]])
	check(eco.cash == 10000 - Economy.AMMO_PRICE, "ammo costs $%d" % Economy.AMMO_PRICE)
	var cash: int = eco.cash
	shop._supply_buttons.ammo.pressed.emit()
	check(eco.cash == cash and shop._note.text == "Already full", "can't buy ammo when full (%s)" % shop._note.text)
	var g: int = player.grenades
	shop._supply_buttons.grenade.pressed.emit()
	check(player.grenades == g + 1 and eco.cash == cash - Economy.GRENADE_PRICE, "buys a grenade")
	shop._supply_buttons.armor.pressed.emit()
	check(player.armor == Economy.MAX_ARMOR, "buys full armor")
	player.health = 40
	shop._supply_buttons.health.pressed.emit()
	check(player.health == player.MAX_HEALTH, "buys full health")
	eco.cash = 10
	shop.refresh()
	shop._supply_buttons.grenade.pressed.emit()
	check(eco.cash == 10 and shop._note.text == "Not enough cash", "not enough cash: nothing bought (%s)" % shop._note.text)
	check(shop._supply_buttons.grenade.modulate.a < 1.0, "too expensive items are dimmed")


func _test_weapons_and_upgrades() -> void:
	eco.cash = 20000
	shop.show_tab(1)
	await frames(1)
	await _screenshot("shop_weapons")
	check(shop._weapon_buttons[1].disabled and shop._weapon_buttons[1].text.contains("Owned"), "owned weapons show Owned")
	shop._weapon_buttons[2].pressed.emit()
	check(player.has_weapon(2) and eco.cash == 20000 - Economy.WEAPON_PRICES.Shotgun, "buys the shotgun for $%d" % Economy.WEAPON_PRICES.Shotgun)
	check(shop._weapon_buttons[2].disabled, "bought weapon shows Owned")
	shop.show_tab(2)
	shop.upgrade_weapon = 0
	shop.refresh()
	await frames(1)
	check(shop._upgrade_pick_buttons[0].visible and not shop._upgrade_pick_buttons[3].visible,
			"upgrades list only owned weapons")
	var dmg: int = player.weapon_damage(0)
	var cash: int = eco.cash
	shop._upgrade_buttons.damage.pressed.emit()
	check(player.weapon_damage(0) > dmg and eco.cash == cash - Economy.UPGRADE_PRICES[0],
			"pistol damage upgrade: %d -> %d for $%d" % [dmg, player.weapon_damage(0), Economy.UPGRADE_PRICES[0]])
	shop._upgrade_buttons.damage.pressed.emit()
	cash = eco.cash
	shop._upgrade_buttons.damage.pressed.emit()
	check(cash - eco.cash == Economy.UPGRADE_PRICES[2] and player.upgrade_level(0, "damage") == 3, "third level costs more")
	cash = eco.cash
	shop._upgrade_buttons.damage.pressed.emit()
	check(eco.cash == cash and shop._upgrade_buttons.damage.disabled, "damage maxed out after 3 levels")
	shop._upgrade_buttons.mag.pressed.emit()
	check(player.mag_size(0) == Economy.upgraded_mag(12, 1), "mag size upgrade (%d)" % player.mag_size(0))
	shop._upgrade_buttons.reload.pressed.emit()
	check(player.reload_time(0) < Weapons.LIST[0].reload_time, "reload speed upgrade (%.2f s)" % player.reload_time(0))
	await _screenshot("shop_upgrades")
	# The upgrade is used in game: a mag-upgraded reload fills to the new size.
	player._mag[0] = 1
	shop.close()
	await frames(2)
	check(not paused and not shop.visible, "Close: back to the break, unpaused")
	player.switch_to(0)
	await seconds(0.5)
	player.start_reload()
	await seconds(player.reload_time(0) + 0.2)
	check(player.ammo() == player.mag_size(0), "reload fills the bigger magazine (%d)" % player.ammo())


func _test_ready_and_close() -> void:
	check(main.phase == main.Phase.BREAK and hud.shop_button.visible, "still in the break after closing the shop")
	var w: int = main.wave
	hud.open_shop()
	await frames(1)
	shop._ready_button.pressed.emit()
	await frames(2)
	check(main.wave == w + 1 and main.phase == main.Phase.FIGHT, "READY starts the next wave right away")
	check(not shop.visible and not paused and not hud.shop_button.visible, "shop and SHOP button gone, game running")
	hud.open_shop()
	check(not shop.visible, "the shop can't be opened during a wave")
	main.get_node("SpawnTimer").stop()
	_clear_enemies()


func _test_powerups() -> void:
	_put_player(Vector3(0, 0, 10))
	# Max Ammo.
	player._mag[1] = 0
	player._reserve[1] = 0
	player.grenades = 0
	var collected := []
	eco.powerup_collected.connect(func(k: String) -> void: collected.append(k))
	var p: Node3D = eco.drop("max_ammo", player.global_position + Vector3(0, 0, -4))
	await frames(3)
	check(is_instance_valid(p) and p.visible, "a power-up appears on the ground")
	await _screenshot("powerup")
	_put_player(p.global_position)
	await frames(3)
	check(not is_instance_valid(p) or p.is_queued_for_deletion(), "walking into it picks it up")
	check(player._reserve[1] == Weapons.LIST[1].max_reserve and player.grenades == player.MAX_GRENADES, "Max Ammo refills ammo and grenades")
	check(hud.message_label.text == "MAX AMMO!", "announces it (%s)" % hud.message_label.text)
	check(eco._jingle.stream != null and collected.has("max_ammo"), "plays the power-up sound (and tells the HUD)")
	# Double Points: on the HUD with a timer.
	eco.collect("double_points")
	await frames(2)
	var label: Label = hud._powerup_labels.double_points
	check(label.visible and label.text.contains("20"), "Double Points shows on the HUD with its timer (%s)" % label.text)
	eco.active.double_points = 0.05
	await seconds(0.2)
	check(not label.visible and not eco.active.has("double_points"), "Double Points runs out")
	# Insta-Kill: a brute dies to one pistol bullet; the boss doesn't.
	eco.collect("insta_kill")
	check(player.insta_kill, "Insta-Kill is on")
	player.switch_to(0)
	await seconds(0.5)
	var b := _spawn("brute", player.global_position + Vector3(0, 0, -6))
	_aim_at(b.global_position + Vector3.UP * 1.0)
	await frames(2)
	await _tap_trigger()
	check(b.hp <= 0, "Insta-Kill: one pistol shot kills a brute (hp %d)" % b.hp)
	_clear_enemies()
	var boss := _spawn("boss", player.global_position + Vector3(0, 0, -8))
	_aim_at(boss.global_position + Vector3.UP * 1.4)
	await frames(2)
	await _tap_trigger()
	check(boss.hp > 0, "Insta-Kill doesn't one-shot the Boss (hp %d)" % boss.hp)
	_clear_enemies()
	eco.active.insta_kill = 0.05
	await seconds(0.2)
	check(not player.insta_kill, "Insta-Kill runs out")
	# Armor.
	player.armor = 0
	eco.collect("armor")
	check(player.armor == Economy.MAX_ARMOR, "Armor power-up fills armor")


func _test_nuke() -> void:
	_put_player(Vector3(0, 0, 10))
	var front := _spawn("normal", player.global_position + Vector3(0, 0, -8))
	var front2 := _spawn("soldier", player.global_position + Vector3(2, 0, -9))
	var behind := _spawn("normal", player.global_position + Vector3(0, 0, 6))
	var boss := _spawn("boss", player.global_position + Vector3(-3, 0, -10))
	await frames(3)
	var cash: int = eco.cash
	var kills: int = main.kills
	eco.collect("nuke")
	await frames(2)
	check(front.state == front.State.DEAD and front2.state == front2.State.DEAD, "Nuke kills the enemies on screen")
	check(behind.state != behind.State.DEAD, "an enemy behind the player survives")
	check(boss.state != boss.State.DEAD, "the Boss survives a Nuke")
	check(eco.cash == cash, "no cash for nuked enemies (+$%d)" % (eco.cash - cash))
	check(main.kills == kills + 2, "nuked enemies still count as kills")
	_clear_enemies()


func _test_drops() -> void:
	eco.new_wave()
	# The Boss always drops one; nuked enemies never do.
	var boss := _spawn("boss", Vector3(4, 0, 0))
	await frames(1)
	check(eco.maybe_drop(boss) != null, "the Boss drops a power-up")
	boss.no_reward = true
	check(eco.maybe_drop(boss) == null, "nothing from nuked enemies")
	boss.no_reward = false
	check(eco.maybe_drop(boss) != null and eco.maybe_drop(boss) == null,
			"at most %d drops a wave" % Economy.MAX_DROPS_PER_WAVE)
	_clear_enemies()
	# Drops vanish after their lifetime, blinking first.
	var p: Node3D = eco.drop("nuke", Vector3(20, 0, 20))
	p.time_left = Economy.POWERUP_BLINK - 0.5
	var seen_hidden := false
	for i in 40:
		await process_frame
		if is_instance_valid(p) and not p.visible:
			seen_hidden = true
	check(seen_hidden, "it blinks before it vanishes")
	p.time_left = 0.05
	await seconds(0.2)
	check(not is_instance_valid(p), "it vanishes after %d s" % Economy.POWERUP_LIFETIME)
	# Random kinds are all valid.
	var kinds := {}
	for i in 200:
		kinds[eco._random_kind()] = true
	check(kinds.size() == Economy.DROP_WEIGHTS.size(), "every power-up kind can drop (%s)" % [kinds.keys()])
	for c in main.get_children():
		if c.get_script() == preload("res://effects/powerup_drop.gd"):
			c.free()


func _test_barrels() -> void:
	var barrels := get_nodes_in_group("explosive_barrels")
	check(barrels.size() >= 3, "the map has explosive barrels (%d)" % barrels.size())
	# Two barrels side by side, with an enemy next to them.
	var spot := Vector3(0, 0, 5.5)
	var a: Node3D = preload("res://props/barrel_red.tscn").instantiate()
	var b: Node3D = preload("res://props/barrel_red.tscn").instantiate()
	main.add_child(a)
	main.add_child(b)
	a.global_position = spot
	b.global_position = spot + Vector3(2.5, 0, 0)
	_put_player(Vector3(0, 0, 12.3))
	player.heal(100)
	var e := _spawn("normal", spot + Vector3(-1.2, 0, 0))
	await frames(3)
	var cash: int = eco.cash
	# Shoot it with the pistol.
	player.switch_to(0)
	await seconds(0.5)
	_aim_at(a.global_position + Vector3.UP * 0.5)
	await frames(1)
	await frames(1)
	await _tap_trigger()
	if not a.exploded:
		await _tap_trigger()
	check(a.exploded and not a.get_node("Model").visible, "shooting a red barrel blows it up")
	check(e.state == e.State.DEAD, "the blast kills a zombie next to it")
	check(eco.cash > cash, "barrel kills pay cash")
	check(b._fuse or b.exploded, "the next barrel is set off...")
	await seconds(Economy.BARREL_CHAIN_DELAY.y + 0.1)
	check(b.exploded, "...in a chain reaction")
	check(player.health == 100, "the player 7 m away is safe")
	await _screenshot("barrel_blast")
	# Respawn with the next wave.
	main.start_wave(main.wave + 1)
	main.get_node("SpawnTimer").stop()
	await frames(2)
	check(not a.exploded and a.get_node("Model").visible and not a.get_node("CollisionShape3D").disabled,
			"exploded barrels come back with the next wave")
	check(a.hp == Economy.BARREL_HP, "with full health")
	# The player standing next to one gets hurt.
	_put_player(spot + Vector3(1.5, 0, 0))
	a.take_damage(10)
	await frames(2)
	check(player.health < 100, "a barrel next to the player hurts (%d)" % player.health)
	a.free()
	b.free()
	_clear_enemies()


func _test_game_over() -> void:
	player.armor = 0
	player.take_damage(1000)
	await frames(3)
	check(hud.game_over_panel.visible, "Game Over")
	check(hud.game_over_cash_label.text == "Cash earned: $%d" % eco.total_earned and eco.total_earned > 0,
			"Game Over shows the total cash earned (%s)" % hud.game_over_cash_label.text)
	check(hud.game_over_cash_label.is_visible_in_tree(), "and it is on screen")
	await _screenshot("game_over")


func _test_debug_unlock() -> void:
	settings.debug_unlock_all = true
	await _load_main()
	var all := true
	for i in Weapons.LIST.size():
		all = all and player.has_weapon(i)
	check(all, "Debug: all weapons gives every weapon")
	settings.debug_unlock_all = false
	var menu: Control = hud.settings_menu
	menu.open()
	await frames(1)
	var toggle: CheckButton = menu.get_node("%DebugUnlock")
	toggle.button_pressed = true
	check(settings.debug_unlock_all, "the settings screen has the debug toggle")
	toggle.button_pressed = false
	menu.visible = false


# --- Helpers ------------------------------------------------------------------

func _spawn(kind: String, pos: Vector3) -> Node3D:
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.kind = kind
	e.position = pos
	e.died.connect(main._on_enemy_died.bind(e))
	main.get_node("Enemies").add_child(e)
	e.speed_scale = 0.0
	var to: Vector3 = player.global_position - e.global_position
	e.rotation.y = atan2(-to.x, -to.z)
	return e


func _aim_at(target: Vector3) -> void:
	var from: Vector3 = player.camera.global_position
	var to := target - from
	player.rotation.y = atan2(-to.x, -to.z)
	player.head.rotation.x = atan2(to.y, Vector2(to.x, to.z).length())


func _put_player(pos: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


func _tap_trigger() -> void:
	while player._fire_cooldown > 0.0:
		await physics_frame
	player.touch_shoot = true
	await frames(2)
	player.touch_shoot = false
	await frames(2)


func _clear_enemies() -> void:
	for e in main.get_node("Enemies").get_children():
		e.free()


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)
