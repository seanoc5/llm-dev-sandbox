Fix issue #89. Title: Modulith step-15: activate ModularityTests as failing check on master. Details: Final step of the Modulith adoption sequence (per [docs/architecture/modules.md](../blob/master/docs/architecture/modules.md#migration-sequence)).

## Scope
- Promote `ModulithVerificationTest` from "green snapshot" to **mandatory CI gate**
- Any cross-module violation fails the build
- Update CI workflow if needed (currently fast tests only on master per PR #67)
- Document the rule in CLAUDE.md / module README

## Acceptance
- Master is clean (no cross-module violations)
- A deliberately-introduced violation breaks CI
- Developer docs explain how to interpret + fix Modulith failures

## Depends on
Steps 4–14 (all carve-outs landed)