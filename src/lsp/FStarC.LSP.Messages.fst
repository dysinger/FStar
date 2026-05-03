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

module FStarC.LSP.Messages
open FStarC.Effect
open FStarC
open FStarC.Format
open FStarC.Json
open FStarC.List
open FStarC.Class.Show

#push-options "--admit_smt_queries true"

module U = FStarC.Util

let parse_method (m: string) : ML lsp_method =
  match m with
  | "initialize" -> Initialize
  | "initialized" -> Initialized
  | "shutdown" -> Shutdown
  | "exit" -> Exit
  | "textDocument/didOpen" -> TextDocumentDidOpen
  | "textDocument/didChange" -> TextDocumentDidChange
  | "textDocument/didClose" -> TextDocumentDidClose
  | "textDocument/didSave" -> TextDocumentDidSave
  | "textDocument/completion" -> TextDocumentCompletion
  | "textDocument/hover" -> TextDocumentHover
  | "textDocument/definition" -> TextDocumentDefinition
  | "textDocument/references" -> TextDocumentReferences
  | "textDocument/formatting" -> TextDocumentFormatting
  | "textDocument/semanticTokens/full" -> TextDocumentSemanticTokensFull
  | "textDocument/documentSymbol" -> TextDocumentDocumentSymbol
  | "textDocument/foldingRange" -> TextDocumentFoldingRange
  | "workspace/symbol" -> WorkspaceSymbol
  | "workspace/executeCommand" -> WorkspaceExecuteCommand
  | "$/cancelRequest" -> CancelRequest
  | other -> UnknownMethod other

let method_name (m: lsp_method) : ML string =
  match m with
  | Initialize -> "initialize"
  | Initialized -> "initialized"
  | Shutdown -> "shutdown"
  | Exit -> "exit"
  | TextDocumentDidOpen -> "textDocument/didOpen"
  | TextDocumentDidChange -> "textDocument/didChange"
  | TextDocumentDidClose -> "textDocument/didClose"
  | TextDocumentDidSave -> "textDocument/didSave"
  | TextDocumentCompletion -> "textDocument/completion"
  | TextDocumentHover -> "textDocument/hover"
  | TextDocumentDefinition -> "textDocument/definition"
  | TextDocumentReferences -> "textDocument/references"
  | TextDocumentFormatting -> "textDocument/formatting"
  | TextDocumentSemanticTokensFull -> "textDocument/semanticTokens/full"
  | TextDocumentDocumentSymbol -> "textDocument/documentSymbol"
  | TextDocumentFoldingRange -> "textDocument/foldingRange"
  | WorkspaceSymbol -> "workspace/symbol"
  | WorkspaceExecuteCommand -> "workspace/executeCommand"
  | CancelRequest -> "$/cancelRequest"
  | UnknownMethod s -> s

let try_assoc_msg (key: string) (a: list (string & json)) : ML (option json) =
  match U.try_find (fun (k, _) -> k = key) a with
  | None -> None
  | Some (_, v) -> Some v

let parse_jsonrpc (raw: json) : ML (option jsonrpc_message) =
  match raw with
  | JsonAssoc fields ->
    let id_opt = try_assoc_msg "id" fields in
    let method_opt = try_assoc_msg "method" fields in
    let params_opt = try_assoc_msg "params" fields in
    let result_opt = try_assoc_msg "result" fields in
    let id = match id_opt with
      | Some (JsonInt i) -> Some i
      | None -> None
      | _ -> None
    in
    (match id, method_opt, result_opt with
     | Some i, Some (JsonStr m), None ->
       let method' = parse_method m in
       let params = match params_opt with Some p -> p | None -> JsonNull in
       Some (Request i method' params)
     | None, Some (JsonStr m), None ->
       let method' = parse_method m in
       let params = match params_opt with Some p -> p | None -> JsonNull in
       Some (Notification method' params)
     | Some i, None, Some result ->
       Some (Response i result)
     | Some i, None, None ->
       (match try_assoc_msg "error" fields with
        | Some (JsonAssoc err_fields) ->
          let code = match try_assoc_msg "code" err_fields with
            | Some (JsonInt c) -> c
            | _ -> -1 in
          let message = match try_assoc_msg "message" err_fields with
            | Some (JsonStr msg) -> msg
            | _ -> "Unknown error" in
          Some (Error i code message)
        | _ -> None)
     | _ -> None)
  | _ -> None

let serialize_jsonrpc (msg: jsonrpc_message) : ML string =
  let jsonrpc_ver = JsonStr "2.0" in
  let json = match msg with
    | Request id _method' params ->
      JsonAssoc [
        ("jsonrpc", jsonrpc_ver);
        ("id", JsonInt id);
        ("method", JsonStr (method_name _method'));
        ("params", params)
      ]
    | Response id result ->
      JsonAssoc [
        ("jsonrpc", jsonrpc_ver);
        ("id", JsonInt id);
        ("result", result)
      ]
    | Error id code message ->
      JsonAssoc [
        ("jsonrpc", jsonrpc_ver);
        ("id", JsonInt id);
        ("error", JsonAssoc [
          ("code", JsonInt code);
          ("message", JsonStr message)
        ])
      ]
    | Notification _method' params ->
      JsonAssoc [
        ("jsonrpc", jsonrpc_ver);
        ("method", JsonStr (method_name _method'));
        ("params", params)
      ]
  in
  string_of_json json

let build_initialize_result () : ML json =
  let server_info =
    JsonAssoc [
      ("name", JsonStr "fstar");
      ("version", JsonStr (try U.trim_string (U.file_get_contents "version.txt") with _ -> "unknown"))
    ]
  in
  let capabilities =
    JsonAssoc [
      ("textDocumentSync", JsonAssoc [
        ("openClose", JsonBool true);
        ("change", JsonInt 2);
        ("save", JsonBool true)
      ]);
      ("completionProvider", JsonAssoc [
        ("triggerCharacters", JsonList [JsonStr "."; JsonStr ":"; JsonStr " "])
      ]);
      ("hoverProvider", JsonBool true);
      ("definitionProvider", JsonBool true);
      ("referencesProvider", JsonBool true);
      ("documentFormattingProvider", JsonBool true);
      ("documentSymbolProvider", JsonBool true);
      ("workspaceSymbolProvider", JsonBool true);
      ("executeCommandProvider", JsonAssoc [
        ("commands", JsonList [JsonStr "fstar.restartSolver"])
      ])
    ]
  in
  JsonAssoc [
    ("serverInfo", server_info);
    ("capabilities", capabilities)
  ]

let build_error (id: int) (code: int) (message: string) : ML json =
  JsonAssoc [
    ("jsonrpc", JsonStr "2.0");
    ("id", JsonInt id);
    ("error", JsonAssoc [
      ("code", JsonInt code);
      ("message", JsonStr message)
    ])
  ]

#pop-options
