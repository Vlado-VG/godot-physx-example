extends SceneTree

# Rest-creep bisect: mode selects a variant.
#   0 = as-is (baseline creep)
#   1 = reverse=true at rest  (does the creep flip direction?)
#   2 = brake=1.0 at rest     (does braking kill it?)
#   3 = handbrake=1.0 at rest

var car: Node
var frame := 0
var mode := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		mode = int(args[0])

	var ground: Node = ClassDB.instantiate("StaticBody3D")
	root.add_child(ground)
	var gs: Node = ClassDB.instantiate("CollisionShape3D")
	var gbox: Object = ClassDB.instantiate("BoxShape3D")
	gbox.set("size", Vector3(500, 1, 500))
	gs.set("shape", gbox)
	ground.add_child(gs)
	ground.set_position(Vector3(0, -0.5, 0))

	var scene: PackedScene = load("res://demo/editor/cpu/vehicle.tscn")
	var demo: Node = scene.instantiate()
	root.add_child(demo)
	car = demo.get_node("DogeCar")
	if mode >= 1:
		car.set("use_gearbox", true)
		print("[creep] use_gearbox readback=", car.get("use_gearbox"))
	if mode == 9:
		for w in car.get_children():
			if w.get_class() == "PhysXVehicleWheel3D":
				w.set("tire_friction", 0.0)
	# Commands go through the car script's own input fields -- _physics_process
	# re-writes the vehicle properties from these every tick, so setting the
	# properties directly would be stomped.
	match mode:
		1:
			car.set("_auto_inputs", {"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0, "reverse": true})
		2:
			car.set("_auto_inputs", {"throttle": 0.0, "brake": 1.0, "steer": 0.0, "handbrake": 0.0})
		3:
			car.set("_auto_inputs", {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0, "reverse": true})
	physics_frame.connect(_tick)

func _tick() -> void:
	frame += 1
	if frame % 60 == 0:
		var vel: Vector3 = car.get_linear_velocity()
		var yaw: float = car.global_basis.get_euler().y
		print("[creep m%d] f=%3d pos=(%.3f %.3f %.3f) |v|=%.4f yaw=%.4f" % [
				mode, frame, car.global_position.x, car.global_position.y,
				car.global_position.z, vel.length(), yaw])
	if frame >= 600:
		var yaw: float = car.global_basis.get_euler().y
		print("[creep m%d] RESULT pos=%s |v|=%.4f yaw=%.4f rad (%.2f deg)" % [
				mode, car.global_position, car.get_linear_velocity().length(), yaw, rad_to_deg(yaw)])
		quit(0)
