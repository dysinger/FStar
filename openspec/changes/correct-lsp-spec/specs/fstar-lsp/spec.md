# F* Language Server Protocol Specification — Delta

> Change: correct-lsp-spec
> Base spec: openspec/specs/fstar-lsp/spec.md

---

## MODIFIED Requirements

### Requirement: LSP Transport Layer

**ID**: REQ-LSP-001
**Priority**: P1

The LSP server SHALL implement the standard LSP transport layer over stdin/stdout using Content-Length header framing per the LSP 3.17 specification. Messages SHALL be encoded as UTF-8 JSON per JSON-RPC 2.0.

**Implementation note**: The existing IDE subsystem (`FStarC.Interactive.Ide`) uses line-delimited JSON via `Util.read_line` and `write_json` (which appends `\n`). The LSP server MUST use a different transport — `Util.nread` (exact-byte reading) for the message body and Content-Length headers for framing. Both `Util.read_line` and `Util.nread` are available on `stream_reader`, so no new FFI is needed. The existing `Util.open_stdin` creates the `stream_reader`.

#### Scenario: Read a valid LSP message

- **GIVEN** a client sends `Content-Length: 42\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize",...}`
- **WHEN** the LSP server reads from stdin
- **THEN** it SHALL parse the Content-Length header using line reading, then read exactly 42 bytes of JSON via `Util.nread`, and dispatch the message

#### Scenario: Write an LSP response

- **GIVEN** the server has a JSON response of 128 bytes
- **WHEN** the server writes to stdout
- **THEN** it SHALL emit `Content-Length: 128\r\n\r\n` followed by the JSON body

#### Scenario: Read multiple messages in a stream

- **GIVEN** two LSP messages arrive back-to-back on stdin: message A (64 bytes) and message B (32 bytes)
- **WHEN** the server reads
- **THEN** it SHALL parse message A completely, then message B, without leftover bytes corrupting either parse

#### Scenario: Malformed Content-Length header

- **GIVEN** input that does not start with `Content-Length: <digits>\r\n`
- **WHEN** the server reads
- **THEN** it SHALL log an error and exit with code 1 (parse error per JSON-RPC 2.0)

---

### Requirement: LSP Capability Declaration

**ID**: REQ-LSP-003
**Priority**: P1

The server SHALL declare its capabilities accurately in the `InitializeResult`. It SHALL NOT advertise capabilities it does not implement.

#### Scenario: Capability response includes all supported features

- **GIVEN** an `initialize` request
- **WHEN** the server responds
- **THEN** the `capabilities` SHALL include:
  - `textDocumentSync`: `{ "openClose": true, "change": 2, "save": true }` (Incremental sync — full re-check each time, see REQ-LSP-004)
  - `completionProvider`: `{ "triggerCharacters": [".", ":", " "] }`
  - `hoverProvider`: `true`
  - `definitionProvider`: `true`
  - `referencesProvider`: `true` (best-effort, single-module, see REQ-LSP-009)
  - `documentFormattingProvider`: `true`
  - `documentSymbolProvider`: `true`
  - `workspaceSymbolProvider`: `true` (best-effort, see REQ-LSP-013)
  - `executeCommandProvider`: `{ "commands": ["fstar.restartSolver"] }`

- **AND** the following capabilities SHALL NOT be advertised in v0.1.0 (deferred to v0.2.0):
  - `semanticTokensProvider` — no token classification in IDE backend
  - `foldingRangeProvider` — no folding range computation in IDE backend

---

### Requirement: Text Document Synchronization

**ID**: REQ-LSP-004
**Priority**: P1

The server SHALL support incremental text document synchronization via `textDocument/didOpen`, `textDocument/didChange`, and `textDocument/didClose`.

**Implementation note**: The IDE subsystem (`FStarC.Interactive.Ide.Types`) defines `grepl_state` with `grepl_repls: PSMap.t repl_state` — a map from file paths to `repl_state` instances. This multi-document infrastructure already exists. The LSP server SHALL maintain one `repl_state` per open document in its document store, creating/removing entries on didOpen/didClose. Each `repl_state` gets its own IDE environment, dependency stack, and completion table.

#### Scenario: didOpen — open a file

