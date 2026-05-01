(*
   Copyright 2008-2025 Microsoft Research

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)

(* LSP Server — main event loop and lifecycle management *)

module FStarC.LSP.Server
open FStarC.Effect
open FStarC
open FStarC.Format
open FStarC.Json
open FStarC.List
open FStarC.Range
open FStarC.Range.Ops
open FStarC.Errors
open FStarC.Class.Show
open FStarC.Options
open FStarC.TypeChecker.Env
open FStarC.Interactive.Ide.Types
open FStarC.Interactive.Ide
open FStarC.Universal
open FStarC.Parser.ParseIt
open FStarC.Parser.Dep

module U = FStarC.Util
module LSPT = FStarC.LSP.Transport
module LSPM = FStarC.LSP.Messages
module LSPX = FStarC.LSP.Translator

#push-options "--admit_smt_queries true"

type document_entry = {
  doc_uri: string;
  doc_text: string;
  doc_repl: repl_state;
}

type server_state = {
  lifecycle: LSPM.lsp_state;
  documents: list document_entry;
}

let initial_server_state () : ML server_state =
  { lifecycle = LSPM.StateUninitialized;
    documents = []
  }

let get_or_create_document (st: server_state) (uri: string) (text: string) : ML (server_state & repl_state) =
  match U.try_find (fun d -> d.doc_uri = uri) st.documents with
  | Some doc ->
    let doc = { doc with doc_text = text } in
    let docs = List.map (fun d -> if d.doc_uri = uri then doc else d) st.documents in
    ({ st with documents = docs }, doc.doc_repl)
  | None ->
    let path = LSPX.uri_to_filepath uri in
    let env = init_env (empty_deps [path]) in
    let env = set_range env (initial_range path) in
    let repl = {
      repl_line = 1;
      repl_column = 0;
      repl_fname = path;
      repl_curmod = None;
      repl_env = env;
      repl_deps_stack = [];
      repl_stdin = U.open_stdin ();
      repl_names = FStarC.Interactive.CompletionTable.empty;
      repl_buffered_input_queries = [];
      repl_lang = []
    } in
    let doc = { doc_uri = uri; doc_text = text; doc_repl = repl } in
    ({ st with documents = doc :: st.documents }, repl)

let run_ide_query (repl: repl_state) (q: query) : ML (list json) =
  let result = js_repl_eval repl q in
  let (responses, _) = result in
  responses

let publish_diagnostics (uri: string) (issues: list json) : ML unit =
  let params = JsonAssoc [
    ("uri", JsonStr uri);
    ("diagnostics", JsonList issues)
  ] in
  let msg = JsonAssoc [
    ("jsonrpc", JsonStr "2.0");
    ("method", JsonStr "textDocument/publishDiagnostics");
    ("params", params)
  ] in
  LSPT.write_message (string_of_json msg)

let handle_initialize (st: server_state) (id: int) : ML (server_state & string) =
  let caps = LSPM.build_initialize_result () in
  let resp = LSPM.Response id caps in
  let resp_str = LSPM.serialize_jsonrpc resp in
  ({ st with lifecycle = LSPM.StateInitialized }, resp_str)

