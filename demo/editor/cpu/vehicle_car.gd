extends RigidBody3D

# PhysX vehicle2 test car -- ported from the old Car-Demo (Godot 4.2
# VehicleBody3D + VehicleWheel3D) onto the PhysX module's vehicle2 RID API
# (PhysXServer3D, DirectDrive / EngineDrive archetypes).
#
# The old Doge.tscn geometry (chassis boxes, wheel attach points, wheel mesh
# offsets) is reproduced in vehicle_car.tscn; this script replaces the
# VehicleBody3D mechanism with the server-level vehicle:
#
#   vehicle_create(archetype) -> vehicle_set_chassis_body -> wheel params ->
#   per-tick vehicle_set_control_inputs / vehicle_set_gear_command
#
# Controls:  W/S throttle+brake/reverse   A/D steer   Space handbrake
#            Shift gear up, Ctrl gear down (gearbox, switches to manual)
#            T back to automatic   P direct-drive <-> gearbox   E engine on/off
#            F flip the car upright (GTA style)   R reset + refuel   ESC quit
#
# Wheel meshes are posed from vehicle telemetry every physics tick: steer
# angles come from vehicle_get_wheel_steer_angles() (Ackermann-aware), spin
# from the per-wheel rotation state, ride height from the suspension contact
# point (or full droop when airborne).


## true = EngineDrive archetype (engine + gearbox), false = DirectDrive.
@export var start_in_gearbox := true
@export var drive_torque := 700.0        # DirectDrive: Nm per driven wheel at full throttle
@export var max_steer_angle := 0.6       # steer lock (rad)
@export var brake_torque := 2500.0       # main brake channel (Nm)
@export var handbrake_torque := 3500.0   # handbrake channel (Nm)
@export var tire_friction := 2.0
@export var engine_peak_torque := 550.0  # EngineDrive peak torque (Nm)
@export var steer_speed := 2.5           # steer ramp (fractions of lock per second)

# Wheel attach points, taken verbatim from the original Doge.tscn wheel nodes
# (chassis space, -Z front), lifted by WHEEL_RIDE_MARGIN: vehicle2's attach is
# the suspension TOP (maximum compression), and the wheel hangs travel minus
# resting compression below it -- the margin makes the resting wheel center
# land exactly on the original node position, so the visual offsets from the
# original scene stay valid. Order: 0 right-front, 1 left-front, 2 right-rear,
# 3 left-rear.
const WHEEL_RIDE_MARGIN := 0.12
const WHEEL_ATTACH := [
	Transform3D(Basis(), Vector3(0.997421, 0.340338 + WHEEL_RIDE_MARGIN, -1.50006)),
	Transform3D(Basis(), Vector3(-1.02668, 0.340338 + WHEEL_RIDE_MARGIN, -1.50006)),
	Transform3D(Basis(), Vector3(0.997421, 0.286814 + WHEEL_RIDE_MARGIN, 1.26411)),
	Transform3D(Basis(), Vector3(-1.02668, 0.286814 + WHEEL_RIDE_MARGIN, 1.26411)),
]
const WHEEL_RADIUS := 0.37     # original Doge.tscn wheel_radius
const WHEEL_TRAVEL := 0.357    # original Doge.tscn suspension_travel
const WHEEL_SPUNG_MASS := 225.0
const WHEEL_DROOP := 0.2       # visual drop used when a wheel is airborne
const AUTOMATIC_GEAR := 255  # eAUTOMATIC_GEAR -- gearbox shifts by itself

# Telemetry consumed by the HUD (vehicle_hud.gd).
var telemetry := {
	"speed_kmh": 0.0, "rpm": 0.0, "wheel_rpm": 0.0, "gear_label": "--",
	"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0,
	"clutch": 0.0, "fuel": 1.0, "engine_on": true, "gearbox": true,
	"manual_gear": false, "pitch": 0.0, "roll": 0.0,
	"g_lat": 0.0, "g_long": 0.0,
	"wheels": [],   # [{contact: bool, rpm: float, slip: float} x4]
}

var vehicle_rid: RID
var gearbox := true          # current archetype (true = EngineDrive)
var engine_on := true
var fuel := 1.0
var manual_gear := false     # gearbox mode: player shifts with Shift/Ctrl
var current_gear := 2        # manual gear index (0=R, 1=N, 2..6 = 1st..5th)
var steer := 0.0             # smoothed steer command in [-1, 1]
var flip_cooldown := 0.0

