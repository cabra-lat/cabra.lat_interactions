@icon("../assets/grabbable.svg")
class_name Grabbable3D extends RigidBody3D

const GROUP_NAME: String = "grabbable-3d"

enum GrabMode { PULL, IN_PLACE }
enum OutlineMode { EDGE_SHADER, INVERTED_HULL }

signal interaction(grabbable: Grabbable3D, action: String)

@export_group("References")
@export var grabbable_mesh: MeshInstance3D
@export var grab_points: Array[Marker3D] = []
@export var attractors: Array[Marker3D] = []

@export_group("Settings")
@export var grab_mode: GrabMode = GrabMode.PULL
@export var focus_cursor_name: String = 'open_hand'
@export var should_reset_on_drop: bool = false

@export_group("Physics")
@export_flags_3d_physics var collision_layers_on_grab: int = 0
@export_flags_3d_physics var collision_mask_on_grab: int = 0
@export var throw_strength: float = 3.0 ## in m/s
@export var spring_constant: Vector3 = Vector3(10.0, 10.0, 10.0) ## in N/m
@export var angular_spring_constant: Vector3 = Vector3(5.0, 5.0, 5.0) ## in N·m/rad

# Per-axis damping factors (relative to attractor's local coordinates)
@export var linear_damping_per_axis: Vector3 = Vector3(10.0, 10.0, 10.0) ## in 1/s
@export var angular_damping_per_axis: Vector3 = Vector3(10.0, 10.0, 10.0) ## in 1/s

@export_group("Resting Thresholds")
@export var linear_rest_threshold: float = 0.01 ## in m
@export var angular_rest_threshold: float = 0.01 ## in rad

@export_group("Rotation Settings")
@export var preserve_upright_orientation: bool = true
@export var upright_direction: Vector3 = Vector3.UP
@export var max_rotation_correction_angle: float = 45.0 ## in degrees

@export_group("Visual")
@export var outline_on_focus: bool = true
@export var outline_mode: OutlineMode = OutlineMode.EDGE_SHADER
@export var outline_color: Color = Color.WHITE

var initial_transform: Transform3D
var outline_material: StandardMaterial3D
var outline_shader_material: ShaderMaterial
var is_grabbed: bool = false

# Custom physics state
var custom_linear_velocity: Vector3 = Vector3.ZERO
var custom_angular_velocity: Vector3 = Vector3.ZERO
var custom_transform: Transform3D

# Anti-jitter measures
var position_error_integral: Vector3 = Vector3.ZERO
var rotation_error_integral: Vector3 = Vector3.ZERO
var last_position: Vector3 = Vector3.ZERO
var last_rotation: Basis = Basis.IDENTITY

func _ready() -> void:
  initial_transform = global_transform
  custom_transform = global_transform
  custom_linear_velocity = linear_velocity
  custom_angular_velocity = angular_velocity

  setup_outline_materials()
  setup_physics()
  add_to_group(GROUP_NAME)
  interaction.connect(_on_interaction)

func _physics_process(delta: float) -> void:
  if is_grabbed:
    _custom_physics_process(delta)

func _custom_physics_process(delta: float) -> void:
  # Store previous state for interpolation
  last_position = custom_transform.origin
  last_rotation = custom_transform.basis

  # Custom physics integration
  _custom_integrate_forces(delta)

  # Apply spring forces
  if attractors.size() == 1:
    _apply_single_attractor_physics(delta)
  elif attractors.size() >= 1 and grab_points.size() >= 1:
    _apply_multi_point_physics(delta)

  # Apply resting thresholds
  _apply_resting_thresholds()

  # Apply anti-jitter smoothing
  _apply_anti_jitter(delta)

