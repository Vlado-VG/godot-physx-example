extends Node3D

# GPU river-flow stress test for the PhysX backend (PhysXParticleFluid3D).
#
# A river is born at a single source pool at ~100 m and flows down a graded
# hillside to the collection basin at 0 m: the upper course is steep and
# waterfall-fed (cascades between plunge pockets), then the slopes ease into
# long fine-grained channel reaches -- laminar run, boulder field, the heated
# checkpoint, a split around an island into two contrasting branches, a merge
# confluence, rapids steps, a constriction, a foam bed and slow drift runs.
# The checkpoints exist to put obstacles into the flow, not to collect water:
# the reaches are shallow channels, and the only true basin is at the bottom.
# Rigid bodies (spheres, logs, crates, a dense rock) travel the course with
# the river or get stuck, depending on their density. Nothing is faked with
# shader effects.
#
# Why the course is staged: the foam-capable solver is the MPM compute
# backend, whose simulation is confined to mpm_domain_size (a box centered on
# the node) with the grid capped at 96 cells along X -- and measured on this
# build, grid cells above ~0.08 m either leak particles through geometry or
# blow up their momentum accumulator, while at the working 0.07 m cells a
# closed water body spreads and stalls instead of flowing. So the river is a
# chain of short reaches at the proven scale. Water is injected only at the
# source in play terms: each reach's faucet sits hidden on the previous
# spillway lip and emits exactly the discharge the previous reach's outlet
# probe measures, so a surge upstream propagates down the whole course. Flow
# rate crosses each lip; the falling curtain masks the transfer.
#
# Simulation LOD: every MPM fluid syncs its own GPU queue once per physics
# tick (~13 ms each on the test GPU), so stages near the camera run at full
# rate and the rest hold their water frozen, resuming -- with the discharge
# coupling -- as the camera reaches them. lod=off removes the culling for the
# all-on stress number, stages=N caps the simulating count.
#
#   WASD + RMB   fly camera          1..7  section cameras   C  tour the river
#   TAB          cycle test mode     [ ]   quality preset    G  object burst
#   P            pause               R     reset             F  toggle HUD
#   ESC          quit
#
# Screenshot / benchmark knobs (need a window; the MPM solver needs a
# RenderingDevice):
#   godot --path . demo/gpu/physx_river.tscn -- bench frames=600 preset=HIGH lod=off
#   godot --path . demo/gpu/physx_river.tscn -- shots=shots_river

const WATER_DENSITY := 1000.0

# Per-reach fluid budget presets. The particle size is fixed at the only
# measured scale where water flows and does not leak (0.035 m particles on
# 0.07 m cells); presets scale the water volume and through-flow instead.
const PRESETS := {
	"LOW": {
		"particles": 9000, "foam": 2500, "rate": 2200.0,
		"surface": false, "substeps": 4,
	},
	"MEDIUM": {
		"particles": 17000, "foam": 5000, "rate": 4500.0,
		"surface": false, "substeps": 5,
	},
	"HIGH": {
		"particles": 26000, "foam": 8000, "rate": 7000.0,
		"surface": true, "substeps": 5,
	},
	"STRESS": {
		"particles": 36000, "foam": 13000, "rate": 11000.0,
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
	"HEATED": Color(1.0, 0.45, 0.2),
	"SPLIT": Color(0.8, 0.65, 0.95),
	"CHANNEL A": Color(0.55, 0.9, 0.7),
	"CHANNEL B": Color(0.95, 0.55, 0.45),
	"MERGE": Color(0.95, 0.6, 0.75),
	"RAPIDS": Color(1.0, 0.62, 0.35),
	"RIVER": Color(0.6, 0.85, 0.95),
	"BASIN": Color(0.55, 0.85, 0.85),
}

class Reach:
	var kind: String
	var stage := 0
	var root: Node3D # yawed frame; faucet at local origin
	var fluid: PhysXParticleFluid3D
	var domain := Vector3.ZERO # mpm_domain_size
	var prefill := Vector3.ZERO # spawn_region_size (channels prefill; plunge fills by jet)
	var outlet_probe := AABB() # world-space fill probe at the reach's outlet
	var lip_crest := Vector3.ZERO # world; the spillway the water pours over
	var exit_yaw := 0.0 # downstream heading leaving this reach
	var base_rate := 4500.0
	var emit_vel := Vector3(1.2, -2.6, 0) # local (reach frame)
	var static_bodies: Array[Node] = [] # channel geometry, always coupled
	var obstacle_bodies: Array[Node] = [] # mode-toggled colliders
	var floaters: Array[RigidBody3D] = [] # coupled + buoyancy-simulated
	var upstream: Array[Reach] = [] # stages whose discharge feeds this faucet
	var anchor_pos := Vector3.ZERO # section-camera vantage
	var anchor_look := Vector3.ZERO
	var filled_at := -1.0 # sim seconds until the outlet probe first read >= 0.35
	var rate_scale := 1.0 # live emission multiplier (mode / coupling)

	func _init(p_kind: String) -> void:
		kind = p_kind

var _reaches: Array[Reach] = []
var _floaters: Array[RigidBody3D] = []
var _floater_home := {} # body -> initial transform (reach-local)
var _floater_reach := {} # body -> reach index
var _floater_stranded := {} # body -> sim seconds adrift below the course
var _gate_reach := -1 # channel-B stage index (mode-toggled faucet)

# The heated checkpoint: hot plates in the channel, NVIDIA Flow steam gated on
# measured water contact, and an evaporation loss on the downstream discharge.
var _flow_sim: Node3D
var _flow_emitters: Array[Node3D] = []
var _heat_probe := AABB()
var _steam_level := 0.0
var _steam_available := -1 # -1 unknown, 0 unavailable, 1 running
var _evap_loss := 0.0
var _heat_reach := -1

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
var _scan_reach := 0
var _assign_accum := 0.0
var _nan_total := 0
var _escapes := 0
var _obj_moved := false
var _bench := false
var _bench_frames := 600
var _bench_frame := 0
var _active_stages := 999
var _lod_off := false
var _sim_radius := 16.0
var _sim_active := 0
var _shots_dir := ""
var _shot_idx := 0

# chain-in-progress state consumed by the next stage builder
var _pending_origin := Vector3.ZERO
var _pending_yaw := 0.0
var _pending_upstream: Array[Reach] = []

@onready var _mat_bed: StandardMaterial3D = _make_mat(Color(0.36, 0.34, 0.31), 1.0)
@onready var _mat_bank: StandardMaterial3D = _make_mat(Color(0.44, 0.39, 0.33), 0.95)
@onready var _mat_rock: StandardMaterial3D = _make_mat(Color(0.32, 0.31, 0.3), 0.9)
@onready var _mat_wall: StandardMaterial3D = _make_mat(Color(0.5, 0.48, 0.45), 0.85)
@onready var _mat_water: StandardMaterial3D = _make_water_mat()

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
		elif arg.begins_with("shots="):
			_shots_dir = arg.substr(6)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var pm := ProceduralSkyMaterial.new()
	pm.sky_horizon_color = Color(0.62, 0.67, 0.74)
	pm.ground_horizon_color = Color(0.62, 0.67, 0.74)
	pm.ground_bottom_color = Color(0.42, 0.47, 0.55)
	sky.sky_material = pm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	# light overcast for mood; volumetric fog ON so the Flow steam's FogVolume
	# actually draws (FogVolumes are skipped while volumetric fog is disabled)
	e.fog_enabled = true
	e.fog_density = 0.0006
	e.fog_light_color = Color(0.55, 0.6, 0.68)
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = 0.04
	e.volumetric_fog_albedo = Color(0.9, 0.9, 0.9)
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
	_fly = FlyCamera.new(_cam, 16.0)

	_build_river()
	_spawn_floaters()
	_apply_mode() # builds the per-reach collider lists for the FULL mode
	for i in range(_active_stages, _reaches.size()):
		if is_instance_valid(_reaches[i].fluid):
			_reaches[i].fluid.process_mode = Node.PROCESS_MODE_DISABLED
	var view := _overview_view()
	_cam.position = view[0]
	_cam.look_at(view[1])
	_fly.yaw = _cam.rotation.y
	_fly.pitch = _cam.rotation.x

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
	m.albedo_color = Color(0.12, 0.4, 0.62, 0.6)
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
	sb.position = pos + Vector3(0, radius * 0.4, 0)
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
	l.font_size = 40
	l.pixel_size = 0.05
	l.outline_size = 12
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.9)
	parent.add_child(l)

