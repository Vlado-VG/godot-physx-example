extends SceneTree

# Phase 1 probe for sample-point buoyancy (demo/common/buoyant_body.gd), no
# rendering/waves involved yet -- just proves a plain RigidBody3D floats:
# dropped from above the water, it must decelerate, settle near the
# waterline (not sink to some arbitrary floor, not rocket off), and never
# NaN.

var _hull: RigidBody3D
var _t := 0
const WATER_LEVEL := 0.0
const START_Y := 4.0

func _initialize() -> void:
	print("[buoy] engine=%s" % ProjectSettings.get_setting("physics/3d/physics_engine", "?"))
	var root := Node3D.new()
	get_root().add_child(root)

	_hull = RigidBody3D.new()
	_hull.set_script(load("res://demo/common/buoyant_body.gd"))
	_hull.mass = 50.0
	_hull.water_level = WATER_LEVEL
	_hull.buoyancy_strength = 400.0 # tuned so a 50kg hull with 4 sample points settles a bit below the waterline, not fully out
	_hull.water_drag = 100.0 # near-critical damping for this mass/stiffness (k=1600, m=50 -> c_crit~566 total, ~141/point)

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 1, 2)
	cs.shape = box
	_hull.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.mesh.size = box.size
	_hull.add_child(mi)

	_hull.position = Vector3(0, START_Y, 0)
	root.add_child(_hull)

	await process_frame
	print("[buoy] start pos=", _hull.global_position)
	physics_frame.connect(_tick)

func _tick() -> void:
	_t += 1
	var p := _hull.global_position
	if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
		print("[buoy] FAIL: position went NaN at t+%d" % _t)
		quit(1)
		return
	if absf(p.y) > 100.0:
		print("[buoy] FAIL: hull flew off, y=%.2f at t+%d" % [p.y, _t])
		quit(1)
		return

	if _t % 30 == 0:
		print("[buoy] t+%d pos=%s lin_vel=%s" % [_t, p, _hull.linear_velocity])

	if _t == 300:
		var settled_near_water := absf(p.y - WATER_LEVEL) < 1.0 # within a meter of the waterline for this hull size
		var speed := _hull.linear_velocity.length()
		var calm := speed < 0.5
		print("[buoy] t+300 final pos=%s speed=%.3f -> settled_near_water=%s calm=%s" % [p, speed, settled_near_water, calm])
		var passed := settled_near_water and calm
		if passed:
			print("[buoy] PASS -- hull floated and settled near the waterline")
			quit(0)
		else:
			print("[buoy] FAIL -- did not settle calmly near the waterline")
			quit(1)
