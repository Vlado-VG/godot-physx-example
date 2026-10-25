extends SceneTree

# PhysXSkinnedCloth3D takes its rest lengths from the garment as WORN: on a
# scaled skeleton (a scaled bone pose, a scaled skeleton node) the strip keeps
# the length it is skinned to. Rest lengths came from the mesh's bind-space
# vertices, so a garment skinned bigger than its mesh contracted toward its
# pins (kezsonaj 0002).
# A 0.2 x 1 m strip pinned along its top row hangs under gravity on three rigs:
#   1. bone 0 posed at scale 1.3: hangs ~1.3 m (was 0.84: contracted, curled);
#   2. the Skeleton3D node at scale 1.5: hangs ~1.0 m in the mesh's own space
#      (= 1.5 m in the world; was 0.48);
#   3. unscaled: hangs ~1.0 m, as before.
# Needs a window (the cloth solver is a compute shader):
#   godot --path . --script res://test/gpu/skinned_cloth_scaled_rest_test.gd

var _rigs := []
var _t := 0
var _ok := true


func _check(cond: bool, msg: String) -> void:
	print("[cloth_scale] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


# A two-bone skeleton (bone 1 one metre up from bone 0) with a 0.2 x 1 m strip
# skinned to bone 1, pinned along its top row. Returns the cloth node.
func _rig(x: float, bone_scale: float, node_scale: float) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(x, 0, 0)
	get_root().add_child(root)
	var sk := Skeleton3D.new()
	sk.add_bone("root")
	sk.add_bone("tip")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 1, 0)))
	sk.reset_bone_poses()
	sk.set_bone_pose_scale(0, Vector3.ONE * bone_scale)
	sk.scale = Vector3.ONE * node_scale
	root.add_child(sk)

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

	var cloth: Node3D = ClassDB.instantiate("PhysXSkinnedCloth3D")
	var dist := PackedFloat32Array()
	for r in ROWS:
		for c in 2:
			dist.append(0.0 if r == ROWS - 1 else 2.0)
	cloth.set("max_distances", dist)
	sk.add_child(cloth)
	cloth.set("mesh_instance_path", cloth.get_path_to(mi))
	return cloth


# Particle positions in the strip mesh's local space (= the skeleton's).
func _positions(cloth: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for n in cloth.get_parent().get_children(true):
		if n is MeshInstance3D and n.name != "Strip":
			var mat: ShaderMaterial = (n as MeshInstance3D).get_surface_override_material(0)
			var tex: Texture2DRD = mat.get_shader_parameter("cloth_positions") if mat else null
			if tex == null:
				continue
			var f := RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0).to_float32_array()
			for i in int(cloth.call("get_particle_count")):
				out.append(Vector3(f[i * 4], f[i * 4 + 1], f[i * 4 + 2]))
	return out


# How far the strip hangs below its pinned top row, in the mesh's local space.
func _hang(cloth: Node3D) -> float:
	var p := _positions(cloth)
	if p.is_empty():
		return 0.0
	var hi := -INF
	var lo := INF
	for v in p:
		hi = maxf(hi, v.y)
		lo = minf(lo, v.y)
	return hi - lo


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXSkinnedCloth3D"):
		print("[cloth_scale] SKIP: no PhysXSkinnedCloth3D")
		quit(0)
		return
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.look_at_from_position(Vector3(2, 1.5, 7), Vector3(2, 1.5, 0))
	_rigs = [_rig(0, 1.3, 1.0), _rig(2, 1.0, 1.5), _rig(4, 1.0, 1.0)]
	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	if _t != 180:
		return
	# Local space: rig 1's mesh is unscaled, so local = world (worn length 1.3);
	# rig 2's mesh carries the node's 1.5, so its worn 1.5 m reads 1.0 here.
	var h0 := _hang(_rigs[0])
	var h1 := _hang(_rigs[1])
	var h2 := _hang(_rigs[2])
	_check(h0 > 1.2, "bone posed at scale 1.3: the strip hangs %.2f m (want ~1.3; was 0.84 on bind-space rest lengths)" % h0)
	_check(h1 > 0.9, "skeleton node at scale 1.5: the strip hangs %.2f in its own space (want ~1.0; was 0.48 on bind-space rest lengths)" % h1)
	_check(h2 > 0.9 and h2 < 1.15, "unscaled: the strip hangs %.2f m (want ~1.0)" % h2)
	print("[cloth_scale] ", "PASS" if _ok else "FAIL")
	quit(0 if _ok else 1)
