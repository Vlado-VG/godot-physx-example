extends Node

# G turns a scene's PXTGI (its PXTGI3D) off and on; a corner label says which. Hidden, the GI node steps aside
# and Godot's own lighting is back.

@export var gi_path: NodePath = ^"../GI"

var _gi: Node3D
var _label: Label


func _ready() -> void:
	_gi = get_node_or_null(gi_path)
	var hud := CanvasLayer.new()
	hud.layer = 10
	_label = Label.new()
	# Pinned to the top right corner, growing leftward as the text changes.
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	hud.add_child(_label)
	add_child(hud)
	_update_label()


func _update_label() -> void:
	_label.text = "GI: %s [G]" % ("PXTGI" if _gi and _gi.visible else "off")


func _unhandled_input(event: InputEvent) -> void:
	if _gi == null or not (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_G):
		return
	_gi.visible = not _gi.visible
	_update_label()
	get_viewport().set_input_as_handled()
