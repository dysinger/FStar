# F* Language Server Protocol Specification
> Version: 0.1.0
> Updated: 2026-04-30

## Purpose

Add a Language Server Protocol (LSP) server to the F* compiler. The LSP server SHALL provide standard IDE features — diagnostics, completions, hover, go-to-definition, formatting, semantic tokens, and symbol search — to any LSP-compliant editor (VS Code, Emacs, Neovim, Helix, Zed) and to CLI agents. The LSP server SHALL reuse the existing F* interactive IDE subsystem (`FStarC.Interactive.Ide`) as its backend, translating LSP messages to F* IDE queries and IDE responses back to LSP responses and notifications.

## Background

F* currently provides a custom JSON-based IDE protocol via `--ide` mode. The protocol supports: push/pop of code fragments, full-buffer checking, autocomplete, symbol lookup, compute, search, code formatting, and diagnostics. It uses raw line-delimited JSON over stdin/stdout. This protocol is not LSP and requires editor-specific adapters.

LSP (Language Server Protocol, version 3.17) is the industry-standard protocol defined by Microsoft. It uses HTTP-like framing (Content-Length header) over stdin/stdout. Every major editor supports LSP natively or via plugins.

## Architecture

```
Editor/Agent (LSP client)
    │
    │ LSP messages (Content-Length framed JSON over stdin/stdout)
    │
    ▼
┌──────────────────────────┐
│  FStarC.LSP.Server        │  ◄── NEW: LSP transport layer + message dispatch
│  ┌──────────────────────┐ │
│  │ LSP ↔ IDE Translator │ │  ◄── NEW: maps LSP methods to IDE queries
│  └──────────┬───────────┘ │
│             │ IDE queries/responses (internal)
│  ┌──────────▼───────────┐ │
│  │ FStarC.Interactive.  │ │  ◄── EXISTING: IDE subsystem
│  │ Ide / Incremental /  │ │
│  │ CompletionTable      │ │
│  └──────────────────────┘ │
└──────────────────────────┘
```

The LSP server SHALL be a new module `FStarC.LSP.Server` that:
1. Reads LSP messages from stdin using Content-Length framing
2. Dispatches to handler functions for each LSP method
3. Translates LSP parameters to F* IDE queries where applicable
4. Translates IDE responses back to LSP responses
5. Sends LSP notifications (diagnostics, progress) asynchronously
6. Writes LSP messages to stdout using Content-Length framing

## Standards Reference

- **LSP 3.17 Specification**: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- **JSON-RPC 2.0**: LSP uses JSON-RPC 2.0 as its base protocol
- **F* IDE Protocol**: Existing custom protocol in `FStarC.Interactive.Ide`

---

## Requirements

### Requirement: LSP Transport Layer
**ID**: REQ-LSP-001
**Priority**: P1
The LSP server SHALL implement the standard LSP transport layer over stdin/stdout using Content-Length header framing per the LSP 3.17 specification. Messages SHALL be encoded as UTF-8 JSON per JSON-RPC 2.0.

#### Scenario: Read a valid LSP message
- **GIVEN** a client sends `Content-Length: 42\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize",...}`
- **WHEN** the LSP server reads from stdin
- **THEN** it SHALL parse the Content-Length, read exactly 42 bytes of JSON, and dispatch the message

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

### Requirement: LSP Lifecycle — Initialize and Shutdown
**ID**: REQ-LSP-002
**Priority**: P1
The LSP server SHALL support the standard LSP lifecycle: `initialize`, `initialized`, `shutdown`, and `exit`.

#### Scenario: Successful initialization
- **GIVEN** a client sends an `initialize` request with `textDocumentSync: 2` (Incremental) and requested capabilities
- **WHEN** the server processes it
- **THEN** the server SHALL respond with `InitializeResult` containing `serverInfo` (name: "fstar", version from `version.txt`), `capabilities` (see REQ-LSP-003), and `serverCapabilities` listing all supported features
- **AND** the server SHALL transition to the `Initialized` state

