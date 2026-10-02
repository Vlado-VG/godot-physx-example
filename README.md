# godot_physx test project

A Godot 4.x project for exercising the **godot_physx** engine module (a PhysX 5
`PhysicsServer3D` backend). It has no value without a custom engine build that
includes that module.

## Running

Build Godot with the `godot_physx` module, then open this project with that
editor binary. `project.godot` already selects the PhysX backend:

```
[physics]
3d/physics_engine="PhysX"
```

Scenes and tests are grouped by what they need:

- **`cpu/`** — rigid bodies, joints, characters, areas, queries. Works with any
  `godot_physx` build.
- **`gpu/`** — GPU particle fluids (`PhysXParticleFluid3D`). Needs an engine
  built with `physx_gpu=yes` and a CUDA device; inert otherwise.

`PhysXCloth3D` runs on the GPU (a PhysX deformable surface) when CUDA is present
and falls back to a built-in CPU solver otherwise, like GPU rigid dynamics — so
its scenes appear under both.

## Demos

`demo/cpu/` and `demo/gpu/` are **runtime demos** — they build the whole scene
from GDScript and are meant to be played. `demo/editor/` holds **authoring
demos** — the PhysX object is a real scene node, so you select it to use its
viewport gizmo and inspector, then press Play.

### `demo/editor/` — author with the node, then play

| Scene | What it shows |
| --- | --- |
| `cpu/cloth.tscn` | `PhysXCloth3D` flags and a banner as scene nodes: select a cloth to drag its grid handles, move its pins and tune its inspector. A `WindArea` gusts them on Play. Runs anywhere. |
| `gpu/cloth.tscn` | A 48×48 `PhysXCloth3D` sheet draping over a sphere plus a wind-blown flag — the resolution and drape the GPU deformable surface allows. SPACE drops a ball. Falls back to the CPU solver without CUDA. |
| `gpu/fluid.tscn` | `PhysXParticleFluid3D` as a scene node: gizmo and inspector for the emitter, plus the GPU isosurface + foam surface. Needs a `physx_gpu=yes` build. |
| `cpu/bridge.tscn` | A rope bridge built entirely from stock nodes — `RigidBody3D` planks joined by `Generic6DOFJoint3D` (linear axes locked, angular Z a spring). Select a `Deck/J*` joint to see the spring config and its limit gizmo. Play and it settles under the crates; `C` drops more. |
| `cpu/debris.tscn` | `PhysXChunkEmitter3D` as a scene node: select it to tune chunk size, impulse, spread and budget in the inspector. A small shooting range — walk in, left-click a wall or the floor and real rigid-body chunks fly out, bounce and settle. |
| `cpu/soft_body.tscn` | Stock `SoftBody3D` blobs (sphere, subdivided box) on the PhysX backend — select one to paint pinned vertices with its gizmo and tune `pressure_coefficient` / `linear_stiffness` / `total_mass` in the inspector. Press Play, `SPACE` drops a heavy ball on them. |
| `cpu/heightmap.tscn` | Stock `HeightMapShape3D` terrain — a `@tool` script generates the collision and the matching visible mesh from noise, so selecting `Terrain/CollisionShape3D` shows the real height-field gizmo in the editor; the exported noise params rebuild it live. Play to walk the terrain (`WASD`, `SPACE` jump) and `B` rolls a row of balls down a slope. |
| `cpu/shape_scale.tscn` | Walk a capsule character over collision shapes with non-uniform node scale baked into the geometry — stretched box platforms, a chamfered-box convex ramp, a trimesh hump, a scaled sphere dome and a scaled height-field mound. Select a piece and stretch its transform in the inspector, then press Play. |

### `demo/cpu/`