# Inputs written by _read_inputs (or the autotest) each physics tick.
var _in_throttle := 0.0      # [-1, 1] direct / [0, 1] gearbox
var _in_brake := 0.0
var _in_steer := 0.0         # +1 = left (vehicle2 positive steer yaws toward -X)
var _in_handbrake := 0.0
var _auto_inputs = null      # Dictionary set by the autotest to drive without keys

var _prev_velocity := Vector3.ZERO
var _wheel_nodes: Array[Node3D] = []
var _spawn_xform := Transform3D.IDENTITY


func _ready() -> void:
	_spawn_xform = global_transform
	_wheel_nodes.assign([$WheelRF, $WheelLF, $WheelRR, $WheelLR])
	# The PhysX actor only exists once the body entered the space; give the
	# server one tick, then assemble the vehicle.
	await get_tree().physics_frame
	_build_vehicle(start_in_gearbox)
	if "--autotest" in OS.get_cmdline_user_args():
		_autotest.call_deferred()


func _exit_tree() -> void:
	if vehicle_rid.is_valid():
		PhysicsServer3D.free_rid(vehicle_rid)
		vehicle_rid = RID()


func _physics_process(delta: float) -> void:
	if vehicle_rid.is_valid():
		_read_inputs(delta)
		_apply_fuel(delta)
		PhysXServer3D.get_singleton().vehicle_set_control_inputs(
				vehicle_rid, _in_throttle, _in_brake, _in_steer, _in_handbrake)
		_sample_telemetry()
	_update_wheel_visuals()
	_update_gforces(delta)
	flip_cooldown = maxf(0.0, flip_cooldown - delta)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_P:
			_set_drive_mode(not gearbox)
		KEY_SHIFT:
			_shift_gear(1)
		KEY_CTRL:
			_shift_gear(-1)
		KEY_T:
			manual_gear = false
			if gearbox and vehicle_rid.is_valid():
				PhysXServer3D.get_singleton().vehicle_set_gear_command(vehicle_rid, AUTOMATIC_GEAR)
		KEY_E:
			engine_on = not engine_on and fuel > 0.0
		KEY_F:
			_do_flip()
		KEY_R:
			_reset_car()
		KEY_ESCAPE:
			get_tree().quit()


# ---------------------------------------------------------------------------
# Vehicle assembly
# ---------------------------------------------------------------------------

func _build_vehicle(p_gearbox: bool) -> void:
	gearbox = p_gearbox
	if vehicle_rid.is_valid():
		PhysicsServer3D.free_rid(vehicle_rid)  # chassis body survives (see PHYSX-VEHI-011)
		vehicle_rid = RID()
	var server := PhysXServer3D.get_singleton()
	vehicle_rid = server.vehicle_create(1 if gearbox else 0)
	server.vehicle_set_chassis_body(vehicle_rid, get_rid())
	server.vehicle_set_wheel_count(vehicle_rid, 4)
	for i in 4:
		server.vehicle_set_wheel_params(vehicle_rid, i, {
			"radius": WHEEL_RADIUS,
			"suspension_travel": WHEEL_TRAVEL,
			"local_pose": WHEEL_ATTACH[i],
			"steer": i < 2,
			"front": i < 2,
			"traction": true,
			"brake": true,
			"suspension_stiffness": 9300.0,
			"suspension_damping": 1100.0,
			"suspension_sprung_mass": WHEEL_SPUNG_MASS,
			"wheel_mass": 20.0,
			"tire_friction": tire_friction,
		})
	server.vehicle_set_response_params(vehicle_rid, {
		"drive_torque": drive_torque,
		"max_steer_angle": max_steer_angle,
		"brake_torque": brake_torque,
		"handbrake_torque": handbrake_torque,
	})
	server.vehicle_set_ackermann_params(vehicle_rid, {"enabled": true, "percent": 100.0})
	if gearbox:
		server.vehicle_set_engine_params(vehicle_rid, {
			"peak_torque": engine_peak_torque,
			"idle_omega": 90.0,
			"max_omega": 640.0,
		})
		server.vehicle_set_gearbox_params(vehicle_rid, {"switch_time": 0.25})
		server.vehicle_set_autobox_params(vehicle_rid, {"latency": 0.3})
		server.vehicle_set_gear_command(vehicle_rid, AUTOMATIC_GEAR)
	manual_gear = false
	current_gear = 2


func _set_drive_mode(p_gearbox: bool) -> void:
	if p_gearbox == gearbox:
		return
	_build_vehicle(p_gearbox)


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