func _custom_integrate_forces(delta: float) -> void:
  # Apply gravity
  var gravity = get_gravity()
  custom_linear_velocity += gravity * delta

  # Apply per-axis damping in attractor's local space
  if attractors.size() > 0:
    var attractor_basis = attractors[0].global_transform.basis
    var local_linear_vel = attractor_basis.inverse() * custom_linear_velocity

    local_linear_vel.x *= max(0.0, 1.0 - linear_damping_per_axis.x * delta)
    local_linear_vel.y *= max(0.0, 1.0 - linear_damping_per_axis.y * delta)
    local_linear_vel.z *= max(0.0, 1.0 - linear_damping_per_axis.z * delta)

    custom_linear_velocity = attractor_basis * local_linear_vel

    # Apply per-axis angular damping in attractor's local space
    var local_angular_vel = attractor_basis.inverse() * custom_angular_velocity

    local_angular_vel.x *= max(0.0, 1.0 - angular_damping_per_axis.x * delta)
    local_angular_vel.y *= max(0.0, 1.0 - angular_damping_per_axis.y * delta)
    local_angular_vel.z *= max(0.0, 1.0 - angular_damping_per_axis.z * delta)

    custom_angular_velocity = attractor_basis * local_angular_vel

  # Integrate position
  custom_transform.origin += custom_linear_velocity * delta

  # Integrate rotation using quaternions for stability
  if custom_angular_velocity.length_squared() > 0.0001:
    var rotation_quat = Quaternion(custom_transform.basis)
    var rotation_axis = custom_angular_velocity.normalized()
    var rotation_angle = custom_angular_velocity.length() * delta
    var angular_quat = Quaternion(rotation_axis, rotation_angle)

    rotation_quat = angular_quat * rotation_quat
    custom_transform.basis = Basis(rotation_quat)

  # Update the actual rigid body state
  global_transform = custom_transform
  linear_velocity = custom_linear_velocity
  angular_velocity = custom_angular_velocity

func _apply_single_attractor_physics(delta: float) -> void:
  if attractors.size() == 0:
    return

  var attractor = attractors[0]
  var target_pos = attractor.global_position
  var current_pos = custom_transform.origin

  # Calculate displacement in attractor's local space
  var attractor_basis = attractor.global_transform.basis
  var local_displacement = attractor_basis.inverse() * (target_pos - current_pos)

  # Apply 3D spring forces in attractor's local space
  var local_spring_accel = Vector3(
    local_displacement.x * spring_constant.x / mass,
    local_displacement.y * spring_constant.y / mass,
    local_displacement.z * spring_constant.z / mass
  )

  # Add integral term to reduce steady-state error (anti-jitter)
  position_error_integral += local_displacement * delta
  var local_integral_accel = position_error_integral * 0.1  # Small integral gain

  # Convert back to global space
  var global_spring_accel = attractor_basis * (local_spring_accel + local_integral_accel)
  custom_linear_velocity += global_spring_accel * delta

  # Apply angular spring
  _apply_angular_spring(delta)

func _apply_multi_point_physics(delta: float) -> void:
  # Apply forces at each grab point
  for i in range(min(attractors.size(), grab_points.size())):
    var grab_point = grab_points[i]
    var attractor = attractors[i % attractors.size()]

    var target_pos = attractor.global_position
    var point_pos = custom_transform * grab_point.position

    # Calculate displacement in attractor's local space
    var attractor_basis = attractor.global_transform.basis
    var local_displacement = attractor_basis.inverse() * (target_pos - point_pos)

    # 3D spring acceleration for this point in attractor's local space
    var local_point_accel = Vector3(
      local_displacement.x * spring_constant.x / mass,
      local_displacement.y * spring_constant.y / mass,
      local_displacement.z * spring_constant.z / mass
    )

    # Convert to global space
    var global_point_accel = attractor_basis * local_point_accel

    # Apply force at grab point
    var lever_arm = point_pos - custom_transform.origin
    custom_linear_velocity += global_point_accel * delta

    # Calculate torque: τ = r × F
    var torque = lever_arm.cross(global_point_accel * mass)
    custom_angular_velocity += torque * delta / _get_moment_of_inertia()

  # Apply angular spring
  _apply_angular_spring(delta)

