extends RefCounted
## The playable maps, in the order the map selection screen shows them.
## Each map is a full game scene that runs main.gd; its `map_id` (set in the
## scene) must match the id here. The best score is saved per map id.
##
## Fields:
##  id          save key, and main.gd's map_id in that scene
##  name        shown on the map selection screen
##  short       short name (daily missions: "Reach wave 8 on Town")
##  description one line under the name
##  scene       the game scene to load
##  thumbnail   preview picture (made by tools/make_thumbnails.gd)
##  color       accent colour of the map's card

const LIST := [
	{
		"id": "yard",
		"short": "Yard",
		"name": "Industrial Yard",
		"description": "A walled yard of containers, crates and barrels in the afternoon sun.",
		"scene": "res://main.tscn",
		"thumbnail": "res://ui/thumbnails/yard.jpg",
		"color": Color(0.95, 0.7, 0.35),
	},
	{
		"id": "town",
		"short": "Town",
		"name": "Abandoned Town",
		"description": "Small streets, empty houses and wrecked cars at dusk.",
		"scene": "res://maps/town.tscn",
		"thumbnail": "res://ui/thumbnails/town.jpg",
		"color": Color(0.95, 0.5, 0.45),
	},
	{
		"id": "warehouse",
		"short": "Warehouse",
		"name": "Warehouse Night",
		"description": "Dark aisles of shelves and forklifts, and a loading yard outside.",
		"scene": "res://maps/warehouse.tscn",
		"thumbnail": "res://ui/thumbnails/warehouse.jpg",
		"color": Color(0.45, 0.7, 1.0),
	},
]


## The Training Arena (main menu > Training): not on the map selection screen,
## always unlocked, earns nothing (training/training.gd).
const TRAINING := {
	"id": "training",
	"short": "Training",
	"name": "Training Arena",
	"description": "A shooting range: targets, dummies of every enemy type and challenges.",
	"scene": "res://maps/training.tscn",
	"thumbnail": "res://ui/thumbnails/training.jpg",
	"color": Color(0.55, 0.9, 0.55),
}


static func find(id: String) -> Dictionary:
	for m: Dictionary in LIST:
		if m.id == id:
			return m
	return LIST[0]


## Game modes (Play > choose a mode > choose a map). Every map is played in
## both; each mode+map has its own best score, stars and missions
## (save_key()). Combat: soldiers who fight from cover
## (soldiers/soldiers_mode.gd, scenes maps/combat_<map id>.tscn).
const ZOMBIES := "zombies"
const COMBAT := "combat"
const MODES := [
	{
		"id": ZOMBIES,
		"name": "Zombies",
		"description": "Survive endless waves of the undead: runners, brutes, exploders and the Brute Boss.",
		"color": Color(0.55, 0.9, 0.4),
	},
	{
		"id": COMBAT,
		"name": "Combat",
		"description": "Armed soldiers fight from cover, peek and fire bursts. Flank them, keep moving.",
		"color": Color(0.95, 0.55, 0.3),
	},
]


static func mode_info(mode: String) -> Dictionary:
	for m: Dictionary in MODES:
		if m.id == mode:
			return m
	return MODES[0]


## The id best scores, stars and missions are saved under: the map id in
## Zombies ("town"), "combat_<map id>" in Combat ("combat_town").
static func save_key(map_id: String, mode := ZOMBIES) -> String:
	return map_id if mode == ZOMBIES else mode + "_" + map_id


## The map id of a save key ("combat_town" -> "town").
static func base_id(key: String) -> String:
	for m: Dictionary in MODES:
		if key.begins_with(m.id + "_"):
			return key.substr(m.id.length() + 1)
	return key


## The mode of a save key ("combat_town" -> "combat").
static func mode_of(key: String) -> String:
	for m: Dictionary in MODES:
		if key.begins_with(m.id + "_"):
			return m.id
	return ZOMBIES


## The map entry to load (LoadingScreen.go) for a map in a mode: Combat gets
## its own scene (maps/combat_<id>.tscn) and "mode".
static func for_mode(map_id: String, mode := ZOMBIES) -> Dictionary:
	var m := find(map_id).duplicate()
	m.mode = mode
	if mode == COMBAT:
		m.scene = "res://maps/combat_%s.tscn" % map_id
	return m