# ------------------------------------------------------------------ reaches
# Two reach archetypes carry the whole course. Both work in the reach root's
# yawed frame with the faucet at the local origin -- the node IS the MPM
# domain center, and it sits on the previous spillway lip so the water appears
# to pour over it.
#   plunge: the jet free-falls `fall` meters into a pocket; the pocket's
#           downstream lip is the next reach's pour-over. The waterfall in
#           front of the pocket is just air between two stage domains.
#   channel:a sloped run of `length` meters at `slope_deg` from the head to
#           the outlet lip; fine water flows down it under through-flow.

func _new_reach(kind: String, origin: Vector3, yaw_deg: float, domain: Vector3) -> Reach:
	var reach := Reach.new(kind)
	reach.stage = _reaches.size() + 1
	reach.root = Node3D.new()
	reach.root.position = origin
	reach.root.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
	add_child(reach.root)
	reach.domain = domain
	reach.upstream = _pending_upstream
	_reaches.append(reach)
	return reach

# Outlet lip: crest 0.25 over the reach's downstream water line + the probe.
func _outlet(reach: Reach, x: float, water_y: float, width: float) -> void:
	reach.static_bodies.append(_slab(reach.root, Vector3(x, water_y - 0.35, 0), Vector3(0.4, 1.3, width + 0.6), _mat_wall))
	var probe_local := AABB(Vector3(x - 0.85, water_y - 0.26, -width * 0.32), Vector3(0.6, 0.22, width * 0.64))
	var xf := reach.root.global_transform
	reach.outlet_probe = AABB(xf * probe_local.position, probe_local.size)
	reach.lip_crest = xf * Vector3(x, water_y + 0.25, 0)
	var exit_dir := xf.basis * Vector3(1, 0, 0)
	reach.exit_yaw = atan2(-exit_dir.z, exit_dir.x)

func _finish_reach(reach: Reach, wide := false) -> void:
	var xf := reach.root.global_transform
	var off := Vector3(-7.0, 4.5, 10.0) if wide else Vector3(-4.0, 3.5, 8.5)
	reach.anchor_pos = xf * off
	reach.anchor_look = xf * Vector3(1.2, -2.2, 0)
	_spawn_fluid(reach)

