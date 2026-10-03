extends Node3D

# GPU river-flow stress test for the PhysX backend (PhysXParticleFluid3D).
#
# NODE-AUTHORED: the whole course -- channel geometry, fluid stages, floaters,
# soft bodies, steam rig, labels, camera and HUD -- lives in physx_river.tscn
# as ordinary nodes (StaticBody3D channels, RigidBody3D floaters, SoftBody3D
# blobs, PhysXParticleFluid3D faucets, PhysXFlow* steam). Open the scene in
# the editor and edit it like any other scene; this script only runs the
# simulation behavior.
#
# The scene contract this script reads:
#   $River/<Reach>*      reaches in downstream order (Node3D, yawed; +X is
#                        downstream, faucet at the local origin). Each has:
#     Fluid              PhysXParticleFluid3D -- the reach's faucet + domain
#                        (node = domain center; authored on the previous
#                        spillway lip so water appears to pour over it)
#     Outlet             Node3D marker: origin = discharge probe center,
#                        scale = probe box size
#     Anchor / Look      Node3D markers framing the section camera
#     Obstacles/…        optional mode-toggled obstacle bodies
#     HeatProbe          heated checkpoint's contact probe (origin/scale)
#     Steam              PhysXFlowSimulation3D + PhysXFlowEmitter3D children
#     metadata/upstream  comma-separated reach names feeding this faucet
#                        (default: the previous reach)
#   $Floaters/*          RigidBody3D bodies riding the river; density decides
#                        whether they travel or stick; metadata/volume = m^3
#   $SoftBodies/*        stock SoftBody3D blobs -- deformable-body test only:
#                        this backend has no fluid/soft coupling (documented)
#   $River/<Reach>/Obstacles, /Island    mode-toggled bodies (TAB cycles)
#   $Camera              authored overview view; 1..7 keys jump to sections
#   $HUD/Label           readout
#
# The course is ONE CONTINUOUS WATER SLIDE from a spring tank at ~98 m to the
# collection basin at 0 m -- no weirs, no plunge pools, no free falls, no
# labels. The chute floors and bank walls span exactly head-to-tail and
# overlap their neighbors at every joint (the joints carry a joint patch and
# shared-crease geometry), so the static bodies form one unbroken flume. Each
# segment carries its own PhysXParticleFluid3D whose world-aligned MPM domain
# is sized to the segment plus the joint overlap and laterally no wider than
# the channel, with its bottom exactly at the floor line -- water handed off
# at a seam always sits inside a live domain, and squeezed particles can only
# pop back on top of the floor, never under it. Every fluid also couples the
# NEIGHBOR segments' floor and bank bodies (colliders are per-fluid). Every
# segment prefills full at spawn and its faucet (hidden mid-run, pitched with
# the channel) emits the discharge the upstream segment's flow meter reads,
# so the single top source drives the whole course and surges propagate
# downstream. Flow rate crosses each seam; MPM domains clamp particles, so
# water mass cannot. The slopes grade from ~58 deg at the top to ~7 deg at
# the bottom; the only true basin is the last reach, floor at 0 m.
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

# Quality presets scale each fluid's authored (MEDIUM) capacity/foam/rate.
const PRESETS := {
	"LOW": { "count": 0.6, "foam": 0.5, "rate": 0.6, "surface": false, "substeps": 3 },
	"MEDIUM": { "count": 1.0, "foam": 1.0, "rate": 1.0, "surface": false, "substeps": 3 },
	"HIGH": { "count": 1.4, "foam": 1.6, "rate": 1.4, "surface": true, "substeps": 4 },
	"STRESS": { "count": 1.9, "foam": 2.6, "rate": 2.2, "surface": true, "substeps": 5 },
}
const PRESET_ORDER: Array[String] = ["LOW", "MEDIUM", "HIGH", "STRESS"]

# Test modes (TAB): obstacle bodies toggle, the ChannelB faucet gates.
const MODES: Array[String] = ["FULL", "LAMINAR", "TURBULENT", "SPLIT/MERGE", "STRESS"]