#### Scenario: Shutdown
- **GIVEN** the server is in the `Running` state
- **WHEN** a client sends a `shutdown` request
- **THEN** the server SHALL cancel any ongoing typechecking operations, flush pending diagnostics, and respond with success
- **AND** the server SHALL transition to the `Shutdown` state

#### Scenario: Exit after shutdown
- **GIVEN** the server is in the `Shutdown` state
- **WHEN** a client sends an `exit` notification
- **THEN** the server SHALL exit with code 0

#### Scenario: Exit without shutdown
- **GIVEN** the server is in the `Running` state
- **WHEN** a client sends an `exit` notification without prior `shutdown`
- **THEN** the server SHALL exit with code 1

#### Scenario: Request before initialization
- **GIVEN** the server has not received `initialize`
- **WHEN** any other request (e.g., `textDocument/completion`) arrives
- **THEN** the server SHALL respond with JSON-RPC error code `-32002` (ServerNotInitialized)

---

### Requirement: LSP Capability Declaration
**ID**: REQ-LSP-003
**Priority**: P1
The server SHALL declare its capabilities accurately in the `InitializeResult`. It SHALL NOT advertise capabilities it does not implement.

#### Scenario: Capability response includes all supported features
- **GIVEN** an `initialize` request
- **WHEN** the server responds
- **THEN** the `capabilities` SHALL include:
  - `textDocumentSync`: `{ "openClose": true, "change": 2, "save": true }` (Incremental sync)
  - `completionProvider`: `{ "triggerCharacters": [".", ":", " "] }`
  - `hoverProvider`: `true`
  - `definitionProvider`: `true`
  - `referencesProvider`: `true`
  - `documentFormattingProvider`: `true`
  - `semanticTokensProvider`: `{ "legend": { "tokenTypes": [...], "tokenModifiers": [...] }, "full": true }`
  - `documentSymbolProvider`: `true`
  - `workspaceSymbolProvider`: `true`
  - `foldingRangeProvider`: `true`
  - `executeCommandProvider`: `{ "commands": ["fstar.restartSolver"] }`

---

### Requirement: Text Document Synchronization
**ID**: REQ-LSP-004
**Priority**: P1
The server SHALL support incremental text document synchronization via `textDocument/didOpen`, `textDocument/didChange`, and `textDocument/didClose`.

#### Scenario: didOpen — open a file
- **GIVEN** a client sends `textDocument/didOpen` with URI `file:///path/to/Module.fst`, languageId `fstar`, and full text
- **WHEN** the server processes it
- **THEN** the server SHALL register the document in its text document store
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

### Requirement: Diagnostics Publishing
**ID**: REQ-LSP-005
**Priority**: P1
The server SHALL publish F* typechecking errors and warnings as LSP diagnostics.

#### Scenario: Publish errors after typecheck
- **GIVEN** a document `Module.fst` with a type error at line 5, column 10
- **WHEN** the server completes a full-buffer check
- **THEN** the server SHALL send a `textDocument/publishDiagnostics` notification with:
  - `uri`: the document URI
  - `diagnostics`: an array containing one Diagnostic with `range` from line 5 col 10, `severity: 1` (Error), `message` containing the F* error text, and `source: "fstar"`
- **AND** the Diagnostic SHALL include both the use range and the definition range (if different) via `relatedInformation`

#### Scenario: Publish warnings
- **GIVEN** a document with an F* warning (e.g., unused variable)
- **WHEN** the server completes a check
- **THEN** the Diagnostic SHALL have `severity: 2` (Warning)

#### Scenario: Clear diagnostics on fix
- **GIVEN** a document with errors
- **WHEN** the user fixes all errors and the server re-checks
- **THEN** the server SHALL send `textDocument/publishDiagnostics` with an empty `diagnostics` array

#### Scenario: Diagnostics for dependencies
- **GIVEN** a check of `A.fst` reveals an error in a dependency `B.fst`
- **WHEN** the server completes the check
- **THEN** diagnostics SHALL be published for both `A.fst` and `B.fst` (the document owning each range)

