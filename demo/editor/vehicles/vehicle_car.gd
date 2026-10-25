extends PhysXVehicle3D

# PhysX node-level vehicle demo car -- the Doge test car, now on the PhysX
# module's NODE vehicle stack (PhysXVehicle3D + PhysXVehicleWheel3D children)
# instead of the server-RID API. No vehicle_create / vehicle_set_wheel_params
# dictionaries / vehicle_set_control_inputs anywhere: the vehicle is the node,
# the wheels are child nodes configured below, and driving is just writing the
# throttle / brake / steer / reverse properties every physics tick.
#
# The old Doge.tscn geometry (chassis box, wheel attach points, wheel mesh
# offsets) is reproduced in vehicle_car.tscn. Placement convention of the node
# stack matches Godot's own: forward = -Z, steered axle on the more negative Z
# side -- exactly how the old scene was authored, so the geometry ports over
# unchanged (the doge-body glb keeps its original Y-180 rotation).
#
# The node stack drives DIRECT by default; P toggles the PhysX engine-drive
# drivetrain (use_gearbox: engine + clutch + gearbox), T toggles its autobox
# (automatic DRIVE vs manual gears). Wheel visuals need no script at all: the
# node poses its PhysXVehicleWheel3D children every tick (jounce + steer +
# spin baked in), so the Wheel.glb meshes just hang under them.
#
# Controls:  W/S throttle+brake/reverse   A/D steer   Space handbrake
#            P direct <-> gearbox   T autobox on/off (gearbox mode)
#            F flip the car upright (GTA style)   R reset   ESC quit

@export var drive_torque := 350.0         # direct drive, PER WHEEL (the response applies it at each driven wheel; 4 driven wheels -> 4x)
@export var max_steer_lock := 0.6         # steer lock (rad)
@export var brake_torque := 2500.0        # main brake channel (Nm)
@export var tire_friction := 2.0
@export var steer_speed := 2.5            # steer ramp (fractions of lock per second)

# Wheel tuning, applied to the PhysXVehicleWheel3D children in _ready (same
# numbers the old RID-API build passed through vehicle_set_wheel_params).
const WHEEL_RADIUS := 0.37     # original Doge.tscn wheel_radius
const WHEEL_TRAVEL := 0.357    # original Doge.tscn suspension_travel

# Telemetry consumed by the HUD (vehicle_hud.gd). The node stack exposes what
# it exposes: forward speed, linear velocity, per-wheel jounce/separation, and
# in engine-drive mode (P) the live engine rpm + gearbox gear.
var telemetry := {
	"speed_kmh": 0.0, "gear_label": "--",
	"drive_label": "DIRECT", "engine_rpm": 0.0,
	"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0,
	"pitch": 0.0, "roll": 0.0,
	"g_lat": 0.0, "g_long": 0.0,
	"wheels": [],   # [{contact: bool, jounce: float} x4]
}

var _steer_smooth := 0.0     # smoothed steer command in [-1, 1] (parent's `steer` property receives it)
var flip_cooldown := 0.0

# Inputs written by _read_inputs (or the autotest) each physics tick.
var _in_throttle := 0.0      # [0, 1] (reverse is the `reverse` property)
var _in_brake := 0.0
var _in_steer := 0.0         # +1 = left (positive steer yaws toward -X)
var _in_handbrake := 0.0
var _in_reverse := false
var _auto_inputs = null      # Dictionary set by the autotest to drive without keys

# Brief handbrake hold after spawn: a dropped/settling vehicle otherwise
# keeps whatever horizontal momentum the landing leaves (a free-rolling car
# has no rolling resistance in the tire model), so the car appears to creep
# away on its own. Released by the first drive input or on timeout.
var _spawn_brake := 0.75

var _prev_velocity := Vector3.ZERO
var _wheel_nodes: Array[Node3D] = []
var _spawn_xform := Transform3D.IDENTITY


