# Design: correct-lsp-spec

## Purpose

Correct the F* LSP specification to precisely describe what is buildable given the existing IDE subsystem's actual capabilities. This design documents the technical decisions made during the spec correction investigation.

---

## Investigation Summary

### What Exists (Verified)

| Component | File(s) | Lines | Capabilities |
|-----------|---------|-------|-------------|
| `FStarC.Interactive.Ide` | `src/interactive/FStarC.Interactive.Ide.fst` | 1,304 | Main loop, query dispatch, `validate_and_run_query` |
| `FStarC.Interactive.Ide.Types` | `src/interactive/FStarC.Interactive.Ide.Types.fst` + `.fsti` | 266 + 166 | `repl_state`, `grepl_state`, all query types, `json_of_issue` |
| `FStarC.Interactive.Incremental` | `src/interactive/FStarC.Interactive.Incremental.fst` + `.fsti` | 386 + 54 | `run_full_buffer`, `format_code`, `inspect_repl_stack` |
| `FStarC.Interactive.CompletionTable` | `src/interactive/FStarC.Interactive.CompletionTable.fst` + `.fsti` | 489 + 63 | Symbol table, completion search |
| `FStarC.Interactive.PushHelper` | `src/interactive/FStarC.Interactive.PushHelper.fst` + `.fsti` | 339 + 58 | Fragment push/validation |
| `FStarC.Interactive.QueryHelper` | `src/interactive/FStarC.Interactive.QueryHelper.fst` + `.fsti` | 104 + 39 | Query construction helpers |
| `FStarC.Interactive.JsonHelper` | `src/interactive/FStarC.Interactive.JsonHelper.fst` + `.fsti` | 66 + 43 | JSON parsing/printing helpers |
| `FStarC.Util` | `src/basic/FStarC.Util.fsti` | — | `open_stdin`, `read_line`, `nread` (exact-byte read) |

### What Does NOT Exist

- `src/lsp/` directory (no files)
- Content-Length framing code anywhere
- JSON-RPC 2.0 message types
- LSP message lifecycle (initialize/shutdown/exit)
- Any LSP ↔ IDE translation layer

---

## Key Technical Decisions

### Decision 1: Content-Length Transport via `Util.nread`

**Problem**: The IDE uses `Util.read_line` for line-delimited JSON. LSP requires Content-Length framing with exact-byte body reading.

**Solution**: `FStarC.Util` already exposes `nread : stream_reader -> int -> ML (option string)` — reads exactly N bytes. This is exactly what Content-Length framing needs. No new FFI required.

**Architecture**:
```
Transport module
├── encode_message : string -> Tot string
│   — Pure: prepend "Content-Length: N\r\n\r\n"
├── decode_message : string -> Tot (option string)
│   — Pure: parse header, extract N, extract N-byte body
├── read_message : ML (option string)
│   — Effectful: read_line for header, nread for body, call decode_message
├── write_message : string -> ML unit
│   — Effectful: call encode_message, write to stdout
└── lemma_framing_roundtrip : Lemma
    — Pure proof: encode_message then decode_message = Some original
```

### Decision 2: Multi-Document via `grepl_state`

**Problem**: The IDE is built around a single `repl_state`, but LSP is multi-document.

**Solution**: The IDE already defines `grepl_state`:
```fstar
type grepl_state = { grepl_repls: PSMap.t repl_state; grepl_stdin: stream_reader }
```

This is an existing but underused type. The LSP server shall:
1. Maintain a `grepl_state` as its global state
2. Insert `repl_state` entries on `didOpen` (keyed by filepath)
3. Remove entries on `didClose`
4. Route all method calls to the correct `repl_state` by URI → filepath

**Risk**: The IDE's `interactive_mode'` and `build_initial_repl_state` assume a single file context. Some features (like `Options.add_verify_module`) may need adjustment for multi-file operation. However, the `grepl_state` infrastructure exists, so this is an integration challenge, not a design gap.

### Decision 3: Demote Semantic Tokens + Folding Ranges

**Problem**: REQ-LSP-011 (semantic tokens) and REQ-LSP-014 (folding ranges) were P2 requirements with no IDE backend support.

**Rationale**: 
- Semantic tokens require AST node classification (`FStarC.Syntax.Syntax` or `FStarC.Parser.AST`) — ~200+ node types. This is a significant independent feature.
- Folding ranges require AST structure analysis for block boundaries.
- Neither feature blocks the core LSP value proposition (diagnostics, completion, hover, go-to-definition).
- These can be added later when the LSP server is stable.

### Decision 4: Proof Scope — Transport Only

**Problem**: REQ-LSP-024 demanded 4 lemmas across Transport, Messages, and Translator, but the IDE itself uses zero proofs (all `ML` effect).

**Rationale**:
- Transport framing is the highest-risk component — a framing bug corrupts the entire protocol.
- Messages and Translator lemmas are "nice to have" — URL roundtrip and dispatch completeness are less critical.
- The `Lemma` type erases to `unit` at extraction, so proofs add zero runtime cost.
- Keeping v0.1.0 proof-scoped to Transport means faster delivery of a working server.

### Decision 5: LSP Method → IDE Query Mapping Table

**Problem**: The original spec mentions a Translator but never specifies which LSP method maps to which IDE query.

**Solution**: Added REQ-LSP-025 with an exhaustive mapping table. This was extracted directly from `Ide.Types.query'` type definition and verified against actual IDE query semantics.

