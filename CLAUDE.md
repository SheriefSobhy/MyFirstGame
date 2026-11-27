# Dead Perimeter — project notes

A first-person wave-survival shooter in Godot 4.7 (GDScript). Ships to the web
(GitHub Pages from `docs/`), Android (debug APK) and Windows.

- Godot: `C:\Godot\Godot_v4.7.2-stable_win64_console.exe`
- Renderer: GL Compatibility (web/desktop), Mobile on Android. Keep every
  effect working in Compatibility. Third-party assets are CC0, except the
  Mixamo characters/arms and the CC BY 4.0 Sketchfab guns (CREDITS.md). Raw art goes in `art_source/`
  (git-ignored: some FBX files are over 100 MB). Never commit raw FBX.
- Style: plain GDScript, `preload()` constants instead of `class_name`,
  UI mostly built in code, every balance number in a config script.

## Layout

| What | Where |
|---|---|
| Main menu → Play: mode → map → match | `ui/main_menu.*`, `ui/map_select.*` (mode step, then map cards), `ui/loading_screen.*` (tip + progress bar, threaded load), a map scene (`main.tscn`, `maps/*.tscn`, `maps/combat_*.tscn`) |
| Match flow (waves, score, spawns, Game Over) | `main.gd` (every map scene runs it; `map_id` picks the save key) |
| Player, weapons, upgrades, skins on the view models | `player.gd`, `weapon_stats.gd`, `weapon_view.gd`, `weapon_model.gd`, `fp_arms.gd`, `effects/casings.gd` (see "First-person weapons") |
| Enemies | `enemy.gd`, `enemy_types.gd`, models in `assets/models/enemies/` (see "Enemy models") |
| HUD, pause, Game Over, level-up popup, toasts | `hud.gd` / `hud.tscn`, `combat_feedback.gd`, `touch_controls.gd` |
| First-match tutorial | `tutorial.gd` (added to the HUD by `main.gd`) |
| Revive ("Watch ad to revive", placeholder ad) | `ui/revive_screen.gd`, `main.gd` `_on_player_died` |
| Customize Controls (touch layout editor) | `ui/controls_editor.gd` (opened from Settings) |
| Graphics Auto (FPS-measured quality) | `auto_quality.gd` |
| In-match economy (cash, shop, power-ups, barrels) | config `economy.gd`, state `match_economy.gd`, UI `ui/shop_menu.gd` |
| **Persistent progression** | config `progression_config.gd`, state `progress.gd` (autoload `Progress`) |
| Armory / Achievements screens | `ui/armory_menu.gd`, `ui/achievements_menu.gd` (overlays on the main menu) |
| Weapon skins (material tint / camo) | `weapon_skins.gd` |
| **Lighting mood** (3 maps, not Training) | config `atmosphere_config.gd`, builder `atmosphere.gd` (created by `main.gd`), shader `effects/light_shaft.gdshader` |
| Maps list, modes | `maps.gd` (`LIST` for map select, `MODES`, `save_key`, `for_mode`, `TRAINING` for the arena) |
| **Training Arena** (main menu > Training) | scene `maps/training.tscn` (built by `build_maps.gd`), `training/training.gd` (extends `main.gd`), `training/target.gd`, `training/weapon_rack.gd`, `training/training_ui.gd`, config `training_config.gd` |
| **Combat mode** (Play > Combat > map) | see "Game modes" |
| Settings + best scores | `settings.gd` (autoload `Settings`), `ui/settings_menu.*` |
| Music | `music.gd` (autoload `Music`) |
| Level kit (Blender-made walls, frames, roofs, pipes, signs...) | `tools/blender/build_kit.py` → `assets/models/kit/kit.glb` + `assets/textures/kit/`, placed by `tools/kit_builder.gd`, material `materials/kit.tres` (`kit_surface.gdshader`) |
| Build / bake / test scripts | `tools/` |

