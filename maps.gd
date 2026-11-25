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


static func find(id: String) -> Dictionary:
	for m: Dictionary in LIST:
		if m.id == id:
			return m
	return LIST[0]
