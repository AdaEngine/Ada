// Generated from GLSL by AdaShaderTranspilerTool.
diagnostic(off, derivative_uniformity);

struct VertexOut {
  Color : vec4f,
  ViewPosition : vec3f,
  ViewNormal : vec3f,
  ViewTangent : vec4f,
  TextureCoordinate : vec2f,
  TextureFlags : vec4f,
  ShadowFlags : vec4f,
  ShadowPosition : vec4f,
  Roughness : f32,
  Metallic : f32,
  EmissiveStrength : f32,
  EmissiveLightThreshold : f32,
}

struct AE_GlobalView {
  /* @offset(0) */
  u_Projection : mat4x4f,
  /* @offset(64) */
  u_ViewProjection : mat4x4f,
  /* @offset(128) */
  u_ViewMatrix : mat4x4f,
}

struct DirectionalLight3DUniform {
  /* @offset(0) */
  u_LightDirectionIntensity : vec4f,
  /* @offset(16) */
  u_LightRadianceAmbient : vec4f,
  /* @offset(32) */
  u_ShadowViewProjection : mat4x4f,
  /* @offset(96) */
  u_ShadowParameters : vec4f,
}

var<private> a_Model0 : vec4f;

var<private> a_Model1 : vec4f;

var<private> a_Model2 : vec4f;

var<private> a_Model3 : vec4f;

var<private> a_Normal : vec3f;

var<private> a_Position : vec3f;

var<private> a_Tangent : vec4f;

var<private> Output : VertexOut;

var<private> a_Color : vec4f;

@group(0) @binding(2) var<uniform> x_102 : AE_GlobalView;

var<private> a_TextureCoordinate : vec2f;

var<private> a_TextureFlags : vec4f;

var<private> a_ShadowFlags : vec4f;

@group(0) @binding(1) var<uniform> x_174 : DirectionalLight3DUniform;

var<private> a_Material : vec4f;

var<private> gl_Position : vec4f;

fn main_1() {
  var model : mat4x4f;
  var normalMatrix : mat3x3f;
  var normal : vec3f;
  var worldPosition : vec4f;
  var worldTangent : vec3f;
  var x_169 : vec4f;
  model = mat4x4f(vec4f(a_Model0.x, a_Model0.y, a_Model0.z, a_Model0.w), vec4f(a_Model1.x, a_Model1.y, a_Model1.z, a_Model1.w), vec4f(a_Model2.x, a_Model2.y, a_Model2.z, a_Model2.w), vec4f(a_Model3.x, a_Model3.y, a_Model3.z, a_Model3.w));
  let x_48 = model[0u];
  let x_50 = model[1u];
  let x_52 = model[2u];
  normalMatrix = transpose(((1.0f / determinant(mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz))) * mat3x3f(vec3f(((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][1u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][2u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][2u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][1u])), ((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][2u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][1u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][1u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][2u])), ((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][1u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][2u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][2u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][1u]))), vec3f(((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][2u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][0u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][0u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][2u])), ((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][0u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][2u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][2u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][0u])), ((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][2u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][0u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][0u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][2u]))), vec3f(((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][0u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][1u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][1u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][0u])), ((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][1u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][0u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][0u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[2u][1u])), ((mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][0u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][1u]) - (mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[0u][1u] * mat3x3f(x_48.xyz, x_50.xyz, x_52.xyz)[1u][0u]))))));
  normal = normalize((normalMatrix * a_Normal));
  worldPosition = (model * vec4f(a_Position.x, a_Position.y, a_Position.z, 1.0f));
  worldTangent = normalize((mat3x3f(model[0u].xyz, model[1u].xyz, model[2u].xyz) * a_Tangent.xyz));
  Output.Color = a_Color;
  Output.ViewPosition = ((x_102.u_ViewMatrix * worldPosition)).xyz;
  let x_113 = x_102.u_ViewMatrix;
  Output.ViewNormal = normalize((mat3x3f(x_113[0u].xyz, x_113[1u].xyz, x_113[2u].xyz) * normal));
  let x_127 = x_102.u_ViewMatrix;
  let x_137 = normalize((mat3x3f(x_127[0u].xyz, x_127[1u].xyz, x_127[2u].xyz) * worldTangent));
  Output.ViewTangent = vec4f(x_137.x, x_137.y, x_137.z, a_Tangent.w);
  Output.TextureCoordinate = a_TextureCoordinate;
  Output.TextureFlags = a_TextureFlags;
  Output.ShadowFlags = a_ShadowFlags;
  if ((a_ShadowFlags.x > 0.5f)) {
    x_169 = (x_174.u_ShadowViewProjection * worldPosition);
  } else {
    x_169 = vec4f();
  }
  Output.ShadowPosition = x_169;
  Output.Roughness = clamp(a_Material.x, 0.03999999910593032837f, 1.0f);
  Output.Metallic = clamp(a_Material.y, 0.0f, 1.0f);
  Output.EmissiveStrength = max(a_Material.z, 0.0f);
  Output.EmissiveLightThreshold = a_Material.w;
  gl_Position = (x_102.u_ViewProjection * worldPosition);
  return;
}

struct main_out {
  @location(0)
  Output_1 : vec4f,
  @location(1)
  Output_2 : vec3f,
  @location(2)
  Output_3 : vec3f,
  @location(3)
  Output_4 : vec4f,
  @location(4)
  Output_5 : vec2f,
  @location(5)
  Output_6 : vec4f,
  @location(6)
  Output_7 : vec4f,
  @location(7)
  Output_8 : vec4f,
  @location(8)
  Output_9 : f32,
  @location(9)
  Output_10 : f32,
  @location(10)
  Output_11 : f32,
  @location(11)
  Output_12 : f32,
  @builtin(position)
  gl_Position : vec4f,
}

@vertex
fn flat3d_vertex(@location(5) a_Model0_param : vec4f, @location(6) a_Model1_param : vec4f, @location(7) a_Model2_param : vec4f, @location(8) a_Model3_param : vec4f, @location(1) a_Normal_param : vec3f, @location(0) a_Position_param : vec3f, @location(4) a_Tangent_param : vec4f, @location(9) a_Color_param : vec4f, @location(2) a_TextureCoordinate_param : vec2f, @location(11) a_TextureFlags_param : vec4f, @location(12) a_ShadowFlags_param : vec4f, @location(10) a_Material_param : vec4f) -> main_out {
  a_Model0 = a_Model0_param;
  a_Model1 = a_Model1_param;
  a_Model2 = a_Model2_param;
  a_Model3 = a_Model3_param;
  a_Normal = a_Normal_param;
  a_Position = a_Position_param;
  a_Tangent = a_Tangent_param;
  a_Color = a_Color_param;
  a_TextureCoordinate = a_TextureCoordinate_param;
  a_TextureFlags = a_TextureFlags_param;
  a_ShadowFlags = a_ShadowFlags_param;
  a_Material = a_Material_param;
  main_1();
  return main_out(Output.Color, Output.ViewPosition, Output.ViewNormal, Output.ViewTangent, Output.TextureCoordinate, Output.TextureFlags, Output.ShadowFlags, Output.ShadowPosition, Output.Roughness, Output.Metallic, Output.EmissiveStrength, Output.EmissiveLightThreshold, gl_Position);
}

