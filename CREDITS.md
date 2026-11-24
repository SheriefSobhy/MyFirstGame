# Credits

Every third-party asset in this project is released under
[CC0 1.0 Universal (public domain)](https://creativecommons.org/publicdomain/zero/1.0/).
Credit isn't required, but it's listed here with thanks.

## Textures and sky: Poly Haven (https://polyhaven.com)

All at 1K resolution: albedo (`_diff`), normal (`_nor_gl`) and roughness (`_rough`) maps.

| Asset | Used for | Source |
| --- | --- | --- |
| Lonely Road Afternoon (Pure Sky) HDRI | Sky and ambient light | https://polyhaven.com/a/lonely_road_afternoon_puresky |
| Concrete Floor Worn 001 | Yard floor | https://polyhaven.com/a/concrete_floor_worn_001 |
| Factory Brick | Perimeter walls, warehouse A | https://polyhaven.com/a/factory_brick |
| Concrete Wall 008 | Warehouse B, ramp, barriers | https://polyhaven.com/a/concrete_wall_008 |
| Rusty Corrugated Iron | Shipping containers | https://polyhaven.com/a/rusty_corrugated_iron |
| Rusty Metal 02 | Metal crates, pole transformers | https://polyhaven.com/a/rusty_metal_02 |
| Rough Wood | Pallets and electricity poles (generated meshes) | https://polyhaven.com/a/rough_wood |

Concrete Wall 008 is also used for plaster patches on the brick walls and for the rubble.

## Models: Poly Haven (https://polyhaven.com)

glTF at 1K. Their textures are limited to 512 px on import.

| Asset | Source |
| --- | --- |
| Barrel 01 (red explosive barrel) | https://polyhaven.com/a/Barrel_01 |
| Barrel 03 (rusty barrel) | https://polyhaven.com/a/barrel_03 |
| Wooden Crate 02 | https://polyhaven.com/a/wooden_crate_02 |
| Old Military Crate | https://polyhaven.com/a/old_military_crate |
| Metal Jerrycan | https://polyhaven.com/a/metal_jerrycan |
| Old Tyre (tyre stacks) | https://polyhaven.com/a/old_tyre |
| Trashbag | https://polyhaven.com/a/trashbag |

## Models: Quaternius (https://quaternius.com)

Downloaded as GLB from the community showcase mirror
https://github.com/trebeljahr/quaternius-showcase, whose LICENSES.md lists each pack as CC0.

| Asset | Pack | Source |
| --- | --- | --- |
| `Character.glb`: the normal zombie enemy, with Walk, Punch, HitRecieve and Death animations | Cyberpunk Game Kit | https://quaternius.com/packs/cyberpunkgamekit.html |
| `Swat.glb`: first-person arms. Only the arms are kept and posed onto the current gun in `fp_arms.gd` | Ultimate Modular Men Pack | https://quaternius.com/packs/ultimatemodularcharacters.html |
| `buildings/Building2_Small`, `Building3_Big`, `Building3_Small`, `Building4`: skyline | Buildings Pack | https://quaternius.com/packs/buildings.html |
| `buildings/3Story_Slim_Mat`, `4Story_Mat`, `6Story_Stack_Mat`: skyline | Ultimate Buildings Pack | https://quaternius.com/packs/ultimatetexturedbuildings.html |
| `props/Rock1-3`, `Rock5`: concrete rubble, re-textured with Concrete Wall 008 | Modular Dungeon Pack | https://quaternius.com/packs/medievaldungeon.html |

### Guns: Quaternius' Ultimate Gun Pack (CC0)

All eight guns come from Quaternius' **Ultimate Gun Pack** (July 2019, 40 low-poly guns, CC0).
It was downloaded from OpenGameArt: https://opengameart.org/content/low-poly-guns-pack
(also on https://quaternius.itch.io/50-lowpoly-guns).

The pack ships as FBX/OBJ/Blend. The chosen models were converted to GLB in Godot: each model was scaled to metres with the barrel along +X and the grip at the origin.
Plain parts were made non-metallic, and parts named "Metal" were given a slight metallic sheen.
The in-game names are generic.

| File (`assets/models/quaternius/ultimate_guns/`) | In game | Pack model |
| --- | --- | --- |
| `pistol.glb` | Pistol | `Pistol_1` |
| `carbine.glb` | Assault Rifle | `AssaultRifle2_1` |
| `shotgun.glb` | Shotgun | `Shotgun_2` |
| `sniper.glb` | Sniper | `SniperRifle_1` |
| `smg.glb` | SMG | `SubmachineGun_2` |
| `ak_rifle.glb` | AK Rifle | `AssaultRifle_2` |
| `lmg.glb` | LMG | `AssaultRifle_5` with its magazine replaced by a drum (made in Godot from cylinders) and the pack's `Bipod` accessory added |
| `revolver.glb` | Revolver | `Revolver_2` |

These replace the earlier Survival Pack pistol and shotgun and the Sci-Fi Modular Gun Pack rifle and sniper.

The skyline buildings are merged into four meshes by `tools/build_level.gd`, with their material colours stored as vertex colours.

### Enemy types: Quaternius' Ultimate Animated Character Pack (CC0)

The runner, brute, boss, soldier and exploder enemies use characters from Quaternius' **Ultimate Animated Character Pack** (Nov 2019, 50+ animated characters, CC0).
It was downloaded from OpenGameArt: https://opengameart.org/content/animated-characters-pack

The FBX files are kept as shipped and imported by Godot. Each character has Walk, Punch, RecieveHit and Shoot_OneHanded animations.
The pack's "Defeat" animation is a slumped pose, so for these enemies the death is the hit animation plus a fall-over done in code.
Each type is recoloured in code (`enemy_types.gd`) so it's easy to recognise.

| File (`assets/models/quaternius/characters/`) | Enemy | Changes in game |
| --- | --- | --- |
| `Zombie_Female.fbx` | Runner | Small; red shirt, paler skin |
| `Zombie_Male.fbx` | Brute and Brute Boss | Large; red-brown skin and dark clothes. The boss is bigger and darker, with glowing red eyes |
| `Soldier_Male.fbx` | Soldier | Holds the game's pistol model (`ultimate_guns/pistol.glb`) |
| `Worker_Male.fbx` | Exploder | Red hard hat and a glowing, pulsing orange vest |

### Maps 2 and 3: town and warehouse models (CC0)

The Abandoned Town and Warehouse Night maps are built by `tools/build_maps.gd`.
It merges these models into a few vertex-coloured meshes (in `level/generated/town_*.res` and `wh_*.res`), so the source files in `assets/models/map_sources/` aren't exported with the game.

| File(s) (`assets/models/map_sources/`) | Used for | Pack | Source |
| --- | --- | --- | --- |
| `quaternius/1Story_Mat`, `1Story_GableRoof_Mat`, `2Story_Mat`, `2Story_Balcony_Mat`, `2Story_GableRoof_Mat` | Town houses (scaled up, each tinted a different colour) | Quaternius, Ultimate Buildings Pack | https://quaternius.com/packs/ultimatetexturedbuildings.html |
| `quaternius/Streetlight_Single`, `Sign_Stop`, `TrafficLight` | Town street lights, stop sign, traffic light | Quaternius, Street Pack | https://quaternius.com (GLB from the mirror https://github.com/trebeljahr/quaternius-showcase) |
| `kenney/sedan`, `suv`, `van`, `police`, `truck`, `taxi`, `hatchbackSports` | Town cars, and the truck in the warehouse yard | Kenney, Car Kit (license in `kenney/carkit_License.txt`) | https://kenney.nl/assets/car-kit |

Both maps also reuse assets listed elsewhere on this page:
- the Poly Haven textures (asphalt and pavement are the concrete floor and wall textures, re-tinted);
- the props (barrels, crates, pallets, tyres, jerrycans);
- the yard's distant skyline.

The warehouse's pallet racks, boxes and forklifts, the lamp fixtures and the road markings are made from simple shapes in `tools/build_maps.gd`.
No CC0 forklift model was found.

## Sounds

| File(s) | Used for | Author / pack | Source |
| --- | --- | --- | --- |
| `gunshot_pistol.wav` | Pistol gunshot | The Free Firearm Sound Library (Walther PPQ, `X_31P.wav`), cut to a single 0.7 s shot | https://opengameart.org/content/the-free-firearm-sound-library |
| `guns/*.wav` | Every gun's shot, plus all reload, pump, bolt and cylinder sounds | The Free Firearm Sound Library, by Ben Jaszczak (see the table below) | Mirror: https://github.com/buddingmonkey/FreeFirearmsSFXLibrary |
| `footstep_concrete_000-004.ogg` | Footsteps | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `impactPunch_medium_000-002.ogg` | Enemy hit | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `impactGeneric_light_000-002.ogg` | Bullet impacts on walls, grenade bounces | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `metalClick.ogg`, `metalLatch.ogg` | Dry-fire click (out of ammo) and grenade pin, ammo box pickup | Kenney, RPG Audio | https://kenney.nl/assets/rpg-audio |
| `explosion.ogg` | Grenade explosion | EZduzziteh, "Explosions" (`explosion1.ogg`) | https://opengameart.org/content/explosions-4 |
| `zombie_moans.ogg` | Normal zombie growls and death groan | Darsycho, "Zombie moans" | https://opengameart.org/content/zombie-moans |
| `wind_loop.ogg` | Ambient wind | "Wind Whoosh Loop" | https://opengameart.org/content/wind-whoosh-loop |

The `guns/` sounds come from the library's CC0 GitHub mirror (its LICENSE file is CC0 1.0).
Each file is a short cut of one track, converted to mono 16-bit 44.1 kHz and normalised.

| File | Gun | Library track |
| --- | --- | --- |
| `rifle_shot.wav` | AR-15 | `Prepared SFX/AR-15/D_24P.wav` |
| `rifle_mag_out.wav`, `rifle_mag_in.wav` | AR-15 | `D_3.wav` (detach mag), `D_4.wav` (insert loaded mag) |
| `shotgun_shot.wav` | Benelli Nova | `Prepared SFX/Nova/O_17P.wav` |
| `shotgun_pump.wav`, `shotgun_shell.wav` | Benelli Nova | `O_6.wav` (full pump cycle), `O_7.wav` (insert shell) |
| `sniper_shot.wav` | Tikka T3 | `Prepared SFX/Tikka/W_24P.wav` |
| `sniper_bolt.wav`, `sniper_mag_out.wav`, `sniper_mag_in.wav` | Tikka T3 | `W_16.wav` (bolt cycle), `W_5.wav` (detach mag), `W_4.wav` (insert mag) |
| `pistol_mag_out.wav`, `pistol_mag_in.wav` | Walther PPQ | `X_3.wav` (detach mag), `X_4.wav` (insert loaded mag) |
| `smg_shot.wav` | Carl Gustav M45 | `Prepared SFX/Carl Gustav M45/G_20P.wav` |
| `smg_mag_out.wav`, `smg_mag_in.wav`, `smg_bolt.wav` | Carl Gustav M45 | `G_9.wav` (detach mag), `G_8.wav` (insert mag), `G_10.wav` (lock back bolt) |
| `ak_shot.wav` | AK-47 | `Prepared SFX/AK-47/C_31P.wav` |
| `ak_mag_out.wav`, `ak_mag_in.wav`, `ak_bolt.wav` | AK-47 (also used for the LMG) | `C_11.wav` (detach mag), `C_10.wav` (insert mag), `C_2.wav` (full cycle) |
| `lmg_shot.wav` | Norinco SKS (played at a lower pitch) | `Prepared SFX/SKS/U_19P.wav` |
| `revolver_shot.wav` | Smith & Wesson 642 | `Prepared SFX/Smith & Wesson 642/V_22P.wav` |
| `revolver_open.wav`, `revolver_eject.wav`, `revolver_load.wav`, `revolver_close.wav` | Smith & Wesson 642 | `V_9.wav` (flip cylinder open), `V_3.wav` (extract shells), `V_18.wav` (load cylinder), `V_10.wav` (flip cylinder closed) |

The sound library names the real guns it recorded. In the game every weapon has a generic name.

### Enemy sounds (`assets/sounds/enemies/`)

Each file was cut to a single sound, converted to mono 16-bit 44.1 kHz and normalised.

| File(s) | Used for | Author / pack | Source |
| --- | --- | --- | --- |
| `runner_1-3.wav` | Runner shrieks | artisticdude, "Zombies Sound Pack" (`zombie-3`, `zombie-11`, `zombie-13`) | https://opengameart.org/content/zombies-sound-pack |
| `exploder_1-2.wav` | Exploder groans | artisticdude, "Zombies Sound Pack" (`zombie-16`, `zombie-17`) | https://opengameart.org/content/zombies-sound-pack |
| `brute_1-2.wav` | Brute and boss growls (played low) | Ogrebane, "Monster Sound Pack" (`Monster-1`, `Monster-2`) | https://opengameart.org/content/monster-sound-pack-volume-1 |
| `soldier_hurt_1-2.wav` | Soldier grunts | Ogrebane, "Monster Sound Pack" (`monster-10`, `monster-12`) | https://opengameart.org/content/monster-sound-pack-volume-1 |
| `brute_roar.wav` | The boss's roar when it appears | trazzz123, "CC0 Deep Monster Roar" | https://opengameart.org/content/cc0-deep-monster-roar |
| `brute_step_1-3.ogg` | Brute and boss footsteps | Kenney, Impact Sounds (`impactSoft_heavy_000-002`) | https://kenney.nl/assets/impact-sounds |
| `exploder_beep.ogg` | Exploder beeping | Kenney, Interface Sounds (`tick_002`) | https://kenney.nl/assets/interface-sounds |
| `soldier_warning.ogg` | Soldier's warning tone before a shot | Kenney, Digital Audio (`highUp`) | https://kenney.nl/assets/digital-audio |

The soldier's shot reuses `gunshot_pistol.wav`, and exploders reuse the grenade's `explosion.ogg`.

The Kenney sounds were taken from the mirror https://github.com/ETdoFresh/kenney.nl.
Kenney's own license files are kept in `assets/sounds/kenney_*_License.txt`.

## Music

All tracks are by yd on OpenGameArt, released as CC0. They're kept as uploaded (Ogg Vorbis, about 160 kbps) and loop in-game.

| File | Used for | Track | Source |
| --- | --- | --- | --- |
| `assets/music/menu_menace.ogg` | Main menu | "Menace" by yd | https://opengameart.org/content/menace |
| `assets/music/game_zombies_march.ogg` | Gameplay, Industrial Yard | "Zombies' March" by yd (`ZombiesAreComing.ogg`) | https://opengameart.org/content/zombies-march |
| `assets/music/town_empty_city.ogg` | Gameplay, Abandoned Town | "EmptyCity" by yd | https://opengameart.org/content/emptycity-background-music |
| `assets/music/warehouse_insistent.ogg` | Gameplay, Warehouse Night | "Insistent" by yd | https://opengameart.org/content/insistent-background-loop |

## Code-generated effects and detail

The bullet holes, sparks, dust, blood, muzzle flash, sniper scope overlay, ammo boxes, pickup glow, the frag grenade model, the explosion (fireball, smoke, sparks, light flash and scorch mark), the grenade throw preview, the weapon wheel, the soldier's warning laser, glint and tracers, the boss health bar, the map selection screen and the menu screens (theme and background gradient) use no image files.
They're built in Godot from gradients and simple meshes.

These were made for this project, so no license applies:

- `assets/textures/generated/`: the grime textures (cracks, oil, dirt stains, puddle mask), the tiling noise used to vary the walls and floor, and the chain-link pattern. `tools/gen_textures.gd` makes them from noise and random walks.
- The pallets, electricity poles, wires, chain-link fences and grime quads in `level/generated/`. `tools/build_level.gd` builds them from boxes and cylinders.
- The baked lighting (`main.lmbake`, `main.exr`), made with Godot's LightmapGI.
- The map pictures on the map selection screen (`ui/thumbnails/`), rendered from the game by `tools/make_thumbnails.gd`.