class ReachInfo:
	var node: Node3D
	var fluid: PhysXParticleFluid3D # the ACTIVE fluid (MPM or PBD)
	var pbd: PhysXParticleFluid3D # this reach's PBD group fluid (pure water)
	var domain := Vector3.ZERO
	var outlet_probe := AABB()
	var anchor := Vector3.ZERO
	var look := Vector3.ZERO
	var statics: Array[Node] = [] # always-coupled channel bodies
	var obstacles: Array[Node] = [] # mode-toggled bodies (rocks, pebbles)
	var islands: Array[Node] = [] # the split island (SPLIT/MERGE mode)
	var upstream: Array[int] = [] # reach indices feeding this faucet
	var base_count := 0
	var base_foam := 0
	var base_rate := 1.0
	var rate_scale := 1.0
	var filled_at := -1.0

	func name() -> String:
		return String(node.name)

var _reaches: Array[ReachInfo] = []
var _reach_by_name := {}
var _floaters: Array[RigidBody3D] = []
var _floater_home := {} # body -> authored transform (world)
var _floater_reach := {} # body -> reach index
var _floater_stranded := {} # body -> sim seconds adrift below the course
var _heat_idx := -1 # heated checkpoint reach
var _heat_probe := AABB()
var _flow_emitters: Array[Node3D] = []
var _steam_level := 0.0
var _steam_available := -1 # -1 unknown, 0 unavailable, 1 running
var _evap_loss := 0.0
var _solver_pbd := true # default: ONE PBD water body for the whole course
var _river_water: PhysXParticleFluid3D
var _overview_xf := Transform3D() # the authored $Camera view

var _preset := "MEDIUM"
var _mode_idx := 0
var _hud_visible := true
@onready var _cam: Camera3D = $Camera
@onready var _hud: Label = $HUD/Label
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
var _sim_radius := 12.0
var _sim_active := 0
var _shots_dir := ""
var _shot_idx := 0
var _capturing := false

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
		elif arg == "solver=pbd":
			_set_solver.call_deferred(true)
		elif arg.begins_with("shots="):
			_shots_dir = arg.substr(6)

	_overview_xf = _cam.transform
	_fly = FlyCamera.new(_cam, 16.0)
	_discover_scene()
	# MEDIUM (the authored preset) matches the scene files: keep the prefills,
	# the slide starts full. Other presets rebuild the fluids empty; they then
	# fill by through-flow.
	_apply_preset(_preset != "MEDIUM")
	_apply_mode() # builds the per-reach collider lists for the FULL mode
	for i in range(_active_stages, _reaches.size()):
		_reaches[i].fluid.process_mode = Node.PROCESS_MODE_DISABLED

# ------------------------------------------------------------ scene binding

