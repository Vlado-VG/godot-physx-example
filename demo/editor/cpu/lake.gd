extends Node3D

# Sample-point buoyancy showcase (demo/common/buoyant_body.gd) -- three
# pre-tuned floaters on the real PhysXWaterSurface3D (see lake.tscn), plus
# SPACE to drop more at random and left-click-drag to shove any floater
# around by hand -- a real, direct way to disturb the water (see
# buoyant_body.gd's height-proximity-gated submit_sphere() for why this
# actually ripples the surface instead of just moving a prop around). The
# three starting props deliberately use different buoyancy_strength/mass
# ratios off the one proven data point (buoyancy_test.gd: a 50kg 2x1x2 hull
# with strength=400 settles a bit below the waterline) to show a visibly
# higher/lower float depth, not a real per-object density model.
#
#   SPACE  drop a random floater   left-drag  shove a floater
#   WASD/Space/Ctrl  fly   hold RMB  look   R  reset   ESC  quit

const WATER_LEVEL := 0.0
# Spring-pull-toward-mouse drag, not a hard position snap -- keeps the
# dragged body inside the real physics simulation (still collides, still
# feeds a real linear_velocity into buoyant_body.gd's wake-strength coupling,
# so dragging naturally disturbs the water with zero special-casing). Scaled
# by the body's own mass so the drag "feels" similarly stiff regardless of
# which floater (15-60 kg) is grabbed.
const DRAG_SPRING := 60.0
const DRAG_DAMPING := 12.0

@onready var _hud: Label = $HUD/Label
@onready var _camera: Camera3D = $Camera3D
@onready var _floor_mesh: MeshInstance3D = $Pool/Floor/MeshInstance3D
@onready var _water: PhysXWaterSurface3D = $Water
var _caustics_shader: Shader
var _caustics_texture: Texture2D
var _floaters: Array[RigidBody3D] = []
var _dragging: RigidBody3D = null
var _drag_height := 0.0 # world Y of the horizontal plane dragging happens along, frozen at grab time
var _fly: FlyCamera
var _caustics_bound := false # get_caustics_texture() is null until the water node builds (never in the editor) -- bind once available, not every frame
@export var absorption_color := Color(0.012, 0.07, 0.12, 1.0):
	set(value):
		absorption_color = value
		_update_receiver_absorption()
@export_range(0.0, 2.0, 0.01) var absorption_density := 0.55:
	set(value):
		absorption_density = value
		_update_receiver_absorption()

func _ready() -> void:
	_caustics_shader = (_floor_mesh.material_override as ShaderMaterial).shader
	_update_receiver_absorption()
	for c in $Floaters.get_children():
		if c is RigidBody3D:
			_floaters.append(c)
	_fly = FlyCamera.new(_camera)

func _unhandled_input(event: InputEvent) -> void:
	# FlyCamera only claims RMB (look toggle) and mouse-motion-while-captured
	# -- left-click drag and every key below are untouched either way.
	if _fly.handle_input(event):
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_drop_random()
			KEY_R:
				get_tree().reload_current_scene()
			KEY_ESCAPE:
				get_tree().quit()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_start_drag(event.position)
		else:
			_dragging = null

func _try_start_drag(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * 200.0)
	var result := get_world_3d().direct_space_state.intersect_ray(params)
	if result.is_empty():
		return
	var body = result.get("collider")
	if body is RigidBody3D and body in _floaters:
		_dragging = body
		_drag_height = body.global_position.y

func _drag_target(screen_pos: Vector2) -> Vector3:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var plane := Plane(Vector3.UP, _drag_height)
	var hit = plane.intersects_ray(from, dir)
	return hit if hit != null else from + dir * 10.0 # camera looking ~parallel to the plane -- fall back to a fixed distance

func _physics_process(_delta: float) -> void:
	if _dragging == null:
		return
	if not is_instance_valid(_dragging):
		_dragging = null
		return
	var target := _drag_target(get_viewport().get_mouse_position())
	var offset := target - _dragging.global_position
	var force := offset * DRAG_SPRING * _dragging.mass - _dragging.linear_velocity * DRAG_DAMPING * _dragging.mass
	_dragging.apply_central_force(force)