- **GIVEN** a client sends `textDocument/didOpen` with URI `file:///path/to/Module.fst`, languageId `fstar`, and full text
- **WHEN** the server processes it
- **THEN** the server SHALL register the document in its document store (map URI → `repl_state`)
- **AND** the server SHALL initiate a full-buffer check of the document using the F* IDE subsystem (`FullBuffer` query with kind `Full`)
- **AND** the server SHALL publish diagnostics (errors/warnings) from the check

#### Scenario: didChange — incremental edit

- **GIVEN** an open document `Module.fst`
- **WHEN** a client sends `textDocument/didChange` with a range-based text edit
- **THEN** the server SHALL apply the edit to its document store
- **AND** the server SHALL initiate a full-buffer re-check (since F* IDE does not support per-fragment diffing)

#### Scenario: didChange — full sync fallback

- **GIVEN** a client using full-document sync (`change: 1`)
- **WHEN** a client sends `textDocument/didChange` with full document text
- **THEN** the server SHALL replace the document content and initiate a re-check

#### Scenario: didClose — close a file

- **GIVEN** an open document `Module.fst`
- **WHEN** a client sends `textDocument/didClose`
- **THEN** the server SHALL remove the document from its store
- **AND** the server SHALL publish an empty diagnostic list to clear any stale markers

#### Scenario: didSave — save notification

- **GIVEN** an open document `Module.fst`
- **WHEN** a client sends `textDocument/didSave`
- **THEN** the server SHALL re-check the document and publish updated diagnostics

---

### Requirement: Find References

**ID**: REQ-LSP-009
**Priority**: P2

The server SHALL support finding references to a symbol via `textDocument/references`.

**Implementation note**: The IDE `Search` query searches the current module's completion table and environment for symbol occurrences. Cross-file reference finding is best-effort — it depends on which modules are loaded in the current `repl_state`'s environment. Full workspace reference search requires loading all project files, which is deferred to v0.2.0.

#### Scenario: Find references of a function

- **GIVEN** a symbol `helper` used in the current module
- **WHEN** a client sends `textDocument/references` at a usage of `helper`
- **THEN** the server SHALL map to an F* IDE `Search` query for the symbol
- **AND** the server SHALL return a list of `Location` objects, one per usage site found in the current module's environment

#### Scenario: Find references including declaration

- **GIVEN** a request with `context.includeDeclaration: true`
- **WHEN** references are computed
- **THEN** the result SHALL include the declaration site as well as all usage sites

#### Scenario: No references found

- **GIVEN** a symbol used only at its definition site
- **WHEN** references are requested
- **THEN** the server SHALL return an empty array (or array containing only the declaration if `includeDeclaration` is true)

---

### Requirement: Workspace Symbol Search

**ID**: REQ-LSP-013
**Priority**: P2

The server SHALL support workspace-wide symbol search via `workspace/symbol`.

**Implementation note**: The IDE `CompletionTable` maintains a symbol table for the current module. Workspace search is best-effort — it searches the symbols of all currently-open modules (those with active `repl_state` entries). Full workspace search across unopened files is deferred to v0.2.0.

#### Scenario: Search for a symbol by name

- **GIVEN** one or more modules are open
- **WHEN** a client sends `workspace/symbol` with query `map`
- **THEN** the server SHALL search known symbols from all open modules' completion tables
- **AND** the server SHALL return a list of `SymbolInformation` objects with `name`, `kind`, `location`

#### Scenario: Empty search results

- **GIVEN** a query that matches no symbols
- **WHEN** workspace/symbol is requested
- **THEN** the server SHALL return an empty array

---

### Requirement: Progress Reporting

**ID**: REQ-LSP-015
**Priority**: P2

The server SHALL report long-running operations via LSP progress notifications.

**Implementation note**: The IDE `Incremental` module supports `Callback` queries that fire during full-buffer processing. Specifically, `push_decl` inserts `Callback (FragmentStarted d)` before each declaration push, and `inspect_repl_stack` fires `FragmentSuccess`/`FragmentError` callbacks. The LSP server SHALL hook into these callbacks via `write_full_buffer_fragment_progress` to send `$/progress` notifications. Each fragment's progress SHALL be reported using a unique progress token scoped to the check operation.

#### Scenario: Typechecking progress

