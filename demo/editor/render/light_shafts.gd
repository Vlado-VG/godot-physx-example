extends Node3D

# PhysXLightShafts3D: screen-space light shafts from the sun, next to Godot's own
# volumetric fog for comparison. A low sun behind a colonnade, a lattice window,
# a slatted wall and a small grove (plain MeshInstance3D nodes in the scene):
# the shafts stream from the sun through the gaps and darken along everything
# that blocks it, with no fog in the scene; the fog lights up its whole volume
# instead.
#
#   1        light shafts on / off
#   2        Godot's volumetric fog on / off (Forward+ only: Mobile has none)
#   M        mode: shaft bloom and occlusion / shaft bloom / shaft occlusion
#   arrows   move the sun
#   WASD + right mouse   fly the camera

@onready var _env: Environment = $WorldEnvironment.environment
@onready var _sun: DirectionalLight3D = $Sun
@onready var _shafts: Node3D = $Sun/PhysXLightShafts3D
@onready var _cam: Camera3D = $Camera3D
@onready var _label: Label = $HUD/Label


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_1:
			_shafts.visible = not _shafts.visible
		KEY_2:
			_env.volumetric_fog_enabled = not _env.volumetric_fog_enabled
		KEY_M:
			_shafts.set("mode", (int(_shafts.get("mode")) + 1) % 3)
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var turn := Vector2(Input.get_axis("ui_left", "ui_right"), Input.get_axis("ui_down", "ui_up"))
	if turn != Vector2.ZERO:
		_sun.rotation_degrees.y -= turn.x * 20.0 * delta
		_sun.rotation_degrees.x = clampf(_sun.rotation_degrees.x - turn.y * 10.0 * delta, -60.0, -1.0)
	var on := ["off", "on"]
	var modes := ["shaft bloom and occlusion", "shaft bloom", "shaft occlusion"]
	var vp_rid := get_viewport().get_viewport_rid()
	_label.text = "Light shafts: %s [1]   mode: %s [M]   Godot volumetric fog (Forward+ only): %s [2]\narrows: move the sun (pitch %.1f, yaw %.1f)   WASD + right mouse: fly\nFPS %d   render gpu %.2f ms\ncamera pos (%.2f, %.2f, %.2f) rot (%.1f, %.1f, %.1f)" % [
		on[int(_shafts.visible)], modes[int(_shafts.get("mode"))], on[int(_env.volumetric_fog_enabled)],
		_sun.rotation_degrees.x, _sun.rotation_degrees.y,
		Engine.get_frames_per_second(), RenderingServer.viewport_get_measured_render_time_gpu(vp_rid),
		_cam.position.x, _cam.position.y, _cam.position.z,
		_cam.rotation_degrees.x, _cam.rotation_degrees.y, _cam.rotation_degrees.z]