---

## Corrected Architecture

```
Editor/Agent (LSP client)
    │
    │ LSP messages (Content-Length framed JSON over stdin/stdout)
    │
    ▼
┌──────────────────────────────────────┐
│  FStarC.LSP.Server                    │
│  ┌──────────────────────────────────┐ │
│  │ Document Store (grepl_state)      │ │  ← grepl_repls: PSMap.t repl_state
│  │ ┌──────┐ ┌──────┐ ┌──────┐      │ │
│  │ │A.fst │ │B.fst │ │C.fst │ ...  │ │
│  │ └──────┘ └──────┘ └──────┘      │ │
│  ├──────────────────────────────────┤ │
│  │ Lifecycle State Machine           │ │
│  │ Uninitialized → Initialized →    │ │
│  │   Running → Shutdown              │ │
│  ├──────────────────────────────────┤ │
│  │ Method Dispatch                   │ │
│  │ initialize, textDocument/*, ...   │ │
│  └──────────┬───────────────────────┘ │
│             │                          │
│  ┌──────────▼───────────────────────┐ │
│  │ FStarC.LSP.Translator             │ │
│  │ LSP ↔ IDE: position, query,      │ │
│  │ response, diagnostic conversion   │ │
│  └──────────┬───────────────────────┘ │
│             │ IDE queries/responses    │
│  ┌──────────▼───────────────────────┐ │
│  │ FStarC.LSP.Transport              │ │
│  │ Content-Length encode/decode      │ │
│  │ stdin nread / stdout write        │ │
│  └──────────┬───────────────────────┘ │
│             │                          │
│  ┌──────────▼───────────────────────┐ │
│  │ FStarC.Interactive.Ide             │ │
│  │ (Existing IDE subsystem)           │ │
│  │ validate_and_run_query,            │ │
│  │ run_full_buffer, etc.              │ │
│  └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```

---

## Module Dependency Graph

```
FStarC.Util (open_stdin, read_line, nread, print_raw)
    ↓
FStarC.LSP.Transport (framing + I/O)
    ↓
FStarC.Json + FStarC.LSP.Transport
    ↓
FStarC.LSP.Messages (JSON-RPC types, serialization)
    ↓                                    ↓
FStarC.LSP.Translator              FStarC.LSP.Messages
(LSP ↔ IDE)                        (types for Server)
    ↓                                    ↓
    └──────────── FStarC.LSP.Server ─────┘
    (main loop, lifecycle, dispatch, document store)
         ↓
    FStarC.Main.fst (--lsp flag, call Server.start)
```

---

## Feature Support Matrix (v0.1.0)

| LSP Method | IDE Query | Status | Risk |
|---|---|---|---|
| `initialize` | N/A (server lifecycles) | ✅ Full support | Low |
| `initialized` | N/A (notification) | ✅ Full support | Low |
| `shutdown` | N/A (server lifecycles) | ✅ Full support | Low |
| `exit` | N/A (server lifecycles) | ✅ Full support | Low |
| `textDocument/didOpen` | `FullBuffer(Full)` | ✅ Full support | Low |
| `textDocument/didChange` | `FullBuffer(Full)` | ✅ Full support | Low |
| `textDocument/didClose` | N/A (store management) | ✅ Full support | Low |
| `textDocument/didSave` | `FullBuffer(Full)` | ✅ Full support | Low |
| `textDocument/completion` | `AutoComplete` | ✅ Full support | Low |
| `textDocument/hover` | `Lookup(LKSymbolOnly)` | ✅ Full support | Low |
| `textDocument/definition` | `Lookup(LKCode)` | ✅ Full support | Low |
| `textDocument/references` | `Search` | ⚠️ Best-effort | Medium |
| `textDocument/formatting` | `Format` | ✅ Full support | Low |
| `textDocument/documentSymbol` | `dump_symbols` | ✅ Full support | Medium |
| `workspace/symbol` | `CompletionTable` | ⚠️ Best-effort | Medium |
| `workspace/executeCommand` | `RestartSolver` | ✅ Full support | Low |
| `$/cancelRequest` | `Cancel` | ✅ Full support | Medium |
| `$/progress` | `Callback(FragmentStarted)` | ✅ Full support | Medium |
| `textDocument/semanticTokens` | N/A | ❌ v0.2.0 | High |
| `textDocument/foldingRange` | N/A | ❌ v0.2.0 | High |
