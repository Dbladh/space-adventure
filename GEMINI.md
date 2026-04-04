# GEMINI Project Mandates: Project Octo-Loot

This project follows a strict set of rules for its procedural, low-poly (No Man's Sky/Superhot-style) looter shooter architecture.

## 1. Determinism
- **Master Seed**: Every generation call must be deterministic based on a 64-bit integer.
- **Hierarchical Seeding**: Seeds must cascade from the Galaxy -> Planet -> Moon -> Weapon.
- **Precision**: 64-bit float precision must be prioritized for all spatial calculations to avoid "far-field" jitter in astronomical scales.
- **Reproducibility**: Given the same master seed, the entire universe and every item in it must remain perfectly consistent across sessions.

## 2. Aesthetics (Superhot / Low-Poly)
- **Low-Poly**: All 3D meshes should prioritize minimalist geometry. No high-detail sculpts.
- **Flat Shading**: Every mesh must use flat shading (faceted appearance). 
    - **Constraint**: `SurfaceTool.generate_normals(false)` or manual face-normal calculation is MANDATORY.
- **Universal Palette**:
    - **Environment**: Stark White (#FFFFFF), Concrete Grey (#888888).
    - **Enemies**: Crimson Red (#FF0000).
    - **Loot/Interactors**: Deep Charcoal (#1A1A1A).
- **VFX**: Minimalist, blocky, or pixelated.

## 3. Scale & Astronomy
- **Galaxy Registry**: The galaxy is defined by exactly 8 planets.
- **Coordinate System**: The Galaxy coordinate system is deterministic and stored in `GalaxyRegistry.gd`.

## 4. Agent Personas

### The Architect (Lead)
- **Role**: Oversees 64-bit universal seeding, Galaxy Registry, and global project settings.
- **Objective**: Ensure structural integrity and deterministic universe state.

### The Proceduralist
- **Role**: Master of `FastNoiseLite`, `SurfaceTool`, and `ArrayMesh`.
- **Objective**: Generating flat-shaded planetary terrain and modular geometry.

### The Gunsmith
- **Role**: System designer for modular "Composition over Inheritance" loot.
- **Objective**: The `WeaponPart` Resource system and `LootFactory` assembly math.

## 5. Development Instructions
- **Composition over Inheritance**: Use Component nodes (e.g., `MeshComponent`, `StatComponent`) instead of base classes.
- **Static Typing**: All GDScript must use static typing (e.g., `var value: float = 0.0`).
- **Signal-Based Communication**: Use Signals for inter-node communication.
- **Educational Commenting**: Every piece of code must include detailed, explicit comments explaining why a particular logic is used and what each section does.
