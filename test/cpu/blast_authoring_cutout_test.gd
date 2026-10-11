extends SceneTree

# Verifies PhysXAuthoring::fracture_mesh()'s PATTERN_CUTOUT option --
# FractureTool::cutout(), fed a grayscale bitmap
# (NvBlastExtAuthoringBuildCutoutSet), instead of PATTERN_VORONOI/
# PATTERN_SLICING's own generated sites/planes. Unlike those two, NvBlast
# doesn't generate this pattern itself -- same as Unreal's own Blast
# integration (a plain UTexture2D artists import), the caller supplies the
# bitmap.
#
# Two known-GOOD patterns are checked, deliberately different in kind:
#  - test_cutout_pattern.png: a clean 3x3 grid, straight edge-to-edge lines.
#  - test_cutout_spiderweb.png: real radial/curved cracks -- every one
#    reaching the image edge, unlike the pattern below.
# Same two-level proof per pattern as blast_authoring_test.gd: a real chunk
# count, then the authored asset reloaded through this engine's own
# PhysXDestructible3D (the dump below is its native asset_path/chunks_path
# format) and the full damage/split/spawn check on the real spawn path --
# also proves the pre-flight validation below doesn't false-positive-reject
# either of these.
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
# The destructibles load on world entry, which lands after _initialize() in a
# --script run -- the per-pattern damage checks run from _physics_process,
# the same pattern destructible_test.gd uses.

var _authoring
var _box: BoxMesh
var _results := {}
var _phase := 0
var _destructible: PhysXDestructible3D
var _label := ""
var _expected := 0
var _tick := 0

func _initialize() -> void:
	print("[blast_authoring_cutout] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXBlastAuthoring"):
		print("[blast_authoring_cutout] PhysXBlastAuthoring not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	_authoring = ClassDB.instantiate("PhysXBlastAuthoring")
	var PATTERN_CUTOUT = _authoring.PATTERN_CUTOUT

	_box = BoxMesh.new()
	_box.size = Vector3(2, 2, 0.4) # pane-shaped, like the glass/wall use case Cutout is meant for

	# No pattern -- must fail cleanly, not crash (mirrors Unreal's own
	# "Texture with cutout pattern not found" error path).
	var no_pattern_asset = _authoring.fracture_mesh(_box, 8, 42, PATTERN_CUTOUT)
	if no_pattern_asset != null:
		print("[blast_authoring_cutout] FAIL: fracture_mesh succeeded with no cutout_pattern texture")
		quit(1)
		return
	print("[blast_authoring_cutout] no-pattern case correctly returned null")

	if not _test_bad_pattern_rejected():
		_finish(false)
		return

	# Known-good patterns run one per phase (see _physics_process).
	_spawn_for_pattern("res://demo/common/blast/test_cutout_pattern.png", "grid")

func _test_bad_pattern_rejected() -> bool:
	var pattern: Texture2D = load("res://demo/common/blast/test_cutout_pattern_bad.png")
	if pattern == null:
		print("[blast_authoring_cutout] [bad] FAIL: could not load test_cutout_pattern_bad.png")
		return false
	var asset = _authoring.fracture_mesh(_box, 8, 42, _authoring.PATTERN_CUTOUT, pattern)
	var ok: bool = asset == null
	print("[blast_authoring_cutout] [bad] fracture_mesh returned %s (expect null, rejected cleanly, no crash) -> %s" % [
		("null" if asset == null else "NON-NULL"), ("PASS" if ok else "FAIL")])
	return ok

# Authors the pattern, dumps the asset in PhysXDestructible3D's native
# two-file format and spawns a destructible on it. The damage check happens
# in _physics_process once world entry has loaded it.
func _spawn_for_pattern(pattern_path: String, label: String) -> void:
	var pattern: Texture2D = load(pattern_path)
	if pattern == null:
		print("[blast_authoring_cutout] [%s] FAIL: could not load %s" % [label, pattern_path])
		_finish(false)
		return

	var asset = _authoring.fracture_mesh(_box, 8, 42, _authoring.PATTERN_CUTOUT, pattern)
	if asset == null:
		print("[blast_authoring_cutout] [%s] FAIL: fracture_mesh returned null" % label)
		_finish(false)
		return

	var chunk_count: int = asset.get_chunk_count()
	var asset_bytes: PackedByteArray = asset.asset_bytes
	print("[blast_authoring_cutout] [%s] chunk_count=%d asset_bytes=%d bytes" % [label, chunk_count, asset_bytes.size()])
	if chunk_count < 3 or asset_bytes.is_empty():
		print("[blast_authoring_cutout] [%s] FAIL: expected a real multi-chunk result and non-empty asset_bytes" % label)
		_finish(false)
		return

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
	var destructible := PhysXDestructible3D.new()
	destructible.asset_path = ProjectSettings.globalize_path(asset_path)
	destructible.chunks_path = ProjectSettings.globalize_path(chunks_path)
	destructible.position = Vector3(0, 5, 0)
	root.add_child(destructible)
	_destructible = destructible
	_label = label
	_expected = chunk_count - 1

func _physics_process(_d: float) -> bool:
	_tick += 1
	if _tick < 2 or _destructible == null:
		return false

	if not _destructible.is_loaded():
		print("[blast_authoring_cutout] [%s] FAIL: destructible failed to load the authored dump" % _label)
		_finish(false)
		return false
	var spawned: int = _destructible.apply_radial_damage(Vector3(0, 5, 0), 5.0, 0.1, 3.0)
	var body_count: int = _destructible.get_piece_count()
	print("[blast_authoring_cutout] [%s] end-to-end: spawned=%d (expect %d) body_count=%d" % [_label, spawned, _expected, body_count])
	_results[_label] = (spawned == _expected and body_count == _expected)
	_destructible.free()
	_destructible = null
	_tick = 0

	match _label:
		"grid":
			_spawn_for_pattern("res://demo/common/blast/test_cutout_spiderweb.png", "spiderweb")
		"spiderweb":
			_finish(_results.get("grid", false) and _results.get("spiderweb", false))
	return false

func _finish(ok: bool) -> void:
	print("[blast_authoring_cutout] overall -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