func _spawn_fluid(reach: Reach) -> void:
	var p: Dictionary = PRESETS[_preset]
	if is_instance_valid(reach.fluid):
		reach.fluid.queue_free()
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_MPM # the foam-capable path, on any GPU
	f.spawn_on_ready = true
	f.particle_count = p.particles
	f.particle_size = 0.035 # the only measured scale that flows without leaking
	f.viscosity = 0.02
	f.cohesion = 0.02
	f.surface_tension = 0.006
	f.spawn_region_size = reach.prefill
	f.mpm_domain_size = reach.domain
	f.mpm_substeps = p.substeps
	f.emitting = true
	f.emission_rate = reach.base_rate * (p.rate / PRESETS["MEDIUM"].rate)
	f.emission_radius = 0.09
	f.emission_velocity = reach.emit_vel
	f.surface_mesh = p.surface # GPU marching-tetrahedra water surface
	f.foam_enabled = true # MPM diffuse layer: foam/spray/bubbles where agitated
	f.foam_particle_count = p.foam
	f.foam_lifetime = 1.8
	f.foam_threshold = 170.0 # MPM scale; lower = foams more readily
	f.foam_buoyancy = 0.9
	f.material_override = _mat_water
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	f.process_mode = Node.PROCESS_MODE_PAUSABLE
	reach.root.add_child(f)
	f.position = Vector3.ZERO # faucet = domain center, on the spillway lip
	reach.fluid = f

# A sloped floor with banks between two floor-top points (reach frame).
func _seg_run(reach: Reach, from: Vector3, to: Vector3, width: float, bank_h := 0.55) -> void:
	var seg := Node3D.new()
	var dir := to - from
	var flat := Vector2(dir.x, dir.z).length()
	seg.position = (from + to) * 0.5
	seg.rotation = Vector3(0, atan2(-dir.z, dir.x), atan2(dir.y, flat))
	reach.root.add_child(seg)
	var t := 0.35
	reach.static_bodies.append(_slab(seg, Vector3(0, -t * 0.5, 0), Vector3(dir.length() + 0.4, t, width), _mat_bed))
	for side in [-1.0, 1.0]:
		reach.static_bodies.append(_slab(seg, Vector3(0, bank_h * 0.5 - 0.1, side * (width * 0.5 + 0.18)),
				Vector3(dir.length() + 0.8, bank_h + t, 0.36), _mat_bank))

# PLUNGE reach: the faucet jet free-falls `fall` m into a pocket; the pocket's
# downstream lip is the next pour-over. Pocket center drifts downstream with
# the jet's arc. Falls are free -- they happen in the air between domains.
func _plunge_stage(kind: String, fall: float, width: float, label: String,
		pocket_len := 1.8, depth := 0.38, bank_extra := 0.0) -> Reach:
	var r := _new_reach(kind, _pending_origin, _pending_yaw, Vector3(6.7, 16, 5))
	r.prefill = Vector3.ZERO # plunge pockets fill from their own waterfall
	var water := -(fall + 0.3) # pocket water line below the faucet
	var px := clampf(0.85 + fall * 0.11, 0.9, 1.55) # jet-arc landing drift
	var bank_h := 0.75 + bank_extra
	var t := 0.4
	var floor_len := pocket_len + 1.2
	r.static_bodies.append(_slab(r.root, Vector3(px, water - depth - t * 0.5, 0), Vector3(floor_len, t, width + 0.8), _mat_bed))
	for side in [-1.0, 1.0]:
		r.static_bodies.append(_slab(r.root, Vector3(px, water + bank_h * 0.5, side * (width * 0.5 + 0.22)),
				Vector3(floor_len + 0.6, bank_h + t, 0.4), _mat_bank))
	r.static_bodies.append(_slab(r.root, Vector3(px - floor_len * 0.5 - 0.22, water + bank_h * 0.5, 0),
			Vector3(0.4, bank_h + t, width + 0.8), _mat_bank))
	_outlet(r, px + floor_len * 0.5 + 0.1, water, width)
	if label != "":
		_label(r.root, label, Vector3(px, 1.0, 0), SECTION_COLORS.get(kind, Color.WHITE))
	return r

# CHANNEL reach: a sloped run from the head (just past the lip) down to the
# outlet lip. head_drop is the waterfall from the previous lip to the water.
func _channel_stage(kind: String, head_drop: float, length: float, slope_deg: float,
		width: float, label: String, bank_h := 0.55) -> Reach:
	var r := _new_reach(kind, _pending_origin, _pending_yaw, Vector3(6.7, 15, 5))
	r.prefill = Vector3(length * 0.7, 0.28, width * 0.65) # the run starts wet
	var head_water := -(head_drop + 0.28)
	var drop := length * tan(deg_to_rad(slope_deg))
	_seg_run(r, Vector3(0.2, head_water, 0), Vector3(0.2 + length, head_water - drop, 0), width, bank_h)
	_outlet(r, 0.2 + length + 0.2, head_water - drop, width)
	if label != "":
		_label(r.root, label, Vector3(length * 0.4, 0.8, 0), SECTION_COLORS.get(kind, Color.WHITE))
	return r

# The chain: hook the next faucet onto the previous spillway lip.
func _chain(prev: Reach, yaw_delta_deg: float) -> void:
	var dir := Vector3(cos(prev.exit_yaw), 0, -sin(prev.exit_yaw))
	_pending_origin = prev.lip_crest + dir * 0.12 + Vector3(0, 0.15, 0)
	_pending_yaw = rad_to_deg(prev.exit_yaw) + yaw_delta_deg
	_pending_upstream = [prev]

func _branch(split: Reach, right: bool, yaw_delta_deg: float) -> void:
	var dir := Vector3(cos(split.exit_yaw), 0, -sin(split.exit_yaw))
	var side := dir.cross(Vector3.UP) * (0.5 if right else -0.5)
	_pending_origin = split.lip_crest + dir * 0.12 + side + Vector3(0, 0.15, 0)
	_pending_yaw = rad_to_deg(split.exit_yaw) + yaw_delta_deg
	_pending_upstream = [split]

