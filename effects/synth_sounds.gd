extends RefCounted
## Small feedback sounds made in code (no audio files to download or
## license): the hit marker tick, the headshot "tink", the kill sound and the
## low-health heartbeat. Each is built once (a few ms) and then cached.

const RATE := 22050

static var _cache := {}


## Short dry click for every hit.
static func hit_tick() -> AudioStreamWAV:
	return _build("tick", func(t: float) -> float:
		return (sin(TAU * 2900.0 * t) * 0.6 + sin(TAU * 4700.0 * t) * 0.3) * exp(-t * 140.0), 0.05)


## Bright metallic ring for a headshot.
static func headshot() -> AudioStreamWAV:
	return _build("headshot", func(t: float) -> float:
		var ring := sin(TAU * 2350.0 * t) * 0.5 + sin(TAU * 3870.0 * t) * 0.3 + sin(TAU * 5610.0 * t) * 0.2
		var knock := sin(TAU * lerpf(900.0, 300.0, minf(t / 0.03, 1.0)) * t) * exp(-t * 90.0)
		return ring * exp(-t * 16.0) * 0.8 + knock * 0.5, 0.35)


## A deep thump with a short chime on top: confirms a kill.
static func kill() -> AudioStreamWAV:
	return _build("kill", func(t: float) -> float:
		# The thump's pitch falls from 170 Hz to 45 Hz (phase is the integral).
		var phase := TAU * (45.0 * t + 125.0 * (1.0 - exp(-t * 30.0)) / 30.0)
		var thump := sin(phase) * exp(-t * 14.0)
		var chime := (sin(TAU * 1320.0 * t) * 0.6 + sin(TAU * 1980.0 * t) * 0.4) * exp(-t * 11.0)
		var attack := minf(t / 0.004, 1.0)
		return (thump * 0.8 + chime * 0.35) * attack, 0.4)


## Rising three-note arpeggio for picking up a power-up.
static func powerup() -> AudioStreamWAV:
	return _build("powerup", func(t: float) -> float:
		var note := mini(int(t / 0.09), 2)
		var freq: float = [660.0, 830.0, 990.0][note]
		var x := t - note * 0.09
		var env := minf(x / 0.005, 1.0) * exp(-x * (6.0 if note == 2 else 14.0))
		return (sin(TAU * freq * t) * 0.6 + sin(TAU * freq * 2.0 * t) * 0.25) * env, 0.6)


## "Lub-dub": two soft low thumps.
static func heartbeat() -> AudioStreamWAV:
	return _build("heart", func(t: float) -> float:
		return _thump(t, 0.0, 58.0) + _thump(t, 0.17, 50.0) * 0.75, 0.5)


static func _thump(t: float, start: float, freq: float) -> float:
	var x := t - start
	if x < 0.0:
		return 0.0
	return sin(TAU * freq * x) * minf(x / 0.008, 1.0) * exp(-x * 22.0)


static func _build(key: String, wave: Callable, length: float) -> AudioStreamWAV:
	if _cache.has(key):
		return _cache[key]
	var count := int(RATE * length)
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / RATE
		var fade := minf(1.0, (length - t) / 0.01)  # no click at the end
		var v: float = clampf(wave.call(t) * fade, -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	_cache[key] = s
	return s
