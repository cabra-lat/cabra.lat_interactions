@icon("../assets/interactable.svg")
class_name Interactable3D extends Node3D

const GroupName = "interactables-3d"

signal interacted(interactable: Interactable3D)
signal focused(interactable: Interactable3D)
signal unfocused(interactable: Interactable3D)
signal interaction_limit_reached(interactable: Interactable3D)

enum OutlineMode {
  EdgeShader,
  InvertedHull
}

@export var activate_on_start: bool = true
@export var disable_after_interaction: bool = false
@export var number_of_times_can_be_interacted: int = -1
@export var lock_player_on_interact: bool = false
@export var interaction_sound: AudioStream
@export var interaction_particles: PackedScene
@export var interaction_cooldown: float = 1.0
@export_group("Cursors")
@export var focus_cursor_name: String = 'pointing_hand'
@export_group("Scan")
@export var scannable: bool = false
@export var can_be_rotated_on_scan: bool = true
@export var target_scannable_object: Node3D
@export_group("Outline")
@export var outline_mode: OutlineMode = OutlineMode.EdgeShader
@export var outline_on_focus: bool = true
@export var outline_mesh: GeometryInstance3D
@export_subgroup("Edge shader") # https://www.videopoetics.com/tutorials/pixel-perfect-outline-shaders-unity/
@export var outline_shader_color: Color = Color.WHITE
@export var outline_thickness: float = 2.0
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

var can_interact: bool = true
var can_be_interacted: bool = true
var times_interacted: int = 0:
  set(value):
    var previous_value = times_interacted
    times_interacted = value
    if number_of_times_can_be_interacted < 0: return

    if previous_value != times_interacted \
    and times_interacted >= number_of_times_can_be_interacted:
      interaction_limit_reached.emit(self)
      deactivate()

var outline_material: StandardMaterial3D
var outline_shader_material: ShaderMaterial

func _enter_tree() -> void:
  var children = get_children()
  outline_mesh = children.filter(func(c): return c is MeshInstance3D).pop_front()
  add_to_group(GroupName)

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

  if activate_on_start:
    activate()

  interacted.connect(on_interacted)
  focused.connect(on_focused)
  unfocused.connect(on_unfocused)

func interact():
  if can_be_interacted and can_interact:
    interacted.emit(self)
    can_interact = false
    times_interacted += 1
    await get_tree().create_timer(interaction_cooldown).timeout
    can_interact = true

func activate() -> void:
  can_be_interacted = true
  times_interacted = 0

func deactivate() -> void:
  can_be_interacted = false
  _remove_outline_shader()

func focus() -> void: focused.emit(self)

func unfocus() -> void: unfocused.emit(self)

func _apply_outline_shader() -> void:
  if can_be_interacted and outline_on_focus and outline_mesh:
    var material = outline_mesh.get_active_material(0)

    match outline_mode:
      OutlineMode.EdgeShader:
        if material and not material.next_pass:
          outline_shader_material.set_shader_parameter("outline_color", outline_shader_color)
          outline_shader_material.set_shader_parameter("outline_thickness", outline_thickness)
          material.next_pass = outline_shader_material

      OutlineMode.InvertedHull:
        outline_material.albedo_color = outline_hull_color
        outline_material.grow_amount = outline_grow_amount
        outline_mesh.material_overlay = outline_material

func _remove_outline_shader() -> void:
  if outline_on_focus and outline_mesh is MeshInstance3D:
    var material = outline_mesh.get_active_material(0)

    match outline_mode:
      OutlineMode.EdgeShader:
        if material:
          material.next_pass = null
      OutlineMode.InvertedHull:
        outline_mesh.material_overlay = null

#region Signal callbacks
func on_interacted(_interactable: Interactable3D) -> void:
  if interaction_sound:
    var audio = AudioStreamPlayer3D.new()
    audio.stream = interaction_sound
    add_child(audio)
    audio.play()

  if interaction_particles:
    var particles = interaction_particles.instantiate()
    add_child(particles)
    particles.global_transform = global_transform
    particles.emitting = true

  if disable_after_interaction:
    deactivate()

func on_focused(_interactable: Interactable3D) -> void:
  _apply_outline_shader()

func on_unfocused(_interactable: Interactable3D) -> void:
  _remove_outline_shader()
#endregion
