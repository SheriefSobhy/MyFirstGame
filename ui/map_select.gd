extends Control
## Map selection, shown after Play on the main menu: one card per map in
## maps.gd with its picture, description and best score. Picking a card loads
## that map; Back returns to the main menu.

const Maps := preload("res://maps.gd")
const MENU_SCENE := "res://ui/main_menu.tscn"

@onready var cards: HBoxContainer = %Cards
@onready var back_button: Button = %BackButton
@onready var loading_label: Label = %Loading

## The Play button of each card, by map id (also used by the tests).
var play_buttons := {}


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for m: Dictionary in Maps.LIST:
		cards.add_child(_make_card(m))
	back_button.pressed.connect(_on_back)
	Music.play_menu()
	if not DisplayServer.is_touchscreen_available():
		play_buttons[Maps.LIST[0].id].grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		_on_back()
		get_viewport().set_input_as_handled()


func _make_card(m: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.05, 0.85)
	style.border_color = m.color
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)

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

	var title := Label.new()
	title.text = m.name
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", m.color)
	box.add_child(title)

	var desc := Label.new()
	desc.text = m.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 56)
	desc.add_theme_font_size_override("font_size", 18)
	desc.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	box.add_child(desc)

	var best := Label.new()
	best.name = "Best"
	var score := Settings.best_score_for(m.id)
	best.text = "Best: %d   (wave %d)" % [score, Settings.best_wave_for(m.id)] if score > 0 else "Best: -"
	best.add_theme_font_size_override("font_size", 20)
	box.add_child(best)

	var play := Button.new()
	play.name = "Play"
	play.text = "Play"
	play.custom_minimum_size = Vector2(0, 64)
	play.add_theme_font_size_override("font_size", 30)
	play.pressed.connect(_on_play.bind(m))
	box.add_child(play)
	play_buttons[m.id] = play
	return panel


func _on_play(m: Dictionary) -> void:
	for b: Button in play_buttons.values():
		b.disabled = true
	back_button.disabled = true
	loading_label.text = "Loading %s..." % m.name
	loading_label.visible = true
	# Let "Loading..." draw before the map loads (that takes a moment).
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file(m.scene)


func _on_back() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)