---

### Requirement: Completion
**ID**: REQ-LSP-006
**Priority**: P1
The server SHALL provide code completions via `textDocument/completion`.

#### Scenario: Symbol completion
- **GIVEN** an open document with cursor at `List.ma|` (where `|` is cursor)
- **WHEN** a client sends `textDocument/completion` at that position
- **THEN** the server SHALL map to an F* IDE `AutoComplete` query
- **AND** the server SHALL return a list of `CompletionItem` with matching symbols (e.g., `List.map`, `List.mapi`, `List.mapTot`)

#### Scenario: Completion item details
- **GIVEN** a completion result for symbol `List.map`
- **WHEN** the server builds the CompletionItem
- **THEN** each item SHALL include:
  - `label`: the symbol name (e.g., `map`)
  - `kind`: `3` (Function) for let-bindings, `6` (Variable), `9` (Module), `14` (Keyword) as appropriate
  - `detail`: the symbol's type signature (from lookup)
  - `documentation`: fsdoc comment if available
  - `filterText`: the partial symbol for client-side filtering

#### Scenario: Keyword completion
- **GIVEN** cursor at beginning of a line
- **WHEN** completion is requested
- **THEN** F* keywords (`let`, `type`, `module`, `val`, `assume`, `effect`, `match`, `if`, `forall`, `exists`, `open`, `include`, `private`) SHALL appear as completions with `kind: 14` (Keyword)

#### Scenario: Dot completion trigger
- **GIVEN** an open F* document
- **WHEN** the user types `.` after a module name
- **THEN** the client SHALL automatically request completion (per the `triggerCharacters` capability)

#### Scenario: Empty completion
- **GIVEN** cursor at a position with no completions available
- **WHEN** completion is requested
- **THEN** the server SHALL return an empty CompletionList (not an error)

---

### Requirement: Hover
**ID**: REQ-LSP-007
**Priority**: P1
The server SHALL provide type information and documentation on hover via `textDocument/hover`.

#### Scenario: Hover over a symbol
- **GIVEN** an open document with `let add (x y: int) : int = x + y` and cursor over `add`
- **WHEN** a client sends `textDocument/hover` at that position
- **THEN** the server SHALL map to an F* IDE `Lookup` query (context: `symbol-only`)
- **AND** the server SHALL return a `Hover` result with:
  - `contents`: MarkupContent with `kind: "markdown"` containing the type signature (e.g., `` ```fstar\nadd: int -> int -> int\n``` ``)
  - `range`: the range of the symbol

#### Scenario: Hover over a local binding
- **GIVEN** `let x = 5 in x + 1` with cursor over the second `x`
- **WHEN** hover is requested
- **THEN** the server SHALL return the type of `x` (e.g., `int`) and the source location of its definition

#### Scenario: Hover with fsdoc
- **GIVEN** a symbol with an fsdoc comment (`/// This adds two numbers`)
- **WHEN** hover is requested
- **THEN** the hover content SHALL include the fsdoc documentation in addition to the type signature

#### Scenario: Hover with no symbol
- **GIVEN** cursor over whitespace or a non-identifier token
- **WHEN** hover is requested
- **THEN** the server SHALL return `null` (no hover information)

---

### Requirement: Go to Definition
**ID**: REQ-LSP-008
**Priority**: P1
The server SHALL support navigation to symbol definitions via `textDocument/definition`.

#### Scenario: Go to definition of a top-level function
- **GIVEN** a document using `List.map` and cursor over `map`
- **WHEN** a client sends `textDocument/definition` at that position
- **THEN** the server SHALL map to an F* IDE `Lookup` query (context: `code` with `definition` feature)
- **AND** the server SHALL return a `Location` or `LocationLink` pointing to the definition site of `List.map` in the F* standard library

#### Scenario: Go to definition of a local binding
- **GIVEN** `let x = 5 in x + 1` with cursor over the second `x`
- **WHEN** definition is requested
- **THEN** the server SHALL return the location of the `let x = 5` binding

