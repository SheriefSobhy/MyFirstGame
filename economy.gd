extends RefCounted
## Every balance number of the in-match economy in one place: cash, the shop,
## weapon upgrades, power-up drops, armor and the explosive barrels.
## Tuned for 5-10 minute matches (about 5-8 waves): a new weapon or a couple
## of upgrades after each wave, never everything.

# --- Cash ------------------------------------------------------------------------

const START_CASH := 500
## Cash for killing each enemy type (enemy_types.gd keys).
const KILL_CASH := {
	"normal": 60,
	"runner": 70,
	"soldier": 100,
	"exploder": 80,
	"brute": 200,
	"boss": 750,
}
const HEADSHOT_CASH := 40           # extra for a killing headshot
const STREAK_CASH := 25             # extra per kill in a streak after the first (Double Kill +25, Triple +50...)
const STREAK_CASH_MAX := 100
## Clearing wave n pays WAVE_CASH + WAVE_CASH_PER_WAVE * n.
const WAVE_CASH := 150
const WAVE_CASH_PER_WAVE := 50

# --- Break between waves -------------------------------------------------------

## Seconds between waves. The countdown stops while the shop is open.
const BREAK_TIME := 10.0

# --- Shop: supplies ----------------------------------------------------------------

const AMMO_PRICE := 300             # every owned weapon's magazine and spare ammo to full
const GRENADE_PRICE := 150          # one grenade (up to the player's MAX_GRENADES)
const ARMOR_PRICE := 400            # armor to full
const HEALTH_PRICE := 300           # health to full

# --- Revive ------------------------------------------------------------------------

## Dying offers this many revives per match ("Watch ad to revive"): back with
## full health, enemies near you pushed away.
const REVIVES_PER_MATCH := 1
const REVIVE_OFFER_TIME := 10.0     # seconds to decide before it counts as "No thanks"
const REVIVE_AD_TIME := 3.0         # the placeholder ad screen
const REVIVE_PUSH_RADIUS := 9.0     # m: enemies this close are pushed away...
const REVIVE_PUSH_SPEED := 9.0      # ...at this speed (m/s, about 5 m) ...
const REVIVE_STUN := 1.2            # ...and staggered this long (s)
const REVIVE_INVULNERABLE := 2.0    # s of no damage after coming back

# --- Armor -------------------------------------------------------------------------

const MAX_ARMOR := 100
## Share of each hit the armor takes while it lasts (the rest hurts health).
const ARMOR_ABSORB := 0.7

# --- Shop: weapons ----------------------------------------------------------------

## The weapons you start every match with, in every mode (weapon_stats.gd
## names): the AK as primary plus the pistol as secondary. Settings
## "Debug: all weapons" gives every weapon instead.
const START_WEAPONS := ["AK Rifle", "Pistol"]
## The start weapon in hand when a match begins.
const START_PRIMARY := "AK Rifle"
## Price of the other weapons (weapon_stats.gd names).
const WEAPON_PRICES := {
	"Shotgun": 1000,
	"Revolver": 1000,
	"SMG": 1250,
	"Assault Rifle": 1500,
	"Sniper": 2000,
	"LMG": 3000,
}

# --- Shop: upgrades (per weapon, this match only) --------------------------------

const UPGRADE_LEVELS := 3
## Price of upgrade level 1, 2, 3 (the same for each kind of upgrade).
const UPGRADE_PRICES := [600, 1200, 2400]
## Damage per bullet x (1 + DAMAGE_PER_LEVEL * level), and at least +1 a level.
const DAMAGE_PER_LEVEL := 0.5
## Magazine size x (1 + MAG_PER_LEVEL * level), rounded up.
const MAG_PER_LEVEL := 0.25
## Reload time x (1 - RELOAD_PER_LEVEL * level).
const RELOAD_PER_LEVEL := 0.15
const UPGRADE_NAMES := {"damage": "Damage", "mag": "Mag Size", "reload": "Reload Speed"}

# --- Power-ups --------------------------------------------------------------------

const DROP_CHANCE := 0.06           # per kill
const BOSS_DROP_CHANCE := 1.0       # the Boss always drops one
const MAX_DROPS_PER_WAVE := 2
## How often each kind is picked (relative weights).
const DROP_WEIGHTS := {
	"max_ammo": 3,
	"double_points": 2,
	"insta_kill": 2,
	"nuke": 1,
	"armor": 2,
}
const POWERUP_LIFETIME := 15.0      # seconds on the ground before it vanishes
const POWERUP_BLINK := 4.0          # blinks for the last few seconds
const POWERUP_PICKUP_RADIUS := 1.3  # m
const DOUBLE_POINTS_TIME := 20.0
const INSTA_KILL_TIME := 15.0
## On the ground and on the HUD.
const POWERUP_INFO := {
	"max_ammo": {"name": "Max Ammo", "short": "AMMO", "color": Color(1.0, 0.8, 0.2)},
	"double_points": {"name": "Double Points", "short": "2X", "color": Color(0.3, 1.0, 0.35)},
	"insta_kill": {"name": "Insta-Kill", "short": "KILL", "color": Color(1.0, 0.25, 0.2)},
	"nuke": {"name": "Nuke", "short": "NUKE", "color": Color(1.0, 0.55, 0.1)},
	"armor": {"name": "Armor", "short": "ARMOR", "color": Color(0.35, 0.7, 1.0)},
}

# --- Explosive barrels -----------------------------------------------------------

const BARREL_HP := 2                # pistol: one shot; rifle: two
const BARREL_RADIUS := 5.5          # m, enemies (and other barrels) inside get hit
const BARREL_DAMAGE := 15           # at the centre, less further out
const BARREL_PLAYER_RADIUS := 5.0
const BARREL_PLAYER_DAMAGE := 35
const BARREL_CHAIN_DELAY := Vector2(0.12, 0.3)  # seconds before a barrel set off by another goes up


## Cash for killing `kind` (with the extras). streak = kills in the current streak.
static func kill_cash(kind: String, headshot: bool, streak: int) -> int:
	var cash: int = KILL_CASH.get(kind, KILL_CASH.normal)
	if headshot:
		cash += HEADSHOT_CASH
	cash += mini(STREAK_CASH * maxi(streak - 1, 0), STREAK_CASH_MAX)
	return cash


static func wave_cash(wave: int) -> int:
	return WAVE_CASH + WAVE_CASH_PER_WAVE * wave


## Price of the next level of an upgrade, or -1 when it is maxed out.
static func upgrade_price(level: int) -> int:
	return UPGRADE_PRICES[level] if level < UPGRADE_LEVELS else -1


static func upgraded_damage(base: int, level: int) -> int:
	return maxi(roundi(base * (1.0 + DAMAGE_PER_LEVEL * level)), base + level)


static func upgraded_mag(base: int, level: int) -> int:
	return ceili(base * (1.0 + MAG_PER_LEVEL * level))


static func upgraded_reload(base: float, level: int) -> float:
	return base * (1.0 - RELOAD_PER_LEVEL * level)
