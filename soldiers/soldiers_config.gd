extends RefCounted
## Combat mode: every balance number in one place (like economy.gd).
## The mode itself is soldiers/soldiers_mode.gd (all 3 maps, scenes
## maps/combat_<map>.tscn), the cover-to-cover AI is soldiers/tactical_soldier.gd.

# --- Waves --------------------------------------------------------------------
const START_SOLDIERS := 3       # wave 1
const SOLDIERS_PER_WAVE := 1    # extra soldiers each wave
const MAX_ALIVE := 8            # at once (bodies count until they sink away)
const SPAWN_INTERVAL := 1.5     # seconds between spawns within a wave

# --- Cover --------------------------------------------------------------------
## Cover is found on every map (soldiers_mode.gd _build_cover) from the box
## colliders of the level (NavigationRegion3D/Level, sight-blocking layer 1)
## that stand on the ground: houses, containers, cars, racks, forklifts,
## crates, dumpsters, short walls. Each side gets a point near both ends
## (COVER_EDGE_IN from the corner, COVER_OUT off the face):
##  - tall (top >= TALL_COVER m): the soldier stands behind it and peeks out
##    PEEK_OUT m past the corner;
##  - low (LOW_COVER..TALL_COVER m: cars, crates, dumpsters): it crouches
##    behind it (CROUCH_*) and stands up on the spot to fire over the top.
## Thin things (poles: a side under MIN_COVER_SIDE m) and the long outer walls
## (a side over MAX_COVER_SIDE m) are skipped, and so are points the navmesh
## doesn't reach. COVER_SKIP: collider names never used (per map id).
const TALL_COVER := 1.75
const LOW_COVER := 1.0
const MIN_COVER_SIDE := 0.9
const MAX_COVER_SIDE := 20.0
const COVER_SKIP := {
	"yard": [],
	"town": [],
	"warehouse": ["DoorHeader"],
}
const COVER_OUT := 0.75         # m off the face
const COVER_EDGE_IN := 0.7      # m in from the corner
const COVER_SLIDE := [0.0, 0.6, 1.2]  # m further in tried when that spot is blocked
const PEEK_OUT := 1.1           # m past the corner
const COVER_SNAP := 0.35        # m: a point further than this from the navmesh is dropped
const COVER_MERGE := 0.9        # m: points closer than this are one point
const EYE_HEIGHT := 1.55        # soldier's eyes above the ground (cover checks)
const CROUCH_EYE_HEIGHT := 0.95 # ... crouched behind low cover
const CROUCH_DROP := 0.5        # m the hips go down (the hostage's procedural crouch_modifier.gd)
const CROUCH_LEAN := 18.0       # degrees the upper body leans forward (same)
const CROUCH_TIME := 0.25       # s to crouch / stand up (the "Idle Crouching" clip blends in)
const CROUCH_HEIGHT := 1.2      # m: the body's hit capsule while crouched

# --- Spawns -------------------------------------------------------------------
## Soldiers come in at the map's spawn points at least this far from the
## player, preferring points the player can't see (else the farthest ones).
const SPAWN_MIN_DISTANCE := 16.0

# --- Soldier AI ---------------------------------------------------------------
const COVER_RANGE := Vector2(6.0, 24.0)  # m from the player a cover point may be
const COVER_BEST_DISTANCE := 12.0        # preferred distance to the player
const COVER_RAY_BUDGET := 16             # raycasts per cover search (2 per candidate)
const NO_VIEW_RESET := 4.0               # m the player moves before a cover that gave no view is tried again
const RUN_SPEED := 1.5                   # x walking speed between covers
const PEEK_SPEED := 0.7                  # x walking speed stepping out / back
const HIDE_TIME := Vector2(1.0, 2.2)     # seconds behind cover between peeks
const PEEKS_PER_COVER := Vector2i(2, 3)  # peeks before moving to another cover
const PEEK_WAIT := 1.2                   # s at the peek spot without a view = go back
const FLANK_CHECK := 0.35                # s between "can the player see me?" checks
const TOO_CLOSE := 4.5                   # m: the player this close to the cover = move
const SEARCH_RETRY := 1.0                # s before searching again when no cover was found

