extends RefCounted
## Every enemy type's stats and look in one place (like weapon_stats.gd).
## enemy.gd reads the entry for its `kind`; main.gd decides which kinds
## spawn in each wave.
##
## Fields:
##  name            shown on the boss health bar
##  mesh            Mixamo character: assets/models/enemies/<mesh>_<low|med|high>.glb
##                  (picked by graphics quality, see model_scene) and
##                  <mesh>_anims.res (its animations). Built from art_source/
##                  by tools/blender/build_enemies.bat.
##  model_scale     size of the model (the characters are ~2 m tall at 1.0)
##  anims           animation names in that library: walk, attack, death,
##                  idle (+ shoot). Hit reactions are procedural (enemy.gd).
##  anim_speed      playback rates. walk_max: how much faster than its own
##                  pace the walk may play to keep up with `speed` (past that
##                  the feet slide a little instead of the legs blurring);
##                  attack, death, idle multiply. The attack is started so its
##                  strike lands at attack_hit_time.
##  tint            multiplies every material's colour (WHITE = as made)
##  glow            emission colour over the whole body (null = none); the
##                  Exploder's pulses
##  hp, speed       health and walking speed (m/s)
##  attack_range, attack_damage, attack_hit_time, attack_duration   melee
##  hit_stun        seconds a hit interrupts it (0 = it never staggers)
##  radius, height  collision capsule
##  points          score for a kill
##  growls          voice clips (null = slices of the shared moan recording)
##  growl_pitch     random pitch range for the voice
##  steps           footstep sounds (heavy types), played on each step
##  blood           colour of the hit spray; null = metal sparks instead (exploder vest)
##  head_size       head hitbox radius as a share of the head bone length (see enemy.gd)

const ZOMBIE_MOANS := preload("res://assets/sounds/zombie_moans.ogg")

## Navigation: every map has one navmesh per entry, baked by
## tools/bake_navmesh.gd into <map navmesh><suffix>.res, each kept `radius`
## away from walls and props with `height` of headroom. Each enemy type walks
## on the first one it fits (nav_mesh_for), on that entry's navigation layer.
## The first is the map scene's own NavigationRegion3D; main.gd adds the others.
## radius/height are whole numbers of cells (0.125 m / 0.1 m).
const NAV_MESHES := [
	{"layer": 1, "suffix": "", "radius": 0.5, "height": 1.8},          # zombie, runner, soldier, exploder
	{"layer": 2, "suffix": "_brute", "radius": 0.625, "height": 2.7},  # Brute (0.6 m, 2.6 m)
	{"layer": 4, "suffix": "_boss", "radius": 0.875, "height": 3.5},   # Brute Boss (0.8 m, 3.3 m)
]
const NAV_SMALL := 1


## The navmesh entry an enemy type walks on: the smallest it fits.
static func nav_mesh_for(kind: String) -> Dictionary:
	for m: Dictionary in NAV_MESHES:
		if m.radius >= TYPES[kind].radius and m.height >= TYPES[kind].height:
			return m
	return NAV_MESHES[NAV_MESHES.size() - 1]


## The navigation layer an enemy type walks on.
static func nav_layer(kind: String) -> int:
	return nav_mesh_for(kind).layer


const MODEL_DIR := "res://assets/models/enemies/"
## Detail level per Settings.Quality (LOW, MEDIUM, HIGH): ~3k / 7k / 15k
## triangles with 256 / 512 / 1024 px textures.
const LODS := ["low", "med", "high"]


## The model for a type at a graphics quality (loaded once, then cached by
## Godot). Only the level in use is loaded.
static func model_scene(kind: String, quality: int) -> PackedScene:
	return load("%s%s_%s.glb" % [MODEL_DIR, TYPES[kind].mesh, LODS[clampi(quality, 0, 2)]])


static func anim_library(kind: String) -> AnimationLibrary:
	return load("%s%s_anims.res" % [MODEL_DIR, TYPES[kind].mesh])

# Animation sets (names in the libraries made by tools/mixamo_anims.gd).
const ZOMBIE_ANIMS := {"walk": "walk", "attack": "attack", "death": "death", "idle": "idle"}
const RUNNING_ANIMS := {"walk": "run", "attack": "attack", "death": "death", "idle": "idle"}

const TYPES := {
	"normal": {
		"name": "Zombie",
		"mesh": "zombie",
		"model_scale": 0.86,
		"anims": ZOMBIE_ANIMS,
		"anim_speed": {"walk_max": 2.4, "attack": 1.4, "death": 1.1, "idle": 1.0},
		"tint": Color.WHITE,
		"glow": null,
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
		"blood": Color(0.45, 0.06, 0.03),
		"head_size": 0.75,
	},
	# Small, fast and fragile: sprints at the player, hits lightly but often.
	"runner": {
		"name": "Runner",
		"mesh": "runner",
		"model_scale": 0.71,
		"anims": RUNNING_ANIMS,
		"anim_speed": {"walk_max": 2.2, "attack": 1.9, "death": 1.3, "idle": 1.3},
		"tint": Color.WHITE,
		"glow": null,
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
		"blood": Color(0.5, 0.07, 0.03),
		"head_size": 0.75,
	},
	# Huge, slow and very tough. Doesn't flinch, and each punch hurts a lot.
	"brute": {
		"name": "Brute",
		"mesh": "brute",
		"model_scale": 1.27,
		"anims": ZOMBIE_ANIMS,
		# Slow and heavy: the walk never hurries much, swings are slower.
		"anim_speed": {"walk_max": 1.7, "attack": 1.0, "death": 0.8, "idle": 0.75},
		"tint": Color.WHITE,
		"glow": null,
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
		"blood": Color(0.3, 0.03, 0.02),
		"head_size": 0.75,
	},
	# Every 5th wave: an even bigger, darker brute with a health bar.
	"boss": {
		"name": "Brute Boss",
		"mesh": "brute",
		"model_scale": 1.62,
		"anims": ZOMBIE_ANIMS,
		"anim_speed": {"walk_max": 1.5, "attack": 0.9, "death": 0.7, "idle": 0.65},
		"tint": Color(0.5, 0.42, 0.42),
		"glow": Color(0.12, 0.01, 0.0),
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
		"blood": Color(0.28, 0.02, 0.04),
		"head_size": 0.75,
	},
	# Keeps its distance and shoots: a red laser and a warning tone first,
	# then a shot with a visible tracer. Punches if you get too close.
	"soldier": {
		"name": "Soldier",
		"mesh": "soldier",
		"model_scale": 0.94,
		# Melee: a rifle jab (the firing clip). Idle: standing with the rifle up.
		"anims": {"walk": "walk", "attack": "shoot", "death": "death", "idle": "idle", "shoot": "shoot"},
		"anim_speed": {"walk_max": 2.2, "attack": 0.6, "death": 1.3, "idle": 1.0},
		"tint": Color.WHITE,
		"glow": null,
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
		"blood": Color(0.75, 0.02, 0.02),
		"head_size": 0.75,
	},
	# Glowing, beeping walking bomb: blows up next to the player, or when killed.
	"exploder": {
		"name": "Exploder",
		"mesh": "exploder",
		"model_scale": 0.89,
		"anims": RUNNING_ANIMS,
		"anim_speed": {"walk_max": 2.2, "attack": 1.0, "death": 1.2, "idle": 1.0},
		"tint": Color(1.0, 0.9, 0.8),
		"glow": Color(1.0, 0.33, 0.03),
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
		"blood": null,
		"head_size": 0.75,
	},
}
