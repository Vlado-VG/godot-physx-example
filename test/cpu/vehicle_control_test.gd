extends SceneTree

# R1: RigidBody3D-style control of the PhysX vehicles, for autopilots and world
# forces. For the car, the motorcycle and the tank:
#   set_linear_velocity / set_angular_velocity take effect;
#   apply_central_impulse changes the velocity by impulse / mass;
#   apply_central_force held upward lifts the vehicle off the ground;
#   teleport(transform) moves it there at once, at rest, without a rebuild
#   (same chassis actor), and it still drives afterwards.
# For the car also: handbrake stops a rolling car sooner than coasting, and a
# low tire_grip (live, no rebuild) lets a car pushed sideways slide much further.

var _car: PhysXVehicle3D
var _moto: PhysXMotorcycle3D
var _tank: PhysXTank3D
var _coast: PhysXVehicle3D
var _hand: PhysXVehicle3D
var _grip: PhysXVehicle3D
var _slip: PhysXVehicle3D
var _t := 0
var _ok := true
var _mark := {}


func _check(cond: bool, msg: String) -> void:
	print("[control] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _floor() -> void:
	var f := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(800, 1, 800)
	cs.shape = b
	f.add_child(cs)
	f.position = Vector3(0, -0.5, 0)
	get_root().add_child(f)


func _box(size: Vector3, y: float) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	cs.position = Vector3(0, y, 0)
	return cs


func _make_car(x: float) -> PhysXVehicle3D:
	var car := PhysXVehicle3D.new()
	car.position = Vector3(x, 0.6, 0)
	car.add_child(_box(Vector3(1.9, 0.8, 3.7), 0.4))
	for p in [Vector3(-0.75, 0.05, 1.35), Vector3(0.75, 0.05, 1.35), Vector3(-0.75, 0.05, -1.35), Vector3(0.75, 0.05, -1.35)]:
		var w := PhysXVehicleWheel3D.new()
		w.position = p
		w.use_as_steering = p.z > 0.0
		car.add_child(w)
	get_root().add_child(car)
	return car


func _make_moto(x: float) -> PhysXMotorcycle3D:
	var moto := PhysXMotorcycle3D.new()
	moto.position = Vector3(x, 0.6, 0)
	moto.add_child(_box(Vector3(0.4, 0.6, 1.8), 0.5))
	for z in [0.75, -0.75]:
		var w := PhysXVehicleWheel3D.new()
		w.position = Vector3(0, 0.05, z)
		w.use_as_steering = z > 0.0
		moto.add_child(w)
	get_root().add_child(moto)
	return moto


func _make_tank(x: float) -> PhysXTank3D:
	var tank := PhysXTank3D.new()
	tank.position = Vector3(x, 0.6, 0)
	tank.add_child(_box(Vector3(2.4, 1.2, 6.0), 0.9))
	for wx in [-1.2, 1.2]:
		for z in [-1.5, -0.5, 0.5, 1.5]:
			var w := PhysXVehicleWheel3D.new()
			w.position = Vector3(wx, 0.1, z)
			w.radius = 0.35
			w.half_width = 0.12
			w.wheel_mass = 15.0
			w.wheel_moment_of_inertia = 1.2
			w.damping_rate = 0.15
			w.suspension_travel = 0.15
			w.suspension_stiffness = 60000.0
			w.suspension_damping = 5000.0
			w.tire_lateral_stiffness = 30000.0
			w.tire_longitudinal_stiffness = 40000.0
			w.tire_friction = 1.4
			tank.add_child(w)
	get_root().add_child(tank)
	return tank


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXVehicle3D", "teleport"):
		print("[control] PhysXVehicle3D has no teleport -> FAIL")
		quit(1)
		return
	_floor()
	_car = _make_car(-80)
	_moto = _make_moto(-40)
	_tank = _make_tank(0)
	_coast = _make_car(40)
	_hand = _make_car(60)
	_grip = _make_car(100)
	_slip = _make_car(130)
	physics_frame.connect(_tick)


func _vehicles() -> Array:
	return [["car", _car], ["moto", _moto], ["tank", _tank]]


func _tick() -> void:
	_t += 1
	match _t:
		60:
			# Velocities, straight in.
			for pair in _vehicles():
				pair[1].set_linear_velocity(Vector3(0, 0, 4))
				pair[1].set_angular_velocity(Vector3(0, 0.5, 0))
				_check(pair[1].get_linear_velocity().distance_to(Vector3(0, 0, 4)) < 0.01, "%s: set_linear_velocity reads back" % pair[0])
				_check(absf(pair[1].get_angular_velocity().y - 0.5) < 0.01, "%s: set_angular_velocity reads back" % pair[0])
			# The car tests' rolling starts.
			for c in [_coast, _hand]:
				c.set_linear_velocity(Vector3(0, 0, 10))
				_mark[c] = c.global_position.z
			_hand.handbrake = 1.0
			_slip.tire_grip = 0.05
			for c in [_grip, _slip]:
				c.set_linear_velocity(Vector3(6, 0, 0))
				_mark[c] = c.global_position.x
		70:
			for pair in _vehicles():
				pair[1].set_linear_velocity(Vector3.ZERO)
				pair[1].set_angular_velocity(Vector3.ZERO)
		90:
			# An impulse of mass * 3 sideways: +3 m/s.
			for pair in _vehicles():
				var v: Node = pair[1]
				var before: Vector3 = v.get_linear_velocity()
				v.apply_central_impulse(Vector3(v.mass * 3.0, 0, 0))
				_mark[v] = before
		91:
			for pair in _vehicles():
				var dv: float = pair[1].get_linear_velocity().x - _mark[pair[1]].x
				_check(absf(dv - 3.0) < 0.6, "%s: apply_central_impulse(mass * 3) -> +%.2f m/s (want ~3)" % [pair[0], dv])
		130:
			for pair in _vehicles():
				pair[1].set_linear_velocity(Vector3.ZERO)
				_mark[pair[1]] = pair[1].global_position.y
		131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160:
			# Twice its weight upward: a net 1 g lift.
			for pair in _vehicles():
				pair[1].apply_central_force(Vector3(0, pair[1].mass * 9.81 * 2.0, 0))
		161:
			for pair in _vehicles():
				var rise: float = pair[1].global_position.y - _mark[pair[1]]
				_check(rise > 0.5, "%s: apply_central_force lifts it (%.2f m in 0.5 s)" % [pair[0], rise])
		200:
			for pair in _vehicles():
				var v: Node3D = pair[1]
				var target := Transform3D(Basis(Vector3.UP, PI * 0.5), v.global_position + Vector3(0, 1.5, 200))
				_mark[v] = target
				v.set_linear_velocity(Vector3(3, 0, 3))
				v.teleport(target)
				_check(v.global_position.distance_to(target.origin) < 0.01, "%s: teleport moves it at once" % pair[0])
				_check(v.get_linear_velocity().length() < 0.01, "%s: teleport leaves it at rest" % pair[0])
		260:
			for pair in _vehicles():
				var v: Node3D = pair[1]
				var target: Transform3D = _mark[v]
				var flat := Vector2(v.global_position.x - target.origin.x, v.global_position.z - target.origin.z).length()
				_check(flat < 0.5 and v.global_position.y < target.origin.y, "%s: and settles there (%.2f m off)" % [pair[0], flat])
				_mark[v] = v.global_position
			_car.throttle = 1.0
		340:
			var moved := _car.global_position.distance_to(_mark[_car])
			_check(moved > 1.0, "car: still drives after a teleport (%.1f m)" % moved)
			_car.throttle = 0.0
			var coast: float = _coast.global_position.z - _mark[_coast]
			var hand: float = _hand.global_position.z - _mark[_hand]
			_check(hand < coast * 0.7, "car: handbrake stops it sooner (%.1f m vs %.1f m coasting)" % [hand, coast])
			var grip: float = _grip.global_position.x - _mark[_grip]
			var slip: float = _slip.global_position.x - _mark[_slip]
			_check(slip > grip * 1.5, "car: tire_grip 0.05 slides further sideways (%.2f m vs %.2f m)" % [slip, grip])
			print("[control] ", "PASS" if _ok else "FAIL")
			quit(0 if _ok else 1)