#### Scenario: No definition available
- **GIVEN** cursor over a primitive (e.g., `int`, `bool`, `+`)
- **WHEN** definition is requested
- **THEN** the server SHALL return `null`

---

### Requirement: Find References
**ID**: REQ-LSP-009
**Priority**: P2
The server SHALL support finding all references to a symbol via `textDocument/references`.

#### Scenario: Find references of a function
- **GIVEN** a symbol `helper` used in multiple files
- **WHEN** a client sends `textDocument/references` at a usage of `helper`
- **THEN** the server SHALL map to an F* IDE `Search` query for the symbol
- **AND** the server SHALL return a list of `Location` objects, one per usage site

#### Scenario: Find references including declaration
- **GIVEN** a request with `context.includeDeclaration: true`
- **WHEN** references are computed
- **THEN** the result SHALL include the declaration site as well as all usage sites

#### Scenario: No references found
- **GIVEN** a symbol used only at its definition site
- **WHEN** references are requested
- **THEN** the server SHALL return an empty array (or array containing only the declaration if `includeDeclaration` is true)

---

### Requirement: Document Formatting
**ID**: REQ-LSP-010
**Priority**: P2
The server SHALL support document formatting via `textDocument/formatting`.

#### Scenario: Format an entire document
- **GIVEN** a malformatted F* document
- **WHEN** a client sends `textDocument/formatting`
- **THEN** the server SHALL map to an F* IDE `Format` query
- **AND** the server SHALL return a list of `TextEdit` objects representing the reformatted document

#### Scenario: Format a syntactically invalid document
- **GIVEN** a document with a parse error
- **WHEN** formatting is requested
- **THEN** the server SHALL return an error response indicating the document cannot be formatted (not crash)

---

### Requirement: Semantic Tokens
**ID**: REQ-LSP-011
**Priority**: P2
The server SHALL provide semantic token highlighting via `textDocument/semanticTokens/full`.

#### Scenario: Full document semantic tokens
- **GIVEN** a successfully typechecked F* document
- **WHEN** a client sends `textDocument/semanticTokens/full`
- **THEN** the server SHALL analyze the typed AST and return a `SemanticTokens` result with data encoding token types and modifiers relative to the document

#### Scenario: Semantic token types
- **GIVEN** the semantic token legend
- **WHEN** tokens are classified
- **THEN** the token types SHALL include at minimum:
  - `namespace` (module names)
  - `type` (type constructors)
  - `class` (typeclass names)
  - `function` (function/lemma names)
  - `variable` (local bindings)
  - `keyword` (F* keywords)
  - `comment` (comments)
  - `string` (string literals)
  - `number` (numeric literals)
  - `operator` (operators)
  - `typeParameter` (universe variables, implicit type params)

---

### Requirement: Document Symbols
**ID**: REQ-LSP-012
**Priority**: P2
The server SHALL provide document symbol information via `textDocument/documentSymbol`.

#### Scenario: Document symbols for a module
- **GIVEN** a typechecked F* module with multiple top-level definitions
- **WHEN** `textDocument/documentSymbol` is requested
- **THEN** the server SHALL return a list of `DocumentSymbol` objects (hierarchical if nested modules), each with:
  - `name`: the symbol name
  - `kind`: `5` (Class) for typeclasses, `12` (Function) for let-bindings, `13` (Variable), `23` (Struct) for type definitions
  - `range`: the full range of the definition
  - `selectionRange`: the range of the identifier

---

### Requirement: Workspace Symbol Search
**ID**: REQ-LSP-013
**Priority**: P2
The server SHALL support workspace-wide symbol search via `workspace/symbol`.

#### Scenario: Search for a symbol by name
- **GIVEN** the workspace has been typechecked
- **WHEN** a client sends `workspace/symbol` with query `map`
- **THEN** the server SHALL search all known symbols (from the F* environment) whose names contain `map`
- **AND** the server SHALL return a list of `SymbolInformation` objects with `name`, `kind`, `location`