func _discover_scene() -> void:
	var river := get_node("River")
	for child in river.get_children():
		var fluid := child.get_node_or_null("Fluid") as PhysXParticleFluid3D
		if fluid == null:
			continue
		var info := ReachInfo.new()
		info.node = child
		info.fluid = fluid
		pass # the PBD group fluids are bound after the reach loop (meta pbd_group)
		info.domain = fluid.mpm_domain_size
		var outlet: Node3D = child.get_node_or_null("Outlet")
		if outlet != null:
			info.outlet_probe = AABB(outlet.global_position - outlet.scale * 0.5, outlet.scale)
		var anchor: Node3D = child.get_node_or_null("Anchor")
		if anchor != null:
			info.anchor = anchor.global_position
		var look: Node3D = child.get_node_or_null("Look")
		if look != null:
			info.look = look.global_position
		info.statics = _collect_statics(child, true)
		var obstacles := child.get_node_or_null("Obstacles")
		if obstacles != null:
			info.obstacles = _collect_statics(obstacles, false)
		var island := child.get_node_or_null("Island")
		if island != null:
			info.islands.append(island)
		info.base_count = fluid.particle_count
		info.base_foam = fluid.foam_particle_count
		info.base_rate = fluid.emission_rate
		var up_meta: String = child.get_meta("upstream") if child.has_meta("upstream") else ""
		for up_name in up_meta.split(",", false):
			if _reach_by_name.has(up_name):
				info.upstream.append(_reach_by_name[up_name])
		if child.get_node_or_null("HeatProbe") != null:
			_heat_idx = _reaches.size()
			var probe: Node3D = child.get_node("HeatProbe")
			_heat_probe = AABB(probe.global_position - probe.scale * 0.5, probe.scale)
			var steam := child.get_node_or_null("Steam")
			if steam != null:
				for emitter in steam.get_children():
					_flow_emitters.append(emitter)
		_reach_by_name[info.name()] = _reaches.size()
		_reaches.append(info)
		if _reaches.size() > 1 and info.upstream.is_empty():
			info.upstream = [_reaches.size() - 2] # default: the previous reach
	# the geometry overlaps at every joint: couple each fluid with its
	# neighbors' channel bodies too (floor + banks + joint patch), so water
	# handing off at a seam still has ground AND walls inside the domain
	# overlap -- colliders are per-fluid, and an uncoupled neighbor wall is
	# simply not there for this fluid's particles
	for i in range(_reaches.size()):
		for j in [i - 1, i + 1]:
			if j < 0 or j >= _reaches.size():
				continue
			for body in _reaches[j].node.get_children():
				if body is StaticBody3D and String(body.name) in ["Floor", "BankL", "BankR", "JointPatch"]:
					_reaches[i].statics.append(body)
	# bind the merged PBD group fluids (pure PhysX water for the M toggle):
	# each reach carries meta pbd_group naming the group fluid that covers it
	_river_water = get_node_or_null("RiverWater") as PhysXParticleFluid3D
	var pbd_groups := {}
	for child in get_children():
		if String(child.name).begins_with("PBDGroup"):
			pbd_groups[String(child.name)] = child
	for info in _reaches:
		info.pbd = pbd_groups.get("PBDGroup%d" % int(info.node.get_meta("pbd_group", 0)), null)
	# default mode is the single PBD river water: park EVERY other fluid out
	# of the tree -- the 23 staged MPM fluids AND the six old PBDGroup boxes
	# (they spawn_on_ready huge AABBs of water = the "curtains"). Only the
	# RiverWater source stays. M re-attaches the staged set.
	if _solver_pbd:
		for info in _reaches:
			var mpm := info.node.get_node_or_null("Fluid")
			if mpm != null and mpm.get_parent() != null:
				info.node.remove_child(mpm)
		for child in get_children():
			if String(child.name).begins_with("PBDGroup") and child.get_parent() != null:
				remove_child(child)

# All StaticBody3D under `from`; with skip_obstacles, any subtree named
# Obstacles is left out (those are mode-toggled, listed separately).
func _collect_statics(from: Node, skip_obstacles: bool) -> Array[Node]:
	var out: Array[Node] = []
	for child in from.get_children():
		if skip_obstacles and String(child.name) == "Obstacles":
			continue
		if child is StaticBody3D:
			out.append(child)
		out.append_array(_collect_statics(child, skip_obstacles))
	return out

# -------------------------------------------------------------- fluid knobs

func _apply_preset(restart := true) -> void:
	var p: Dictionary = PRESETS[_preset]
	for info in _reaches:
		info.fluid.particle_count = maxi(int(info.base_count * p.count), 1)
		info.fluid.foam_particle_count = maxi(int(info.base_foam * p.foam), 1)
		info.fluid.surface_mesh = p.surface or bool(info.node.get_meta("always_surface", false))
		info.fluid.mpm_substeps = p.substeps
		if restart:
			info.fluid.clear() # reconfigured on the next emission tick

func _apply_mode() -> void:
	var mode: String = MODES[_mode_idx]
	var obstacles_on := mode in ["FULL", "TURBULENT", "STRESS"]
	var islands_on := mode in ["FULL", "SPLIT/MERGE", "STRESS"]
	for info in _reaches:
		for body in info.obstacles:
			body.visible = obstacles_on
			_set_shapes_disabled(body, not obstacles_on)
		for island in info.islands:
			island.visible = islands_on
			_set_shapes_disabled(island, not islands_on)
		info.rate_scale = 2.2 if mode == "STRESS" else 1.0
		_rebuild_colliders(info)