# ------------------------------------------------------------------ course
# Graded profile: steep waterfall-fed upper course, then progressively
# flatter fine-water reaches, ending in the one collecting basin at 0 m.
func _build_river() -> void:
	var origin := Vector3(0, 100, 0)
	_pending_origin = origin
	_pending_yaw = 0.0
	_pending_upstream = []

	# S1 SOURCE -- the only visible pour: a small header pool under the faucet.
	var r := _plunge_stage("SOURCE", 1.6, 1.5, "SOURCE - 100m", 1.6, 0.45, 0.3)
	r.base_rate = 5200.0
	r.emit_vel = Vector3(0.6, -3.2, 0)
	_finish_reach(r)

	# S2 LAMINAR -- after a tall fall, a long smooth 24 deg run.
	_chain(r, 10.0)
	r = _channel_stage("LAMINAR", 6.0, 2.8, 24.0, 1.1, "LAMINAR FLOW")
	_finish_reach(r)

	# S3 TURN -- plunge pool in a tight bend.
	_chain(r, 30.0)
	r = _plunge_stage("TURN", 5.0, 1.4, "TURN / SWIRL", 1.7, 0.4, 0.15)
	_finish_reach(r)

	# S4 BOULDER FIELD -- steep channel strewn with rocks.
	_chain(r, -16.0)
	r = _channel_stage("TURBULENT", 4.5, 2.8, 32.0, 1.2, "TURBULENCE / OBSTACLES")
	_rock(r.root, Vector3(1.0, -1.72, -0.2), 0.11, r)
	_rock(r.root, Vector3(1.5, -2.0, 0.22), 0.08, r)
	_rock(r.root, Vector3(2.0, -2.3, -0.08), 0.12, r)
	_finish_reach(r)

	# S5 CASCADE STEPS -- the marble-run staircase.
	_chain(r, 12.0)
	r = _channel_stage("RAPIDS", 4.0, 2.8, 38.0, 1.2, "CASCADE STEPS")
	for i in range(3):
		r.static_bodies.append(_slab(r.root, Vector3(0.7 + i * 0.68, -0.48 - i * 0.4, 0), Vector3(0.45, 0.16, 1.1), _mat_bed))
	_finish_reach(r)

	# S6 HEATED CHECKPOINT -- hot plates, Flow steam, evaporation loss.
	_chain(r, -12.0)
	r = _channel_stage("HEATED", 3.5, 2.8, 15.0, 1.2, "HEATED CHECKPOINT / STEAM")
	_build_heat(r)
	_finish_reach(r)

	# S7 SPLIT -- the channel divides around a wedge island.
	_chain(r, 12.0)
	r = _channel_stage("SPLIT", 3.0, 2.8, 16.0, 1.7, "FLOW SPLIT")
	r.static_bodies.append(_slab(r.root, Vector3(1.4, -0.78, 0), Vector3(1.2, 0.55, 0.22), _mat_wall, Vector3(0, 0, 0.1)))
	_finish_reach(r)

	# S8A / S8B -- the two branches in parallel.
	_branch(r, false, 14.0)
	var a := _channel_stage("CHANNEL A", 2.5, 2.6, 13.0, 1.0, "CHANNEL A - LOW TURBULENCE")
	_branch(r, true, -14.0)
	var b := _channel_stage("CHANNEL B", 2.5, 2.6, 19.0, 0.9, "CHANNEL B - HIGH TURBULENCE")
	_rock(b.root, Vector3(1.1, -0.95, -0.12), 0.08, b)
	b.static_bodies.append(_slab(b.root, Vector3(1.6, -0.9, 0.28), Vector3(0.7, 0.5, 0.18), _mat_wall))
	_finish_reach(a)
	_finish_reach(b)
	_gate_reach = _reaches.find(b)

	# S9 MERGE -- both branches feed one confluence pocket.
	_chain(a, 0.0)
	_pending_upstream = [a, b]
	r = _plunge_stage("MERGE", 3.5, 1.6, "FLOW MERGE / TURBULENCE", 1.7, 0.42, 0.15)
	r.static_bodies.append(_slab(r.root, Vector3(1.5, -3.15, -0.4), Vector3(0.6, 0.4, 0.22), _mat_wall, Vector3(0, 0, -0.28)))
	r.static_bodies.append(_slab(r.root, Vector3(1.5, -3.15, 0.4), Vector3(0.6, 0.4, 0.22), _mat_wall, Vector3(0, 0, 0.28)))
	_finish_reach(r)

	# S10 RAPIDS -- one last steep staircase before the valley opens up.
	_chain(r, -12.0)
	r = _channel_stage("RAPIDS", 4.5, 2.8, 36.0, 1.3, "RAPIDS / FOAM")
	for i in range(3):
		r.static_bodies.append(_slab(r.root, Vector3(0.7 + i * 0.68, -0.5 - i * 0.38, 0), Vector3(0.45, 0.16, 1.15), _mat_bed))
	_finish_reach(r)

	# S11 CONSTRICTION -- walls pinch the stream to half width.
	_chain(r, 12.0)
	r = _channel_stage("TURBULENT", 3.0, 2.8, 13.0, 1.3, "CONSTRICTION")
	for side in [-1.0, 1.0]:
		r.static_bodies.append(_slab(r.root, Vector3(1.4, -0.85, side * 0.38), Vector3(0.8, 0.55, 0.32), _mat_wall))
	_finish_reach(r)

	# S12 FOAM BED -- a shallow pebble-strewn drift.
	_chain(r, -10.0)
	r = _channel_stage("RIVER", 2.6, 2.8, 10.0, 1.4, "FOAM BED")
	for i in range(6):
		_rock(r.root, Vector3(0.6 + i * 0.36, -0.58 - i * 0.05, (0.28 if i % 2 == 0 else -0.28)), 0.05 + 0.01 * (i % 3), r)
	_finish_reach(r)

	# S13 SLOW RIVER -- long flat drift where floaters ride the stream.
	_chain(r, 10.0)
	r = _channel_stage("RIVER", 2.2, 2.9, 8.0, 1.5, "SLOW RIVER - DRIFT")
	_finish_reach(r)

	# S14 BASIN -- the one true basin; its fall is computed to land the floor
	# on world y = 0 so the whole course drains into it.
	_chain(r, -8.0)
	var basin_fall := maxf(_pending_origin.y - 1.0, 2.0)
	r = _plunge_stage("BASIN", basin_fall, 3.0, "COLLECTION BASIN - 0m", 3.2, 0.9, 1.2)
	r.base_rate = 5200.0
	r.emit_vel = Vector3(0.6, -3.0, 0)
	_finish_reach(r, true)

