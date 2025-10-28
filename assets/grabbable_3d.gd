@icon("../assets/grabbable.svg")
class_name Grabbable3D extends RigidBody3D

const GroupName: String = "grabbable-3d"

signal pulled(grabbable: Grabbable3D)
signal throwed(grabbable: Grabbable3D)
signal dropped(grabbable: Grabbable3D)
signal focused(grabbable: Grabbable3D)
signal unfocused(grabbable: Grabbable3D)

enum GrabMode {
  Pull, # Pull the body to the selected slot
  InPlace # Move the body in place, no pulling is applied
}

enum OutlineMode {
  EdgeShader,
  InvertedHull
}

enum GrabPointMode {
  SinglePoint,    # Use only one attractor point
  TwoPoints,      # Use two grab points for stable orientation
  CenterOfMass    # Use center of mass for natural rotation
}

@export_group("Mesh")
## The mesh related to this grabbable to apply the outline
@export var grabbable_mesh: MeshInstance3D

@export_group("Grab Points")
## How to handle grab point physics
@export var grab_point_mode: GrabPointMode = GrabPointMode.TwoPoints
# Reference to the attractor (Marker3D)
@export var attractor: Marker3D
# Reference to grab points for two-handed interaction
@export var grab_point_A: Marker3D
@export var grab_point_B: Marker3D
# Optional secondary attractor for two-point mode
@export var attractor_B: Marker3D

@export_group("Cursors")
@export var focus_cursor_name: String = 'open_hand'

@export_group("Gameplay Settings")
@export var should_reset_on_drop: bool = false

@export_group("Physics")
@export_flags_3d_physics var collision_layers_on_grab: int = 0
@export_flags_3d_physics var collision_mask_on_grab: int = 0
@export var grab_mode: GrabMode = GrabMode.Pull
@export var throw_strength: float = 1.0  ## Strength when throwing
@export var spring_constant: float = 10.0  ## Strength of the spring
@export var rotational_spring_constant: float = 5.0  ## Strength for rotation alignment
@export var damping_factor: float = 10.0    ## How quickly the object comes to rest
@export var resting_distance: float = 1.0  ## Distance from target where the object is considered 'resting'

@export_group("Transparency")
@export_range(0.0, 1.0) var transparency_value_on_pull: float = 1.0

@export_group("Rotation")
@export var adjust_rotation_on_pull: bool = false
@export var lerp_adjust_speed: float = 7.0

@export_group("Outline")
@export var outline_on_focus: bool = true
@export var outline_mode: OutlineMode = OutlineMode.EdgeShader
@export_subgroup("Edge shader")
@export var outline_shader_color: Color = Color.WHITE
@export var outline_width: float = 2.0
@export var outline_shader: Shader = preload("res://shaders/pixel_perfect_outline.gdshader")
@export_subgroup("Inverted hull")
@export var outline_hull_color: Color = Color.WHITE
@export_range(0, 16, 0.01) var outline_grow_amount: float = 0.02

@export_group("Information")
@export var id: String = ""
@export var title: String = ""
@export var description: String = ""
@export var title_translation_key: String = ""
@export var description_translation_key: String = ""

var initial_transform
var outline_material: StandardMaterial3D
var outline_shader_material: ShaderMaterial

# For two-point grabbing
var target_transform: Transform3D
var is_aligning_rotation: bool = false

# Add a public function to reset its state
func reset_to_initial_state() -> void:
  drop()
  PhysicsServer3D.body_set_state(
    get_rid(),
    PhysicsServer3D.BODY_STATE_TRANSFORM,
    initial_transform
  )
  linear_velocity = Vector3.ZERO
  angular_velocity = Vector3.ZERO

func _ready() -> void:
  if outline_mode == OutlineMode.EdgeShader and not outline_shader_material:
    outline_shader_material = ShaderMaterial.new()
    outline_shader_material.shader = outline_shader

  if outline_mode == OutlineMode.InvertedHull and not outline_material:
    outline_material = StandardMaterial3D.new()
    outline_material.grow = true
    outline_material.blend_mode = BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA
    outline_material.cull_mode = BaseMaterial3D.CULL_FRONT
    outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    outline_material.albedo_color.a = transparency_value_on_pull

func _enter_tree() -> void:
  contact_monitor = true
  max_contacts_reported = 5
  add_to_group(GroupName)

  focused.connect(on_focused)
  unfocused.connect(on_unfocused)
  throwed.connect(on_throwed)
  dropped.connect(on_dropped)
  pulled.connect(on_pulled)
  sleeping_state_changed.connect(_on_sleeping_state_changed)

