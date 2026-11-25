extends Control
## The Armory (from the main menu): spend coins on permanent weapon upgrades
## (damage, magazine, reload; 5 levels each) and weapon skins. Pick a weapon
## at the top; the turning preview shows it in its equipped skin. Weapons
## your level hasn't unlocked yet show the level they need.
## Prices and effects: progression_config.gd. State: progress.gd.

signal closed

const Config := preload("res://progression_config.gd")
const Weapons := preload("res://weapon_stats.gd")
const WeaponModel := preload("res://weapon_model.gd")
const WeaponSkins := preload("res://weapon_skins.gd")
const THEME := preload("res://ui/theme.tres")
const COLOR_GOLD := Color(1.0, 0.8, 0.35)
const COLOR_DIM := Color(1, 1, 1, 0.55)
const STATS := ["damage", "mag", "reload"]
const STAT_NAMES := {"damage": "Damage", "mag": "Mag Size", "reload": "Reload Speed"}

## The weapon being looked at (Weapons.LIST index).
var weapon := 0

var _coins_label: Label
var _note: Label
var _note_tween: Tween
var _weapon_buttons: Array[Button] = []
var _tabs: Array[Button] = []
var _pages: Array[Control] = []
var _lock_label: Label
var _upgrade_buttons := {}    # stat -> Button
var _skin_buttons := {}       # skin id -> Button
var _back_button: Button
var _preview_holder: Node3D
var _preview_model: Node3D
var _preview_time := 0.0


func _ready() -> void:
	theme = THEME
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.offset_left = -600
	panel.offset_right = 600
	panel.offset_top = -340
	panel.offset_bottom = 340
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := _label("ARMORY", 34)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	_coins_label = _label("0 coins", 32, COLOR_GOLD)
	header.add_child(_coins_label)

	var picks := GridContainer.new()
	picks.columns = 4
	picks.add_theme_constant_override("h_separation", 10)
	picks.add_theme_constant_override("v_separation", 8)
	box.add_child(picks)
	var group := ButtonGroup.new()
	for i in Weapons.LIST.size():
		var b := _button("", Vector2(0, 50), 21)
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(select_weapon.bind(i))
		picks.add_child(b)
		_weapon_buttons.append(b)

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 14)
	middle.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(middle)
	middle.add_child(_build_preview())

	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	middle.add_child(right)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 10)
	right.add_child(tab_row)
	var tab_group := ButtonGroup.new()
	for i in 2:
		var tab := _button(["Upgrades", "Skins"][i], Vector2(0, 54))
		tab.toggle_mode = true
		tab.button_group = tab_group
		tab.size_flags_horizontal = SIZE_EXPAND_FILL
		tab.pressed.connect(show_tab.bind(i))
		tab_row.add_child(tab)
		_tabs.append(tab)
	_lock_label = _label("", 24, Color(1, 0.6, 0.4))
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(_lock_label)
	var pages := Control.new()
	pages.size_flags_vertical = SIZE_EXPAND_FILL
	pages.custom_minimum_size = Vector2(0, 230)
	right.add_child(pages)
	_pages = [_build_upgrades(), _build_skins()]
	for p in _pages:
		p.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		pages.add_child(p)

	_note = _label("", 22, Color(1, 0.6, 0.4))
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_note)
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(footer)
	_back_button = _button("Back", Vector2(260, 62))
	_back_button.pressed.connect(close)
	footer.add_child(_back_button)

	Progress.changed.connect(refresh)
	show_tab(0)
	select_weapon(0)


func _process(delta: float) -> void:
	if visible and _preview_holder:
		_preview_time += delta
		_preview_holder.rotation.y = sin(_preview_time * 0.8) * 0.5 - 0.35


func open() -> void:
	visible = true
	refresh()
	if not DisplayServer.is_touchscreen_available():
		_back_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("release_mouse"):
		close()
		get_viewport().set_input_as_handled()


func select_weapon(index: int) -> void:
	weapon = index
	_show_preview()
	refresh()


func show_tab(index: int) -> void:
	for i in _pages.size():
		_pages[i].visible = i == index
		_tabs[i].set_pressed_no_signal(i == index)
	refresh()


func current_tab() -> int:
	return 1 if _pages[1].visible else 0


# --- Pages ---------------------------------------------------------------------

func _build_upgrades() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	for stat: String in STATS:
		var b := _button("", Vector2(0, 170), 23)
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(_buy_upgrade.bind(stat))
		row.add_child(b)
		_upgrade_buttons[stat] = b
	return row


func _build_skins() -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for id: String in Config.SKINS:
		var b := _button("", Vector2(0, 100), 21)
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		var skin_color: Color = Config.SKINS[id].color
		for style_name: String in ["normal", "hover", "pressed", "disabled", "focus"]:
			var base := THEME.get_stylebox(style_name, "Button")
			if base is StyleBoxFlat:
				var s: StyleBoxFlat = base.duplicate()
				s.border_color = skin_color if id != "standard" else Color(1, 1, 1, 0.4)
				s.set_border_width_all(4)
				b.add_theme_stylebox_override(style_name, s)
		b.pressed.connect(_skin_pressed.bind(id))
		grid.add_child(b)
		_skin_buttons[id] = b
	return grid


