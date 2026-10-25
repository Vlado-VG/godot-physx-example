extends SceneTree

# The Inspector shows only the chosen solver's settings on
# PhysXParticleFluid3D: MPM hides the PBD-only fluid, foam and anisotropy
# settings, PBD hides the mpm_ group, and Auto follows the solver it picks on
# this machine (which the solver dropdown names). Hidden values still save.
#   godot --headless --path . --script res://test/gpu/fluid_solver_properties_test.gd

const PBD_ONLY := ["surface_tension", "cohesion", "vorticity", "adhesion", "surface_friction", "surface_anisotropy", "foam_enabled", "foam_size"]
const MPM_ONLY := ["mpm_domain_size", "mpm_substeps", "mpm_colliders"]
const BOTH := ["viscosity", "gravity_scale", "particle_size", "render_mode"]

var _pass := true


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("  [%s] %-58s %s" % ["ok" if ok else "FAIL", label, detail])
	_pass = _pass and ok


func _shown(n: Node, names: Array) -> Array:
	var out := []
	for p in n.get_property_list():
		if p.name in names and (p.usage & PROPERTY_USAGE_EDITOR):
			out.append(p.name)
	return out


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXParticleFluid3D"):
		print("[solver_props] not registered -> SKIP")
		quit(0)
		return
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_render_mode"):
		print("[solver_props] SKIP: this engine build has no fluid render modes / PBD extras yet")
		quit(0)
		return
	var f: Node = ClassDB.instantiate("PhysXParticleFluid3D")
	var all := PBD_ONLY + MPM_ONLY + BOTH

	f.set("solver", 2)
	var shown := _shown(f, all)
	_check("MPM: the mpm_ settings and the shared ones", MPM_ONLY.all(func(n): return n in shown) and BOTH.all(func(n): return n in shown))
	_check("MPM: no PBD-only settings", not PBD_ONLY.any(func(n): return n in shown), "%s" % [shown])

	f.set("solver", 1)
	shown = _shown(f, all)
	_check("PBD: the PBD-only settings and the shared ones", PBD_ONLY.filter(func(n): return n != "surface_anisotropy").all(func(n): return n in shown) and BOTH.all(func(n): return n in shown), "%s" % [shown])
	_check("PBD: no mpm_ settings", not MPM_ONLY.any(func(n): return n in shown))

	f.set("solver", 0)
	var hint := ""
	for p in f.get_property_list():
		if p.name == "solver":
			hint = p.hint_string
	var picks_pbd := hint.begins_with("Auto (PBD here)")
	_check("Auto: the dropdown names what it picks here", picks_pbd or hint.begins_with("Auto (MPM here)"), hint)
	shown = _shown(f, all)
	_check("Auto: shows that solver's settings", ("mpm_substeps" in shown) != picks_pbd and ("cohesion" in shown) == picks_pbd, "%s" % [shown])

	f.set("solver", 1)
	f.set("mpm_substeps", 7)
	var holder := Node3D.new()
	holder.add_child(f)
	f.owner = holder
	var packed := PackedScene.new()
	packed.pack(holder)
	var st := packed.get_state()
	var saved := {}
	for i in st.get_node_property_count(1):
		saved[st.get_node_property_name(1, i)] = st.get_node_property_value(1, i)
	_check("a hidden setting is still saved", saved.get("mpm_substeps", 0) == 7, "%s" % [saved.get("mpm_substeps", "missing")])
	holder.free()

	print("[solver_props] %s" % ("PASS" if _pass else "FAIL"))
	quit(0 if _pass else 1)