func _ready() -> void:
	_spawn_xform = global_transform
	_wheel_nodes.assign([$WheelRF, $WheelLF, $WheelRR, $WheelLR])
	# Scene layout (vehicle_car.tscn): steered axle on the -Z side (Godot
	# forward). The wheel node's own position IS the suspension attachment
	# hardpoint; the attachment sits the old resting-center lift (+0.12) above
	# it so the resting wheel center lands on the original node position and
	# the visual offsets stay valid.
	var attach: Array[Vector3] = [
		Vector3(0.997421, 0.340338 + 0.12, -1.50006),  # RF (steered, -Z front)
		Vector3(-1.02668, 0.340338 + 0.12, -1.50006),  # LF
		Vector3(0.997421, 0.286814 + 0.12, 1.26411),   # RR
		Vector3(-1.02668, 0.286814 + 0.12, 1.26411),   # LR
	]
	for i in 4:
		var w: Node3D = _wheel_nodes[i]
		w.position = attach[i]
		w.set("radius", WHEEL_RADIUS)
		w.set("suspension_travel", WHEEL_TRAVEL)
		w.set("suspension_stiffness", 9300.0)
		w.set("suspension_damping", 1100.0)
		w.set("wheel_mass", 20.0)
		w.set("tire_friction", tire_friction)
		# NOTE: use_as_steering/use_as_traction are authored in the .tscn
		# (front two steered, all four driven) -- NOT here. The vehicle
		# rebuilds on every wheel property change, so flipping the flags from
		# script walks the composition through invalid "1 steering wheel"
		# intermediate states and spams the "exactly 2 steering" error.

	# Vehicle-level tuning (was vehicle_set_response_params / ackermann).
	mass = 900.0
	max_engine_torque = drive_torque
	max_brake_torque = brake_torque
	max_steer_angle = max_steer_lock
	ackermann_strength = 1.0

	if "--autotest" in OS.get_cmdline_user_args():
		_autotest.call_deferred()

	_make_ice_patch()


func _physics_process(delta: float) -> void:
	_read_inputs(delta)
	# Driving = writing properties; the vehicle node's own internal physics
	# process turns them into PxVehicle2 commands.
	throttle = _in_throttle
	brake = _in_brake
	set_steer(_steer_smooth)
	handbrake = _in_handbrake
	reverse = _in_reverse
	telemetry["throttle"] = _in_throttle
	telemetry["brake"] = _in_brake
	telemetry["steer"] = _steer_smooth
	telemetry["handbrake"] = _in_handbrake
	_update_ice_friction()
	_sample_telemetry()
	flip_cooldown = maxf(0.0, flip_cooldown - delta)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_P:
			# Direct <-> engine drive (PhysXVehicle3D rebuilds live; the pose
			# is kept by the node's two-way transform contract).
			use_gearbox = not use_gearbox
			if use_gearbox:
				use_autobox = true   # come up in DRIVE so W works right away
				target_gear = 255
			telemetry["g_lat"] = 0.0
			telemetry["g_long"] = 0.0
		KEY_T:
			# Autobox on/off (engine drive only). Leaving the autobox puts the
			# gearbox in 1st so W keeps driving; reverse still works via S.
			if use_gearbox:
				use_autobox = not use_autobox
				if not use_autobox:
					target_gear = 2
		KEY_F:
			_do_flip()
		KEY_R:
			_reset_car()
		KEY_ESCAPE:
			get_tree().quit()


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

