shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform float hatch_density : hint_range(0.0, 4.0) = 1.0;
uniform float hatch_strength : hint_range(0.0, 1.0) = 0.85;

varying vec3 v_color;

void vertex() {
	v_color = COLOR.rgb;
}

void fragment() {
	ALBEDO = v_color; 
}

void light() {
	// ACE ILLUSTRATOR LOGIC: Fine Black-Ink Hatching (Ship-Matching Quality)
	float n_dot_l = dot(NORMAL, LIGHT);
	float atten = ATTENUATION;
	float l_level = n_dot_l * atten;
	
	// Deterministic Screen-Space Pixel Geometry (Fine 6px Grid)
	// This matches the dense, granular ink-lines seen on the Starhawk wing textures.
	vec2 screen_pixel = SCREEN_UV * VIEWPORT_SIZE;
	
	// Diagonal Patterns (X and Y axis combined for 45-degree hand-drawn feel)
	float line_a = step(0.75, mod(screen_pixel.x + screen_pixel.y, 6.0 / hatch_density));
	float line_b = step(0.75, mod(screen_pixel.x - screen_pixel.y, 6.0 / hatch_density));
	
	// COMPOSITE SHADOW STACK (Pure-Black Inversion Fix)
	vec3 final_col = ALBEDO;
	
	if (l_level > 0.65) {
		// 1. HIGH LIGHT: Clean Albedo
		final_col = ALBEDO;
	} else if (l_level > 0.3) {
		// 2. LIGHT SHADOW: Fine Parallel Black Ink
		// We mix toward BLACK (vec3(0.0)) to ensure the line is darker than the shadow.
		final_col = mix(ALBEDO, vec3(0.0), line_a * hatch_strength);
	} else {
		// 3. DEEP SHADOW: Dense Cross-Hatching
		float pattern = max(line_a, line_b);
		final_col = mix(ALBEDO * 0.3, vec3(0.0), pattern * hatch_strength);
	}
	
	// Additive Light Accumulation
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR;
}
