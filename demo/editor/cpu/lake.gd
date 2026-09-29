extends Node3D

# Sample-point buoyancy showcase (demo/common/buoyant_body.gd) -- three
# pre-tuned floaters dropped onto a flat Phase-1 water plane (no waves/FFT/
# caustics yet, see buoyant_body.gd's own header), plus SPACE to drop more at
# random. The three starting props deliberately use different
# buoyancy_strength/mass ratios off the one proven data point (buoyancy_test.gd:
# a 50kg 2x1x2 hull with strength=400 settles a bit below the waterline) to
# show a visibly higher/lower float depth, not a real per-object density model.
#
#   SPACE  drop a random floater      R  reset      ESC  quit

const WATER_LEVEL := 0.0

@onready var _hud: Label = $HUD/Label
var _floaters: Array[RigidBody3D] = []

func _ready() -> void:
	for c in $Floaters.get_children():
		if c is RigidBody3D:
			_floaters.append(c)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_drop_random()
			KEY_R:
				get_tree().reload_current_scene()
			KEY_ESCAPE:
				get_tree().quit()

func _drop_random() -> void:
	var kinds := ["ball", "crate", "log"]
	var kind: String = kinds[randi() % kinds.size()]
	var rb := RigidBody3D.new()
	rb.set_script(load("res://demo/common/buoyant_body.gd"))
	rb.water_level = WATER_LEVEL
	rb.can_sleep = false

	var cs := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(randf(), 0.5, 0.9)
	mi.material_override = mat

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
			rb.sample_points = [Vector3(-1.3, 0, -0.25), Vector3(1.3, 0, -0.25), Vector3(-1.3, 0, 0.25), Vector3(1.3, 0, 0.25)]

	rb.add_child(cs)
	rb.add_child(mi)
	rb.position = Vector3(randf_range(-3.0, 3.0), 6.0, randf_range(-3.0, 3.0))
	rb.rotation = Vector3(randf_range(-0.3, 0.3), randf_range(0, TAU), randf_range(-0.3, 0.3))
	$Floaters.add_child(rb)
	_floaters.append(rb)

func _process(_dt: float) -> void:
	_hud.text = "Sample-point buoyancy (demo/common/buoyant_body.gd)   SPACE drop   R reset   ESC\nfloaters: %d   FPS: %d" % [
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