#### Scenario: Empty search results
- **GIVEN** a query that matches no symbols
- **WHEN** workspace/symbol is requested
- **THEN** the server SHALL return an empty array

---

### Requirement: Folding Ranges
**ID**: REQ-LSP-014
**Priority**: P3
The server SHALL provide folding range information via `textDocument/foldingRange`.

#### Scenario: Folding ranges from AST structure
- **GIVEN** a parsed F* document
- **WHEN** `textDocument/foldingRange` is requested
- **THEN** the server SHALL compute folding ranges from the AST (parsed, not typechecked) for:
  - Module-level definitions
  - `begin`/`end` blocks
  - `match` branches
  - Multi-line parenthesized expressions
  - Comment blocks

---

### Requirement: Progress Reporting
**ID**: REQ-LSP-015
**Priority**: P2
The server SHALL report long-running operations via LSP progress notifications.

#### Scenario: Typechecking progress
- **GIVEN** a large module that takes more than 1 second to typecheck
- **WHEN** typechecking starts
- **THEN** the server SHALL send a `$/progress` notification with `kind: "begin"`, a unique token, and `title: "Typechecking Module.fst"`
- **AND** when typechecking completes, the server SHALL send `$/progress` with `kind: "end"`

#### Scenario: Incremental check progress
- **GIVEN** an incremental full-buffer check reporting fragment progress
- **WHEN** each fragment is processed
- **THEN** the server MAY report progress via `$/progress` with `kind: "report"` and a percentage or message

---

### Requirement: Cancel Request
**ID**: REQ-LSP-016
**Priority**: P2
The server SHALL support cancellation of in-progress requests via `$/cancelRequest`.

#### Scenario: Cancel a long typecheck
- **GIVEN** a long-running `textDocument/didChange` that triggers typechecking
- **WHEN** the client sends `$/cancelRequest` with the request ID
- **THEN** the server SHALL cancel the underlying F* IDE query using the `Cancel` mechanism
- **AND** the server SHALL respond to the original request with JSON-RPC error `-32800` (RequestCancelled)

---

### Requirement: Restart Solver Command
**ID**: REQ-LSP-017
**Priority**: P3
The server SHALL expose the F* solver restart functionality via `workspace/executeCommand`.

#### Scenario: Restart the Z3 solver
- **GIVEN** the Z3 solver may be in a bad state
- **WHEN** the client sends `workspace/executeCommand` with command `"fstar.restartSolver"`
- **THEN** the server SHALL map to the F* IDE `RestartSolver` query
- **AND** the server SHALL respond with success

---

### Requirement: Error Handling Resilience
**ID**: REQ-LSP-018
**Priority**: P1
The LSP server SHALL handle errors gracefully without crashing. It SHALL never exit due to invalid client input or internal F* errors.

#### Scenario: Invalid LSP message
- **GIVEN** a malformed JSON message that cannot be parsed
- **WHEN** the server receives it
- **THEN** the server SHALL respond with JSON-RPC error `-32700` (ParseError)
- **AND** the server SHALL continue processing subsequent messages

#### Scenario: Internal F* error during typecheck
- **GIVEN** an F* internal assert failure during typechecking
- **WHEN** the failure occurs
- **THEN** the server SHALL capture the error, publish it as a diagnostic (not crash)
- **AND** the server SHALL continue processing subsequent requests

#### Scenario: Method not found
- **GIVEN** an LSP request for an unsupported method
- **WHEN** the server receives it
- **THEN** the server SHALL respond with JSON-RPC error `-32601` (MethodNotFound)

#### Scenario: Invalid parameters
- **GIVEN** an LSP request with missing or invalid parameters
- **WHEN** the server processes it
- **THEN** the server SHALL respond with JSON-RPC error `-32602` (InvalidParams)

---

### Requirement: CLI Agent Support
**ID**: REQ-LSP-019
**Priority**: P1
The LSP server SHALL be usable from CLI tools and AI agents, not just editors. The stdin/stdout transport SHALL work with simple pipe invocation from a shell or process spawn.