func _physics_process(delta: float) -> void:
  constant_force = Vector3.ZERO
  if not attractor:
    initial_transform = global_transform
    return

  match grab_point_mode:
    GrabPointMode.SinglePoint:
      _apply_single_point_physics(delta)
    GrabPointMode.TwoPoints:
      _apply_two_point_physics(delta)
    GrabPointMode.CenterOfMass:
      _apply_center_of_mass_physics(delta)

func _apply_single_point_physics(delta: float) -> void:
  var target_position = attractor.global_transform.origin
  var current_position = global_transform.origin
  var direction = (target_position - current_position).normalized()
  var distance = target_position.distance_to(current_position)

  # Spring force: Pull the object towards the attractor
  var spring_force = direction * (distance * spring_constant)
  var weight_force = mass * get_gravity()

  # Apply damping
  angular_damp = damping_factor
  linear_damp = damping_factor

  constant_force = -weight_force # make it weightless
  apply_central_force(spring_force)

  # Optional rotation alignment
  if adjust_rotation_on_pull:
    _align_rotation_to_attractor(delta)

func _apply_two_point_physics(delta: float) -> void:
  if not grab_point_A or not grab_point_B:
    # Fall back to single point if grab points aren't set up
    _apply_single_point_physics(delta)
    return

  var weight_force = mass * get_gravity()
  constant_force = -weight_force # Counteract gravity

  # Apply damping
  angular_damp = damping_factor
  linear_damp = damping_factor

  # Calculate forces for both grab points
  if attractor_B:
    # Two separate attractors for two-handed control
    _apply_two_attractor_physics(delta)
  else:
    # Single attractor with two grab points for stable orientation
    _apply_single_attractor_two_points_physics(delta)

func _apply_two_attractor_physics(delta: float) -> void:
  # Point A physics
  var target_A = attractor.global_transform.origin
  var point_A = grab_point_A.global_transform.origin
  var direction_A = (target_A - point_A).normalized()
  var distance_A = target_A.distance_to(point_A)
  var force_A = direction_A * (distance_A * spring_constant)

  # Point B physics
  var target_B = attractor_B.global_transform.origin
  var point_B = grab_point_B.global_transform.origin
  var direction_B = (target_B - point_B).normalized()
  var distance_B = target_B.distance_to(point_B)
  var force_B = direction_B * (distance_B * spring_constant)

  # Apply forces at grab points
  apply_force(force_A, point_A - global_transform.origin)
  apply_force(force_B, point_B - global_transform.origin)

  # Align rotation based on grab points
  _align_rotation_based_on_points(target_A, target_B, delta)

func _apply_single_attractor_two_points_physics(delta: float) -> void:
  var target_position = attractor.global_transform.origin
  var target_basis = attractor.global_transform.basis

  # Calculate where grab points should be relative to attractor
  var local_A = grab_point_A.position
  var local_B = grab_point_B.position

  # Convert to world space targets
  var target_A = target_position + target_basis * local_A
  var target_B = target_position + target_basis * local_B

  var point_A = grab_point_A.global_transform.origin
  var point_B = grab_point_B.global_transform.origin

  # Calculate forces
  var force_A = (target_A - point_A) * spring_constant
  var force_B = (target_B - point_B) * spring_constant

  # Apply forces at grab points
  apply_force(force_A, point_A - global_transform.origin)
  apply_force(force_B, point_B - global_transform.origin)

  # Additional rotational alignment
  _align_rotation_to_attractor(delta)

func _apply_center_of_mass_physics(delta: float) -> void:
  var target_position = attractor.global_transform.origin
  var current_position = global_transform.origin
  var direction = (target_position - current_position).normalized()
  var distance = target_position.distance_to(current_position)

  var spring_force = direction * (distance * spring_constant)
  var weight_force = mass * get_gravity()

  angular_damp = damping_factor
  linear_damp = damping_factor

  constant_force = -weight_force
  apply_central_force(spring_force)

  # Natural rotation - no forced alignment
  if adjust_rotation_on_pull:
    _align_rotation_to_attractor(delta)

