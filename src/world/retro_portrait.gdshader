shader_type canvas_item;

// Same pipeline as retro_vfx.gdshader (pixelate + 8x8 Bayer dither + palette
// crush + shadow tint) but sampled from the bound TEXTURE instead of the
// screen back-buffer. Lets a TextureRect apply the retro look to itself
// without relying on hint_screen_texture — which breaks when multiple
// overlapping rects all try to sample the back buffer in one batch.

uniform float pixel_size : hint_range(1, 20) = 6.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.4;
uniform float saturation : hint_range(0.0, 3.0) = 1.6;
uniform float contrast : hint_range(0.0, 3.0) = 1.35;

float bayer8(ivec2 p) {
    int x = p.x % 8;
    int y = p.y % 8;
    const int m[64] = int[](
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21
    );
    return float(m[y * 8 + x]) / 64.0;
}

void fragment() {
    vec2 tex_size = vec2(textureSize(TEXTURE, 0));
    vec2 p_size = tex_size / pixel_size;
    vec2 snapped_uv = floor(UV * p_size) / p_size;

    vec4 src = texture(TEXTURE, snapped_uv);
    vec3 scene_col = src.rgb;

    scene_col = (scene_col - 0.5) * contrast + 0.5;

    float lum = dot(scene_col, vec3(0.299, 0.587, 0.114));
    scene_col = mix(vec3(lum), scene_col, saturation);

    ivec2 d_pos = ivec2(FRAGCOORD.xy / pixel_size);
    float d_val = bayer8(d_pos);

    float d_mask = (1.0 - abs(lum - 0.5) * 2.0) * dither_strength;
    scene_col += (d_val - 0.5) * d_mask;

    scene_col = floor(scene_col * 5.0 + 0.5) / 5.0;

    vec3 shadow_tint = vec3(0.1, 0.0, 0.2);
    scene_col = mix(shadow_tint, scene_col, smoothstep(-0.1, 0.4, lum));

    COLOR = vec4(scene_col, src.a);
}