func _read_inputs(delta: float) -> void:
	var throttle_in := 0.0
	var brake_in := 0.0
	var steer_in := 0.0
	var handbrake_in := 0.0
	var want_reverse := false

	if _auto_inputs != null:
		throttle_in = _auto_inputs.get("throttle", 0.0)
		brake_in = _auto_inputs.get("brake", 0.0)
		steer_in = _auto_inputs.get("steer", 0.0)
		handbrake_in = _auto_inputs.get("handbrake", 0.0)
		if _auto_inputs.has("target_x"):
			# Lane-keeping assist for scripted runs: P-controller on the
			# lateral offset (positive steer yaws the vehicle toward -X).
			steer_in = clampf(0.04 * (global_position.x - _auto_inputs["target_x"]),
					-0.35, 0.35)
	else:
		steer_in = (1.0 if Input.is_physical_key_pressed(KEY_A) else 0.0) \
				- (1.0 if Input.is_physical_key_pressed(KEY_D) else 0.0)
		handbrake_in = 1.0 if Input.is_physical_key_pressed(KEY_SPACE) else 0.0
		var fwd_speed := _forward_speed()
		var w := Input.is_physical_key_pressed(KEY_W)
		var s := Input.is_physical_key_pressed(KEY_S)
		if w and not s:
			# Forward: brake out of a fast backward roll, otherwise throttle.
			if fwd_speed < -0.8:
				brake_in = 1.0
			else:
				throttle_in = 1.0
		elif s and not w:
			if fwd_speed > 0.8:
				brake_in = 1.0
			else:
				want_reverse = true

	if not engine_on:
		throttle_in = 0.0
		want_reverse = false

	# Map the pedal state onto the active archetype.
	if gearbox:
		_in_throttle = maxf(throttle_in, 0.0)
		_in_brake = brake_in
		if manual_gear:
			pass  # throttle drives whatever gear the player selected
		elif want_reverse:
			# Auto box: explicitly command reverse while reversing.
			PhysXServer3D.get_singleton().vehicle_set_gear_command(vehicle_rid, 0)
		else:
			PhysXServer3D.get_singleton().vehicle_set_gear_command(vehicle_rid, AUTOMATIC_GEAR)
	else:
		# Direct drive: the throttle sign selects the drive direction.
		if want_reverse:
			_in_throttle = -1.0
		else:
			_in_throttle = throttle_in
		_in_brake = brake_in
	_in_steer = steer_in
	_in_handbrake = handbrake_in

	# Speed-sensitive steering: full lock for parking, progressively limited
	# with speed so holding A/D at highway pace no longer spins the car.
	var speed_kmh := linear_velocity.length() * 3.6
	var steer_limit: float = 1.0 / (1.0 + speed_kmh / 90.0)
	steer = move_toward(steer, _in_steer * steer_limit, steer_speed * delta)
	telemetry["throttle"] = absf(_in_throttle)
	telemetry["brake"] = _in_brake
	telemetry["steer"] = steer
	telemetry["handbrake"] = _in_handbrake


func _shift_gear(dir: int) -> void:
	if not gearbox or not vehicle_rid.is_valid():
		return
	if not manual_gear:
		manual_gear = true
		current_gear = PhysXServer3D.get_singleton().vehicle_get_engine_state(vehicle_rid).get("gear", 2)
	current_gear = clampi(current_gear + dir, 0, 6)
	PhysXServer3D.get_singleton().vehicle_set_gear_command(vehicle_rid, current_gear)


func _forward_speed() -> float:
	return -global_basis.z.dot(linear_velocity)


# ---------------------------------------------------------------------------
# Fuel / engine
# ---------------------------------------------------------------------------

func _apply_fuel(delta: float) -> void:
	if engine_on:
		var burn: float = 0.002 + 0.020 * telemetry["throttle"]
		fuel = maxf(0.0, fuel - burn * delta)
		if fuel <= 0.0:
			engine_on = false
	telemetry["fuel"] = fuel
	telemetry["engine_on"] = engine_on


func _reset_car() -> void:
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, _spawn_xform)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	fuel = 1.0
	engine_on = true
	steer = 0.0
	_prev_velocity = Vector3.ZERO


# ---------------------------------------------------------------------------
# Flip recovery (GTA style): roll the car back onto its wheels.
# ---------------------------------------------------------------------------

