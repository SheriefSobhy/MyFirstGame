extends Control
## Loading screen between the map selection and a match: the map's name and
## picture, a game tip and a progress bar while the map scene loads in the
## background (ResourceLoader threaded loading; the single-threaded web build
## loads in one go, so its bar jumps). Shown for at least MIN_TIME so the tip
## can be read.
##
## Use: LoadingScreen.go(get_tree(), map) where map is a maps.gd entry.

const SCENE := "res://ui/loading_screen.tscn"
const Maps := preload("res://maps.gd")
const MIN_TIME := 1.2        # s on screen at least
const BAR_SPEED := 2.5       # the bar catches up with the real progress (share per second)
const TIPS := [
	"Headshots do double damage and pay extra cash.",
	"Clear a wave to get 25 health back and open the shop.",
	"Red barrels explode: let the zombies gather around them first.",
	"Exploders blow up when they reach you. Shoot them from far away.",
	"Soldiers aim a red laser before they fire: get behind cover.",
	"Hold the grenade button to see where it will land.",
	"Armor from the shop takes part of every hit.",
	"Kill streaks pay bonus cash: keep the kills coming.",
	"Power-up drops: Double Points and Insta-Kill don't last long, use them!",
	"The Armory upgrades your weapons for good, with coins from every match.",
	"Daily missions pay coins. A new set comes every day.",
	"Every 5th wave brings the Brute Boss.",
	"Reach waves 5, 10 and 15 to earn a map's three stars.",
	"Aiming down the sights makes every gun more accurate.",
	"Settings > Customize Controls lets you move and resize the touch buttons.",
	"Battery low? Cap the frame rate at 30 FPS in Settings.",
	"Try your Armory upgrades and skins in the Training Arena first.",
]

## Combat mode (maps.gd for_mode(..., COMBAT)) shows these instead.
const COMBAT_TIPS := [
	"Soldiers hide behind cover and peek out to fire: shoot when they show.",
	"Flank a soldier to drive them out of their cover.",
	"Keep moving: soldiers hit a moving target far less often.",
	"Out of fire for 4 seconds, your health comes back.",
	"The red arrow shows where the shots came from.",
	"Soldiers crouch behind cars and crates and pop up to shoot.",
	"Headshots do double damage and pay extra cash.",
	"Combat has its own best scores and stars on every map.",
]

## The map being loaded (set by go()).
static var target := {}

var progress_bar: ProgressBar
var tip_label: Label
var title_label: Label
var _path := ""
var _shown := 0.0
var _real := 0.0
var _started := false
var _loaded: PackedScene


## Switches to the loading screen, which then loads `map` (maps.gd entry).
static func go(tree: SceneTree, map: Dictionary) -> void:
	target = map
	tree.change_scene_to_file(SCENE)


func _ready() -> void:
	get_tree().paused = false
	var map: Dictionary = target if not target.is_empty() else Maps.LIST[0]
	_path = map.scene
	_build(map)
	# Let the screen draw before the load starts (the web build blocks on it).
	await get_tree().process_frame
	await get_tree().process_frame
	if ResourceLoader.load_threaded_request(_path) != OK:
		push_warning("Could not start loading %s" % _path)
	_started = true


func _build(map: Dictionary) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.04, 0.05)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)
	var pic := TextureRect.new()
	pic.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.modulate = Color(0.45, 0.45, 0.45)
	if ResourceLoader.exists(map.get("thumbnail", "")):
		pic.texture = load(map.thumbnail)
	add_child(pic)
	var box := VBoxContainer.new()
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = -440
	box.offset_right = 440
	box.offset_top = -250
	box.offset_bottom = -50
	box.add_theme_constant_override("separation", 14)
	add_child(box)
	var combat: bool = map.get("mode", "") == Maps.COMBAT
	title_label = _label(map.get("name", "") + (" - Combat" if combat else ""), 48, map.get("color", Color.WHITE))
	box.add_child(title_label)
	tip_label = _label("Tip: " + (COMBAT_TIPS if combat else TIPS).pick_random(), 24, Color(1, 1, 1, 0.9))
	tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(tip_label)
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size = Vector2(0, 20)
	progress_bar.max_value = 1.0
	progress_bar.show_percentage = false
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0, 0, 0, 0.7)
	bar_bg.set_corner_radius_all(5)
	var fill := StyleBoxFlat.new()
	fill.bg_color = map.get("color", Color(1.0, 0.8, 0.35))
	fill.set_corner_radius_all(5)
	progress_bar.add_theme_stylebox_override("background", bar_bg)
	progress_bar.add_theme_stylebox_override("fill", fill)
	box.add_child(progress_bar)
	box.add_child(_label("Loading...", 20, Color(1, 1, 1, 0.6)))


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _process(delta: float) -> void:
	_shown += delta
	if _started and _loaded == null:
		var p := []
		match ResourceLoader.load_threaded_get_status(_path, p):
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				_real = p[0] if not p.is_empty() else _real
			ResourceLoader.THREAD_LOAD_LOADED:
				_loaded = ResourceLoader.load_threaded_get(_path)
				_real = 1.0
			_:
				# Failed: fall back to a normal (blocking) load.
				_loaded = load(_path)
				_real = 1.0
	# The bar moves smoothly; the last bit waits for the minimum time.
	var goal := minf(_real, _shown / MIN_TIME) if _real >= 1.0 else _real * 0.95
	progress_bar.value = move_toward(progress_bar.value, goal, BAR_SPEED * delta)
	if _loaded != null and progress_bar.value >= 1.0:
		set_process(false)
		get_tree().change_scene_to_packed(_loaded)
