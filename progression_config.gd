extends RefCounted
## Every balance number of the persistent progression in one place: XP and
## levels, what each level unlocks, coins, the Armory (permanent upgrades and
## skins), daily missions, the daily login reward, map stars and achievements.
## The state itself (and saving it) is progress.gd (autoloaded as "Progress").
## The in-match economy (cash, the shop) is economy.gd.

# --- XP and levels -------------------------------------------------------------

const MAX_LEVEL := 50
## XP to go from level n to n+1 is XP_BASE + XP_STEP * (n - 1):
## 300 for level 2, 450 for level 3 ... 7500 for level 50 (about 190k in all).
const XP_BASE := 300
const XP_STEP := 150
## XP for killing each enemy type (enemy_types.gd keys).
const KILL_XP := {
	"normal": 10,
	"runner": 12,
	"soldier": 18,
	"exploder": 15,
	"brute": 40,
	"boss": 150,
}
const HEADSHOT_XP := 5              # extra for a killing headshot
## Clearing wave n gives WAVE_XP + WAVE_XP_PER_WAVE * n.
const WAVE_XP := 40
const WAVE_XP_PER_WAVE := 10
## At the end of a match: MATCH_XP + MATCH_XP_PER_WAVE * waves survived.
const MATCH_XP := 50
const MATCH_XP_PER_WAVE := 10
## Coins for every level gained.
const LEVEL_UP_COINS := 50

# --- Unlocks -------------------------------------------------------------------

## The level a weapon becomes available in the in-match shop (weapon_stats.gd
## names; missing = level 1). Settings "Debug: all weapons" ignores this.
const WEAPON_UNLOCK_LEVEL := {
	"SMG": 2,
	"Shotgun": 3,
	"Revolver": 5,
	"AK Rifle": 7,
	"Sniper": 10,
	"LMG": 15,
}
## The level a map can be played from (maps.gd ids; missing = level 1).
const MAP_UNLOCK_LEVEL := {
	"town": 4,
	"warehouse": 8,
}

# --- Coins (earned at the end of a match) --------------------------------------

## COINS_PER_WAVE * waves + waves^2 * COINS_WAVE_SQUARED + COINS_PER_KILL * kills:
## wave 8 with ~100 kills is about 240 coins, wave 15 about 600.
const COINS_PER_WAVE := 10
const COINS_WAVE_SQUARED := 1
const COINS_PER_KILL := 1

# --- Armory: permanent weapon upgrades ------------------------------------------

const PERM_LEVELS := 5
## Coin price of permanent level 1..5 (the same for each kind and weapon).
const PERM_PRICES := [150, 300, 500, 800, 1200]
## Each level: damage x(1 + 8%), magazine x(1 + 10%), reload time x(1 - 6%).
## They stack with the in-match shop upgrades (economy.gd). Damage that comes
## out fractional is rounded up on that share of the shots (2.4 = 40% of the
## shots do 3).
const PERM_DAMAGE := 0.08
const PERM_MAG := 0.10
const PERM_RELOAD := 0.06

# --- Armory: weapon skins --------------------------------------------------------

## Skins in shop order. "standard" is the gun as modelled and always owned.
## color: the skin's colour; mix: how much of the original colour it replaces
## (the original's light and dark parts still show through); pattern "camo"
## adds a blotchy camouflage texture.
const SKINS := {
	"standard": {"name": "Standard", "price": 0, "color": Color.WHITE, "mix": 0.0,
			"metallic": -1.0, "roughness": -1.0, "pattern": ""},
	"desert": {"name": "Desert", "price": 250, "color": Color(0.82, 0.68, 0.45), "mix": 0.85,
			"metallic": 0.1, "roughness": 0.8, "pattern": ""},
	"black": {"name": "Black", "price": 400, "color": Color(0.07, 0.07, 0.08), "mix": 0.9,
			"metallic": 0.4, "roughness": 0.45, "pattern": ""},
	"camo": {"name": "Camo", "price": 600, "color": Color(0.42, 0.45, 0.3), "mix": 0.9,
			"metallic": 0.0, "roughness": 0.85, "pattern": "camo"},
	"gold": {"name": "Gold", "price": 1500, "color": Color(1.0, 0.76, 0.3), "mix": 0.9,
			"metallic": 1.0, "roughness": 0.28, "pattern": ""},
}