func _do_flip() -> void:
	if flip_cooldown > 0.0:
		return
	flip_cooldown = 0.5
	var up := global_basis.y
	if up.dot(Vector3.UP) > 0.35:
		return  # roughly upright already; the suspension can cope
	# Roll axis: rotating around (up x world-up) swings the chassis up vector
	# toward world-up along the shortest arc.
	var axis := up.cross(Vector3.UP)
	if axis.length_squared() < 1e-4:
		axis = global_basis.z  # perfectly upside down: roll around the axle line
	axis = axis.normalized()
	angular_velocity *= 0.2  # damp the current tumble so the roll reads cleanly
	apply_torque_impulse(axis * mass * 1.6)
	apply_impulse(Vector3.UP * mass * 1.4)


# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

func _sample_telemetry() -> void:
	var server := PhysXServer3D.get_singleton()
	telemetry["speed_kmh"] = linear_velocity.length() * 3.6
	telemetry["gearbox"] = gearbox
	telemetry["manual_gear"] = manual_gear

	var wheel_states: Array = server.vehicle_get_wheel_states(vehicle_rid)
	var wheels: Array = []
	var max_wheel_rpm := 0.0
	for st in wheel_states:
		wheels.append({
			"contact": st.get("in_contact", false),
			"rpm": st.get("rpm", 0.0),
			"slip": st.get("skid", 0.0),
		})
		max_wheel_rpm = maxf(max_wheel_rpm, absf(st.get("rpm", 0.0)))
	telemetry["wheels"] = wheels
	telemetry["wheel_rpm"] = max_wheel_rpm

	if gearbox:
		var es: Dictionary = server.vehicle_get_engine_state(vehicle_rid)
		telemetry["rpm"] = es.get("rpm", 0.0)
		telemetry["clutch"] = es.get("clutch", 0.0)
		telemetry["gear_label"] = _gear_label(int(es.get("gear", 1)))
	else:
		telemetry["rpm"] = 0.0
		telemetry["clutch"] = 0.0
		if absf(_in_throttle) > 0.01:
			telemetry["gear_label"] = "REV" if _in_throttle < 0.0 else "FWD"
		else:
			telemetry["gear_label"] = "--"

	var e := global_basis.get_euler()
	telemetry["pitch"] = rad_to_deg(e.x)
	telemetry["roll"] = rad_to_deg(e.z)


func _gear_label(gear: int) -> String:
	match gear:
		0: return "R"
		1: return "N"
		_:
			if gear >= 2 and gear <= 6:
				return str(gear - 1)
			return "?"


func _update_gforces(delta: float) -> void:
	if delta <= 0.0:
		return
	var accel := (linear_velocity - _prev_velocity) / delta
	_prev_velocity = linear_velocity
	telemetry["g_lat"] = lerpf(telemetry["g_lat"], global_basis.x.dot(accel) / 9.81, 0.15)
	telemetry["g_long"] = lerpf(telemetry["g_long"], -global_basis.z.dot(accel) / 9.81, 0.15)


# ---------------------------------------------------------------------------
# Wheel visuals: steer (per-wheel Ackermann angle) + spin + suspension ride.
# ---------------------------------------------------------------------------

func _update_wheel_visuals() -> void:
	if vehicle_rid.is_valid():
		var server := PhysXServer3D.get_singleton()
		var steer_angles: PackedFloat32Array = server.vehicle_get_wheel_steer_angles(vehicle_rid)
		var wheel_states: Array = server.vehicle_get_wheel_states(vehicle_rid)
		var to_local := global_transform.affine_inverse()
		for i in _wheel_nodes.size():
			var node := _wheel_nodes[i]
			var attach: Vector3 = WHEEL_ATTACH[i].origin
			var local_center: Vector3
			var in_contact := false
			if i < wheel_states.size():
				var st: Dictionary = wheel_states[i]
				in_contact = st.get("in_contact", false)
				if in_contact:
					# Wheel center rides on the contact plane: point + normal * radius.
					var world_center: Vector3 = st["contact_point"] + st["contact_normal"] * WHEEL_RADIUS
					local_center = to_local * world_center
			if not in_contact:
				local_center = attach + Vector3(0.0, -WHEEL_DROOP, 0.0)
			var spin := 0.0
			if i < wheel_states.size():
				spin = wheel_states[i].get("rotation", 0.0)
			var steer_angle := steer_angles[i] if i < steer_angles.size() else 0.0
			node.position = local_center
			node.basis = Basis(Vector3.UP, steer_angle) * Basis(Vector3.RIGHT, spin)