func _read_inputs(delta: float) -> void:
	var throttle_in := 0.0
	var brake_in := 0.0
	var steer_in := 0.0
	var handbrake_in := 0.0
	var want_reverse := false

	if _spawn_brake > 0.0:
		_spawn_brake -= delta
		brake_in = 1.0

	if _auto_inputs != null:
		throttle_in = _auto_inputs.get("throttle", 0.0)
		brake_in = _auto_inputs.get("brake", 0.0)
		steer_in = _auto_inputs.get("steer", 0.0)
		handbrake_in = _auto_inputs.get("handbrake", 0.0)
		want_reverse = _auto_inputs.get("reverse", false)
		if _auto_inputs.has("target_x"):
			# Lane-keeping assist for scripted runs: P-controller on the
			# lateral offset (positive steer yaws the vehicle toward -X).
			steer_in = clampf(0.04 * (global_position.x - _auto_inputs["target_x"]),
					-0.35, 0.35)
	else:
		steer_in = (1.0 if Input.is_physical_key_pressed(KEY_A) else 0.0) \
				- (1.0 if Input.is_physical_key_pressed(KEY_D) else 0.0)
		handbrake_in = 1.0 if Input.is_physical_key_pressed(KEY_SPACE) else 0.0
		var fwd_speed := get_forward_speed()
		var w := Input.is_physical_key_pressed(KEY_W)
		var s := Input.is_physical_key_pressed(KEY_S)
		if w and not s:
			# Forward: brake out of a fast backward roll, otherwise throttle.
			if fwd_speed < -0.8:
				brake_in = 1.0
			else:
				throttle_in = 1.0
			want_reverse = false
		elif s and not w:
			if fwd_speed > 0.8:
				brake_in = 1.0
			else:
				want_reverse = true

	# Direct drive: `reverse` selects the drive direction; the throttle never
	# goes negative (the old sign-based direct-drive trick is gone).
	_in_throttle = maxf(throttle_in, 0.0)
	_in_brake = brake_in
	_in_reverse = want_reverse
	_in_steer = steer_in
	_in_handbrake = handbrake_in

	# Standstill auto-hold: with no input and the car nearly stopped, keep the
	# brakes on. PhysX vehicle tires model no rolling resistance, so a settled
	# car would otherwise coast forever on whatever momentum or terrain slope
	# it has (and slowly yaw on any geometry asymmetry).
	if _in_throttle <= 0.0 and not _in_reverse and brake_in <= 0.0 		and absf(get_forward_speed()) < 0.25:
		_in_brake = 1.0

	# Neutral coast drag: in engine-drive neutral the drivetrain is fully
	# decoupled and the tire model has no rolling resistance, so the car
	# would coast almost forever on inertia alone. A light speed-proportional
	# brake stands in for rolling resistance + driveline drag while rolling
	# in N (suppressed while throttling -- that would fight a blip).
	if use_gearbox and get_engine_gear() == GEAR_NEUTRAL and _in_throttle <= 0.0:
		var coast_kmh := get_linear_velocity().length() * 3.6
		_in_brake = maxf(_in_brake, clampf(coast_kmh / 150.0, 0.0, 0.05))

	# Speed-sensitive steering: full lock for parking, progressively limited
	# with speed so holding A/D at highway pace no longer spins the car.
	var speed_kmh := get_linear_velocity().length() * 3.6
	var steer_limit: float = 1.0 / (1.0 + speed_kmh / 90.0)
	_steer_smooth = move_toward(_steer_smooth, _in_steer * steer_limit, steer_speed * delta)


func _reset_car() -> void:
	# Reset = the node transform contract: writing global_transform pushes the
	# pose into the chassis and zeroes all velocities (RigidBody3D-style).
	global_transform = _spawn_xform
	_steer_smooth = 0.0
	_prev_velocity = Vector3.ZERO
	telemetry["g_lat"] = 0.0
	telemetry["g_long"] = 0.0


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
	# Upright the chassis around its own yaw: keep the heading, zero the roll
	# and pitch, nudge up so the suspension re-settles from air.
	var fwd := global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3(0, 0, 1)
	fwd = fwd.normalized()
	var xform := Transform3D(Basis(Vector3.UP, atan2(-fwd.x, -fwd.z)), global_position + Vector3(0, 1.0, 0))
	global_transform = xform


# ---------------------------------------------------------------------------
# Ice patch: demonstrates the LIVE tire-friction API. The patch is a visual
# quad off the driving lines; each physics tick any wheel inside its rect
# runs at ice friction via PhysXVehicleWheel3D.set_tire_friction (which
# rewrites the built vehicle's tire data in place, no rebuild), and leaves
# restore the authored value.
# ---------------------------------------------------------------------------

# Rect in world XZ: position (x, z) + size (w, d). Kept OFF the driving
# lines (the straight is at x=0 and the loop at x=24) so scripted runs and
# the autotest never cross it.
const ICE_RECT := Rect2(-10.0, 26.0, 6.0, 18.0)
const ICE_FRICTION := 0.25

var _ice_mesh: MeshInstance3D
var _base_friction := 1.0


func _make_ice_patch() -> void:
	_ice_mesh = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(ICE_RECT.size.x, 0.04, ICE_RECT.size.y)
	_ice_mesh.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.55, 0.85, 1.0, 0.4)
	_ice_mesh.material_override = mat
	_ice_mesh.position = Vector3(
			ICE_RECT.position.x + ICE_RECT.size.x * 0.5, 0.025,
			ICE_RECT.position.y + ICE_RECT.size.y * 0.5)
	# Deferred: _ready runs while the parent scene root is still setting up
	# its own children, so a direct add_child here fails.
	get_parent().add_child.call_deferred(_ice_mesh)
	_base_friction = _wheel_nodes[0].get("tire_friction")


