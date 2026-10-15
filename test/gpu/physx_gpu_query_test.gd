extends SceneTree

# PhysX.is_gpu_available() / PhysX.get_gpu_device_name() (R2). Checked against
# something observable instead of the hardware: a PBD fluid only gets live
# particles when GPU dynamics really runs, so the query must agree with it, and
# the device name is non-empty exactly when the query is true. Runs headless.

var _fluid: Node3D
var _tick := 0


func _initialize() -> void:
	if not ClassDB.class_exists("PhysX"):
		print("[gpu_query] no PhysX class -> FAIL")
		quit(1)
		return
	print("[gpu_query] engine = %s  is_gpu_available = %s  device = '%s'" % [
		ProjectSettings.get_setting("physics/3d/physics_engine", "?"), PhysX.is_gpu_available(), PhysX.get_gpu_device_name()])
	var root := Node3D.new()
	get_root().add_child(root)
	_fluid = ClassDB.instantiate("PhysXParticleFluid3D")
	_fluid.set("solver", 1) # SOLVER_PBD: GPU only, never falls back
	_fluid.set("particle_count", 500)
	root.add_child(_fluid)


func _physics_process(_d: float) -> bool:
	_tick += 1
	if _tick < 10:
		return false
	var gpu := PhysX.is_gpu_available()
	var name := PhysX.get_gpu_device_name()
	var live: int = _fluid.get_live_particle_count()
	var ok := (gpu == (live > 0)) and (gpu == (name != ""))
	print("[gpu_query] PBD live particles %d, is_gpu_available %s, device '%s' -> %s" % [live, gpu, name, "PASS" if ok else "FAIL"])
	quit(0 if ok else 1)
	return true