# ---------------------------------------------------------------------------
# Autotest (-- --autotest on the command line): scripted drive, prints
# "AUTOTEST:" lines, then quits. Not part of the interactive demo.
# ---------------------------------------------------------------------------

func _autotest() -> void:
	await _probe_test_style_vehicle()
	await _frames(40)
	print("AUTOTEST: mode=GEARBOX settled speed_kmh=%.1f" % telemetry["speed_kmh"])
	_dump_state("settled")

	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(180)
	print("AUTOTEST: gearbox 3s throttle: speed=%.1f km/h gear=%s rpm=%.0f" % [
			telemetry["speed_kmh"], telemetry["gear_label"], telemetry["rpm"]])
	_dump_state("gearbox-throttle")

	_auto_inputs = {"throttle": 0.0, "brake": 1.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(180)
	print("AUTOTEST: after 3s brake: speed=%.1f km/h" % telemetry["speed_kmh"])

	_set_drive_mode(false)
	await _frames(10)
	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(180)
	print("AUTOTEST: direct 3s throttle: speed=%.1f km/h" % telemetry["speed_kmh"])

	_auto_inputs = {"throttle": 0.6, "brake": 0.0, "steer": 0.6, "handbrake": 0.0}
	await _frames(120)
	print("AUTOTEST: direct steer 2s: heading-change-check speed=%.1f pos=%s" % [
			telemetry["speed_kmh"], global_position])

	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(90)
	_auto_inputs = {"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": 1.0}
	await _frames(120)
	print("AUTOTEST: after handbrake: speed=%.1f km/h" % telemetry["speed_kmh"])

	# Steering symmetry: +steer must yaw the car left (-X), -steer right (+X).
	_auto_inputs = null
	teleport(Transform3D(Basis(), Vector3(0, 0.8, 60)))
	await _frames(30)
	_auto_inputs = {"throttle": 0.8, "brake": 0.0, "steer": 0.5, "handbrake": 0.0}
	var x0: float = global_position.x
	await _frames(120)
	var left_dx: float = global_position.x - x0
	teleport(Transform3D(Basis(), Vector3(0, 0.8, 60)))
	await _frames(30)
	_auto_inputs = {"throttle": 0.8, "brake": 0.0, "steer": -0.5, "handbrake": 0.0}
	x0 = global_position.x
	await _frames(120)
	var right_dx: float = global_position.x - x0
	print("AUTOTEST: steering symmetry: left_dx=%.2f (expect<0) right_dx=%.2f (expect>0)" % [
			left_dx, right_dx])

	# Ramp run: spawn before the ramp-up, full throttle, measure apex height.
	_auto_inputs = null
	teleport(Transform3D(Basis(), Vector3(0, 0.8, 14)))
	await _frames(30)
	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	var max_y := 0.0
	for i in 500:
		await get_tree().physics_frame
		max_y = maxf(max_y, global_position.y)
	print("AUTOTEST: ramp run: max_y=%.2f end=%s end_pitch=%.1f" % [
			max_y, global_position, telemetry["pitch"]])

	# Flip test: land upside down off the driving lines, then _do_flip() must
	# right the car.
	_auto_inputs = null
	var flipped := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1)), Vector3(8, 1.8, -20))
	teleport(flipped)
	await _frames(40)
	print("AUTOTEST: pre-flip up.y=%.2f" % global_basis.y.y)
	_do_flip()
	await _frames(240)
	print("AUTOTEST: post-flip up.y=%.2f fuel=%.1f engine_on=%s" % [
			global_basis.y.y, telemetry["fuel"], telemetry["engine_on"]])

	# Loop-the-loop run: gearbox mode (exercises P mid-session), long east
	# straight with lane-keeping, full throttle through the loop. The car must
	# stay wheel-first against the loop's inside over the top (up.y near +1
	# means wheels toward the sky AND the chassis following the loop) and land
	# driving on past the exit.
	_set_drive_mode(true)
	await _frames(5)
	teleport(Transform3D(Basis(), Vector3(24, 0.8, 80)))
	fuel = 1.0
	engine_on = true
	await _frames(30)
	print("AUTOTEST:   loop spawn settled: y=%.3f" % global_position.y)
	var loop_inputs := {"throttle": 1.0, "brake": 0.0, "steer": 0.0,
			"handbrake": 0.0, "target_x": 24.0}
	_auto_inputs = loop_inputs
	var loop_max_y := 0.0
	var loop_min_up := 1.0
	var apex_up := 1.0
	var entry_speed := 0.0
	var entry_z := 0.0
	for i in 900:
		await get_tree().physics_frame
		if i % 15 == 0:
			var es: Dictionary = PhysXServer3D.get_singleton().vehicle_get_engine_state(vehicle_rid)
			print("AUTOTEST:   loop-trace t=%2.2fs pos=(%.1f, %.2f, %.1f) up.y=%.2f speed=%.0f gear=%s eng_rpm=%.0f thr=%.1f fuel=%.2f wheel_rpm=%.0f" % [
					i / 60.0, global_position.x, global_position.y, global_position.z,
					global_basis.y.y, telemetry["speed_kmh"], telemetry["gear_label"],
					es.get("rpm", 0.0), telemetry["throttle"], telemetry["fuel"],
					telemetry["wheel_rpm"]])
		if global_position.z < -40.0 and entry_speed == 0.0:
			entry_speed = telemetry["speed_kmh"]
			entry_z = global_position.y
		if global_position.z < -120.0:
			loop_inputs["throttle"] = 0.0
			loop_inputs["brake"] = 1.0  # stay on the ground plane
		if global_position.y > 5.0:
			loop_min_up = minf(loop_min_up, global_basis.y.y)
		if global_position.y > 12.0:
			apex_up = minf(apex_up, global_basis.y.y)
		loop_max_y = maxf(loop_max_y, global_position.y)
	print("AUTOTEST: loop run: entry=%.0f km/h entry_y=%.2f max_y=%.2f (top=16) min_up_high=%.2f apex_up=%.2f end=%s speed=%.0f" % [
			entry_speed, entry_z, loop_max_y, loop_min_up, apex_up,
			global_position, telemetry["speed_kmh"]])
	_dump_state("loop-end")
	print("AUTOTEST: DONE")
	get_tree().quit()


