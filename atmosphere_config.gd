extends RefCounted
## Mood of the three maps (not the Training Arena), on top of the baked light:
## the colour grade, fog, dust, light shafts, reflection probes, flickering
## lamps and emergency lights. atmosphere.gd builds it all from this table.
## Which parts run at each graphics level (Atmosphere.apply_quality):
##   Low     baked light + colour grade only
##   Medium  + fog, dust, flickering lamps
##   High    + reflection probes, light shafts, glow, emergency lights
##
## Per map:
##  grade    tonemap + adjustments + a per-channel colour curve (shadows / mids /
##           highlights tint) + glow
##  fog      depth fog (colour, density...), shown from Medium up
##  dust     floating motes around the player: colour (alpha = strength), amount,
##           size, the box they fill (m), lifetime
##  shafts   additive light shafts. "cone" hangs under a lamp, "beam" goes along
##           the direction of the Sun node ("dir": "sun"), or towards "to",
##           from `pos`. r0 / r1 = radius at the start / far end, len, intensity
##  probes   reflection probes (pos, size, interior)
##  flicker  existing lamps that flicker: lamp / tube (glow mesh) node names,
##           strong (bursts of dark) or weak (small dips)
##  lights   extra real-time lamps that flicker (name, pos, colour, energy, range)
##  beacons  emergency lights: pulsing, or alternating colour/colour2 (police)

const TONE_FILMIC := 2
const TONE_ACES := 3
const TONE_AGX := 4