func _update_ice_friction() -> void:
	for w in _wheel_nodes:
		var p: Vector3 = w.global_position
		var wanted: float = ICE_FRICTION if ICE_RECT.has_point(Vector2(p.x, p.z)) else _base_friction
		if absf(float(w.get("tire_friction")) - wanted) > 0.01:
			w.set("tire_friction", wanted)


# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

func _sample_telemetry() -> void:
	telemetry["speed_kmh"] = get_linear_velocity().length() * 3.6
	# Transmission state: in engine-drive mode the GEAR row shows the real
	# gearbox gear (R / N / forward; D<n> with the autobox), direct drive
	# keeps the direction readout.
	telemetry["engine_rpm"] = get_engine_rpm() if use_gearbox else 0.0
	if use_gearbox:
		var g := get_engine_gear()
		if use_autobox:
			telemetry["drive_label"] = "GEARBOX AUTO"
			if g == GEAR_REVERSE:
				telemetry["gear_label"] = "R"
			elif g == GEAR_NEUTRAL:
				telemetry["gear_label"] = "N"
			else:
				telemetry["gear_label"] = "D%d" % (g - 1)
		else:
			telemetry["drive_label"] = "GEARBOX"
			if g == GEAR_REVERSE:
				telemetry["gear_label"] = "R"
			elif g == GEAR_NEUTRAL:
				telemetry["gear_label"] = "N"
			else:
				telemetry["gear_label"] = str(g - 1)
	else:
		telemetry["drive_label"] = "DIRECT"
		telemetry["gear_label"] = "REV" if reverse else ("FWD" if absf(_in_throttle) > 0.01 or absf(_in_brake) > 0.01 else "--")

	var wheels: Array = []
	for i in 4:
		wheels.append({
			# separation is the gap between tire and road: ~0 = contact.
			"contact": get_wheel_separation(i) <= 0.01,
			"jounce": get_wheel_jounce(i),
		})
	telemetry["wheels"] = wheels

	var e := global_basis.get_euler()
	telemetry["pitch"] = rad_to_deg(e.x)
	telemetry["roll"] = rad_to_deg(e.z)


func _update_gforces(delta: float) -> void:
	if delta <= 0.0:
		return
	var accel := (get_linear_velocity() - _prev_velocity) / delta
	_prev_velocity = get_linear_velocity()
	telemetry["g_lat"] = lerpf(telemetry["g_lat"], global_basis.x.dot(accel) / 9.81, 0.15)
	telemetry["g_long"] = lerpf(telemetry["g_long"], -global_basis.z.dot(accel) / 9.81, 0.15)


# ---------------------------------------------------------------------------
# Autotest (-- --autotest on the command line): scripted drive, prints
# "AUTOTEST:" lines, then quits. Not part of the interactive demo.
# ---------------------------------------------------------------------------