func _set_shapes_disabled(body: Node, disabled: bool) -> void:
	for child in body.get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", disabled)

# The fluid node re-reads mpm_colliders every step; paths are fluid-relative.
func _rebuild_colliders(info: ReachInfo) -> void:
	if not is_instance_valid(info.fluid) or _solver_pbd:
		return # PBD collides with the whole space; no collider lists needed
	var mode: String = MODES[_mode_idx]
	var paths: Array[NodePath] = []
	for body in info.statics:
		# the hot plates are visual-only for the fluid: their sharp upstream
		# corners squeeze passing particles straight down through the floor
		if String(body.name).begins_with("HotPlate"):
			continue
		paths.append(info.fluid.get_path_to(body))
	if mode in ["FULL", "TURBULENT", "STRESS"]:
		for body in info.obstacles:
			paths.append(info.fluid.get_path_to(body))
	if mode in ["FULL", "SPLIT/MERGE", "STRESS"]:
		for island in info.islands:
			paths.append(info.fluid.get_path_to(island))
	for i in range(_floaters.size()):
		if _floater_reach.get(_floaters[i], -1) == _reaches.find(info) and is_instance_valid(_floaters[i]):
			paths.append(info.fluid.get_path_to(_floaters[i]))
	info.fluid.mpm_colliders = paths

func _spawn_floater_burst() -> void:
	# Object-interaction stress: a seeded wave of bodies into the source and
	# the boulder field -- they ride the river down the whole course.
	var spots := [0, 3, 5]
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260929
	var holder := get_node("Floaters")
	for i in range(8):
		var kind := "crate" if i % 3 != 0 else "ball"
		var body := RigidBody3D.new()
		_build_floater_body(body, kind, 0.07 + 0.03 * (i % 3), 450.0 if kind == "crate" else 320.0)
		var base: Node3D = _reaches[spots[i % spots.size()]].node
		body.position = base.global_transform * (Vector3(0.4, 0.6, 0) \
				+ Vector3(rng.randf_range(-0.2, 0.2), 0.2 * int(i / spots.size()), rng.randf_range(-0.2, 0.2)))
		holder.add_child(body)
		body.process_mode = Node.PROCESS_MODE_PAUSABLE
		_floaters.append(body)
		_floater_home[body] = body.transform
		_floater_reach[body] = -1
		_floater_stranded[body] = -1.0

# A floater body from parts (burst bodies; scene-authored ones carry their own).
func _build_floater_body(body: RigidBody3D, kind: String, size: float, density: float) -> void:
	body.can_sleep = false
	body.continuous_cd = true
	body.linear_damp = 0.05
	body.angular_damp = 0.1
	var volume := 1.0
	var cs := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.5
	match kind:
		"ball", "sphere", "buoy", "rock":
			volume = 4.0 / 3.0 * PI * pow(size, 3.0)
			body.mass = density * volume
			var sh := SphereShape3D.new()
			sh.radius = size
			cs.shape = sh
			var sm := SphereMesh.new()
			sm.radius = size
			sm.height = size * 2.0
			mi.mesh = sm
			match kind:
				"ball": mat.albedo_color = Color(0.95, 0.8, 0.3)
				"sphere": mat.albedo_color = Color.from_hsv(0.55, 0.7, 0.9)
				"buoy": mat.albedo_color = Color(0.95, 0.55, 0.15)
				"rock": mat.albedo_color = Color(0.3, 0.29, 0.28)
		"crate":
			volume = pow(size, 3.0)
			body.mass = density * volume
			var box := BoxShape3D.new()
			box.size = Vector3.ONE * size
			cs.shape = box
			var bm := BoxMesh.new()
			bm.size = Vector3.ONE * size
			mi.mesh = bm
			mat.albedo_color = Color(0.72, 0.55, 0.3)
		"log":
			var radius := size * 0.14
			volume = PI * radius * radius * size
			body.mass = density * volume
			var cap := CapsuleShape3D.new()
			cap.radius = radius
			cap.height = size
			cs.shape = cap
			var cm := CapsuleMesh.new()
			cm.radius = radius
			cm.height = size
			mi.mesh = cm
			mi.rotation = Vector3(PI / 2, 0, 0)
			mat.albedo_color = Color(0.55, 0.38, 0.2)
	mi.material_override = mat
	body.add_child(cs)
	body.add_child(mi)
	body.set_meta("volume", volume)

