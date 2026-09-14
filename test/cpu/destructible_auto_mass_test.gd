extends SceneTree

# Verifies PhysXDestructible3D's auto_mass/density: mass auto-computes from
# density * the intact mesh's real volume by default (unlike plain
# RigidBody3D, which always defaults to a flat 1.0 regardless of the
# shape's actual size), and -- the real risk flagged before building this --
# an explicit override via set_mass() must never be silently destroyed by a
# later auto-recompute (a reload, a density change).
#
# SKIPs (not FAILs) on a build without blast_sdk= configured.

var _node
var _tick := 0
var _auto_mass_1 := 0.0
var _ok := true

func _initialize() -> void:
	print("[destructible_auto_mass] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[destructible_auto_mass] PhysXDestructible3D not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var root := Node3D.new()
	get_root().add_child(root)

	_node = ClassDB.instantiate("PhysXDestructible3D")
	_node.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	_node.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	root.add_child(_node)

func _check(label: String, cond: bool) -> void:
	print("[destructible_auto_mass] ", label, " -> ", ("PASS" if cond else "FAIL"))
	if not cond:
		_ok = false

func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 5:
		# 1) auto_mass defaults on -- mass should already be a real,
		# non-default density-derived value, not the flat 1.0 a plain
		# RigidBody3D would have.
		print("[destructible_auto_mass] auto_mass=", _node.auto_mass, " mass=", _node.mass, " density=", _node.density)
		_auto_mass_1 = _node.mass
		_check("auto-computed on load", bool(_node.auto_mass) and absf(_auto_mass_1 - 1.0) > 0.001)

		# 2) Doubling density should double the auto-computed mass
		# immediately, no reload needed.
		_node.density = _node.density * 2.0
		print("[destructible_auto_mass] after doubling density: mass=", _node.mass, " (expect ~", _auto_mass_1 * 2.0, ")")
		_check("live density recompute", absf(_node.mass - _auto_mass_1 * 2.0) < 0.01)

		# 3) The real risk: set_mass() must be a real, permanent override --
		# never silently destroyed by a later auto-recompute.
		_node.set_mass(42.0)
		print("[destructible_auto_mass] after set_mass(42): mass=", _node.mass, " auto_mass=", _node.auto_mass)
		_check("set_mass is immediate + disables auto_mass", absf(_node.mass - 42.0) < 0.001 and bool(_node.auto_mass) == false)

		# Try to destroy it: change density again (would have recomputed
		# mass if auto_mass were still on) and force a full reload
		# (re-assigning asset_path re-triggers _load()).
		_node.density = _node.density * 10.0
		_node.asset_path = _node.asset_path
		print("[destructible_auto_mass] after density change + reload: mass=", _node.mass, " (expect still 42)")
		_check("override survives density change", absf(_node.mass - 42.0) < 0.001)

	if _tick == 10:
		# Reload is async relative to the property assignment above (same
		# NOTIFICATION_ENTER_WORLD timing as everything else in this node) --
		# re-check the override survived it by this point.
		_check("override survives reload", absf(_node.mass - 42.0) < 0.001)

		# 4) Turning auto_mass back on explicitly should recompute again
		# (proves the override wasn't just "stuck," auto really was off).
		_node.auto_mass = true
		print("[destructible_auto_mass] after re-enabling auto_mass: mass=", _node.mass, " (expect != 42)")
		_check("re-enabling auto_mass recomputes", absf(_node.mass - 42.0) > 0.001)

		print("[destructible_auto_mass] overall -> %s" % ("PASS" if _ok else "FAIL"))
		quit(0 if _ok else 1)
		return true
	return false