- **GIVEN** a large module that takes more than 1 second to typecheck
- **WHEN** typechecking starts
- **THEN** the server SHALL send a `$/progress` notification with `kind: "begin"`, a unique token, and `title: "Typechecking Module.fst"`
- **AND** when typechecking completes, the server SHALL send `$/progress` with `kind: "end"`

#### Scenario: Incremental check progress

- **GIVEN** an incremental full-buffer check reporting fragment progress via `FragmentStarted` callbacks
- **WHEN** each fragment is processed
- **THEN** the server MAY report progress via `$/progress` with `kind: "report"` and a percentage or message

---

### Requirement: Cancel Request

**ID**: REQ-LSP-016
**Priority**: P2

The server SHALL support cancellation of in-progress requests via `$/cancelRequest`.

**Implementation note**: The IDE defines `Cancel of option position` query. When position is `Some`, it cancels pushes at/beyond that position. When `None`, it cancels all pending queries. The F* `repl_state` type includes `repl_buffered_input_queries: list query` — the Cancel query drains this buffer. The LSP server SHALL use the IDE Cancel mechanism: LSP `$/cancelRequest` provides a request ID, which the server maps to the corresponding IDE query's `qid` and issues a Cancel.

#### Scenario: Cancel a long typecheck

- **GIVEN** a long-running `textDocument/didChange` that triggers typechecking
- **WHEN** the client sends `$/cancelRequest` with the request ID
- **THEN** the server SHALL cancel the underlying F* IDE query using the `Cancel` mechanism
- **AND** the server SHALL respond to the original request with JSON-RPC error `-32800` (RequestCancelled)

---

### Requirement: Entry Point — `--lsp` Flag on `fstar.exe`

**ID**: REQ-LSP-020
**Priority**: P1

The F* compiler SHALL support a new `--lsp` command-line flag on `fstar.exe` to start the LSP server. This flag SHALL follow the same pattern as the existing `--ide` flag.

**Implementation note**: Line numbers verified against current source on `t/openspec` branch.

The following files SHALL be modified:

1. **`src/basic/FStarC.Errors.Codes.fsti`** — Add `| Error_FlagConflict` to the `error_code` discriminated union (before `type error_setting`)
2. **`src/basic/FStarC.Errors.Codes.fst`** — Add `Error_FlagConflict, CAlwaysError, 362;` to `default_settings`
3. **`src/basic/FStarC.Options.fst`** — Add option declaration (follow `--ide` pattern on line 1034):
   - Option declaration: `(noshort, "lsp", Const (Bool true), text "...")`
   - Accessor: `let get_lsp () = lookup_opt "lsp" as_bool`
   - Public API: `let lsp () = get_lsp ()`
4. **`src/basic/FStarC.Options.fsti`** — Export `val lsp : unit -> ML bool` (follow `val ide` pattern)
5. **`src/fstar/FStarC.Main.fst`** — Add LSP entry point before the `--ide` check:
   - If `Options.lsp()` and `Options.interactive()`: raise `Error_FlagConflict`
   - If `Options.lsp()`: call `FStarC.LSP.Server.start ()`
   - Add `open FStarC.LSP.Server` import

#### Scenario: Start LSP server via `fstar.exe --lsp`

- **GIVEN** a shell command `fstar.exe --lsp`
- **WHEN** the compiler starts
- **THEN** it SHALL enter LSP mode, reading LSP messages from stdin
- **AND** it SHALL NOT require a filename argument (unlike `--ide`)

#### Scenario: --lsp vs --ide mutual exclusion

- **GIVEN** the compiler
- **WHEN** both `--lsp` and `--ide` are specified
- **THEN** the compiler SHALL report an error and exit with code 1

#### Scenario: --lsp with compiler flags

- **GIVEN** `fstar.exe --lsp --include ./src --z3rlimit 50`
- **WHEN** the server starts
- **THEN** it SHALL use the include path for module resolution and pass the Z3 resource limit to the solver
- **AND** standard compiler flags (`--include`, `--z3rlimit`, `--cache_dir`, `--trace_error`, etc.) SHALL work normally

---

### Requirement: Proofs for Provable Components

**ID**: REQ-LSP-024
**Priority**: P2

The LSP server SHALL include proofs for the Transport module's Content-Length framing, where bugs in framing would cause protocol failures.

