extends SceneTree

# PhysXDestructible3D's debris options and break notification (R24). Three cubes
# 10 m apart on one floor, each hit the same way at tick 10:
#  A  piece_lifetime 1 s + piece_shrink_time 0.5 s: not fractured before the hit;
#     the hit emits fractured(8) once and is_fractured() turns true; still 8
#     pieces inside the shrink window, but no longer colliding (a shrinking piece
#     mustn't block anyone); none after 1 s; is_fractured() stays true.
#  B  freeze_when_asleep: once the debris settles, its pieces are kinematic (still
#     solid, never move again).
#  D  dynamic + freeze_when_asleep, chipped at one corner so a big piece stays
#     whole; once that is frozen, a full hit breaks it and the new pieces come
#     loose (rigid), not frozen in mid-air.
#  C  defaults (control): pieces stay, and stay rigid.
# SKIPs (not FAILs) on a build without blast_sdk= configured.

const HIT_TICK := 10

var _a
var _b
var _c
var _dyn
var _floor: StaticBody3D
var _tick := 0
var _signals: Array[int] = []
var _pass := true


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[debris] PhysXDestructible3D not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return
	var root := Node3D.new()
	get_root().add_child(root)
	_floor = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 20)
	cs.shape = box
	_floor.add_child(cs)
	_floor.position = Vector3(10, -0.5, 0)
	root.add_child(_floor)
	_a = _cube(root, Vector3(0, 1.2, 0))
	_a.piece_lifetime = 1.0
	_a.piece_shrink_time = 0.5
	_a.fractured.connect(func(n: int) -> void: _signals.append(n))
	_b = _cube(root, Vector3(10, 1.2, 0))
	_b.freeze_when_asleep = true
	_c = _cube(root, Vector3(20, 1.2, 0))
	_dyn = _cube(root, Vector3(30, 1.2, 0))
	_dyn.dynamic = true
	_dyn.freeze_when_asleep = true
	_dyn.impact_strength = 1000000.0 # only the test's hits break it, not landing


func _cube(root: Node3D, at: Vector3):
	var n = ClassDB.instantiate("PhysXDestructible3D")
	n.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	n.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	n.shatter_speed = 1.5 # keep the debris near its cube, inside _modes()' 5 m sphere
	n.position = at
	root.add_child(n)
	return n


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-52s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


# [frozen (static or kinematic) bodies, rigid bodies] among the pieces within 5 m of p_center.
func _modes(p_center: Vector3) -> Array:
	var params := PhysicsShapeQueryParameters3D.new()
	var probe := SphereShape3D.new()
	probe.radius = 5.0
	params.shape = probe
	params.transform = Transform3D(Basis(), p_center)
	params.exclude = [_floor.get_rid()]
	var seen := {}
	var st := 0
	var rg := 0
	for hit in get_root().get_world_3d().direct_space_state.intersect_shape(params, 64):
		var rid: RID = hit.rid
		if seen.has(rid):
			continue
		seen[rid] = true
		if PhysicsServer3D.body_get_mode(rid) != PhysicsServer3D.BODY_MODE_RIGID:
			st += 1
		else:
			rg += 1
	return [st, rg]


func _physics_process(_d: float) -> bool:
	if _a == null:
		return true
	_tick += 1
	if _tick == HIT_TICK:
		_check("A not fractured before the hit", not _a.is_fractured(), "")
		for n in [_a, _b, _c]:
			n.apply_radial_damage(n.global_position, 5.0, 0.1, 3.0)
		var chipped: int = _dyn.apply_radial_damage(_dyn.global_position + Vector3(-0.5, 0.5, 0.5), 5.0, 0.05, 0.8) # one corner chunk + a 7-chunk piece
		print("  [..] D chipped: %d pieces now" % _dyn.get_piece_count())
		_check("A emitted fractured(8) once", _signals == [8], str(_signals))
		_check("A is_fractured() after the hit", _a.is_fractured(), "")
	if _tick == HIT_TICK + 45: # 0.75 s: inside the shrink window, not yet gone
		_check("A still has its pieces at 0.75 s", _a.get_piece_count() == 8, "%d pieces" % _a.get_piece_count())
		var a: Array = _modes(_a.global_position)
		_check("A's shrinking pieces no longer collide", a[0] + a[1] == 0, "%d found by a query" % (a[0] + a[1]))
	if _tick == HIT_TICK + 75: # 1.25 s: past piece_lifetime
		_check("A's pieces are gone after 1 s", _a.get_piece_count() == 0, "%d pieces" % _a.get_piece_count())
		_check("A is_fractured() stays true", _a.is_fractured(), "")
	if _tick == HIT_TICK + 599: # 10 s: B's debris has long settled
		var b: Array = _modes(_b.global_position)
		var c: Array = _modes(_c.global_position)
		_check("B froze its settled pieces", b[0] == _b.get_piece_count() and b[1] == 0, "%d frozen, %d rigid of %d" % [b[0], b[1], _b.get_piece_count()])
		_check("C (defaults) keeps its pieces, still rigid", c[0] == 0 and c[1] == _c.get_piece_count() and _c.get_piece_count() == 8, "%d frozen, %d rigid of %d" % [c[0], c[1], _c.get_piece_count()])
		var d: Array = _modes(_dyn.global_position)
		_check("D froze its chipped pile (big piece included)", d[1] == 0 and d[0] == _dyn.get_piece_count() and _dyn.get_piece_count() > 1 and _dyn.get_piece_count() < 8, "%d frozen, %d rigid of %d" % [d[0], d[1], _dyn.get_piece_count()])
		var broke: int = _dyn.apply_radial_damage(_dyn.global_position + Vector3(0, 0.3, 0), 50.0, 0.1, 4.0)
		var after: Array = _modes(_dyn.global_position)
		_check("D hit again: the new pieces come loose", broke > 0 and after[1] >= broke, "%d new, now %d frozen, %d rigid" % [broke, after[0], after[1]])
	if _tick == HIT_TICK + 600:
		print("[debris] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false
