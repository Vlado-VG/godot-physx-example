extends Camera3D

# Need-for-Speed style chase camera.
#
# Unlike the old lazy-look-at cam (which kept whatever relative position it
# had and look_at'ed the car -- over jumps, crashes or hard acceleration it
# ended up above/behind at a random bearing, pitching the view down so the
# player couldn't see forward), this camera's view direction is LEVEL by
# construction: it inherits only the car's smoothed heading yaw, never its
# pitch or roll. The car moves under the view, not the other way around.
#
# Mouse free-look: moving the mouse orbits around the car (yaw + pitch).
# While driving, once the mouse goes idle the orbit eases back onto the
# chase view. FOV widens with speed for a sense of acceleration.

@export var target_distance := 5.0   # chase distance (m)
@export var target_height := 1.7     # chase height above the car origin (m)
@export var follow_speed := 10.0     # heading/position smoothing rate
@export var look_ahead := 4.0        # chase look-at point this far ahead of the car
@export var mouse_sensitivity := 0.0035
@export var recenter_delay := 1.2    # seconds of mouse idle before recentering
@export var recenter_speed := 3.0    # free-look ease-back rate while driving
@export var base_fov := 70.0
@export var speed_fov := 15.0        # extra FOV at ~220 km/h

const CHASE_PITCH := 0.22            # natural downward tilt of the chase view (rad)

var _car: Node3D
var _yaw := 0.0                      # smoothed car heading (the chase bearing)
var _look_yaw := 0.0                 # mouse orbit offset (yaw)
var _look_pitch := 0.0               # mouse orbit offset (pitch, 0 = chase height)
var _mouse_idle := 1e9
var _lookat := Vector3.ZERO


func _ready() -> void:
	_car = get_parent().get_parent()
	_yaw = _car_yaw()
	_lookat = _car.global_transform.origin
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look_yaw -= event.relative.x * mouse_sensitivity
		_look_pitch += event.relative.y * mouse_sensitivity
		_look_pitch = clampf(_look_pitch, -0.4, 1.1)
		_mouse_idle = 0.0
	elif event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	var car_pos: Vector3 = _car.global_transform.origin
	var speed_kmh: float = _car.get_linear_velocity().length() * 3.6

	# Chase bearing follows the car's HEADING, not its velocity or its full
	# basis -- crashes, spins and airborne rotation can't fling the view.
	_yaw = lerp_angle(_yaw, _car_yaw(), 1.0 - exp(-follow_speed * delta))

	_mouse_idle += delta
	if _mouse_idle > recenter_delay and speed_kmh > 8.0:
		_look_yaw = move_toward(_look_yaw, 0.0,
				recenter_speed * delta * (absf(_look_yaw) + 0.05))
		_look_pitch = move_toward(_look_pitch, 0.0,
				recenter_speed * delta * (absf(_look_pitch) + 0.05))

	var total_yaw := _yaw + _look_yaw
	var pitch := CHASE_PITCH + _look_pitch
	var offset: Vector3 = Basis(Vector3.UP, total_yaw) \
			* Vector3(0.0, sin(pitch) * target_distance, cos(pitch) * target_distance)
	var target_pos: Vector3 = car_pos + Vector3(0.0, target_height, 0.0) + offset
	# Never dip below just above the car's own plane (jumps, cresting hills).
	target_pos.y = maxf(target_pos.y, car_pos.y + 0.5)
	global_position = global_position.lerp(target_pos, 1.0 - exp(-follow_speed * delta))

	# Look ahead of the car while chasing; while free-looking, look at the
	# car itself (the ahead-offset fades out with the orbit offset).
	var ahead := look_ahead * exp(-absf(_look_yaw) * 2.0) \
			* (1.0 - clampf(absf(_look_pitch), 0.0, 1.0))
	var look_target: Vector3 = car_pos + Vector3(0.0, 0.8, 0.0) \
			- Basis(Vector3.UP, _yaw) * Vector3(0.0, 0.0, 1.0) * ahead
	_lookat = _lookat.lerp(look_target, 1.0 - exp(-follow_speed * delta))
	look_at(_lookat, Vector3.UP)

	# Speed FOV kick.
	fov = base_fov + speed_fov * clampf(speed_kmh / 220.0, 0.0, 1.0)


## The car's horizontal heading as a yaw angle whose Basis(UP, yaw).z points
## BACKWARD from the car (where the chase camera sits). Falls back to the
## last bearing when the car points straight up or down (mid-flip).
func _car_yaw() -> float:
	var fwd := -_car.global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-6:
		return _yaw
	var behind := -fwd.normalized()
	return atan2(behind.x, behind.z)