**Scope for v0.1.0**: Only the Transport module's `lemma_framing_roundtrip` is required. Lemmas for Messages (`lemma_uri_filepath_roundtrip`, `lemma_response_preserves_id`) and Translator (`lemma_dispatch_known_methods`) are deferred to v0.2.0. The codebase SHALL be designed with proofs in mind — pure functions separated from effectful I/O, data invariants made explicit via refinements. Effectful wrappers use `ML` with `admit()` at the I/O boundary, marked with `// Proof boundary: I/O` comments.

#### Target: Content-Length Framing Roundtrip (Transport module)

```fstar
/// Framing roundtrip: any valid JSON string survives encode→decode unchanged
let lemma_framing_roundtrip (msg: string{String.length msg > 0}) : Lemma
  (ensures decode_message (encode_message msg) == Some msg)
  = ()
```

Implementation approach:
- `encode_message : string -> Tot string` — pure, prepends Content-Length header
- `decode_message : string -> Tot (option string)` — pure, parses header and extracts body
- `read_message : ML (option string)` — effectful, reads stdin via `read_line` + `nread`; calls `decode_message`
- `write_message : string -> ML unit` — effectful, calls `encode_message`, writes stdout

#### Scenario: Proofs are checkable by the compiler

- **GIVEN** the LSP server source code
- **WHEN** the F* compiler typechecks it
- **THEN** `lemma_framing_roundtrip` in `Transport` SHALL verify (green)
- **AND** modules that wrap I/O (`Server`, `Translator`) SHALL use `ML` effect and `admit()` at I/O boundaries, marked with explicit `// Proof boundary: I/O` comments

#### Scenario: Proofs don't block extraction

- **GIVEN** proof annotations in the code
- **WHEN** the compiler extracts to OCaml
- **THEN** all `Lemma` types SHALL erase to unit at extraction time
- **AND** the extracted OCaml code SHALL be identical to what would be produced without proofs

---

## ADDED Requirements

### Requirement: LSP Method → IDE Query Mapping

**ID**: REQ-LSP-025
**Priority**: P1

The Translator module SHALL map LSP methods to F* IDE queries according to the following table. This mapping SHALL be exhaustive for all supported methods.

| LSP Method | IDE Query | IDE Types Reference |
|---|---|---|
| `textDocument/didOpen` | `FullBuffer (code, Full, with_symbols=false)` | `FStarC.Interactive.Incremental.run_full_buffer` |
| `textDocument/didChange` | `FullBuffer (code, Full, with_symbols=false)` | Same as didOpen (full re-check) |
| `textDocument/didSave` | `FullBuffer (code, Full, with_symbols=false)` | Same as didOpen |
| `textDocument/completion` | `AutoComplete (prefix, context)` | `AutoComplete` in `Ide.Types.query'` |
| `textDocument/hover` | `Lookup (symbol, LKSymbolOnly, Some pos, ["type"; "documentation"], None)` | `Lookup` with `LKSymbolOnly` context |
| `textDocument/definition` | `Lookup (symbol, LKCode, Some pos, ["definition"], None)` | `Lookup` with `LKCode` context |
| `textDocument/references` | `Search (terms)` | `Search` query |
| `textDocument/formatting` | `Format (code)` | `Format` query; calls `Incremental.format_code` |
| `textDocument/documentSymbol` | N/A — extracted from `dump_symbols` output | `dump_symbols_for_lid` in `Incremental` |
| `workspace/symbol` | N/A — searches `CompletionTable` across open repls | `CompletionTable` module |
| `workspace/executeCommand "fstar.restartSolver"` | `RestartSolver` | `RestartSolver` query |
| `$/cancelRequest` | `Cancel (Some position)` or `Cancel None` | `Cancel` query; drains `repl_buffered_input_queries` |

**Position conversion**: The Translator SHALL convert LSP positions (0-based lines) to F* IDE positions (1-based lines). Column numbers remain 0-based in both systems.

**Diagnostics conversion**: The Translator SHALL map `FStarC.Errors.issue` returned from IDE queries to LSP `Diagnostic` objects. The IDE already provides `json_of_issue` which extracts level, message, range, and issue number. The Translator SHALL convert these to LSP's `range`, `severity`, `message`, `source`, and `relatedInformation` fields.

#### Scenario: Completion request mapping

