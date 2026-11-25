extends Control
## Shown when the player dies and still has a revive this match (main.gd):
## "Watch ad to revive" or "No thanks" (also after REVIVE_OFFER_TIME).
## The ad is a placeholder for now: a 3-second fake ad screen, then
## `revived`. To connect real rewarded ads, replace _play_ad(): call the ad
## SDK there and call _ad_finished() when the reward is granted (or
## _ad_failed() if no ad could be shown).
## Runs while the game is paused.

signal revived
signal declined

const Economy := preload("res://economy.gd")
const THEME := preload("res://ui/theme.tres")
const COLOR_GOLD := Color(1.0, 0.8, 0.35)

var offer_panel: Control
var ad_panel: Control
var watch_button: Button
var no_button: Button
var _countdown_label: Label
var _ad_label: Label
var _ad_bar: ProgressBar
var _offer_left := 0.0
var _ad_left := 0.0
var _in_ad := false


func _init() -> void:
	theme = THEME
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false


func _ready() -> void:
	# The offer: dim the game, a panel in the middle.
	offer_panel = Control.new()
	offer_panel.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(offer_panel)
	var dim := ColorRect.new()
	dim.color = Color(0.25, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	offer_panel.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.offset_left = -330
	panel.offset_right = 330
	panel.offset_top = -170
	panel.offset_bottom = 170
	offer_panel.add_child(panel)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	box.add_child(_label("You died!", 48, Color(1, 0.4, 0.35)))
	box.add_child(_label("Come back with full health. Enemies near you are pushed away.", 22, Color.WHITE))
	watch_button = Button.new()
	watch_button.text = "Watch ad to revive"
	watch_button.custom_minimum_size = Vector2(380, 70)
	watch_button.size_flags_horizontal = SIZE_SHRINK_CENTER
	watch_button.add_theme_color_override("font_color", COLOR_GOLD)
	watch_button.pressed.connect(_play_ad)
	box.add_child(watch_button)
	no_button = Button.new()
	no_button.text = "No thanks"
	no_button.custom_minimum_size = Vector2(240, 56)
	no_button.size_flags_horizontal = SIZE_SHRINK_CENTER
	no_button.pressed.connect(_decline)
	box.add_child(no_button)
	_countdown_label = _label("", 20, Color(1, 1, 1, 0.6))
	box.add_child(_countdown_label)

	# The placeholder ad: a black screen with a countdown.
	ad_panel = ColorRect.new()
	(ad_panel as ColorRect).color = Color(0.02, 0.02, 0.03)
	ad_panel.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	ad_panel.visible = false
	add_child(ad_panel)
	var ad_box := VBoxContainer.new()
	ad_box.set_anchors_and_offsets_preset(PRESET_CENTER)
	ad_box.offset_left = -300
	ad_box.offset_right = 300
	ad_box.offset_top = -100
	ad_box.offset_bottom = 100
	ad_box.add_theme_constant_override("separation", 18)
	ad_panel.add_child(ad_box)
	ad_box.add_child(_label("Advertisement", 40, Color(1, 1, 1, 0.85)))
	_ad_label = _label("", 24, Color(1, 1, 1, 0.6))
	ad_box.add_child(_ad_label)
	_ad_bar = ProgressBar.new()
	_ad_bar.custom_minimum_size = Vector2(0, 14)
	_ad_bar.show_percentage = false
	_ad_bar.max_value = Economy.REVIVE_AD_TIME
	ad_box.add_child(_ad_bar)


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Shows "Watch ad to revive" / "No thanks".
func offer() -> void:
	visible = true
	offer_panel.visible = true
	ad_panel.visible = false
	_in_ad = false
	_offer_left = Economy.REVIVE_OFFER_TIME
	_update_countdown()
	if not DisplayServer.is_touchscreen_available():
		watch_button.grab_focus()


func is_open() -> bool:
	return visible


func _process(delta: float) -> void:
	if not visible:
		return
	if _in_ad:
		_ad_left -= delta
		_ad_bar.value = Economy.REVIVE_AD_TIME - _ad_left
		_ad_label.text = "Placeholder ad: your game continues in %d" % ceili(maxf(_ad_left, 0.0))
		if _ad_left <= 0.0:
			_ad_finished()
		return
	_offer_left -= delta
	_update_countdown()
	if _offer_left <= 0.0:
		_decline()


func _update_countdown() -> void:
	_countdown_label.text = "Game over in %d" % ceili(maxf(_offer_left, 0.0))


# Placeholder: a fake 3-second ad. Real ads go here (see the top).
func _play_ad() -> void:
	if _in_ad:
		return
	_in_ad = true
	_ad_left = Economy.REVIVE_AD_TIME
	_ad_bar.value = 0.0
	offer_panel.visible = false
	ad_panel.visible = true


func _ad_finished() -> void:
	_in_ad = false
	visible = false
	revived.emit()


func _ad_failed() -> void:
	_decline()


func _decline() -> void:
	_in_ad = false
	visible = false
	declined.emit()
