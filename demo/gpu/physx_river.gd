extends Node3D

# GPU river-flow stress test for the PhysX backend (PhysXParticleFluid3D).
#
# A test river descends ~100 m -> 0 m as a terraced cascade: fourteen staged
# plunge pools, each one PhysXParticleFluid3D fluid stepping ~6 m down the
# hillside. Every stage exercises one flow regime -- source spring, laminar
# run, swirl turn, boulder field, churn ridges, a jet split around a wedge,
# two parallel branches (calm A vs rocky B), a merge confluence, rapids
# steps, a constriction gap, a final chute and the 0 m collection basin,
# which takes the course's one tall plunge. Foam, splash, rigid floaters and
# fluid/rigid coupling are real; nothing is faked with shader effects.
#
# Why terraces: the foam-capable solver is the MPM compute backend, which is
# confined to mpm_domain_size (a box centered on the node -- the faucet), with
# the grid capped at 96 cells along X and 32 analytic colliders per fluid, and
# -- decisively -- whose couple pass freezes the grid nodes of a particle film
# lying on a surface. Thin overland flow and weir spillways therefore stall at
# every scale (measured), while free-falling jets, plunge pools, splashes and
# bulk pool sloshing all behave. The river is built from what the solver
# actually does well: each terrace is a deep plunge pool -- prefilled at spawn
# so its level is independent of the emission balance -- with its own cascade
# plume at the pool head. Stages are hydraulically coupled: a submersion probe
# at each pool's outlet modulates the next faucet's emission rate, so a surge
# upstream propagates down the whole course; the hand-off itself is a measured
# discharge transfer at each lip -- flow rate crosses the boundary, not mass.
#
# Simulation LOD: every MPM fluid syncs its own GPU queue once per physics
# tick (~13 ms each on the test GPU), so all fourteen stages at once spend
# more time in driver sync than in solver time. Stages near the camera run at
# full rate and the rest hold their pools frozen, resuming -- with the
# discharge coupling -- as the camera reaches them; lod=off removes the
# culling for the all-on stress number, stages=N caps the simulating count.
#
#   WASD + RMB   fly camera          1..7  section cameras   C  tour the river
#   TAB          cycle test mode     [ ]   quality preset    G  object burst
#   P            pause               R     reset             F  toggle HUD
#   ESC          quit
#
# Headless-friendly benchmark (needs a window -- the MPM solver needs a
# RenderingDevice); presets/stage cap/lod can be preselected on the command line:
#   godot --path . demo/gpu/physx_river.tscn -- bench frames=600 preset=HIGH lod=off

const WATER_DENSITY := 1000.0

# Per-stage fluid budget presets. Particle size sets the MPM grid cell (the
# solver targets ~2 cells per particle, capped at 96 along X); the pool depth
# is sized to stay several cells deep at every preset so the water always moves
# as a body. Emission stays a fraction of capacity so most particles stand in
# the pool -- the faucet is the through-flow, the buffer is the pool. The GPU
# isosurface water mesh is HIGH/STRESS only: fourteen fluids re-meshing every
# third tick costs far more CPU than the solver itself, so MEDIUM runs the
# sphere MultiMesh (LOW too) and the surface is the detail preset's luxury.
const PRESETS := {
	"LOW": {
		"particle_size": 0.07, "particles": 7000, "foam": 2500, "rate": 1100.0,
		"surface": false, "substeps": 4,
	},
	"MEDIUM": {
		"particle_size": 0.058, "particles": 18000, "foam": 6000, "rate": 2200.0,
		"surface": false, "substeps": 5,
	},
	"HIGH": {
		"particle_size": 0.058, "particles": 26000, "foam": 9000, "rate": 3000.0,
		"surface": true, "substeps": 5,
	},
	"STRESS": {
		"particle_size": 0.058, "particles": 36000, "foam": 14000, "rate": 5000.0,
		"surface": true, "substeps": 6,
	},
}
const PRESET_ORDER: Array[String] = ["LOW", "MEDIUM", "HIGH", "STRESS"]

# Test modes (TAB). Each is a rule set over the registered obstacle groups and
# the channel-B branch; the fluid collider lists and faucet gates are rebuilt
# from them.
const MODES: Array[String] = ["FULL", "LAMINAR", "TURBULENT", "SPLIT/MERGE", "STRESS"]

const SECTION_COLORS := {
	"SOURCE": Color(0.92, 0.9, 0.55),
	"LAMINAR": Color(0.6, 0.9, 0.6),
	"TURN": Color(0.6, 0.8, 0.95),
	"TURBULENT": Color(0.95, 0.7, 0.4),
	"SPLIT": Color(0.8, 0.65, 0.95),
	"CHANNEL A": Color(0.55, 0.9, 0.7),
	"CHANNEL B": Color(0.95, 0.55, 0.45),
	"MERGE": Color(0.95, 0.6, 0.75),
	"RAPIDS": Color(1.0, 0.62, 0.35),
	"CHUTE": Color(1.0, 0.75, 0.45),
	"BASIN": Color(0.55, 0.85, 0.85),
}

class Reach:
	var kind: String
	var stage := 0
	var root: Node3D # yawed frame; faucet at local origin
	var fluid: PhysXParticleFluid3D
	var domain := Vector3.ZERO # mpm_domain_size
	var prefill := Vector3.ZERO # spawn_region_size: the plunge pool slab
	var outlet_probe := AABB() # world-space fill probe at the pool's outlet end
	var outlet_pos := Vector3.ZERO # world; feeds the next terrace's faucet
	var exit_yaw := 0.0 # downstream heading leaving this terrace
	var base_rate := 2200.0
	var emit_vel := Vector3(1.8, -1.5, 0) # local (reach frame)
	var static_bodies: Array[Node] = [] # basin geometry, always coupled
	var obstacle_bodies: Array[Node] = [] # mode-toggled colliders
	var floaters: Array[RigidBody3D] = [] # coupled + buoyancy-simulated
	var upstream: Array[Reach] = [] # stages whose discharge feeds this faucet
	var node_local := Vector3(2.0, -6.65, 0) # pool center, 0.5 m over the water
	var anchor_pos := Vector3.ZERO # section-camera vantage
	var anchor_look := Vector3.ZERO
	var filled_at := -1.0 # sim seconds until the outlet probe first read >= 0.5
	var rate_scale := 1.0 # live emission multiplier (mode / coupling)

	func _init(p_kind: String) -> void:
		kind = p_kind