# --- Daily missions ---------------------------------------------------------------

const DAILY_MISSIONS := 3
## The pool the day's missions are drawn from (no two of the same id).
## type:  kills / headshots / waves / matches / cash count up over the day's
##        matches; kill_kind counts one enemy type ("brute" also counts the
##        Boss); reach_wave is the highest wave reached on one map (picked
##        from the unlocked maps).
## targets/rewards: one pair is picked (target i pays rewards[i] coins).
const MISSION_POOL := [
	{"id": "kills", "type": "kills", "text": "Kill %d enemies", "targets": [60, 100, 150], "rewards": [100, 150, 220]},
	{"id": "headshots", "type": "headshots", "text": "Get %d headshots", "targets": [15, 30], "rewards": [120, 200]},
	{"id": "brutes", "type": "kill_kind", "kind": "brute", "text": "Kill %d Brutes", "targets": [3, 5], "rewards": [150, 220]},
	{"id": "runners", "type": "kill_kind", "kind": "runner", "text": "Kill %d Runners", "targets": [15, 30], "rewards": [100, 160]},
	{"id": "soldiers", "type": "kill_kind", "kind": "soldier", "text": "Kill %d Soldiers", "targets": [8, 15], "rewards": [110, 170]},
	{"id": "exploders", "type": "kill_kind", "kind": "exploder", "text": "Kill %d Exploders", "targets": [6, 12], "rewards": [120, 180]},
	{"id": "boss", "type": "kill_kind", "kind": "boss", "text": "Defeat %d Brute Boss", "targets": [1], "rewards": [200]},
	{"id": "reach", "type": "reach_wave", "text": "Reach wave %d on %s", "targets": [6, 8, 10], "rewards": [120, 170, 250]},
	{"id": "waves", "type": "waves", "text": "Clear %d waves", "targets": [10, 20], "rewards": [100, 170]},
	{"id": "matches", "type": "matches", "text": "Play %d matches", "targets": [2, 4], "rewards": [80, 150]},
	{"id": "cash", "type": "cash", "text": "Earn $%d cash in matches", "targets": [6000, 12000], "rewards": [100, 170]},
]

# --- Daily login reward -------------------------------------------------------------

## Coins for day 1..7 of a login streak. Missing a day starts again at day 1;
## after day 7 it goes round again.
const LOGIN_REWARDS := [50, 75, 100, 150, 200, 300, 500]

# --- Map stars ------------------------------------------------------------------------

## A map's stars: one for each of these waves reached.
const STAR_WAVES := [5, 10, 15]

# --- Achievements ---------------------------------------------------------------------

