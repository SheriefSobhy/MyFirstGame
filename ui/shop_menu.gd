extends Control
## The between-waves shop (opened from the HUD's SHOP button, or B on a
## keyboard). The game is paused while it is open, so the break countdown
## waits. Three tabs of big, touch-friendly buttons:
##  - Supplies: ammo refill, a grenade, armor, health.
##  - Weapons: buy the weapons you don't have (once your level unlocks them;
##    locked ones show the level they need).
##  - Upgrades: pick an owned weapon, then damage / mag size / reload speed
##    (3 levels each, rising price; this match only).
## READY closes it and starts the next wave right away; Close goes back to
## the break. Prices and effects: economy.gd. Purchases: match_economy.gd.

signal closed
signal ready_pressed

const Economy := preload("res://economy.gd")
const Weapons := preload("res://weapon_stats.gd")
const Progression := preload("res://progression_config.gd")
const THEME := preload("res://ui/theme.tres")
const BIG_FONT := 26
const COLOR_CASH := Color(0.45, 1.0, 0.45)
const COLOR_DIM := Color(1, 1, 1, 0.55)
const STATS := ["damage", "mag", "reload"]

var economy: Node
var player: Node
## The weapon the Upgrades tab shows.
var upgrade_weapon := 0

var _cash_label: Label
var _note: Label
var _note_tween: Tween
var _tabs: Array[Button] = []
var _pages: Array[Control] = []
var _supply_buttons := {}          # "ammo"... -> Button
var _weapon_buttons: Array[Button] = []
var _upgrade_pick_buttons: Array[Button] = []
var _upgrade_buttons := {}         # stat -> Button
var _ready_button: Button
var _close_button: Button


func _ready() -> void:
	theme = THEME
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.custom_minimum_size = Vector2(1120, 600)
	panel.offset_left = -560
	panel.offset_right = 560
	panel.offset_top = -300
	panel.offset_bottom = 300
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	# Header: title and cash.
	var header := HBoxContainer.new()
	box.add_child(header)
	var title := _label("SHOP", 34)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	_cash_label = _label("$0", 34, COLOR_CASH)
	header.add_child(_cash_label)

	# Tabs.
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 10)
	box.add_child(tab_row)
	var group := ButtonGroup.new()
	for i in 3:
		var tab := _button(["Supplies", "Weapons", "Upgrades"][i], Vector2(0, 60))
		tab.toggle_mode = true
		tab.button_group = group
		tab.size_flags_horizontal = SIZE_EXPAND_FILL
		tab.pressed.connect(show_tab.bind(i))
		tab_row.add_child(tab)
		_tabs.append(tab)

	var pages := Control.new()
	pages.custom_minimum_size = Vector2(0, 270)
	pages.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(pages)
	_pages = [_build_supplies(), _build_weapons(), _build_upgrades()]
	for p in _pages:
		p.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		pages.add_child(p)

	_note = _label("", 22, Color(1, 0.6, 0.4))
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_note)

	# Footer.
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 30)
	box.add_child(footer)
	_close_button = _button("Close", Vector2(240, 64))
	_close_button.pressed.connect(close)
	footer.add_child(_close_button)
	_ready_button = _button("READY  ▶", Vector2(300, 64))
	_ready_button.add_theme_color_override("font_color", COLOR_CASH)
	_ready_button.pressed.connect(_on_ready)
	footer.add_child(_ready_button)
	var hint := _label("The next wave waits while the shop is open", 20, COLOR_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	show_tab(0)


func open() -> void:
	visible = true
	upgrade_weapon = player.weapon_index
	refresh()
	if not DisplayServer.is_touchscreen_available():
		_ready_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _on_ready() -> void:
	visible = false
	ready_pressed.emit()


func show_tab(index: int) -> void:
	for i in _pages.size():
		_pages[i].visible = i == index
		_tabs[i].set_pressed_no_signal(i == index)
	refresh()


func current_tab() -> int:
	for i in _pages.size():
		if _pages[i].visible:
			return i
	return 0


# --- Pages ---------------------------------------------------------------------

func _build_supplies() -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	for key: String in ["ammo", "grenade", "armor", "health"]:
		var b := _button("", Vector2(0, 120))
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(_buy_supply.bind(key))
		grid.add_child(b)
		_supply_buttons[key] = b
	return grid


func _build_weapons() -> Control:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	for i in Weapons.LIST.size():
		var b := _button("", Vector2(0, 120))
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(_buy_weapon.bind(i))
		grid.add_child(b)
		_weapon_buttons.append(b)
	return grid


func _build_upgrades() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	var picks := GridContainer.new()
	picks.columns = 4
	picks.add_theme_constant_override("h_separation", 10)
	picks.add_theme_constant_override("v_separation", 10)
	box.add_child(picks)
	var group := ButtonGroup.new()
	for i in Weapons.LIST.size():
		var b := _button(Weapons.LIST[i].name, Vector2(0, 54), 22)
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			upgrade_weapon = i
			refresh())
		picks.add_child(b)
		_upgrade_pick_buttons.append(b)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	for stat: String in STATS:
		var b := _button("", Vector2(0, 130), 24)
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(_buy_upgrade.bind(stat))
		row.add_child(b)
		_upgrade_buttons[stat] = b
	return box


