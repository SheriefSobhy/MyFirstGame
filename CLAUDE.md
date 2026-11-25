# Last Stand — project notes

A first-person wave-survival shooter in Godot 4.7 (GDScript). Ships to the web
(GitHub Pages from `docs/`), Android (debug APK) and Windows.

- Godot: `C:\Godot\Godot_v4.7.2-stable_win64_console.exe`
- Renderer: GL Compatibility (web/desktop), Mobile on Android. Keep every
  effect working in Compatibility. All third-party assets are CC0 (CREDITS.md).
- Style: plain GDScript, `preload()` constants instead of `class_name`,
  UI mostly built in code, every balance number in a config script.

## Layout

| What | Where |
|---|---|
| Main menu → map select → match | `ui/main_menu.*`, `ui/map_select.*`, `ui/loading_screen.*` (tip + progress bar, threaded load), a map scene (`main.tscn`, `maps/*.tscn`) |
| Match flow (waves, score, spawns, Game Over) | `main.gd` (every map scene runs it; `map_id` picks the save key) |
| Player, weapons, upgrades, skins on the view models | `player.gd`, `weapon_stats.gd`, `weapon_model.gd`, `fp_arms.gd` |
| Enemies | `enemy.gd`, `enemy_types.gd` |
| HUD, pause, Game Over, level-up popup, toasts | `hud.gd` / `hud.tscn`, `combat_feedback.gd`, `touch_controls.gd` |
| First-match tutorial | `tutorial.gd` (added to the HUD by `main.gd`) |
| Revive ("Watch ad to revive", placeholder ad) | `ui/revive_screen.gd`, `main.gd` `_on_player_died` |
| Customize Controls (touch layout editor) | `ui/controls_editor.gd` (opened from Settings) |
| Graphics Auto (FPS-measured quality) | `auto_quality.gd` |
| In-match economy (cash, shop, power-ups, barrels) | config `economy.gd`, state `match_economy.gd`, UI `ui/shop_menu.gd` |
| **Persistent progression** | config `progression_config.gd`, state `progress.gd` (autoload `Progress`) |
| Armory / Achievements screens | `ui/armory_menu.gd`, `ui/achievements_menu.gd` (overlays on the main menu) |
| Weapon skins (material tint / camo) | `weapon_skins.gd` |
| Maps list | `maps.gd` |
| Settings + best scores | `settings.gd` (autoload `Settings`), `ui/settings_menu.*` |
| Music | `music.gd` (autoload `Music`) |
| Build / bake / test scripts | `tools/` |

## Balance numbers

- In-match (cash, shop prices, 3-level match upgrades, power-ups, revive): `economy.gd`.
- Persistent (XP curve, level unlocks, coins, Armory prices and bonuses,
  skins, daily mission pool, login rewards, map star waves, achievements):
  `progression_config.gd`. Change numbers there only.
- Weapon stats: `weapon_stats.gd`. Enemy stats: `enemy_types.gd`.

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
`test_weapons`, `test_combat_feel`, `test_enemies`, `test_mobile`, `test_navigation`
(run that one with `--fixed-fps 60`). Most accept `-- --shots <folder>`
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

## Build and publish

- `build_all.bat`: Android APK → `builds/LastStand.apk`, Windows →
  `builds/windows/LastStand.exe` (git-ignored). No commit.
- `publish.bat`: web export to `docs/`, commit everything, push (GitHub Pages).
- `tools/rebake.bat`: lightmap + navmeshes after level geometry changes.
