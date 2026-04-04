# SKILLS.md - Project Octo-Loot Capabilities

This document defines the core capabilities for the GEMINI agents in Project Octo-Loot.

## Skill: FlatMeshBuilder (The Proceduralist)
- **Objective**: Create low-poly ArrayMeshes without vertex smoothing.
- **Constraints**: 
    - Must use `SurfaceTool.generate_normals(false)` to force flat-shading.
    - Alternatively, manually calculate one normal per face triangle to ensure faceted surfaces.
    - All geometry must be minimalist and follow the "Superhot" low-poly style.

## Skill: SeedUnpacker (The Architect)
- **Objective**: Implement hierarchical 64-bit seed derivation.
- **Algorithm**:
    - **Master Seed** (64-bit) -> Unpacked into Galaxy, Planet, Moon, and Loot seeds.
    - Uses bit-masking and bit-shifting to ensure that modifying one part of the world (e.g., a moon) doesn't change other parts (e.g., a weapon on a different planet).
    - Ensures that 64-bit float precision is maintained during spatial coordinate calculations to prevent "jitter" at large distances.
