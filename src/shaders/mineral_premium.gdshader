shader_type spatial;
render_mode cull_back, blend_mix, diffuse_burley, specular_schlick_ggx;

// Per-tier knobs — set once on the shared material, no per-instance cost.
uniform float emission_strength : hint_range(0.0, 3.0) = 0.5;
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.0;
uniform float iridescence : hint_range(0.0, 1.0) = 0.0;
uniform float sparkle_amount : hint_range(0.0, 1.0) = 0.0;
uniform float metallic_amount : hint_range(0.0, 1.0) = 0.5;
uniform float roughness_amount : hint_range(0.0, 1.0) = 0.3;

// Per-instance via MeshInstance3D.set_instance_shader_parameter:
//   flash_strength — bumped to 1.0 on hit, decays via the script's flash_timer
//   beat_glow      — receives the live music-director kick/beat intensity
instance uniform float flash_strength = 0.0;
instance uniform float beat_glow = 0.0;

// Per-instance phase derived from world position so 100 minerals don't pulse
// in lockstep. Zero CPU cost — purely shader-side.
float instance_phase(mat4 model) {
	return model[3].x * 0.137 + model[3].z * 0.219 + model[3].y * 0.083;
}

// Cheap hash for sparkle noise.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec3 base = COLOR.rgb;
	float phase = instance_phase(MODEL_MATRIX);

	// View-driven fresnel for rim glow + iridescence.
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - ndv, 3.0);

	// Iridescent rainbow rim — wraps around the edges of the gem.
	float t = TIME * 0.6 + rim * 6.2831 + phase;
	vec3 rainbow = vec3(
		sin(t) * 0.5 + 0.5,
		sin(t + 2.094) * 0.5 + 0.5,
		sin(t + 4.188) * 0.5 + 0.5
	);
	vec3 iri_albedo = mix(base, rainbow, iridescence * rim * 0.35);

	// Pulse: gentle breathing emission.
	float pulse = 1.0 + sin(TIME * 1.8 + phase) * pulse_amount;

	// Sparkle: time-varying speckle in the high-emission spots.
	float spk = 0.0;
	if (sparkle_amount > 0.0) {
		vec2 sp_uv = UV * 32.0 + vec2(TIME * 0.7, 0.0) + phase;
		float n = hash21(floor(sp_uv));
		spk = smoothstep(0.92, 1.0, n) * sparkle_amount;
	}

	ALBEDO = iri_albedo;
	METALLIC = metallic_amount;
	ROUGHNESS = roughness_amount;
	EMISSION = (iri_albedo * emission_strength * pulse) + vec3(spk);
	// Brighten rim on high-iridescence to sell the "premium" look.
	EMISSION += rainbow * iridescence * rim * 0.25;
	// Live damage flash + beat-sync glow (per-instance).
	EMISSION += base * (flash_strength * 12.0 + beat_glow);
}