func _apply_angular_spring(delta: float) -> void:
  if attractors.size() == 0 or angular_spring_constant.length_squared() == 0:
    return

  var attractor = attractors[0]
  var current_basis = custom_transform.basis
  var target_basis = _get_target_rotation_basis()

  # Calculate rotation difference
  var rotation_diff = target_basis.inverse() * current_basis
  var rotation_quat = rotation_diff.get_rotation_quaternion()

  # Extract axis and angle
  var axis = rotation_quat.get_axis()
  var angle = rotation_quat.get_angle()

  if angle > 0.01:
    # Apply restorative torque (negative sign)
    var attractor_basis = attractor.global_transform.basis

    # Calculate torque in attractor's local space
    var local_torque = Vector3(
      -axis.x * angle * angular_spring_constant.x,
      -axis.y * angle * angular_spring_constant.y,
      -axis.z * angle * angular_spring_constant.z
    )

    # Add integral term to reduce steady-state error
    rotation_error_integral += axis * angle * delta
    local_torque += rotation_error_integral * 0.05  # Small integral gain

    # Convert to global space
    var global_torque = attractor_basis * local_torque
    custom_angular_velocity += global_torque * delta / _get_moment_of_inertia()

func _apply_resting_thresholds() -> void:
  # Check if we should come to rest
  if custom_linear_velocity.length() < linear_rest_threshold:
    custom_linear_velocity = Vector3.ZERO
    position_error_integral = Vector3.ZERO  # Reset integral when at rest

  if custom_angular_velocity.length() < angular_rest_threshold:
    custom_angular_velocity = Vector3.ZERO
    rotation_error_integral = Vector3.ZERO  # Reset integral when at rest

func _apply_anti_jitter(delta: float) -> void:
  # Simple low-pass filter to reduce jitter
  var smoothing_factor = 0.9  # Adjust between 0.0 (no smoothing) and 1.0 (max smoothing)

  # Smooth position
  custom_transform.origin = last_position.lerp(custom_transform.origin, smoothing_factor)

  # Smooth rotation using quaternion slerp
  var current_quat = Quaternion(custom_transform.basis)
  var last_quat = Quaternion(last_rotation)
  var smoothed_quat = last_quat.slerp(current_quat, smoothing_factor)
  custom_transform.basis = Basis(smoothed_quat)

func _get_target_rotation_basis() -> Basis:
  if attractors.size() == 0:
    return custom_transform.basis

  var attractor = attractors[0]

  if preserve_upright_orientation:
    # Preserve upright orientation while aligning forward direction
    return _get_upright_aligned_basis(attractor.global_transform.basis)
  else:
    # Direct alignment with attractor
    return attractor.global_transform.basis

func _get_upright_aligned_basis(attractor_basis: Basis) -> Basis:
  var current_basis = custom_transform.basis

  # Extract forward direction from attractor
  var attractor_forward = -attractor_basis.z  # Assuming -Z is forward in Godot

  # Calculate the desired right vector (cross product of world up and forward)
  var desired_right = upright_direction.cross(attractor_forward).normalized()

  # Recalculate forward to ensure orthogonality
  var desired_forward = desired_right.cross(upright_direction).normalized()

  # Create the new basis
  var new_basis = Basis(
    desired_right,
    upright_direction,
    -desired_forward  # Godot uses -Z as forward
  )

  # Limit rotation if needed
  if max_rotation_correction_angle < 180.0:
    var current_rotation = current_basis.get_rotation_quaternion()
    var target_rotation = new_basis.get_rotation_quaternion()
    var rotation_diff = current_rotation.inverse() * target_rotation
    var angle = rotation_diff.get_angle()
    var max_angle = deg_to_rad(max_rotation_correction_angle)

    if angle > max_angle:
      # Slerp towards the target with a maximum angle
      var t = max_angle / angle
      var limited_rotation = current_rotation.slerp(target_rotation, t)
      new_basis = Basis(limited_rotation)

  return new_basis

