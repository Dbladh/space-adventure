shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_disabled, depth_draw_opaque;

uniform sampler2D leaf_texture : source_color, filter_nearest;
uniform sampler2D normal_map : hint_normal, filter_nearest;
uniform float normal_strength : hint_range(0.0, 5.0) = 1.2;
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.8;
uniform float wind_speed : hint_range(0.0, 10.0) = 1.2;
uniform float wind_strength : hint_range(0.0, 5.0) = 0.8;
uniform float biolum_intensity : hint_range(0.0, 2.0) = 0.0;
// Mobile path: skip halftone / SSS / rim / biolum tiers in light(),
// and pull the dither fade range in (3-5 km vs 8-12 km).
uniform bool mobile_simple = false;

varying vec3 v_color;
varying vec2 v_uv;
varying float v_cam_dist;

// ACE ORDERED DITHER: 4x4 Bayer Matrix for crunchy retro-fading
const mat4 DITHER_MATRIX = mat4(
	vec4(0.0625, 0.5625, 0.1875, 0.6875),
	vec4(0.8125, 0.3125, 0.9375, 0.4375),
	vec4(0.25,   0.75,   0.125,  0.625),
	vec4(1.0,    0.5,    0.875,  0.375)
);

void vertex() {
	v_color = COLOR.rgb;
	v_uv = UV;
	
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	float time = floor(TIME * 8.0) / 8.0;
	
	// ACE WIND HIBERNATION: Fade animation based on proximity to the camera.
	float cam_dist = length(CAMERA_POSITION_WORLD - world_origin);
	v_cam_dist = cam_dist;
	float dist_weight = smoothstep(2500.0, 1200.0, cam_dist);
	
	// 1. PRIMARY SWAY & LEAF FLUTTER
	float sway = sin(time * wind_speed + world_origin.x * 0.05 + world_origin.z * 0.05) * 0.3;
	float flutter = sin(time * wind_speed * 1.8 + VERTEX.x * 2.0) * 0.04;
	
	// 2. HYPER-PROCEDURAL LUMPINESS (Break the circular silhouette)
	vec3 noise_pos = world_origin * 0.15 + VERTEX * 0.4;
	float lump = sin(noise_pos.x * 2.2 + noise_pos.z * 1.8) * cos(noise_pos.y * 1.5);
	lump += sin(noise_pos.x * 0.5 + noise_pos.z * 0.7) * 0.6;
	
	// Apply combined movement, weighted by height AND proximity
	float h_weight = clamp(VERTEX.y * 0.05, 0.0, 1.0) * dist_weight;
	VERTEX += NORMAL * lump * 1.3; // Deform the sphere into complex botanical lumps
	VERTEX.x += (sway * wind_strength + flutter) * h_weight;
	VERTEX.z += (sway * wind_strength * 0.4 + flutter) * h_weight;
}

void fragment() {
	// ACE LEAF DETAIL: Scaled up 2x from previous (0.25x multiplier)
	vec2 leaf_uv = v_uv * 0.25; 
	vec4 tex_col = texture(leaf_texture, leaf_uv);
	// ACE OBSIDIAN DEPTH: Aggressively push darks to near-black for maximum physical relief
	tex_col.rgb = pow(tex_col.rgb, vec3(2.6));
	
	// Alpha-clip for clean edges
	if (tex_col.a < 0.3) discard;
	
	// ACE DISTANCE DITHER: Saturn-style dissolve for the far horizon (LOD Replacement)
	// Gradually dissolves objects into the background between 8km and 12km
	// (mobile pulls these in to 3-5 km — half the fragment-shaded foliage area).
	float fade_start = mobile_simple ? 3000.0 : 8000.0;
	float fade_end = mobile_simple ? 5000.0 : 12000.0;
	float transparency = 1.0 - clamp((v_cam_dist - fade_start) / (fade_end - fade_start), 0.0, 1.0);
	
	ivec2 d_uv = ivec2(mod(FRAGCOORD.xy, 4.0));
	if (DITHER_MATRIX[d_uv.x][d_uv.y] > transparency) discard;
	
	// NORMAL MAPPING: Inject micro-scale leaf details (Normal Map + Auto-Normal)
	vec3 tex_normal = texture(normal_map, leaf_uv).xyz * 2.0 - 1.0;
	
	// AUTO-NORMAL Fallback: If map is flat, derive detail from albedo intensity
	float h0 = dot(tex_col.rgb, vec3(0.333));
	float h1 = dot(texture(leaf_texture, leaf_uv + vec2(0.005, 0.0)).rgb, vec3(0.333));
	float h2 = dot(texture(leaf_texture, leaf_uv + vec2(0.0, 0.005)).rgb, vec3(0.333));
	vec3 auto_norm = normalize(vec3(h0 - h1, h0 - h2, 0.1));
	
	tex_normal = normalize(tex_normal + auto_norm);
	NORMAL = normalize(TANGENT * tex_normal.x + BINORMAL * tex_normal.y + NORMAL * tex_normal.z);
	
	// BACKFACE SYNC: Correct lighting on 'under-side' of leaf cards
	NORMAL = (FRONT_FACING) ? NORMAL : -NORMAL;
	
	// ALPHA HUE SHIFT: Use Blue channel as a branch-specific variety seed
	vec3 branch_col = v_color;
	branch_col.g *= (0.85 + COLOR.b * 0.3); 
	branch_col.r += (COLOR.b - 0.5) * 0.15; 
	
	// BOLD TEXTURE BLENDING: Mix 75% texture, 25% biome color for punchy leaf details.
	ALBEDO = mix(branch_col, branch_col * tex_col.rgb, 0.75);
	
	// VOLUMETRIC AO Approximation: Darken the inward-facing parts a bit more
	float center_mask = 1.0 - length(v_uv - vec2(0.5)) * 0.6;
	ALBEDO *= center_mask;
}