func teleport(xform: Transform3D) -> void:
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	_prev_velocity = Vector3.ZERO


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Autotest diagnostics: raw wheel telemetry + chassis pose.
func _dump_state(tag: String) -> void:
	var server := PhysXServer3D.get_singleton()
	var ws: Array = server.vehicle_get_wheel_states(vehicle_rid)
	print("AUTOTEST: state[%s] chassis_pos=%s vel=%s" % [tag, global_position, linear_velocity])
	for i in ws.size():
		var st: Dictionary = ws[i]
		print("AUTOTEST:   wheel%d contact=%s point=%s normal=%s rpm=%.1f" % [
				i, st.get("in_contact"), st.get("contact_point"),
				st.get("contact_normal"), st.get("rpm", 0.0)])
	if ws.is_empty():
		print("AUTOTEST:   (no wheel telemetry)")


## Server-level clone of VehicleTests.MakeVehicle (the geometry that passes the
## C# suite). If this drives, the vehicle mechanism works in this scene and the
## problem is the Doge car's wheel geometry; if not, the mechanism itself.
func _probe_test_style_vehicle() -> void:
	var server := PhysXServer3D.get_singleton()
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_RIGID)
	PhysicsServer3D.body_set_space(body, PhysicsServer3D.body_get_space(get_rid()))
	var shape := PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(shape, Vector3(0.9, 0.3, 2.0))
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_MASS, 800.0)
	PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_BOUNCE, 0.0)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), Vector3(-8, 1, 20)))
	var v := server.vehicle_create(0)
	server.vehicle_set_chassis_body(v, body)
	server.vehicle_set_wheel_count(v, 4)
	for i in 4:
		server.vehicle_set_wheel_params(v, i, {
			"radius": 0.4,
			"suspension_travel": 0.3,
			"local_pose": Transform3D(Basis(), Vector3(
					-0.7 + 1.4 * (i % 2), -0.05, -0.7 + 1.4 * int(i / 2.0))),
			"steer": i < 2,
			"front": i < 2,
			"traction": true,
			"brake": true,
		})
	server.vehicle_set_control_inputs(v, 1.0, 0.0, 0.0, 0.0)
	await _frames(180)
	var pos: Vector3 = PhysicsServer3D.body_get_state(
			body, PhysicsServer3D.BODY_STATE_TRANSFORM).origin
	print("AUTOTEST: probe(test-style, direct) pos=%s moved_z=%.2f" % [pos, pos.z - 20.0])
	PhysicsServer3D.free_rid(v)
	PhysicsServer3D.free_rid(body)
