extends SceneTree

# One-shot authoring tool: builds the physx_river course as a NODE TREE and
# saves it to res://demo/gpu/physx_river.tscn. Run once:
#
#   redot --headless --path . -s res://demo/gpu/author_river_tool.gd
#
# COURSE SHAPE -- ONE CONTINUOUS WATER SLIDE from a spring tank at ~98 m down
# to the basin at 0 m. There are no weirs, no plunge pools and no free falls:
# the course is a chain of pitched chute segments whose floor and bank slabs
# OVERLAP their neighbors by ~0.8 m at every joint (static bodies physically
# intersect), so the channel is one unbroken flume. Each segment carries its
# own PhysXParticleFluid3D whose world-aligned MPM domain is sized from the
# segment's world footprint INCLUDING the overlaps, so consecutive domains
# overlap too: water handed off at a seam always sits inside a live domain
# and the body of water reads as continuous. Every segment is prefilled with
# water and its faucet (hidden mid-run, pitched with the channel) emits the
# discharge the previous segment's outlet probe measures -- the slide is full
# from the first frame and stays full. All features (cascade treads,
# boulders, heated plates, split island, constriction, foam-bed pebbles) are
# embedded IN the floor line; nothing floats. No labels.

const W := 1.05 # flume width (head tank / island / basin are wider)
const PS := 0.035
const SEG_LEN := 8.0 # chute length along the slope (steep ones run 9.5)
const OVERLAP := 0.8 # floor/bank/domain overlap past each joint

var scene_root: Node3D
var river: Node3D
var floaters: Node3D
var soft_bodies: Node3D

var mat_bed: StandardMaterial3D
var mat_bank: StandardMaterial3D
var mat_rock: StandardMaterial3D
var mat_wall: StandardMaterial3D
var mat_hot: StandardMaterial3D

var cursor := Vector3(0, 98.5, 0) # floor-line path point (world)
var cur_yaw := 0.0 # radians
var prev_slope_deg := 0.0 # the tank floor is flat
var reach_count := 0
var total_drop := 0.0

# The chute chain (name, slope_deg, yaw kink, flags). Slopes grade from
# near-vertical at the top to a flat drift at the bottom; kinks alternate so
# the course snakes without exceeding ~20 deg of absolute yaw.
const PROFILE := [
	# name, slope_deg, yaw kink, flags, length along the slope
	["Chute01", 58.0, 8.0, "", 9.5],
	["Chute02", 55.0, -10.0, "", 9.5],
	["Chute03", 55.0, 10.0, "", 9.5],
	["Chute04", 54.0, -8.0, "", 9.5],
	["BoulderRun", 52.0, 10.0, "rocks", 9.5],
	["Chute06", 50.0, -10.0, "", 9.5],
	["Cascade", 48.0, 8.0, "steps", 9.5],
	["Chute08", 46.0, -8.0, "", 9.5],
	["Heated", 42.0, 8.0, "heat", 9.5],
	["Chute10", 38.0, -8.0, "", 8.0],
	["Chute11", 34.0, 8.0, "", 8.0],
	["Chute12", 30.0, -8.0, "", 8.0],
	["IslandSplit", 26.0, 8.0, "island", 8.0],
	["Rapids", 22.0, -10.0, "rocks", 7.2],
	["Chute15", 18.0, 8.0, "", 7.2],
	["Constriction", 15.0, -8.0, "pinch", 7.2],
	["FoamBed", 12.0, 8.0, "pebbles", 6.5],
	["SlowRiver1", 10.0, -6.0, "", 6.5],
	["SlowRiver2", 8.0, 6.0, "", 6.5],
	["SlowRiver3", 7.0, -6.0, "", 6.5],
	["FinalChute", 40.0, 0.0, "", 6.5],
]

func _initialize() -> void:
	_make_materials()
	scene_root = Node3D.new()
	scene_root.name = "PhysXRiver"
	scene_root.set_script(load("res://demo/gpu/physx_river.gd"))
	_build_environment(scene_root)

	river = Node3D.new()
	river.name = "River"
	scene_root.add_child(river)
	floaters = Node3D.new()
	floaters.name = "Floaters"
	scene_root.add_child(floaters)
	soft_bodies = Node3D.new()
	soft_bodies.name = "SoftBodies"
	scene_root.add_child(soft_bodies)

	_head_tank()
	for i in range(PROFILE.size()):
		var entry: Array = PROFILE[i]
		# the final chute absorbs the remaining drop so its floor ends at y = 0
		var forced := -1.0
		if i == PROFILE.size() - 1:
			forced = cursor.y
		_chute(entry[0], entry[1], entry[2], String(entry[3]).split(":", false), forced, entry[4])
	# the basin tank (flat, wide, deep) continues that floor at y = 0
	_basin()

	_bake_pbd_groups()
	_build_floaters()
	_build_soft_bodies()
	_build_camera_and_hud()

	_set_owner_recursive(scene_root, scene_root)
	var packed := PackedScene.new()
	packed.pack(scene_root)
	var err := ResourceSaver.save(packed, "res://demo/gpu/physx_river.tscn")
	print("[author] save err=", err, "  reaches=", reach_count,
			"  chute drop=%.1f m" % total_drop, "  basin floor y=", cursor.y)
	quit(0 if err == OK else 1)

