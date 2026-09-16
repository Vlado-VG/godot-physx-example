extends SceneTree

# Verifies PhysXBlastAuthoring::fracture_mesh()'s new PATTERN_CUTOUT option
# (feature/physx-blast-destruction) -- FractureTool::cutout(), fed a
# grayscale bitmap (NvBlastExtAuthoringBuildCutoutSet), instead of
# PATTERN_VORONOI/PATTERN_SLICING's own generated sites/planes. Unlike those
# two, NvBlast doesn't generate this pattern itself -- same as Unreal's own
# Blast integration (a plain UTexture2D artists import), the caller supplies
# the bitmap.
#
# Two known-GOOD patterns are checked, deliberately different in kind:
#  - test_cutout_pattern.png: a clean 3x3 grid, straight edge-to-edge lines.
#  - test_cutout_spiderweb.png: real radial/curved cracks -- every one
#    reaching the image edge, unlike the pattern below.
# Same two-level proof per pattern: a real chunk count, then the full
# damage/split/spawn check through GodotPhysXBlastProbe to confirm the data
# is genuinely valid -- also proves the pre-flight validation below doesn't
# false-positive-reject either of these.
#
# Plus one known-BAD pattern, stress-testing the fix directly:
#  - test_cutout_pattern_bad.png: the exact pattern that crashed
#    FractureTool::cutout() two different ways (SweepingAccelerator
#    construction) before PhysXBlastAuthoring::fracture_mesh() added a
#    pre-flight check -- radial cracks stopping short of the image edge,
#    leaving the fill region as one connected ring around the web with a
#    hole in the middle (a real broken pane's cracks always reach an edge,
#    so every shard is a closed polygon -- this pattern doesn't). Must now
#    be rejected cleanly (a null Ref + an ERR_PRINT), not crash the whole
#    process the way it did twice while this pattern was being authored.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured.

func _initialize() -> void:
	print("[blast_authoring_cutout] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXBlastAuthoring"):
		print("[blast_authoring_cutout] PhysXBlastAuthoring not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var authoring = ClassDB.instantiate("PhysXBlastAuthoring")
	var PATTERN_CUTOUT = authoring.PATTERN_CUTOUT

	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 0.4) # pane-shaped, like the glass/wall use case Cutout is meant for

	# No pattern -- must fail cleanly, not crash (mirrors Unreal's own
	# "Texture with cutout pattern not found" error path).
	var no_pattern_asset = authoring.fracture_mesh(box, 8, 42, PATTERN_CUTOUT)
	if no_pattern_asset != null:
		print("[blast_authoring_cutout] FAIL: fracture_mesh succeeded with no cutout_pattern texture")
		quit(1)
		return
	print("[blast_authoring_cutout] no-pattern case correctly returned null")

	var grid_ok := _test_pattern(authoring, box, "res://demo/common/blast/test_cutout_pattern.png", "grid")
	var web_ok := _test_pattern(authoring, box, "res://demo/common/blast/test_cutout_spiderweb.png", "spiderweb")
	var bad_ok := _test_bad_pattern_rejected(authoring, box)

	var ok := grid_ok and web_ok and bad_ok
	print("[blast_authoring_cutout] overall -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _test_bad_pattern_rejected(authoring, box: BoxMesh) -> bool:
	var pattern: Texture2D = load("res://demo/common/blast/test_cutout_pattern_bad.png")
	if pattern == null:
		print("[blast_authoring_cutout] [bad] FAIL: could not load test_cutout_pattern_bad.png")
		return false
	var asset = authoring.fracture_mesh(box, 8, 42, authoring.PATTERN_CUTOUT, pattern)
	var ok: bool = asset == null
	print("[blast_authoring_cutout] [bad] fracture_mesh returned %s (expect null, rejected cleanly, no crash) -> %s" % [
		("null" if asset == null else "NON-NULL"), ("PASS" if ok else "FAIL")])
	return ok

func _test_pattern(authoring, box: BoxMesh, pattern_path: String, label: String) -> bool:
	var pattern: Texture2D = load(pattern_path)
	if pattern == null:
		print("[blast_authoring_cutout] [%s] FAIL: could not load %s" % [label, pattern_path])
		return false

	var asset = authoring.fracture_mesh(box, 8, 42, authoring.PATTERN_CUTOUT, pattern)
	if asset == null:
		print("[blast_authoring_cutout] [%s] FAIL: fracture_mesh returned null" % label)
		return false

	var chunk_count: int = asset.get_chunk_count()
	var asset_bytes: PackedByteArray = asset.asset_bytes
	print("[blast_authoring_cutout] [%s] chunk_count=%d asset_bytes=%d bytes" % [label, chunk_count, asset_bytes.size()])
	if chunk_count < 3 or asset_bytes.is_empty():
		print("[blast_authoring_cutout] [%s] FAIL: expected a real multi-chunk result and non-empty asset_bytes" % label)
		return false

	var asset_path := "user://blast_authoring_cutout_test_%s.asset" % label
	var af := FileAccess.open(asset_path, FileAccess.WRITE)
	af.store_buffer(asset.asset_bytes)
	af.close()

	var chunks_path := "user://blast_authoring_cutout_test_%s.chunks" % label
	var cf := FileAccess.open(chunks_path, FileAccess.WRITE)
	var chunk_points: Array = asset.chunk_points
	cf.store_line("chunks %d" % chunk_points.size())
	for i in chunk_points.size():
		var points: PackedVector3Array = chunk_points[i]
		var tri_count := points.size() / 3
		cf.store_line("chunk %d %d" % [i, tri_count])
		for t in tri_count:
			var a := points[t * 3 + 0]
			var b := points[t * 3 + 1]
			var c := points[t * 3 + 2]
			cf.store_line("%f %f %f %f %f %f %f %f %f" % [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
	cf.close()

	var root := Node3D.new()
	get_root().add_child(root)
	var probe = ClassDB.instantiate("GodotPhysXBlastProbe")
	probe.set_space(get_root().get_world_3d().space)
	probe.set_base_transform(Transform3D(Basis(), Vector3(0, 5, 0)))
	var globalized_asset := ProjectSettings.globalize_path(asset_path)
	var globalized_chunks := ProjectSettings.globalize_path(chunks_path)
	if not probe.load(globalized_asset, globalized_chunks):
		print("[blast_authoring_cutout] [%s] FAIL: probe.load() of the cutout-authored dump failed" % label)
		return false
	print("[blast_authoring_cutout] [%s] probe loaded, live_actor_count=%d" % [label, probe.get_live_actor_count()])
	var spawned: int = probe.apply_radial_damage(Vector3.ZERO, 5.0, 0.1, 3.0)
	var expected := chunk_count - 1
	print("[blast_authoring_cutout] [%s] end-to-end probe test: spawned=%d (expect %d) body_count=%d" % [label, spawned, expected, probe.get_body_count()])

	return spawned == expected and probe.get_body_count() == expected