# ------------------------------------------------------------------- heat

# The heated checkpoint: emissive plates across the channel floor, a hot
# light, and a NVIDIA Flow smoke simulation standing by above them. The steam
# emitters are gated every coupling tick on the measured water contact with
# the plates, so the plume is driven by the fluid, not by the clock.
func _build_heat(reach: Reach) -> void:
	var mat_hot := StandardMaterial3D.new()
	mat_hot.albedo_color = Color(0.25, 0.08, 0.03)
	mat_hot.emission_enabled = true
	mat_hot.emission = Color(1.0, 0.35, 0.08)
	mat_hot.emission_energy_multiplier = 2.6
	for i in range(3):
		reach.static_bodies.append(_slab(reach.root, Vector3(0.85 + i * 0.7, -0.42 - i * 0.13, 0.0),
				Vector3(0.55, 0.09, 1.0), mat_hot))
	var light := OmniLight3D.new()
	light.position = Vector3(1.4, 0.6, 0.0)
	light.light_color = Color(1.0, 0.45, 0.15)
	light.light_energy = 2.2
	light.omni_range = 5.0
	reach.root.add_child(light)

	_heat_probe = AABB(reach.root.global_transform * Vector3(0.6, -0.55, -0.45), Vector3(2.0, 0.45, 0.9))
	_heat_reach = _reaches.find(reach)

	if not ClassDB.class_exists("PhysXFlowSimulation3D"):
		_steam_available = 0
		return
	_flow_sim = ClassDB.instantiate("PhysXFlowSimulation3D")
	reach.root.add_child(_flow_sim)
	_flow_sim.position = Vector3(1.4, 0.2, 0.0)
	_flow_sim.process_mode = Node.PROCESS_MODE_PAUSABLE
	_flow_sim.set("max_blocks", 1024)
	_flow_sim.set("cell_size", 0.35)
	_flow_sim.set("combustion_enabled", false) # pure steam: no fuel, no combustion
	_flow_sim.set("buoyancy_per_temp", 600.0) # 0.9 temp must beat gravity 100 and rise
	_flow_sim.set("cooling_rate", 0.25)
	_flow_sim.set("fog_density", 30.0)
	for side in [-1.0, 1.0]:
		var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
		reach.root.add_child(e)
		e.position = Vector3(1.4, -0.3, side * 0.32)
		e.set("shape", 1) # box
		e.set("size", Vector3(2.4, 0.5, 0.8))
		e.set("velocity", Vector3(0, 6.0, 0))
		e.set("smoke", 0.0) # gated on contact; scales with the measured intensity
		e.set("temperature", 0.9)
		e.set("fuel", 0.0)
		_flow_emitters.append(e)
	var paths: Array[NodePath] = []
	for e in _flow_emitters:
		paths.append(_flow_sim.get_path_to(e))
	_flow_sim.set("emitters", paths)

# --------------------------------------------------------------- floaters

# Free bodies along the course: light ones ride the stream and tumble over
# the spillways, dense ones sit against the flow. Reach assignment is dynamic
# -- a body is buoyed by whichever stage currently contains it.
const FLOATER_TABLE := [
	# start reach, kind, local offset, size, density
	[1, "ball", Vector3(0.7, 0.5, 0.2), 0.07, 250.0],
	[1, "ball", Vector3(1.3, 0.5, -0.2), 0.09, 400.0],
	[3, "crate", Vector3(0.8, 0.5, 0.15), 0.13, 650.0],
	[3, "rock", Vector3(2.0, 0.5, -0.15), 0.1, 3200.0],
	[5, "sphere", Vector3(0.9, 0.5, 0.2), 0.08, 450.0],
	[6, "log", Vector3(0.8, 0.5, 0.0), 0.45, 420.0],
	[7, "crate", Vector3(0.9, 0.5, 0.1), 0.11, 1150.0],
	[9, "ball", Vector3(0.8, 0.5, -0.15), 0.08, 300.0],
	[10, "log", Vector3(0.9, 0.5, 0.1), 0.4, 400.0],
	[12, "ball", Vector3(0.8, 0.5, 0.2), 0.09, 260.0],
	[12, "crate", Vector3(1.4, 0.5, -0.1), 0.12, 700.0],
	[13, "ball", Vector3(0.8, 0.5, 0.0), 0.1, 300.0],
	[13, "log", Vector3(1.5, 0.5, 0.15), 0.42, 420.0],
	[14, "buoy", Vector3(1.5, 1.2, -0.3), 0.11, 240.0],
	[14, "crate", Vector3(2.0, 1.2, 0.4), 0.14, 700.0],
]

