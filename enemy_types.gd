extends RefCounted
## Every enemy type's stats and look in one place (like weapon_stats.gd).
## enemy.gd reads the entry for its `kind`; main.gd decides which kinds
## spawn in each wave.
##
## Fields:
##  name            shown on the boss health bar
##  model           animated character (null = the model already in enemy.tscn)
##  model_scale     size of the model (the type's height comes from this)
##  anims           animation names: walk, attack, hit, death (+ shoot)
##  fall_over       true = on death the body also tips over backwards (for
##                  models whose death animation doesn't fall to the ground)
##  walk_anim_ref   ground speed (m/s at speed_scale 1) the walk animation
##                  was made for; playback is sped up/slowed to match `speed`
##  colors          material name -> new albedo colour (recolours the model)
##  glow            material name -> emission colour (glowing parts)
##  hp, speed       health and walking speed (m/s)
##  attack_range, attack_damage, attack_hit_time, attack_duration   melee
##  hit_stun        seconds a hit interrupts it (0 = it never staggers)
##  radius, height  collision capsule
##  points          score for a kill
##  growls          voice clips (null = slices of the shared moan recording)
##  growl_pitch     random pitch range for the voice
##  steps           footstep sounds (heavy types), played on each step

const ZOMBIE_MOANS := preload("res://assets/sounds/zombie_moans.ogg")