# --- Perception (tactical_soldier.gd "Perception") ----------------------------
## Awareness: UNAWARE (patrol / idle) -> SUSPICIOUS (investigates a noise or a
## glimpse, "?") -> COMBAT (the cover fight, "!"); losing the player in
## combat -> SEARCH (last known position + nearby cover, "?") -> UNAWARE.
## Sight: a cone in front, up to SIGHT_RANGE x the map / spot visibility, with
## a clear line. Seeing the player fills a notice meter (faster close up and
## when already suspicious); SUSPECT_LEVEL = suspicious, 1 = combat.
const SIGHT_RANGE := 38.0       # m in full light, no fog
const SIGHT_FOV := 110.0        # degrees, the whole cone
const TOUCH_RANGE := 2.0        # m: this close it notices the player whatever way it faces
const NOTICE_TIME := Vector2(0.35, 2.0)  # s of seeing the player to notice: at NOTICE_NEAR m / at the sight range
const NOTICE_NEAR := 6.0
const AWARE_NOTICE := 2.0       # x faster while suspicious or searching
const SUSPECT_LEVEL := 0.35     # notice meter level that makes it suspicious
const NOTICE_DECAY := 0.3       # meter lost per second out of sight
const PERCEPTION_TICK := 0.2    # s between sight checks (one ray each)
const COMBAT_SIGHT_RANGE := 55.0  # m: in combat it keeps track of a player in view (no cone)
## Darkness and fog: the sight range is multiplied by the map's visibility
## where the player stands, at least LAMP_VISIBILITY within LAMP_REACH x a
## lamp's range (lit spots in dark maps).
const VISIBILITY := {"yard": 1.0, "town": 0.7, "warehouse": 0.6}
const LAMP_VISIBILITY := 0.95
const LAMP_REACH := 0.7
## Hearing. Walking (WALK_SPEED) is silent; only sprinting is heard.
const GUNSHOT_HEAR := 35.0      # m: the player's shots, with a clear line between them
const GUNSHOT_HEAR_BLOCKED := 0.55  # x that range through walls
const SPRINT_HEAR := 8.0        # m: the player sprinting
const SPRINT_SPEED := 5.5       # m/s: the player moving faster than this is sprinting
const EXPLOSION_HEAR := 45.0    # m: grenades, barrels, C4
## Suspicious, search, patrol.
const INVESTIGATE_SPEED := 0.7  # x walking speed to a noise
const INVESTIGATE_TURN := 0.6   # s it first turns towards the noise
const LOOK_AROUND_TIME := 4.0   # s it looks round where the noise was
const LOSE_CONTACT := 6.0       # s in combat without seeing / hearing the player = search
const SEARCH_TIME := 15.0       # s of searching before going back to patrol
const SEARCH_RADIUS := 10.0     # m round the last known position: cover it checks
const SEARCH_COVERS := 2        # cover points it checks
const SEARCH_SPEED := 0.8       # x walking speed
const SEARCH_LOOK := 1.5        # s looking round at each search point
const PATROL_SPEED := 0.45      # x walking speed (mission guards)
const PATROL_RADIUS := Vector2(4.0, 9.0)  # m from the post its other patrol points are
const PATROL_POINTS := 2        # points besides the post
const PATROL_WAIT := Vector2(2.0, 4.0)    # s at each point
## Combat waves: unaware soldiers sweep the area round a rough guess of where
## the player is (HUNT_GUESS m off), a new guess on arrival.
const HUNT_GUESS := 10.0
const HUNT_SPEED := 0.75
## Radio: a soldier that spots the player tells the others within RADIO_RANGE
## m, RADIO_DELAY s later (at most every RADIO_INTERVAL s).
const RADIO_RANGE := 25.0
const RADIO_DELAY := Vector2(1.0, 2.0)
const RADIO_INTERVAL := 4.0
## "?" / "!" above the head.
const ICON_ALERT_TIME := 2.0    # s the "!" shows after it goes into combat
const ICON_HEIGHT := 0.45       # m above the head

# --- Movement and animation (tactical_soldier.gd "Animation") ------------------
## Locomotion is a blend by velocity in the soldier's frame (idle / walk /
## strafe left / right / walk back / run), played at the speed that matches
## the ground speed (no foot sliding).
const TURN_RATE := 300.0        # degrees/s at most when turning
const TURN_GAIN := 7.0          # turn speed per radian left (eases in)
const STRAFE_RANGE := 18.0      # m: moving in combat this close to a player in view, it faces them
const STRAFE_ANGLE := 60.0      # degrees between the way it moves and the player before it strafes
const STRAFE_SPEED := 0.9       # x walking speed while strafing / backing
const RUN_FORWARD := 1.75       # x the walk clip's speed: faster (forwards) = the run clip
const ANIM_SCALE := Vector2(0.5, 1.8)  # playback speed limits
const BLEND_SMOOTH := 9.0       # blend position follow rate (1/s)
const STANCE_SMOOTH := 4.0      # relaxed <-> aiming idle blend rate (1/s)
const TURN_STEP := 0.35         # standing and turning: sideways step per rad/s
const HIT_REACT_TIME := 0.6     # s of the "Hit Reaction" clip before it blends out
const HIT_REACT_SPEED := 1.4

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
