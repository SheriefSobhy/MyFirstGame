extends RefCounted
## Soldiers (Test) mode: every balance number in one place (like economy.gd).
## The mode itself is soldiers/soldiers_mode.gd (Industrial Yard only), the
## cover-to-cover AI is soldiers/tactical_soldier.gd.

# --- Waves --------------------------------------------------------------------
const START_SOLDIERS := 3       # wave 1
const SOLDIERS_PER_WAVE := 1    # extra soldiers each wave
const MAX_ALIVE := 8            # at once (bodies count until they sink away)
const SPAWN_INTERVAL := 1.5     # seconds between spawns within a wave

# --- Cover --------------------------------------------------------------------
## Tall objects in the Yard (main.tscn) a standing soldier can hide behind:
## centre and footprint on the ground (x, z), axis-aligned. Cover points are
## made along each side, near both ends (COVER_EDGE_IN from the corner,
## COVER_OUT off the face), each with a peek spot just past the corner
## (PEEK_OUT). Points the small enemies' navmesh doesn't reach are dropped.
## Low things (barriers, the 1.2 m crate pair, pallets) don't hide a soldier.
const COVER_OBJECTS := [
	{"name": "Warehouse", "center": Vector2(-7.0, -9.0), "size": Vector2(8.0, 5.0)},
	{"name": "ContainerRed", "center": Vector2(5.0, -4.0), "size": Vector2(6.1, 2.44)},
	{"name": "ContainerBlue", "center": Vector2(-6.0, 3.0), "size": Vector2(2.44, 6.1)},
	{"name": "CrateStack", "center": Vector2(-1.7, 2.1), "size": Vector2(1.8, 1.4)},
]
const COVER_OUT := 0.75         # m off the face
const COVER_EDGE_IN := 0.7      # m in from the corner
const PEEK_OUT := 1.1           # m past the corner
const COVER_SNAP := 0.35        # m: a point further than this from the navmesh is dropped
const COVER_MERGE := 0.9        # m: points closer than this are one point
const EYE_HEIGHT := 1.55        # soldier's eyes above the ground (cover checks)

# --- Soldier AI ---------------------------------------------------------------
const COVER_RANGE := Vector2(6.0, 24.0)  # m from the player a cover point may be
const COVER_BEST_DISTANCE := 12.0        # preferred distance to the player
const COVER_RAY_BUDGET := 10             # raycasts per cover search (2 per candidate)
const RUN_SPEED := 1.3                   # x walking speed between covers
const PEEK_SPEED := 0.7                  # x walking speed stepping out / back
const HIDE_TIME := Vector2(1.0, 2.2)     # seconds behind cover between peeks
const PEEKS_PER_COVER := Vector2i(2, 3)  # peeks before moving to another cover
const PEEK_WAIT := 1.2                   # s at the peek spot without a view = go back
const FLANK_CHECK := 0.35                # s between "can the player see me?" checks
const TOO_CLOSE := 4.5                   # m: the player this close to the cover = move
const SEARCH_RETRY := 1.0                # s before searching again when no cover was found

# --- Shooting -----------------------------------------------------------------
const AIM_TIME := 0.35                   # s of raising the rifle before a burst
const BURST := Vector2i(3, 5)            # shots per burst
const BURST_INTERVAL := 0.12             # s between shots
const SHOT_DAMAGE := 4
const SHOT_RANGE := 45.0
## Hit chance per bullet: HIT_NEAR at NEAR_DISTANCE or closer, falling to
## HIT_FAR at FAR_DISTANCE; a moving player is harder to hit (x MOVING_FACTOR
## at MOVING_SPEED m/s or faster, scaled down from there).
const HIT_NEAR := 0.6
const HIT_FAR := 0.1
const NEAR_DISTANCE := 5.0
const FAR_DISTANCE := 28.0
const MOVING_FACTOR := 0.45
const MOVING_SPEED := 4.0
const MISS_OFFSET := Vector2(0.6, 1.5)   # m beside the player a miss goes
const TRACER_SPEED := 160.0              # m/s
const TRACER_LENGTH := 2.2               # m
const TRACER_WIDTH := 0.025              # m
const TRACER_HIT_SHORT := 1.2            # m: a hit's tracer stops this far before the player (not across the camera)
const FLASH_TIME := 0.05                 # s the muzzle flash shows
const FLASH_SIZE := 0.45                 # m

# --- Player in this mode ------------------------------------------------------
const REGEN_DELAY := 4.0        # s without damage before health comes back
const REGEN_RATE := 15.0        # health per second
const INDICATOR_TIME := 1.3     # s a damage direction arrow stays on screen
const INDICATOR_RADIUS := 150.0 # px from the screen centre
