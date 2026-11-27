extends Control
## Play on the main menu opens this: first choose a mode (Zombies / Combat,
## maps.gd MODES), then a map: one card per map in maps.gd with its picture,
## description, and the best score and stars (3 per map) of that mode.
## Maps your level hasn't unlocked show the level they need (the same in
## both modes). Picking a card opens the loading screen
## (ui/loading_screen.gd), which loads that map in the chosen mode. Back goes
## from the maps to the modes, and from the modes to the main menu.

const Maps := preload("res://maps.gd")
const Progression := preload("res://progression_config.gd")
const StarRow := preload("res://ui/star_row.gd")
const MENU_SCENE := "res://ui/main_menu.tscn"
const LoadingScreen := preload("res://ui/loading_screen.gd")

## The mode picked last (the map cards show it; Zombies at first).
static var last_mode := Maps.ZOMBIES

@onready var cards: HBoxContainer = %Cards
@onready var back_button: Button = %BackButton
@onready var loading_label: Label = %Loading
@onready var title: Label = $Margin/Box/Title

## The mode the map cards are for.
var mode := Maps.ZOMBIES
## The Play button of each map card, by map id (also used by the tests).
## Built for `mode`, also while the mode step is showing.
var play_buttons := {}
## The button of each mode card, by mode id.
var mode_buttons := {}
## True while the mode step (Zombies / Combat) is showing.
var choosing_mode := true
var _mode_cards: HBoxContainer


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mode_cards = HBoxContainer.new()
	_mode_cards.name = "ModeCards"
	_mode_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	_mode_cards.add_theme_constant_override("separation", 24)
	cards.add_sibling(_mode_cards)
	for m: Dictionary in Maps.MODES:
		_mode_cards.add_child(_make_mode_card(m))
	_build_map_cards(last_mode)
	back_button.pressed.connect(_on_back)
	Music.play_menu()
	show_modes()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		_on_back()
		get_viewport().set_input_as_handled()


## Shows the mode step.
func show_modes() -> void:
	choosing_mode = true
	title.text = "Choose a mode"
	_mode_cards.visible = true
	cards.visible = false
	if not DisplayServer.is_touchscreen_available():
		mode_buttons[last_mode].grab_focus()


## Picks a mode and shows its map cards.
func choose_mode(id: String) -> void:
	last_mode = id
	_build_map_cards(id)
	choosing_mode = false
	title.text = "%s: choose a map" % Maps.mode_info(id).name
	_mode_cards.visible = false
	cards.visible = true
	if not DisplayServer.is_touchscreen_available():
		play_buttons[Maps.LIST[0].id].grab_focus()


func _build_map_cards(id: String) -> void:
	mode = id
	for c in cards.get_children():
		cards.remove_child(c)
		c.queue_free()
	play_buttons.clear()
	for m: Dictionary in Maps.LIST:
		cards.add_child(_make_card(m))


func _card_panel(color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.05, 0.85)
	style.border_color = color
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_mode_card(m: Dictionary) -> Control:
	var panel := _card_panel(m.color)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var name_label := Label.new()
	name_label.text = m.name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 44)
	name_label.add_theme_color_override("font_color", m.color)
	box.add_child(name_label)

	var desc := Label.new()
	desc.text = m.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 84)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", 20)
	desc.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	box.add_child(desc)

	# Best score and stars over all maps in this mode.
	var best := 0
	var stars := 0
	for map: Dictionary in Maps.LIST:
		var key := Maps.save_key(map.id, m.id)
		best = maxi(best, Settings.best_score_for(key))
		stars += Progress.stars(key)
	var info := Label.new()
	info.name = "Info"
	info.text = "Best: %s     Stars: %d / %d" % [str(best) if best > 0 else "-", stars, Maps.LIST.size() * 3]
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 20)
	box.add_child(info)

	var button := Button.new()
	button.name = "Choose"
	button.text = "Play %s" % m.name
	button.custom_minimum_size = Vector2(0, 72)
	button.add_theme_font_size_override("font_size", 32)
	button.pressed.connect(choose_mode.bind(m.id))
	box.add_child(button)
	mode_buttons[m.id] = button
	return panel


func _make_card(m: Dictionary) -> Control:
	var key := Maps.save_key(m.id, mode)
	var panel := _card_panel(m.color)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(0, 190)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	if ResourceLoader.exists(m.thumbnail):
		pic.texture = load(m.thumbnail)
	box.add_child(pic)

	var title_label := Label.new()
	title_label.text = m.name
	title_label.add_theme_font_size_override("font_size", 30)
	title_label.add_theme_color_override("font_color", m.color)
	box.add_child(title_label)

	var desc := Label.new()
	desc.text = m.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 56)
	desc.add_theme_font_size_override("font_size", 18)
	desc.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	box.add_child(desc)

	var best := Label.new()
	best.name = "Best"
	var score := Settings.best_score_for(key)
	best.text = "Best: %d   (wave %d)" % [score, Settings.best_wave_for(key)] if score > 0 else "Best: -"
	best.add_theme_font_size_override("font_size", 20)
	box.add_child(best)

	# Stars: reach wave 5 / 10 / 15 (progression_config.gd STAR_WAVES).
	var star_row := HBoxContainer.new()
	star_row.add_theme_constant_override("separation", 12)
	box.add_child(star_row)
	var stars := StarRow.new(Progress.stars(key), 28.0)
	stars.name = "Stars"
	star_row.add_child(stars)
	var star_hint := Label.new()
	star_hint.text = "Reach wave %s" % " / ".join(Progression.STAR_WAVES.map(func(w: int) -> String: return str(w)))
	star_hint.add_theme_font_size_override("font_size", 16)
	star_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	star_row.add_child(star_hint)

	var play := Button.new()
	play.name = "Play"
	play.custom_minimum_size = Vector2(0, 64)
	play.add_theme_font_size_override("font_size", 30)
	if Progress.is_map_unlocked(m.id):
		play.text = "Play"
	else:
		# Locked until the player's level is high enough (the same in both modes).
		play.text = "Locked: Level %d" % Progression.map_unlock_level(m.id)
		play.disabled = true
		pic.modulate = Color(0.35, 0.35, 0.35)
	play.pressed.connect(_on_play.bind(m))
	box.add_child(play)
	play_buttons[m.id] = play
	return panel


func _on_play(m: Dictionary) -> void:
	if not Progress.is_map_unlocked(m.id):
		return
	for b: Button in play_buttons.values():
		b.disabled = true
	back_button.disabled = true
	# The loading screen (tip + progress bar) loads the map in the mode.
	LoadingScreen.go(get_tree(), Maps.for_mode(m.id, mode))


func _on_back() -> void:
	if not choosing_mode:
		show_modes()
		return
	get_tree().change_scene_to_file(MENU_SCENE)