func _autotest() -> void:
	await _frames(40)
	_auto_inputs = {"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(20)
	print("AUTOTEST: mode=DIRECT settled speed_kmh=%.1f" % telemetry["speed_kmh"])

	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(180)
	print("AUTOTEST: direct 3s throttle: speed=%.1f km/h fwd=%.1f" % [
			telemetry["speed_kmh"], get_forward_speed()])

	_auto_inputs = {"throttle": 0.0, "brake": 1.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(180)
	print("AUTOTEST: after 3s brake: speed=%.1f km/h" % telemetry["speed_kmh"])

	_auto_inputs = {"throttle": 0.6, "brake": 0.0, "steer": 0.6, "handbrake": 0.0}
	await _frames(120)
	print("AUTOTEST: direct steer 2s: heading-change-check speed=%.1f pos=%s" % [
			telemetry["speed_kmh"], global_position])

	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	await _frames(90)
	_auto_inputs = {"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": 1.0}
	await _frames(120)
	print("AUTOTEST: after handbrake: speed=%.1f km/h" % telemetry["speed_kmh"])

	# Reverse: command reverse from standstill, verify negative forward speed.
	_auto_inputs = null
	global_transform = Transform3D(Basis(), Vector3(0, 0.8, 60))
	await _frames(30)
	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0, "reverse": true}
	await _frames(120)
	print("AUTOTEST: reverse 2s: fwd=%.1f (expect<0) pos.z=%.1f" % [
			get_forward_speed(), global_position.z])
	_auto_inputs = null

	# Steering symmetry: +steer must yaw the car left (-X), -steer right (+X).
	_auto_inputs = null
	global_transform = Transform3D(Basis(), Vector3(0, 0.8, 60))
	await _frames(30)
	_auto_inputs = {"throttle": 0.8, "brake": 0.0, "steer": 0.5, "handbrake": 0.0}
	var x0: float = global_position.x
	await _frames(120)
	var left_dx: float = global_position.x - x0
	global_transform = Transform3D(Basis(), Vector3(0, 0.8, 60))
	await _frames(30)
	_auto_inputs = {"throttle": 0.8, "brake": 0.0, "steer": -0.5, "handbrake": 0.0}
	x0 = global_position.x
	await _frames(120)
	var right_dx: float = global_position.x - x0
	print("AUTOTEST: steering symmetry: left_dx=%.2f (expect<0) right_dx=%.2f (expect>0)" % [
			left_dx, right_dx])

	# Ramp run: spawn before the ramp-up, full throttle, measure apex height.
	_auto_inputs = null
	global_transform = Transform3D(Basis(), Vector3(0, 0.8, 14))
	await _frames(30)
	_auto_inputs = {"throttle": 1.0, "brake": 0.0, "steer": 0.0, "handbrake": 0.0}
	var max_y := 0.0
	for i in 240:  # ~4 s: through the ramp and a little past, before the map edge
		await get_tree().physics_frame
		max_y = maxf(max_y, global_position.y)
	print("AUTOTEST: ramp run: max_y=%.2f end=%s end_pitch=%.1f" % [
			max_y, global_position, telemetry["pitch"]])

	# Flip test: land upside down off the driving lines, then _do_flip() must
	# right the car.
	_auto_inputs = null
	var flipped := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1)), Vector3(8, 1.8, -20))
	global_transform = flipped
	await _frames(40)
	print("AUTOTEST: pre-flip up.y=%.2f" % global_basis.y.y)
	_do_flip()
	await _frames(240)
	print("AUTOTEST: post-flip up.y=%.2f" % global_basis.y.y)

	# Loop-the-loop run: long east straight with lane-keeping, full throttle
	# through the loop. The car must stay wheel-first against the loop's
	# inside over the top (up.y near +1 at entry means wheels down; through
	# the apex the chassis follows the loop) and land driving on past exit.
	global_transform = Transform3D(Basis(), Vector3(24, 0.8, 80))
	await _frames(30)
	print("AUTOTEST:   loop spawn settled: y=%.3f" % global_position.y)
	var loop_inputs := {"throttle": 1.0, "brake": 0.0, "steer": 0.0,
			"handbrake": 0.0, "target_x": 24.0}
	_auto_inputs = loop_inputs
	var loop_max_y := 0.0
	var loop_min_up := 1.0
	var apex_up := 1.0
	var entry_speed := 0.0
	var entry_y := 0.0
	for i in 900:
		await get_tree().physics_frame
		if i % 15 == 0:
			print("AUTOTEST:   loop-trace t=%2.2fs pos=(%.1f, %.2f, %.1f) up.y=%.2f speed=%.0f thr=%.1f" % [
					i / 60.0, global_position.x, global_position.y, global_position.z,
					global_basis.y.y, telemetry["speed_kmh"], telemetry["throttle"]])
		if global_position.z < -40.0 and entry_speed == 0.0:
			entry_speed = telemetry["speed_kmh"]
			entry_y = global_position.y
		if global_position.z < -120.0:
			loop_inputs["throttle"] = 0.0
			loop_inputs["brake"] = 1.0  # stay on the ground plane
		if global_position.y > 5.0:
			loop_min_up = minf(loop_min_up, global_basis.y.y)
		if global_position.y > 12.0:
			apex_up = minf(apex_up, global_basis.y.y)
		loop_max_y = maxf(loop_max_y, global_position.y)
	print("AUTOTEST: loop run: entry=%.0f km/h entry_y=%.2f max_y=%.2f (top=16) min_up_high=%.2f apex_up=%.2f end=%s speed=%.0f" % [
			entry_speed, entry_y, loop_max_y, loop_min_up, apex_up,
			global_position, telemetry["speed_kmh"]])
	print("AUTOTEST: DONE")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
