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
| `Character.glb`: enemy soldier with Walk, Punch, HitRecieve and Death animations | Cyberpunk Game Kit | https://quaternius.com/packs/cyberpunkgamekit.html |
| `Pistol_1.glb`: pistol | Survival Pack | https://quaternius.com/packs/survival.html |
| `guns/Shotgun_1.glb`: shotgun | Survival Pack | https://quaternius.com/packs/survival.html |
| `guns/AR_1.glb`: assault rifle | Sci-Fi Modular Gun Pack | https://quaternius.com/packs/scifimodularguns.html |
| `guns/Sniper_1.glb`: sniper rifle | Sci-Fi Modular Gun Pack | https://quaternius.com/packs/scifimodularguns.html |
| `Swat.glb`: first-person arms. Only the arms are kept and posed onto the current gun in `fp_arms.gd` | Ultimate Modular Men Pack | https://quaternius.com/packs/ultimatemodularcharacters.html |
| `buildings/Building2_Small`, `Building3_Big`, `Building3_Small`, `Building4`: skyline | Buildings Pack | https://quaternius.com/packs/buildings.html |
| `buildings/3Story_Slim_Mat`, `4Story_Mat`, `6Story_Stack_Mat`: skyline | Ultimate Buildings Pack | https://quaternius.com/packs/ultimatetexturedbuildings.html |
| `props/Rock1-3`, `Rock5`: concrete rubble, re-textured with Concrete Wall 008 | Modular Dungeon Pack | https://quaternius.com/packs/medievaldungeon.html |

The skyline buildings are merged into four meshes by `tools/build_level.gd`, with their material colours stored as vertex colours.

## Sounds

| File(s) | Used for | Author / pack | Source |
| --- | --- | --- | --- |
| `gunshot_pistol.wav` | Pistol gunshot | The Free Firearm Sound Library (Walther PPQ, `X_31P.wav`), cut to a single 0.7 s shot | https://opengameart.org/content/the-free-firearm-sound-library |
| `guns/*.wav` | Rifle, shotgun and sniper gunshots, and every weapon's reload, pump and bolt sounds | The Free Firearm Sound Library, by Ben Jaszczak (see the table below) | Mirror: https://github.com/buddingmonkey/FreeFirearmsSFXLibrary |
| `footstep_concrete_000-004.ogg` | Footsteps | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `impactPunch_medium_000-002.ogg` | Enemy hit | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `impactGeneric_light_000-002.ogg` | Bullet impacts on walls | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `metalClick.ogg`, `metalLatch.ogg` | Dry-fire click (out of ammo), ammo box pickup | Kenney, RPG Audio | https://kenney.nl/assets/rpg-audio |
| `zombie_moans.ogg` | Enemy growls and death groan | Darsycho, "Zombie moans" | https://opengameart.org/content/zombie-moans |
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

The Kenney sounds were taken from the mirror https://github.com/ETdoFresh/kenney.nl.
Kenney's own license files are kept in `assets/sounds/kenney_*_License.txt`.

## Code-generated effects and detail

The bullet holes, sparks, dust, blood, muzzle flash, sniper scope overlay, ammo boxes and pickup glow use no image files.
They're built in Godot from gradients and simple meshes.

These were made for this project, so no license applies:

- `assets/textures/generated/`: the grime textures (cracks, oil, dirt stains, puddle mask), the tiling noise used to vary the walls and floor, and the chain-link pattern. `tools/gen_textures.gd` makes them from noise and random walks.
- The pallets, electricity poles, wires, chain-link fences and grime quads in `level/generated/`. `tools/build_level.gd` builds them from boxes and cylinders.
- The baked lighting (`main.lmbake`, `main.exr`), made with Godot's LightmapGI.
