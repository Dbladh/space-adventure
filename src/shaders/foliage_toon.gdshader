shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_disabled, depth_draw_opaque;

uniform sampler2D leaf_texture : source_color;
uniform sampler2D normal_map : hint_normal;
uniform float normal_strength : hint_range(0.0, 5.0) = 1.2;
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.8;
uniform float wind_speed : hint_range(0.0, 10.0) = 1.2;
uniform float wind_strength : hint_range(0.0, 5.0) = 0.8;

varying vec3 v_color;
varying vec2 v_uv;

void vertex() {
	v_color = COLOR.rgb;
	v_uv = UV;
	
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	float time = floor(TIME * 8.0) / 8.0;
	
	// 1. PRIMARY SWAY (Subtle leaning)
	float sway = sin(time * wind_speed + world_origin.x * 0.15 + world_origin.z * 0.15) * 0.8;
	sway += sin(time * wind_speed * 0.4 + world_origin.y * 0.2) * 0.2;
	
	// 2. LEAF FLUTTER (Maintain botanical life)
	float flutter = sin(time * wind_speed * 3.5 + VERTEX.x * 8.0) * 0.12;
	
	// Apply combined movement, weighted by height
	float h_weight = clamp(VERTEX.y * 0.1, 0.0, 1.0);
	VERTEX.x += (sway * wind_strength + flutter) * h_weight;
	VERTEX.z += (sway * wind_strength * 0.5 + flutter) * h_weight;
}

void fragment() {
	// ACE LEAF DETAIL: Scale UVs (1.8x) so each card displays individual leaf fragments rather than a whole cluster
	vec2 leaf_uv = v_uv * 1.5; 
	vec4 tex_col = texture(leaf_texture, leaf_uv);
	// Alpha-clip for clean edges
	if (tex_col.a < 0.3) discard;
	
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
	
	vec3 shadow_col = ALBEDO * 0.45; // Lifted shadow floor for 'Light & Airy' feel (Was 0.35)
	vec3 mid_col = ALBEDO * 0.75;
	
	vec3 final_col = mix(shadow_col, mid_col, t2);
	final_col = mix(final_col, ALBEDO, t1);
	
	// 1. BACKLIT TRANSLUCENCY (Fake SSS): Leaves glow when the sun is behind them
	float sss = pow(clamp(dot(LIGHT, VIEW), 0.0, 1.0), 3.0) * 0.6;
	final_col += ALBEDO * sss;
	
	// 2. ILLUSTRATIVE RIM LIGHT: Edge-lighting against the sky
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0) * dot(NORMAL, LIGHT);
	final_col += LIGHT_COLOR * clamp(rim, 0.0, 1.0) * 0.5;
	
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR;
}
