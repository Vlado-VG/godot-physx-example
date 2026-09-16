extends Camera3D

# Chase camera, ported from the old Car-Demo CameraFollow.gd (unchanged
# behavior: lazy follow at a fixed distance/height, smoothed look-at).

@export var target_distance := 5.0
@export var target_height := 2.0
@export var follow_speed := 10.0

var _last_lookat: Vector3


func _ready() -> void:
	var car: Node3D = get_parent().get_parent()
	_last_lookat = car.global_transform.origin


func _physics_process(delta: float) -> void:
	var car: Node3D = get_parent().get_parent()
	var delta_v := global_transform.origin - car.global_transform.origin
	var target_pos := global_transform.origin

	# Ignore vertical separation when restoring the follow distance.
	delta_v.y = 0.0
	if delta_v.length() > target_distance:
		delta_v = delta_v.normalized() * target_distance
		delta_v.y = target_height
		target_pos = car.global_transform.origin + delta_v
	else:
		target_pos.y = car.global_transform.origin.y + target_height

	global_position = global_position.lerp(target_pos, delta * follow_speed)
	_last_lookat = _last_lookat.lerp(car.global_transform.origin, delta * follow_speed)
	look_at(_last_lookat, Vector3.UP)