# --- Buying ----------------------------------------------------------------------

func _buy_supply(key: String) -> void:
	var price: int = {"ammo": Economy.AMMO_PRICE, "grenade": Economy.GRENADE_PRICE,
			"armor": Economy.ARMOR_PRICE, "health": Economy.HEALTH_PRICE}[key]
	var ok: bool = economy.call("buy_" + key)
	_after_buy(ok, price, "Already full")


func _buy_weapon(index: int) -> void:
	if player.has_weapon(index):
		return
	var ok: bool = economy.buy_weapon(index)
	_after_buy(ok, economy.weapon_price(index), "")
	if ok:
		upgrade_weapon = index


func _buy_upgrade(stat: String) -> void:
	var price: int = economy.upgrade_price(upgrade_weapon, stat)
	_after_buy(economy.buy_upgrade(upgrade_weapon, stat), price, "Maxed out")


func _after_buy(ok: bool, price: int, full_text: String) -> void:
	if ok:
		_show_note("")
	elif price >= 0 and not economy.can_afford(price):
		_show_note("Not enough cash")
	else:
		_show_note(full_text)
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
	if economy == null or player == null:
		return
	_cash_label.text = "$%d" % economy.cash
	var s := _supply_buttons
	_set_item(s.ammo, "Ammo Refill", "every weapon you own", Economy.AMMO_PRICE, true)
	_set_item(s.grenade, "Grenade", "%d / %d" % [player.grenades, player.MAX_GRENADES],
			Economy.GRENADE_PRICE, player.grenades < player.MAX_GRENADES)
	_set_item(s.armor, "Armor", "%d / %d" % [player.armor, Economy.MAX_ARMOR],
			Economy.ARMOR_PRICE, player.armor < Economy.MAX_ARMOR)
	_set_item(s.health, "Health", "%d / %d" % [player.health, player.MAX_HEALTH],
			Economy.HEALTH_PRICE, player.health < player.MAX_HEALTH)

	for i in _weapon_buttons.size():
		var w: Dictionary = Weapons.LIST[i]
		var b := _weapon_buttons[i]
		if player.has_weapon(i):
			b.text = "%s\nOwned" % w.name
			b.disabled = true
			b.modulate = Color.WHITE
		elif not economy.weapon_unlocked(i):
			b.text = "%s\nLocked\nLevel %d" % [w.name, Progression.weapon_unlock_level(w.name)]
			b.disabled = true
			b.modulate = Color(1, 1, 1, 0.45)
		else:
			_set_item(b, w.name, "", economy.weapon_price(i), true)

	if not player.has_weapon(upgrade_weapon):
		upgrade_weapon = player.weapon_index
	for i in _upgrade_pick_buttons.size():
		_upgrade_pick_buttons[i].visible = player.has_weapon(i)
		_upgrade_pick_buttons[i].set_pressed_no_signal(i == upgrade_weapon)
	for stat: String in STATS:
		var b: Button = _upgrade_buttons[stat]
		var level: int = player.upgrade_level(upgrade_weapon, stat)
		var now_next := _stat_text(stat, level)
		var title := "%s  %d/%d" % [Economy.UPGRADE_NAMES[stat], level, Economy.UPGRADE_LEVELS]
		if level >= Economy.UPGRADE_LEVELS:
			b.text = "%s\n%s\nMAX" % [title, now_next]
			b.disabled = true
		else:
			_set_item(b, title, now_next, Economy.upgrade_price(level), true)


# Damage 2 -> 3, Mag 12 -> 15, Reload 1.3s -> 1.1s (with the Armory's
# permanent upgrades included, so damage can be fractional: 2.4 -> 3.6).
func _stat_text(stat: String, level: int) -> String:
	var now := _stat_string(stat, player.stat_value(upgrade_weapon, stat, level))
	if level >= Economy.UPGRADE_LEVELS:
		return now
	return "%s → %s" % [now, _stat_string(stat, player.stat_value(upgrade_weapon, stat, level + 1))]


static func _stat_string(stat: String, value: float) -> String:
	if stat == "reload":
		return "%.1fs" % value
	if is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return "%.1f" % value


func _set_item(b: Button, title: String, detail: String, price: int, available: bool) -> void:
	var lines := [title]
	if detail != "":
		lines.append(detail)
	lines.append("$%d" % price)
	b.text = "\n".join(lines)
	b.disabled = not available
	# Too expensive: still pressable (it says why), but dimmed.
	b.modulate = Color.WHITE if economy.can_afford(price) else Color(1, 1, 1, 0.55)


func _label(text: String, font_size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(text: String, min_size: Vector2, font_size := BIG_FONT) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = FOCUS_ALL if not DisplayServer.is_touchscreen_available() else FOCUS_NONE
	b.add_theme_font_size_override("font_size", font_size)
	return b
