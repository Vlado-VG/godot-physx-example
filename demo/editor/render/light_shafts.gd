extends Node3D

# PhysXLightShafts3D: screen-space light shafts from the sun, next to Godot's own
# volumetric fog for comparison. A low sun behind a colonnade, a lattice window
# and a small grove: the shafts stream from the sun through the gaps and darken
# along everything that blocks it, with no fog in the scene; the fog lights up
# its whole volume instead.
#
#   1        light shafts on / off
#   2        Godot's volumetric fog on / off
#   M        mode: shaft bloom and occlusion / shaft bloom / shaft occlusion
#   arrows   move the sun
#   WASD + right mouse   fly the camera

@onready var _env: Environment = $WorldEnvironment.environment
@onready var _sun: DirectionalLight3D = $Sun
@onready var _shafts: Node3D = $Sun/PhysXLightShafts3D
@onready var _cam: Camera3D = $Camera3D
@onready var _label: Label = $HUD/Label


func _box(size: Vector3, pos: Vector3, rot := Vector3.ZERO) -> void:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	m.mesh = bm
	m.position = pos
	m.rotation_degrees = rot
	add_child(m)


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# A colonnade under a lintel.
	for i in 9:
		_box(Vector3(0.8, 9, 0.8), Vector3(-12 + i * 3, 4.5, -20))
	_box(Vector3(30, 1, 1.5), Vector3(0, 9.5, -20))
	# A lattice window further back, in front of the sun.
	for i in 9:
		_box(Vector3(0.18, 9, 0.3), Vector3(-4 + i, 6.5, -32))
		_box(Vector3(8.4, 0.18, 0.3), Vector3(0, 2.5 + i, -32))
	# A slatted wall to the right.
	for i in 12:
		_box(Vector3(0.25, 6, 0.25), Vector3(8 + i * 0.6, 3, -10))
	# A small grove to the left: trunks and leaning branches.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for t in 5:
		var base := Vector3(-22 + t * 3.2, 0, -26 + rng.randf_range(-2, 2))
		_box(Vector3(0.4, 7, 0.4), base + Vector3(0, 3.5, 0))
		for b in 7:
			var h := rng.randf_range(3.5, 7.5)
			_box(Vector3(rng.randf_range(1.5, 3.5), 0.15, 0.15), base + Vector3(0, h, 0), Vector3(0, rng.randf_range(0, 180), rng.randf_range(-35, 35)))


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
	_label.text = "Light shafts: %s [1]   mode: %s [M]   Godot volumetric fog: %s [2]\narrows: move the sun (pitch %.1f, yaw %.1f)   WASD + right mouse: fly\nFPS %d   render gpu %.2f ms\ncamera pos (%.2f, %.2f, %.2f) rot (%.1f, %.1f, %.1f)" % [
		on[int(_shafts.visible)], modes[int(_shafts.get("mode"))], on[int(_env.volumetric_fog_enabled)],
		_sun.rotation_degrees.x, _sun.rotation_degrees.y,
		Engine.get_frames_per_second(), RenderingServer.viewport_get_measured_render_time_gpu(vp_rid),
		_cam.position.x, _cam.position.y, _cam.position.z,
		_cam.rotation_degrees.x, _cam.rotation_degrees.y, _cam.rotation_degrees.z]