let handle_request (st: server_state) (id: int) (method': LSPM.lsp_method) (params: json) : ML (server_state & string) =
  if LSPX.method_needs_initialization method' && st.lifecycle = LSPM.StateUninitialized then
    let err = LSPM.build_error id (-32002) "Server not initialized" in
    (st, string_of_json err)
  else
    match method' with
    | LSPM.Initialize ->
      handle_initialize st id

    | LSPM.Initialized ->
      let resp = LSPM.Response id JsonNull in
      ({ st with lifecycle = LSPM.StateRunning }, LSPM.serialize_jsonrpc resp)

    | LSPM.Shutdown ->
      let resp = LSPM.Response id JsonNull in
      ({ st with lifecycle = LSPM.StateShutdown }, LSPM.serialize_jsonrpc resp)

    | LSPM.TextDocumentDidOpen ->
      (match LSPX.get_text_document_uri params, LSPX.get_text_document_text params with
       | Some uri, Some text ->
         let st, repl = get_or_create_document st uri text in
         let qid = show id in
         let query = { qid = qid; qq = FullBuffer (text, Full, false) } in
         let responses = run_ide_query repl query in
         publish_diagnostics uri responses;
         let resp = LSPM.Response id JsonNull in
         (st, LSPM.serialize_jsonrpc resp)
       | _ ->
         let err = LSPM.build_error id (-32602) "Invalid params: missing textDocument.uri or text" in
         (st, string_of_json err))

    | LSPM.TextDocumentDidChange ->
      (match LSPX.get_text_document_uri params with
       | Some uri ->
         let text_opt =
           match LSPX.try_field "contentChanges" params with
           | Some (JsonList (change :: _)) -> LSPX.field_str "text" change
           | _ -> LSPX.get_text_document_text params
         in
         (match text_opt with
          | Some text ->
            let st, repl = get_or_create_document st uri text in
            let qid = show id in
            let query = { qid = qid; qq = FullBuffer (text, Full, false) } in
            let responses = run_ide_query repl query in
            publish_diagnostics uri responses;
            let resp = LSPM.Response id JsonNull in
            (st, LSPM.serialize_jsonrpc resp)
          | None ->
            let err = LSPM.build_error id (-32602) "Missing text content" in
            (st, string_of_json err))
       | _ ->
         let err = LSPM.build_error id (-32602) "Missing textDocument.uri" in
         (st, string_of_json err))

    | LSPM.TextDocumentDidClose ->
      (match LSPX.get_text_document_uri params with
       | Some uri ->
         let docs = List.filter (fun d -> d.doc_uri <> uri) st.documents in
         let st = { st with documents = docs } in
         publish_diagnostics uri [];
         let resp = LSPM.Response id JsonNull in
         (st, LSPM.serialize_jsonrpc resp)
       | _ ->
         let err = LSPM.build_error id (-32602) "Missing textDocument.uri" in
         (st, string_of_json err))

    | LSPM.TextDocumentCompletion ->
      (match LSPX.get_text_document_uri params with
       | Some uri ->
         (match U.try_find (fun d -> d.doc_uri = uri) st.documents with
          | Some doc ->
            let qid = show id in
            let query = { qid = qid; qq = AutoComplete ("", CKCode) } in
            let responses = run_ide_query doc.doc_repl query in
            let resp = LSPM.Response id (JsonList responses) in
            (st, LSPM.serialize_jsonrpc resp)
          | None ->
            let resp = LSPM.Response id (JsonList []) in
            (st, LSPM.serialize_jsonrpc resp))
       | _ ->
         let resp = LSPM.Response id (JsonList []) in
         (st, LSPM.serialize_jsonrpc resp))

    | LSPM.TextDocumentHover ->
      (match st.documents with
       | doc :: _ ->
         let qid = show id in
         let query = { qid = qid; qq = Lookup ("", LKSymbolOnly, None, ["symbol-only"], None) } in
         let responses = run_ide_query doc.doc_repl query in
         let resp = LSPM.Response id (match responses with
           | r :: _ -> r
           | _ -> JsonNull) in
         (st, LSPM.serialize_jsonrpc resp)
       | [] ->
         let resp = LSPM.Response id JsonNull in
         (st, LSPM.serialize_jsonrpc resp))

    | LSPM.TextDocumentDefinition ->
      (match st.documents with
       | doc :: _ ->
         let qid = show id in
         let query = { qid = qid; qq = Lookup ("", LKCode, None, ["definition"], None) } in
         let responses = run_ide_query doc.doc_repl query in
         let resp = LSPM.Response id (match responses with
           | r :: _ -> r
           | _ -> JsonNull) in
         (st, LSPM.serialize_jsonrpc resp)
       | [] ->
         let resp = LSPM.Response id JsonNull in
         (st, LSPM.serialize_jsonrpc resp))

    | LSPM.TextDocumentFormatting ->
      (match LSPX.get_text_document_uri params with
       | Some uri ->
         (match U.try_find (fun d -> d.doc_uri = uri) st.documents with
          | Some doc ->
            let qid = show id in
            let query = { qid = qid; qq = Format (doc.doc_text) } in
            let responses = run_ide_query doc.doc_repl query in
            let resp = LSPM.Response id (match responses with
              | (JsonAssoc fields) :: _ ->
                (match U.try_find (fun (k, _) -> k = "formatted-code") fields with
                 | Some (_, formatted) -> formatted
                 | _ -> JsonNull)
              | _ -> JsonNull) in
            (st, LSPM.serialize_jsonrpc resp)
          | None ->
            let err = LSPM.build_error id (-32602) "Document not open" in
            (st, string_of_json err))
       | _ ->
         let err = LSPM.build_error id (-32602) "Missing textDocument.uri" in
         (st, string_of_json err))

    | LSPM.WorkspaceSymbol ->
      (match LSPX.field_str "query" params with
       | Some query_str ->
         let qid = show id in
         let query = { qid = qid; qq = Search (query_str) } in
         let repl = match st.documents with
           | doc :: _ -> doc.doc_repl
           | _ ->
             let empty_env = init_env (empty_deps []) in
             {
               repl_line = 1; repl_column = 0; repl_fname = "";
               repl_curmod = None; repl_env = empty_env;
               repl_deps_stack = [];
               repl_stdin = U.open_stdin ();
               repl_names = FStarC.Interactive.CompletionTable.empty;
               repl_buffered_input_queries = [];
               repl_lang = []
             }
         in
         let responses = run_ide_query repl query in
         let resp = LSPM.Response id (JsonList responses) in
         (st, LSPM.serialize_jsonrpc resp)
       | None ->
         let resp = LSPM.Response id (JsonList []) in
         (st, LSPM.serialize_jsonrpc resp))

    | LSPM.WorkspaceExecuteCommand ->
      (match LSPX.field_str "command" params with
       | Some "fstar.restartSolver" ->
         let qid = show id in
         let query = { qid = qid; qq = RestartSolver } in
         (match st.documents with
          | doc :: _ ->
            let _responses = run_ide_query doc.doc_repl query in
            ()
          | _ -> ());
         let resp = LSPM.Response id JsonNull in
         (st, LSPM.serialize_jsonrpc resp)
       | _ ->
         let err = LSPM.build_error id (-32601) "Unknown command" in
         (st, string_of_json err))

    | _ ->
      let err = LSPM.build_error id (-32601) ("Method not implemented: " ^ LSPM.method_name method') in
      (st, string_of_json err)

let handle_notification (st: server_state) (method': LSPM.lsp_method) (_params: json) : ML server_state =
  match method' with
  | LSPM.Initialized ->
    { st with lifecycle = LSPM.StateRunning }
  | LSPM.Exit -> st
  | _ -> st

let rec server_loop (st: server_state) : ML unit =
  match LSPT.read_message () with
  | None -> ()
  | Some raw ->
    match json_of_string raw with
    | None ->
      (try
        let err = LSPM.build_error 0 (-32700) "Parse error" in
        LSPT.write_message (string_of_json err)
      with _ -> ());
      server_loop st
    | Some json_msg ->
      (match LSPM.parse_jsonrpc json_msg with
       | None ->
         let err = LSPM.build_error 0 (-32700) "Invalid JSON-RPC message" in
         LSPT.write_message (string_of_json err);
         server_loop st
       | Some (LSPM.Request id method' params) ->
         (try
           let st, response_str = handle_request st id method' params in
           LSPT.write_message response_str;
           server_loop st
         with
         | _ ->
           let err = LSPM.build_error id (-32603) "Internal error" in
           LSPT.write_message (string_of_json err);
           server_loop st)
       | Some (LSPM.Notification method' params) ->
         if method' = LSPM.Exit then (
           if st.lifecycle = LSPM.StateShutdown then exit 0
           else exit 1
         );
         let st = handle_notification st method' params in
         server_loop st
       | Some _ -> server_loop st)

let start () : ML unit =
  let st = initial_server_state () in
  server_loop st

#pop-options