# ------------------------------------------------------------------- reset

func _reset(full_presets := false) -> void:
	for info in _reaches:
		info.filled_at = -1.0
		info.rate_scale = 2.2 if MODES[_mode_idx] == "STRESS" else 1.0
		if is_instance_valid(info.fluid):
			info.fluid.clear() # next emit reconfigures; reaches refill by flow
	if full_presets:
		_apply_preset()
		_apply_mode() # fresh collider lists for the fresh fluids
	for body in _floaters:
		if is_instance_valid(body):
			body.transform = _floater_home[body]
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO
			_floater_stranded[body] = -1.0
	_nan_total = 0
	_escapes = 0
	_scan_reach = 0
	_goto_anchor(-1)

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
			KEY_M:
				_set_solver(not _solver_pbd)
			KEY_BRACKETLEFT:
				_cycle_preset(-1)
			KEY_BRACKETRIGHT:
				_cycle_preset(1)
			KEY_1: _goto_anchor(-1)
			KEY_2: _goto_named("Source")
			KEY_3: _goto_named("BoulderRun")
			KEY_4: _goto_named("Heated")
			KEY_5: _goto_named("IslandSplit")
			KEY_6: _goto_named("Rapids")
			KEY_7: _goto_named(_reaches[_reaches.size() - 1].name())

# M key: switch the whole river between staged MPM water (foam + steam, one
# fluid per segment) and pure PhysX CUDA water (PBD, no foam -- PBD collides
# with the whole space, so each segment's water genuinely flows the slide and
# mingles across seams; no domains, no LOD needed). The swap detaches the
# inactive twin and re-adds the active one; spawn_on_ready fills it.
func _set_solver(pbd: bool) -> void:
	if pbd == _solver_pbd:
		return
	_solver_pbd = pbd
	for info in _reaches:
		if info.pbd == null:
			continue
		var mpm: PhysXParticleFluid3D = info.node.get_node_or_null("Fluid")
		var active := info.fluid
		if pbd:
			if active == mpm and mpm.get_parent() != null:
				mpm.get_parent().remove_child(mpm)
			if info.pbd.get_parent() == null:
				add_child(info.pbd) # group fluids live directly under the root
			info.fluid = info.pbd
		else:
			if active == info.pbd and info.pbd.get_parent() != null:
				info.pbd.get_parent().remove_child(info.pbd)
			if mpm.get_parent() == null:
				info.node.add_child(mpm)
				mpm.call("spawn") # spawn_on_ready is off for the staged set
			info.fluid = mpm
		info.filled_at = -1.0
		_rebuild_colliders(info)
	print("[river] solver = ", "PhysX PBD (pure water, no foam)" if pbd else "MPM (staged, foam + steam)")

func _cycle_preset(dir: int) -> void:
	var idx := PRESET_ORDER.find(_preset)
	_preset = PRESET_ORDER[(idx + dir + PRESET_ORDER.size()) % PRESET_ORDER.size()]
	_apply_preset(true)

func _goto_named(reach_name: String) -> void:
	_goto_anchor(_reach_by_name.get(reach_name, -1))

func _goto_anchor(reach_idx: int) -> void:
	_tour = false
	if reach_idx < 0 or reach_idx >= _reaches.size():
		_cam.transform = _overview_xf
	else:
		_cam.position = _reaches[reach_idx].anchor
		_cam.look_at(_reaches[reach_idx].look)
	_sync_fly()

func _sync_fly() -> void:
	_fly.yaw = _cam.rotation.y
	_fly.pitch = _cam.rotation.x

# ------------------------------------------------------------------- camera

