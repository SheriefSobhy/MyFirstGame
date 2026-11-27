extends RefCounted
## Combat mode > Missions: every mission and every balance number in one
## place (like economy.gd). The runtime is missions/mission_mode.gd (extends
## the Combat mode), the objective types are missions/defend.gd and
## missions/rescue.gd. Progress (best stars per mission) is in progress.gd.
##
## Each map has SLOTS mission slots; a slot with no mission here shows
## "Coming soon". Missions unlock in order per map: slot n needs slot n-1
## cleared (and the map unlocked by level, as in Waves).
##
## Positions are map coordinates (metres, y ignored: snapped to the navmesh).
##
## Common fields:
##  id, map, slot (1..SLOTS), type ("defend" | "rescue"), name, objective
##  (briefing line), tip (briefing tip), player_start, player_yaw (degrees,
##  0 = looking along -Z), par_time (s, star 2 for Rescue), first/repeat
##  {coins, xp} rewards.
## Defend: zone {pos, radius}, duration (s), waves [{at (s), count}],
##  pusher_share (share of soldiers that walk into the zone; the rest fight
##  from cover), capture_time (s for one soldier alone to capture),
##  star 2 = the capture bar never went past CAPTURE_STAR.
## Rescue: hostage (pos, yaw), guards [[pos, yaw]], extraction {pos, radius},
##  reinforcements [{after (s after the hostage is freed), count}],
##  hostage_target_chance (a soldier's burst goes at the hostage instead).

const SLOTS := 5

## The mission to play: set by the mission list (ui/map_select.gd) before
## loading maps/mission_<map>.tscn; mission_mode.gd reads it (Retry keeps
## it, Next Mission changes it).
static var pending := ""
const TYPE_NAMES := {"defend": "Defend the Point", "rescue": "Rescue"}

# --- Framework --------------------------------------------------------------------
const HEALTH_STAR := 0.5        # star 3: finish with more than this share of health
const USE_REACH := 2.2          # m: the USE button shows this close to an interactable
const MARKER_EDGE := 70.0       # px: the off-screen arrow stays this far inside the screen
const RESULT_DELAY := 1.2       # s between the win / loss and the result screen

# --- Defend the Point -------------------------------------------------------------
const CAPTURE_STACK := 0.5      # each extra soldier in the zone adds this much speed
const CAPTURE_DECAY := 0.04     # share per second the bar drains with no soldier inside
const CAPTURE_STAR := 0.5       # star 2: the bar never passed this
const PUSH_FIRE_COOLDOWN := Vector2(2.0, 3.5)  # s between a pusher's bursts
const PUSH_SPEED := 1.1         # x walking speed of a pusher
const PUSH_SPOT_RADIUS := 0.6   # share of the zone radius a pusher's spot lies within

# --- Rescue -----------------------------------------------------------------------
const FREE_TIME := 3.0          # s holding USE to free the hostage
const HOSTAGE_HP := 100
const HOSTAGE_DAMAGE := 6       # per soldier bullet that hits him
const HOSTAGE_WALK := 4.2       # m/s following
const HOSTAGE_RUN := 6.5        # m/s when far behind
const HOSTAGE_RUN_DISTANCE := 7.0
const FOLLOW_BEHIND := 2.2      # m behind the player he aims for
const FOLLOW_STOP := 2.0        # m: closer than this to the player he stands still
const COWER_TIME := 1.4         # s crouched after a bullet passes near him
const COWER_NEAR := 2.5         # m: a bullet this close makes him crouch
const HOSTAGE_WARP := 22.0      # m: stuck further than this behind = moved behind the player
const GUARD_HEAR := 9.0         # m: guards notice the player this close
const GUARD_SIGHT := 24.0       # m: ... or seeing them this far (in front of them)
const GUARD_FOV := 0.2          # dot: "in front" (about 160 degrees)
const GUARD_ALERT_RADIUS := 20.0  # m: an alerted guard alerts the others this close
const GUNSHOT_ALERT := 22.0     # m: the player's shots alert guards this close

