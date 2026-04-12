shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform vec3 albedo : source_color = vec3(0.35, 0.25, 0.15);
uniform sampler2D bark_texture : source_color;
uniform sampler2D normal_map : hint_normal;
uniform float normal_strength : hint_range(0.0, 5.0) = 1.0;
uniform float hatching_strength : hint_range(0.0, 1.0) = 0.4;
uniform float shadow_cut : hint_range(0.0, 1.0) = 0.45;

varying vec3 v_color;
varying vec3 v_world_pos;
varying vec3 v_normal;

void vertex() {
	v_color = COLOR.rgb;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	
	// Subtle trunk sway
	float wind = sin(v_world_pos.x * 0.1 + TIME * 1.5) * 0.05 * (VERTEX.y * 0.1);
	VERTEX.x += wind;
	VERTEX.z += wind;
}

void fragment() {
	vec4 tex = texture(bark_texture, UV * vec2(1.0, 3.5));
	
	// NORMAL MAPPING: Apply tactile bark depth detail
	vec3 tex_normal = texture(normal_map, UV * vec2(1.0, 3.5)).xyz * 2.0 - 1.0;
	
	// AUTO-NORMAL Fallback: Derive tactility from bark albedo intensity
	float h0 = dot(tex.rgb, vec3(0.333));
	float h1 = dot(texture(bark_texture, (UV + vec2(0.005, 0.0)) * vec2(1.0, 3.5)).rgb, vec3(0.333));
	float h2 = dot(texture(bark_texture, (UV + vec2(0.0, 0.005)) * vec2(1.0, 3.5)).rgb, vec3(0.333));
	vec3 auto_norm = normalize(vec3(h0 - h1, h0 - h2, 0.1));
	
	tex_normal = normalize(tex_normal + auto_norm);
	NORMAL = normalize(TANGENT * tex_normal.x + BINORMAL * tex_normal.y + NORMAL * tex_normal.z);
	
	// Multi-tone integration: Mix instance color (Brown/Tan/White) with bark texture
	ALBEDO = mix(v_color, v_color * tex.rgb, 0.7);
	
	// LIGHTING: Standard Toon with rim highlights
	float rim = 1.0 - dot(NORMAL, VIEW);
	ALBEDO += v_color * pow(rim, 3.0) * 0.2;
}
