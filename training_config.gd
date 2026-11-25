extends RefCounted
## Every Training Arena number in one place (training/training.gd and the
## targets read them). The arena itself is built by tools/build_maps.gd.
## Nothing here is earned: no XP, coins, missions or achievements.

# --- Targets ---------------------------------------------------------------------

## The static lanes: one paper target and two steel plates per distance (m
## from the firing line), bigger further out so they stay visible.
const DISTANCES := [10, 25, 50, 100]
const TARGET_SCALE := {10: 1.0, 25: 1.0, 50: 1.35, 100: 2.0}
## Each distance has its own lane on the left of the range (lane centre x),
## so near targets never hide far ones: the paper target on the lane's left,
## the two plates on its right.
const LANES := {10: -14.75, 25: -12.25, 50: -9.5, 100: -5.5}
## Steel plates fall when hit and stand up again this many seconds later.
const METAL_RESET := 3.0
## Moving targets (middle lanes, around MOVER_X): [distance m, half the
## slide length m, speed m/s].
const MOVER_X := 1.4
const MOVERS := [[30.0, 3.0, 1.6], [45.0, 3.2, 2.4]]
## The pop-up targets the challenges raise (x, z), in front of the movers.
const POPUPS := [
	Vector2(-1.5, -9.0), Vector2(1.5, -11.0), Vector2(4.0, -9.5), Vector2(-0.5, -14.0),
	Vector2(2.0, -15.0), Vector2(4.3, -17.0), Vector2(0.5, -19.5), Vector2(3.0, -21.5),
]


## x of the paper target at distance d.
static func paper_x(d: int) -> float:
	return LANES[d] - 0.55 * TARGET_SCALE[d]


## x of the two steel plates at distance d.
static func metal_x(d: int) -> Array[float]:
	var c: float = LANES[d]
	var s: float = TARGET_SCALE[d]
	return [c + 0.3 * s, c + 0.95 * s]

# --- Dummies ---------------------------------------------------------------------

## The dummies standing in the dummy lane at the start, one of each type.
const DUMMY_KINDS := ["normal", "runner", "soldier", "exploder", "brute", "boss"]
## Where each of them stands (x, z; the firing line is z = 0, downrange is -z).
const DUMMY_HOMES := {
	"normal": Vector2(6.5, -15.0), "runner": Vector2(8.0, -15.0), "soldier": Vector2(9.5, -15.0),
	"exploder": Vector2(11.0, -15.0), "brute": Vector2(12.6, -18.0), "boss": Vector2(14.4, -21.0),
}
## Walking dummies go this far (m) either way along the lane from their spot.
const DUMMY_PATROL := 5.0
## Dummies spawned from the training panel appear somewhere in here (x, z, w, d).
const DUMMY_AREA := Rect2(6.5, -24.0, 6.5, 10.0)
## Walking dummies' speed (m/s), whatever their type.
const DUMMY_SPEED := 1.1
## Seconds after death before a dummy stands up again at its spot.
const DUMMY_RESPAWN := 3.0
## At most this many dummies (the six + ones spawned from the panel), for phones.
const MAX_DUMMIES := 12

# --- Weapon rack -------------------------------------------------------------------

## Within this distance (m) of a rack slot the Take button shows.
const RACK_REACH := 1.8

# --- Stats -----------------------------------------------------------------------

## DPS on the last target: hits on the same target closer together than this
## (s) count as one burst.
const DPS_BURST_GAP := 1.5

# --- Challenges ------------------------------------------------------------------

## Seconds of "3, 2, 1" before a challenge starts.
const COUNTDOWN := 3
const CHALLENGES := {
	"targets": {
		"name": "Target Practice",
		"info": "Hit 20 pop-up targets as fast as you can.",
		"count": 20,
		"lower_is_better": true,   # best time
	},
	"headshots": {
		"name": "Headshot Challenge",
		"info": "15 headshots on walking dummies in 60 seconds.",
		"count": 15,
		"time": 60.0,
		"lower_is_better": false,  # most headshots
	},
	"reflex": {
		"name": "Reflex",
		"info": "30 targets pop up for 1 second each. Hit as many as you can.",
		"count": 30,
		"up_time": 1.0,            # s each target stays up
		"gap": Vector2(0.35, 0.9), # s between targets (random)
		"lower_is_better": false,  # best accuracy %
	},
}


## A challenge best as text: "12.4 s", "11 headshots", "87%", or "-".
static func format_best(id: String, value: float) -> String:
	if value < 0.0:
		return "-"
	match id:
		"targets":
			return "%.1f s" % value
		"headshots":
			return "%d headshots" % int(value)
		_:
			return "%d%%" % roundi(value)
