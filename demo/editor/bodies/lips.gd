@tool
extends Node3D

# Plain capsules walking up a lip in a triangle mesh -- no SeparationRayShape3D (stairs.tscn has that). Each lane is
# one ConcavePolygonShape3D: a floor slab and a raised plate, the lip between them 2 to 30 cm tall. A CharacterBody3D
# with Godot's default capsule (radius 0.5) gets up a lip the rounded bottom meets at a slope gentler than its
# floor_max_angle (45 degrees): up to about 0.5 * (1 - cos 45) = 0.146 m. So the bots climb the 15 cm lip and stop at
# 20 cm, on PhysX and Jolt alike. The lanes are built by this script, in the editor too.
#
#   WASD move   SPACE jump   click: capture mouse / look   ESC release mouse
#   R reset

const LIPS := [0.02, 0.05, 0.10, 0.15, 0.20, 0.30]
const LANE_SPACING := 3.0
const BOT_SPEED := 2.0
const BOT_GRAVITY := 18.0
const BOT_LOOP := 4.0 # s, then the bots start over

var _bots: Array[CharacterBody3D] = []
var _labels: Array[Label3D] = []
var _bot_time := 0.0
var _fp: FirstPersonCharacter


func _ready() -> void:
	_build_lanes()
	if Engine.is_editor_hint():
		return
	_fp = FirstPersonCharacter.new($Player, $Player/Camera3D, self)


func _box_faces(size: Vector3, centre: Vector3) -> PackedVector3Array:
	var bm := BoxMesh.new()
	bm.size = size
	var faces := bm.get_faces()
	for i in faces.size():
		faces[i] += centre
	return faces


# Each lane: one trimesh (slab, plate) with a matching mesh, a bot at its start, a label over the lip. Not owned by
# the scene, so nothing generated is saved into it.
func _build_lanes() -> void:
	var old := get_node_or_null("Lanes")
	if old:
		old.free()
	var lanes := Node3D.new()
	lanes.name = "Lanes"
	add_child(lanes)
	var lane_mat := StandardMaterial3D.new()
	lane_mat.albedo_color = Color(0.42, 0.46, 0.55)
	var bot_mat := StandardMaterial3D.new()
	bot_mat.albedo_color = Color(0.9, 0.6, 0.25)
	for i in LIPS.size():
		var lip: float = LIPS[i]
		var x := (i - (LIPS.size() - 1) * 0.5) * LANE_SPACING
		# The slab's top at y = 0 from z = 4 to z = 0, the plate's at y = lip from z = 0 to z = -4.
		var faces := _box_faces(Vector3(2.4, 0.2, 4.0), Vector3(0, -0.1, 2.0))
		faces.append_array(_box_faces(Vector3(2.4, 0.2 + lip, 4.0), Vector3(0, (lip - 0.2) * 0.5, -2.0)))
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		var body := StaticBody3D.new()
		body.name = "Lane%d" % i
		body.position = Vector3(x, 0, 0)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = faces
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = lane_mat
		body.add_child(mi)
		lanes.add_child(body)

		var label := Label3D.new()
		label.text = "%d cm lip" % roundi(lip * 100.0)
		label.font_size = 48
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = Vector3(x, 1.8 + lip, -0.5)
		lanes.add_child(label)
		_labels.append(label)

		var bot := CharacterBody3D.new()
		var bcs := CollisionShape3D.new()
		bcs.shape = CapsuleShape3D.new()
		bcs.position = Vector3(0, 1.0, 0)
		bot.add_child(bcs)
		var bmi := MeshInstance3D.new()
		bmi.mesh = CapsuleMesh.new()
		bmi.material_override = bot_mat
		bmi.position = Vector3(0, 1.0, 0)
		bot.add_child(bmi)
		bot.position = Vector3(x, 0.05, 3.0)
		lanes.add_child(bot)
		_bots.append(bot)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_fp.physics_process(delta)
	_bot_time += delta
	if _bot_time > BOT_LOOP:
		_bot_time = 0.0
		for bot in _bots:
			bot.position = Vector3(bot.position.x, 0.05, 3.0)
			bot.velocity = Vector3.ZERO
	for i in _bots.size():
		var bot := _bots[i]
		var v := bot.velocity
		v.z = -BOT_SPEED
		v.y = -0.1 if bot.is_on_floor() else v.y - BOT_GRAVITY * delta
		bot.velocity = v
		bot.move_and_slide()
		# Up on the plate once past the lip and at its height.
		var lip: float = LIPS[i]
		if bot.position.z < -0.6:
			_labels[i].text = "%d cm lip: climbs" % roundi(lip * 100.0)
		elif _bot_time > BOT_LOOP - 0.5:
			_labels[i].text = "%d cm lip: stops" % roundi(lip * 100.0)


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if _fp.handle_input(event):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else:
					get_tree().quit()
			KEY_R:
				get_tree().reload_current_scene()
