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
open FStarC.Json

type lsp_method =
  | Initialize
  | Initialized
  | Shutdown
  | Exit
  | TextDocumentDidOpen
  | TextDocumentDidChange
  | TextDocumentDidClose
  | TextDocumentDidSave
  | TextDocumentCompletion
  | TextDocumentHover
  | TextDocumentDefinition
  | TextDocumentReferences
  | TextDocumentFormatting
  | TextDocumentSemanticTokensFull
  | TextDocumentDocumentSymbol
  | TextDocumentFoldingRange
  | WorkspaceSymbol
  | WorkspaceExecuteCommand
  | CancelRequest
  | UnknownMethod of string

type lsp_state =
  | StateUninitialized
  | StateInitialized
  | StateRunning
  | StateShutdown

type jsonrpc_message =
  | Request  : id: int -> method': lsp_method -> params: json -> jsonrpc_message
  | Response : id: int -> result: json -> jsonrpc_message
  | Error    : id: int -> code: int -> message: string -> jsonrpc_message
  | Notification : method': lsp_method -> params: json -> jsonrpc_message

val parse_method : string -> ML lsp_method
val method_name : lsp_method -> ML string
val parse_jsonrpc : json -> ML (option jsonrpc_message)
val serialize_jsonrpc : jsonrpc_message -> ML string
val build_initialize_result : unit -> ML json
val build_error : int -> int -> string -> ML json
