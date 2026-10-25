extends SceneTree

# PhysXParticleFluid3D.surface_friction (PBD): a pour onto a floor stays a
# pool at the default, where at 0.05 (the fixed value it used to be) particles
# slid away across the floor one by one. Two identical pours, 10 m apart; the
# share of the particles on the floor more than 1 m from the pour.
# Needs a window and a CUDA device (PBD) -- skips otherwise:
#   godot --path . --script res://test/gpu/particle_fluid_friction_test.gd

const FRAMES := 720

var _t := 0
var _default: PhysXParticleFluid3D
var _slick: PhysXParticleFluid3D


func _pour(x: float) -> PhysXParticleFluid3D:
	var f := PhysXParticleFluid3D.new()
	f.solver = PhysXParticleFluid3D.SOLVER_PBD
	f.particle_count = 10000
	f.particle_size = 0.02
	f.spawn_on_ready = false
	f.emitting = true
	f.emission_rate = 1500.0
	f.emission_radius = 0.11
	f.emission_velocity = Vector3(0, -2.5, 0)
	f.position = Vector3(x, 2.2, 0)
	get_root().add_child(f)
	return f


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_surface_friction"):
		print("[fluid_friction] SKIP: this engine build has no surface_friction yet")
		quit(0)
		return
	var fb := StaticBody3D.new()
	var fc := CollisionShape3D.new()
	var fs := BoxShape3D.new()
	fs.size = Vector3(30, 1, 30)
	fc.shape = fs
	fb.add_child(fc)
	fb.position = Vector3(0, -0.5, 0)
	get_root().add_child(fb)
	_default = _pour(-5.0)
	_slick = _pour(5.0)
	_slick.set("surface_friction", 0.05) # set(): keeps the script parseable on builds without the property
	process_frame.connect(_frame)


func _far(f: PhysXParticleFluid3D) -> float:
	var ground := 0
	var far := 0
	for p in f.get_particle_positions():
		if p.y > 0.15:
			continue
		ground += 1
		if Vector2(p.x - f.position.x, p.z - f.position.z).length() > 1.0:
			far += 1
	return float(far) / maxi(ground, 1)


func _frame() -> void:
	_t += 1
	if _t == 10 and _default.get_live_particle_count() == 0:
		print("[fluid_friction] no live particles (no CUDA device) -> SKIP")
		quit(0)
		return
	if _t == FRAMES:
		var d := _far(_default)
		var s := _far(_slick)
		var friction: float = _default.get("surface_friction")
		var ok := is_equal_approx(friction, 0.2) and d < 0.01 and s > d + 0.01
		print("[fluid_friction] share of the pool more than 1 m out after %.0f s: surface_friction %.2f -> %.3f, 0.05 -> %.3f" % [FRAMES / 60.0, friction, d, s])
		print("[fluid_friction] ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
