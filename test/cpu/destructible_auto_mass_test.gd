extends SceneTree

# Verifies PhysXDestructible3D's mass property: it auto-seeds to a real,
# volume-derived starting value the first time an asset loads (unlike plain
# RigidBody3D, which always defaults to a flat 1.0 regardless of the
# shape's actual size) -- but ONLY while still sitting at its untouched
# compile-time default. An earlier design used a separate density/auto_mass
# toggle for this; dropped after checking that neither Godot nor Unreal
# actually expose raw density as a per-component number that way (Unreal's
# lives on a shared PhysicalMaterial asset, Godot has no density concept at
# all), and it needed a confusing read-only-until-you-flip-a-switch
# Inspector lock that fought live user edits. This is the simpler design:
# one plain always-editable float, seeded once, never silently overwritten
# again by anything (a reload included) once it's an explicit value.
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
		# 1) Mass should already be a real, non-default volume-derived value
		# on load, not the flat 1.0 a plain RigidBody3D would have.
		_seeded_mass = _node.mass
		print("[destructible_auto_mass] mass after load = ", _seeded_mass)
		_check("auto-seeded on load", absf(_seeded_mass - 1.0) > 0.001)

		# 2) The real risk this exists to guard against: an explicit
		# override must never be silently destroyed by a later reload.
		_node.set_mass(42.0)
		print("[destructible_auto_mass] after set_mass(42): mass=", _node.mass)
		_check("set_mass is immediate", absf(_node.mass - 42.0) < 0.001)

		_node.asset_path = _node.asset_path # forces a real reload
		print("[destructible_auto_mass] after reload: mass=", _node.mass, " (expect still 42)")
		_check("override survives immediate reload", absf(_node.mass - 42.0) < 0.001)

	if _tick == 10:
		# Reload is async relative to the property assignment above -- same
		# NOTIFICATION_ENTER_WORLD timing as everything else on this node --
		# re-check the override held once that's actually settled.
		_check("override survives settled reload", absf(_node.mass - 42.0) < 0.001)

		print("[destructible_auto_mass] overall -> %s" % ("PASS" if _ok else "FAIL"))
		quit(0 if _ok else 1)
		return true
	return false
