extends RefCounted
## Combat mode > Missions: every mission and every balance number in one
## place (like economy.gd). The runtime is missions/mission_mode.gd (extends
## the Combat mode), the objective types are missions/defend.gd, rescue.gd,
## sabotage.gd, extraction.gd and hunt.gd. Progress (best stars per mission)
## is in progress.gd.
##
## Each map has SLOTS mission slots; a slot with no mission here shows
## "Coming soon". Missions unlock in order per map: slot n needs slot n-1
## cleared (and the map unlocked by level, as in Waves).
##
## Positions are map coordinates (metres, snapped to the navmesh; y is 0 on the
## ground, or a roof height: the Yard blockhouse roof is at 2.8 m).
##
## Common fields:
##  id, map, slot (1..SLOTS), type (a TYPE_NAMES key), name, objective
##  (briefing line), tip (briefing tip), player_start, player_yaw (degrees,
##  0 = looking along -Z), par_time (s, star 2 for every type but Defend), first/repeat
##  {coins, xp} rewards.
## Defend: zone {pos, radius}, duration (s), waves [{at (s), count}],
##  pusher_share (share of soldiers that walk into the zone; the rest fight
##  from cover), capture_time (s for one soldier alone to capture),
##  star 2 = the capture bar never went past CAPTURE_STAR.
## Rescue: hostage (pos, yaw), guards [[pos, yaw]], extraction {pos, radius},
##  reinforcements [{after (s after the hostage is freed), count}],
##  hostage_target_chance (a soldier's burst goes at the hostage instead).
## Sabotage: targets [{kind ("generator" | "fuel" | "vehicle"), pos, yaw}],
##  guards [[pos, yaw]], exit {pos, radius}, countdown (s from the last
##  charge to the blasts), reinforcements [{after_plant (charges planted),
##  count}].
## Extraction: guards [[pos, yaw]] (positions along the way), lz {pos,
##  radius, yaw (the helicopter's heading)}, hold (s inside the LZ),
##  hold_waves [{at (s of holding), count}].
## Hunt: spots [[pos, yaw]] (the Commander starts at one, picked at random),
##  bodyguards [[offset, yaw]] (around his spot), vehicle {pos, yaw, drive
##  (m it drives off)}, commander_hp, radio_count (soldiers he calls in),
##  intel_radius (m: the ring around his rough area).

const SLOTS := 5

## The mission to play: set by the mission list (ui/map_select.gd) before
## loading maps/mission_<map>.tscn; mission_mode.gd reads it (Retry keeps
## it, Next Mission changes it).
static var pending := ""
const TYPE_NAMES := {"defend": "Defend the Point", "rescue": "Rescue", "sabotage": "Sabotage",
		"extraction": "Extraction", "hunt": "Hunt the Commander"}

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

# --- Sabotage ---------------------------------------------------------------------
const PLANT_TIME := 4.0         # s holding USE to plant a charge
const PLANT_NOISE := 16.0       # m: guards this close hear the player planting...
const PLANT_NOISE_AFTER := 1.0  # ... once they've held USE this long
const C4_BEEP := Vector2(1.0, 0.12)  # s between beeps: at the start / the end of the countdown
const BLAST_RADIUS := 9.0       # m: each target's explosion
const BLAST_ENEMY_DAMAGE := 40
const BLAST_PLAYER_DAMAGE := 90
const BLAST_STAGGER := 0.45     # s between the targets going off
const WRECK_FIRE_TIME := 14.0   # s a blown-up target keeps burning
const TARGET_SIZE := {          # collision box (m) per target kind
	"generator": Vector3(1.7, 1.4, 1.1), "fuel": Vector3(3.0, 1.9, 1.5), "vehicle": Vector3(2.3, 2.1, 4.5)}

# --- Extraction -------------------------------------------------------------------
const HELI_APPROACH := 12.0     # s of the hold the helicopter takes to fly in and land
const HELI_FROM := Vector3(55.0, 30.0, -40.0)  # where it comes from, relative to the LZ
const HELI_LIFT := 6.0          # s after boarding it climbs away (cosmetic)
const BOARD_RADIUS := 3.6       # m from the helicopter's centre that counts as aboard

# --- Hunt the Commander -----------------------------------------------------------
const COMMANDER_TINT := Color(0.85, 0.42, 0.38)  # uniform tint
const COMMANDER_BERET := Color(0.75, 0.04, 0.04)
const COMMANDER_ARMOR := 0.5    # share of non-headshot damage he takes
const COMMANDER_FLEE := 1.6     # x walking speed running to the vehicle
const RADIO_DELAY := 1.5        # s from spotting the player to the call for help
const VEHICLE_DRIVE_TIME := 3.0 # s the escape vehicle drives off