func _tour_step(delta: float) -> void:
	# Glide down the course: ease toward each reach anchor in turn.
	var target := _reaches[_tour_target % _reaches.size()]
	_cam.position = _cam.position.lerp(target.anchor, clampf(delta * 0.8, 0.0, 1.0))
	var to_look := (target.look - _cam.position).normalized()
	if to_look.length_squared() > 0.001:
		var current := -_cam.global_transform.basis.z
		var blended := current.slerp(to_look, clampf(delta * 2.0, 0.0, 1.0)).normalized()
		_cam.look_at(_cam.position + blended, Vector3.UP)
	_sync_fly()
	if _cam.position.distance_to(target.anchor) < 5.0:
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
		var preset_scale: float = PRESETS[_preset].rate
		var mode_scale := 2.2 if MODES[_mode_idx] == "STRESS" else 1.0
		_update_steam(dt)
		for i in range(_reaches.size()):
			var info := _reaches[i]
			if not is_instance_valid(info.fluid):
				continue
			var fill := clampf(info.fluid.get_submersion(info.outlet_probe), 0.0, 1.0)
			if fill >= 0.08 and info.filled_at < 0.0:
				info.filled_at = _t
			# reservoir coupling: a seam passes on what its upstream segment
			# HOLDS, so the spring alone sets the whole course's fill level --
			# no water is created beyond what the source poured in
			var target := 1.0
			var n := 0
			for up in info.upstream:
				var upf := _reaches[up].fluid
				target += clampf(float(upf.get_live_particle_count()) / maxf(float(upf.particle_count), 1.0) * 1.15, 0.0, 1.0)
				n += 1
			if n > 0:
				target = clampf((target - 1.0) / n, 0.08, 1.0)
			if i == _heat_idx:
				target = maxf(target, 0.6) # the checkpoint always has a stream to boil
			if i == _heat_idx + 1:
				target *= 1.0 - _evap_loss # discharge lost to evaporation
			info.rate_scale = lerpf(info.rate_scale, target, clampf(dt * 1.6, 0.0, 1.0))
			info.fluid.emission_rate = info.base_rate * info.rate_scale * mode_scale * preset_scale

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
		var fluid := _reach_fluid(_reaches[ridx])
		if not is_instance_valid(fluid):
			continue
		var vol: float = body.get_meta("volume", 1.0)
		var side := pow(maxf(vol, 0.001), 1.0 / 3.0)
		var aabb := AABB(body.global_position - Vector3.ONE * side * 0.5, Vector3.ONE * side)
		var submerged := clampf(fluid.get_submersion(aabb), 0.0, 1.0)
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
				body.transform = _floater_home[body]
				body.linear_velocity = Vector3.ZERO
				body.angular_velocity = Vector3.ZERO
				_floater_stranded[body] = -1.0
		else:
			_floater_stranded[body] = -1.0

# The active fluid for a reach: the shared river water in PBD mode, the
# reach's own MPM fluid in staged mode.
func _reach_fluid(reach: ReachInfo) -> PhysXParticleFluid3D:
	return _river_water if _solver_pbd else reach.fluid

# Which stage's domain currently contains this body?
func _reach_index_of(body: RigidBody3D) -> int:
	if _solver_pbd:
		# one water body: bind by the nearest reach anchor
		var best := 0
		var best_d := 1e18
		for i in range(_reaches.size()):
			var d := body.global_position.distance_squared_to(_reaches[i].node.global_position)
			if d < best_d:
				best_d = d
				best = i
		return best
	for i in range(_reaches.size()):
		var info := _reaches[i]
		var rel := (body.global_position - info.fluid.global_position).abs()
		var half := info.domain * 0.5
		if rel.x <= half.x and rel.y <= half.y and rel.z <= half.z:
			return i
	return -1

# Hand a floater's coupling from its old stage to its new one.
func _move_floater_reach(body: RigidBody3D, new_idx: int) -> void:
	var old_idx: int = _floater_reach.get(body, -1)
	_floater_reach[body] = new_idx
	if old_idx >= 0 and old_idx < _reaches.size():
		_rebuild_colliders(_reaches[old_idx])
	if new_idx >= 0 and new_idx < _reaches.size():
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
	_fly.process(delta) # WASD flight (mouse-look is handled in _unhandled_input)
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
	if _shots_dir != "" and not _capturing and _bench_frame % 140 == 70:
		_capturing = true
		_capture_shot()
	if _bench and _bench_frame >= _bench_frames:
		_finish_bench()