var _reaches: Array[Reach] = []
var _floaters: Array[RigidBody3D] = [] # every spawned body, in spawn order
var _floater_home := {} # body -> initial transform (reach-local)
var _floater_reach := {} # body -> reach index
var _floater_stranded := {} # body -> sim seconds since it fell below y = -6
var _gate_reach := -1 # channel-B stage index (mode-toggled faucet)

var _preset := "MEDIUM"
var _mode_idx := 0
var _hud: Label
var _hud_visible := true
var _cam: Camera3D
var _fly: FlyCamera
var _tour := false
var _tour_target := 0
var _t := 0.0
var _paused := false
var _couple_accum := 0.0
var _hud_accum := 0.0
var _scan_accum := 0.0
var _scan_reach := 0 # staggered per-reach validation scan
var _nan_total := 0
var _escapes := 0
var _obj_moved := false
var _bench := false
var _bench_frames := 600
var _bench_frame := 0
var _active_stages := 999 # stages beyond this are frozen (perf scaling knob)
var _lod_off := false # lod=off: every stage simulates (the all-on stress number)
var _sim_radius := 45.0 # stages within this of the camera simulate; others hold
var _sim_active := 0

@onready var _mat_bed: StandardMaterial3D = _make_mat(Color(0.38, 0.36, 0.33), 1.0)
@onready var _mat_bank: StandardMaterial3D = _make_mat(Color(0.45, 0.4, 0.34), 0.95)
@onready var _mat_rock: StandardMaterial3D = _make_mat(Color(0.32, 0.31, 0.3), 0.9)
@onready var _mat_wall: StandardMaterial3D = _make_mat(Color(0.52, 0.5, 0.47), 0.85)
@onready var _mat_water: StandardMaterial3D = _make_water_mat()
@onready var _mat_gate: StandardMaterial3D = _make_mat(Color(0.85, 0.3, 0.2), 0.6)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # keep input + HUD alive while paused

	for arg in OS.get_cmdline_user_args():
		if arg == "bench":
			_bench = true
		elif arg.begins_with("frames="):
			_bench_frames = int(arg.substr(7))
		elif arg.begins_with("preset="):
			var wanted := arg.substr(7)
			if wanted in PRESET_ORDER:
				_preset = wanted
		elif arg.begins_with("stages="):
			_active_stages = int(arg.substr(8))
		elif arg == "lod=off":
			_lod_off = true

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.fog_enabled = true
	e.fog_density = 0.0012
	e.fog_light_color = Color(0.75, 0.82, 0.9)
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	add_child(sun)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.far = 1200.0
	_cam.position = Vector3(60, 55, 62)
	_cam.look_at(Vector3(14, 42, 14))
	_fly = FlyCamera.new(_cam, 22.0)

	_build_river()
	_spawn_floaters()
	_apply_mode() # builds the per-reach collider lists for the FULL mode
	# bench/profiling knob: stages beyond the limit stay visible but frozen
	for i in range(_active_stages, _reaches.size()):
		if is_instance_valid(_reaches[i].fluid):
			_reaches[i].fluid.process_mode = Node.PROCESS_MODE_DISABLED

	var layer := CanvasLayer.new()
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 17)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)

# ------------------------------------------------------------------ geometry

func _make_mat(albedo: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	return m

func _make_water_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.1, 0.38, 0.6, 0.6)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.metallic = 0.1
	m.roughness = 0.06
	m.refraction_enabled = true
	m.refraction_scale = 0.05
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