#### Scenario: CLI agent queries diagnostics
- **GIVEN** a shell command `echo '...initialize + textDocument/didOpen...' | fstar.exe --lsp`
- **WHEN** the server processes the piped input
- **THEN** the server SHALL output LSP-formatted responses and diagnostics on stdout
- **AND** the server SHALL exit cleanly after processing the shutdown sequence

#### Scenario: Agent reads JSON responses
- **GIVEN** a CLI agent spawns `fstar.exe --lsp` as a subprocess
- **WHEN** the agent sends LSP requests on stdin
- **THEN** the server SHALL produce valid Content-Length-framed JSON on stdout
- **AND** each response SHALL be a complete, standalone JSON-RPC message

---

### Requirement: Entry Point — `--lsp` Flag on `fstar.exe`
**ID**: REQ-LSP-020
**Priority**: P1
The F* compiler SHALL support a new `--lsp` command-line flag on `fstar.exe` to start the LSP server. This flag SHALL follow the same pattern as the existing `--ide` flag (line 1034 of `FStarC.Options.fst`: `(noshort, "ide", Const (Bool true), ...)`).

#### Implementation Path (verified against source)

The following files SHALL be modified:

1. **`src/basic/FStarC.Options.fst`** — Add option declaration (follow pattern at line ~1034):
   ```fstar
   ( noshort, "lsp", Const (Bool true),
     text "Language Server Protocol mode (standard LSP over stdin/stdout)");
   ```
   Add accessor (follow `get_ide` pattern at line 494):
   ```fstar
   let get_lsp () = lookup_opt "lsp" as_bool
   ```

2. **`src/basic/FStarC.Options.fsti`** — Expose public API (follow `val ide` pattern at line 246):
   ```fstar
   val lsp : unit -> ML bool
   ```
   And implement:
   ```fstar
   let lsp () = get_lsp ()
   ```

3. **`src/fstar/FStarC.Main.fst`** — Add LSP entry point (before `--ide` check at line 381):
   ```fstar
   if Options.lsp () then begin
     if Options.interactive () then
       Errors.raise_error0 Errors.Error_FlagConflict
         "--lsp and --ide are mutually exclusive";
     FStarC.LSP.Server.start ()
   end
   else if Options.interactive () then begin
     ... existing --ide handling ...
   end
   ```

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

### Requirement: Logging and Debugging
**ID**: REQ-LSP-021
**Priority**: P3
The server SHALL support optional debug logging to stderr (not stdout, which is reserved for LSP communication).

#### Scenario: Debug logging to stderr
- **GIVEN** the server is started with environment variable `FSTAR_LSP_DEBUG=1`
- **WHEN** any LSP message is processed
- **THEN** the server MAY log the message type and timing to stderr
- **AND** logging SHALL NOT interfere with the LSP protocol on stdout

#### Scenario: Log LSP message trace
- **GIVEN** `FSTAR_LSP_TRACE=1`
- **WHEN** messages are sent/received
- **THEN** the server MAY log full JSON payloads to stderr (for debugging transport issues)

---

### Requirement: Reuse of Existing IDE Subsystem
**ID**: REQ-LSP-022
**Priority**: P1
The LSP server SHALL reuse the existing `FStarC.Interactive.Ide` subsystem rather than reimplementing typechecking, completion, lookup, or formatting logic.

#### Scenario: Mapping a completion request
- **GIVEN** an LSP `textDocument/completion` request
- **WHEN** the server processes it
- **THEN** the server SHALL construct an F* IDE query (e.g., `AutoComplete`) and submit it to the IDE subsystem
- **AND** the IDE subsystem SHALL handle the actual completion logic

#### Scenario: Mapping a full-buffer check
- **GIVEN** an LSP `textDocument/didOpen` or `textDocument/didChange`
- **WHEN** the server processes it
- **THEN** the server SHALL construct a `FullBuffer` IDE query and submit it to `FStarC.Interactive.Incremental`
- **AND** the resulting issues SHALL be mapped to LSP diagnostics

