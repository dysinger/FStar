# Change Proposal: correct-lsp-spec

## Summary

Correct the F* LSP specification to match what is actually buildable with the existing IDE subsystem (`FStarC.Interactive.Ide`), scoping v0.1.0 to features the IDE backend already supports.

## Motivation

The current spec (`openspec/specs/fstar-lsp/spec.md`) was written aspirationally without deep investigation of the IDE subsystem. Investigation of all 3,398 lines of IDE source (`src/interactive/`) revealed multiple gaps:

1. **Transport**: IDE uses line-delimited JSON (`read_line`/`write_json` with `\n`), not Content-Length framing. The spec correctly requires Content-Length for LSP compliance, but didn't document that `Util.nread` exists for exact-byte reading.
2. **Protocol**: IDE uses a custom query/response protocol (`kind: "response"`, `query-id`, `status`, `response`), not JSON-RPC 2.0. A complete translator is needed.
3. **Features**: Several spec'd features (semantic tokens, folding ranges) have zero IDE backend support. Others (references, workspace symbols) are best-effort given the IDE's single-file design.
4. **Proofs**: The spec demands 4 lemmas but the IDE itself uses `ML` effect with zero proofs. Transport roundtrip is the only realistic lemma for v0.1.0.
5. **Multi-document**: The spec implies full multi-file support but doesn't mention that `grepl_state` (multi-repl map) already exists in the IDE.

## Scope

### In scope (v0.1.0 corrections)
- Demote semantic tokens (REQ-LSP-011) to v0.2.0 — no IDE backend exists
- Demote folding ranges (REQ-LSP-014) to v0.2.0 — no IDE backend exists
- Scope proofs (REQ-LSP-024) to Transport roundtrip only; rest deferred
- Remove `semanticTokensProvider` and `foldingRangeProvider` from capabilities (REQ-LSP-003)
- Add `Util.nread` documentation to Transport section
- Add `grepl_state` documentation to text sync section
- Add LSP method → IDE query mapping table to Translator section
- Mark references (REQ-LSP-009) as best-effort (IDE Search is single-module)
- Mark workspace symbols (REQ-LSP-013) as best-effort
- Verify and update line number references in REQ-LSP-020
- Add `Cancellable` type for Cancel request support
- Clarify that `Callback` queries exist for progress reporting hook

### Out of scope
- Implementation (separate change)
- Semantic tokens specification (deferred to v0.2.0)
- Folding ranges specification (deferred to v0.2.0)
- Full proof suite (deferred to v0.2.0)
- Code actions, rename, signature help (already marked out of scope)

## Risks

- None. This is a specification-only change that aligns the spec with reality.

## Dependencies

- None. The IDE subsystem is already analyzed.
