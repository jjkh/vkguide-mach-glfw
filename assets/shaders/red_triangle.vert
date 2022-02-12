#version 450 // GLSL v4.5

void main()
{
	const vec3 positions[3] = vec3[3](
		vec3( 0.8f,  0.8f,  0.0f),
		vec3(-0.8f,  0.8f,  0.0f),
		vec3( 0.0f, -0.8f,  0.0f)
	);

	// output the position of each vertex
	gl_Position = vec4(positions[gl_VertexIndex], 1.0f);
}