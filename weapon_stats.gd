extends RefCounted
## Every weapon's stats in one place. Tweak the numbers here; nothing else
## needs to change. The order of LIST is the weapon slot order (keys 1-4).
##
## Fields:
##  name            shown on the HUD and in pickup messages
##  model           the gun model (barrel along +X, grip at the origin)
##  view_length     how long the gun looks in first person, in metres
##  view_offset     nudges the first-person model so the grip sits in the right hand
##  arms_offset     slides the arm rig forward for long guns (arms only reach ~35 cm)
##  left_hand       where the left wrist goes (same space as view_offset); the
##                  fingers reach ~8 cm further along left_hand_forward
##  left_hand_forward / left_hand_back   left hand direction (wrist->knuckles / back of hand)
##  pickup_length   size of the floating pickup in the arena, in metres
##  automatic       true = hold to keep firing, false = one shot per press
##  damage          per bullet (enemies have 3 HP)
##  pellets         bullets per shot (shotgun > 1)
##  spread          random spread cone in degrees (always applied)
##  spread_per_shot extra spread added by each shot while firing (recoil bloom)
##  max_spread      cap for that extra spread
##  spread_recovery how fast the extra spread shrinks again, degrees per second
##  range           how far bullets reach, metres
##  mag_size        rounds per magazine
##  reserve         spare rounds you get with the weapon (-1 = unlimited)
##  max_reserve     most spare rounds you can carry (-1 = unlimited)
##  ammo_box        spare rounds one ammo box gives this weapon
##  fire_delay      seconds between shots (includes the pump / bolt time)
##  cycle_sound     pump or bolt sound played after each shot (null = none)
##  cycle_delay     seconds after the shot before the pump / bolt sound
##  reload_time     seconds
##  reload_sounds   [[seconds after reload starts, sound], ...]
##  shot_sound, shot_volume_db
##  recoil          how hard the gun model kicks back
##  view_kick       how many degrees the view climbs per shot
##  shake           camera shake per shot (0..1)
##  flash_size      muzzle flash scale
##  zoom_fov        scope field of view while aiming (0 = no scope)
##  scoped_spread   spread while scoped (replaces `spread`)
##  sight           what aiming looks through: "iron" (the top of the gun),
##                  "red_dot" (a reflex sight added on top) or "scope" (the
##                  sniper: full-screen scope overlay, uses zoom_fov)
##  ads_fov         field of view while aiming down the sights (not "scope")
##  ads_spread      spread multiplier while aiming down the sights (0.5 = half)
##  sight_at        where along the gun the sight sits, 0 = back .. 1 = muzzle
##  ads_offset      extra nudge (m) for the gun while aiming, if a hand is in the way

