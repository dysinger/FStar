(*
   Copyright 2008-2016  Nikhil Swamy and Microsoft Research

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

module FStarC.Interactive.Ide

open FStarC.Effect
open FStarC.Interactive.Ide.Types

/// Evaluate a single IDE query against a repl_state.
/// Returns (json_responses, state_or_exitcode).
/// Used by the LSP server to drive the IDE subsystem programmatically.
val js_repl_eval : repl_state -> query -> (list FStarC.Json.json & either repl_state int)

/// Install hooks to redirect Format output and error handling to the given printer callback.
/// Used by the LSP server to capture IDE output instead of writing to stdout.
val install_ide_mode_hooks : (FStarC.Json.json -> unit) -> unit

val interactive_mode (filename:string): unit