| Scene | What it shows |
| --- | --- |
| `physx_playground.tscn` | First-person character, a jointed ragdoll, a hinged door, a pendulum row, a 2000-box `MultiMesh` pile, and dangling chains. Left click launches a ragdoll, right click fires a ball with a radial blast. |
| `physx_showcase.tscn` | Box stress test with a switchable body count (1k–50k) and an orbiting camera. Each box is a `RigidBody3D` node. |
| `physx_rid_showcase.tscn` | The same stress test, but every box is a bare `PhysicsServer3D` RID body (one shared shape, no nodes) — much lighter at high counts. Use it against `physx_showcase` to see the per-node cost. |
| `physx_wind.tscn` | A gusting `WindArea` driving jointed rigid-body pennants and streamers, tumbling debris and a pendulum wind gauge; walk into the volume and it pushes the character too. |
| `cloth_wind.tscn` | The same gusting `WindArea`, now driving real `PhysXCloth3D` flags and banners (CPU XPBD), with tumbling crates and drifting leaves. Walkable. |
| `physx_bridge.tscn` | A walkable rope bridge: a chain of plank `RigidBody3D` bodies pin-jointed end to end and anchored to a stone abutment at each side, sagging into a catenary. Walk across, drop a crate pile mid-span (`C`) and it dips and holds. |
| `physx_soft_body.tscn` | A soft-body marble run — batches of stock `SoftBody3D` blobs pour down a chute, bounce and squash down a stair section and out into a catch basin. Free-fly camera (`WASD` + mouse), `F` drops more onto the running pile so the count/FPS climb, `C` clears, `B` rolls a heavy ball in. Headless `bench` mode. |
| `physx_ballpit.tscn` | A FleX-style ball pit — 5k–20k small rigid spheres (bare `PhysicsServer3D` RID bodies, one shared shape, `MultiMesh`-drawn) piling in a dark pit on the GPU solver. Wade a capsule character through them (`WASD`, `SHIFT` sprint, `SPACE` hop) and they scatter; `F` flings a wrecking ball, `G` pours a fresh wave, `1`–`4` set the count. |

### `demo/gpu/`

