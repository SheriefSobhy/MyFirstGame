extends Node
## The in-match economy (main.gd adds it): cash, the shop's purchases, power-up
## drops and the active power-ups. Every number comes from economy.gd.
##
## Cash: kills (more for headshots, streaks and big enemies), and a bonus for
## each cleared wave. Double Points doubles kill cash. Nuke kills pay nothing.
## The shop (ui/shop_menu.gd) calls the buy_* functions; each returns true if
## it bought something (enough cash, and it wasn't already full / owned / maxed).

signal cash_changed(cash: int, gained: int)   # gained < 0 when spending
signal powerup_collected(kind: String)

const Economy := preload("res://economy.gd")
const Weapons := preload("res://weapon_stats.gd")
const PowerupDrop := preload("res://effects/powerup_drop.gd")
const Synth := preload("res://effects/synth_sounds.gd")

var cash := Economy.START_CASH
## All the cash earned this match (for the Game Over screen).
var total_earned := 0
## Timed power-ups running now: kind -> seconds left.
var active := {}

var player: Node
var _drops_this_wave := 0
var _jingle: AudioStreamPlayer


func _ready() -> void:
	_jingle = AudioStreamPlayer.new()
	_jingle.stream = Synth.powerup()
	add_child(_jingle)


func _process(delta: float) -> void:
	for kind: String in active.keys():
		active[kind] -= delta
		if active[kind] <= 0.0:
			active.erase(kind)
			if kind == "insta_kill" and player:
				player.insta_kill = false


# --- Cash ----------------------------------------------------------------------

func earn(amount: int) -> void:
	if amount <= 0:
		return
	cash += amount
	total_earned += amount
	cash_changed.emit(cash, amount)


func can_afford(price: int) -> bool:
	return price >= 0 and cash >= price


func _spend(price: int) -> bool:
	if not can_afford(price):
		return false
	cash -= price
	cash_changed.emit(cash, -price)
	return true


## An enemy the player killed. streak = kills in the current kill streak.
## Returns the cash paid.
func award_kill(enemy: Node, streak: int) -> int:
	if enemy.get("no_reward"):
		return 0  # nuked
	var amount := Economy.kill_cash(enemy.kind, enemy.last_hit_was_headshot(), streak)
	if active.has("double_points"):
		amount *= 2
	earn(amount)
	return amount


func award_wave(wave: int) -> void:
	earn(Economy.wave_cash(wave))


func new_wave() -> void:
	_drops_this_wave = 0


# --- Shop ------------------------------------------------------------------------

func buy_ammo() -> bool:
	if not can_afford(Economy.AMMO_PRICE) or not player.refill_ammo():
		return false
	return _spend(Economy.AMMO_PRICE)


func buy_grenade() -> bool:
	if not can_afford(Economy.GRENADE_PRICE) or player.add_grenades(1) == 0:
		return false
	return _spend(Economy.GRENADE_PRICE)


func buy_armor() -> bool:
	if not can_afford(Economy.ARMOR_PRICE) or not player.add_armor(Economy.MAX_ARMOR):
		return false
	return _spend(Economy.ARMOR_PRICE)


func buy_health() -> bool:
	if not can_afford(Economy.HEALTH_PRICE) or player.health >= player.MAX_HEALTH:
		return false
	player.heal(player.MAX_HEALTH)
	return _spend(Economy.HEALTH_PRICE)


## Price of weapon `index` in the shop, or -1 if it isn't sold (a start weapon).
static func weapon_price(index: int) -> int:
	return Economy.WEAPON_PRICES.get(Weapons.LIST[index].name, -1)


## Weapons unlock by player level (progression_config.gd).
static func weapon_unlocked(index: int) -> bool:
	return Progress.is_weapon_unlocked(Weapons.LIST[index].name)


func buy_weapon(index: int) -> bool:
	var price := weapon_price(index)
	if player.has_weapon(index) or not weapon_unlocked(index) or not can_afford(price):
		return false
	player.give_weapon(index)
	return _spend(price)


## Price of the next level of `stat` for weapon `index` (-1 = maxed out).
func upgrade_price(index: int, stat: String) -> int:
	return Economy.upgrade_price(player.upgrade_level(index, stat))


func buy_upgrade(index: int, stat: String) -> bool:
	var price := upgrade_price(index, stat)
	if not player.has_weapon(index) or not can_afford(price):
		return false
	player.upgrade(index, stat)
	return _spend(price)


# --- Power-ups -------------------------------------------------------------------

## Maybe drops a power-up where `enemy` died (economy.gd DROP_CHANCE).
func maybe_drop(enemy: Node3D) -> Node3D:
	if enemy.get("no_reward") or _drops_this_wave >= Economy.MAX_DROPS_PER_WAVE:
		return null
	var chance: float = Economy.BOSS_DROP_CHANCE if enemy.kind == "boss" else Economy.DROP_CHANCE
	if randf() >= chance:
		return null
	return drop(_random_kind(), enemy.global_position)


## Puts a power-up of `kind` on the ground at `pos`.
func drop(kind: String, pos: Vector3) -> Node3D:
	_drops_this_wave += 1
	var p := PowerupDrop.new()
	p.kind = kind
	get_parent().add_child(p)
	p.global_position = Vector3(pos.x, pos.y, pos.z)
	p.collected.connect(collect)
	return p


func _random_kind() -> String:
	var total := 0
	for k: String in Economy.DROP_WEIGHTS:
		total += Economy.DROP_WEIGHTS[k]
	var r := randi() % total
	for k: String in Economy.DROP_WEIGHTS:
		r -= Economy.DROP_WEIGHTS[k]
		if r < 0:
			return k
	return "max_ammo"


## The player picked up a power-up.
func collect(kind: String) -> void:
	match kind:
		"max_ammo":
			player.refill_ammo()
			player.add_grenades(player.MAX_GRENADES)
		"double_points":
			active["double_points"] = Economy.DOUBLE_POINTS_TIME
		"insta_kill":
			active["insta_kill"] = Economy.INSTA_KILL_TIME
			player.insta_kill = true
		"nuke":
			nuke()
		"armor":
			player.add_armor(Economy.MAX_ARMOR)
	_jingle.play()
	_speak(Economy.POWERUP_INFO[kind].name)
	powerup_collected.emit(kind)


## Kills every enemy on screen (in the camera's view). No cash for them, and
## the Boss shrugs it off.
func nuke() -> int:
	var camera := get_viewport().get_camera_3d()
	var count := 0
	for e: Node in get_tree().get_nodes_in_group("enemies"):
		if not e is CharacterBody3D or e.kind == "boss":
			continue
		var chest: Vector3 = (e as Node3D).global_position + Vector3.UP * e.stats.height * 0.6
		if camera and not camera.is_position_in_frustum(chest):
			continue
		e.no_reward = true
		e.take_damage(e.hp, chest, Vector3.UP)
		count += 1
	if player and player.has_method("add_shake"):
		player.add_shake(0.6)
	return count


## Seconds left of a timed power-up (0 if it isn't running).
func time_left(kind: String) -> float:
	return active.get(kind, 0.0)


# The power-up's name read out by the device's text-to-speech voice (phones,
# most browsers and Windows have one). The jingle plays either way.
func _speak(text: String) -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH) \
			or not ProjectSettings.get_setting("audio/general/text_to_speech", false):
		return
	var voices := DisplayServer.tts_get_voices_for_language("en")
	if voices.is_empty():
		return
	DisplayServer.tts_stop()
	DisplayServer.tts_speak(text, voices[0], roundi(Settings.master_volume * 100.0), 0.85, 1.0)