# Steam at the heated checkpoint: measure water contact on the hot plates,
# smooth it into a steam intensity, gate the Flow emitters with it (smoke
# injection scales with the contact), and derive the evaporation loss the
# downstream reach's discharge suffers. Flow availability is checked once,
# shortly after startup -- the runtime loads nvflow.dll lazily.
func _update_steam(dt: float) -> void:
	if _heat_idx < 0:
		return
	var heat := _reaches[_heat_idx]
	if not is_instance_valid(_reach_fluid(heat)):
		return
	var contact := clampf(_reach_fluid(heat).get_submersion(_heat_probe) * 3.0, 0.0, 1.0)
	# fast attack, slow release: steam lingers briefly after the water passes
	var rate := 3.0 if contact > _steam_level else 0.7
	_steam_level = lerpf(_steam_level, contact, clampf(dt * rate, 0.0, 1.0))
	var smoking := _steam_level > 0.04
	for e in _flow_emitters:
		e.set("density", 3.0 * _steam_level if smoking else 0.0)
	_evap_loss = 0.15 * _steam_level

# Simulation LOD: stages near the camera simulate; the rest hold their water.
func _update_sim_lod() -> void:
	if _lod_off or _solver_pbd:
		_sim_active = 1 if _solver_pbd else _reaches.size()
		return
	var dists := {}
	for i in range(_reaches.size()):
		if is_instance_valid(_reaches[i].fluid) and i < _active_stages:
			dists[i] = _cam.position.distance_squared_to(_reaches[i].fluid.global_position)
	var order := dists.keys()
	order.sort_custom(func(a, b): return dists[a] < dists[b])
	var keep := {}
	for i in range(mini(2, order.size())): # the nearest reaches always run
		keep[order[i]] = true
	for i in order: # plus anything inside the radius
		if dists[i] < _sim_radius * _sim_radius:
			keep[i] = true
	keep[_heat_idx] = true # the heated checkpoint always simulates + steams
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
	var info := _reaches[_scan_reach % _reaches.size()]
	_scan_reach += 1
	var scan_fluid := _reach_fluid(info)
	if not is_instance_valid(scan_fluid) or (_solver_pbd and info.stage != 1):
		return # one shared body: scan it once from the source reach
	if info.stage != 1:
		return
	var pts := scan_fluid.get_particle_positions()
	if pts.is_empty():
		return
	var center := info.fluid.global_position # the domain centers on the node
	var half := info.domain * 0.5 + Vector3.ONE * 0.5
	for p in pts:
		if p.x != p.x or p.y != p.y or p.z != p.z:
			_nan_total += 1
			continue
		if not _solver_pbd:
			var rel := (p - center).abs()
			if rel.x > half.x or rel.y > half.y or rel.z > half.z:
				_escapes += 1
	for body in _floaters:
		if is_instance_valid(body):
			if body.global_position.distance_to(_floater_home[body].origin) > 3.0:
				_obj_moved = true
			if body.linear_velocity.length() > 200.0:
				_nan_total += 1 # velocity blow-up counts against stability

func _fluid_totals() -> Array:
	var totals := [0, 0, 0.0, 0] # particles, foam, step ms, reaches
	if _solver_pbd and is_instance_valid(_river_water):
		# one shared body: report it directly (the per-reach MPM fluids are
		# detached in this mode and would read zero)
		totals[0] = _river_water.get_live_particle_count()
		totals[1] = _river_water.get_live_foam_count()
		totals[3] = 1
		return totals
	for info in _reaches:
		if is_instance_valid(info.fluid):
			totals[0] += info.fluid.get_live_particle_count()
			totals[1] += info.fluid.get_live_foam_count()
			totals[2] += info.fluid.get_mpm_step_msec()
			totals[3] += 1
	return totals