# ------------------------------------------------------------------ helpers

func _dir() -> Vector3:
	return Vector3(cos(cur_yaw), 0, -sin(cur_yaw))

func _lat() -> Vector3:
	return Vector3(cos(cur_yaw + PI * 0.5), 0, -sin(cur_yaw + PI * 0.5))

func _make_materials() -> void:
	mat_bed = _mat(Color(0.36, 0.34, 0.31), 1.0)
	mat_bank = _mat(Color(0.44, 0.39, 0.33), 0.95)
	mat_rock = _mat(Color(0.32, 0.31, 0.3), 0.9)
	mat_wall = _mat(Color(0.5, 0.48, 0.45), 0.85)
	mat_hot = _mat(Color(0.25, 0.08, 0.03), 0.6)
	mat_hot.emission_enabled = true
	mat_hot.emission = Color(1.0, 0.35, 0.08)
	mat_hot.emission_energy_multiplier = 2.6

func _mat(albedo: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	return m

func _build_environment(parent: Node3D) -> void:
	var env := WorldEnvironment.new()
	env.name = "Environment"
	var e := Environment.new()
	# bright clear sky -- the whole slide must read top to bottom
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var pm := ProceduralSkyMaterial.new()
	pm.sky_top_color = Color(0.25, 0.5, 0.85)
	pm.sky_horizon_color = Color(0.68, 0.78, 0.88)
	pm.sky_curve = 0.12
	pm.ground_bottom_color = Color(0.35, 0.4, 0.45)
	pm.ground_horizon_color = Color(0.68, 0.78, 0.88)
	pm.sun_angle_max = 30.0
	pm.sun_curve = 0.12
	sky.sky_material = pm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 1.0
	e.ambient_light_energy = 1.1
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	# no distance fog; volumetric fog stays ON so the Flow steam's FogVolume
	# draws (FogVolumes are skipped while volumetric fog is disabled)
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = 0.012
	e.volumetric_fog_albedo = Color(0.95, 0.95, 0.95)
	env.environment = e
	parent.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 350.0
	parent.add_child(sun)

func _slab(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO, slab_name := "") -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = slab_name if slab_name != "" else "Slab%d" % (parent.get_child_count() + 1)
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

func _rock(parent: Node3D, pos: Vector3, radius: float) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = "Rock%d" % (parent.get_child_count() + 1)
	sb.position = pos
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
	mi.material_override = mat_rock
	sb.add_child(mi)
	parent.add_child(sb)
	return sb

func _marker(parent: Node3D, name: String, pos: Vector3, scale := Vector3.ONE) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.position = pos
	n.scale = scale
	parent.add_child(n)
	return n

# ------------------------------------------------------------------ reaches

func _add_fluid(reach: Node3D, local_pos: Vector3, pitch: float, domain: Vector3,
		prefill: Vector3, rate: float, vel: Vector3, grid_res := 0, stiffness := 6000.0) -> void:
	var f := PhysXParticleFluid3D.new()
	f.name = "Fluid"
	f.solver = PhysXParticleFluid3D.SOLVER_MPM # the foam-capable path
	f.spawn_on_ready = true
	f.particle_count = 14000
	f.particle_size = PS # the only measured scale that flows without leaking
	f.viscosity = 0.02 # high viscosity jets particles through floors at impacts
	f.cohesion = 0.02
	f.surface_tension = 0.006
	f.spawn_region_size = prefill
	f.mpm_domain_size = domain
	if grid_res > 0:
		f.mpm_grid_resolution = grid_res # pin the cell size on wide domains
	f.mpm_stiffness = stiffness # deep pools need a stiffer EOS to hold still
	f.mpm_substeps = 3 if stiffness <= 6000.0 else 4
	f.emitting = true
	f.emission_rate = rate
	f.emission_radius = 0.06
	f.emission_velocity = vel
	f.foam_enabled = true
	f.foam_particle_count = 1200
	f.foam_lifetime = 1.2
	f.foam_threshold = 450.0 # foam only at real agitation, not everywhere
	f.foam_buoyancy = 0.9
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	reach.add_child(f)
	f.position = local_pos
	f.rotation = Vector3(0, 0, pitch)

func _finish_reach(reach: Node3D, anchor_local: Vector3, look_local: Vector3) -> void:
	_marker(reach, "Anchor", anchor_local)
	_marker(reach, "Look", look_local)

# World-aligned MPM domain covering the segment's footprint INCLUDING the
# joints overlap, plus water margins. Returns (domain_size, pinned_grid_res).
func _domain_for(head: Vector3, tail: Vector3, mid: Vector3, width: float, seg_name := "?") -> Array:
	var dir3 := (tail - head).normalized()
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for t: float in [-OVERLAP, (tail - head).length() + OVERLAP]:
		var p: Vector3 = head + dir3 * t
		for side in [-1.0, 1.0]:
			var c: Vector3 = p + _lat() * side * (width * 0.5 - 0.02)
			lo = lo.min(c)
			hi = hi.max(c)
	lo.y -= 0.02 # domain bottom AT the floor line: squeezed particles pop
	hi.y += 1.0 # back on top -- under-floor water is geometrically impossible
	var half := (hi - lo) * 0.5
	var center := (hi + lo) * 0.5
	var off := (center - mid).abs() # node sits at the run midpoint
	var domain := Vector3(
			maxf((half.x + off.x) * 2.0, 5.0),
			maxf((half.y + off.y) * 2.0, 8.5),
			maxf((half.z + off.z) * 2.0, 4.5))
	var grid := int(ceil(domain.x / 0.07))
	if grid > 128:
		print("[author] WARN ", seg_name, " domain ", domain, " needs grid ", grid, " > 128 (dx coarsens)")
		grid = 128
	return [domain, grid]

# PBD twin fluid: pure PhysX CUDA water for the M-key toggle -- no foam, no
# domain box (PBD collides with the whole space, so this water flows the slide
# as one body). Authored alongside the MPM fluid; the runtime activates one.
var _pbd_acc := {} # group index -> {aabb: AABB, rate: float}

# Queue a reach's water volume into its PBD group (4 reaches per group fluid:
# 23 CUDA particle systems would each stall the frame on their GPU sync; 6
# merged systems keep the pure-PhysX mode fast while the water still flows
# the whole slide as one body).
func _add_pbd(reach: Node3D, pos: Vector3, pitch: float, region: Vector3, rate: float) -> void:
	var g := reach_count / 4
	var world := _reach_xform(reach) * pos
	var half := region.length() * 0.5
	var box := AABB(world - Vector3.ONE * half, Vector3.ONE * half * 2.0)
	if not _pbd_acc.has(g):
		_pbd_acc[g] = {"aabb": box, "rate": rate}
	else:
		_pbd_acc[g].aabb = _pbd_acc[g].aabb.merge(box)
		_pbd_acc[g].rate = maxf(_pbd_acc[g].rate, rate)
	reach.set_meta("pbd_group", g)

# Bake one PBD fluid per group: spawn region = the group's water volume.
func _bake_pbd_groups() -> void:
	for g in _pbd_acc:
		var box: AABB = _pbd_acc[g].aabb
		var f := PhysXParticleFluid3D.new()
		f.name = "PBDGroup%d" % g
		f.solver = PhysXParticleFluid3D.SOLVER_PBD
		f.foam_enabled = false # pure water: the PBD diffuse layer is engine-disabled
		f.particle_size = 0.1
		f.particle_count = 16000
		f.viscosity = 0.35 # damps the spray on the steep chutes
		f.cohesion = 0.06 # keeps the stream coherent instead of ball-pitting
		f.surface_tension = 0.02
		f.surface_mesh = true # marching-cubes the particles into a water surface
		f.material_override = mat_water # translucent blue, not white beads
		f.spawn_region_size = box.size
		f.spawn_on_ready = true
		f.emitting = true
		f.emission_rate = _pbd_acc[g].rate
		f.emission_radius = 0.12
		f.emission_velocity = Vector3(1.4, -0.8, 0)
		f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		scene_root.add_child(f)
		f.position = box.get_center()
		f.set_meta("group", g)

# The spring tank at the top: the one visible water source, continuous into
# Chute01. The faucet pours visibly from ~1 m above the water.
func _head_tank() -> void:
	var len := 3.2
	var width := 1.8
	var water_y := cursor.y + 0.8
	var head := cursor + _dir() * (len * 0.5)
	var reach := Node3D.new()
	reach.name = "HeadTank"
	reach.position = head
	river.add_child(reach)
	var t := 0.4
	_slab(reach, Vector3(0, -t * 0.5, 0), Vector3(len + 0.04, t, width + 0.8), mat_bed, Vector3.ZERO, "Floor")
	for side in [-1.0, 1.0]:
		_slab(reach, Vector3(0, 0.5, side * (width * 0.5 + 0.22)),
				Vector3(len + 1.8, 1.8, 0.4), mat_bank, Vector3.ZERO, "BankL" if side < 0 else "BankR")
	# the spring: a small stone ring the faucet pours from
	_slab(reach, Vector3(-len * 0.25, 1.15, 0), Vector3(0.9, 0.5, 0.9), mat_rock, Vector3.ZERO, "Spring")
	_marker(reach, "Outlet", Vector3(len * 0.5 + 0.2, 0.25, 0), Vector3(0.9, 0.5, width * 0.9))
	_add_pbd(reach, Vector3(0, 0.5, 0), 0.0, Vector3(len * 0.7, 0.6, width * 0.7), 5200.0)
	_finish_reach(reach, Vector3(-4.0, 3.0, 6.0), Vector3(1.0, 0.2, 0))
	_add_fluid(reach, Vector3(-len * 0.25, 1.85, 0), 0.0, Vector3(5.5, 8.0, 5.0),
			Vector3(1.4, 0.4, 1.3), 5200.0, Vector3(0.6, -2.6, 0))
	reach.get_node("Fluid").particle_count = 22000
	reach_count += 1
	# the tank floor continues into chute 1 at the same height
	# (cursor stays: chute 1 starts at the tank floor line)

# A chute segment: pitched floor + banks overlapping both joints, embedded
# features, outlet probe at the end, and its own pitched fluid whose domain
# covers the segment plus the overlaps. `forced_drop > 0` overrides the slope
# drop (used by the final chute to land the basin floor on y = 0).
func _chute(name: String, slope_deg: float, kink_deg: float, flags: Array, forced_drop := -1.0, seg_len := SEG_LEN) -> void:
	var slope := deg_to_rad(slope_deg)
	var drop := seg_len * sin(slope)
	var run := seg_len * cos(slope)
	if forced_drop > 0.0:
		drop = forced_drop
		run = drop / tan(slope)
	var head := cursor
	var tail := head + _dir() * run + Vector3(0, -drop, 0)
	var mid := (head + tail) * 0.5

	var reach := Node3D.new()
	reach.name = name
	reach.position = mid
	reach.rotation = Vector3(0, cur_yaw, 0)
	if reach_count > 0:
		reach.set_meta("upstream", String(river.get_child(reach_count - 1).name))
	river.add_child(reach)
	reach_count += 1

	var tan_s := tan(slope)
	var pitch := -slope
	# joint seal: a patch pitched at the average of the previous and this
	# segment's slope, sunk under the shared crease -- with the floors now
	# spanning exactly head..tail, this seals float-precision cracks and the
	# wedge under big slope changes
	var avg_slope := deg_to_rad((prev_slope_deg + slope_deg) * 0.5)
	var avg_up := Vector3(sin(avg_slope), cos(avg_slope), 0)
	var joint_local := Vector3(-run * 0.5, drop * 0.5, 0)
	_slab(reach, joint_local - avg_up * 0.175, Vector3(1.7, 0.35, W + 0.3), mat_bed,
			Vector3(0, 0, -avg_slope), "JointPatch")
	# continuous floor + banks, spanning exactly head..tail; steep
	# chutes get taller banks so fast splash stays in the channel
	var bank_h := 1.5 # full-height flume walls; steep dump-ins overflow low banks
	var seg3 := sqrt(run * run + drop * drop) # exact head-to-tail length
	_slab(reach, Vector3(0, -0.175, 0), Vector3(seg3 - 0.06, 0.35, W + 0.6), mat_bed, Vector3(0, 0, pitch), "Floor")
	for side in [-1.0, 1.0]:
		_slab(reach, Vector3(0, bank_h * 0.5 - 0.17, side * (W * 0.5 + 0.18)),
				Vector3(seg3 + 0.7, bank_h, 0.36), mat_bank, Vector3(0, 0, pitch), "BankL" if side < 0 else "BankR")

	# floor features, all embedded in the floor line y(x) = -tan*x
	if "steps" in flags:
		var tread_run := 0.45
		var treads := int(run / tread_run)
		for i in range(treads):
			var x0: float = -run * 0.5 + tread_run * i
			var tread_y: float = -tan_s * x0
			_slab(reach, Vector3(x0 + tread_run * 0.5, tread_y - 0.3, 0),
					Vector3(tread_run + 0.01, 0.6, W), mat_bed, Vector3.ZERO, "Tread%d" % (i + 1))
	if "rocks" in flags:
		var obs := Node3D.new()
		obs.name = "Obstacles"
		reach.add_child(obs)
		for i in range(4):
			var x: float = -run * 0.3 + i * run * 0.2
			var r: float = 0.09 + 0.03 * (i % 3)
			_rock(obs, Vector3(x, -tan_s * x - r * 0.25, (0.3 if i % 2 == 0 else -0.3)), r)
	if "heat" in flags:
		_build_heat(reach, run, tan_s)
	if "island" in flags:
		# wider segment: the island divides the flow; it recombines after --
		# split AND merge inside one continuous body of water
		_slab(reach, Vector3(-run * 0.5 + 0.55, 0.55, -(W * 0.5 + 0.32)), Vector3(1.1, 1.6, 0.4), mat_bank, Vector3(0, -0.4, 0), "WidenL")
		_slab(reach, Vector3(-run * 0.5 + 0.55, 0.55, (W * 0.5 + 0.32)), Vector3(1.1, 1.6, 0.4), mat_bank, Vector3(0, 0.4, 0), "WidenR")
		_slab(reach, Vector3(run * 0.5 - 0.55, -tan_s * (run * 0.5 - 0.55) + 0.55, -(W * 0.5 + 0.32)), Vector3(1.1, 1.6, 0.4), mat_bank, Vector3(0, 0.4, 0), "NarrowL")
		_slab(reach, Vector3(run * 0.5 - 0.55, -tan_s * (run * 0.5 - 0.55) + 0.55, (W * 0.5 + 0.32)), Vector3(1.1, 1.6, 0.4), mat_bank, Vector3(0, -0.4, 0), "NarrowR")
		var island := _slab(reach, Vector3(0.0, -tan_s * 0.0 + 0.16, 0), Vector3(run * 0.55, 0.55, 0.24), mat_wall, Vector3(0, 0, pitch), "Island")
		island.set_meta("island", true)
		var obs2 := Node3D.new()
		obs2.name = "Obstacles"
		reach.add_child(obs2)
		_rock(obs2, Vector3(0.6, -tan_s * 0.6 + 0.02, 0.55), 0.09)
		_rock(obs2, Vector3(1.4, -tan_s * 1.4 + 0.02, 0.6), 0.07)
		_slab(obs2, Vector3(2.1, -tan_s * 2.1 + 0.2, 0.58), Vector3(0.8, 0.6, 0.3), mat_wall, Vector3.ZERO, "SidePinch")
	if "pinch" in flags:
		for side in [-1.0, 1.0]:
			_slab(reach, Vector3(0.0, 0.2, side * (W * 0.5 - 0.32)),
					Vector3(0.9, 0.55, 0.3), mat_wall, Vector3.ZERO, "PinchL" if side < 0 else "PinchR")
	if "pebbles" in flags:
		var obs3 := Node3D.new()
		obs3.name = "Obstacles"
		reach.add_child(obs3)
		for i in range(6):
			var x: float = -run * 0.4 + i * run * 0.16
			var pr: float = 0.05 + 0.012 * (i % 3)
			_rock(obs3, Vector3(x, -tan_s * x - pr * 0.4, (0.3 if i % 2 == 0 else -0.3)), pr)

	# flow meter: mid-segment on chutes (the fast tail film reads too thin),
	# upstream on the gentle tails where the discharge pools
	var meter_x := -run * 0.2 if slope_deg <= 12.0 else 0.0
	_marker(reach, "Outlet", Vector3(meter_x, -tan_s * meter_x + 0.3, 0), Vector3(1.4, 0.45, W * 0.9))
	_finish_reach(reach, Vector3(-3.0, 2.6, 6.0), Vector3(1.0, -1.2, 0))

	# fluid pitched with the chute; domain from the world footprint + overlaps
	# domain sized about the node, which sits just above the floor: the
	# emitter is submerged in the flow film, so a seam never visibly spawns
	var node_pos := mid + Vector3(0, 0.06, 0)
	var dom := _domain_for(head, tail, node_pos, W, name)
	var stiff := 12000.0 if slope_deg <= 15.0 else 6000.0
	# the emitter sits in the flow film; its LOCAL velocity is tilted up by
	# the slope so the WORLD-space emission is horizontal along the channel --
	# the engine staggers each batch along the world velocity (vel * 4 ms * i),
	# and an un-tilted velocity would drive the batch tail into the floor
	var seam_vel := Vector3(cos(slope) * 2.0, sin(slope) * 2.0, 0)
	_add_fluid(reach, Vector3(0, 0.06, 0), pitch, dom[0],
			Vector3(run * 0.85, 0.15, W * 0.6), 4500.0, seam_vel, dom[1], stiff)
	if "heat" in flags:
		reach.get_node("Fluid").particle_count = 16000
	_add_pbd(reach, Vector3(0, 0.06, 0), pitch, Vector3(run * 0.8, 0.45, W * 0.85), 4500.0)

	total_drop += drop
	cursor = tail
	cur_yaw += deg_to_rad(kink_deg)

# The collection basin: a flat, wide, deep tank continuous with the final
# chute; its floor lands on world y = 0 and nothing drains out.
func _basin() -> void:
	var len := 7.0
	var width := 5.0
	var depth := 1.2
	var floor_y := cursor.y # continuous with the final chute's floor
	var head := cursor + _dir() * (len * 0.5)
	var reach := Node3D.new()
	reach.name = "Basin"
	reach.position = head
	reach.rotation = Vector3(0, cur_yaw, 0)
	if reach_count > 0:
		reach.set_meta("upstream", String(river.get_child(reach_count - 1).name))
	river.add_child(reach)
	reach_count += 1

	var t := 0.5
	_slab(reach, Vector3(-len * 0.5 - 0.3, -t * 0.5, 0), Vector3(len + 2.4, t, width + 1.0), mat_bed, Vector3.ZERO, "Floor")
	for side in [-1.0, 1.0]:
		_slab(reach, Vector3(0, 0.9, side * (width * 0.5 + 0.25)),
				Vector3(len + 1.6, 2.6, 0.5), mat_bank, Vector3.ZERO, "BankL" if side < 0 else "BankR")
	_slab(reach, Vector3(len * 0.5 + 0.25, 1.3, 0), Vector3(0.5, 4.0, width + 1.0), mat_bank, Vector3.ZERO, "EndWall")
	# entry funnels widen the channel mouth into the basin
	for side in [-1.0, 1.0]:
		_slab(reach, Vector3(-len * 0.5 + 0.4, 0.5, side * (W * 0.5 + 0.55)),
				Vector3(2.0, 1.4, 0.4), mat_bank, Vector3(0, side * -0.6, 0), "FunnelL" if side < 0 else "FunnelR")
	_marker(reach, "Outlet", Vector3(-len * 0.5 + 0.6, 0.3, 0), Vector3(0.9, 0.5, width * 0.9))
	_add_pbd(reach, Vector3(0, depth * 0.6, 0), 0.0, Vector3(len * 0.8, depth * 0.6, width * 0.8), 4500.0)
	_finish_reach(reach, Vector3(-6.5, 6.5, 11.0), Vector3(0.5, 0.4, 0))
	var dom := _domain_for(cursor, cursor + _dir() * len, head, width, "Basin")
	_add_fluid(reach, Vector3(0, 0.3, 0), 0.0, dom[0], Vector3(len * 0.8, 0.6, width * 0.7),
			2400.0, Vector3(1.2, -1.6, 0), dom[1], 12000.0)
	reach.get_node("Fluid").particle_count = 70000
	reach.set_meta("always_surface", true) # the basin always draws its water surface
	_add_pbd(reach, Vector3(0, depth * 0.6, 0), 0.0, Vector3(len * 0.8, depth * 0.6, width * 0.8), 4500.0)
	reach.get_node("Fluid").particle_count = 24000
	cursor = head + _dir() * len
	cursor.y = floor_y

# The heated checkpoint: emissive plates lying flush IN the channel floor, a
# hot light, the contact probe just above them. Water flowing down the chute
# passes over the plates -- the runtime measures the contact, drives the Flow
# steam plume and throttles the next segment's discharge (evaporation).
func _build_heat(reach: Node3D, run: float, tan_s: float) -> void:
	# a downstream sill dams the emitted film into a heated pool just below
	# the segment's emitter (x 0 .. +1.05 local): the water dwells over the
	# plates, boils visibly, and the evaporation loss downstream is measured
	# from a solid contact read. (No upstream sill: the inflow there is a
	# frozen LOD pile, and sill walls leak under pond pressure at their base
	# corners -- keep the pool on the emitter's downstream side only.)
	_slab(reach, Vector3(1.3, -tan_s * 1.3 + 0.09, 0.0), Vector3(0.5, 0.7, W), mat_bed, Vector3(0, 0, 0.02), "PoolSill")
	for i in range(3):
		var x := 0.35 + i * 0.4
		_slab(reach, Vector3(x, -tan_s * x - 0.045, 0.0), Vector3(0.3, 0.09, W - 0.2), mat_hot, Vector3.ZERO, "HotPlate%d" % (i + 1))
	var light := OmniLight3D.new()
	light.name = "Glow"
	light.position = Vector3(0.7, 0.9, 0.0)
	light.light_color = Color(1.0, 0.45, 0.15)
	light.light_energy = 0.7
	light.omni_range = 2.6
	reach.add_child(light)
	_marker(reach, "HeatProbe", Vector3(0.7, -tan_s * 0.7 + 0.25, 0), Vector3(1.2, 0.45, W - 0.2))

	if not ClassDB.class_exists("PhysXGas3D"):
		return
	# Steam via PhysXGas3D -- the same volumetric solver as the fire-under-roof
	# demo (proven rendering path). Pure white vapor: no fire look.
	var steam := ClassDB.instantiate("PhysXGas3D") as Node3D
	steam.name = "Steam"
	reach.add_child(steam)
	steam.position = Vector3(0.7, 1.1, 0.0)
	steam.set("domain_size", Vector3(4.5, 4.5, 3.0))
	steam.set("cell_size", 0.15)
	steam.set("emitter_velocity", Vector3(0, 16, 0))
	steam.set("buoyancy", 20.0)
	steam.set("vorticity_strength", 6.0)
	steam.set("dissipation", 0.985)
	steam.set("fog_density", 26.0)
	steam.set("fog_albedo", Color(0.92, 0.94, 0.97))
	steam.set("fire_look", false)
	var e := ClassDB.instantiate("PhysXGasEmitter3D") as Node3D
	e.name = "Emitter"
	steam.add_child(e)
	e.position = Vector3(0, -0.8, 0)
	e.set("radius", 0.35)
	e.set("velocity", Vector3(0, 16, 0))
	e.set("density", 4.0) # the runtime gates this on measured water contact
	e.set("divergence", 0.6)
	steam.set("emitters", [steam.get_path_to(e)])

# ----------------------------------------------------------------- floaters

const FLOATER_TABLE := [
	# reach name, kind, offset from the reach origin, size, density
	["HeadTank", "ball", Vector3(0.4, 1.6, 0.2), 0.07, 250.0],
	["HeadTank", "ball", Vector3(0.8, 1.6, -0.2), 0.09, 400.0],
	["BoulderRun", "crate", Vector3(-1.5, 1.0, 0.2), 0.13, 650.0],
	["BoulderRun", "rock", Vector3(1.5, 1.0, -0.2), 0.1, 3200.0],
	["Cascade", "sphere", Vector3(-1.0, 1.0, 0.2), 0.08, 450.0],
	["Heated", "log", Vector3(-1.6, 1.0, 0.0), 0.45, 420.0],
	["IslandSplit", "crate", Vector3(-1.5, 1.0, 0.5), 0.11, 1150.0],
	["Rapids", "ball", Vector3(-1.5, 1.0, -0.2), 0.08, 300.0],
	["Rapids", "log", Vector3(0.5, 1.0, 0.1), 0.4, 400.0],
	["Constriction", "ball", Vector3(-1.5, 1.0, 0.2), 0.09, 260.0],
	["FoamBed", "crate", Vector3(-1.0, 1.0, -0.1), 0.12, 700.0],
	["SlowRiver1", "ball", Vector3(-1.0, 1.0, 0.0), 0.1, 300.0],
	["SlowRiver1", "log", Vector3(0.5, 1.0, 0.15), 0.42, 420.0],
	["SlowRiver2", "buoy", Vector3(-0.5, 1.2, -0.2), 0.11, 240.0],
	["Basin", "crate", Vector3(0.5, 2.2, 0.6), 0.14, 700.0],
	["Basin", "ball", Vector3(-0.8, 2.2, -0.5), 0.1, 300.0],
]

func _reach_by_name(name: String) -> Node3D:
	return river.get_node(NodePath(name))

func _reach_xform(reach: Node3D) -> Transform3D:
	# reach roots carry only yaw; detached nodes have no global transform
	return Transform3D(Basis(Vector3.UP, reach.rotation.y), reach.position)

func _build_floaters() -> void:
	var idx := 0
	var colors := {
		"ball": Color(0.95, 0.8, 0.3), "sphere": Color(0.35, 0.65, 0.95),
		"buoy": Color(0.95, 0.55, 0.15), "crate": Color(0.72, 0.55, 0.3),
		"log": Color(0.55, 0.38, 0.2), "rock": Color(0.3, 0.29, 0.28),
	}
	for entry in FLOATER_TABLE:
		idx += 1
		var body := RigidBody3D.new()
		body.name = entry[1].capitalize() + "%02d" % idx
		body.can_sleep = false
		body.continuous_cd = true
		body.linear_damp = 0.05
		body.angular_damp = 0.1
		var size: float = entry[3]
		var density: float = entry[4]
		var volume := 1.0
		var cs := CollisionShape3D.new()
		var mi := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colors[entry[1]]
		mat.roughness = 0.5
		match entry[1]:
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
			"crate":
				volume = pow(size, 3.0)
				body.mass = density * volume
				var box := BoxShape3D.new()
				box.size = Vector3.ONE * size
				cs.shape = box
				var bm := BoxMesh.new()
				bm.size = Vector3.ONE * size
				mi.mesh = bm
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
		mi.material_override = mat
		body.add_child(cs)
		body.add_child(mi)
		body.set_meta("volume", volume)
		var reach := _reach_by_name(entry[0])
		body.position = _reach_xform(reach) * (entry[2] as Vector3)
		floaters.add_child(body)

# Soft bodies: a separate deformable-body test -- the PhysX backend has no
# fluid/soft coupling, so these ride no water; they deform against geometry.
func _build_soft_bodies() -> void:
	var basin := _reach_by_name("Basin")
	var slow := _reach_by_name("SlowRiver2")

	var blob_a := SoftBody3D.new()
	blob_a.name = "BlobSphere"
	var sm := SphereMesh.new()
	sm.radius = 0.42
	sm.height = 0.84
	sm.radial_segments = 14
	sm.rings = 9
	blob_a.mesh = sm
	blob_a.total_mass = 1.4
	blob_a.simulation_precision = 10
	blob_a.pressure_coefficient = 50.0
	blob_a.linear_stiffness = 0.8
	blob_a.ray_pickable = false
	var mat_a := StandardMaterial3D.new()
	mat_a.albedo_color = Color(0.8, 0.4, 0.9)
	mat_a.roughness = 0.5
	mat_a.cull_mode = BaseMaterial3D.CULL_DISABLED
	blob_a.material_override = mat_a
	blob_a.position = _reach_xform(basin) * Vector3(-0.8, 2.6, 0.5)
	soft_bodies.add_child(blob_a)

	var blob_b := SoftBody3D.new()
	blob_b.name = "BlobBox"
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * 0.8
	bm.subdivide_width = 3
	bm.subdivide_height = 3
	bm.subdivide_depth = 3
	blob_b.mesh = bm
	blob_b.total_mass = 1.6
	blob_b.simulation_precision = 10
	blob_b.pressure_coefficient = 55.0
	blob_b.linear_stiffness = 0.8
	blob_b.ray_pickable = false
	var mat_b := StandardMaterial3D.new()
	mat_b.albedo_color = Color(0.3, 0.8, 0.7)
	mat_b.roughness = 0.5
	mat_b.cull_mode = BaseMaterial3D.CULL_DISABLED
	blob_b.material_override = mat_b
	blob_b.position = _reach_xform(slow) * Vector3(0.5, 1.6, 0.3)
	soft_bodies.add_child(blob_b)

func _build_camera_and_hud() -> void:
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.far = 2000.0
	scene_root.add_child(cam)
	var aabb := AABB(river.get_child(0).position, Vector3.ZERO)
	for reach in river.get_children():
		aabb = aabb.expand(reach.position)
	aabb = aabb.expand(cursor)
	var center := aabb.get_center()
	var eye := center + Vector3(0.55, 0.42, 0.55) * maxf(aabb.size.length() * 0.75, 60.0)
	cam.transform = Transform3D(Basis.looking_at((center - eye).normalized(), Vector3.UP), eye)

	var hud := CanvasLayer.new()
	hud.name = "HUD"
	scene_root.add_child(hud)
	var label := Label.new()
	label.name = "Label"
	label.position = Vector2(16, 12)
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.text = "starting..."
	hud.add_child(label)

func _set_owner_recursive(node: Node, owner: Node) -> void:
	if node != owner:
		node.owner = owner
	for child in node.get_children():
		_set_owner_recursive(child, owner)