## Balance numbers

- In-match (cash, shop prices, 3-level match upgrades, power-ups, revive): `economy.gd`.
- Persistent (XP curve, level unlocks, coins, Armory prices and bonuses,
  skins, daily mission pool, login rewards, map star waves, achievements):
  `progression_config.gd`. Change numbers there only.
- Weapon stats: `weapon_stats.gd`. Enemy stats: `enemy_types.gd`.
- Training Arena (target/dummy/challenge layout and numbers): `training_config.gd`.

## Training Arena (`training/`)

Always unlocked, opened from the main menu's Training button through the
loading screen (`Maps.TRAINING`, not in `Maps.LIST`). Nothing is earned:
`training.gd` never calls `Progress.start_match`/`on_kill`/..., so no XP,
coins, missions, achievements or best scores (a test checks this).

- `training.gd` extends `main.gd` (graphics quality, navmeshes, prewarm) and
  replaces `_ready`/`_process`; no waves. Player: `invincible`,
  `own_all_weapons()`, `set_infinite_ammo()` (reserve -1, reloads stay),
  `infinite_grenades`. Armory upgrades/skins apply as in a match.
- Range: firing line z = 0, downrange -z to 100 m. Lanes: one per distance on
  the left (paper + 2 steel plates, `LANES`, so near targets never hide far
  ones), pop-ups and 2 moving targets in the middle, dummies on the right.
  Weapon rack on the hall's back wall (E / TAKE).
- Targets (`target.gd`) look like enemies to the gun (`take_damage`,
  `is_head_hit`, `hp`), so hit markers/damage numbers work; the silhouette's
  head is a headshot. Steel plates fall and reset after `METAL_RESET`.
- Dummies are `enemy.gd` with `dummy = true`: never chase/attack/aim, the
  exploder doesn't blow up; `set_dummy_walk()` patrols slowly along the lane.
  They come back `DUMMY_RESPAWN` s after dying; head zones show `head_sphere()`.
- Stats from `player.fired` + `enemy_hit` (one shot = one hit however many
  pellets). DPS is in damage-number units (x10).
- Challenges (`CHALLENGES`): Target Practice (time), Headshot Challenge
  (count), Reflex (accuracy %); bests in `Settings.training_bests`
  (`user://save.cfg` [training]), cleared with the best scores.
- Lit by the sun + a baked lightmap (`maps/training.lmbake/.exr`, ~0.9 MB);
  the hall lamps are `BAKE_STATIC` (no runtime cost).

## Game modes: Zombies and Combat (`soldiers/`)

Play → choose a mode (`maps.gd` `MODES`) → choose a map. Both modes on all
3 maps, same level unlocks. Zombies = the map scene (`main.gd`), unchanged.

- **Save keys** (`Maps.save_key(map, mode)`): Zombies `"town"`, Combat
  `"combat_town"`: best scores, best wave / stars and "reach wave" missions
  are per mode and map. `maps_played` counts the base map (`Maps.base_id`).
  The old `"soldiers"` key loads as `combat_yard`.
- **Scenes**: `maps/combat_<map>.tscn` = the map scene with
  `soldiers/soldiers_mode.gd` (extends `main.gd`; `base_map_id` keeps the
  map id for the lighting mood, `map_id` becomes the save key).
  `Maps.for_mode(id, mode)` gives the entry for `LoadingScreen.go`.
- **Cover** is generated at runtime from the level's ground box colliders
  (`soldiers_mode.gd` `cover_objects` / `_build_cover`, numbers in
  `soldiers_config.gd`): tall (>= 1.75 m: houses, containers, racks,
  forklifts) = stand + peek past the corner; low (1-1.75 m: cars, crates,
  dumpsters) = crouch (`crouch_modifier.gd`, procedural SkeletonModifier3D:
  hips down + leg IK; the pose only exists during `skeleton_updated`, so the
  crouched head hitbox is cached there) and stand up to fire. Poles and
  outer walls are skipped. The warehouse map has no low objects.
