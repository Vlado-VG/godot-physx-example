extends SceneTree

# PhysXSkinnedCloth3D on one surface of a multi-surface mesh hides only that
# surface (U22: it hid the whole MeshInstance3D, so a character imported as one
# mesh -- body, hair, garments as surfaces -- vanished but for the cloth).
# One skinned mesh: surface 0 a red "body" panel, surface 1 a white strip made
# cloth, swinging toward the camera under sideways gravity (seen from above):
#   1. the body panel still draws, and the node stays visible;
#   2. the strip's own (unsimulated) copy is hidden: where it stood, nothing
#      white is left once the cloth has swung away, and the simulated strip
#      draws where it swung to;
#   3. the user's own override material on the strip's surface is back once the
#      cloth node is removed.
# Needs a window (the cloth solver is a compute shader):
#   godot --path . --script res://test/gpu/skinned_cloth_surface_hide_test.gd

var _mi: MeshInstance3D
var _cloth: Node3D
var _cam: Camera3D
var _user_mat: StandardMaterial3D
var _t := 0
var _ok := true


func _check(cond: bool, msg: String) -> void:
	print("[cloth_hide] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _panel(verts: PackedVector3Array, x0: float, x1: float, rows: int) -> void:
	for r in rows:
		for c in 2:
			verts.append(Vector3(lerpf(x0, x1, c), 1.0 + float(r) / (rows - 1), 0))


func _surface(mesh: ArrayMesh, x0: float, x1: float, rows: int, col: Color) -> void:
	var verts := PackedVector3Array()
	_panel(verts, x0, x1, rows)
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var idx := PackedInt32Array()
	for i in verts.size():
		normals.append(Vector3(0, 0, 1))
		uvs.append(Vector2(i % 2, float(i / 2) / (rows - 1)))
		bones.append_array([0, 0, 0, 0])
		weights.append_array([1.0, 0.0, 0.0, 0.0])
	for r in rows - 1:
		var a := r * 2
		idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(mesh.get_surface_count() - 1, m)


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXSkinnedCloth3D"):
		print("[cloth_hide] SKIP: no PhysXSkinnedCloth3D")
		quit(0)
		return
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.1, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	we.environment = env
	get_root().add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 20, 0)
	get_root().add_child(sun)
	_cam = Camera3D.new()
	get_root().add_child(_cam)
	_cam.look_at_from_position(Vector3(1.5, 2.8, 2.5), Vector3(0.3, 1.6, 0.3))

	var sk := Skeleton3D.new()
	sk.add_bone("root")
	sk.add_bone("tip")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 1, 0)))
	sk.reset_bone_poses()
	get_root().add_child(sk)

	var mesh := ArrayMesh.new()
	_surface(mesh, 0.6, 1.0, 2, Color(0.9, 0.1, 0.1)) # surface 0: the body
	_surface(mesh, -0.2, 0.0, 9, Color(1, 1, 1)) # surface 1: the cloth strip
	var skin := Skin.new()
	skin.add_bind(1, Transform3D(Basis(), Vector3(0, -1, 0)))
	_mi = MeshInstance3D.new()
	_mi.mesh = mesh
	_mi.skin = skin
	sk.add_child(_mi)
	_mi.skeleton = _mi.get_path_to(sk)
	# The user's own override on the cloth surface: put back after.
	_user_mat = StandardMaterial3D.new()
	_user_mat.albedo_color = Color(1, 1, 1)
	_user_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_user_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mi.set_surface_override_material(1, _user_mat)

	_cloth = ClassDB.instantiate("PhysXSkinnedCloth3D")
	_cloth.set("surface", 1)
	var dist := PackedFloat32Array()
	for r in 9:
		for c in 2:
			dist.append(0.0 if r == 8 else 2.0)
	_cloth.set("max_distances", dist)
	sk.add_child(_cloth)
	_cloth.set("mesh_instance_path", _cloth.get_path_to(_mi))
	physics_frame.connect(_tick)


func _px(p: Vector3) -> Color:
	var img := get_root().get_texture().get_image()
	var uv := _cam.unproject_position(p) / get_root().get_visible_rect().size
	return img.get_pixelv(Vector2i(uv * Vector2(img.get_size())))


func _tick() -> void:
	_t += 1
	if _t == 10:
		# Gravity toward the camera: the strip swings out of its rest place and
		# hangs from its pinned top edge toward +Z.
		PhysicsServer3D.area_set_param(get_root().get_world_3d().space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3(0, 0, 1))
	if _t == 150:
		var body := _px(Vector3(0.8, 1.5, 0))
		_check(_mi.visible and body.r > 0.6 and body.g < 0.3, "the body surface still draws (pixel %s), node visible %s" % [body, _mi.visible])
		# Low on the strip's rest place: the cloth has swung away from there, so
		# only the original surface could still be white here.
		var rest := _px(Vector3(-0.1, 1.08, 0))
		_check(rest.v < 0.5, "the strip's own surface is hidden where it stood (pixel %s)" % rest)
		# The simulated strip (white) draws somewhere in the frame.
		var img := get_root().get_texture().get_image()
		var white := 0
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				if img.get_pixel(x, y).v > 0.8 and img.get_pixel(x, y).s < 0.2:
					white += 1
		_check(white > 200, "the simulated strip draws where it swung to (%d white samples)" % white)
		get_root().get_texture().get_image().save_png("user://skinned_cloth_surface_hide_test.png")
		_cloth.get_parent().remove_child(_cloth)
		_cloth.free()
	if _t == 160:
		_check(_mi.get_surface_override_material(1) == _user_mat and _mi.visible, "the user's override is back on the strip's surface once the cloth is gone")
		print("[cloth_hide] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)
