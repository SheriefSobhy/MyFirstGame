extends RefCounted
## Small feedback sounds made in code (no audio files to download or
## license): the hit marker tick, the headshot "tink", the kill sound and the
## low-health heartbeat, and the missions' C4 beep, radio, helicopter rotor and
## engine loops. Each is built once (a few ms) and then cached.

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


## A steel plate ringing when hit (Training Arena metal targets).
static func ding() -> AudioStreamWAV:
	return _build("ding", func(t: float) -> float:
		var ring := sin(TAU * 1180.0 * t) * 0.5 + sin(TAU * 2730.0 * t) * 0.3 + sin(TAU * 4410.0 * t) * 0.15
		var knock := sin(TAU * 420.0 * t) * exp(-t * 60.0)
		return (ring * exp(-t * 7.0) * 0.8 + knock * 0.4) * minf(t / 0.002, 1.0), 0.7)


## A soft rising blip: a pop-up target appears (Training Arena challenges).
static func blip() -> AudioStreamWAV:
	return _build("blip", func(t: float) -> float:
		var f := lerpf(700.0, 1100.0, minf(t / 0.06, 1.0))
		return sin(TAU * f * t) * minf(t / 0.004, 1.0) * exp(-t * 30.0) * 0.5, 0.12)


## "Lub-dub": two soft low thumps.
static func heartbeat() -> AudioStreamWAV:
	return _build("heart", func(t: float) -> float:
		return _thump(t, 0.0, 58.0) + _thump(t, 0.17, 50.0) * 0.75, 0.5)


## Missions: the C4 charge's short high beep.
static func c4_beep() -> AudioStreamWAV:
	return _build("c4", func(t: float) -> float:
		return (sin(TAU * 2600.0 * t) * 0.6 + sin(TAU * 5200.0 * t) * 0.15) * minf(t / 0.003, 1.0) * exp(-t * 25.0), 0.09)


## Missions: a burst of radio static with a squelch beep (the Commander
## calling for help).
static func radio() -> AudioStreamWAV:
	var lp := [0.0, 0.0]
	return _build("radio", func(t: float) -> float:
		var n := randf() * 2.0 - 1.0
		lp[0] = float(lp[0]) + (n - float(lp[0])) * 0.35
		lp[1] = float(lp[1]) + (float(lp[0]) - float(lp[1])) * 0.35
		var band: float = float(lp[0]) - float(lp[1])  # roughly 1-3 kHz
		var gate := 1.0 if fmod(t, 0.11) < 0.08 else 0.35
		var squelch := sin(TAU * 1400.0 * t) * 0.4 if t < 0.08 else 0.0
		return band * 1.6 * gate * minf(t / 0.01, 1.0) + squelch, 0.75)


## Combat: a short radio blip (two beeps in static) when a soldier alerts.
static func radio_alert() -> AudioStreamWAV:
	return _build("radio_alert", func(t: float) -> float:
		var beep := sin(TAU * (1250.0 if t < 0.09 else 950.0) * t) * 0.45
		var gap := 0.0 if t > 0.07 and t < 0.1 else 1.0
		return (beep * gap + (randf() - 0.5) * 0.25) * minf(t / 0.005, 1.0), 0.18)


## Missions: the helicopter, a seamless 1 s loop: blade thumps 11 times a
## second (low-passed noise + a low tone) over a quiet turbine whine.
static func rotor_loop() -> AudioStreamWAV:
	var lp := [0.0]
	return _build("rotor", func(t: float) -> float:
		var phase := fmod(t * 11.0, 1.0)
		var env := exp(-phase * 9.0)
		var n := randf() * 2.0 - 1.0
		lp[0] = float(lp[0]) + (n - float(lp[0])) * 0.08
		var thump: float = float(lp[0]) * 3.0 * env + sin(TAU * 66.0 * t) * env * 0.5
		var whine := sin(TAU * 880.0 * t) * 0.04 + sin(TAU * 1320.0 * t) * 0.02
		return thump * 0.8 + whine, 1.0, true)


## Missions: an engine idling, a seamless 1 s loop (40 Hz firing).
static func engine_loop() -> AudioStreamWAV:
	return _build("engine", func(t: float) -> float:
		var p := fmod(t * 40.0, 1.0)
		var saw := 1.0 - 2.0 * p
		var wobble := 1.0 + 0.25 * sin(TAU * 5.0 * t)
		return (saw * 0.35 + sin(TAU * 80.0 * t) * 0.25 + sin(TAU * 120.0 * t) * 0.1) * wobble * 0.7, 1.0, true)


static func _thump(t: float, start: float, freq: float) -> float:
	var x := t - start
	if x < 0.0:
		return 0.0
	return sin(TAU * freq * x) * minf(x / 0.008, 1.0) * exp(-x * 22.0)


static func _build(key: String, wave: Callable, length: float, loop := false) -> AudioStreamWAV:
	if _cache.has(key):
		return _cache[key]
	var count := int(RATE * length)
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / RATE
		var fade := 1.0 if loop else minf(1.0, (length - t) / 0.01)  # no click at the end
		var v: float = clampf(wave.call(t) * fade, -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = count
	_cache[key] = s
	return s