const MAPS := {
	# Hazy, dusty afternoon: soft contrast, warm lifted shadows, golden haze.
	"yard": {
		"grade": {
			"tonemap": TONE_ACES, "white": 6.0, "exposure": 1.0,
			"brightness": 1.0, "contrast": 0.97, "saturation": 0.95,
			"shadows": Color(0.05, 0.045, 0.05), "mids": Color(0.5, 0.49, 0.47), "highs": Color(1.0, 0.96, 0.88),
			"glow_intensity": 0.55, "glow_bloom": 0.1, "glow_threshold": 1.0,
		},
		"fog": {"color": Color(0.9, 0.78, 0.62), "density": 0.0085, "sky_affect": 0.12, "sun_scatter": 0.45},
		"dust": {"color": Color(1.0, 0.86, 0.62, 0.5), "amount": 110, "size": 0.035, "box": Vector3(18, 7, 18), "lifetime": 10.0},
		"shafts": [],
		"probes": [{"pos": Vector3(0, 2.5, 0), "size": Vector3(26, 8, 26), "interior": false}],
		"lights": [
			{"name": "WorkLamp", "pos": Vector3(4.0, 2.7, 11.2), "color": Color(1.0, 0.74, 0.44), "energy": 1.8, "range": 7.0, "strong": true},
		],
	},
	# Cold, foggy evening: desaturated blue-grey, thick cold fog, warm lamps pop.
	"town": {
		"grade": {
			"tonemap": TONE_ACES, "white": 5.0, "exposure": 1.25,
			"brightness": 1.05, "contrast": 1.06, "saturation": 0.8,
			"shadows": Color(0.02, 0.035, 0.08), "mids": Color(0.49, 0.5, 0.52), "highs": Color(0.94, 0.98, 1.0),
			"glow_intensity": 0.9, "glow_bloom": 0.14, "glow_threshold": 0.85,
		},
		"fog": {"color": Color(0.4, 0.47, 0.58), "density": 0.024, "sky_affect": 0.5, "sun_scatter": 0.25},
		"dust": {"color": Color(0.8, 0.86, 1.0, 0.3), "amount": 90, "size": 0.03, "box": Vector3(18, 6, 18), "lifetime": 10.0},
		"shafts": [
			{"kind": "cone", "pos": Vector3(5.3, 4.55, 5.3), "len": 4.5, "r0": 0.2, "r1": 2.0, "color": Color(1.0, 0.72, 0.42), "intensity": 0.22},
			{"kind": "cone", "pos": Vector3(-5.3, 4.55, 5.3), "len": 4.5, "r0": 0.2, "r1": 2.0, "color": Color(1.0, 0.72, 0.42), "intensity": 0.22},
			{"kind": "cone", "pos": Vector3(5.3, 4.55, -5.3), "len": 4.5, "r0": 0.2, "r1": 2.0, "color": Color(1.0, 0.72, 0.42), "intensity": 0.22},
			{"kind": "cone", "pos": Vector3(-5.3, 4.55, -5.3), "len": 4.5, "r0": 0.2, "r1": 2.0, "color": Color(1.0, 0.72, 0.42), "intensity": 0.22},
			{"kind": "cone", "pos": Vector3(15.0, 4.55, -5.3), "len": 4.5, "r0": 0.2, "r1": 2.0, "color": Color(1.0, 0.72, 0.42), "intensity": 0.18},
			{"kind": "cone", "pos": Vector3(-15.0, 4.55, 5.3), "len": 4.5, "r0": 0.2, "r1": 2.0, "color": Color(1.0, 0.72, 0.42), "intensity": 0.18},
			{"kind": "beam", "pos": Vector3(-20.0, 3.5, 1.6), "dir": "sun", "len": 22.0, "r0": 1.4, "r1": 2.0, "color": Color(1.0, 0.7, 0.5), "intensity": 0.12},
		],
		"probes": [{"pos": Vector3(0, 3.0, 0), "size": Vector3(48, 10, 48), "interior": false}],
		"flicker": [
			{"lamp": "Lamp1", "tube": "Bulb1", "strong": true},
			{"lamp": "Lamp2", "tube": "Bulb2", "strong": false},
		],
		"beacons": [
			# The police car's light bar.
			{"name": "PoliceLights", "pos": Vector3(2.5, 1.75, -9.0), "color": Color(1.0, 0.1, 0.08), "color2": Color(0.15, 0.3, 1.0), "energy": 3.5, "range": 9.0, "speed": 7.0},
		],
	},
	# Dark warehouse, warm lamp light, cold moonlight through high windows.
	"warehouse": {
		"grade": {
			"tonemap": TONE_FILMIC, "white": 4.0, "exposure": 1.0,
			"brightness": 1.06, "contrast": 1.1, "saturation": 1.0,
			"shadows": Color(0.015, 0.035, 0.07), "mids": Color(0.5, 0.5, 0.5), "highs": Color(1.0, 0.94, 0.84),
			"glow_intensity": 0.9, "glow_bloom": 0.14, "glow_threshold": 0.9,
		},
		"fog": {"color": Color(0.07, 0.08, 0.12), "density": 0.02, "sky_affect": 0.5, "sun_scatter": 0.0},
		"dust": {"color": Color(1.0, 0.86, 0.62, 0.35), "amount": 100, "size": 0.03, "box": Vector3(16, 6, 16), "lifetime": 10.0},
		"shafts": [
			# Under the ceiling lights.
			{"kind": "cone", "pos": Vector3(-12.0, 6.0, 0.0), "len": 6.0, "r0": 0.25, "r1": 3.0, "color": Color(1.0, 0.82, 0.55), "intensity": 0.15},
			{"kind": "cone", "pos": Vector3(-4.5, 6.0, 0.0), "len": 6.0, "r0": 0.25, "r1": 3.0, "color": Color(1.0, 0.82, 0.55), "intensity": 0.15},
			{"kind": "cone", "pos": Vector3(3.0, 6.0, 0.0), "len": 6.0, "r0": 0.25, "r1": 3.0, "color": Color(1.0, 0.82, 0.55), "intensity": 0.15},
			{"kind": "cone", "pos": Vector3(-7.75, 6.0, -8.1), "len": 6.0, "r0": 0.25, "r1": 2.6, "color": Color(1.0, 0.82, 0.55), "intensity": 0.1},
			{"kind": "cone", "pos": Vector3(-7.75, 6.0, 8.1), "len": 6.0, "r0": 0.25, "r1": 2.6, "color": Color(1.0, 0.82, 0.55), "intensity": 0.1},
			# Moonlight through the high windows of the south wall.
			{"kind": "beam", "pos": Vector3(-10.25, 4.95, 12.8), "dir": "sun", "len": 8.0, "r0": 0.9, "r1": 1.1, "color": Color(0.5, 0.65, 1.0), "intensity": 0.24, "fade_in": 0.08, "fade_out": 0.45},
			{"kind": "beam", "pos": Vector3(-1.9, 4.95, 12.8), "dir": "sun", "len": 8.0, "r0": 0.9, "r1": 1.1, "color": Color(0.5, 0.65, 1.0), "intensity": 0.24, "fade_in": 0.08, "fade_out": 0.45},
			{"kind": "beam", "pos": Vector3(6.4, 4.95, 12.8), "dir": "sun", "len": 8.0, "r0": 0.9, "r1": 1.1, "color": Color(0.5, 0.65, 1.0), "intensity": 0.24, "fade_in": 0.08, "fade_out": 0.45},
			# The yard floodlight.
			{"kind": "beam", "pos": Vector3(20.0, 5.9, 0.8), "to": Vector3(8.0, 0.5, 0.0), "r0": 0.2, "r1": 3.4, "color": Color(0.8, 0.88, 1.0), "intensity": 0.12, "fade_in": 0.05, "fade_out": 0.5},
		],
		"probes": [
			{"pos": Vector3(-4.0, 3.2, 0.0), "size": Vector3(25, 6.4, 27), "interior": true},
			{"pos": Vector3(15.5, 3.0, 0.0), "size": Vector3(14, 6, 28), "interior": false},
		],
		"flicker": [
			{"lamp": "Lamp1", "tube": "LampTube1", "strong": true},
			{"lamp": "Floodlight", "tube": "FloodGlow", "strong": false},
		],
		"beacons": [
			{"name": "Emergency1", "pos": Vector3(7.6, 5.0, -4.6), "color": Color(1.0, 0.08, 0.05), "energy": 3.0, "range": 9.0, "speed": 3.5},
			{"name": "Emergency2", "pos": Vector3(-15.4, 4.6, 0.0), "color": Color(1.0, 0.08, 0.05), "energy": 3.0, "range": 9.0, "speed": 3.5},
		],
	},
}


static func has_map(id: String) -> bool:
	return MAPS.has(id)