## The 6 missions (2 per map), difficulty rising Yard -> Town -> Warehouse.
const LIST := [
	# --- Yard ---------------------------------------------------------------------
	{
		"id": "yard_defend", "map": "yard", "slot": 1, "type": "defend",
		"name": "Hold the Yard",
		"objective": "Hold the supply point for 2 minutes. Don't let the soldiers take it.",
		"tip": "Stand inside the ring: soldiers can't capture it while you're in it.",
		"player_start": Vector3(1.0, 0, -1.5), "player_yaw": 0.0,
		"zone": {"pos": Vector3(1.0, 0, -1.5), "radius": 3.5},
		"duration": 120.0, "capture_time": 12.0, "pusher_share": 0.6,
		"waves": [{"at": 2.0, "count": 3}, {"at": 30.0, "count": 3}, {"at": 60.0, "count": 4}, {"at": 90.0, "count": 4}],
		"first": {"coins": 150, "xp": 300}, "repeat": {"coins": 40, "xp": 80},
	},
	{
		"id": "yard_rescue", "map": "yard", "slot": 2, "type": "rescue",
		"name": "Pen Break",
		"objective": "A captured officer is held in the fenced pen. Free him and bring him to the extraction point.",
		"tip": "Hold USE for 3 seconds next to the hostage. Keep him behind you on the way out.",
		"player_start": Vector3(-1.0, 0, -10.5), "player_yaw": 200.0,
		"hostage": {"pos": Vector3(10.0, 0, 10.0), "yaw": -135.0},
		"guards": [[Vector3(5.5, 0, 9.0), 180.0], [Vector3(9.0, 0, 5.5), 0.0], [Vector3(3.0, 0, 5.0), 160.0]],
		"extraction": {"pos": Vector3(-9.5, 0, 9.0), "radius": 2.5},
		"reinforcements": [{"after": 6.0, "count": 2}],
		"hostage_target_chance": 0.2, "par_time": 100.0,
		"first": {"coins": 200, "xp": 400}, "repeat": {"coins": 50, "xp": 100},
	},
	# --- Town ---------------------------------------------------------------------
	{
		"id": "town_defend", "map": "town", "slot": 1, "type": "defend",
		"name": "Crossroads",
		"objective": "Hold the crossroads for 2:30. Soldiers come from every street.",
		"tip": "Use the cars for cover, but step back into the ring when they push.",
		"player_start": Vector3(0.0, 0, 0.0), "player_yaw": 0.0,
		"zone": {"pos": Vector3(0.0, 0, 0.0), "radius": 4.0},
		"duration": 150.0, "capture_time": 10.0, "pusher_share": 0.6,
		"waves": [{"at": 2.0, "count": 4}, {"at": 30.0, "count": 4}, {"at": 60.0, "count": 5},
				{"at": 90.0, "count": 5}, {"at": 120.0, "count": 6}],
		"first": {"coins": 250, "xp": 500}, "repeat": {"coins": 60, "xp": 120},
	},
	{
		"id": "town_rescue", "map": "town", "slot": 2, "type": "rescue",
		"name": "Back Alley",
		"objective": "The officer is held in the backyard behind the north-west houses. Get him out to the south street.",
		"tip": "Clear the guards at the alley first: he follows you, and they shoot at him too.",
		"player_start": Vector3(2.0, 0, 8.0), "player_yaw": 0.0,
		"hostage": {"pos": Vector3(-19.5, 0, -19.5), "yaw": 45.0},
		"guards": [[Vector3(-17.5, 0, -17.0), 45.0], [Vector3(-13.0, 0, -13.5), 45.0], [Vector3(-5.5, 0, -15.0), 120.0],
				[Vector3(-15.0, 0, -4.0), 0.0], [Vector3(-3.0, 0, -6.0), 30.0], [Vector3(-19.5, 0, -15.5), 90.0]],
		"extraction": {"pos": Vector3(4.0, 0, 20.5), "radius": 2.8},
		"reinforcements": [{"after": 5.0, "count": 2}, {"after": 30.0, "count": 2}],
		"hostage_target_chance": 0.25, "par_time": 150.0,
		"first": {"coins": 300, "xp": 600}, "repeat": {"coins": 70, "xp": 140},
	},
	# --- Warehouse ----------------------------------------------------------------
	{
		"id": "warehouse_defend", "map": "warehouse", "slot": 1, "type": "defend",
		"name": "Loading Bay",
		"objective": "Hold the loading yard for 3 minutes against soldiers from the warehouse and the gate.",
		"tip": "They come from inside and outside: keep turning, and throw grenades into the ring.",
		"player_start": Vector3(14.5, 0, -1.5), "player_yaw": 90.0,
		"zone": {"pos": Vector3(14.5, 0, -1.5), "radius": 4.0},
		"duration": 180.0, "capture_time": 9.0, "pusher_share": 0.65,
		"waves": [{"at": 2.0, "count": 4}, {"at": 28.0, "count": 5}, {"at": 55.0, "count": 5},
				{"at": 85.0, "count": 6}, {"at": 115.0, "count": 6}, {"at": 145.0, "count": 7}],
		"first": {"coins": 350, "xp": 700}, "repeat": {"coins": 80, "xp": 160},
	},
	{
		"id": "warehouse_rescue", "map": "warehouse", "slot": 2, "type": "rescue",
		"name": "Dark Aisles",
		"objective": "The officer is held deep in the warehouse, between the back racks. Bring him out to the truck.",
		"tip": "The aisles are dark and the guards are many: take them one aisle at a time.",
		"player_start": Vector3(20.0, 0, -6.0), "player_yaw": 90.0,
		"hostage": {"pos": Vector3(-12.0, 0, -8.1), "yaw": 90.0},
		"guards": [[Vector3(-8.0, 0, -8.0), 90.0], [Vector3(-14.5, 0, -3.0), 0.0], [Vector3(-6.0, 0, -3.0), 90.0],
				[Vector3(0.5, 0, -8.0), 90.0], [Vector3(2.0, 0, 4.0), 90.0], [Vector3(-8.0, 0, 8.1), 90.0],
				[Vector3(6.0, 0, -2.0), 90.0], [Vector3(-1.0, 0, 0.0), 60.0]],
		"extraction": {"pos": Vector3(19.5, 0, 11.0), "radius": 2.5},
		"reinforcements": [{"after": 5.0, "count": 3}, {"after": 35.0, "count": 3}],
		"hostage_target_chance": 0.3, "par_time": 180.0,
		"first": {"coins": 400, "xp": 800}, "repeat": {"coins": 90, "xp": 180},
	},
]


static func find(id: String) -> Dictionary:
	for m: Dictionary in LIST:
		if m.id == id:
			return m
	return {}


## The mission in a map's slot ({} = Coming soon).
static func in_slot(map_id: String, slot: int) -> Dictionary:
	for m: Dictionary in LIST:
		if m.map == map_id and m.slot == slot:
			return m
	return {}


## The mission after this one on the same map ({} if none).
static func next_of(id: String) -> Dictionary:
	var m := find(id)
	return {} if m.is_empty() else in_slot(m.map, m.slot + 1)


## Missions on a map.
static func for_map(map_id: String) -> Array:
	return LIST.filter(func(m: Dictionary) -> bool: return m.map == map_id)


## Text for star n (1..3) of a mission.
static func star_text(m: Dictionary, n: int) -> String:
	match n:
		1:
			return "Complete the mission"
		2:
			if m.type == "defend":
				return "Capture bar never above %d%%" % int(CAPTURE_STAR * 100)
			return "Finish in under %s" % time_text(m.par_time)
		_:
			return "Finish with over %d%% health" % int(HEALTH_STAR * 100)


static func time_text(seconds: float) -> String:
	var s := maxi(ceili(seconds), 0)
	return "%d:%02d" % [s / 60, s % 60]