- Soldier AI `tactical_soldier.gd` (extends `enemy.gd`); a cover whose peek
  showed nothing is skipped until the player moves. Spawns >= 16 m from the
  player, out of sight if possible. Damage indicator + regen.
- Phone demo: `adb shell "run-as <package> sh -c 'echo town > files/soldiers_demo'"`
  (`soldiers_demo.gd` autopilot, 75 s, FPS report in `files/soldiers_demo.txt`).
- `test_soldiers` runs all 3 maps (`-- --map town` for one).

## Combat missions (`missions/`)

Play → Combat → Waves (the mode above) or Missions → map → 5 slots
(`missions_config.gd` `SLOTS`; an empty slot would say "Coming soon"). Slot n
unlocks when slot n-1 is cleared (`Progress.is_mission_unlocked`).

- Data + every number: `missions_config.gd` (`LIST`: 15 missions, slots
  1-5 = Defend, Rescue, Sabotage, Extraction, Hunt on each map, positions in
  map metres, yaw 0 = facing -Z). `Missions.pending` = the mission to load;
  scenes `maps/mission_<map>.tscn` run `mission_mode.gd` (extends
  `soldiers_mode.gd`; no waves/shop/score/Waves progress; `_end_progress`
  returns {}).
- Framework: briefing (paused) → START → objective → `finish()` → result
  screen (Retry / Next / Missions / Menu). Objective types extend
  `objective.gd` (`setup/begin/tick/star2`; guards: `spawn_guard(s)`,
  alert spreading, `listen_for_gunshots`), registered in `mission_mode.gd`
  `TYPES`. Helpers: `snap`, `spawn_soldier_at`, `queue_soldier`,
  `add_interactable` (USE button / hold E, `mission_ui.gd`, optional reach).
  Stars: complete / `star2()` (par time for all but Defend) / health > 50%;
  `Progress.complete_mission` keeps the best and pays first-clear or repeat
  rewards (`mission_stars` in progress.cfg [missions]).
- Defend (`defend.gd`): `zone_ring.gd`; pushers (`tactical_soldier.gd`
  `push_spot`) walk in; capture fills only without the player inside.
  Star 2 = capture never above 50% (the timer is fixed).
- Rescue (`rescue.gd`, `hostage.gd`): guards (`alert = false`, `guard_post`)
  wake on sight/sound/shots; hold USE 3 s; the hostage follows on the small
  navmesh, ducks (crouch_modifier), is on physics layer 4 (player bullets
  pass through); soldiers aim bursts at him (`alt_target`, `alt_chance`).
  Mesh = Exploder (Ch35 officer); anims `hostage_anims.res` from
  `mixamo_anims.gd -- --only hostage` (`HOSTAGE_SET`: placeholders until
  Terrified / Walking / Running are downloaded).
- Sabotage (`sabotage.gd`, `sabotage_target.gd`): generator / fuel tank
  (primitives) / Kenney truck, box collider + NavigationObstacle3D (the
  baked navmesh doesn't know them). Hold USE 4 s to plant (guards within
  PLANT_NOISE hear it), reinforcements per charge, countdown + exit zone;
  blasts = `Blast.detonate` + extra fireballs + a burning wreck. In the exit
  zone when they blow = win.
- Extraction (`extraction.gd`, `helicopter.gd`): reach the LZ, hold it 30 s
  (the clock stops outside), waves; the helicopter's approach is driven by
  the hold clock (`driven`, last HELI_APPROACH s), it lands, stepping within
  BOARD_RADIUS = win. Model `assets/models/vehicles/helicopter.glb` from
  `tools/blender/build_helicopter.py` (CC0 source in `art_source/opengameart/`).
