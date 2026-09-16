extends SceneTree

# Verifies PhysXBlastAuthoring::fracture_mesh()'s new PATTERN_SLICING option
# (feature/physx-blast-destruction) -- FractureTool::slicing() instead of the
# original PATTERN_VORONOI (uniformlyGenerateSitesInMesh +
# voronoiFracturing()), for regular/brick-like pieces instead of organic
# random cells. Same two-level proof blast_authoring_test.gd already uses
# for Voronoi: a real chunk count + round-trip, then the full damage/split/
# spawn check through GodotPhysXBlastProbe to confirm the data is genuinely
# valid, not just plausible-looking bytes.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured.

func _initialize() -> void:
	print("[blast_authoring_slicing] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXBlastAuthoring"):
		print("[blast_authoring_slicing] PhysXBlastAuthoring not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)

	var authoring = ClassDB.instantiate("PhysXBlastAuthoring")
	var PATTERN_SLICING = authoring.PATTERN_SLICING
	var asset = authoring.fracture_mesh(box, 8, 42, PATTERN_SLICING)
	if asset == null:
		print("[blast_authoring_slicing] fracture_mesh returned null -> FAIL")
		quit(1)
		return

	var chunk_count: int = asset.get_chunk_count()
	var asset_bytes: PackedByteArray = asset.asset_bytes
	print("[blast_authoring_slicing] chunk_count=", chunk_count, " asset_bytes=", asset_bytes.size(), " bytes")
	if chunk_count < 2 or asset_bytes.is_empty():
		print("[blast_authoring_slicing] FAIL: expected chunk_count >= 2 (root + at least one slice) and non-empty asset_bytes")
		quit(1)
		return

	# Full end-to-end proof: dump into GodotPhysXBlastProbe's file format (same
	# approach blast_authoring_test.gd uses for Voronoi) and confirm damage
	# actually splits it into (chunk_count - 1) real rigid bodies -- not just
	# that the bytes look the right shape.
	var asset_path := "user://blast_authoring_slicing_test.asset"
	var af := FileAccess.open(asset_path, FileAccess.WRITE)
	af.store_buffer(asset.asset_bytes)
	af.close()

	var chunks_path := "user://blast_authoring_slicing_test.chunks"
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
		print("[blast_authoring_slicing] probe.load() of the slicing-authored dump failed -> FAIL")
		quit(1)
		return
	print("[blast_authoring_slicing] probe loaded, live_actor_count=", probe.get_live_actor_count())
	var spawned: int = probe.apply_radial_damage(Vector3.ZERO, 5.0, 0.1, 3.0)
	var expected := chunk_count - 1
	print("[blast_authoring_slicing] end-to-end probe test: spawned=", spawned, " (expect ", expected, ") body_count=", probe.get_body_count())

	var ok: bool = spawned == expected and probe.get_body_count() == expected
	print("[blast_authoring_slicing] overall -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