# A static box with a matching visual; `rot` is in the parent frame.
func _slab(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos
	sb.rotation = rot
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	sb.add_child(mi)
	parent.add_child(sb)
	return sb

# A half-buried boulder; spheres resolve exactly as MPM analytic colliders.
func _rock(parent: Node3D, pos: Vector3, radius: float, register_into: Reach = null) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos + Vector3(0, radius * 0.45, 0)
	var cs := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	cs.shape = shape
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	mi.mesh = sm
	mi.material_override = _mat_rock
	sb.add_child(mi)
	parent.add_child(sb)
	if register_into != null:
		register_into.obstacle_bodies.append(sb)
	return sb

func _label(parent: Node3D, text: String, pos: Vector3, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 64
	l.pixel_size = 0.055
	l.outline_size = 14
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.9)
	parent.add_child(l)

# ------------------------------------------------------------------ terraces
# Terrace-local frame: the faucet hangs at the origin, `depth` above the plunge
# pool's water surface. The pool is the prefill slab, walled, with the outlet
# lip on +X where the next terrace's faucet hooks on. Proven working envelope:
# pools several grid cells deep, jets in free fall, features as bulk obstructions.

func _new_reach(stage: int, kind: String, origin: Vector3, yaw_deg: float) -> Reach:
	var reach := Reach.new(kind)
	reach.stage = stage
	reach.root = Node3D.new()
	reach.root.position = origin
	reach.root.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
	add_child(reach.root)
	reach.domain = Vector3(12, 14, 7)
	_reaches.append(reach)
	return reach

# The common pool: floor, side banks, upstream wall, outlet lip. Returns the
# world-space outlet probe and lip position through the reach.
# Build one terrace's pool at `water_y` below the faucet (the jet free-falls
# that far); the pool spans local x 0.6 .. 0.6 + length.
func _build_pool(reach: Reach, length: float, width: float, depth: float, water_y: float, bank_extra := 0.0) -> void:
	var floor_y := water_y - depth
	var bank_h := depth + 1.0 + bank_extra # banks stand 1 m above the water line
	var wall_h := depth + 0.45 # upstream wall stays below the faucet
	var t := 0.5
	var cx := 2.0 # pool spans local x 0.6 .. 0.6 + length
	reach.static_bodies.append(_slab(reach.root, Vector3(cx, floor_y - t * 0.5, 0), Vector3(length + 1.0, t, width + 1.0), _mat_bed))
	for side in [-1.0, 1.0]:
		reach.static_bodies.append(_slab(reach.root, Vector3(cx, floor_y + bank_h * 0.5, side * (width * 0.5 + t * 0.5)),
				Vector3(length + 1.4, bank_h + t, t), _mat_bank))
	reach.static_bodies.append(_slab(reach.root, Vector3(0.6 - t * 0.5, floor_y + wall_h * 0.5, 0),
			Vector3(t, wall_h + t, width + 1.4), _mat_bank))
	# outlet lip: crest 0.35 above the water line -- contains the pool, reads
	# as the weir the next waterfall pours from
	reach.static_bodies.append(_slab(reach.root, Vector3(0.6 + length + 0.25, floor_y + (depth + 0.35 + 1.0) * 0.5, 0),
			Vector3(0.5, depth + 1.35, width + 1.0), _mat_wall))
	var xf := reach.root.global_transform
	var probe_local := AABB(Vector3(0.6 + length - 1.2, floor_y + 0.05, -width * 0.4), Vector3(1.1, depth - 0.1, width * 0.8))
	reach.outlet_probe = AABB(xf * probe_local.position, probe_local.size)
	reach.outlet_pos = xf * Vector3(0.6 + length + 0.5, water_y, 0)
	var exit_dir := xf.basis * Vector3(1, 0, 0)
	reach.exit_yaw = atan2(-exit_dir.z, exit_dir.x)

func _finish_reach(reach: Reach, anchor_local: Vector3, look_local: Vector3) -> void:
	var xf := reach.root.global_transform
	reach.anchor_pos = xf * anchor_local
	reach.anchor_look = xf * look_local
	_spawn_fluid(reach)

func _spawn_fluid(reach: Reach) -> void:
	var p: Dictionary = PRESETS[_preset]
	if is_instance_valid(reach.fluid):
		reach.fluid.queue_free()
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_MPM # the foam-capable path, on any GPU
	f.spawn_on_ready = true # prefill: the plunge pool starts full and at rest
	f.particle_count = p.particles
	f.particle_size = p.particle_size
	f.viscosity = 0.02
	f.cohesion = 0.02
	f.surface_tension = 0.006
	f.spawn_region_size = Vector3(reach.prefill.x, minf(reach.prefill.y, 0.45), reach.prefill.z)
	f.mpm_domain_size = reach.domain
	f.mpm_substeps = p.substeps
	f.emitting = true
	f.emission_rate = reach.base_rate * (p.rate / PRESETS["MEDIUM"].rate)
	f.emission_radius = 0.16
	f.emission_velocity = reach.emit_vel
	f.surface_mesh = p.surface # GPU marching-tetrahedra water surface
	f.foam_enabled = true # MPM diffuse layer: foam/spray/bubbles where agitated
	f.foam_particle_count = p.foam
	f.foam_lifetime = 2.2
	f.foam_threshold = 170.0 # MPM scale; lower = foams more readily
	f.foam_buoyancy = 0.9
	f.material_override = _mat_water
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	f.process_mode = Node.PROCESS_MODE_PAUSABLE
	reach.root.add_child(f)
	f.position = reach.node_local # faucet = domain center, over the pool head
	reach.fluid = f

func _build_river() -> void:
	# Each terrace's faucet hangs ~2.1 m above the previous outlet lip, one
	# step downstream along the previous exit heading; its jet then free-falls
	# ~6 m into the pool, so the waterfall IS the inter-stage descent.
	var origin := Vector3(0, 100, 0)
	var yaw := 0.0

	# S1 SOURCE -- the spring: a deep pool plunged straight down into.
	var r: Reach = _new_reach(1, "SOURCE", origin, yaw)
	r.prefill = Vector3(2.2, 0.65, 2.2)
	r.emit_vel = Vector3(0.4, -4.5, 0.4)
	r.base_rate = 2400.0
	_build_pool(r, 2.6, 2.6, 0.7, -7.15)
	_label(r.root, "SOURCE - 100m", Vector3(0.5, 1.4, 0), SECTION_COLORS["SOURCE"])
	_label(r.root, "STAGE 1/14", Vector3(2.2, -4.6, 0), Color(1, 1, 1, 0.6))
	_finish_reach(r, Vector3(-4.5, 3.5, 4.5), Vector3(1.8, -6.6, 0))

	# S2 LAMINAR -- long, wide, calm; the jet glides across the surface.
	r = _chain_next(r, 22.0)
	r.kind = "LAMINAR"
	r.prefill = Vector3(3.3, 0.5, 2.3)
	r.emit_vel = Vector3(2.6, -0.5, 0)
	_build_pool(r, 3.4, 2.6, 0.55, -7.15)
	_label(r.root, "LAMINAR FLOW", Vector3(1.5, 1.2, 0), SECTION_COLORS["LAMINAR"])
	_finish_reach(r, Vector3(-3.8, 2.6, 4.6), Vector3(2.0, -6.7, 0))

	# S3 TURN -- crescent pool; the tangential jet sets the whole basin swirling.
	r = _chain_next(r, 40.0)
	r.kind = "TURN"
	r.prefill = Vector3(2.6, 0.55, 2.4)
	r.emit_vel = Vector3(2.4, -0.9, 1.2)
	_build_pool(r, 2.8, 2.8, 0.6, -7.15)
	for side in [-1.0, 1.0]:
		r.static_bodies.append(_slab(r.root, Vector3(2.0, -6.7, side * 1.85), Vector3(2.2, 1.0, 0.5), _mat_bank, Vector3(0, 0, side * 0.35)))
	_label(r.root, "TURN / SWIRL", Vector3(1.2, 1.2, 0), SECTION_COLORS["TURN"])
	_finish_reach(r, Vector3(-4.2, 3.0, -4.4), Vector3(1.8, -6.6, 0))

	# S4 ROCK GARDEN -- the jet slams a boulder field mid-pool.
	r = _chain_next(r, -36.0)
	r.kind = "TURBULENT"
	r.prefill = Vector3(2.8, 0.5, 2.4)
	r.emit_vel = Vector3(2.2, -2.4, 0)
	_build_pool(r, 3.0, 2.8, 0.55, -7.15)
	_rock(r.root, Vector3(1.9, -7.15, -0.5), 0.42, r)
	_rock(r.root, Vector3(2.4, -7.15, 0.55), 0.3, r)
	_rock(r.root, Vector3(1.4, -7.15, 0.7), 0.34, r)
	_label(r.root, "TURBULENCE / OBSTACLES", Vector3(1.4, 1.2, 0), SECTION_COLORS["TURBULENT"])
	_finish_reach(r, Vector3(-4.2, 2.8, 4.4), Vector3(2.0, -6.7, 0))

	# S5 CHURN -- a submerged ridge and a partial barrier chop the splash up.
	r = _chain_next(r, 30.0)
	r.kind = "TURBULENT"
	r.prefill = Vector3(2.6, 0.5, 2.3)
	r.emit_vel = Vector3(2.0, -2.2, 0)
	_build_pool(r, 2.8, 2.6, 0.55, -7.15)
	r.static_bodies.append(_slab(r.root, Vector3(1.6, -7.35, 0), Vector3(1.2, 0.4, 2.6), _mat_bed)) # ridge
	r.obstacle_bodies.append(_slab(r.root, Vector3(2.5, -7.05, -0.9), Vector3(0.8, 1.0, 1.0), _mat_wall)) # partial barrier
	_label(r.root, "HIGH TURBULENCE", Vector3(1.4, 1.2, 0), SECTION_COLORS["TURBULENT"])
	_finish_reach(r, Vector3(-3.8, 2.6, -4.6), Vector3(1.8, -6.7, 0))

	# S6 SPLIT -- the jet divides around a wedge; both parallel branches feed
	# from this terrace's discharge.
	r = _chain_next(r, -24.0)
	r.kind = "SPLIT"
	r.prefill = Vector3(2.9, 0.5, 2.9)
	r.emit_vel = Vector3(2.2, -2.2, 0)
	r.base_rate = 2600.0
	_build_pool(r, 3.1, 3.2, 0.55, -7.15)
	r.static_bodies.append(_slab(r.root, Vector3(1.9, -6.95, 0), Vector3(1.3, 0.9, 0.45), _mat_wall, Vector3(0, 0, 0.18)))
	_label(r.root, "FLOW SPLIT", Vector3(1.2, 1.2, 0), SECTION_COLORS["SPLIT"])
	_finish_reach(r, Vector3(-4.4, 2.8, 4.4), Vector3(2.0, -6.7, 0))
	var split := r

	# S7A / S7B -- the two branches, in parallel at the same elevation.
	var a := _branch_next(split, false, 26.0)
	a.kind = "CHANNEL A"
	a.prefill = Vector3(2.8, 0.5, 2.7)
	a.emit_vel = Vector3(2.2, -1.8, 0)
	_build_pool(a, 3.0, 3.0, 0.55, -7.15)
	_label(a.root, "CHANNEL A - LOW TURBULENCE", Vector3(1.4, 1.2, 0), SECTION_COLORS["CHANNEL A"])
	_finish_reach(a, Vector3(-4.0, 2.6, -4.6), Vector3(2.0, -6.7, 0))

	var b := _branch_next(split, true, -26.0)
	b.kind = "CHANNEL B"
	b.base_rate = b.base_rate * 0.75 # the narrow branch carries less discharge
	b.prefill = Vector3(2.6, 0.5, 2.0)
	b.emit_vel = Vector3(2.0, -2.0, 0)
	_build_pool(b, 2.8, 2.3, 0.55, -7.15)
	_rock(b.root, Vector3(1.8, -7.15, -0.35), 0.3, b)
	_rock(b.root, Vector3(2.3, -7.15, 0.4), 0.24, b)
	b.static_bodies.append(_slab(b.root, Vector3(2.0, -6.8, 0.85), Vector3(1.0, 1.1, 0.4), _mat_wall)) # constriction wall
	_gate_reach = _reaches.find(b)
	_label(b.root, "CHANNEL B - HIGH TURBULENCE", Vector3(1.2, 1.2, 0), SECTION_COLORS["CHANNEL B"])
	_finish_reach(b, Vector3(-3.8, 2.6, 4.4), Vector3(1.8, -6.7, 0))

	# S8 MERGE -- both branches feed this faucet; deflector wedges split the
	# plume into two arms that impinge -- a real confluence.
	r = _chain_next(a, 0.0)
	r.upstream = [a, b]
	r.kind = "MERGE"
	r.base_rate = 2400.0
	r.prefill = Vector3(2.8, 0.5, 2.7)
	r.emit_vel = Vector3(0.8, -3.4, 0)
	_build_pool(r, 3.0, 3.0, 0.55, -7.15)
	r.static_bodies.append(_slab(r.root, Vector3(2.0, -7.0, -0.8), Vector3(1.1, 0.9, 0.4), _mat_wall, Vector3(0, 0, -0.4)))
	r.static_bodies.append(_slab(r.root, Vector3(2.0, -7.0, 0.8), Vector3(1.1, 0.9, 0.4), _mat_wall, Vector3(0, 0, 0.4)))
	_label(r.root, "FLOW MERGE / TURBULENCE", Vector3(1.4, 1.2, 0), SECTION_COLORS["MERGE"])
	_finish_reach(r, Vector3(-4.2, 2.8, 4.4), Vector3(2.0, -6.7, 0))

	# S9 RAPIDS -- the jet hammers a staircase of submerged steps.
	r = _chain_next(r, 28.0)
	r.kind = "RAPIDS"
	r.prefill = Vector3(2.7, 0.5, 2.3)
	r.emit_vel = Vector3(1.6, -4.2, 0)
	_build_pool(r, 2.9, 2.6, 0.55, -7.15)
	for i in range(3):
		r.static_bodies.append(_slab(r.root, Vector3(1.2 + i * 0.7, -7.5 + i * 0.22, 0), Vector3(0.6, 0.35, 2.5), _mat_bed))
	_label(r.root, "RAPIDS / FOAM", Vector3(1.4, 1.2, 0), SECTION_COLORS["RAPIDS"])
	_finish_reach(r, Vector3(-4.0, 3.4, -4.4), Vector3(1.8, -6.7, 0))

	# S10 CONSTRICTION -- the whole stream is squeezed through a narrow gap.
	r = _chain_next(r, -30.0)
	r.kind = "TURBULENT"
	r.prefill = Vector3(2.6, 0.5, 2.3)
	r.emit_vel = Vector3(2.4, -2.6, 0)
	_build_pool(r, 2.8, 2.6, 0.55, -7.15)
	for side in [-1.0, 1.0]:
		r.static_bodies.append(_slab(r.root, Vector3(1.8, -6.55, side * 0.62), Vector3(1.0, 1.5, 1.0), _mat_wall))
	_label(r.root, "CONSTRICTION", Vector3(1.2, 1.2, 0), SECTION_COLORS["TURBULENT"])
	_finish_reach(r, Vector3(-3.8, 2.6, 4.6), Vector3(1.8, -6.7, 0))

	# S11 CHURN 2 -- a dense small-rock bed for foam-on-impact.
	r = _chain_next(r, 24.0)
	r.kind = "TURBULENT"
	r.prefill = Vector3(2.6, 0.5, 2.3)
	r.emit_vel = Vector3(2.0, -2.6, 0)
	_build_pool(r, 2.8, 2.5, 0.55, -7.15)
	_rock(r.root, Vector3(1.7, -7.15, -0.4), 0.26, r)
	_rock(r.root, Vector3(2.1, -7.15, 0.35), 0.22, r)
	_rock(r.root, Vector3(2.5, -7.15, -0.15), 0.3, r)
	_rock(r.root, Vector3(1.4, -7.15, 0.55), 0.2, r)
	_label(r.root, "FOAM BED", Vector3(1.4, 1.2, 0), SECTION_COLORS["TURBULENT"])
	_finish_reach(r, Vector3(-3.8, 2.6, -4.6), Vector3(1.8, -6.7, 0))

	# S12 FINAL CHUTE -- one last tall plunge.
	r = _chain_next(r, -22.0)
	r.kind = "CHUTE"
	r.prefill = Vector3(2.5, 0.55, 2.2)
	r.emit_vel = Vector3(0.9, -5.0, 0)
	_build_pool(r, 2.7, 2.5, 0.6, -7.15)
	_label(r.root, "FINAL CHUTE", Vector3(1.2, 1.2, 0), SECTION_COLORS["CHUTE"])
	_finish_reach(r, Vector3(-3.6, 3.2, 4.4), Vector3(1.8, -6.7, 0))

	# S13 BASIN -- the 0 m collection pool: wide, terminal, and the one tall
	# plunge of the course. The faucet height lands the pool floor on y = 0.
	var faucet_y := 0.7 + 6.55 + 6.0 # floor 0 -> water 0.7 -> faucet 13.25
	var boost := faucet_y - (r.outlet_pos.y - 5.55)
	r = _chain_next(r, 0.0, boost)
	r.kind = "BASIN"
	r.base_rate = 2600.0
	r.node_local = Vector3(2.0, -0.55, 0) # plunge from 6 m up, pool center
	r.prefill = Vector3(3.6, 0.65, 3.2)
	r.emit_vel = Vector3(0.5, -4.0, 0)
	r.domain = Vector3(12, 26, 8)
	_build_pool(r, 3.8, 3.6, 0.7, -6.55, 2.0) # extra-tall banks hold the splash
	_label(r.root, "COLLECTION BASIN - 0m", Vector3(1.4, 1.6, 0), SECTION_COLORS["BASIN"])
	_label(r.root, "STAGE 14/14", Vector3(2.6, -4.2, -1.0), Color(1, 1, 1, 0.6))
	_finish_reach(r, Vector3(-4.8, 4.0, -5.2), Vector3(1.8, -6.9, 0))

func _chain_next(prev: Reach, yaw_delta_deg: float, height_boost := 0.0) -> Reach:
	var dir := Vector3(cos(prev.exit_yaw), 0, -sin(prev.exit_yaw))
	var origin := prev.outlet_pos + dir * 1.1 + Vector3(0, -5.55 + height_boost, 0)
	var yaw := rad_to_deg(prev.exit_yaw) + yaw_delta_deg
	var reach := _new_reach(_reaches.size() + 1, "TBD", origin, yaw)
	reach.upstream = [prev]
	return reach

# A parallel branch: hooks onto the split terrace's outlet at a lateral offset.
func _branch_next(split: Reach, right: bool, yaw_delta_deg: float) -> Reach:
	var dir := Vector3(cos(split.exit_yaw), 0, -sin(split.exit_yaw))
	var side := dir.cross(Vector3.UP) * (0.9 if right else -0.9)
	var origin := split.outlet_pos + dir * 1.1 + side + Vector3(0, -5.55, 0)
	var yaw := rad_to_deg(split.exit_yaw) + yaw_delta_deg
	var reach := _new_reach(_reaches.size() + 1, "TBD", origin, yaw)
	reach.upstream = [split]
	return reach

# --------------------------------------------------------------- floaters

# Deterministic floaters across the regimes; offsets are terrace-local (y
# relative to the faucet) and each body starts just above its pool.
const FLOATER_TABLE := [
	# reach, kind, local offset, size, density
	[1, "buoy", Vector3(1.8, -6.6, 0.5), 0.3, 350.0],
	[2, "log", Vector3(2.0, -6.5, -0.3), 1.5, 500.0],
	[3, "crate", Vector3(2.2, -6.5, 0.4), 0.6, 550.0],
	[5, "sphere", Vector3(2.4, -6.5, -0.4), 0.32, 400.0],
	[6, "barrel", Vector3(2.6, -6.5, 0.6), 0.8, 450.0],
	[7, "crate", Vector3(2.2, -6.5, 0.0), 0.7, 1800.0],
	[8, "log", Vector3(2.0, -6.5, 0.3), 1.4, 500.0],
	[13, "buoy", Vector3(2.4, -6.5, -0.5), 0.34, 300.0],
	[13, "crate", Vector3(3.0, -6.5, 0.6), 0.65, 600.0],
]

func _spawn_floaters() -> void:
	for entry in FLOATER_TABLE:
		var reach: Reach = _reaches[entry[0]]
		var body := _make_floater(entry[1], entry[3], entry[4])
		body.position = entry[2] # terrace-local; parented under the terrace root
		reach.root.add_child(body)
		body.process_mode = Node.PROCESS_MODE_PAUSABLE
		_floaters.append(body)
		_floater_home[body] = body.transform
		_floater_reach[body] = entry[0]
		_floater_stranded[body] = -1.0
		reach.floaters.append(body)

func _make_floater(kind: String, size: float, density: float) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.can_sleep = false
	rb.continuous_cd = true
	rb.linear_damp = 0.05
	rb.angular_damp = 0.1
	var volume := 1.0
	match kind:
		"buoy":
			volume = 4.0 / 3.0 * PI * pow(size, 3.0)
			rb.mass = density * volume
			var sh := SphereShape3D.new()
			sh.radius = size
			_add_shape_mesh(rb, sh, _sphere_mesh(size), Color(0.95, 0.55, 0.15), 0.5, 0.0)
		"sphere":
			volume = 4.0 / 3.0 * PI * pow(size, 3.0)
			rb.mass = density * volume
			var sh := SphereShape3D.new()
			sh.radius = size
			_add_shape_mesh(rb, sh, _sphere_mesh(size), Color.from_hsv(0.55, 0.7, 0.9), 0.4, 0.0)
		"log", "barrel":
			var radius := size * 0.16 if kind == "log" else size * 0.42
			volume = PI * radius * radius * size
			rb.mass = density * volume
			var cap := CapsuleShape3D.new()
			cap.radius = radius
			cap.height = size
			var mesh := CapsuleMesh.new()
			mesh.radius = radius
			mesh.height = size
			var color := Color(0.55, 0.38, 0.2) if kind == "log" else Color(0.35, 0.5, 0.65)
			var rough := 0.9 if kind == "log" else 0.35
			var mi := _add_shape_mesh(rb, cap, mesh, color, rough, 0.0 if kind == "log" else 0.6)
			mi.rotation = Vector3(PI / 2, 0, 0) # lie along the flow
		"crate", "rock":
			var shrink := 0.7 if kind == "rock" else 1.0
			volume = pow(size * shrink, 3.0)
			rb.mass = density * volume
			var box := BoxShape3D.new()
			box.size = Vector3.ONE * size * shrink
			var mesh := BoxMesh.new()
			mesh.size = Vector3.ONE * size * shrink
			var color := Color(0.3, 0.29, 0.28) if kind == "rock" else Color(0.72, 0.55, 0.3)
			_add_shape_mesh(rb, box, mesh, color, 0.95 if kind == "rock" else 0.85, 0.0)
	rb.set_meta("volume", volume) # buoyancy probe size
	return rb

func _sphere_mesh(radius: float) -> SphereMesh:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	return sm

func _add_shape_mesh(rb: RigidBody3D, shape: Shape3D, mesh: Mesh, color: Color, rough: float, metal: float) -> MeshInstance3D:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = rough
	mat.metallic = metal
	mi.material_override = mat
	rb.add_child(mi)
	return mi

# ------------------------------------------------------------------- modes

func _apply_mode() -> void:
	var mode: String = MODES[_mode_idx]
	var obstacles_on := mode in ["FULL", "TURBULENT", "STRESS"]
	var split_on := mode in ["FULL", "SPLIT/MERGE", "STRESS"]
	for reach in _reaches:
		for body in reach.obstacle_bodies:
			body.visible = obstacles_on
			_set_shapes_disabled(body, not obstacles_on)
		_rebuild_colliders(reach)
	for reach in _reaches:
		# The channel-B branch is gated off in the single-channel modes; its
		# faucet closes and its probe stops feeding the merge.
		if _reaches.find(reach) == _gate_reach:
			reach.rate_scale = 0.0 if not split_on else 1.0
		else:
			reach.rate_scale = 2.2 if mode == "STRESS" else 1.0

func _set_shapes_disabled(body: Node, disabled: bool) -> void:
	for child in body.get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", disabled)

# The fluid node re-reads mpm_colliders every step, so list changes apply on
# the next tick. Paths are taken relative to the fluid node itself.
func _rebuild_colliders(reach: Reach) -> void:
	if not is_instance_valid(reach.fluid):
		return
	var mode: String = MODES[_mode_idx]
	var obstacles_on := mode in ["FULL", "TURBULENT", "STRESS"]
	var paths: Array[NodePath] = []
	for body in reach.static_bodies:
		paths.append(reach.fluid.get_path_to(body))
	if obstacles_on:
		for body in reach.obstacle_bodies:
			paths.append(reach.fluid.get_path_to(body))
	for floater in reach.floaters:
		if is_instance_valid(floater):
			paths.append(reach.fluid.get_path_to(floater))
	reach.fluid.mpm_colliders = paths

func _spawn_floater_burst() -> void:
	# Object-interaction stress: a wave of crates and buoys into the source
	# pool, the rock garden and the merge pool. Seeded, so bursts repeat.
	var spots := [[0, Vector3(0.4, -6.2, 0.0)], [3, Vector3(1.6, -6.2, 0.2)], [7, Vector3(1.4, -6.2, 0.0)]]
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260929
	for i in range(9):
		var spot: Array = spots[i % spots.size()]
		var reach: Reach = _reaches[spot[0]]
		var kind := "crate" if i % 3 != 0 else "buoy"
		var body := _make_floater(kind, 0.45 + 0.25 * (i % 3), 450.0 if kind == "crate" else 350.0)
		var local: Vector3 = spot[1] + Vector3(rng.randf_range(-0.4, 0.4), 0.35 * int(i / spots.size()), rng.randf_range(-0.4, 0.4))
		body.position = local
		reach.root.add_child(body)
		body.process_mode = Node.PROCESS_MODE_PAUSABLE
		_floaters.append(body)
		_floater_home[body] = body.transform
		_floater_reach[body] = spot[0]
		_floater_stranded[body] = -1.0
		reach.floaters.append(body)
		_rebuild_colliders(reach)

# ------------------------------------------------------------------- reset

func _reset(full_presets := false) -> void:
	for reach in _reaches:
		reach.filled_at = -1.0
		if _reaches.find(reach) == _gate_reach:
			reach.rate_scale = 0.0 if not (MODES[_mode_idx] in ["FULL", "SPLIT/MERGE", "STRESS"]) else 1.0
		else:
			reach.rate_scale = 2.2 if MODES[_mode_idx] == "STRESS" else 1.0
		if full_presets:
			_spawn_fluid(reach)
		elif is_instance_valid(reach.fluid):
			reach.fluid.clear() # next emit reconfigures; the pool refills by circulation
		for floater in reach.floaters:
			_reset_floater(floater)
	if full_presets:
		_apply_mode() # fresh fluids need their collider lists again
	_nan_total = 0
	_escapes = 0
	_scan_reach = 0
	_goto_anchor(-1)

func _reset_floater(body: RigidBody3D) -> void:
	if not is_instance_valid(body):
		return
	body.transform = _floater_home[body]
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	_floater_stranded[body] = -1.0

# ------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if _fly.handle_input(event):
		_tour = false
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				get_tree().quit()
			KEY_F:
				_hud_visible = not _hud_visible
				_hud.visible = _hud_visible
			KEY_P:
				_paused = not _paused
				get_tree().paused = _paused
			KEY_R:
				_reset()
			KEY_G:
				_spawn_floater_burst()
			KEY_C:
				_tour = not _tour
			KEY_TAB:
				_mode_idx = (_mode_idx + 1) % MODES.size()
				_apply_mode()
			KEY_BRACKETLEFT:
				_cycle_preset(-1)
			KEY_BRACKETRIGHT:
				_cycle_preset(1)
			KEY_1: _goto_anchor(-1)
			KEY_2: _goto_anchor(1)
			KEY_3: _goto_anchor(3)
			KEY_4: _goto_anchor(5)
			KEY_5: _goto_anchor(8)
			KEY_6: _goto_anchor(9)
			KEY_7: _goto_anchor(13)

func _cycle_preset(dir: int) -> void:
	var idx := PRESET_ORDER.find(_preset)
	_preset = PRESET_ORDER[(idx + dir + PRESET_ORDER.size()) % PRESET_ORDER.size()]
	_reset(true)

func _goto_anchor(reach_idx: int) -> void:
	_tour = false
	if reach_idx < 0 or reach_idx >= _reaches.size():
		_cam.position = Vector3(60, 55, 62)
		_cam.look_at(Vector3(14, 42, 14))
	else:
		var reach := _reaches[reach_idx]
		_cam.position = reach.anchor_pos
		_cam.look_at(reach.anchor_look)
	_sync_fly()

func _sync_fly() -> void:
	_fly.yaw = _cam.rotation.y
	_fly.pitch = _cam.rotation.x

# ------------------------------------------------------------------- camera

func _tour_step(delta: float) -> void:
	# Glide down the course: ease toward each terrace anchor in turn.
	var target := _reaches[_tour_target % _reaches.size()]
	_cam.position = _cam.position.lerp(target.anchor_pos, clampf(delta * 0.8, 0.0, 1.0))
	var to_look := (target.anchor_look - _cam.position).normalized()
	if to_look.length_squared() > 0.001:
		var current := -_cam.global_transform.basis.z
		var blended := current.slerp(to_look, clampf(delta * 2.0, 0.0, 1.0)).normalized()
		_cam.look_at(_cam.position + blended, Vector3.UP)
	_sync_fly()
	if _cam.position.distance_to(target.anchor_pos) < 6.0:
		_tour_target = (_tour_target + 1) % _reaches.size()

# -------------------------------------------------------------- simulation

func _physics_process(delta: float) -> void:
	if _paused or get_tree().paused:
		return
	_t += delta

	# Discharge coupling: each pool's outlet probe modulates the next faucet,
	# so upstream surges propagate down the course instead of every terrace
	# running at a blind fixed rate.
	_couple_accum += delta
	if _couple_accum >= 0.2:
		var dt := _couple_accum
		_couple_accum = 0.0
		var preset_scale: float = PRESETS[_preset].rate / PRESETS["MEDIUM"].rate
		var mode_scale := 2.2 if MODES[_mode_idx] == "STRESS" else 1.0
		for reach in _reaches:
			if not is_instance_valid(reach.fluid):
				continue
			var fill := clampf(reach.fluid.get_submersion(reach.outlet_probe), 0.0, 1.0)
			if fill >= 0.5 and reach.filled_at < 0.0:
				reach.filled_at = _t
			var target := 1.0
			var n := 0
			for up in reach.upstream:
				if is_instance_valid(up.fluid):
					target += clampf(up.fluid.get_submersion(up.outlet_probe), 0.0, 1.0)
					n += 1
			if n > 0:
				target = clampf(0.15 + (target - 1.0) / n * 1.05, 0.15, 1.0)
			if _reaches.find(reach) == _gate_reach and not (MODES[_mode_idx] in ["FULL", "SPLIT/MERGE", "STRESS"]):
				reach.rate_scale = 0.0 # channel B gated off
				reach.fluid.emission_rate = 0.0
			else:
				reach.rate_scale = lerpf(reach.rate_scale, target, clampf(dt * 1.6, 0.0, 1.0))
				reach.fluid.emission_rate = reach.base_rate * reach.rate_scale * mode_scale * preset_scale

	# Script-side buoyancy + drag, per floater, from its pool's fluid state --
	# the same approximation the faucet demo uses (the MPM couple pass nudges
	# coupled bodies but does not float them by density).
	for body in _floaters:
		if not is_instance_valid(body):
			continue
		var reach := _reaches[_floater_reach.get(body, 0)]
		if not is_instance_valid(reach.fluid):
			continue
		var vol: float = body.get_meta("volume", 1.0)
		var side := pow(maxf(vol, 0.001), 1.0 / 3.0)
		var aabb := AABB(body.global_position - Vector3.ONE * side * 0.5, Vector3.ONE * side)
		var submerged := clampf(reach.fluid.get_submersion(aabb), 0.0, 1.0)
		body.linear_damp = lerpf(0.05, 2.5, submerged)
		if submerged > 0.0:
			var buoy: float = WATER_DENSITY * submerged * vol * 9.8
			body.apply_central_force(Vector3.UP * minf(buoy, body.mass * 9.8 * 1.35))

	# Strayed-body recovery: anything below the site for 15 s goes back home.
	for body in _floaters:
		if not is_instance_valid(body):
			continue
		if body.global_position.y < -6.0:
			var since: float = _floater_stranded.get(body, -1.0)
			if since < 0.0:
				_floater_stranded[body] = _t
			elif _t - since > 15.0:
				_reset_floater(body)
		else:
			_floater_stranded[body] = -1.0

func _process(delta: float) -> void:
	if _tour:
		_tour_step(delta)
	_bench_frame += 1
	_scan_accum += delta
	if _scan_accum >= 1.5:
		_scan_accum = 0.0
		_validate_next_reach()
	_hud_accum += delta
	if _hud_accum >= 0.25:
		_hud_accum = 0.0
		_update_sim_lod()
		_update_hud()
	if _bench and _bench_frame >= _bench_frames:
		_finish_bench()

# Broad sanity instrumentation -- one terrace per 1.5 s so the full GPU
# readback stays off the hot path. NaNs and out-of-domain particles should both
# stay at zero (the MPM clamps to its domain box); per-terrace fill times give
# the 100 m -> 0 m transit; floater displacement proves the water does work.
func _validate_next_reach() -> void:
	if _reaches.is_empty():
		return
	var reach := _reaches[_scan_reach % _reaches.size()]
	_scan_reach += 1
	if not is_instance_valid(reach.fluid):
		return
	var pts := reach.fluid.get_particle_positions()
	if pts.is_empty():
		return
	var half := reach.domain * 0.5 + Vector3.ONE * 0.5
	var center := reach.fluid.global_position # the domain centers on the node
	for p in pts:
		if p.x != p.x or p.y != p.y or p.z != p.z:
			_nan_total += 1
			continue
		var rel := (p - center).abs()
		if rel.x > half.x or rel.y > half.y or rel.z > half.z:
			_escapes += 1
	for body in _floaters:
		if is_instance_valid(body):
			var home: Transform3D = _floater_home.get(body, Transform3D.IDENTITY)
			if body.global_position.distance_to(home.origin) > 2.0:
				_obj_moved = true
			if body.linear_velocity.length() > 200.0:
				_nan_total += 1 # velocity blow-up counts against stability

func _fluid_totals() -> Array:
	var totals := [0, 0, 0.0, 0] # particles, foam, step ms, active reaches
	for reach in _reaches:
		if is_instance_valid(reach.fluid):
			totals[0] += reach.fluid.get_live_particle_count()
			totals[1] += reach.fluid.get_live_foam_count()
			totals[2] += reach.fluid.get_mpm_step_msec()
			totals[3] += 1
	return totals

func _finish_bench() -> void:
	var totals := _fluid_totals()
	var fps := maxf(Engine.get_frames_per_second(), 1.0)
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	print("[river] benchA frames=%d fps=%.1f frame_ms=%.2f mpm_step_ms=%.2f proc=%.1f phys=%.1f" % [
			_bench_frame, fps, 1000.0 / fps, totals[2], proc_ms, phys_ms])
	print("[river] benchB particles=%d foam=%d sim=%d/%d preset=%s mode=%s nan=%d escapes=%d" % [
			totals[0], totals[1], _sim_active, _reaches.size(), _preset, MODES[_mode_idx], _nan_total, _escapes])
	get_tree().quit()

func _section_for_camera() -> String:
	if _reaches.is_empty():
		return "-"
	var best := 0
	var best_d := 1e18
	for i in range(_reaches.size()):
		var d := _cam.position.distance_squared_to(_reaches[i].root.global_transform.origin)
		if d < best_d:
			best_d = d
			best = i
	return _reaches[best].kind

# Simulation LOD: every MPM fluid syncs its own GPU queue once per physics
# tick (~13 ms on the test GPU), so simulating all fourteen stages at once
# costs more in driver sync than in solver time. Stages near the camera run at
# full rate; the rest hold their prefilled pools frozen and resume -- with the
# measured discharge coupling -- as the camera reaches them. lod=off removes
# the culling for the all-on stress number.
func _update_sim_lod() -> void:
	if _lod_off:
		return
	var dists := {}
	for i in range(_reaches.size()):
		if is_instance_valid(_reaches[i].fluid) and i < _active_stages:
			dists[i] = _cam.position.distance_squared_to(_reaches[i].fluid.global_position)
	var order := dists.keys()
	order.sort_custom(func(a, b): return dists[a] < dists[b])
	var keep := {}
	for i in range(mini(3, order.size())): # the nearest stages always run
		keep[order[i]] = true
	for i in order: # plus anything inside the radius
		if dists[i] < _sim_radius * _sim_radius:
			keep[i] = true
	_sim_active = keep.size()
	for i in range(_reaches.size()):
		if is_instance_valid(_reaches[i].fluid) and i < _active_stages:
			_reaches[i].fluid.process_mode = Node.PROCESS_MODE_PAUSABLE if keep.has(i) else Node.PROCESS_MODE_DISABLED

func _update_hud() -> void:
	if not _hud_visible:
		return
	var totals := _fluid_totals()
	var fps := Engine.get_frames_per_second()
	var filled := 0
	var last_fill := 0.0
	for reach in _reaches:
		if reach.filled_at >= 0.0:
			filled += 1
			last_fill = maxf(last_fill, reach.filled_at)
	var transit := ""
	if filled == _reaches.size():
		transit = "  transit 100m->0m: %ds" % int(last_fill)
	var state := "PAUSED" if _paused else ("TOUR" if _tour else "FLY")
	var stability := "STABLE" if _nan_total == 0 and _escapes == 0 else "UNSTABLE (nan=%d escapes=%d)" % [_nan_total, _escapes]
	_hud.text = "\n".join([
		"PHYSX GPU RIVER TEST - terraced MPM cascade, %d stages (%d simulating)" % [_reaches.size(), _sim_active],
		"engine=%s  particles=%d  foam=%d  emit=%.0f/s  mpm step=%.1f ms" % [
			ProjectSettings.get_setting("physics/3d/physics_engine", "?"), totals[0], totals[1], _emit_rate_total(), totals[2]],
		"fps=%d (%.1f ms)  preset=%s  mode=%s  %s" % [fps, 1000.0 / maxf(fps, 1), _preset, MODES[_mode_idx], state],
		"flow: %d/%d outlets fed%s  objects moved=%s  %s" % [filled, _reaches.size(), transit, "yes" if _obj_moved else "no", stability],
		"section: %s" % _section_for_camera(),
		"WASD+RMB fly  1-7 sections  C tour  TAB mode  [ ] preset  G objects  P pause  R reset  F hud  ESC",
	])

func _emit_rate_total() -> float:
	var rate := 0.0
	for reach in _reaches:
		if is_instance_valid(reach.fluid):
			rate += reach.fluid.emission_rate
	return rate