# The turning gun on the left (its own little 3D world).
func _build_preview() -> Control:
	var frame := SubViewportContainer.new()
	frame.custom_minimum_size = Vector2(400, 300)
	frame.stretch = true
	frame.mouse_filter = MOUSE_FILTER_IGNORE
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_2X
	frame.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.08, 1.25)
	cam.fov = 40.0
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 35, 0)
	sun.light_energy = 1.4
	vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, -140, 0)
	fill.light_energy = 0.5
	vp.add_child(fill)
	_preview_holder = Node3D.new()
	vp.add_child(_preview_holder)
	return frame


func _show_preview() -> void:
	if _preview_holder == null:
		return
	if _preview_model:
		_preview_model.queue_free()
	var w: Dictionary = Weapons.LIST[weapon]
	var model: Node3D = w.model.instantiate()
	var aabb: AABB = WeaponModel.measure(model).aabb
	var s := 0.9 / aabb.size.x
	model.scale = Vector3.ONE * s
	model.position = -aabb.get_center() * s
	WeaponSkins.apply(model, Progress.skin_of(w.name))
	_preview_holder.add_child(model)
	_preview_model = model


## The preview gun (for tests).
func preview_model() -> Node3D:
	return _preview_model


# --- Buying ----------------------------------------------------------------------

func _weapon_name() -> String:
	return Weapons.LIST[weapon].name


func _buy_upgrade(stat: String) -> void:
	var price := Config.perm_price(Progress.upgrade_level(_weapon_name(), stat))
	if Progress.buy_upgrade(_weapon_name(), stat):
		_show_note("")
	elif price >= 0 and Progress.coins < price:
		_show_note("Not enough coins")
	refresh()


func _skin_pressed(id: String) -> void:
	var wname := _weapon_name()
	if Progress.owns_skin(wname, id):
		Progress.equip_skin(wname, id)
	elif Progress.buy_skin(wname, id):
		_show_note("")
	elif Progress.coins < Config.SKINS[id].price:
		_show_note("Not enough coins")
	_show_preview()
	refresh()


func _show_note(text: String) -> void:
	_note.text = text
	_note.modulate.a = 1.0
	if _note_tween:
		_note_tween.kill()
	if text != "":
		_note_tween = create_tween()
		_note_tween.tween_interval(1.2)
		_note_tween.tween_property(_note, "modulate:a", 0.0, 0.4)


# --- Showing the current state ------------------------------------------------------

func refresh() -> void:
	if _coins_label == null:
		return
	_coins_label.text = "%d coins" % Progress.coins
	for i in _weapon_buttons.size():
		var n: String = Weapons.LIST[i].name
		var b := _weapon_buttons[i]
		b.set_pressed_no_signal(i == weapon)
		if Progress.is_weapon_unlocked(n):
			b.text = n
			b.modulate = Color.WHITE
		else:
			b.text = "%s  (Lv %d)" % [n, Config.weapon_unlock_level(n)]
			b.modulate = Color(1, 1, 1, 0.55)

	var wname := _weapon_name()
	var unlocked := Progress.is_weapon_unlocked(wname)
	_lock_label.text = "" if unlocked else "Locked: unlocks at level %d" % Config.weapon_unlock_level(wname)
	_lock_label.visible = not unlocked

	for stat: String in STATS:
		var b: Button = _upgrade_buttons[stat]
		var lv := Progress.upgrade_level(wname, stat)
		var title := "%s\n%d / %d" % [STAT_NAMES[stat], lv, Config.PERM_LEVELS]
		var price := Config.perm_price(lv)
		if price < 0:
			b.text = "%s\n%s\nMAX" % [title, _bonus_text(stat, lv)]
			b.disabled = true
			b.modulate = Color.WHITE
		else:
			b.text = "%s\n%s → %s\n%d coins" % [title, _bonus_text(stat, lv), _bonus_text(stat, lv + 1), price]
			b.disabled = not unlocked
			b.modulate = Color.WHITE if unlocked and Progress.coins >= price else Color(1, 1, 1, 0.55)

	for id: String in _skin_buttons:
		var b: Button = _skin_buttons[id]
		var skin: Dictionary = Config.SKINS[id]
		var state: String
		if Progress.skin_of(wname) == id:
			state = "Equipped"
		elif Progress.owns_skin(wname, id):
			state = "Owned: equip"
		else:
			state = "%d coins" % skin.price
		b.text = "%s\n%s" % [skin.name, state]
		b.disabled = not unlocked
		var affordable: bool = Progress.owns_skin(wname, id) or Progress.coins >= skin.price
		b.modulate = Color.WHITE if unlocked and affordable else Color(1, 1, 1, 0.55)


# "+16%" damage / mag, "-12%" reload time.
static func _bonus_text(stat: String, level: int) -> String:
	if level == 0:
		return "0%"
	match stat:
		"damage":
			return "+%d%%" % roundi(Config.PERM_DAMAGE * level * 100.0)
		"mag":
			return "+%d%%" % roundi(Config.PERM_MAG * level * 100.0)
		_:
			return "-%d%%" % roundi(Config.PERM_RELOAD * level * 100.0)


func _label(text: String, font_size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(text: String, min_size: Vector2, font_size := 26) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = FOCUS_ALL if not DisplayServer.is_touchscreen_available() else FOCUS_NONE
	b.add_theme_font_size_override("font_size", font_size)
	return b