func _align_rotation_to_attractor(delta: float) -> void:
  if not attractor:
    return

  var current_basis = global_transform.basis
  var target_basis = attractor.global_transform.basis

  # Calculate rotation difference
  var rotation_diff = current_basis.inverse() * target_basis
  var axis = rotation_diff.get_rotation_quaternion().get_axis()
  var angle = rotation_diff.get_rotation_quaternion().get_angle()

  # Apply torque to align rotation
  if angle > 0.01:  # Small threshold to prevent jitter
    var torque = axis * angle * rotational_spring_constant
    apply_torque_impulse(torque * delta)

func _align_rotation_based_on_points(target_A: Vector3, target_B: Vector3, delta: float) -> void:
  var current_A = grab_point_A.global_transform.origin
  var current_B = grab_point_B.global_transform.origin

  # Calculate current and desired directions
  var current_dir = (current_B - current_A).normalized()
  var target_dir = (target_B - target_A).normalized()

  # Calculate rotation axis and angle
  var rotation_axis = current_dir.cross(target_dir).normalized()
  var rotation_angle = acos(clamp(current_dir.dot(target_dir), -1.0, 1.0))

  # Apply torque if significant rotation needed
  if rotation_angle > 0.01:
    var torque = rotation_axis * rotation_angle * rotational_spring_constant
    apply_torque_impulse(torque * delta)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
  var collision_count = state.get_contact_count()
  for i in range(collision_count):
    var collider = state.get_contact_collider_object(i)
    var collision_position = state.get_contact_local_position(i)
    var collision_impulse = state.get_contact_impulse(i)
    if collider:
      GlobalSoundManager.play_collision_sound(collider, collision_position, collision_impulse, 0.25)
      GlobalSoundManager.play_collision_sound(self, collision_position, collision_impulse, 0.25)
      break

func _apply_outline_shader() -> void:
  if outline_on_focus and grabbable_mesh:
    var material = grabbable_mesh.get_active_material(0)

    # Clone the material so that each instance gets its own unique material
    var cloned_material = material.duplicate()

    match outline_mode:
      OutlineMode.EdgeShader:
        if cloned_material and not cloned_material.next_pass:
          outline_shader_material.set_shader_parameter("outline_color", outline_shader_color)
          outline_shader_material.set_shader_parameter("outline_width", outline_width)
          cloned_material.next_pass = outline_shader_material

      OutlineMode.InvertedHull:
        outline_material.albedo_color = outline_hull_color
        outline_material.grow_amount = outline_grow_amount
        grabbable_mesh.material_overlay = outline_material

    # Apply the cloned material back to the mesh
    grabbable_mesh.set_surface_override_material(0, cloned_material)

func _remove_outline_shader() -> void:
  if outline_on_focus:
    var material = grabbable_mesh.get_active_material(0)

    match outline_mode:
      OutlineMode.EdgeShader:
        if material:
          material.next_pass = null
      OutlineMode.InvertedHull:
        grabbable_mesh.material_overlay = null

func throw(direction):
  var throw_force = direction * throw_strength
  apply_central_force(Vector3.ZERO)
  apply_central_impulse(Vector3.ZERO)
  apply_impulse(throw_force)
  drop()
  throwed.emit(self)

func drop():
  attractor = null
  attractor_B = null
  linear_damp = 0.0
  angular_damp = 0.0
  collision_layer |= collision_layers_on_grab
  collision_mask |= collision_mask_on_grab
  dropped.emit(self)

func pull(target):
  attractor = target
  collision_layer &= ~collision_layers_on_grab
  collision_mask &= ~collision_mask_on_grab
  pulled.emit(self)

func pull_two_handed(primary_target: Marker3D, secondary_target: Marker3D = null):
  attractor = primary_target
  attractor_B = secondary_target
  if secondary_target:
    grab_point_mode = GrabPointMode.TwoPoints
  collision_layer &= ~collision_layers_on_grab
  collision_mask &= ~collision_mask_on_grab
  pulled.emit(self)

func focus() -> void:
  focused.emit(self)

func unfocus() -> void:
  unfocused.emit(self)

#region Signal callbacks
func on_focused(_grabbable: Grabbable3D) -> void:
  _apply_outline_shader()

func on_unfocused(_grabbable: Grabbable3D) -> void:
  _remove_outline_shader()

func on_pulled(_grabbable: Grabbable3D) -> void:
  pass

func on_throwed(_grabbable: Grabbable3D) -> void:
  pass

func on_dropped(_grabbable: Grabbable3D) -> void:
  pass

func _on_sleeping_state_changed():
  if attractor: return
#endregion
