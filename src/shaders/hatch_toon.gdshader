shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform sampler2D albedo_tex : source_color;
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.8;

varying vec3 v_color;
varying vec2 v_uv;

void vertex() {
	v_color = COLOR.rgb;
	v_uv = UV;
}

void fragment() {
	// Sample texture for Starhawk hulls, or use pure color for asteroids
	vec4 tex_col = texture(albedo_tex, v_uv);
	ALBEDO = v_color * tex_col.rgb; 
}

float aa_step(float edge, float val) {
	// ACE ANTI-ALIASING: Surgical softening of cel-bands
	float delta = fwidth(val) * 1.5; 
	return smoothstep(edge - delta, edge + delta, val);
}

void light() {
	// ACE UNIVERSAL SHADOW HARDENING: Surgical thresholding to purge remaining Moire
	float atten = ATTENUATION;
	// Buffer the snap (0.45-0.55) to provide flicker-free anti-aliased shadow borders
	float sharp_atten = smoothstep(0.45, 0.55, atten); 
	float l_level = dot(NORMAL, LIGHT) * sharp_atten;
	
	// COLOR TIERING: High-fidelity BANDING
	float t2 = aa_step(0.25, l_level);
	float t1 = aa_step(0.65, l_level);
	
	vec3 shadow_col = ALBEDO * 0.18; // Vibrant ambient floor keeps trees from flickering black
	vec3 mid_col = ALBEDO * 0.55;
	
	vec3 final_col = mix(shadow_col, mid_col, t2);
	final_col = mix(final_col, ALBEDO, t1);
	
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR;
}
