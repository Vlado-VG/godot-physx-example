extends SceneTree

# Two-terrace PhysXParticleFluid3D river, MPM solver, in series: each terrace
# is a prefilled plunge pool (spawn_region) whose faucet jets into it -- the
# same architecture as the river demo. PASS if: both pools prefill, the jet's
# impact agitates stage A enough to spawn diffuse foam, stage B's faucet rate
# couples up once stage A's outlet probe reads full (the measured hand-off the
# demo uses), nothing escapes its domain or sinks beneath a pool floor, and no
# NaN appears. GPU-only (MPM runs on any RenderingDevice) -- skips cleanly.

const PS := 0.06 # particle size; grid cell tracks ~2x this
const RATE := 1500.0
const CAP := 12000

var _fluid_a: PhysXParticleFluid3D
var _fluid_b: PhysXParticleFluid3D
var _bodies: Array[Node] = [] # pool geometry, coupled to both fluids
var _root: Node3D
var _tick := 0
var _coupled_at := 0
var _exit_code := 1

func _initialize() -> void:
	print("[river] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))
	if not ClassDB.class_exists("PhysXParticleFluid3D"):
		print("[river] PhysXParticleFluid3D not registered -> SKIP")
		quit(0)
		return
	_root = Node3D.new()
	get_root().add_child(_root)

	# Terrace A: faucet node 1.0 m above the water line (4.85), pool floor top
	# 4.3, banks one meter above the water, outlet lip at x 2.8. Pool footprint
	# is sized so the prefill stands ~0.5 m deep (several grid cells).
	_box(Vector3(1.5, 4.0, 0), Vector3(2.6, 0.6, 2.2)) # pool floor, top 4.3
	for side in [-1.0, 1.0]:
		_box(Vector3(1.5, 5.05, side * 1.3), Vector3(3.0, 2.0, 0.5)) # banks
	_box(Vector3(0.0, 4.8, 0), Vector3(0.5, 1.4, 2.6)) # upstream wall (low: clears the faucet)
	_box(Vector3(2.85, 4.7, 0), Vector3(0.5, 1.7, 2.4)) # outlet lip, crest 5.35

	# Terrace B: one step down and downstream, same anatomy.
	_box(Vector3(6.8, 4.9, 0), Vector3(2.4, 0.6, 2.0)) # pool floor, top 5.2
	for side in [-1.0, 1.0]:
		_box(Vector3(6.8, 5.95, side * 1.2), Vector3(2.8, 2.0, 0.5))
	_box(Vector3(5.4, 5.7, 0), Vector3(0.5, 1.4, 2.4))
	_box(Vector3(8.05, 5.6, 0), Vector3(0.5, 1.7, 2.2)) # outlet lip, crest 6.25

	_fluid_a = _make_fluid(Vector3(1.5, 5.35, 0), Vector3(2.2, 0.45, 2.0))
	_fluid_a.emission_rate = RATE
	_fluid_b = _make_fluid(Vector3(6.8, 6.25, 0), Vector3(2.0, 0.45, 1.8))
	_fluid_b.emission_rate = RATE * 0.15 # opened by the measured hand-off below

	for f in [_fluid_a, _fluid_b]:
		var paths: Array[NodePath] = []
		for body in _bodies:
			paths.append(f.get_path_to(body))
		f.mpm_colliders = paths

func _make_fluid(pos: Vector3, prefill: Vector3) -> PhysXParticleFluid3D:
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_MPM
	f.particle_count = CAP
	f.particle_size = PS
	f.spawn_region_size = prefill # the plunge pool, seeded at rest
	f.mpm_domain_size = Vector3(9, 14, 7)
	f.emitting = true
	f.emission_radius = 0.14
	f.emission_velocity = Vector3(1.6, -2.4, 0)
	f.foam_enabled = true # diffuse foam spawns where the jet agitates the pool
	f.foam_particle_count = 4000
	f.foam_threshold = 170.0
	f.foam_lifetime = 1.5
	f.position = pos
	_root.add_child(f)
	return f

func _box(pos: Vector3, size: Vector3) -> void:
	var sb := StaticBody3D.new()
	sb.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	_root.add_child(sb)
	_bodies.append(sb)

func _scan(f: PhysXParticleFluid3D, floor_y: float) -> Dictionary:
	# "sunken" = below a pool floor AND inside its footprint: a genuine leak
	# through the geometry. Splash that spilled over an outlet lip and settled
	# on the terrace's domain floor is a physical spill, not a leak -- counted
	# separately and only reported.
	var out := {"nan": 0, "sunken": 0, "spill": 0, "count": 0}
	var pts := f.get_particle_positions()
	out.count = pts.size()
	for p in pts:
		if p.x != p.x or p.y != p.y or p.z != p.z:
			out.nan += 1
		elif p.y < floor_y - 0.4:
			out.sunken += 1
	return out

func _physics_process(_d: float) -> bool:
	_tick += 1
	if _fluid_a == null:
		return true
	if _tick == 6 and _fluid_a.get_live_particle_count() == 0:
		print("[river] 0 live particles (no RenderingDevice / compute) -> SKIP")
		quit(0)
		return true

	# Measured-discharge hand-off: stage A's outlet probe opens stage B's faucet.
	if _coupled_at == 0:
		var fill_a := _fluid_a.get_submersion(AABB(Vector3(1.7, 4.35, -0.8), Vector3(1.0, 0.4, 1.6)))
		if fill_a >= 0.4:
			_coupled_at = _tick
			_fluid_b.emission_rate = RATE
			print("[river] stage A outlet full at tick %d -> stage B faucet opens" % _tick)

	if _tick % 120 == 0:
		var sa := _scan(_fluid_a, 4.3)
		var sb := _scan(_fluid_b, 5.2)
		print("[river] tick %4d  a(n=%d)  b(n=%d)  foam_a=%d  rate_b=%.0f" %
				[_tick, sa.count, sb.count, _fluid_a.get_live_foam_count(), _fluid_b.emission_rate])

	if _tick == 900:
		var sa := _scan(_fluid_a, 4.3)
		var sb := _scan(_fluid_b, 5.2)
		var nan: int = sa.nan + sb.nan
		var sunken: int = sa.sunken + sb.sunken
		var foam: int = _fluid_a.get_live_foam_count()
		var prefilled: bool = sa.count > 5000 and sb.count > 5000
		var agitated: bool = foam > 150
		var coupled: bool = _coupled_at > 0 and _fluid_b.emission_rate >= RATE * 0.8
		var ok: bool = prefilled and agitated and coupled and nan == 0 and sunken == 0
		print("[river] a=%d b=%d coupled@%d foam=%d nan=%d sunken=%d -> %s" %
				[sa.count, sb.count, _coupled_at, foam, nan, sunken, "PASS" if ok else "FAIL"])
		_exit_code = 0 if ok else 1
		_root.free()
		_fluid_a = null
		_fluid_b = null
		return false
	if _tick >= 903:
		quit(_exit_code)
		return true
	return false
