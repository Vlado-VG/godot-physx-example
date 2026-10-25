extends SceneTree

# PhysXSkinnedCloth3D collides with BOX collision shapes on physical bones
# (U22: only capsules and spheres were read, boxes ignored), and reads the
# shapes live (they were read once at build):
#   a 0.2 x 1 m strip pinned along its top edge swings toward +Z under
#   sideways gravity into a box on a PhysicalBone3D (box faces z 0.25..0.45);
#   1. it stops at the box (furthest z < 0.3; swings to ~1 m without it);
#   2. the box made thicker toward the strip (z 0.15..0.45) pushes it back;
#   3. the shape disabled: the strip swings through (furthest z > 0.6).
# Needs a window (the cloth solver is a compute shader):
#   godot --path . --script res://test/gpu/skinned_cloth_box_bone_test.gd

var _cloth: Node3D
var _shape: CollisionShape3D
var _t := 0
var _ok := true


func _check(cond: bool, msg: String) -> void:
	print("[cloth_box] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXSkinnedCloth3D"):
		print("[cloth_box] SKIP: no PhysXSkinnedCloth3D")
		quit(0)
		return
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.look_at_from_position(Vector3(3, 1.5, 3), Vector3(0, 1.4, 0.3))

	var sk := Skeleton3D.new()
	sk.add_bone("root")
	sk.add_bone("tip")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 1, 0)))
	sk.reset_bone_poses()
	get_root().add_child(sk)

	# A physical skeleton with one bone carrying a box (not simulating).
	var sim := PhysicalBoneSimulator3D.new()
	sk.add_child(sim)
	var pb := PhysicalBone3D.new()
	pb.bone_name = "root"
	sim.add_child(pb)
	_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 1.4, 0.2)
	_shape.shape = box
	_shape.position = Vector3(0.1, 1.5, 0.35)
	pb.add_child(_shape)

	const ROWS := 9
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var idx := PackedInt32Array()
	for r in ROWS:
		for c in 2:
			verts.append(Vector3(c * 0.2, 1.0 + float(r) / (ROWS - 1), 0))
			normals.append(Vector3(0, 0, 1))
			uvs.append(Vector2(c, float(r) / (ROWS - 1)))
			bones.append_array([0, 0, 0, 0])
			weights.append_array([1.0, 0.0, 0.0, 0.0])
	for r in ROWS - 1:
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, StandardMaterial3D.new())
	var skin := Skin.new()
	skin.add_bind(1, Transform3D(Basis(), Vector3(0, -1, 0)))
	var mi := MeshInstance3D.new()
	mi.name = "Strip"
	mi.mesh = mesh
	mi.skin = skin
	sk.add_child(mi)
	mi.skeleton = mi.get_path_to(sk)

	_cloth = ClassDB.instantiate("PhysXSkinnedCloth3D")
	var dist := PackedFloat32Array()
	for r in ROWS:
		for c in 2:
			dist.append(0.0 if r == ROWS - 1 else 2.0)
	_cloth.set("max_distances", dist)
	sk.add_child(_cloth)
	_cloth.set("mesh_instance_path", _cloth.get_path_to(mi))
	physics_frame.connect(_tick)


func _positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for n in _cloth.get_parent().get_children(true):
		if n is MeshInstance3D and n.name != "Strip":
			var mat: ShaderMaterial = (n as MeshInstance3D).get_surface_override_material(0)
			var tex: Texture2DRD = mat.get_shader_parameter("cloth_positions") if mat else null
			if tex == null:
				continue
			var f := RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0).to_float32_array()
			for i in int(_cloth.call("get_particle_count")):
				out.append(Vector3(f[i * 4], f[i * 4 + 1], f[i * 4 + 2]))
	return out


func _z_range() -> Vector2:
	var lo := INF
	var hi := -INF
	for v in _positions():
		lo = minf(lo, v.z)
		hi = maxf(hi, v.z)
	return Vector2(lo, hi)


func _tick() -> void:
	_t += 1
	if _t == 10:
		PhysicsServer3D.area_set_param(get_root().get_world_3d().space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3(0, 0, 1))
		var caps: Array = _cloth.call("get_body_capsules")
		var boxes := caps.filter(func(d: Dictionary) -> bool: return d.get("box", false))
		_check(boxes.size() == 1, "the physical bone's box is a collider (%d of %d colliders are boxes)" % [boxes.size(), caps.size()])
	if _t == 150:
		var z := _z_range()
		_check(z.y > 0.1 and z.y < 0.3, "the strip swings into the box and stops at its face (furthest z %.2f, want 0.1..0.3)" % z.y)
		# Thicker toward the strip, live: face at z 0.15.
		(_shape.shape as BoxShape3D).size = Vector3(1.0, 1.4, 0.3)
		_shape.position = Vector3(0.1, 1.5, 0.3)
	if _t == 270:
		var z := _z_range()
		_check(z.y < 0.2, "the box resized live pushes the strip back (furthest z %.2f, want < 0.2)" % z.y)
		_shape.disabled = true
	if _t == 420:
		var z := _z_range()
		_check(z.y > 0.6, "the shape disabled live: the strip swings through (furthest z %.2f, want > 0.6)" % z.y)
		print("[cloth_box] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)