const TYPES := {
	"normal": {
		"name": "Zombie",
		"model": null,
		"model_scale": 1.15,
		"anims": {
			"walk": "CharacterArmature|Walk",
			"attack": "CharacterArmature|Punch_Right",
			"hit": "CharacterArmature|HitRecieve",
			"death": "CharacterArmature|Death",
		},
		"walk_anim_ref": 2.3,
		"fall_over": false,
		"colors": {},
		"glow": {},
		"hp": 3,
		"speed": 1.4,
		"attack_range": 1.4,
		"attack_damage": 10,
		"attack_hit_time": 0.4,
		"attack_duration": 0.85,
		"hit_stun": 0.35,
		"radius": 0.35,
		"height": 1.75,
		"points": 10,
		"growls": null,
		"growl_pitch": Vector2(0.85, 1.1),
		"steps": [],
	},
	# Small, fast and fragile: sprints at the player, hits lightly but often.
	"runner": {
		"name": "Runner",
		"model": preload("res://assets/models/quaternius/characters/Zombie_Female.fbx"),
		"model_scale": 0.48,
		"anims": {
			"walk": "CharacterArmature|Walk",
			"attack": "CharacterArmature|Punch",
			"hit": "CharacterArmature|RecieveHit",
			"death": "CharacterArmature|RecieveHit",
		},
		"walk_anim_ref": 1.1,
		"fall_over": true,
		"colors": {"Skin": Color(0.55, 0.62, 0.28), "Clothes": Color(0.75, 0.12, 0.1), "DarkClothes": Color(0.45, 0.06, 0.05)},
		"glow": {},
		"hp": 2,
		"speed": 4.2,
		"attack_range": 1.3,
		"attack_damage": 6,
		"attack_hit_time": 0.3,
		"attack_duration": 0.6,
		"hit_stun": 0.25,
		"radius": 0.3,
		"height": 1.45,
		"points": 15,
		"growls": [
			preload("res://assets/sounds/enemies/runner_1.wav"),
			preload("res://assets/sounds/enemies/runner_2.wav"),
			preload("res://assets/sounds/enemies/runner_3.wav"),
		],
		"growl_pitch": Vector2(1.15, 1.35),
		"steps": [],
	},
	# Huge, slow and very tough. Doesn't flinch, and each punch hurts a lot.
	"brute": {
		"name": "Brute",
		"model": preload("res://assets/models/quaternius/characters/Zombie_Male.fbx"),
		"model_scale": 0.85,
		"anims": {
			"walk": "CharacterArmature|Walk",
			"attack": "CharacterArmature|Punch",
			"hit": "CharacterArmature|RecieveHit",
			"death": "CharacterArmature|RecieveHit",
		},
		"walk_anim_ref": 2.0,
		"fall_over": true,
		"colors": {"Skin": Color(0.42, 0.2, 0.17), "Clothes": Color(0.12, 0.11, 0.12), "DarkClothes": Color(0.08, 0.07, 0.08), "Pants": Color(0.2, 0.17, 0.14)},
		"glow": {},
		"hp": 25,
		"speed": 1.0,
		"attack_range": 2.1,
		"attack_damage": 30,
		"attack_hit_time": 0.45,
		"attack_duration": 1.1,
		"hit_stun": 0.0,
		"radius": 0.6,
		"height": 2.6,
		"points": 50,
		"growls": [
			preload("res://assets/sounds/enemies/brute_1.wav"),
			preload("res://assets/sounds/enemies/brute_2.wav"),
		],
		"growl_pitch": Vector2(0.6, 0.75),
		"steps": [
			preload("res://assets/sounds/enemies/brute_step_1.ogg"),
			preload("res://assets/sounds/enemies/brute_step_2.ogg"),
			preload("res://assets/sounds/enemies/brute_step_3.ogg"),
		],
	},
	# Every 5th wave: an even bigger brute with glowing eyes and a health bar.
	"boss": {
		"name": "Brute Boss",
		"model": preload("res://assets/models/quaternius/characters/Zombie_Male.fbx"),
		"model_scale": 1.1,
		"anims": {
			"walk": "CharacterArmature|Walk",
			"attack": "CharacterArmature|Punch",
			"hit": "CharacterArmature|RecieveHit",
			"death": "CharacterArmature|RecieveHit",
		},
		"walk_anim_ref": 2.6,
		"fall_over": true,
		"colors": {"Skin": Color(0.3, 0.1, 0.1), "Clothes": Color(0.06, 0.06, 0.07), "DarkClothes": Color(0.05, 0.05, 0.05), "Pants": Color(0.12, 0.1, 0.09), "Brain": Color(0.7, 0.2, 0.25)},
		"glow": {"Face": Color(1.0, 0.1, 0.05)},
		"hp": 80,
		"speed": 1.1,
		"attack_range": 2.6,
		"attack_damage": 40,
		"attack_hit_time": 0.5,
		"attack_duration": 1.2,
		"hit_stun": 0.0,
		"radius": 0.8,
		"height": 3.3,
		"points": 250,
		"growls": [
			preload("res://assets/sounds/enemies/brute_1.wav"),
			preload("res://assets/sounds/enemies/brute_2.wav"),
		],
		"growl_pitch": Vector2(0.45, 0.55),
		"steps": [
			preload("res://assets/sounds/enemies/brute_step_1.ogg"),
			preload("res://assets/sounds/enemies/brute_step_2.ogg"),
			preload("res://assets/sounds/enemies/brute_step_3.ogg"),
		],
	},
	# Keeps its distance and shoots: a red laser and a warning tone first,
	# then a shot with a visible tracer. Punches if you get too close.
	"soldier": {
		"name": "Soldier",
		"model": preload("res://assets/models/quaternius/characters/Soldier_Male.fbx"),
		"model_scale": 0.56,
		"anims": {
			"walk": "CharacterArmature|Walk",
			"attack": "CharacterArmature|Punch",
			"hit": "CharacterArmature|RecieveHit",
			"death": "CharacterArmature|RecieveHit",
			"shoot": "CharacterArmature|Shoot_OneHanded",
			"idle": "CharacterArmature|Idle",
		},
		"walk_anim_ref": 1.3,
		"fall_over": true,
		"colors": {},
		"glow": {},
		"hp": 4,
		"speed": 2.2,
		"attack_range": 1.4,
		"attack_damage": 8,
		"attack_hit_time": 0.35,
		"attack_duration": 0.75,
		"hit_stun": 0.3,
		"radius": 0.35,
		"height": 1.7,
		"points": 25,
		"growls": [
			preload("res://assets/sounds/enemies/soldier_hurt_1.wav"),
			preload("res://assets/sounds/enemies/soldier_hurt_2.wav"),
		],
		"growl_pitch": Vector2(1.2, 1.4),
		"steps": [],
	},
	# Glowing, beeping walking bomb: blows up next to the player, or when killed.
	"exploder": {
		"name": "Exploder",
		"model": preload("res://assets/models/quaternius/characters/Worker_Male.fbx"),
		"model_scale": 0.52,
		"anims": {
			"walk": "CharacterArmature|Walk",
			"attack": "CharacterArmature|Punch",
			"hit": "CharacterArmature|RecieveHit",
			"death": "CharacterArmature|RecieveHit",
		},
		"walk_anim_ref": 1.2,
		"fall_over": true,
		"colors": {"Vest": Color(0.95, 0.35, 0.05), "Shirt": Color(0.95, 0.75, 0.2), "Hat": Color(0.9, 0.1, 0.05)},
		"glow": {"Vest": Color(1.0, 0.35, 0.05)},
		"hp": 2,
		"speed": 3.3,
		"attack_range": 2.2,
		"attack_damage": 0,
		"attack_hit_time": 0.0,
		"attack_duration": 0.0,
		"hit_stun": 0.2,
		"radius": 0.33,
		"height": 1.6,
		"points": 20,
		"growls": [
			preload("res://assets/sounds/enemies/exploder_1.wav"),
			preload("res://assets/sounds/enemies/exploder_2.wav"),
		],
		"growl_pitch": Vector2(0.9, 1.1),
		"steps": [],
	},
}
