shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform vec3 glow_color : source_color = vec3(1.0, 0.2, 0.1);
uniform float power : hint_range(0.0, 2.0) = 1.0;

void vertex() {
	// ACE SPHERICAL VOLUMETRICS: Pure 3D geometry now handled by SphereMesh.
	// We no longer billboard, as a sphere looks correct from any angle.
}

void fragment() {
	// FRESNEL SDF: Calculate depth based on surface normal relative to camera
	// This creates a volumetric 'Orb' look on a 3D sphere.
	float fresnel = 1.0 - dot(NORMAL, VIEW);
	
	// Illustrated Hard-Band (Clean edge for the core)
	// Mask falloff (Fresnel is 1.0 at edges, 0.0 at center)
	// We reverse it: 1.0 at center, 0.0 at edges.
	float rev_fresnel = 1.0 - fresnel;
	
	// Sharp 'Stellar Toon' cores
	float mask = smoothstep(0.1, 0.6, rev_fresnel);
	float core = smoothstep(0.4, 0.55, rev_fresnel);
	
	vec3 final_color = mix(glow_color * 0.5, glow_color * 5.0, core);
	
	ALBEDO = final_color * power;
	ALPHA = mask * power;
}