float aa_step(float edge, float val) {
	float delta = fwidth(val) * 1.5; 
	return smoothstep(edge - delta, edge + delta, val);
}

void light() {
	float atten = ATTENUATION;
	float sharp_atten = smoothstep(0.45, 0.55, atten); 
	
	// SPH-NORMAL BIAS: Blend between face normal and view dir for smoother 'Pom-Pom' lighting
	vec3 light_norm = normalize(mix(NORMAL, vec3(0,1,0), 0.3));
	float l_level = dot(light_norm, LIGHT) * sharp_atten;
	
	// COLOR TIERING (Studio Ghibli style)
	float t2 = aa_step(0.20, l_level);
	float t1 = aa_step(0.60, l_level);
	
	vec3 shadow_col = ALBEDO * 0.45;
	vec3 mid_col = ALBEDO * 0.75;

	// Mobile path: skip halftone, SSS, rim, biolum — keeps the toon tiering
	// (cheap) but drops ~5 sin/pow/smoothstep ops per fragment per light.
	if (mobile_simple) {
		vec3 final_col = mix(shadow_col, mid_col, t2);
		final_col = mix(final_col, ALBEDO, t1);
		DIFFUSE_LIGHT += final_col * LIGHT_COLOR * ATTENUATION;
	} else {
		// ACE HALFTONE: Add dot-matrix texture to the midtones and shadows
		// This creates a 'Comic/Sketch' look that is unique to Shadowglass
		vec2 dot_uv = FRAGCOORD.xy * 0.15;
		float dots = sin(dot_uv.x) * sin(dot_uv.y);
		float halftone = smoothstep(0.0, 0.15, dots);
		shadow_col *= mix(0.7, 1.0, halftone);
		mid_col *= mix(0.85, 1.0, halftone);

		vec3 final_col = mix(shadow_col, mid_col, t2);
		final_col = mix(final_col, ALBEDO, t1);

		// 1. BACKLIT TRANSLUCENCY (Fake SSS): Leaves softly transmit when the sun is behind them.
		float sss = pow(clamp(dot(LIGHT, VIEW), 0.0, 1.0), 4.0) * 0.18;
		final_col += ALBEDO * sss;

		// 2. ILLUSTRATIVE RIM LIGHT: Subtle edge-lighting (was 0.5 — read as a glow halo on every tree).
		float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0) * max(dot(NORMAL, LIGHT), 0.0);
		final_col += LIGHT_COLOR * clamp(rim, 0.0, 1.0) * 0.12;

		// 3. BIOLUMINESCENT PULSE: Rare planetary attribute (driven by biolum_intensity uniform).
		float bio_pulse = (sin(TIME * 1.5) * 0.5 + 0.5) * biolum_intensity;
		final_col += ALBEDO * bio_pulse * 1.2;

		// ATTENUATION respect — leaves now darken in shadow instead of being full-bright.
		DIFFUSE_LIGHT += final_col * LIGHT_COLOR * ATTENUATION;
	}
}