- **GIVEN** an LSP `textDocument/completion` request at position line 5, column 10
- **WHEN** the Translator processes it
- **THEN** it SHALL extract the identifier prefix at the cursor position from the document text
- **AND** it SHALL construct an `AutoComplete` IDE query with the prefix and context `CKCode`
- **AND** it SHALL convert the resulting `CompletionTable.completion_result` entries to LSP `CompletionItem` objects

#### Scenario: Hover request mapping

- **GIVEN** an LSP `textDocument/hover` request at position line 5, column 10
- **WHEN** the Translator processes it
- **THEN** it SHALL extract the identifier at the cursor position from the document text
- **AND** it SHALL construct a `Lookup` IDE query with context `LKSymbolOnly` and features `["type"; "documentation"]`
- **AND** it SHALL convert the IDE lookup result to an LSP `Hover` with MarkupContent

#### Scenario: Diagnostics mapping

- **GIVEN** an IDE `issue` with level `EError`, message `"Type mismatch"`, and use range at line 5
- **WHEN** the Translator converts it to an LSP Diagnostic
- **THEN** it SHALL produce a Diagnostic with `severity: 1` (Error), `message: "Type mismatch"`, and `range` spanning the use range
- **AND** if the issue has a definition range different from the use range, it SHALL be included as `relatedInformation`

---

### Requirement: Leverage Existing `grepl_state` for Multi-Document Support

**ID**: REQ-LSP-026
**Priority**: P1

The LSP server SHALL use the existing `grepl_state` infrastructure (`FStarC.Interactive.Ide.Types`) to manage multiple open documents. Each open document SHALL have its own `repl_state` with independent environment, dependency stack, and completion table.

**Implementation note**: The `grepl_state` type is already defined:

```fstar
type grepl_state = { grepl_repls: PSMap.t repl_state; grepl_stdin: stream_reader }
```

The LSP server SHALL:
1. Create a `grepl_state` at startup with `grepl_stdin` from `Util.open_stdin ()`
2. On `textDocument/didOpen`: extract filepath from URI, build a new `repl_state` via `build_initial_repl_state filepath`, insert into `grepl_repls`
3. On `textDocument/didClose`: remove the entry from `grepl_repls`
4. Route feature requests to the `repl_state` corresponding to the document URI in the request

#### Scenario: Two open documents

- **GIVEN** documents `A.fst` and `B.fst` are both open via didOpen
- **WHEN** a completion request arrives for `A.fst`
- **THEN** the server SHALL route to `A.fst`'s `repl_state`
- **AND** `B.fst`'s state SHALL be unaffected

#### Scenario: Close one of two documents

- **GIVEN** documents `A.fst` and `B.fst` are both open
- **WHEN** `textDocument/didClose` arrives for `A.fst`
- **THEN** the server SHALL remove `A.fst` from `grepl_repls`
- **AND** the server SHALL publish empty diagnostics for `A.fst`
- **AND** `B.fst`'s state SHALL remain active and functional

---

### Requirement: Implementation Language

**ID**: REQ-LSP-023
**Priority**: P1

The LSP server SHALL be implemented in F* using the same F* dialect (ML effect, monadic style) as the rest of the compiler codebase. New modules SHALL be added to the existing build system.

#### Scenario: New module in the compiler source

- **GIVEN** the compiler source tree
- **WHEN** the LSP server is implemented
- **THEN** new files SHALL be added under `src/lsp/`:
  - `FStarC.LSP.Server.fst` / `.fsti` — main server loop, lifecycle, method dispatch, document store
  - `FStarC.LSP.Transport.fst` / `.fsti` — Content-Length framing (target: PROOF for pure functions)
  - `FStarC.LSP.Messages.fst` / `.fsti` — LSP type definitions, JSON serialization/deserialization
  - `FStarC.LSP.Translator.fst` / `.fsti` — LSP ↔ IDE translation layer
- **AND** `FStarC.Main.fst` SHALL be updated to add the `--lsp` flag and entry point
- **AND** `FStarC.Options.fst` / `.fsti` SHALL be updated to declare the `--lsp` flag
- **AND** `FStarC.Errors.Codes.fst` / `.fsti` SHALL be updated to add `Error_FlagConflict`
- **AND** the build system (Makefile or dune) SHALL be updated to compile new `src/lsp/` files

---
