extends SceneTree

# PhysXBlastAuthoring.fracture_mesh checks its input before Blast sees it, and
# the mesh cleaner's output after (issue #1 U23). Blast trusted the input: an
# index past the vertices was read out of bounds, a partial triangle crashed,
# and a NaN vertex or a mesh collapsed to a point spun the cleaner forever.
#   1. each bad mesh returns null (with an error), at once;
#   2. a BoxMesh (unwelded corners: cleaned) and a welded closed cube (already
#      closed: not cleaned) still fracture into 9 chunks over the 2 m cube;
#   3. a closed cube plus a stray triangle far off: the cleaner drops the stray
#      and its result is kept -- the chunks span the cube, not out to the stray;
#   4. get_last_error() says why each bad mesh was refused (the fracture dialog
#      shows it), and get_last_warnings() reports the dropped stray;
#   5. an inside-out cube (triangles facing in) is flipped, with a warning, and
#      every piece of every result faces outward (inside out, the pieces' outer
#      faces faced in: culled, the pieces looked hollow).
# SKIPs on a build without blast_sdk=.
#   godot --headless --path . --script res://test/cpu/blast_authoring_input_test.gd

var _ok := true


func _check(cond: bool, msg: String) -> void:
	print("[blast_input] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _mesh(verts: PackedVector3Array, idx: PackedInt32Array) -> ArrayMesh:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return m


# A welded 2 m cube: 8 vertices, 12 triangles, front faces (clockwise, as
# Godot draws them) outward -- or inward, inside out.
func _cube_verts() -> PackedVector3Array:
	var v := PackedVector3Array()
	for i in 8:
		v.append(Vector3(-1 if i & 1 == 0 else 1, -1 if i & 2 == 0 else 1, -1 if i & 4 == 0 else 1))
	return v


func _cube_idx(p_inside_out := false) -> PackedInt32Array:
	var idx := PackedInt32Array()
	for q in [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]:
		if p_inside_out:
			idx.append_array([q[0], q[1], q[2], q[0], q[2], q[3]])
		else:
			idx.append_array([q[0], q[2], q[1], q[0], q[3], q[2]])
	return idx


# The worst piece's share of triangles facing away from its own centre (the
# preview's winding: normal (c - a) x (b - a)).
func _outward_share(asset) -> float:
	var worst := 1.0
	var pts: Array = asset.chunk_points
	for i in range(1, pts.size()):
		var tri: PackedVector3Array = pts[i]
		if tri.size() < 3:
			continue
		var centre := Vector3.ZERO
		for p in tri:
			centre += p
		centre /= tri.size()
		var out := 0
		for t in range(0, tri.size() - 2, 3):
			var n := (tri[t + 2] - tri[t]).cross(tri[t + 1] - tri[t])
			if n.dot((tri[t] + tri[t + 1] + tri[t + 2]) / 3.0 - centre) > 0.0:
				out += 1
		worst = minf(worst, float(out) / (tri.size() / 3))
	return worst


func _span(asset) -> AABB:
	var b := AABB()
	var first := true
	for chunk in asset.chunk_points:
		for p in chunk:
			if first:
				b = AABB(p, Vector3.ZERO)
				first = false
			else:
				b = b.expand(p)
	return b


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXBlastAuthoring"):
		print("[blast_input] PhysXBlastAuthoring not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return
	var authoring = ClassDB.instantiate("PhysXBlastAuthoring")

	# Each bad mesh, and a word its error must contain.
	var bad := {}
	var idx := _cube_idx()
	idx[5] = 500
	bad["an index past the vertices"] = [_mesh(_cube_verts(), idx), "points past"]
	var v := _cube_verts()
	v[3] = Vector3(NAN, 0, 0)
	bad["a NaN vertex"] = [_mesh(v, _cube_idx()), "finite"]
	idx = _cube_idx()
	idx.resize(idx.size() - 1)
	bad["a partial triangle"] = [_mesh(_cube_verts(), idx), "whole number of triangles"]
	v = PackedVector3Array()
	for i in 8:
		v.append(Vector3.ONE)
	bad["every vertex at one point"] = [_mesh(v, _cube_idx()), "no volume"]
	bad["a flat quad"] = [_mesh(PackedVector3Array([Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]), PackedInt32Array([0, 1, 2, 0, 2, 3])), "no volume"]
	for what in bad:
		var t0 := Time.get_ticks_msec()
		var asset = authoring.fracture_mesh(bad[what][0], 8, 42)
		var err: String = authoring.get_last_error()
		_check(asset == null and Time.get_ticks_msec() - t0 < 1000 and err.contains(bad[what][1]),
				"%s: refused (%s, %d ms), last error \"%s\"" % [what, "null" if asset == null else "an asset", Time.get_ticks_msec() - t0, err])

	var cube := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	var good := {"a BoxMesh (cleaned)": box, "a welded closed cube (not cleaned)": _mesh(_cube_verts(), _cube_idx())}
	v = _cube_verts()
	v.append_array([Vector3(6, 6, 6), Vector3(7, 6, 6), Vector3(6, 7, 6)])
	idx = _cube_idx()
	idx.append_array([8, 9, 10])
	good["a cube plus a stray triangle (stray dropped)"] = _mesh(v, idx)
	good["an inside-out cube (flipped)"] = _mesh(_cube_verts(), _cube_idx(true))
	for what in good:
		var asset = authoring.fracture_mesh(good[what], 8, 42)
		var span: AABB = _span(asset) if asset else AABB()
		_check(asset != null and asset.get_chunk_count() == 9 and span.grow(0.01).encloses(cube) and cube.grow(0.01).encloses(span) and authoring.get_last_error().is_empty(),
				"%s: %d chunks spanning %s (want 9 over %s)" % [what, asset.get_chunk_count() if asset else 0, span, cube])
		if asset:
			var share := _outward_share(asset)
			_check(share > 0.95, "%s: every piece faces outward (worst piece %.0f%% of its triangles)" % [what, share * 100.0])
		var warnings: PackedStringArray = authoring.get_last_warnings()
		if what.begins_with("a cube plus"):
			_check(warnings.size() == 1 and warnings[0].contains("dropped"), "the stray's warning is reported: %s" % [warnings])
		elif what.begins_with("an inside-out"):
			_check(warnings.size() == 1 and warnings[0].contains("inside out"), "the flip's warning is reported: %s" % [warnings])
		else:
			_check(warnings.is_empty(), "%s: no warnings" % what)

	print("[blast_input] ", "PASS" if _ok else "FAIL")
	quit(0 if _ok else 1)
