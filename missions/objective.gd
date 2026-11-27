extends Node
## Base of a mission objective type (missions/defend.gd, missions/rescue.gd).
## missions/mission_mode.gd creates the one for the mission's "type" and
## calls these; a new type only needs to fill them in (and an entry in
## mission_mode.gd TYPES + missions_config.gd TYPE_NAMES):
##   setup()        build its things in the level (before the briefing)
##   begin()        START was pressed: the clock runs from now
##   tick(delta)    every frame while running: update the tracker and marker
##                  (mode.ui), call mode.finish(true / false, reason)
##   star2()        the mission's second star (the first is completing it,
##                  the third finishing above half health)
## mode gives: mission (its missions_config.gd entry), player, ui, elapsed,
## snap(), spawn_soldier_at(), queue_soldiers(), add_interactable(), finish().

var mode: Node
var mission: Dictionary


func setup() -> void:
	pass


func begin() -> void:
	pass


func tick(_delta: float) -> void:
	pass


func star2() -> bool:
	return true
