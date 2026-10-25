extends SceneTree

# A capsule CharacterBody3D (Godot's default capsule, radius 0.5) walking with move_and_slide onto a raised plate in a
# single trimesh -- a floor slab and the plate as one ConcavePolygonShape3D -- for a range of lip heights. It must get
# up the lips its rounded bottom meets at a slope gentler than floor_max_angle (45 degrees: up to
# 0.5 * (1 - cos 45) = 0.146 m) and stop at taller ones, as on Jolt (EXPECTED, measured on Jolt). Run with an
# override.cfg setting physics/3d/physics_engine to compare engines.
const EXPECTED := {0.02: true, 0.05: true, 0.10: true, 0.15: true, 0.20: false, 0.25: false, 0.30: false, 0.40: false}

var _heights: Array = EXPECTED.keys()
var _h := 0
var _t := 0
var _root: Node3D
var _char: CharacterBody3D
var _pass := true


func _initialize() -> void:
	print("[lip] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))
	_build()
	physics_frame.connect(_step)


func _box_faces(size: Vector3, centre: Vector3) -> PackedVector3Array:
	var bm := BoxMesh.new()
	bm.size = size
	var faces := bm.get_faces()
	for i in faces.size():
		faces[i] += centre
	return faces


func _build() -> void:
	if _root:
		_root.free()
	_root = Node3D.new()
	get_root().add_child(_root)
	var lip: float = _heights[_h]
	# The slab's top at y = 0; the plate from x = 1 on, its top at y = lip.
	var faces := _box_faces(Vector3(20, 1, 20), Vector3(0, -0.5, 0))
	faces.append_array(_box_faces(Vector3(10, lip, 20), Vector3(6, lip * 0.5, 0)))
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	_root.add_child(body)
	_char = CharacterBody3D.new()
	var ccs := CollisionShape3D.new()
	ccs.shape = CapsuleShape3D.new()
	_char.add_child(ccs)
	_root.add_child(_char)
	_char.position = Vector3(-1.0, 1.0, 0.0) # (local: the first build runs before the tree is up)
	_t = 0


func _step() -> void:
	_t += 1
	if _t > 20:
		_char.velocity.x = 5.0
	if not _char.is_on_floor():
		_char.velocity.y -= 9.8 / 60.0
	else:
		_char.velocity.y = 0.0
	_char.move_and_slide()
	if _t == 120:
		var lip: float = _heights[_h]
		var up := _char.global_position.x > 1.6 and _char.global_position.y > 1.0 + lip * 0.5
		var ok: bool = up == EXPECTED[lip]
		_pass = _pass and ok
		print("  %.2f m lip: %s%s (x %.2f, y %.3f)" % [lip, "climbs" if up else "stops", "" if ok else "   <-- FAIL, Jolt: " + ("climbs" if EXPECTED[lip] else "stops"), _char.global_position.x, _char.global_position.y])
		_h += 1
		if _h >= _heights.size():
			print("[lip] ", "PASS" if _pass else "FAIL")
			quit(0 if _pass else 1)
			return
		_build()
