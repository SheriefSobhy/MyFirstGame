extends RefCounted
## Phone vibration, used through the static functions below. Does nothing
## when the Vibration setting is off. Only phones/tablets actually vibrate
## (Android, and browsers that support it); other devices just record the
## request in `history` (the tests read it).
##
## A light pulse never cuts short a stronger one that is still running
## (a new vibration replaces the current one on Android).

const SHOT := {"ms": 12, "amp": 0.25}
const KILL := {"ms": 45, "amp": 0.7}
const DAMAGE := {"ms": 70, "amp": 0.85}
const EXPLOSION := {"ms": 110, "amp": 1.0}

## Names of the pulses asked for (most recent last, the last 20).
static var history: Array[String] = []
static var _busy_until_ms := 0
static var _busy_amp := 0.0


## The first vibration of a run costs ~80 ms on Android (the vibrator
## service is looked up then): main.gd calls this while the level loads, so
## the first shot doesn't stutter. Too short and weak to feel.
static func warm_up() -> void:
	var settings := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Settings")
	if settings != null and settings.haptics and DisplayServer.is_touchscreen_available():
		Input.vibrate_handheld(1, 0.01)


static func shot() -> void:
	_pulse("shot", SHOT.ms, SHOT.amp)


static func kill() -> void:
	_pulse("kill", KILL.ms, KILL.amp)


static func damage() -> void:
	_pulse("damage", DAMAGE.ms, DAMAGE.amp)


## strength 0..1 (closer explosions shake more).
static func explosion(strength: float) -> void:
	if strength > 0.05:
		_pulse("explosion", roundi(EXPLOSION.ms * clampf(strength, 0.4, 1.0)), EXPLOSION.amp * clampf(strength, 0.4, 1.0))


static func _pulse(kind: String, ms: int, amp: float) -> void:
	# The Settings autoload, looked up at run time (so the test scripts,
	# which can't see autoload names, can load this file too).
	var settings := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Settings")
	if settings == null or not settings.haptics:
		return
	var now := Time.get_ticks_msec()
	if now < _busy_until_ms and amp < _busy_amp:
		return
	_busy_until_ms = now + ms
	_busy_amp = amp
	history.append(kind)
	if history.size() > 20:
		history.remove_at(0)
	if DisplayServer.is_touchscreen_available():
		Input.vibrate_handheld(ms, amp)
