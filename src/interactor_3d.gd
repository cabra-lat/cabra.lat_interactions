@icon("../assets/grabber.svg")
class_name Interactor3D extends RayCast3D

class ActiveGrabbable extends RefCounted:
	var body: Grabbable3D
	var slot: Marker3D

	func _init(_body: Grabbable3D, _slot: Marker3D):
		body = _body
		slot = _slot

signal pulled_grabbable(body: Grabbable3D)
signal throwed_grabbable(body: Grabbable3D)
signal dropped_grabbable(body: Grabbable3D)

@export var follow: Node3D
@export var available_slots: Array[Marker3D] = []
@export var max_mass: float = 10.0
@export var max_grabbables: int = 1
@export var inspect_angular_step: float = PI / 20

@export_group("Action Names")
@export var pull_action:     String = "pull"
@export var throw_action:    String = "throw"
@export var drop_action:     String = "drop"
@export var interact_action: String = "interact"
@export var inspect_action:  String = "inspect"

@onready var Cursor: Cursor3D = $Cursor3D

var active_grabbables: Array[ActiveGrabbable] = []
var focused_interactable: Interactable3D = null
var focused_grabbable: Grabbable3D = null

func _ready() -> void:
	_prepare_slots()
	Cursor.hide()
	
func _physics_process(_delta) -> void:
	global_transform = follow.global_transform
	if not active_grabbables.is_empty():
		Cursor.change_cursor("closed_hand") # Keep hand closed while pulling
		return
	
	var detected = get_collider()
	_unfocus_previous(detected)

	if detected is Grabbable3D:
		Cursor.change_cursor(detected.focus_cursor_name)
		focused_grabbable = detected as Grabbable3D
		focused_grabbable.focus()
		return

	if detected is Interactable3D:
		Cursor.change_cursor(detected.focus_cursor_name)
		focused_interactable = detected as Interactable3D
		focused_interactable.focus()
		return

func _unfocus_previous(detected):
	if focused_grabbable and detected != focused_grabbable:
		focused_grabbable.unfocus()
		focused_grabbable = null
	if focused_interactable and detected != focused_interactable:
		focused_interactable.unfocus()
		focused_interactable = null

func _input(event: InputEvent) -> void:
	Cursor.timer.start()

	if event is InputEventMouseButton:
		var direction = Vector3.UP
		if event.shift_pressed:
			direction = Vector3.LEFT
		
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.is_pressed():
			handle_inspect(inspect_angular_step, direction)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.is_pressed():
			handle_inspect(-inspect_angular_step, direction)
			get_viewport().set_input_as_handled()

	if Input.is_action_just_pressed(interact_action):
		handle_interact()
	
	if Input.is_action_just_pressed(throw_action):
		Cursor.change_cursor("open_hand").out_then_in()
		handle_throw()

	# The drop action
	if Input.is_action_just_pressed(drop_action):
		Cursor.change_cursor("open_hand").reset_scale()
		handle_drop()
		
	if Input.is_action_just_pressed(pull_action):
		Cursor.change_cursor("closed_hand").in_then_out()
		handle_pull()

	if Input.is_action_just_released(pull_action):
		Cursor.change_cursor("open_hand").reset_scale()

func handle_inspect(amount: float, direction: Vector3 = Vector3.UP) -> void:
	if focused_grabbable and is_instance_valid(focused_grabbable):
		var rotation_torque = direction * amount
		focused_grabbable.apply_torque_impulse(rotation_torque)

func handle_interact() -> void:
	if focused_interactable and is_instance_valid(focused_interactable):
		if focused_interactable.can_be_interacted:
			Cursor.change_cursor("pointing_hand").click()
		focused_interactable.interact()

func handle_pull() -> void:
	if slots_available() and can_grab(focused_grabbable):
		pull_grabbable(focused_grabbable)

func slots_available() -> bool:
	return active_grabbables.size() < max_grabbables and active_grabbables.size() < available_slots.size()

func handle_throw() -> void:
	for grabbable in active_grabbables.duplicate():
		throw_grabbable(grabbable.body)

func handle_drop() -> void:
	for grabbable in active_grabbables.duplicate():
		drop_grabbable(grabbable.body)

func pull_grabbable(grabbable: Grabbable3D) -> void:
	if slots_available() and can_grab(grabbable):
		var slot = get_free_slot()
		grabbable.pull(slot)
		active_grabbables.append(ActiveGrabbable.new(grabbable, slot))
		pulled_grabbable.emit(grabbable)

func throw_grabbable(grabbable: Grabbable3D) -> void:
	active_grabbables = active_grabbables.filter(func(g): return g.body != grabbable)
	if grabbable.should_reset_on_drop:
		grabbable.reset_to_initial_state()
	else:
		var direction = (global_basis.z * -1).normalized()
		grabbable.throw(direction)
	throwed_grabbable.emit(grabbable)

func drop_grabbable(grabbable: Grabbable3D) -> void:
	active_grabbables = active_grabbables.filter(func(g): return g.body != grabbable)
	if grabbable.should_reset_on_drop:
		grabbable.reset_to_initial_state()
	else:
		grabbable.drop()
	dropped_grabbable.emit(grabbable)

func can_grab(body: Grabbable3D) -> bool:
	return body and is_instance_valid(body) \
			and body.mass <= max_mass \
			and active_grabbables.size() < max_grabbables

func get_free_slot() -> Marker3D:
	var used_slots: Dictionary = {}
	for g in active_grabbables:
		used_slots[g.slot] = true
	
	var free_slots: Array[Marker3D] = []
	for slot in available_slots:
		if not used_slots.has(slot):
			free_slots.append(slot)
			
	return free_slots.pick_random() if not free_slots.is_empty() else null

func _prepare_slots() -> void:
	if not available_slots.is_empty(): return
	for marker in get_children():
		if marker is Marker3D:
			available_slots.append(marker as Marker3D)