## stat: the lifetime number checked against target (progress.gd stat_value()):
##  kills, headshots, kills_brute (Brutes and Bosses), kills_boss, best_wave
##  (highest wave reached on any map), maps_played, stars, level,
##  max_upgrade (highest permanent upgrade level), skins_bought,
##  login_streak, missions_done, matches.
## reward: coins.
const ACHIEVEMENTS := [
	{"id": "first_blood", "name": "First Blood", "text": "Kill your first enemy", "stat": "kills", "target": 1, "reward": 25},
	{"id": "slayer", "name": "Zombie Slayer", "text": "Kill 500 enemies", "stat": "kills", "target": 500, "reward": 150},
	{"id": "exterminator", "name": "Exterminator", "text": "Kill 5000 enemies", "stat": "kills", "target": 5000, "reward": 600},
	{"id": "sharpshooter", "name": "Sharpshooter", "text": "Get 100 headshots", "stat": "headshots", "target": 100, "reward": 150},
	{"id": "head_hunter", "name": "Head Hunter", "text": "Get 1000 headshots", "stat": "headshots", "target": 1000, "reward": 500},
	{"id": "survivor", "name": "Survivor", "text": "Reach wave 5", "stat": "best_wave", "target": 5, "reward": 75},
	{"id": "veteran", "name": "Veteran", "text": "Reach wave 10", "stat": "best_wave", "target": 10, "reward": 200},
	{"id": "last_stand", "name": "Last Stand", "text": "Reach wave 20", "stat": "best_wave", "target": 20, "reward": 600},
	{"id": "giant_killer", "name": "Giant Killer", "text": "Kill 25 Brutes", "stat": "kills_brute", "target": 25, "reward": 250},
	{"id": "boss_slayer", "name": "Boss Slayer", "text": "Defeat the Brute Boss", "stat": "kills_boss", "target": 1, "reward": 150},
	{"id": "globetrotter", "name": "Globetrotter", "text": "Play every map", "stat": "maps_played", "target": 3, "reward": 200},
	{"id": "star_collector", "name": "Star Collector", "text": "Earn all 9 map stars", "stat": "stars", "target": 9, "reward": 800},
	{"id": "rising_star", "name": "Rising Star", "text": "Reach level 10", "stat": "level", "target": 10, "reward": 200},
	{"id": "legend", "name": "Legend", "text": "Reach level 50", "stat": "level", "target": 50, "reward": 2000},
	{"id": "gunsmith", "name": "Gunsmith", "text": "Max out a permanent upgrade", "stat": "max_upgrade", "target": 5, "reward": 300},
	{"id": "fashion", "name": "Style Points", "text": "Buy a weapon skin", "stat": "skins_bought", "target": 1, "reward": 50},
	{"id": "dedicated", "name": "Dedicated", "text": "Log in 7 days in a row", "stat": "login_streak", "target": 7, "reward": 300},
	{"id": "mission_man", "name": "On a Mission", "text": "Complete 10 daily missions", "stat": "missions_done", "target": 10, "reward": 250},
]


## XP needed to go from `level` to level + 1.
static func xp_to_next(level: int) -> int:
	return XP_BASE + XP_STEP * (level - 1)


## Total XP needed to reach `level` (level 1 = 0).
static func xp_for_level(level: int) -> int:
	var n := clampi(level, 1, MAX_LEVEL) - 1
	return XP_BASE * n + XP_STEP * n * (n - 1) / 2


static func level_for_xp(xp: int) -> int:
	var level := 1
	while level < MAX_LEVEL and xp >= xp_for_level(level + 1):
		level += 1
	return level


static func kill_xp(kind: String, headshot: bool) -> int:
	return KILL_XP.get(kind, KILL_XP.normal) + (HEADSHOT_XP if headshot else 0)


static func wave_xp(wave: int) -> int:
	return WAVE_XP + WAVE_XP_PER_WAVE * wave


static func match_xp(waves: int) -> int:
	return MATCH_XP + MATCH_XP_PER_WAVE * waves


static func match_coins(waves: int, kills: int) -> int:
	return COINS_PER_WAVE * waves + COINS_WAVE_SQUARED * waves * waves + COINS_PER_KILL * kills


static func weapon_unlock_level(weapon_name: String) -> int:
	return WEAPON_UNLOCK_LEVEL.get(weapon_name, 1)


static func map_unlock_level(map_id: String) -> int:
	return MAP_UNLOCK_LEVEL.get(map_id, 1)


## Coin price of the next permanent level, or -1 when it is maxed out.
static func perm_price(level: int) -> int:
	return PERM_PRICES[level] if level < PERM_LEVELS else -1


static func stars_for_wave(wave: int) -> int:
	var stars := 0
	for w: int in STAR_WAVES:
		if wave >= w:
			stars += 1
	return stars


## Coins for day `day` (1-based) of the login streak.
static func login_reward(day: int) -> int:
	return LOGIN_REWARDS[(maxi(day, 1) - 1) % LOGIN_REWARDS.size()]