- Hunt (`hunt.gd`, `escape_vehicle.gd`): Commander = guard with
  `make_commander()` (tint, beret, `armor` 0.5 on non-headshots, more hp);
  random spot (`Hunt.force_spot` for tests), intel ring; alerted = `flee_to`
  the car's door spot (picked when spotted: the navmesh must be ready),
  radio after RADIO_DELAY → backup; reaches the car = fail, killed = win.
- Rotor / engine / C4 / radio sounds are synthesized (`synth_sounds.gd`).
- `test_missions` runs all 5 types on all 3 maps (`-- --map town` for one);
  path checks wait for `navmesh_ready()` after START (not during the paused
  briefing). test_soldiers' town "damage direction indicator" check is
  flaky (~1 in 3).

## Persistent progression (`progress.gd`)

Saved to `user://progress.cfg` (browser storage on the web) after every wave,
at match end, after each Armory purchase/login claim, and on app close/pause.
Best scores stay in `user://save.cfg` (Settings).

- **XP / level 1-50**: kills (per enemy type, + headshot), wave clears, match
  end. XP counts immediately, so level-ups pop up mid-match (`hud.show_level_up`).
  Each level-up also pays `LEVEL_UP_COINS`.
- **Unlocks**: shop weapons by level (SMG 2, Shotgun 3, Revolver 5, AK 7,
  Sniper 10, LMG 15); maps (Town 4, Warehouse 8). Locked items show the level.
  `Settings.debug_unlock_all` ("Debug: all weapons") gives every weapon and
  unlocks every weapon and map.
- **Coins**: match end (`match_coins(waves, kills)`), missions, login streak,
  achievements, level-ups. Spent in the Armory.
- **Armory**: per weapon, permanent damage (+8%/lvl), mag (+10%/lvl), reload
  (-6%/lvl), 5 levels; they stack with the match shop's upgrades via
  `player.stat_value()`. Fractional damage is rolled per bullet
  (`player.roll_damage()`). Skins: Standard, Desert, Black, Camo, Gold.
- **Daily missions**: 3 per local day, seeded by the date, progress carried
  across matches, auto-paid on completion. New set after local midnight.
- **Login reward**: popup on the first main-menu visit of the day; 7-day
  streak, a missed day restarts at day 1.
- **Map stars**: 1 each for reaching wave 5 / 10 / 15 (highest wave
  *started*, `Progress.best_wave`), shown on the map cards.
- **Achievements**: 18, checked against `Progress.stat_value()`.
- `main.gd` drives it: `start_match` → `on_wave_started` / `on_kill` /
  `on_wave_cleared` → `end_match` (Game Over, or Main Menu from pause;
  idempotent per match).
- "Debug: reset progress" (Settings, hidden mid-match, press twice) calls
  `Progress.reset_all()`, which also clears the best scores.

## Mobile / first impression

- **Tutorial**: plays while `Settings.tutorial_done` is false (new players;
  Settings > Replay Tutorial). Wave 1 waits until the basics (move, look,
  shoot, aim, switch, grenade) are done or skipped; the shop tip shows at the
  first break. Touch tips point at the button (`touch_controls.highlight`).
- **Touch layout**: `Settings.touch_layout` {name: {pos, scale}} overrides
  `touch_controls.gd` BUTTONS. `pos.x >= 0` is from the left edge, `< 0` from
  the right; `pos.y` from the bottom. Saved unmirrored; `left_handed` mirrors
  at draw/hit time (joystick too). `touch_opacity` fades buttons + stick.
  Always go through `_button_center()` / `_button_radius()`.
- **Quality**: `Settings.quality` may be `AUTO`; everything reads
  `Settings.effective_quality()`. Auto measures once (first 10 s of a match,
  FPS cap lifted meanwhile), saves `auto_quality`; re-picking Auto measures again.
