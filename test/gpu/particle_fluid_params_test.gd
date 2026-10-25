extends SceneTree

# PhysXParticleFluid3D.gravity_scale and .adhesion (bound on the node; the server
# already had them):
#  1. PBD: gravity_scale = 0 floats where it spawned; gravity_scale = 1 falls.
#  2. MPM: the same (the solver takes it at configure, i.e. at spawn).
#  3. adhesion is bound and round-trips.
#  4. adhesion holds: a one-particle film just under a ceiling hangs there at
#     adhesion 1 and drips off at 0 (PhysX's adhesion radius scale defaults to 0,
#     which made adhesion do nothing until the module set it).
# The fluids sit 10 m apart so they never meet. Needs a windowed run (MPM has no
# compute RenderingDevice headless) and a CUDA device for PBD -- skips otherwise.

const SPAWN_Y := 4.0

var _pbd_float: PhysXParticleFluid3D
var _pbd_fall: PhysXParticleFluid3D
var _mpm_float: PhysXParticleFluid3D
var _mpm_fall: PhysXParticleFluid3D
var _film_dry: PhysXParticleFluid3D
var _film_sticky: PhysXParticleFluid3D
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
	_film_dry = _film(root, Vector3(-5, SPAWN_Y, 10), 0.0)
	_film_sticky = _film(root, Vector3(5, SPAWN_Y, 10), 1.0)


# A static ceiling with its face at y = p_ceiling.y, and one layer of PBD fluid
# spawned just under it, within contact range.
func _film(root: Node3D, p_ceiling: Vector3, p_adhesion: float) -> PhysXParticleFluid3D:
	var ceiling := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3, 0.5, 3)
	cs.shape = box
	ceiling.add_child(cs)
	ceiling.position = p_ceiling + Vector3(0, 0.25, 0)
	root.add_child(ceiling)
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_PBD
	f.particle_count = 400
	f.particle_size = 0.08
	f.spawn_region_size = Vector3(1.5, 0.08, 1.5)
	f.adhesion = p_adhesion
	f.position = p_ceiling - Vector3(0, 0.078, 0) # rest distance 0.067, plus the spawn jitter
	root.add_child(f)
	return f


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
		ok = _check("adhesion 0: the film drips off the ceiling (mean y %.2f)" % _mean_y(_film_dry), _mean_y(_film_dry) < SPAWN_Y - 1.0) and ok
		ok = _check("adhesion 1: the film hangs on the ceiling (mean y %.2f)" % _mean_y(_film_sticky), _mean_y(_film_sticky) > SPAWN_Y - 0.15) and ok
		print("[fluid_params] -> %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
	return false


func _check(what: String, cond: bool) -> bool:
	print("[fluid_params]   %s: %s" % [what, "ok" if cond else "FAILED"])
	return cond