| Scene | What it shows |
| --- | --- |
| `physx_fluid.tscn` | A faucet streaming GPU fluid into a glass tank, with foam/spray and script-side buoyancy on dropped balls. |
| `physx_river.tscn` | **Node-authored** water slide: one continuous flume from a spring at ~98 m to the basin at 0 m -- steep chute cascade easing into flat drift reaches, with boulder runs, a cascade staircase, a heated checkpoint (Flow steam + evaporation loss), a split/merge island, a constriction and a foam bed along the way. Static bodies overlap at every joint so the channel is unbroken; every segment is prefilled full. Rigid bodies ride the river or stick by density; stock `SoftBody3D` blobs are a separate deformable test. Edit the course in the editor; the script only runs behavior. See [The river demo](#the-river-demo). |

### The river demo

`demo/gpu/physx_river.tscn` is a **PhysX GPU fluid technical demo / stress
test**, not a scenery piece -- and it is **node-authored**: the whole course
(StaticBody3D channel slabs with named parts, one PhysXParticleFluid3D faucet
per segment, RigidBody3D floaters, SoftBody3D blobs, the PhysXFlow steam rig,
camera, HUD) is ordinary nodes you can open and edit in the editor.
`demo/gpu/physx_river.gd` holds only the simulation behavior (discharge
coupling, sim LOD, buoyancy, steam gating, HUD); it discovers the course by
the scene contract documented at the top of that file.
`demo/gpu/author_river_tool.gd` is the one-shot generator that produced the
scene (`redot --headless --path . -s res://demo/gpu/author_river_tool.gd`) --
rerun it after heavy edits, or use it as the reference for the layout math.
The scene was verified through the engine's built-in MCP server
(`redot --editor --mcp-server`, tools `scene_action` / `code_intel`).

**The course is one continuous water slide.** A spring tank at ~98 m drains
down an unbroken flume to the collection basin at 0 m: the first slopes are
steep (up to ~58 deg, 9.5 m chute segments), then the course eases through a
cascade staircase, a heated checkpoint, a split/merge island, rapids, a
constriction and a foam bed into flat slow drift reaches. There are no weirs,
no plunge pools and no free falls: the floor and bank slabs span exactly
head-to-tail and meet at shared creases sealed by average-pitch joint patches
and overlapping neighbor walls, so the static bodies form one continuous
channel. Every segment is prefilled full of water at spawn.

| Along the way | What it does to the flow |
| --- | --- |
| Boulder run (52 deg) | rocks split the stream at speed |
| Cascade (48 deg) | ripple-crest staircase; the water cascades crest to crest |
| Heated checkpoint (42 deg) | emissive plates flush in the floor: where the water pools over them it boils into a `PhysXGas3D` steam plume (the fire-under-roof tech), and the measured evaporation loss throttles the next segment's discharge |
| Island split/merge (26 deg) | the channel widens around a wedge island -- the flow divides and recombines inside one continuous body |
| Rapids / constriction / foam bed | rocks, a half-width pinch, a pebble drift |
| Slow river (7-10 deg) | long flat drift; floaters ride the stream |

Rigid bodies (light balls, logs, crates, a dense rock) start along the course
and are re-assigned to whichever segment contains them: light bodies ride the
stream and travel the whole slide; the dense rock stays put. Buoyancy/drag is
script-side via `get_submersion()` (the same scheme as `physx_fluid.tscn`) on
top of the MPM couple-pass reaction. Two stock `SoftBody3D` blobs (sphere,
subdivided box) sit near the slow river and the basin as a **separate
deformable-body test**: this backend has no fluid/soft coupling, so they
squash against geometry only.

**Architecture notes.** The foam-capable fluid is the MPM compute backend,
confined to `mpm_domain_size` (a world-aligned box centered on the fluid
node) with the grid capped at 128 cells per axis -- so the slide is a chain
of 23 fluid segments. Each segment's domain is sized to its footprint plus
the joint overlap, laterally no wider than the channel, with the bottom
exactly at the floor line: water handed off at a seam always sits inside a
live domain (every fluid also couples its neighbors' floor and bank bodies),
and a squeezed particle can only pop back on top of the floor. Water is
generated at the top in play terms: each faucet emits the discharge the
upstream segment's flow meter measures, so surges propagate down the course;
flow rate crosses each seam, water mass cannot (the domains clamp particles).
With the camera away, the sim LOD freezes whole segments -- their water waits
as a static body and flows on when the camera reaches them.

One engine fix went in for this demo: the MPM solver's prefill
(`MPMFluidSolver::_seed_block`) seeded its grid axis-aligned in world space
and ignored the fluid node's rotation, so a spawn region on a pitched channel
ended up half inside the terrain. It now seeds in the node's local frame and
places the block with the node's full transform -- the same thing the PBD
path's `spawn()` always did (modules/physx/particles/mpm_fluid_solver.cpp).

**Controls:** `WASD` + hold `RMB` fly · `1`-`7` section cameras (overview,
source, boulders, heated, island, rapids, basin) · `C` tour the whole slide ·
`TAB` test mode (FULL / LAMINAR / TURBULENT / SPLIT-MERGE / STRESS -- toggles
the obstacle bodies and the split island, STRESS also boosts emission) ·
`M` **solver switch** -- MPM+foam/steam (default, the natural-looking river)
vs pure PhysX CUDA water: the PBD path has no domain boxes, so the whole
slide becomes ONE genuinely continuous body of PhysX water flowing top to
bottom, crossing every seam as mass. Honest tradeoff: a shallow stream of
0.1 m PBD particles on 55 deg chutes bounces and sprays like a ball pit --
the isosurface mesh only renders where the water pools -- and the CUDA
systems sync every frame, so PBD mode is a fluid-simulation experiment, not
the pretty mode · `[` `]` quality preset (LOW / MEDIUM /
HIGH / STRESS) · `G` object burst · `P` pause · `R` reset · `F` HUD ·
`ESC` quit. Benchmark (needs a window; the
MPM solver needs a RenderingDevice):

```
godot --path . demo/gpu/physx_river.tscn -- bench frames=600 preset=HIGH lod=off
godot --path . demo/gpu/physx_river.tscn -- shots=shots_river
```

The HUD reports total/foam particle counts, summed MPM GPU step time, how many
segments are simulating, flow-meter progress down the course, a stability
tripwire (NaN scan + domain-escape scan, one segment per 1.5 s), the heated
checkpoint's steam/evaporation state and the section under the camera.
Measured on the test machine (RTX 4080 SUPER, MEDIUM): ~271k water particles
across 23 segments plus diffuse foam at agitation points, ~56 fps at 720p
with 3 segments simulating and the steam live; `lod=off` simulates all 23 at
once and is the all-on stress number. Stability: multi-thousand-frame bench
with zero NaN and zero domain escapes.

**Limitations.** Needs a RenderingDevice (any GPU); inert under `--headless`.
CUDA/PBD fluid cannot provide foam in the current SDK (diffuse allocation is
disabled engine-side), which is why the river pins the MPM solver. The fluid is the MPM compute backend on purpose: the CUDA/PBD fluid path
cannot provide foam in the current PhysX SDK (its diffuse allocation is
disabled engine-side), and CUDA GPU dynamics still runs the rigid bodies.
The steam needs NVIDIA Flow (any NVIDIA GPU); elsewhere the checkpoint still
heats and throttles but the plume is inert. Startup builds 23 solver instances (shader
pipeline compile each) -- first load takes a while. The MPM backend has no
phase change, so evaporation is a measured discharge loss plus a Flow smoke
plume, not solver-level mass transfer. Occasional stray droplets can linger
at a joint until their segment next simulates (the frozen hand-off piles
described above). Soft-body / deformable coupling with the GPU fluid does not
exist in this backend -- the cloth demos cover deformables.

## Tests

Headless pass/fail scripts, one behaviour each:

```
godot --headless --path . --script res://test/cpu/physics_smoke.gd
```

- **`test/cpu/`** — `physics_smoke`, `sleep_test`, `query_test`, `contact_test`,
  `property_test`, `area_test`, `area_override_test`, `mesh_shape_test`,
  `joint_test`, `character_test`, `pendulum_gravity_test`, `chain_force_test`,
  `heightmap_test`, `heightmap_character_test` (walk terrain, no facet snag),
  `heightmap_edge_test` / `heightmap_crash_repro` (bodies off the height-field
  rim — regressions for the GPU boundary crash), `shape_scale_test` /
  `shape_scale_walk_test` (non-uniform scale baked into box / convex / trimesh /
  height-field shapes), `ballpit_test` (12k rigid spheres pile in a pit, a
  wrecking ball plows in), `soft_body_test`,
  `soft_body_spawn_test`, `soft_body_cascade_test`, `determinism_test`,
  `ragdoll_skeletal_test` (a rigged humanoid `Skeleton3D` +
  `PhysicalBoneSimulator3D` ragdoll: shove it, it must fall, keep its joints
  connected and never NaN).
  `physics_bench.gd` is a step-time benchmark across body counts (run once per
  engine, flipping `physics/3d/physics_engine`). `heightmap_runtime_probe.tscn`
  is a **windowed** run (not `--script`) — the GPU boundary crash only faults
  reliably with a renderer sharing the GPU.
- **`test/gpu/`** — `particle_fluid_test`, `particle_emit_test`,
  `particle_foam_test`, `particle_fluid_mpm_*` (MPM emit / collider / boundless
  variants), `particle_granular_*`, `soft_body_gpu_test` (`PxDeformableVolume` —
  fall, collide, deform, impulse, pin), `river_flow_test` (two-stage river with
  a measured hand-off: stage A must discharge into its sump, which opens stage
  B's faucet downstream). These `SKIP` (exit 0) without a CUDA device (the MPM
  ones without a RenderingDevice).

Both `physx_showcase` and `physx_rid_showcase` also take a headless benchmark
mode — no window, no rendering — that prints physics step time and rate:

```
godot --headless --path . demo/cpu/physx_rid_showcase.tscn --fixed-fps 60 -- bench count=25000 frames=600
```

## License

This project (scenes, scripts, tests) is under the MIT License — see
[LICENSE](LICENSE). Copyright (c) 2026 Wild Ox Studios.

It targets the `godot_physx` engine module, which links NVIDIA PhysX 5
(BSD-3-Clause); that licensing lives with the engine build, not here.
