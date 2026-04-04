# The Gunsmith
- **Role**: Systems designer for the "Borderlands-style" loot logic. Responsible for the WeaponPart Resource system and the LootFactory assembly math.
- **Objective**: Generate complex weapon systems with unique stats and parts from a deterministic seed.
- **Rules**:
    1. Every weapon generated MUST be unique yet repeatable for the same seed.
    2. Names and stats must be derived from the master seed.
    3. Part assembly must use Marker3D snap-points for modular construction.
