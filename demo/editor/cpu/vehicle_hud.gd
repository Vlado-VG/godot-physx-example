extends CanvasLayer

# Forza-Horizon-style telemetry readout -- plain numbers, monospace, no
# gauges. Everything is read off vehicle_car.gd's telemetry dict, which the
# car fills from the NODE vehicle stack each physics tick (the node-level
# PhysXVehicle3D has no engine/gearbox state, so those rows are gone; the
# wheel grid shows per-wheel suspension jounce + contact instead of rpm).
#
#   SPEED / GEAR / THROTTLE / BRAKE / STEERING / HANDBRAKE
#   PITCH / ROLL / G-force lat+long, and a per-wheel contact+jounce grid.

@onready var _car: Node3D = get_node("../DogeCar")
@onready var _panel: Label = $Telemetry
@onready var _speed_label: Label = $Speed


func _process(_delta: float) -> void:
	var t: Dictionary = _car.telemetry
	var wheel_lines := _wheel_grid(t["wheels"])
	_panel.text = "\n".join(PackedStringArray([
		"SPEED      %6.1f km/h" % t["speed_kmh"],
		"GEAR       %6s" % t["gear_label"],
		"THROTTLE   %6.2f" % t["throttle"],
		"BRAKE      %6.2f" % t["brake"],
		"STEERING   %6.2f" % t["steer"],
		"HANDBRAKE  %6.2f" % t["handbrake"],
		"",
		"DRIVE      %6s" % "DIRECT (node)",
		"",
		"PITCH      %6.1f deg" % t["pitch"],
		"ROLL       %6.1f deg" % t["roll"],
		"G LAT      %6.2f g" % t["g_lat"],
		"G LONG     %6.2f g" % t["g_long"],
		"",
		wheel_lines[0],
		wheel_lines[1],
		wheel_lines[2],
	]))
	_speed_label.text = "%d" % int(round(t["speed_kmh"]))


## 2x2 wheel grid: contact marker and suspension jounce per wheel.
## Order matches the car: 0 RF, 1 LF, 2 RR, 3 LR -> display FL FR / RL RR.
func _wheel_grid(wheels: Array) -> Array:
	if wheels.size() < 4:
		return ["WHEELS     (waiting for telemetry)", "", ""]
	var order := [1, 0, 3, 2]
	var cells: Array[String] = []
	for idx in order:
		var w: Dictionary = wheels[idx]
		cells.append("%s %s j%5.2f" % [
				"FL" if idx == 1 else ("FR" if idx == 0 else ("RL" if idx == 3 else "RR")),
				"on " if w["contact"] else "air",
				w["jounce"]])
	return [
		"WHEELS     %s   %s" % [cells[0], cells[1]],
		"           %s   %s" % [cells[2], cells[3]],
		"(on/air = road contact, j = suspension jounce 0..1)",
	]
