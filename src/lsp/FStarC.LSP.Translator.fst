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

(* LSP ↔ IDE Translator — maps LSP methods to F* IDE queries and back *)

module FStarC.LSP.Translator
open FStarC.Effect
open FStarC
open FStarC.Format
open FStarC.Json
open FStarC.List
open FStarC.Range
open FStarC.Range.Ops
open FStarC.Errors
open FStarC.Class.Show
open FStarC.Interactive.Ide.Types
open FStarC.Parser.ParseIt

module U = FStarC.Util
module LSPM = FStarC.LSP.Messages

#push-options "--admit_smt_queries true"

(* Check if an LSP method requires an initialized state *)
let method_needs_initialization (m: LSPM.lsp_method) : bool =
  match m with
  | LSPM.Initialize | LSPM.Initialized | LSPM.Shutdown | LSPM.Exit -> false
  | _ -> true

(* URI ↔ filepath conversion *)
let uri_to_filepath (uri: string) : ML string =
  if U.starts_with uri "file://" then
    U.substring_from uri 7
  else
    uri

let filepath_to_uri (path: string) : ML string =
  if U.starts_with path "file://" then path
  else "file://" ^ path

let lsp_position_to_fstar (uri: string) (line: int) (char: int) : ML (string & int & int) =
  let path = uri_to_filepath uri in
  (path, line + 1, char)

(* JSON field extraction helpers *)
let try_field (key: string) (obj: json) : ML (option json) =
  match obj with
  | JsonAssoc fields ->
    (match U.try_find (fun (k, _) -> k = key) fields with
     | Some (_, v) -> Some v
     | None -> None)
  | _ -> None

let field_str (key: string) (obj: json) : ML (option string) =
  match try_field key obj with
  | Some (JsonStr s) -> Some s
  | _ -> None

let field_int (key: string) (obj: json) : ML (option int) =
  match try_field key obj with
  | Some (JsonInt i) -> Some i
  | _ -> None

let get_text_document_uri (params: json) : ML (option string) =
  match try_field "textDocument" params with
  | Some td -> field_str "uri" td
  | None -> None

let get_text_document_text (params: json) : ML (option string) =
  match try_field "textDocument" params with
  | Some td -> field_str "text" td
  | None -> None

let get_position (params: json) : ML (option (int & int)) =
  match try_field "position" params with
  | Some pos ->
    (match field_int "line" pos, field_int "character" pos with
     | Some l, Some c -> Some (l, c)
     | _ -> None)
  | None -> None

(* Translate an LSP request to an IDE query *)
let translate_to_ide_query (repl: repl_state)
                           (msg: LSPM.jsonrpc_message)
                           : ML (option query) =
  match msg with
  | LSPM.Request id LSPM.TextDocumentDidOpen params ->
    (match get_text_document_uri params, get_text_document_text params with
     | Some uri, Some text ->
       let qid = show id in
       Some { qid = qid; qq = FullBuffer (text, Full, false) }
     | _ -> None)

  | LSPM.Request id LSPM.TextDocumentDidChange params ->
    (match try_field "contentChanges" params with
     | Some (JsonList changes) ->
       (match changes with
        | change :: _ ->
          (match field_str "text" change with
           | Some text ->
             let qid = show id in
             Some { qid = qid; qq = FullBuffer (text, Full, false) }
           | None -> None)
        | _ -> None)
     | _ ->
       (match get_text_document_text params with
        | Some text ->
          let qid = show id in
          Some { qid = qid; qq = FullBuffer (text, Full, false) }
        | None -> None))

  | LSPM.Request id LSPM.TextDocumentCompletion params ->
    (match get_text_document_uri params, get_position params with
     | Some _uri, Some (_line, _char) ->
       let qid = show id in
       Some { qid = qid; qq = AutoComplete ("", CKCode) }
     | _ -> None)

  | LSPM.Request id LSPM.TextDocumentHover _params ->
    let qid = show id in
    Some { qid = qid; qq = Lookup ("", LKSymbolOnly, None, ["symbol-only"], None) }

  | LSPM.Request id LSPM.TextDocumentDefinition _params ->
    let qid = show id in
    Some { qid = qid; qq = Lookup ("", LKCode, None, ["definition"], None) }

  | LSPM.Request id LSPM.TextDocumentReferences _params ->
    let qid = show id in
    Some { qid = qid; qq = Search ("") }

  | LSPM.Request id LSPM.TextDocumentFormatting _params ->
    let qid = show id in
    Some { qid = qid; qq = Format ("") }

  | LSPM.Request id LSPM.TextDocumentDocumentSymbol _params ->
    let qid = show id in
    Some { qid = qid; qq = Search ("") }

  | LSPM.Request id LSPM.WorkspaceSymbol params ->
    (match field_str "query" params with
     | Some query_str ->
       let qid = show id in
       Some { qid = qid; qq = Search (query_str) }
     | _ -> None)

  | LSPM.Request id LSPM.WorkspaceExecuteCommand params ->
    (match field_str "command" params with
     | Some "fstar.restartSolver" ->
       let qid = show id in
       Some { qid = qid; qq = RestartSolver }
     | _ -> None)

  | _ -> None

(* Translate F* issues to LSP diagnostics *)
let translate_issues_to_diagnostics (uri: string) (issues: list issue) : ML (list json) =
  issues |> List.map (fun issue ->
    let severity = match issue.issue_level with
      | EError -> JsonInt 1
      | EWarning -> JsonInt 2
      | EInfo -> JsonInt 3
      | ENotImplemented -> JsonInt 1
    in
    let range = match issue.issue_range with
      | Some r ->
        let start_pos = start_of_use_range r in
        let end_pos = end_of_use_range r in
        JsonAssoc [
          ("start", JsonAssoc [
            ("line", JsonInt (line_of_pos start_pos - 1));
            ("character", JsonInt (col_of_pos start_pos))
          ]);
          ("end", JsonAssoc [
            ("line", JsonInt (line_of_pos end_pos - 1));
            ("character", JsonInt (col_of_pos end_pos))
          ])
        ]
      | None ->
        JsonAssoc [
          ("start", JsonAssoc [("line", JsonInt 0); ("character", JsonInt 0)]);
          ("end", JsonAssoc [("line", JsonInt 0); ("character", JsonInt 0)])
        ]
    in
    let message = format_issue' false issue in
    JsonAssoc [
      ("range", range);
      ("severity", severity);
      ("source", JsonStr "fstar");
      ("message", JsonStr message)
    ])

#pop-options