func _capture_shot() -> void:
	var spots := [-1, _heat_idx, _reaches.size() - 1] # overview, heated, basin
	if _shot_idx >= spots.size():
		get_tree().quit()
		return
	var __spots := spots # (guard: only one capture in flight)
	var reach_idx: int = spots[_shot_idx]
	if reach_idx < 0:
		_cam.transform = _overview_xf
	else:
		_cam.position = _reaches[reach_idx].anchor
		_cam.look_at(_reaches[reach_idx].look)
	_sync_fly()
	# let the LOD + camera + discharged water settle before the grab
	await get_tree().create_timer(5.0).timeout
	var img := get_viewport().get_texture().get_image()
	var path := _shots_dir.path_join("river_%d.png" % reach_idx)
	img.save_png(path)
	print("[river] shot -> ", path)
	_shot_idx += 1
	_capturing = false

func _finish_bench() -> void:
	var totals := _fluid_totals()
	var fps := maxf(Engine.get_frames_per_second(), 1.0)
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var fed := 0
	for info in _reaches:
		if info.filled_at >= 0.0:
			fed += 1
	print("[river] bench frames=%d  fps=%.1f  frame_ms=%.2f  mpm_step_ms=%.2f  script_proc=%.1fms  script_phys=%.1fms  particles=%d  foam=%d  sim=%d/%d  outlets_fed=%d/%d  steam=%s  evap=%.0f%%  preset=%s  mode=%s  nan=%d  escapes=%d" % [
			_bench_frame, fps, 1000.0 / fps, totals[2], proc_ms, phys_ms,
			totals[0], totals[1], _sim_active, _reaches.size(), fed, _reaches.size(),
			_steam_status(), _evap_loss * 100.0, _preset, MODES[_mode_idx], _nan_total, _escapes])
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
	return _reaches[best].name()

func _steam_status() -> String:
	return "STEAM %.0f%%" % (_steam_level * 100.0) if _steam_level > 0.08 else "hot (idle)"

func _update_hud() -> void:
	if not _hud_visible:
		return
	var totals := _fluid_totals()
	var fps := Engine.get_frames_per_second()
	var filled := 0
	var last_fill := 0.0
	for info in _reaches:
		if info.filled_at >= 0.0:
			filled += 1
			last_fill = maxf(last_fill, info.filled_at)
	var transit := ""
	if filled == _reaches.size():
		transit = "  outlets fed in %ds" % int(last_fill)
	var state := "PAUSED" if _paused else ("TOUR" if _tour else "FLY")
	var stability := "STABLE" if _nan_total == 0 and _escapes == 0 else "UNSTABLE (nan=%d escapes=%d)" % [_nan_total, _escapes]
	_hud.text = "\n".join([
		"PHYSX GPU RIVER TEST - node-authored river (%s), %d reaches (%d simulating)" % [
			"PhysX PBD pure water" if _solver_pbd else "staged MPM + foam/steam", _reaches.size(), _sim_active],
		"engine=%s  particles=%d  foam=%d  source emit=%.0f/s  mpm step=%.1f ms" % [
			ProjectSettings.get_setting("physics/3d/physics_engine", "?"), totals[0], totals[1],
			_reaches[0].fluid.emission_rate if _reaches.size() > 0 else 0.0, totals[2]],
		"fps=%d (%.1f ms)  preset=%s  mode=%s  %s" % [fps, 1000.0 / maxf(fps, 1), _preset, MODES[_mode_idx], state],
		"flow: %d/%d outlets fed%s  objects moved=%s  %s" % [filled, _reaches.size(), transit, "yes" if _obj_moved else "no", stability],
		"heat: %s  evap loss=%.0f%%" % [_steam_status(), _evap_loss * 100.0],
		"section: %s" % _section_for_camera(),
		"WASD+RMB fly  1-7 sections  C tour  TAB mode  [ ] preset  G objects  P pause  R reset  F hud  ESC",
	])

func _emit_rate_total() -> float:
	var rate := 0.0
	for info in _reaches:
		if is_instance_valid(info.fluid):
			rate += info.fluid.emission_rate
	return rate
