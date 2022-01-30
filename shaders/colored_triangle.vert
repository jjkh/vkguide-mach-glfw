#version 450 // GLSL v4.5

// output variable for fragment shader
layout (location = 0) out vec3 outColor;

void main()
{
	const vec3 positions[3] = vec3[3](
		vec3( 0.8f,  0.8f,  0.0f),
		vec3(-0.8f,  0.8f,  0.0f),
		vec3( 0.0f, -0.8f,  0.0f)
	);

	const vec3 colors[3] = vec3[3](
		vec3(1.0f, 0.0f, 0.0f),
		vec3(0.0f, 1.0f, 0.0f),
		vec3(0.0f, 0.0f, 1.0f)
	);

	// output the position of each vertex
	gl_Position = vec4(positions[gl_VertexIndex], 1.0f);
	outColor = colors[gl_VertexIndex];
}