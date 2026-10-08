#include <AdaEngine/View.glsl>
#include "../mesh2d/mesh2d_uniform.glsl"
#include "../mesh2d/mesh2d_functions.glsl"

#ifdef VERTEX_POSITIONS
layout (location = 0) in vec3 a_Position;
#endif

#ifdef VERTEX_NORMALS
layout (location = 1) in vec3 a_Normal;
#endif

#ifdef VERTEX_UVS
layout (location = 2) in vec2 a_UV;
#endif

#ifdef VERTEX_COLORS
layout (location = 3) in vec4 a_VertexColor;
#endif