#### Scenario: Existing IDE protocol remains unchanged
- **GIVEN** the addition of the LSP server
- **WHEN** running in `--ide` mode
- **THEN** the existing IDE protocol SHALL continue to function exactly as before (no breaking changes)

---

### Requirement: Implementation Language
**ID**: REQ-LSP-023
**Priority**: P1
The LSP server SHALL be implemented in F* (the F* compiler's implementation language) using the same F* dialect (ML effect, monadic style) as the rest of the compiler codebase.

#### Scenario: New module in the compiler source
- **GIVEN** the compiler source tree
- **WHEN** the LSP server is implemented
- **THEN** new files SHALL be added under `src/lsp/`:
  - `FStarC.LSP.Server.fst` / `.fsti` — main server loop
  - `FStarC.LSP.Transport.fst` / `.fsti` — Content-Length framing (target: PROOF)
  - `FStarC.LSP.Messages.fst` / `.fsti` — LSP type definitions (target: PROOF)
  - `FStarC.LSP.Translator.fst` / `.fsti` — LSP ↔ IDE translation layer
- **AND** `FStarC.Main.fst` SHALL be updated to add the `--lsp` flag and entry point

---

### Requirement: Proofs for Provable Components
**ID**: REQ-LSP-024
**Priority**: P1
The LSP server SHALL include proofs for components where correctness is mechanically checkable and bugs would cause protocol failures. The codebase SHALL be designed with proofs in mind — pure functions separated from effectful I/O, data invariants made explicit via refinements, and roundtrip properties stated as lemmas.

**Proof strategy**: Separate pure computation from effectful I/O. Pure functions get `Tot`/`Lemma` types and SMT proofs. Effectful wrappers use `ML` with `admit()` for the I/O boundary, marked with `// Proof boundary: I/O` comments.

#### Target 1: Content-Length Framing Roundtrip (Transport module)

Prove that framing/unframing is invertible for valid inputs:

```fstar
/// Framing roundtrip: any valid JSON string survives encode→decode unchanged
let lemma_framing_roundtrip (msg: string{String.length msg > 0}) : Lemma
  (ensures decode_message (encode_message msg) == Some msg)
  = ()
```

Implementation approach:
- `encode_message : string -> Tot string` — pure, prepends Content-Length header
- `decode_message : string -> Tot (option string)` — pure, parses header and extracts body
- `read_message : ML (option string)` — effectful, reads stdin; calls `decode_message`
- `write_message : string -> ML unit` — effectful, calls `encode_message`, writes stdout

#### Target 2: URI ↔ Filepath Roundtrip

```fstar
/// file:///path/to/File.fst → /path/to/File.fst → file:///path/to/File.fst
let lemma_uri_filepath_roundtrip (path: string{is_valid_filepath path}) : Lemma
  (ensures filepath_to_uri (uri_to_filepath (filepath_to_uri path)) == filepath_to_uri path)
  = ()
```

#### Target 3: JSON-RPC Message Structure Validation

```fstar
/// Every response carries the request's id
let lemma_response_preserves_id (req: valid_jsonrpc_request) : Lemma
  (ensures (match build_response req result with
            | Some resp -> resp.id == req.id
            | None -> True))
  = ()
```

#### Target 4: Method Dispatch Completeness

```fstar
/// Every known LSP method has a handler
let lemma_dispatch_known_methods (method: lsp_method{Known? method}) : Lemma
  (ensures Some? (lookup_handler method))
  = ()
```

#### Scenario: Proofs are checkable by the compiler
- **GIVEN** the LSP server source code
- **WHEN** the F* compiler typechecks it
- **THEN** all `Lemma` statements in `Transport` and `Messages` modules SHALL verify (green)
- **AND** modules that wrap I/O (`Server`, `Translator`) MAY use `ML` effect and `admit()` at I/O boundaries, marked with explicit `// Proof boundary: I/O` comments

#### Scenario: Proofs don't block extraction
- **GIVEN** proof annotations in the code
- **WHEN** the compiler extracts to OCaml
- **THEN** all `Lemma` types SHALL erase to unit at extraction time
- **AND** the extracted OCaml code SHALL be identical to what would be produced without proofs

---

## Implementation Reference (Verified Against Source)

| Change | File | Line(s) | Pattern to Follow |
|--------|------|---------|-------------------|
| Add `--lsp` option | `src/basic/FStarC.Options.fst` | ~1034 | `(noshort, "ide", Const (Bool true), ...)` on line 1034 |
| Add option accessor | `src/basic/FStarC.Options.fst` | ~494 | `let get_ide () = lookup_opt "ide" as_bool` on line 494 |
| Export public API | `src/basic/FStarC.Options.fsti` | ~246 | `val ide : unit -> ML bool` on line 246 |
| Wire public accessor | `src/basic/FStarC.Options.fst` | ~2112 | `let ide () = get_ide ()` on line 2112 |
| Add entry point | `src/fstar/FStarC.Main.fst` | ~381 | `if Options.interactive () then begin ... Interactive.Ide.interactive_mode filename` |
| Error codes | `src/basic/FStarC.Errors.Codes.fst` | — | Add `Error_FlagConflict` and other LSP error codes |
| New LSP modules | `src/lsp/` | new directory | Follow `src/interactive/` structure; proofs in Transport, Messages |

## Proof Coverage Map

| Module | Proof Strategy | Lemmas |
|--------|---------------|--------|
| `Transport` | Pure encode/decode + `ML` I/O wrappers | `lemma_framing_roundtrip`, `lemma_empty_message_rejected` |
| `Messages` | Pure types + validation, no I/O | `lemma_response_preserves_id`, `lemma_uri_filepath_roundtrip` |
| `Translator` | `ML` effect, admit at I/O boundaries | `lemma_dispatch_known_methods` (pure sub-function) |
| `Server` | `ML` effect throughout | No lemmas (event loop) |

## Technical Notes

- **Implementation**: `src/lsp/` (new), `src/fstar/FStarC.Main.fst` (modified), `src/basic/FStarC.Options.fst` (modified), `src/basic/FStarC.Options.fsti` (modified)
- **Dependencies**: Existing IDE subsystem (`FStarC.Interactive.Ide`, `FStarC.Interactive.Ide.Types`, `FStarC.Interactive.Incremental`, `FStarC.Interactive.CompletionTable`)
- **Transport**: stdin/stdout with Content-Length-framed JSON per LSP 3.17 / JSON-RPC 2.0 (replaces existing line-delimited JSON in `FStarC.Interactive.JsonHelper.write_json`)
- **JSON**: Reuse existing `FStarC.Json` module for JSON construction and parsing
- **No new external dependencies**: No npm packages, no external LSP libraries. The F* compiler is self-contained OCaml/F# code.

## Known Limitations

- **Incremental sync**: Even though `textDocumentSync.change` is declared as `2` (Incremental), the F* IDE subsystem currently only supports full-buffer re-checking. The LSP server SHALL accept incremental edits and apply them to its document store, but SHALL trigger a full re-check each time.
- **Single document focus**: The F* IDE is designed around a single "current" document. Multi-file workspace support SHALL be best-effort initially.
- **No watched files**: `workspace/didChangeWatchedFiles` is out of scope for v0.1.0.
- **No code actions**: `textDocument/codeAction` (quick fixes) is out of scope for v0.1.0.
- **No signature help**: `textDocument/signatureHelp` is out of scope for v0.1.0.
- **No rename**: `textDocument/rename` is out of scope for v0.1.0.
- **No type hierarchy**: `textDocument/typeHierarchy` is out of scope for v0.1.0.

## Out of Scope (v0.1.0)

- Code actions / quick fixes
- Signature help
- Rename refactoring
- Type hierarchy
- Call hierarchy
- Inlay hints
- Inline values
- Linked editing ranges
- Monikers
- Selection ranges
- Color presentation
- Workspace folders / multi-root workspaces
- DidChangeWatchedFiles
- Code Lens