func _spawn_floaters() -> void:
	for entry in FLOATER_TABLE:
		var idx: int = mini(entry[0], _reaches.size() - 1)
		var reach := _reaches[idx]
		var body := _make_floater(entry[1], entry[3], entry[4])
		body.position = entry[2] # reach-local; parented under the reach root
		reach.root.add_child(body)
		body.process_mode = Node.PROCESS_MODE_PAUSABLE
		_floaters.append(body)
		_floater_home[body] = body.transform
		_floater_reach[body] = idx
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
		"sphere", "ball":
			volume = 4.0 / 3.0 * PI * pow(size, 3.0)
			rb.mass = density * volume
			var sh := SphereShape3D.new()
			sh.radius = size
			var color := Color.from_hsv(0.55, 0.7, 0.9) if kind == "sphere" else Color(0.95, 0.8, 0.3)
			_add_shape_mesh(rb, sh, _sphere_mesh(size), color, 0.4, 0.0)
		"log":
			var radius := size * 0.14
			volume = PI * radius * radius * size
			rb.mass = density * volume
			var cap := CapsuleShape3D.new()
			cap.radius = radius
			cap.height = size
			var mesh := CapsuleMesh.new()
			mesh.radius = radius
			mesh.height = size
			var mi := _add_shape_mesh(rb, cap, mesh, Color(0.55, 0.38, 0.2), 0.9, 0.0)
			mi.rotation = Vector3(PI / 2, 0, 0) # lie along the flow
		"crate":
			volume = pow(size, 3.0)
			rb.mass = density * volume
			var box := BoxShape3D.new()
			box.size = Vector3.ONE * size
			var mesh := BoxMesh.new()
			mesh.size = Vector3.ONE * size
			_add_shape_mesh(rb, box, mesh, Color(0.72, 0.55, 0.3), 0.85, 0.0)
		"rock":
			volume = 4.0 / 3.0 * PI * pow(size, 3.0)
			rb.mass = density * volume
			var sh := SphereShape3D.new()
			sh.radius = size
			_add_shape_mesh(rb, sh, _sphere_mesh(size), Color(0.3, 0.29, 0.28), 0.95, 0.0)
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
	# Object-interaction stress: a seeded wave of bodies into the source and
	# the boulder field -- they ride the river down the whole course.
	var spots := [[0, Vector3(0.4, 0.6, 0.0)], [3, Vector3(1.0, 0.6, 0.1)], [5, Vector3(0.9, 0.6, 0.0)]]
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260929
	for i in range(8):
		var spot: Array = spots[i % spots.size()]
		var reach: Reach = _reaches[spot[0]]
		var kind := "crate" if i % 3 != 0 else "ball"
		var body := _make_floater(kind, 0.07 + 0.03 * (i % 3), 450.0 if kind == "crate" else 320.0)
		var local: Vector3 = spot[1] + Vector3(rng.randf_range(-0.2, 0.2), 0.2 * int(i / spots.size()), rng.randf_range(-0.2, 0.2))
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
			reach.fluid.clear() # next emit reconfigures; reaches refill by flow
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
			KEY_6: _goto_anchor(10)
			KEY_7: _goto_anchor(_reaches.size() - 1)

func _cycle_preset(dir: int) -> void:
	var idx := PRESET_ORDER.find(_preset)
	_preset = PRESET_ORDER[(idx + dir + PRESET_ORDER.size()) % PRESET_ORDER.size()]
	_reset(true)

func _goto_anchor(reach_idx: int) -> void:
	_tour = false
	if reach_idx < 0 or reach_idx >= _reaches.size():
		var view := _overview_view()
		_cam.position = view[0]
		_cam.look_at(view[1])
	else:
		var reach := _reaches[reach_idx]
		_cam.position = reach.anchor_pos
		_cam.look_at(reach.anchor_look)
	_sync_fly()

func _sync_fly() -> void:
	_fly.yaw = _cam.rotation.y
	_fly.pitch = _cam.rotation.x

func _overview_view() -> Array:
	if _reaches.is_empty():
		return [Vector3(40, 55, 45), Vector3.ZERO]
	var aabb := AABB(_reaches[0].fluid.global_position, Vector3.ZERO)
	for reach in _reaches:
		if is_instance_valid(reach.fluid):
			aabb = aabb.expand(reach.fluid.global_position)
	var center := aabb.get_center()
	var off := Vector3(0.85, 0.55, 0.85) * maxf(aabb.size.length() * 0.62, 40.0)
	return [center + off, center]

# ------------------------------------------------------------------- camera

func _tour_step(delta: float) -> void:
	# Glide down the course: ease toward each reach anchor in turn.
	var target := _reaches[_tour_target % _reaches.size()]
	_cam.position = _cam.position.lerp(target.anchor_pos, clampf(delta * 0.8, 0.0, 1.0))
	var to_look := (target.anchor_look - _cam.position).normalized()
	if to_look.length_squared() > 0.001:
		var current := -_cam.global_transform.basis.z
		var blended := current.slerp(to_look, clampf(delta * 2.0, 0.0, 1.0)).normalized()
		_cam.look_at(_cam.position + blended, Vector3.UP)
	_sync_fly()
	if _cam.position.distance_to(target.anchor_pos) < 5.0:
		_tour_target = (_tour_target + 1) % _reaches.size()

# -------------------------------------------------------------- simulation

