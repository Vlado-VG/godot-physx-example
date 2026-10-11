extends SceneTree

# U26 regression (godot-physx-example#1): a property set on a LIVE vehicle
# rebuilds it, and the rebuild used to read the wheels' current transforms --
# the simulated pose the vehicle writes onto them every tick (suspension,
# steer, spin) -- as their mounting poses: one rebuild mid-turn left a car
# 0.22 m low and tilted. Car A is an untouched control; car B drives and
# steers, gets max_engine_torque changed mid-turn, then stops. Once both have
# settled, B must sit like A.

var _a: PhysXVehicle3D
var _b: PhysXVehicle3D
var _t := 0

func _car(x: float) -> PhysXVehicle3D:
	var car := PhysXVehicle3D.new()
	car.position = Vector3(x, 0.6, 0)
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(1.9, 0.8, 3.7)
	cs.shape = sh
	cs.position = Vector3(0, 0.4, 0)
	car.add_child(cs)
	for p in [Vector3(-0.75, 0.05, 1.35), Vector3(0.75, 0.05, 1.35), Vector3(-0.75, 0.05, -1.35), Vector3(0.75, 0.05, -1.35)]:
		var w := PhysXVehicleWheel3D.new()
		w.position = p
		w.use_as_steering = p.z > 0.0
		car.add_child(w)
	get_root().add_child(car)
	return car

func _initialize() -> void:
	var f := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(600, 1, 600)
	cs.shape = b
	f.add_child(cs)
	f.position = Vector3(0, -0.5, 0)
	get_root().add_child(f)
	_a = _car(-20)
	_b = _car(20)
	physics_frame.connect(_tick)

func _wheel_ys(car: PhysXVehicle3D) -> Array:
	var ys := []
	for w in car.get_children():
		if w is PhysXVehicleWheel3D:
			ys.append(w.position.y)
	return ys

func _tick() -> void:
	_t += 1
	if _t <= 150:
		_b.throttle = 0.6
		_b.steer = 0.6
	if _t == 150:
		_b.max_engine_torque = _b.max_engine_torque + 1.0 # any property set rebuilds a live vehicle
	if _t > 150:
		_b.throttle = 0.0
		_b.steer = 0.0
		_b.brake = 1.0
	if _t < 450:
		return
	var dy := _b.global_position.y - _a.global_position.y
	var tilt := _b.global_transform.basis.y.y
	var ya := _wheel_ys(_a)
	var yb := _wheel_ys(_b)
	var worst := 0.0
	for i in ya.size():
		worst = max(worst, abs(yb[i] - ya[i]))
	print("[live_rebuild] settled: chassis height diff %.3f m, tilt up.y %.4f, worst wheel height diff %.3f m" % [dy, tilt, worst])
	if abs(dy) < 0.02 and tilt > 0.999 and worst < 0.02:
		print("[live_rebuild] PASS -- a vehicle rebuilt mid-turn settles like an untouched one")
		quit(0)
	else:
		print("[live_rebuild] FAIL: the rebuild used the wheels' simulated poses")
		quit(1)