func _get_moment_of_inertia() -> float:
  # Simplified moment of inertia calculation
  if grabbable_mesh:
    var aabb = grabbable_mesh.get_aabb()
    var size = aabb.size.length()
    return (1.0 / 6.0) * mass * size * size
  else:
    # Fallback if mesh isn't set
    return mass

func setup_outline_materials() -> void:
  match outline_mode:
    OutlineMode.EDGE_SHADER:
      outline_shader_material = ShaderMaterial.new()
      outline_shader_material.shader = preload("../shaders/pixel_perfect_outline.gdshader")
    OutlineMode.INVERTED_HULL:
      outline_material = StandardMaterial3D.new()
      outline_material.grow = true
      outline_material.blend_mode = BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA
      outline_material.cull_mode = BaseMaterial3D.CULL_FRONT
      outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

func setup_physics() -> void:
  contact_monitor = true
  max_contacts_reported = 5
  linear_damp = 0.0
  angular_damp = 0.0

func reset_to_initial_state() -> void:
  drop()
  custom_transform = initial_transform
  custom_linear_velocity = Vector3.ZERO
  custom_angular_velocity = Vector3.ZERO
  position_error_integral = Vector3.ZERO
  rotation_error_integral = Vector3.ZERO
  PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, initial_transform)
  linear_velocity = Vector3.ZERO
  angular_velocity = Vector3.ZERO

# Public API
func throw(direction: Vector3) -> void:
  custom_linear_velocity += direction * throw_strength / mass
  drop()
  interaction.emit(self, "throwed")

func drop() -> void:
  attractors = []
  is_grabbed = false
  position_error_integral = Vector3.ZERO
  rotation_error_integral = Vector3.ZERO
  linear_velocity = custom_linear_velocity
  angular_velocity = custom_angular_velocity
  collision_layer |= collision_layers_on_grab
  collision_mask |= collision_mask_on_grab
  interaction.emit(self, "dropped")

func grab(target_attractors: Array[Marker3D]) -> void:
  attractors = target_attractors
  is_grabbed = true

  # Initialize custom physics state
  custom_transform = global_transform
  custom_linear_velocity = linear_velocity
  custom_angular_velocity = angular_velocity
  position_error_integral = Vector3.ZERO
  rotation_error_integral = Vector3.ZERO
  last_position = custom_transform.origin
  last_rotation = custom_transform.basis

  collision_layer &= ~collision_layers_on_grab
  collision_mask &= ~collision_mask_on_grab
  interaction.emit(self, "grabbed")

# Convenience methods
func grab_single(target: Marker3D) -> void:
  grab([target])

func grab_two_handed(primary: Marker3D, secondary: Marker3D) -> void:
  grab([primary, secondary])

func focus() -> void:
  interaction.emit(self, "focused")

func unfocus() -> void:
  interaction.emit(self, "unfocused")

# Visual effects
func _apply_outline() -> void:
  if not outline_on_focus or not grabbable_mesh: return

  var material = grabbable_mesh.get_surface_override_material(0)
  if not material: return

  var cloned_material = material.duplicate()

  match outline_mode:
    OutlineMode.EDGE_SHADER:
      outline_shader_material.set_shader_parameter("outline_color", outline_color)
      cloned_material.next_pass = outline_shader_material
    OutlineMode.INVERTED_HULL:
      outline_material.albedo_color = outline_color
      grabbable_mesh.material_overlay = outline_material

  grabbable_mesh.set_surface_override_material(0, cloned_material)

func _remove_outline() -> void:
  if not grabbable_mesh: return

  var material = grabbable_mesh.get_surface_override_material(0)
  if material:
    material.next_pass = null

  grabbable_mesh.material_overlay = null

# Signal handler
func _on_interaction(grabbable: Grabbable3D, action: String) -> void:
  match action:
    "focused": _apply_outline()
    "unfocused": _remove_outline()
    "grabbed", "throwed", "dropped": pass
