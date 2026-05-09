shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Biome-aware planet land shader (FloatingOrigin-proof: samples in LOCAL space).
// Drives ground / forest / rock / snow / beach colour from the planet's
// procedurally-rolled palette uniforms.

uniform sampler2D albedo_tex : source_color;
uniform float texture_scale = 1.0;
uniform float planet_radius = 1000000.0;
uniform float sea_level = -120.0;

// Procedural biome palette (set per-planet from PlanetGen.pal_*).
uniform vec3 col_beach   : source_color = vec3(0.76, 0.70, 0.50);
uniform vec3 col_grass   : source_color = vec3(0.27, 0.67, 0.27);
uniform vec3 col_forest  : source_color = vec3(0.20, 0.55, 0.20);
uniform vec3 col_rock    : source_color = vec3(0.50, 0.45, 0.40);
uniform vec3 col_snow    : source_color = vec3(0.92, 0.94, 0.98);

// Cloud noise uniforms — duplicated from the cloud shader so the land
// shader can sample the same cloud density and project shadows down onto
// the surface. PlanetGen sets these on every chunk's land_material to
// match the planet's cloud roll. cloud_strength scales the darkening so
// it can be turned off (set to 0) for cloud-free worlds.
uniform float cloud_cell_scale = 0.001;
uniform float cloud_thresh_lo  = 0.50;
uniform float cloud_thresh_hi  = 0.70;
uniform float cloud_strength   = 0.45;

varying vec3 v_local_pos;
varying vec3 v_local_norm;
varying float v_height;
varying float v_steepness;

void vertex() {
	v_local_pos = VERTEX;
	v_local_norm = normalize(VERTEX);
	v_height = length(VERTEX) - planet_radius;
	v_steepness = dot(normalize(VERTEX), NORMAL);
}

float aa_step(float edge, float val) {
	float delta = fwidth(val) * 1.5;
	return smoothstep(edge - delta, edge + delta, val);
}

// 3D noise functions duplicated from the cloud shader so the land surface
// can sample the same density field and cast cloud shadows on the ground.
float c_hash3(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}
float c_vnoise(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(c_hash3(i + vec3(0,0,0)), c_hash3(i + vec3(1,0,0)), f.x),
	               mix(c_hash3(i + vec3(0,1,0)), c_hash3(i + vec3(1,1,0)), f.x), f.y),
	           mix(mix(c_hash3(i + vec3(0,0,1)), c_hash3(i + vec3(1,0,1)), f.x),
	               mix(c_hash3(i + vec3(0,1,1)), c_hash3(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float c_fbm(vec3 p) {
	float v = 0.0; float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * c_vnoise(p);
		p = p * 2.13 + vec3(13.7, 5.1, 19.3);
		a *= 0.5;
	}
	return v;
}
float cloud_density_at(vec3 dir, float t) {
	vec3 base = dir * planet_radius * cloud_cell_scale;
	vec3 lp_large = base * 0.35 + vec3(t * 0.6, t * 0.3, -t * 0.2);
	vec3 lp_med   = base * 1.0  + vec3(t, t * 0.5, -t * 0.3) + vec3(50.0);
	float d_large = c_fbm(lp_large);
	float d_med   = c_fbm(lp_med);
	return d_large * 0.60 + d_med * 0.40;
}

void fragment() {
	// 1. Triplanar texture (modulates intensity only, not hue).
	vec3 blending = abs(NORMAL);
	blending /= (blending.x + blending.y + blending.z);
	vec3 tex_x = texture(albedo_tex, v_local_pos.zy * texture_scale).rgb;
	vec3 tex_y = texture(albedo_tex, v_local_pos.xz * texture_scale).rgb;
	vec3 tex_z = texture(albedo_tex, v_local_pos.xy * texture_scale).rgb;
	vec3 detail = tex_x * blending.x + tex_y * blending.y + tex_z * blending.z;
	float detail_level = mix(0.88, 1.12, detail.r);

	// 2. Patchy grass mix between forest (darker) and grass (lighter).
	float grass_patch = smoothstep(0.1, 0.4, detail.r + sin(v_local_pos.x * 0.05) * 0.1);
	vec3 base_grass = mix(col_forest, col_grass, grass_patch);

	// 3. Height-based zone bands (organic warp on each edge).
	float warp = sin(v_local_pos.x * 0.0015) * 300.0 + cos(v_local_pos.z * 0.002) * 200.0;
	float warped_h = v_height + warp;

	float beach_warp = sin(v_local_pos.x * 0.008) * 15.0 + cos(v_local_pos.z * 0.01) * 10.0;
	float t_beach_end  = aa_step(sea_level + 120.0 + beach_warp, v_height);
	float t_rock_start = aa_step(2200.0, warped_h);
	float t_snow       = aa_step(4000.0, warped_h);

	vec3 albedo = col_beach;
	albedo = mix(albedo, base_grass, t_beach_end);
	albedo = mix(albedo, col_rock, t_rock_start);
	albedo = mix(albedo, col_snow, t_snow);

	// 4. Polar caps — soft transition that's broken up by triplanar detail
	// noise so the dither pattern lands on irregular pixels instead of clean
	// latitude rings. The transition centers around lat ≈ 65° and varies by
	// ±0.04 (~3°) based on local detail, so the snowline reads as an
	// organic frost edge rather than a sharp circle or a smooth ring band.
	float polar_lat = abs(v_local_norm.y) + (detail.r - 0.5) * 0.08;
	float polar_snow = aa_step(0.90, polar_lat);
	albedo = mix(albedo, col_snow, polar_snow);

	// 5. Steep cliffs read as rock regardless of altitude.
	float slope = abs(v_steepness);
	float cliff_mask = 1.0 - smoothstep(0.3, 0.65, slope);
	vec3 cliff_col = mix(col_rock, col_forest, smoothstep(0.3, 0.65, slope));
	albedo = mix(albedo, cliff_col, cliff_mask * (1.0 - t_snow));

	albedo *= detail_level;

	// CLOUD SHADOWS — DEBUG: temporarily disabled while diagnosing
	// rectangular missing-chunk artifacts. Re-enable once root cause is
	// confirmed (suspect this code may have triggered a shader-compile
	// failure on some chunks, falling back to default white material).
	// float cloud_t = TIME * 0.015;
	// float cloud_d = cloud_density_at(v_local_norm, cloud_t);
	// float cloud_shadow = smoothstep(cloud_thresh_lo, cloud_thresh_hi, cloud_d) * cloud_strength;
	// albedo *= mix(1.0, 0.55, cloud_shadow);

	ALBEDO = albedo;
	ROUGHNESS = 0.92;
	SPECULAR = 0.05;
}

void light() {
	float l_level = dot(NORMAL, LIGHT);
	float t2 = aa_step(0.20, l_level);
	float t1 = aa_step(0.60, l_level);
	vec3 shadow_col = ALBEDO * 0.55;
	vec3 mid_col    = ALBEDO * 0.78;
	vec3 final_col  = mix(shadow_col, mid_col, t2);
	final_col = mix(final_col, ALBEDO, t1);
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR * ATTENUATION;
}
