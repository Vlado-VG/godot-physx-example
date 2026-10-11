extends SceneTree

# PhysXParticleFluid3D.gravity_scale and .adhesion (bound on the node; the server
# already had them):
#  1. PBD: gravity_scale = 0 floats where it spawned; gravity_scale = 1 falls.
#  2. MPM: the same (the solver takes it at configure, i.e. at spawn).
#  3. adhesion is bound and round-trips. Its effect isn't asserted: PhysX's particle
#     adhesion doesn't act yet (known issue -- see the adhesion doc); add a cling
#     check here when it does.
# The fluids sit 10 m apart so they never meet. Needs a windowed run (MPM has no
# compute RenderingDevice headless) and a CUDA device for PBD -- skips otherwise.

const SPAWN_Y := 4.0

var _pbd_float: PhysXParticleFluid3D
var _pbd_fall: PhysXParticleFluid3D
var _mpm_float: PhysXParticleFluid3D
var _mpm_fall: PhysXParticleFluid3D
var _tick := 0


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXParticleFluid3D"):
		print("[fluid_params] PhysXParticleFluid3D not registered -> SKIP")
		quit(0)
		return
	for prop in ["gravity_scale", "adhesion"]:
		if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_" + prop):
			print("[fluid_params] PhysXParticleFluid3D has no %s -> FAIL" % prop)
			quit(1)
			return
	var root := Node3D.new()
	get_root().add_child(root)
	_pbd_float = _pbd(root, Vector3(-15, SPAWN_Y, 0), 0.0)
	_pbd_fall = _pbd(root, Vector3(-5, SPAWN_Y, 0), 1.0)
	_mpm_float = _mpm(root, Vector3(5, SPAWN_Y, 0), 0.0)
	_mpm_fall = _mpm(root, Vector3(15, SPAWN_Y, 0), 1.0)
	_pbd_fall.adhesion = 2.5


func _pbd(root: Node3D, pos: Vector3, gscale: float) -> PhysXParticleFluid3D:
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_PBD
	f.particle_count = 2000
	f.particle_size = 0.08
	f.spawn_region_size = Vector3(0.8, 0.5, 0.8)
	f.gravity_scale = gscale
	f.position = pos
	root.add_child(f)
	return f


func _mpm(root: Node3D, pos: Vector3, gscale: float) -> PhysXParticleFluid3D:
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_MPM
	f.particle_count = 8000
	f.particle_size = 0.05
	f.spawn_region_size = Vector3(0.8, 0.8, 0.8)
	f.mpm_domain_size = Vector3(3, 9, 3)
	f.gravity_scale = gscale
	f.position = pos
	root.add_child(f)
	return f


func _mean_y(f: PhysXParticleFluid3D) -> float:
	var pts := f.get_particle_positions()
	if pts.is_empty():
		return NAN
	var s := 0.0
	for p in pts:
		s += p.y
	return s / pts.size()


func _physics_process(_d: float) -> bool:
	_tick += 1
	if _tick == 6 and (_pbd_fall.get_live_particle_count() == 0 or _mpm_fall.get_live_particle_count() == 0):
		print("[fluid_params] no live particles (no CUDA device, or headless without compute) -> SKIP")
		quit(0)
		return true
	if _tick % 30 == 0:
		print("[fluid_params] tick %3d  pbd float %.2f fall %.2f | mpm float %.2f fall %.2f" % [
			_tick, _mean_y(_pbd_float), _mean_y(_pbd_fall), _mean_y(_mpm_float), _mean_y(_mpm_fall)])
	if _tick == 120:
		var ok := true
		# 2 s at full gravity drops ~20 m (PBD has no floor; MPM stops at its domain floor 4.5 m down).
		ok = _check("PBD gravity_scale 0 floats", absf(_mean_y(_pbd_float) - SPAWN_Y) < 0.5) and ok
		ok = _check("PBD gravity_scale 1 falls", _mean_y(_pbd_fall) < SPAWN_Y - 5.0) and ok
		ok = _check("MPM gravity_scale 0 floats", absf(_mean_y(_mpm_float) - SPAWN_Y) < 0.5) and ok
		ok = _check("MPM gravity_scale 1 falls", _mean_y(_mpm_fall) < SPAWN_Y - 1.0) and ok
		ok = _check("adhesion round-trips", is_equal_approx(_pbd_fall.adhesion, 2.5)) and ok
		print("[fluid_params] -> %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
	return false


func _check(what: String, cond: bool) -> bool:
	print("[fluid_params]   %s: %s" % [what, "ok" if cond else "FAILED"])
	return cond