- **FPS cap**: `Settings.fps_cap` 30/60 → `Engine.max_fps` (never in headless).
- **Revive**: once per match (`economy.gd` REVIVE_*). The ad is a placeholder in
  `ui/revive_screen.gd` `_play_ad()`: hook the real rewarded-ad SDK there.
- **Loading screen**: map select calls `LoadingScreen.go(tree, map)`.
  The single-threaded web build loads in one go (the bar jumps).

## Testing

Each test is a SceneTree script that prints PASS/FAIL and exits 1 on failure:

```
"C:\Godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path . --script res://tools/test_progression.gd
```

Tests: `test_progression`, `test_economy`, `test_game_loop`, `test_maps`,
`test_weapons`, `test_combat_feel`, `test_enemies`, `test_mobile`,
`test_training`, `test_soldiers`, `test_missions`, `test_navigation` (run that one with `--fixed-fps 60`). Most accept `-- --shots <folder>`
(without `--headless`) to save screenshots for a visual check.

- Under a tool script, `Progress` starts empty and saves to
  `user://progress_test.cfg`, so tests never touch real progress.
  `Settings` also skips the tutorial, Auto measuring and the saved touch
  layout / left-handed / opacity under a tool script (a test can turn the
  tutorial on with `Settings.tutorial_done = false`). Dying offers a revive
  first: set `main.revives_left = 0` to go straight to Game Over. Entering a
  map from map select goes through the loading screen (wait for the scene
  by name, not a fixed number of frames). Tests that
  need weapons/maps unlocked set `Progress.xp` (e.g. `xp_for_level(15)`).
- Tests that write best scores back up and restore `user://save.cfg`.
- In test helpers, wait for `process_frame` as well as `physics_frame` after
  a scene change (it completes at the end of a process frame).
- The navigation map belongs to the window, so a new map scene (or Retry)
  inherits a non-zero iteration id from the previous one. Only trust path /
  closest-point queries once `main.navmesh_ready()` is true (it compares
  against the id recorded when the scene loaded). Getting this wrong made
  Bosses spawn off their navmesh in a too-narrow gap on the Town map.
- `test_navigation` counts an enemy as stuck as soon as its own 2 s stuck
  check fires; enemies that can't reach the player (too tight for their size)
  must *wait* at the end of their path, or behind one already waiting there.

## Level kit (Blender)

Blender 5.3 is at `C:Program FilesBlender FoundationBlender 5.3lender.exe`,
used headless only (`blender -b --factory-startup --python ...`).

- `tools/blender/build_kit.bat` runs `build_kit.py`: composes the 1024 texture
  atlas (brick, concrete, corrugated, metal, wood cells + 8 rendered signs)
  from the CC0 textures, models every piece (LOD0 with bevels/trims/small
  parts, `<name>_lod1` without), bakes AO with Cycles into `kit_ao.png`, and
  exports `kit.glb` (build-time only: excluded from exports).
- Vertex data the shader relies on: UV = cell-local repeating UV, UV2 = AO
  atlas UV, COLOR.a = (cell + 8 * palette index + 0.5) / 128. Keep `CELLS` and
  `PAL` in `build_kit.py` in sync with `CELLS` / `PALETTE` in
  `kit_surface.gdshader`. glTF import mangles vertex RGB, so per-instance
  tints are written by `kit_builder.gd` (rgb = tint / 2).
- `kit_builder.gd` merges placed pieces into 14 m chunks (one draw call each,
  one material), moves the AO UV to CUSTOM0 (UV2 stays free for the yard
  lightmap), and adds LOD1 chunks with visibility ranges (town 24 m,
  warehouse 22 m; the yard has no LOD1). Wall details (signs, pipes, AC
  units, lamps) only exist in LOD0.
- Kit visuals never collide: the box colliders stay where they were (walls
  keep full-height colliders, so broken tops are kept under ~0.9 m deep).
- After changing the kit: `build_kit.bat`, then `build_level.gd` and
  `build_maps.gd`, then `tools/rebake.bat`.
