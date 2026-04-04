shader_type spatial;
render_mode cull_front, unshaded;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float outline_width : hint_range(0.0, 10.0) = 1.2;

void vertex() {
	// ACE INK-LINE PRECISION (MultiMesh Hardened)
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float dist = length(view_pos.xyz);
	
	// MULTIMESH SCALE DETECTION: 
	// The MODEL_MATRIX in MultiMeshInstance and individual MeshInstance behaves differently.
	// We extract the uniform scale factor by checking the magnitude of the basis.
	float obj_scale = length(MODEL_MATRIX[0].xyz);
	
	// If obj_scale is 1.0 (typical in MultiMesh for the MMI node itself 
	// while instances have their own transform), we rely on VERTEX range.
	// But in Godot 4, the MODELVIEW_MATRIX contains the instance scale.
	vec3 basis_x = vec3(MODELVIEW_MATRIX[0][0], MODELVIEW_MATRIX[0][1], MODELVIEW_MATRIX[0][2]);
	obj_scale = length(basis_x) / length( INV_VIEW_MATRIX[0].xyz );
	
	// PERSPECTIVE CONSTANT (1.2px)
	float growth = (outline_width * 0.001) * dist / obj_scale;
	growth = clamp(growth, 0.002 / obj_scale, 2.0 / obj_scale);
	
	VERTEX += NORMAL * growth;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
