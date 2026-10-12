extends CanvasLayer
# On-screen perf readout for the Flow demos: FPS plus one line per
# PhysXFlowSimulation3D in the tree (backend, blocks, step time, composites).
# Attach to any scene root; it finds the simulations itself.

var _label: Label
var _sims: Array[Node] = []
var _refresh := 0
var _frames := 0

func _ready() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.offset_left = 8.0
	panel.offset_top = 8.0
	add_child(panel)
	_label = Label.new()
	_label.text = "..."
	panel.add_child(_label)
	_collect_sims()

func _collect_sims() -> void:
	_sims.clear()
	var stack: Array[Node] = [get_tree().root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is PhysXFlowSimulation3D:
			_sims.append(n)
		for c in n.get_children():
			stack.push_back(c)

func _process(_delta: float) -> void:
	_frames += 1
	_refresh -= 1
	if _refresh > 0:
		return
	_refresh = 15
	_update_label()
	if _frames % 60 == 0:
		print("[flow-hud] frame=", _frames, " ", _label.text.replace("\n", " | "))

func _update_label() -> void:
	var lines: Array[String] = []
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	for sim in _sims:
		var d: Dictionary = sim.get_diagnostics()
		lines.append("%s: %s  blocks %s/%s  step %.1f flush %.1f decode %.1f ms  composites %s  maxR %.2f" % [
				sim.name, d.get("backend", "?"),
				d.get("active_blocks", "?"), d.get("max_blocks", "?"),
				int(d.get("last_submit_usec", 0)) / 1000.0,
				int(d.get("last_flush_usec", 0)) / 1000.0,
				int(d.get("last_decode_usec", 0)) / 1000.0,
				d.get("render_outputs", 0),
				sim.get_last_max_temperature()])
	_label.text = "\n".join(lines)
