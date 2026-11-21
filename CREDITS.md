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
| Rusty Metal 02 | Metal crates | https://polyhaven.com/a/rusty_metal_02 |

## Models: Poly Haven (https://polyhaven.com)

glTF at 1K. Their textures are limited to 512 px on import.

| Asset | Source |
| --- | --- |
| Barrel 01 (red explosive barrel) | https://polyhaven.com/a/Barrel_01 |
| Barrel 03 (rusty barrel) | https://polyhaven.com/a/barrel_03 |
| Wooden Crate 02 | https://polyhaven.com/a/wooden_crate_02 |
| Old Military Crate | https://polyhaven.com/a/old_military_crate |
| Metal Jerrycan | https://polyhaven.com/a/metal_jerrycan |

## Models: Quaternius (https://quaternius.com)

Downloaded as GLB from the community showcase mirror
https://github.com/trebeljahr/quaternius-showcase, whose LICENSES.md lists each pack as CC0.

| Asset | Pack | Source |
| --- | --- | --- |
| `Character.glb`: enemy soldier with Walk, Punch, HitRecieve and Death animations | Cyberpunk Game Kit | https://quaternius.com/packs/cyberpunkgamekit.html |
| `Pistol_1.glb`: player pistol | Survival Pack | https://quaternius.com/packs/survival.html |

## Sounds

| File(s) | Used for | Author / pack | Source |
| --- | --- | --- | --- |
| `gunshot_pistol.wav` | Gunshot | The Free Firearm Sound Library (Walther PPQ, `X_31P.wav`), cut to a single 0.7 s shot | https://opengameart.org/content/the-free-firearm-sound-library |
| `footstep_concrete_000-004.ogg` | Footsteps | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `impactPunch_medium_000-002.ogg` | Enemy hit | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `impactGeneric_light_000-002.ogg` | Bullet impacts on walls | Kenney, Impact Sounds | https://kenney.nl/assets/impact-sounds |
| `metalClick.ogg`, `metalLatch.ogg` | Reload (mag out / mag in) | Kenney, RPG Audio | https://kenney.nl/assets/rpg-audio |
| `zombie_moans.ogg` | Enemy growls and death groan | Darsycho, "Zombie moans" | https://opengameart.org/content/zombie-moans |
| `wind_loop.ogg` | Ambient wind | "Wind Whoosh Loop" | https://opengameart.org/content/wind-whoosh-loop |

The Kenney sounds were taken from the mirror https://github.com/ETdoFresh/kenney.nl.
Kenney's own license files are kept in `assets/sounds/kenney_*_License.txt`.

## Code-generated effects

The bullet holes, sparks, dust, blood and muzzle flash use no image files.
They're built in Godot from gradients and simple meshes.
