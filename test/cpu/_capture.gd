extends SceneTree

# Generic verification capture: loads a scene, lets it settle, saves a
# screenshot. Usage:
#   redot --path . -s res://test/cpu/_capture.gd -- scene=res://demo/editor/cpu/lake.tscn out=shot.png frames=400

var _scene: Node
var _out := "shot.png"
var _frames := 400
var _tick := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("scene="):
			var path := arg.substr(6)
			_scene = load(path).instantiate()
			root.add_child(_scene)
		elif arg.begins_with("out="):
			_out = arg.substr(4)
		elif arg.begins_with("frames="):
			_frames = int(arg.substr(7))
	if _scene == null:
		print("[capture] no scene= given")
		quit(1)

func _process(_d: float) -> bool:
	_tick += 1
	if _tick >= _frames:
		var img := root.get_texture().get_image()
		img.save_png(_out)
		print("[capture] saved ", _out)
		quit(0)
		return true
	return false