## The 15 missions (5 per map), difficulty rising Yard -> Town -> Warehouse.
const LIST := [
	# --- Yard ---------------------------------------------------------------------
	{
		"id": "yard_defend", "map": "yard", "slot": 1, "type": "defend",
		"name": "Hold the Depot",
		"objective": "Hold the supply point inside the storage depot for 2 minutes. Don't let the soldiers take it.",
		"tip": "They come through the yard door and the loading door. Stay in the ring and watch both.",
		"player_start": Vector3(16.8, 0, -0.4), "player_yaw": 90.0,
		"zone": {"pos": Vector3(16.8, 0, -0.4), "radius": 3.0},
		"duration": 120.0, "capture_time": 12.0, "pusher_share": 0.6,
		"waves": [{"at": 2.0, "count": 3}, {"at": 30.0, "count": 3}, {"at": 60.0, "count": 4}, {"at": 90.0, "count": 4}],
		"first": {"coins": 150, "xp": 300}, "repeat": {"coins": 40, "xp": 80},
	},
	{
		"id": "yard_rescue", "map": "yard", "slot": 2, "type": "rescue",
		"name": "Rooftop",
		"objective": "A captured officer is held on the blockhouse roof in the back lot. Free him and bring him to the extraction point in the yard.",
		"tip": "Come up the side alley. Hold USE for 3 seconds next to the hostage, then lead him down the stairs.",
		"player_start": Vector3(-14.5, 0, 1.5), "player_yaw": 0.0,
		# y 2.8: on the blockhouse roof (tools/build_level.gd BH_H).
		"hostage": {"pos": Vector3(-7.5, 2.8, -22.6), "yaw": 180.0},
		"guards": [[Vector3(-4.6, 2.8, -21.8), 200.0], [Vector3(-1.5, 0, -16.0), 160.0], [Vector3(9.0, 0, -15.5), 120.0],
				[Vector3(-14.0, 0, -18.5), 30.0]],
		"extraction": {"pos": Vector3(-9.5, 0, 9.0), "radius": 2.5},
		"reinforcements": [{"after": 6.0, "count": 3}],
		"hostage_target_chance": 0.2, "par_time": 120.0,
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
	# --- Slots 3-5: Sabotage, Extraction, Hunt the Commander ----------------------
	# Yard
	{
		"id": "yard_sabotage", "map": "yard", "slot": 3, "type": "sabotage",
		"name": "Lights Out",
		"objective": "Plant C4 on the generator inside the storage depot and on the fuel tank in the back lot, then get to the side alley before they blow.",
		"tip": "Planting takes 4 seconds and the guards hear it: clear the area first.",
		"player_start": Vector3(-9.0, 0, 9.5), "player_yaw": -45.0,
		"targets": [{"kind": "generator", "pos": Vector3(24.6, 0, 2.0), "yaw": 90.0},
				{"kind": "fuel", "pos": Vector3(16.0, 0, -19.0), "yaw": 0.0}],
		"guards": [[Vector3(22.0, 0, 1.2), 270.0], [Vector3(19.5, 0, -6.8), 180.0], [Vector3(15.5, 0, -16.6), 200.0],
				[Vector3(6.5, 0, -14.6), 90.0]],
		"exit": {"pos": Vector3(-14.5, 0, -7.0), "radius": 2.5},
		"countdown": 25.0,
		"reinforcements": [{"after_plant": 1, "count": 2}, {"after_plant": 2, "count": 2}],
		"par_time": 120.0,
		"first": {"coins": 220, "xp": 450}, "repeat": {"coins": 55, "xp": 110},
	},
	{
		"id": "yard_extraction", "map": "yard", "slot": 4, "type": "extraction",
		"name": "Dust Off",
		"objective": "Fight from the far end of the back lot into the yard to the landing zone and hold it until the helicopter lands. Then get on board.",
		"tip": "Stay inside the landing zone: the clock stops while you are out of it.",
		"player_start": Vector3(22.5, 0, -23.0), "player_yaw": 90.0,
		"guards": [[Vector3(10.0, 0, -15.0), 90.0], [Vector3(-1.0, 0, -18.0), 60.0], [Vector3(3.5, 0, -10.0), 0.0],
				[Vector3(-3.5, 0, -3.0), 45.0], [Vector3(6.0, 0, 5.0), 10.0]],
		"lz": {"pos": Vector3(0.0, 0, 8.0), "radius": 4.5, "yaw": 90.0},
		"hold": 30.0,
		"hold_waves": [{"at": 2.0, "count": 2}, {"at": 14.0, "count": 3}],
		"par_time": 170.0,
		"first": {"coins": 240, "xp": 500}, "repeat": {"coins": 60, "xp": 120},
	},
	{
		"id": "yard_hunt", "map": "yard", "slot": 5, "type": "hunt",
		"name": "Red Beret",
		"objective": "An enemy Commander is somewhere in the yard compound with his bodyguards: on the blockhouse roof, in the depot or in the alley. Find him and take him out before he escapes.",
		"tip": "If he spots you, he calls for help and runs for his car in the yard. A headshot goes through his vest.",
		"player_start": Vector3(-6.0, 0, 10.0), "player_yaw": 20.0,
		# The first spot is on the blockhouse roof (y 2.8).
		"spots": [[Vector3(-6.5, 2.8, -22.2), 180.0], [Vector3(21.5, 0, -6.8), 90.0], [Vector3(-14.5, 0, -6.0), 180.0]],
		"bodyguards": [[Vector3(1.0, 0, 1.4), 180.0], [Vector3(-1.0, 0, -1.4), 180.0]],
		"vehicle": {"pos": Vector3(2.5, 0, 10.6), "yaw": 90.0, "drive": 8.0},
		"commander_hp": 10, "radio_count": 2, "intel_radius": 6.0,
		"par_time": 120.0,
		"first": {"coins": 260, "xp": 550}, "repeat": {"coins": 65, "xp": 130},
	},
	# Town
	{
		"id": "town_sabotage", "map": "town", "slot": 3, "type": "sabotage",
		"name": "Scorched Streets",
		"objective": "Plant C4 on the supply truck, the generator and the fuel tank, then reach the south street before they go up.",
		"tip": "Each charge brings more soldiers. Plan the order so the last one is near the exit.",
		"player_start": Vector3(2.5, 0, 17.5), "player_yaw": 0.0,
		"targets": [{"kind": "vehicle", "pos": Vector3(-3.5, 0, -12.0), "yaw": 0.0},
				{"kind": "generator", "pos": Vector3(17.5, 0, -4.6), "yaw": 0.0},
				{"kind": "fuel", "pos": Vector3(-13.0, 0, -5.2), "yaw": 0.0}],
		"guards": [[Vector3(-1.5, 0, -14.5), 180.0], [Vector3(4.0, 0, -10.5), 160.0], [Vector3(16.0, 0, -6.2), 180.0],
				[Vector3(19.0, 0, -1.0), 120.0], [Vector3(-14.5, 0, -3.0), 200.0], [Vector3(-10.0, 0, -2.0), 160.0]],
		"exit": {"pos": Vector3(2.5, 0, 17.5), "radius": 2.8},
		"countdown": 22.0,
		"reinforcements": [{"after_plant": 1, "count": 2}, {"after_plant": 2, "count": 2}, {"after_plant": 3, "count": 3}],
		"par_time": 170.0,
		"first": {"coins": 320, "xp": 650}, "repeat": {"coins": 75, "xp": 150},
	},
	{
		"id": "town_extraction", "map": "town", "slot": 4, "type": "extraction",
		"name": "Main Street Run",
		"objective": "Push down the main street from the west barricade to the landing zone in the east, hold it, and get on the helicopter.",
		"tip": "The cars along the street are your cover. Do not rush past soldiers you have not seen.",
		"player_start": Vector3(-19.5, 0, -1.0), "player_yaw": 270.0,
		"guards": [[Vector3(-13.0, 0, 2.5), 90.0], [Vector3(-8.5, 0, 4.5), 90.0], [Vector3(-5.0, 0, -5.5), 60.0],
				[Vector3(3.0, 0, 3.0), 90.0], [Vector3(5.5, 0, -6.0), 90.0], [Vector3(9.5, 0, -4.6), 90.0]],
		"lz": {"pos": Vector3(13.0, 0, -1.0), "radius": 4.5, "yaw": 90.0},
		"hold": 30.0,
		"hold_waves": [{"at": 2.0, "count": 3}, {"at": 12.0, "count": 3}, {"at": 22.0, "count": 2}],
		"par_time": 180.0,
		"first": {"coins": 340, "xp": 700}, "repeat": {"coins": 80, "xp": 160},
	},
	{
		"id": "town_hunt", "map": "town", "slot": 5, "type": "hunt",
		"name": "High Value Target",
		"objective": "The Commander is hiding in one of the town's backyards with three bodyguards. Take him out before he drives away.",
		"tip": "Intel only gives his rough area. Shots alert everyone nearby: make the first one count.",
		"player_start": Vector3(0.0, 0, 0.0), "player_yaw": 0.0,
		"spots": [[Vector3(-19.5, 0, -19.5), 45.0], [Vector3(19.5, 0, 19.5), 225.0], [Vector3(19.5, 0, -19.5), 315.0]],
		"bodyguards": [[Vector3(1.8, 0, 0.8), 0.0], [Vector3(-1.0, 0, 1.8), 0.0], [Vector3(1.2, 0, -1.6), 0.0]],
		"vehicle": {"pos": Vector3(3.2, 0, 14.0), "yaw": 0.0, "drive": 12.0},
		"commander_hp": 12, "radio_count": 3, "intel_radius": 7.0,
		"par_time": 150.0,
		"first": {"coins": 380, "xp": 750}, "repeat": {"coins": 85, "xp": 170},
	},
	# Warehouse
	{
		"id": "warehouse_sabotage", "map": "warehouse", "slot": 3, "type": "sabotage",
		"name": "Blackout",
		"objective": "Plant C4 on the generator deep inside, the fuel tank and the van in the yard, then get back to the truck.",
		"tip": "The generator is the furthest from the exit: plant it first.",
		"player_start": Vector3(19.5, 0, 11.0), "player_yaw": 90.0,
		"targets": [{"kind": "generator", "pos": Vector3(-14.0, 0, 3.6), "yaw": 90.0},
				{"kind": "fuel", "pos": Vector3(21.0, 0, -6.5), "yaw": 90.0},
				{"kind": "vehicle", "pos": Vector3(10.8, 0, -10.4), "yaw": 90.0}],
		"guards": [[Vector3(-10.0, 0, 3.0), 270.0], [Vector3(-6.0, 0, -3.5), 270.0], [Vector3(-12.0, 0, -8.1), 270.0],
				[Vector3(3.0, 0, 2.0), 270.0], [Vector3(18.0, 0, -4.0), 180.0], [Vector3(12.5, 0, -7.0), 200.0],
				[Vector3(9.8, 0, 4.5), 270.0]],
		"exit": {"pos": Vector3(19.5, 0, 11.0), "radius": 2.5},
		"countdown": 20.0,
		"reinforcements": [{"after_plant": 1, "count": 3}, {"after_plant": 2, "count": 3}, {"after_plant": 3, "count": 3}],
		"par_time": 200.0,
		"first": {"coins": 420, "xp": 850}, "repeat": {"coins": 95, "xp": 190},
	},
	{
		"id": "warehouse_extraction", "map": "warehouse", "slot": 4, "type": "extraction",
		"name": "Through the Racks",
		"objective": "Fight from the back of the warehouse, through the aisles, out to the loading yard. Hold the landing zone until the helicopter lands.",
		"tip": "Soldiers wait in every aisle. In the yard, they come from the gate and from inside.",
		"player_start": Vector3(-14.5, 0, 0.0), "player_yaw": 270.0,
		"guards": [[Vector3(-8.0, 0, -3.0), 90.0], [Vector3(-6.0, 0, 4.0), 90.0], [Vector3(-2.0, 0, -8.1), 90.0],
				[Vector3(0.5, 0, 0.0), 90.0], [Vector3(5.0, 0, -4.0), 90.0], [Vector3(5.5, 0, 4.5), 90.0],
				[Vector3(11.0, 0, 3.0), 90.0], [Vector3(12.0, 0, -7.0), 90.0]],
		"lz": {"pos": Vector3(15.0, 0, -2.5), "radius": 4.5, "yaw": 0.0},
		"hold": 30.0,
		"hold_waves": [{"at": 2.0, "count": 3}, {"at": 11.0, "count": 3}, {"at": 20.0, "count": 3}],
		"par_time": 200.0,
		"first": {"coins": 450, "xp": 900}, "repeat": {"coins": 100, "xp": 200},
	},
	{
		"id": "warehouse_hunt", "map": "warehouse", "slot": 5, "type": "hunt",
		"name": "Kingpin",
		"objective": "The Commander is in the warehouse complex with three bodyguards. Hunt him down before he reaches his car.",
		"tip": "In the dark aisles he is hard to spot. Check the intel ring and move quietly.",
		"player_start": Vector3(14.5, 0, -1.5), "player_yaw": 90.0,
		"spots": [[Vector3(-12.0, 0, -8.1), 270.0], [Vector3(-12.0, 0, 8.1), 270.0], [Vector3(0.5, 0, -11.8), 90.0]],
		"bodyguards": [[Vector3(1.8, 0, 0.0), 270.0], [Vector3(-1.5, 0, 0.0), 270.0], [Vector3(0.0, 0, 1.5), 270.0]],
		"vehicle": {"pos": Vector3(19.5, 0, 11.2), "yaw": 90.0, "drive": 8.0},
		"commander_hp": 14, "radio_count": 4, "intel_radius": 7.0,
		"par_time": 170.0,
		"first": {"coins": 500, "xp": 1000}, "repeat": {"coins": 110, "xp": 220},
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