func _drop_random() -> void:
	var kinds := ["ball", "crate", "log"]
	var kind: String = kinds[randi() % kinds.size()]
	var rb := RigidBody3D.new()
	rb.set_script(load("res://demo/common/buoyant_body.gd"))
	rb.water_level = WATER_LEVEL
	rb.can_sleep = false

	var cs := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	var mat := ShaderMaterial.new()
	mat.shader = _caustics_shader
	mat.set_shader_parameter("albedo_color", Color.from_hsv(randf(), 0.5, 0.9))
	mat.set_shader_parameter("roughness_val", 0.8)
	mat.set_shader_parameter("caustics_half_extent", 10.0)
	mat.set_shader_parameter("caustics_filter_radius", 1.5)
	mat.set_shader_parameter("caustics_surface_fade_depth", 1.25)
	mat.set_shader_parameter("caustic_strength", 1.0)
	mat.set_shader_parameter("absorption_color", absorption_color)
	mat.set_shader_parameter("absorption_density", absorption_density)
	mi.material_override = mat
	_bind_caustics_to_material(mat)

	match kind:
		"ball":
			var shape := SphereShape3D.new()
			shape.radius = 0.6
			cs.shape = shape
			var m := SphereMesh.new()
			m.radius = 0.6
			m.height = 1.2
			mi.mesh = m
			rb.mass = 15.0
			rb.buoyancy_strength = 350.0
			rb.water_drag = 90.0
			rb.hull_radius = 0.7
			rb.sample_points = [Vector3(-0.4, 0, -0.4), Vector3(0.4, 0, -0.4), Vector3(-0.4, 0, 0.4), Vector3(0.4, 0, 0.4)]
		"crate":
			var shape := BoxShape3D.new()
			shape.size = Vector3(2, 1, 2)
			cs.shape = shape
			var m := BoxMesh.new()
			m.size = shape.size
			mi.mesh = m
			rb.mass = 50.0
			rb.buoyancy_strength = 400.0
			rb.water_drag = 100.0
			rb.hull_radius = 1.4
			# default sample_points already match this hull's footprint
		"log":
			var shape := BoxShape3D.new()
			shape.size = Vector3(2.6, 0.6, 0.6)
			cs.shape = shape
			var m := BoxMesh.new()
			m.size = shape.size
			mi.mesh = m
			rb.mass = 60.0
			rb.buoyancy_strength = 380.0
			rb.water_drag = 95.0
			rb.hull_radius = 1.3
			rb.sample_points = [Vector3(-1.3, 0, -0.25), Vector3(1.3, 0, -0.25), Vector3(-1.3, 0, 0.25), Vector3(1.3, 0, 0.25)]

	# water_surface_path must be set BEFORE add_child() -- buoyant_body.gd
	# resolves it in _ready(), which fires as soon as the node enters the
	# tree. An absolute path works before rb itself is in the tree (get_path_
	# to() would not, since that needs both nodes already in the same tree).
	if has_node("Water"):
		rb.water_surface_path = $Water.get_path()

	rb.add_child(cs)
	rb.add_child(mi)
	rb.position = Vector3(randf_range(-3.0, 3.0), 6.0, randf_range(-3.0, 3.0))
	rb.rotation = Vector3(randf_range(-0.3, 0.3), randf_range(0, TAU), randf_range(-0.3, 0.3))
	$Floaters.add_child(rb)
	_floaters.append(rb)

func _process(delta: float) -> void:
	_fly.process(delta)

	if not _caustics_bound:
		_caustics_texture = _water.get_caustics_texture()
		if _caustics_texture != null:
			for receiver_root in [$Pool, $Floaters]:
				for node in receiver_root.find_children("*", "MeshInstance3D", true, false):
					var receiver := node as MeshInstance3D
					var material := receiver.material_override as ShaderMaterial
					if material != null and material.shader == _caustics_shader:
						_bind_caustics_to_material(material)
			_caustics_bound = true

	_hud.text = "Sample-point buoyancy (demo/common/buoyant_body.gd)   SPACE drop   left-drag shove   WASD/hold-RMB fly   R reset   ESC\nfloaters: %d   FPS: %d" % [
		_floaters.size(), Engine.get_frames_per_second()]

	# The pool has real walls/floor (see the scene) -- this is just a deep
	# safety net for anything that somehow escapes them.
	for i in range(_floaters.size() - 1, -1, -1):
		var f := _floaters[i]
		if not is_instance_valid(f):
			_floaters.remove_at(i)
		elif f.global_position.y < -20.0:
			f.queue_free()
			_floaters.remove_at(i)

func _bind_caustics_to_material(material: ShaderMaterial) -> void:
	if _caustics_texture == null:
		return
	material.set_shader_parameter("caustics_tex", _caustics_texture)
	material.set_shader_parameter("caustics_origin", _water.get_caustics_origin())
	material.set_shader_parameter("caustics_light_right", _water.get_caustics_light_right())
	material.set_shader_parameter("caustics_light_up", _water.get_caustics_light_up())
	material.set_shader_parameter("caustics_sun_direction", _water.get_caustics_sun_direction())
	material.set_shader_parameter("caustics_half_extent", _water.get_caustics_half_extent())

func _update_receiver_absorption() -> void:
	if not is_node_ready():
		return
	for receiver_root in [$Pool, $Floaters]:
		for node in receiver_root.find_children("*", "MeshInstance3D", true, false):
			var receiver := node as MeshInstance3D
			var material := receiver.material_override as ShaderMaterial
			if material != null and material.shader == _caustics_shader:
				material.set_shader_parameter("absorption_color", absorption_color)
				material.set_shader_parameter("absorption_density", absorption_density)
