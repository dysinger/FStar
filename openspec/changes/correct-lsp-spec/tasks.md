# Implementation Tasks: correct-lsp-spec

## Phase 1: Spec Corrections

- [x] 1.1 Update REQ-LSP-001 (Transport): Add `Util.nread` documentation, clarify line-delimited vs Content-Length gap
- [x] 1.2 Update REQ-LSP-003 (Capabilities): Remove `semanticTokensProvider` and `foldingRangeProvider` from v0.1.0
- [x] 1.3 Update REQ-LSP-004 (Text Sync): Add `grepl_state` documentation, multi-document design notes
- [x] 1.4 Update REQ-LSP-009 (References): Mark as best-effort, note single-module IDE Search limitation
- [x] 1.5 Demote REQ-LSP-011 (Semantic Tokens): Change priority P2→P3, add "deferred to v0.2.0" note
- [x] 1.6 Update REQ-LSP-013 (Workspace Symbols): Mark as best-effort, note open-modules-only limitation
- [x] 1.7 Demote REQ-LSP-014 (Folding Ranges): Change priority P3, add "deferred to v0.2.0" note
- [x] 1.8 Update REQ-LSP-015 (Progress): Add `Callback` query + `FragmentStarted`/`FragmentSuccess` documentation
- [x] 1.9 Update REQ-LSP-016 (Cancel): Add `repl_buffered_input_queries` drain mechanism documentation
- [x] 1.10 Update REQ-LSP-020 (Entry Point): Add `Error_FlagConflict` steps, verify line numbers against `t/openspec` branch
- [x] 1.11 Update REQ-LSP-024 (Proofs): Scope to Transport roundtrip only, defer Messages+Translator lemmas to v0.2.0
- [x] 1.12 Add REQ-LSP-025 (LSP Method → IDE Query Mapping): Exhaustive mapping table
- [x] 1.13 Add REQ-LSP-026 (Leverage grepl_state): Multi-document support design

## Phase 2: Base Spec Synchronization

- [x] 2.1 Apply all MODIFIED deltas to `openspec/specs/fstar-lsp/spec.md`
- [x] 2.2 Apply all ADDED requirements to `openspec/specs/fstar-lsp/spec.md`
- [x] 2.3 Add REMOVED section noting deferred features (semantic tokens, folding ranges)
- [x] 2.4 Update version: 0.1.0 → 0.2.0
- [x] 2.5 Update "Updated" date to 2026-05-02

## Phase 3: Validation

- [x] 3.1 Verify all REQ-IDs are contiguous (REQ-LSP-001 through REQ-LSP-026)
- [x] 3.2 Verify all requirements use SHALL/MUST/SHOULD keywords
- [x] 3.3 Verify each requirement has at least one scenario
- [x] 3.4 Verify scenarios use GIVEN/WHEN/THEN format (####)
- [x] 3.5 Verify no requirements conflict after delta application
- [x] 3.6 Verify Known Limitations section reflects v0.1.0 scope

## Verification

- [x] Run `openspec status --change "correct-lsp-spec"` to confirm all artifacts exist
- [x] Review diff between delta spec and base spec for consistency
- [x] Confirm all demoted features have clear "deferred to v0.2.0" markers
