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
@export_group("Mesh")
## The mesh related to this grabbable to apply the outline
@export var grabbable_mesh: MeshInstance3D
# Reference to the attractor (Marker3D)
@export var grab_point_A: Marker3D
@export var grab_point_B: Marker3D
@export var attractor: Marker3D
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
@export_subgroup("Edge shader") # https://www.videopoetics.com/tutorials/pixel-perfect-outline-shaders-unity/
@export var outline_shader_color: Color = Color.WHITE
@export var outline_width: float = 2.0
@export var outline_shader: Shader = preload("../shaders/pixel_perfect_outline.gdshader")
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

# Add a public function to reset its state
func reset_to_initial_state() -> void:
  # For a RigidBody3D, you should use `PhysicsServer3D` to teleport it
  # and immediately stop its motion.
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

func _physics_process(_delta: float) -> void:
  constant_force = Vector3.ZERO
  if not attractor:
    initial_transform = global_transform
  else:
    var target_position = attractor.global_transform.origin
    var current_position = global_transform.origin
    var direction = (target_position - current_position).normalized()
    var distance = target_position.distance_to(current_position)

    # Spring force: Pull the object towards the attractor
    var spring_force = direction * (distance * spring_constant)
    var weight_force = mass * get_gravity()

    # Apply angular damping to reduce oscillation and stabilize the rotation
    angular_damp = damping_factor
    linear_damp = damping_factor

    constant_force = - weight_force # make it weightless
    apply_central_force(spring_force) # pull it without rotate

    # If the body has grab points
    if grab_point_A and grab_point_B:
      var point_A = grab_point_A.global_transform.origin
      var point_B = grab_point_B.global_transform.origin
      apply_force(-spring_force, point_A)
      apply_force(+spring_force, point_B)

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
  linear_damp = 0.0
  @warning_ignore("standalone_expression")
  collision_layer |= collision_layers_on_grab
  collision_mask |= collision_mask_on_grab
  dropped.emit(self)

func pull(target):
  attractor = target
  collision_layer &= ~collision_layers_on_grab
  collision_mask &= ~collision_mask_on_grab
  pulled.emit(self)

func focus() -> void: focused.emit(self)

func unfocus() -> void: unfocused.emit(self)

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