- `build_maps.gd -- --only training` (or town / warehouse) rebuilds one map;
  `rebake.bat training` (or yard) bakes one lightmap (the autobake plugin
  bakes `main.tscn` and `maps/training.tscn`). The editor run re-serializes
  `project.godot` and `ui/theme.tres`: revert those (`git checkout`).
- `make_thumbnails.gd -- --only <id>` (with a window) renders one picture.
- `rebake.bat` imports headless first: the editor crashed (signal 11) when it
  had to VRAM-compress new textures itself (GPU compressor on this Intel GPU).
- Size: the kit added ~5 MB to the APK (atlas textures ~2.8 MB, merged meshes
  ~1.7 MB, a larger yard lightmap).
- `tools/map_shots.gd -- --shots <dir> --bench` (with a window): screenshots
  from fixed views per map, and FPS / draw calls / triangles per quality.

## First-person weapons

Sources (git-ignored): `art_source/sketchfab/*.zip` (CC BY 4.0) and
`art_source/mixamo/soldier.fbx`. `tools/blender/build_guns.bat` rebuilds
everything: `build_guns.py` -> `assets/models/guns/<id>_high/med/low.glb`
(barrel +X, grip at origin, real metres; parts named `mag`, `slide`, `bolt`,
`charger`, `pump`, `cover`, `cylinder`, `trigger`, rest `body`),
`build_arms.py` -> `assets/models/arms/arms_<lod>.glb`, then
`tools/gun_imports.gd` sets import options (no auto LODs/shadow meshes, VRAM
textures). Colour maps 1024/512/256 px, normal + metal/rough maps half that
(Low: colour only).

- `Camera3D/ViewModel` is scaled 0.5 (`player.gd` VIEW_SCALE) about the eye:
  life-size picture, half the wall clipping. View-space numbers
  (`hip`, `ads_distance`, sway, recoil) are in its unscaled metres.
- `weapon_view.gd` (one per weapon, model LOD = graphics quality): part
  animations (slide/bolt kick, pump, sniper bolt, revolver cylinder; reloads
  with the left hand on the magazine, LMG cover, revolver swing-out, shotgun
  shells), hand targets (`HANDS` shapes per `hold`), ejection port.
- `fp_arms.gd`: per-frame two-bone IK of the Mixamo arms to the hand
  targets (collarbone reach, forearm twist, finger curls from target meta).
  Re-parenting a target onto a part makes the hand follow it.
- `effects/casings.gd`: pooled MultiMesh casings, no physics bodies.
- Pistol only (optional keys in `weapon_stats.gd`, others keep defaults):
  `gloves_<lod>.glb` (`build_gloves.py`: hands + short plain sleeve, 2K bake),
  `view_scale` 0.25 (no wall clipping), `view_fov` (ViewModel scaled in X/Y,
  no extra pass), spring recoil, breathing, holster switch, 1.8 s reload with
  a falling magazine copy (`_pistol_reload`). On the phone, `touch
  files/pistol_test` instead of `weapon_tour` runs a pistol-only pass with
  per-step frame times (record it with `adb shell screenrecord`).
- The first Android vibration costs ~80 ms: `Haptics.warm_up()` runs in
  `main._prewarm_effects`.
- ADS: `sight_height` (m above the grip; 0 = measured) on the camera axis;
  the rifle gets the procedural reflex sight (`RedDotSight`).
- Tuning tools (window needed): `tools/viewmodel_lab.gd -- --out <dir>
  [--weapon 1] [--ads] [--reload 0.4] [--views fp,side,top,front]` (arms + gun
  alone, from outside too), `tools/weapon_shots.gd -- --shots <dir>`.
- On a phone (debug APK): `adb shell run-as <package> touch files/weapon_tour`
  then start the app: `weapon_tour.gd` screenshots every gun (hip / ADS /
  fire / reload) into `files/tour/` with an FPS report, then quits. Pull with
  `adb exec-out run-as <package> tar c files/tour > tour.tar`.

