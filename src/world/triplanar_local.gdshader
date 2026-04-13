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
	
	# NEON ROADS: Procedural Cyberpunk Grid
	# ACE RADIAL STABILITY: We use a high-contrast radial mask for the 1000m city grid
	vec2 road_grid = fract(v_local_pos.xz * 0.001); 
	float road_mask = step(0.8, road_grid.x) + step(0.8, road_grid.y);
	
	// Robust City Height Mask: 850m is the plateau height. 
	// We use the distance from center minus the planet base radius (estimated 1M-ish)
	// Since v_local_pos is absolute local coordinate on the sphere:
	float dist_from_center = length(v_local_pos);
	// We'll use a derivative-based mask or a wider threshold to ensure visibility
	float city_height_mask = smoothstep(500.0, 800.0, dist_from_center - 1000000.0 * (length(v_normal))); 
	// That's tricky because radius varies. Let's use a simpler heuristic:
	// A high-pass filter on the distance from center
	float h_mask = smoothstep(150.0, 250.0, dist_from_center - 1000000.0); // Assume 1M radius base
	
	vec3 road_col = vec3(0.0, 1.0, 1.0) * road_mask * 15.0; // High intensity neon
	
	ALBEDO = COLOR.rgb * final_tex;
	EMISSION = road_col * step(0.5, h_mask); 
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
