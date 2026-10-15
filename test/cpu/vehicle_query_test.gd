extends SceneTree

# R26 + R30: PhysX vehicles in scene queries and collision exceptions.
#   R26: a raycast hits the car, tank and motorcycle, reporting the vehicle node
#   and its get_rid(); excluding that RID reaches the ground; the wheels still
#   stand on the ground (not on their own chassis); a CharacterBody3D lands on a
#   car's roof and rides it when the car drives off; a contact-monitoring RigidBody3D hitting a car reports the car.
#   R30: a box falls through a car that has an exception with it (from either
#   side: the car's add_collision_exception_with, or the body's own via
#   PhysicsServer3D), and so does a character; get_collision_exceptions lists it;
#   a car excepting another car drops through it to the ground.

var _cars := {}
var _boxes := {}
var _chars := {}
var _hit_by := []
var _t := 0
var _ok := true
var _mark_car := Vector3()
var _mark_char := Vector3()


func _check(cond: bool, msg: String) -> void:
	print("[query] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _floor() -> void:
	var f := StaticBody3D.new()
	f.name = "Floor"
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(400, 1, 400)
	cs.shape = b
	f.add_child(cs)
	f.position = Vector3(0, -0.5, 0)
	get_root().add_child(f)


func _box_shape(size: Vector3, y: float) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	cs.position = Vector3(0, y, 0)
	return cs


func _make_car(x: float, y := 0.6) -> PhysXVehicle3D:
	var car := PhysXVehicle3D.new()
	car.position = Vector3(x, y, 0)
	car.add_child(_box_shape(Vector3(1.9, 0.8, 3.7), 0.4))
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
	moto.add_child(_box_shape(Vector3(0.4, 0.6, 1.8), 0.5))
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
	tank.add_child(_box_shape(Vector3(2.4, 1.2, 6.0), 0.9))
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


func _make_box(x: float, y: float) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.position = Vector3(x, y, 0)
	rb.mass = 20.0
	rb.add_child(_box_shape(Vector3(0.5, 0.5, 0.5), 0.0))
	get_root().add_child(rb)
	return rb


func _make_char(x: float, y: float) -> CharacterBody3D:
	var c := CharacterBody3D.new()
	c.position = Vector3(x, y, 0)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.6
	cs.shape = cap
	c.add_child(cs)
	get_root().add_child(c)
	return c


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXVehicle3D", "add_collision_exception_with"):
		print("[query] PhysXVehicle3D has no add_collision_exception_with -> FAIL")
		quit(1)
		return
	_floor()
	_cars.car = _make_car(-60)
	_cars.moto = _make_moto(-45)
	_cars.tank = _make_tank(-30)
	_cars.roof = _make_car(-15) # a box and a character land on it
	_cars.exc_car = _make_car(0) # excepts a box and a character itself
	_cars.exc_body = _make_car(15) # a box excepts it, from the body's side
	_cars.lower = _make_car(30)
	_cars.upper = _make_car(30, 4.0) # excepts `lower`: drops through it
	_cars.upper.add_collision_exception_with(_cars.lower)
	_cars.contact = _make_car(45)
	physics_frame.connect(_tick)


func _ray(from: Vector3, to: Vector3, exclude: Array[RID] = []) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = exclude
	return get_root().get_world_3d().direct_space_state.intersect_ray(q)


func _tick() -> void:
	_t += 1
	if _t == 60:
		# Settled: rays from above.
		for k in ["car", "moto", "tank"]:
			var v: Node3D = _cars[k]
			var top := v.global_position + Vector3(0, 6, 0)
			var hit := _ray(top, top - Vector3(0, 12, 0))
			_check(not hit.is_empty() and hit.collider == v, "%s: a raycast hits it (collider %s)" % [k, hit.get("collider")])
			_check(not hit.is_empty() and hit.rid == v.get_rid() and v.get_rid().is_valid(), "%s: and reports its get_rid()" % k)
			var past := _ray(top, top - Vector3(0, 12, 0), [v.get_rid()])
			_check(not past.is_empty() and past.collider.name == "Floor", "%s: excluding get_rid() reaches the floor" % k)
			# The wheels carry it: the chassis box bottom stays clear of the ground.
			_check(v.global_position.y > 0.2, "%s: rides on its wheels, not its own chassis (y %.2f)" % [k, v.global_position.y])
		var p := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.3
		p.shape = sph
		p.transform = Transform3D(Basis(), _cars.car.global_position + Vector3(0, 0.8, 0))
		var over := get_root().get_world_3d().direct_space_state.intersect_shape(p)
		_check(over.any(func(r: Dictionary) -> bool: return r.collider == _cars.car), "car: intersect_shape finds it")
		# Drops.
		var r: Vector3 = _cars.roof.global_position
		_boxes.roof = _make_box(r.x - 0.5, r.y + 3.0)
		_chars.roof = _make_char(r.x + 0.5, r.y + 3.0)
		var e: Vector3 = _cars.exc_car.global_position
		_boxes.exc_car = _make_box(e.x - 0.5, e.y + 3.0)
		_chars.exc_car = _make_char(e.x + 0.5, e.y + 3.0)
		_cars.exc_car.add_collision_exception_with(_boxes.exc_car)
		_cars.exc_car.add_collision_exception_with(_chars.exc_car)
		var b: Vector3 = _cars.exc_body.global_position
		_boxes.exc_body = _make_box(b.x, b.y + 3.0)
		PhysicsServer3D.body_add_collision_exception(_boxes.exc_body.get_rid(), _cars.exc_body.get_rid())
		var c: Vector3 = _cars.contact.global_position
		_boxes.contact = _make_box(c.x, c.y + 3.0)
		_boxes.contact.contact_monitor = true
		_boxes.contact.max_contacts_reported = 4
		_boxes.contact.body_entered.connect(func(n: Node) -> void: _hit_by.append(n))
		var ex: Array = _cars.exc_car.get_collision_exceptions()
		_check(ex.size() == 2 and ex.has(_boxes.exc_car) and ex.has(_chars.exc_car), "get_collision_exceptions lists the box and the character")
	if _t > 60:
		for c in _chars.values():
			var ch: CharacterBody3D = c
			ch.velocity.y -= 9.8 / 60.0
			ch.move_and_slide()
	if _t == 240:
		var roof_y: float = _cars.roof.global_position.y + 0.8
		_check(_boxes.roof.global_position.y > roof_y - 0.1, "a box lands on a car's roof (y %.2f, roof ~%.2f)" % [_boxes.roof.global_position.y, roof_y])
		_check(_chars.roof.global_position.y > roof_y + 0.5, "a CharacterBody3D lands on a car's roof (y %.2f)" % _chars.roof.global_position.y)
		_check(_chars.roof.is_on_floor(), "and stands there (is_on_floor)")
		_check(_boxes.exc_car.global_position.y < 0.4, "car.add_collision_exception_with(box): the box falls through (y %.2f)" % _boxes.exc_car.global_position.y)
		_check(_chars.exc_car.global_position.y < 1.0, "car.add_collision_exception_with(character): it falls through (y %.2f)" % _chars.exc_car.global_position.y)
		_check(_boxes.exc_body.global_position.y < 0.4, "body_add_collision_exception(box, car): the box falls through (y %.2f)" % _boxes.exc_body.global_position.y)
		_check(_cars.upper.global_position.y < 1.0, "a car excepting the car below drops through it to the ground (y %.2f)" % _cars.upper.global_position.y)
		_check(_hit_by.has(_cars.contact), "a contact-monitoring box reports hitting the car (body_entered %s)" % [_hit_by])
		# The roof car drives off with the character on it.
		_cars.roof.throttle = 0.4
		_mark_car = _cars.roof.global_position
		_mark_char = _chars.roof.global_position - _cars.roof.global_position
	if _t == 420:
		var moved: float = (_cars.roof.global_position - _mark_car).length()
		var drift: Vector3 = (_chars.roof.global_position - _cars.roof.global_position) - _mark_char
		_check(moved > 3.0 and Vector2(drift.x, drift.z).length() < 0.5 and _chars.roof.is_on_floor(),
				"the character rides the moving car (car %.1f m, character drifted %.2f m on the roof)" % [moved, Vector2(drift.x, drift.z).length()])
		print("[query] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)
