extends SceneTree

# Verifies PhysXDestructible3D's auto_mass checkbox + mass override
# (feature/physx-blast-destruction). Went through three designs before
# landing here:
#  1. density + auto_mass, mass read-only in the Inspector while auto_mass
#     was true -- reported as "grayed out, won't let me change it."
#  2. Dropped both properties entirely, mass always editable, auto-seeded
#     once via a hidden sentinel -- lost the "see the live auto-computed
#     value, and consciously opt out" workflow the user actually wanted.
#  3. This one: auto_mass restored, mass read-only while it's true (so you
#     see what the object would weigh) -- but set_auto_mass() now calls
#     notify_property_list_changed(), which #1 was missing. That was the
#     real bug: the Inspector never re-checked whether mass should still be
#     read-only after the checkbox changed, so unchecking it visually did
#     nothing even though the underlying state was already correct.
#
# A headless test can't click the Inspector checkbox, but it can verify the
# state machine notify_property_list_changed() depends on being correct:
# auto-seeds on load, a real override immediately flips auto_mass off (so
# the field would un-gray), and checking auto_mass again recomputes fresh
# (so the field would re-gray showing a new number, discarding the override
# -- "check again it grays back out and just shows you the number").
#
# SKIPs (not FAILs) on a build without blast_sdk= configured.

var _node
var _tick := 0
var _seeded_mass := 0.0
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
		# non-default volume-derived value, not the flat 1.0 a plain
		# RigidBody3D would have.
		_seeded_mass = _node.mass
		print("[destructible_auto_mass] auto_mass=", _node.auto_mass, " mass=", _seeded_mass)
		_check("auto-seeded on load", bool(_node.auto_mass) and absf(_seeded_mass - 1.0) > 0.001)

		# 2) An explicit override immediately takes effect AND flips
		# auto_mass off -- the field would un-gray in the real Inspector.
		_node.set_mass(42.0)
		print("[destructible_auto_mass] after set_mass(42): mass=", _node.mass, " auto_mass=", _node.auto_mass)
		_check("override is immediate + flips auto_mass off", absf(_node.mass - 42.0) < 0.001 and bool(_node.auto_mass) == false)

		# 3) The override must survive a reload untouched (the original
		# risk this whole feature exists to guard against).
		_node.asset_path = _node.asset_path # forces a real reload
		print("[destructible_auto_mass] after reload: mass=", _node.mass, " (expect still 42)")
		_check("override survives immediate reload", absf(_node.mass - 42.0) < 0.001)

	if _tick == 10:
		_check("override survives settled reload", absf(_node.mass - 42.0) < 0.001)

		# 4) Checking auto_mass again recomputes fresh and discards the
		# override -- "check again it grays back out and just shows you the
		# number."
		_node.auto_mass = true
		print("[destructible_auto_mass] after re-checking auto_mass: mass=", _node.mass, " (expect ~", _seeded_mass, ", != 42)")
		_check("re-enabling auto_mass recomputes fresh", absf(_node.mass - 42.0) > 0.001 and absf(_node.mass - _seeded_mass) < 0.001)

		print("[destructible_auto_mass] overall -> %s" % ("PASS" if _ok else "FAIL"))
		quit(0 if _ok else 1)
		return true
	return false
