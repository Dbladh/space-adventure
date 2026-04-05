shader_type black; // Error here, I will use standard syntax
// Correcting to a functional Godot 4 shader
shader_type spatial;

// Local-Space Triplanar Shader (FloatingOrigin-Proof)
// Managed by THE PROCEDURALIST.

uniform sampler2D albedo_tex : source_color;
uniform float texture_scale = 1.0;
uniform vec3 layer_color = vec3(0.5);

varying vec3 v_local_pos;
varying vec3 v_normal;

void vertex() {
	v_local_pos = VERTEX;
	v_normal = NORMAL;
}

void fragment() {
	// Calculate Tri-planar weights based on LOCAL Normal
	vec3 blending = abs(v_normal);
	blending /= (blending.x + blending.y + blending.z);
	
	// Sample texture using LOCAL Position (Immune to world-space jitter)
	vec3 x_tex = texture(albedo_tex, v_local_pos.zy * texture_scale).rgb;
	vec3 y_tex = texture(albedo_tex, v_local_pos.xz * texture_scale).rgb;
	vec3 z_tex = texture(albedo_tex, v_local_pos.xy * texture_scale).rgb;
	
	vec3 final_tex = x_tex * blending.x + y_tex * blending.y + z_tex * blending.z;
	
	ALBEDO = COLOR.rgb * final_tex;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

float aa_step(float edge, float val) {
	// ACE ANTI-ALIASING: Surgical softening of planetary cel-bands
	float delta = fwidth(val) * 1.5; 
	return smoothstep(edge - delta, edge + delta, val);
}

void light() {
	// UNIVERSAL CLEAN-TOON: 3-Tier Cel-Shading for Planet Surface
	float n_dot_l = dot(NORMAL, LIGHT);
	float atten = ATTENUATION;
	float l_level = n_dot_l * atten;
	
	// COLOR TIERING: Match asteroid clean-cel aesthetic
	float t2 = aa_step(0.25, l_level);
	float t1 = aa_step(0.65, l_level);
	
	vec3 shadow_col = ALBEDO * 0.15;
	vec3 mid_col = ALBEDO * 0.45;
	
	vec3 final_col = mix(shadow_col, mid_col, t2);
	final_col = mix(final_col, ALBEDO, t1);
	
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR;
}