## Enemy models (Mixamo)

Source: `art_source/mixamo/` (characters with skin + animations without,
all on the Mixamo skeleton; not in git, `.gdignore`d). `tools/blender/build_enemies.bat`
rebuilds everything: `tools/mixamo_export.gd` (Godot reads the FBX, incl.
FBX 6.1 that Blender can't; bones lose the `mixamorig_` prefix) ->
`build_enemies.py` (Blender: `<id>_high/med/low.glb`, ~15k/7k/3k tris,
1024/512/256 px WebP; Blender JPEGs fail in Godot's loader) ->
`tools/mixamo_anims.gd` (VRAM compression on the extracted textures, then
`<id>_anims.res`).

- `enemy_types.gd` `model_scene(kind, quality)` loads only the LOD for
  `Settings.effective_quality()`; enemy.gd adds an AnimationPlayer with the
  library (tracks `Skeleton3D:<bone>`, root = the skeleton's parent).
- Retargeting is a world-space delta from the T-pose per bone (the anim
  rigs' rests differ). Looping clips have forward root motion removed;
  metadata: `ground_speed` (walk playback, capped by `anim_speed.walk_max`),
  `steps` (footstep thuds), `hit_time` (attack starts so the strike lands at
  `attack_hit_time`).
- Death clips fall backwards: shot from behind, the body spins to face the
  shot first. No hit clip: HIT plays idle + the procedural flinch.
- Head hitbox: `Head` -> `HeadTop_End`. Soldier rifle on `RightHand`,
  aimed towards `LeftHand`. Boss = Brute mesh, bigger, `tint` darker.
- Size: ~11 MB of glb/webp in the repo; ~1.4 MB of animation libraries.
- `tools/enemy_shots.gd -- --shots <dir> [--maps]` (with a window): each type
  close up, a line-up, and a gameplay shot per map.

## Build and publish

- `build_all.bat`: Android APK → `builds/DeadPerimeter.apk`, Windows →
  `builds/windows/DeadPerimeter.exe` (git-ignored). No commit.
- `publish.bat`: web export to `docs/`, commit everything, push (GitHub Pages).
- `tools/rebake.bat`: lightmaps + navmeshes after level geometry changes.

## Lighting and atmosphere (yard, town, warehouse)

- **Baked**: every map has a LightmapGI (HIGH quality, 6 bounces, denoiser,
  soft sun via `light_angular_distance`). Direct light stays real-time, the
  lightmap holds bounce light only; extra lamps are `BAKE_STATIC` (no runtime
  cost). Town/warehouse: houses, floor tiles and kit LOD0 chunks are baked
  (`BAKE_TEXEL`, `texel_scale 0.4`); cars, racks, props and kit LOD1 are lit by
  the probes. Lightmaps: yard 2.9 MB, town 1.0, warehouse 0.75 (EXR, stored
  uncompressed by `rebake.bat`). After level changes: `build_maps.gd -- --only
  town` (or warehouse), then `rebake.bat town` (or warehouse / yard).
- **Mood** (`atmosphere_config.gd` -> `atmosphere.gd`, applied at runtime so a
  map rebuild never loses it): per-map tonemap + adjustments + 1D colour curve
  + glow, fog, CPU dust around the camera, additive light shaft cylinders
  (`light_shaft.gdshader`: cones under lamps, beams along the sun/moon),
  ReflectionProbes (update once), flickering lamps, emergency lights (police
  car, warehouse red beacons).
- **Quality** (`Atmosphere.apply_quality`, called from `main._apply_quality`):
  Low = baked light + grade; Medium = + fog, dust, flickering lamps; High = +
  probes, shafts, glow, emergency lights. Auto uses the same switch.
- `map_shots.gd -- --shots <dir>` saves High and Low pictures per view.