func _physics_process(delta: float) -> void:
	if _paused or get_tree().paused:
		return
	_t += delta

	_assign_accum += delta
	if _assign_accum >= 0.3:
		_assign_accum = 0.0
		_reassign_floaters()

	# Discharge coupling: each reach's outlet probe modulates the next faucet
	# (hidden on the spillway lip), so the single top source drives the whole
	# course and upstream surges propagate downstream.
	_couple_accum += delta
	if _couple_accum >= 0.2:
		var dt := _couple_accum
		_couple_accum = 0.0
		var preset_scale: float = PRESETS[_preset].rate / PRESETS["MEDIUM"].rate
		var mode_scale := 2.2 if MODES[_mode_idx] == "STRESS" else 1.0
		_update_steam(dt)
		for i in range(_reaches.size()):
			var reach := _reaches[i]
			if not is_instance_valid(reach.fluid):
				continue
			var fill := clampf(reach.fluid.get_submersion(reach.outlet_probe), 0.0, 1.0)
			if fill >= 0.35 and reach.filled_at < 0.0:
				reach.filled_at = _t
			var target := 1.0
			var n := 0
			for up in reach.upstream:
				if is_instance_valid(up.fluid):
					target += clampf(up.fluid.get_submersion(up.outlet_probe), 0.0, 1.0)
					n += 1
			if n > 0:
				target = clampf(0.15 + (target - 1.0) / n * 1.05, 0.15, 1.0)
			if i == _heat_reach + 1:
				target *= 1.0 - _evap_loss # discharge lost to evaporation
			if i == _gate_reach and not (MODES[_mode_idx] in ["FULL", "SPLIT/MERGE", "STRESS"]):
				reach.rate_scale = 0.0 # channel B gated off
				reach.fluid.emission_rate = 0.0
			else:
				reach.rate_scale = lerpf(reach.rate_scale, target, clampf(dt * 1.6, 0.0, 1.0))
				reach.fluid.emission_rate = reach.base_rate * reach.rate_scale * mode_scale * preset_scale

	# Script-side buoyancy + drag, per floater, from its current stage's fluid
	# state -- the same approximation the faucet demo uses (the MPM couple pass
	# nudges coupled bodies but does not float them by density).
	for body in _floaters:
		if not is_instance_valid(body):
			continue
		var ridx := _reach_index_of(body)
		if ridx < 0:
			continue
		if _floater_reach.get(body, -1) != ridx:
			_move_floater_reach(body, ridx)
		var reach := _reaches[ridx]
		if not is_instance_valid(reach.fluid):
			continue
		var vol: float = body.get_meta("volume", 1.0)
		var side := pow(maxf(vol, 0.001), 1.0 / 3.0)
		var aabb := AABB(body.global_position - Vector3.ONE * side * 0.5, Vector3.ONE * side)
		var submerged := clampf(reach.fluid.get_submersion(aabb), 0.0, 1.0)
		body.linear_damp = lerpf(0.05, 2.2, submerged)
		if submerged > 0.0:
			var buoy: float = WATER_DENSITY * submerged * vol * 9.8
			body.apply_central_force(Vector3.UP * minf(buoy, body.mass * 9.8 * 1.35))

	# Adrift-body recovery: anything well below the course for 15 s goes back.
	for body in _floaters:
		if not is_instance_valid(body):
			continue
		if body.global_position.y < -8.0:
			var since: float = _floater_stranded.get(body, -1.0)
			if since < 0.0:
				_floater_stranded[body] = _t
			elif _t - since > 15.0:
				_reset_floater(body)
		else:
			_floater_stranded[body] = -1.0

# Which stage's domain currently contains this body?
func _reach_index_of(body: RigidBody3D) -> int:
	for i in range(_reaches.size()):
		var reach := _reaches[i]
		if not is_instance_valid(reach.fluid):
			continue
		var rel := (body.global_position - reach.fluid.global_position).abs()
		var half := reach.domain * 0.5
		if rel.x <= half.x and rel.y <= half.y and rel.z <= half.z:
			return i
	return -1

# Hand a floater's coupling from its old stage to its new one.
func _move_floater_reach(body: RigidBody3D, new_idx: int) -> void:
	var old_idx: int = _floater_reach.get(body, -1)
	if old_idx >= 0 and old_idx < _reaches.size():
		_reaches[old_idx].floaters.erase(body)
		_rebuild_colliders(_reaches[old_idx])
	if new_idx >= 0 and new_idx < _reaches.size():
		_reaches[new_idx].floaters.append(body)
		_rebuild_colliders(_reaches[new_idx])

# Periodic re-assignment pass (covers bodies the per-tick check missed).
func _reassign_floaters() -> void:
	for body in _floaters:
		if not is_instance_valid(body):
			continue
		var ridx := _reach_index_of(body)
		if ridx >= 0 and _floater_reach.get(body, -1) != ridx:
			_move_floater_reach(body, ridx)

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
	if _shots_dir != "" and _bench_frame % 140 == 70:
		_capture_shot()
	if _bench and _bench_frame >= _bench_frames:
		_finish_bench()

# Steam at the heated checkpoint: measure water contact on the hot plates,
# smooth it into a steam intensity, gate the Flow emitters with it (smoke
# injection scales with the contact), and derive the evaporation loss the
# downstream reach's discharge suffers. Flow availability is checked once,
# shortly after startup -- the runtime loads nvflow.dll lazily.
func _update_steam(dt: float) -> void:
	if _steam_available == 0 or _heat_reach < 0:
		return
	var heat := _reaches[_heat_reach]
	if not is_instance_valid(heat.fluid):
		return
	var contact := clampf(heat.fluid.get_submersion(_heat_probe) * 2.0, 0.0, 1.0)
	# fast attack, slow release: steam lingers briefly after the water passes
	var rate := 3.0 if contact > _steam_level else 0.7
	_steam_level = lerpf(_steam_level, contact, clampf(dt * rate, 0.0, 1.0))
	if _steam_available < 0 and _t > 1.5:
		var diag: Dictionary = _flow_sim.call("get_diagnostics")
		_steam_available = 1 if bool(diag.get("available", false)) else 0
		if _steam_available == 0:
			print("[river] Flow runtime unavailable -- steam inert (", diag.get("backend", "?"), ")")
	if _steam_available == 1:
		var smoking := _steam_level > 0.08
		for e in _flow_emitters:
			e.set("enabled", smoking)
			e.set("smoke", 4.0 * _steam_level)
	_evap_loss = 0.3 * _steam_level

