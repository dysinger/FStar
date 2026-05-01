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

module FStarC.LSP.Translator
open FStarC.Effect
open FStarC.Json
open FStarC.Errors
open FStarC.Interactive.Ide.Types
open FStarC.LSP.Messages

val method_needs_initialization : lsp_method -> bool
val uri_to_filepath : string -> ML string
val filepath_to_uri : string -> ML string
val lsp_position_to_fstar : string -> int -> int -> ML (string & int & int)
val try_field : string -> json -> ML (option json)
val field_str : string -> json -> ML (option string)
val field_int : string -> json -> ML (option int)
val get_text_document_uri : json -> ML (option string)
val get_text_document_text : json -> ML (option string)
val get_position : json -> ML (option (int & int))
val translate_to_ide_query : repl_state -> jsonrpc_message -> ML (option query)
val translate_issues_to_diagnostics : string -> list issue -> ML (list json)