const LIST := [
	{
		"name": "Pistol",
		"model": preload("res://assets/models/quaternius/Pistol_1.glb"),
		"view_length": 0.155,
		"view_offset": Vector3.ZERO,
		"arms_offset": Vector3.ZERO,
		"left_hand": Vector3(-0.035, -0.06, 0.05),
		"left_hand_forward": Vector3(0.5, 0.35, -1.0),
		"left_hand_back": Vector3(-0.8, -0.6, 0.0),
		"pickup_length": 0.35,
		"automatic": false,
		"damage": 2,
		"pellets": 1,
		"spread": 0.0,
		"spread_per_shot": 0.0,
		"max_spread": 0.0,
		"spread_recovery": 0.0,
		"range": 100.0,
		"mag_size": 12,
		"reserve": -1,
		"max_reserve": -1,
		"ammo_box": 0,
		"fire_delay": 0.16,
		"cycle_sound": null,
		"cycle_delay": 0.0,
		"reload_time": 1.3,
		"reload_sounds": [
			[0.05, preload("res://assets/sounds/guns/pistol_mag_out.wav")],
			[0.75, preload("res://assets/sounds/guns/pistol_mag_in.wav")],
		],
		"shot_sound": preload("res://assets/sounds/gunshot_pistol.wav"),
		"shot_volume_db": -4.0,
		"recoil": 1.0,
		"view_kick": 0.4,
		"shake": 0.25,
		"flash_size": 1.0,
		"zoom_fov": 0.0,
		"scoped_spread": 0.0,
		"sight": "iron",
		"ads_fov": 60.0,
		"ads_spread": 0.5,
		"sight_at": 0.2,
		"ads_offset": Vector3.ZERO,
	},
	{
		"name": "Assault Rifle",
		"model": preload("res://assets/models/quaternius/guns/AR_1.glb"),
		"view_length": 0.42,
		"view_offset": Vector3(0.0, -0.01, 0.0),
		"arms_offset": Vector3(0.05, 0.0, -0.17),
		"left_hand": Vector3(-0.02, -0.055, -0.05),
		"left_hand_forward": Vector3(0.25, 0.45, -1.0),
		"left_hand_back": Vector3(-0.7, -1.0, 0.1),
		"pickup_length": 0.95,
		"automatic": true,
		"damage": 1,
		"pellets": 1,
		"spread": 0.3,
		"spread_per_shot": 0.45,
		"max_spread": 3.0,
		"spread_recovery": 8.0,
		"range": 100.0,
		"mag_size": 30,
		"reserve": 90,
		"max_reserve": 180,
		"ammo_box": 30,
		"fire_delay": 0.1,
		"cycle_sound": null,
		"cycle_delay": 0.0,
		"reload_time": 2.0,
		"reload_sounds": [
			[0.1, preload("res://assets/sounds/guns/rifle_mag_out.wav")],
			[1.2, preload("res://assets/sounds/guns/rifle_mag_in.wav")],
		],
		"shot_sound": preload("res://assets/sounds/guns/rifle_shot.wav"),
		"shot_volume_db": -6.0,
		"recoil": 0.45,
		"view_kick": 0.12,
		"shake": 0.15,
		"flash_size": 1.3,
		"zoom_fov": 0.0,
		"scoped_spread": 0.0,
		"sight": "red_dot",
		"ads_fov": 50.0,
		"ads_spread": 0.35,
		"sight_at": 0.3,
		"ads_offset": Vector3.ZERO,
	},
	{
		"name": "Shotgun",
		"model": preload("res://assets/models/quaternius/guns/Shotgun_1.glb"),
		"view_length": 0.46,
		"view_offset": Vector3(0.0, -0.005, 0.03),
		"arms_offset": Vector3(0.05, 0.0, -0.21),
		"left_hand": Vector3(-0.02, -0.06, -0.09),
		"left_hand_forward": Vector3(0.25, 0.45, -1.0),
		"left_hand_back": Vector3(-0.7, -1.0, 0.1),
		"pickup_length": 1.0,
		"automatic": false,
		"damage": 1,
		"pellets": 8,
		"spread": 6.0,
		"spread_per_shot": 0.0,
		"max_spread": 0.0,
		"spread_recovery": 0.0,
		"range": 14.0,
		"mag_size": 6,
		"reserve": 18,
		"max_reserve": 36,
		"ammo_box": 6,
		"fire_delay": 0.95,
		"cycle_sound": preload("res://assets/sounds/guns/shotgun_pump.wav"),
		"cycle_delay": 0.35,
		"reload_time": 2.2,
		"reload_sounds": [
			[0.25, preload("res://assets/sounds/guns/shotgun_shell.wav")],
			[0.7, preload("res://assets/sounds/guns/shotgun_shell.wav")],
			[1.15, preload("res://assets/sounds/guns/shotgun_shell.wav")],
			[1.65, preload("res://assets/sounds/guns/shotgun_pump.wav")],
		],
		"shot_sound": preload("res://assets/sounds/guns/shotgun_shot.wav"),
		"shot_volume_db": -3.0,
		"recoil": 1.8,
		"view_kick": 1.5,
		"shake": 0.6,
		"flash_size": 1.9,
		"zoom_fov": 0.0,
		"scoped_spread": 0.0,
		"sight": "iron",
		"ads_fov": 62.0,
		"ads_spread": 0.7,
		"sight_at": 0.9,
		"ads_offset": Vector3(0.0, -0.035, 0.0),
	},
	{
		"name": "Sniper",
		"model": preload("res://assets/models/quaternius/guns/Sniper_1.glb"),
		"view_length": 0.52,
		"view_offset": Vector3(0.0, -0.01, 0.0),
		"arms_offset": Vector3(0.05, 0.0, -0.2),
		"left_hand": Vector3(-0.02, -0.06, -0.08),
		"left_hand_forward": Vector3(0.25, 0.45, -1.0),
		"left_hand_back": Vector3(-0.7, -1.0, 0.1),
		"pickup_length": 1.15,
		"automatic": false,
		"damage": 6,
		"pellets": 1,
		"spread": 2.0,
		"spread_per_shot": 0.0,
		"max_spread": 0.0,
		"spread_recovery": 0.0,
		"range": 150.0,
		"mag_size": 5,
		"reserve": 15,
		"max_reserve": 25,
		"ammo_box": 5,
		"fire_delay": 1.4,
		"cycle_sound": preload("res://assets/sounds/guns/sniper_bolt.wav"),
		"cycle_delay": 0.45,
		"reload_time": 2.5,
		"reload_sounds": [
			[0.15, preload("res://assets/sounds/guns/sniper_mag_out.wav")],
			[1.3, preload("res://assets/sounds/guns/sniper_mag_in.wav")],
			[1.85, preload("res://assets/sounds/guns/sniper_bolt.wav")],
		],
		"shot_sound": preload("res://assets/sounds/guns/sniper_shot.wav"),
		"shot_volume_db": -2.0,
		"recoil": 2.2,
		"view_kick": 2.0,
		"shake": 0.8,
		"flash_size": 1.7,
		"zoom_fov": 18.0,
		"scoped_spread": 0.0,
		"sight": "scope",
		"ads_fov": 0.0,
		"ads_spread": 1.0,
		"sight_at": 0.0,
		"ads_offset": Vector3.ZERO,
	},
]