# Simulation LOD: every MPM fluid syncs its own GPU queue once per physics
# tick (~13 ms each on the test GPU), so stages near the camera run at full
# rate and the rest hold their water frozen, resuming -- with the discharge
# coupling -- as the camera reaches them.
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
	for i in range(mini(3, order.size())): # the nearest reaches always run
		keep[order[i]] = true
	for i in order: # plus anything inside the radius
		if dists[i] < _sim_radius * _sim_radius:
			keep[i] = true
	_sim_active = keep.size()
	for i in range(_reaches.size()):
		if is_instance_valid(_reaches[i].fluid) and i < _active_stages:
			_reaches[i].fluid.process_mode = Node.PROCESS_MODE_PAUSABLE if keep.has(i) else Node.PROCESS_MODE_DISABLED

# Broad sanity instrumentation -- one reach per 1.5 s so the full GPU readback
# stays off the hot path. NaNs and out-of-domain particles should both stay at
# zero (the MPM clamps to its domain box).
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
			if body.global_position.distance_to(_floater_world_home(home, body)) > 3.0:
				_obj_moved = true
			if body.linear_velocity.length() > 200.0:
				_nan_total += 1 # velocity blow-up counts against stability

func _floater_world_home(home: Transform3D, body: RigidBody3D) -> Vector3:
	var parent := body.get_parent()
	if parent is Node3D:
		return (parent as Node3D).global_transform * home.origin
	return home.origin

func _fluid_totals() -> Array:
	var totals := [0, 0, 0.0, 0] # particles, foam, step ms, reaches
	for reach in _reaches:
		if is_instance_valid(reach.fluid):
			totals[0] += reach.fluid.get_live_particle_count()
			totals[1] += reach.fluid.get_live_foam_count()
			totals[2] += reach.fluid.get_mpm_step_msec()
			totals[3] += 1
	return totals

func _capture_shot() -> void:
	var spots := [-1, _heat_reach, _reaches.size() - 1] # overview, heated, basin
	if _shot_idx >= spots.size():
		get_tree().quit()
		return
	var reach_idx: int = spots[_shot_idx]
	if reach_idx < 0:
		var view := _overview_view()
		_cam.position = view[0]
		_cam.look_at(view[1])
	else:
		_cam.position = _reaches[reach_idx].anchor_pos
		_cam.look_at(_reaches[reach_idx].anchor_look)
	_sync_fly()
	# let the LOD + camera + steam plume settle before the grab
	await get_tree().create_timer(2.0).timeout
	var img := get_viewport().get_texture().get_image()
	var path := _shots_dir.path_join("river_%d.png" % reach_idx)
	img.save_png(path)
	print("[river] shot -> ", path)
	_shot_idx += 1

func _finish_bench() -> void:
	var totals := _fluid_totals()
	var fps := maxf(Engine.get_frames_per_second(), 1.0)
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	print("[river] bench frames=%d  fps=%.1f  frame_ms=%.2f  mpm_step_ms=%.2f  script_proc=%.1fms  script_phys=%.1fms  particles=%d  foam=%d  sim=%d/%d  steam=%s  evap=%.0f%%  preset=%s  mode=%s  nan=%d  escapes=%d" % [
			_bench_frame, fps, 1000.0 / fps, totals[2], proc_ms, phys_ms,
			totals[0], totals[1], _sim_active, _reaches.size(), _steam_status(), _evap_loss * 100.0,
			_preset, MODES[_mode_idx], _nan_total, _escapes])
	get_tree().quit()

func _section_for_camera() -> String:
	if _reaches.is_empty():
		return "-"
	var best := 0
	var best_d := 1e18
	for i in range(_reaches.size()):
		var d := _cam.position.distance_squared_to(_reaches[i].fluid.global_position)
		if d < best_d:
			best_d = d
			best = i
	return _reaches[best].kind

func _steam_status() -> String:
	if _steam_available == 0:
		return "unavailable"
	if _steam_available < 0:
		return "checking"
	return "STEAM %.0f%%" % (_steam_level * 100.0) if _steam_level > 0.08 else "hot (idle)"

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
		transit = "  outlets fed in %ds" % int(last_fill)
	var state := "PAUSED" if _paused else ("TOUR" if _tour else "FLY")
	var stability := "STABLE" if _nan_total == 0 and _escapes == 0 else "UNSTABLE (nan=%d escapes=%d)" % [_nan_total, _escapes]
	_hud.text = "\n".join([
		"PHYSX GPU RIVER TEST - staged MPM river, %d reaches (%d simulating)" % [_reaches.size(), _sim_active],
		"engine=%s  particles=%d  foam=%d  emit=%.0f/s  mpm step=%.1f ms" % [
			ProjectSettings.get_setting("physics/3d/physics_engine", "?"), totals[0], totals[1], _emit_rate_total(), totals[2]],
		"fps=%d (%.1f ms)  preset=%s  mode=%s  %s" % [fps, 1000.0 / maxf(fps, 1), _preset, MODES[_mode_idx], state],
		"flow: %d/%d outlets fed%s  objects moved=%s  %s" % [filled, _reaches.size(), transit, "yes" if _obj_moved else "no", stability],
		"heat: %s  evap loss=%.0f%%" % [_steam_status(), _evap_loss * 100.0],
		"section: %s" % _section_for_camera(),
		"WASD+RMB fly  1-7 sections  C tour  TAB mode  [ ] preset  G objects  P pause  R reset  F hud  ESC",
	])

func _emit_rate_total() -> float:
	var rate := 0.0
	for reach in _reaches:
		if is_instance_valid(reach.fluid):
			rate += reach.fluid.emission_rate
	return rate
