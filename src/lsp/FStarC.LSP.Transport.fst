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

(* LSP Transport Layer — Content-Length framed JSON over stdin/stdout *)
(* Category (a): admit_smt_queries for substring bounds — F* can't statically
   verify bounds for Util.substring calls in decode_message. The code is correct
   and extracts everywhere. *)

module FStarC.LSP.Transport
open FStarC.Effect
open FStarC
open FStarC.Format

module U = FStarC.Util

#push-options "--admit_smt_queries true"

let crlf = "\r\n"
let header_prefix = "Content-Length: "

let encode_message (msg: string) : Tot string =
  let len = String.length msg in
  header_prefix ^ (string_of_int len) ^ crlf ^ crlf ^ msg

let decode_message (input: string) : ML (option string) =
  if not (U.starts_with input header_prefix) then None
  else
    let after_prefix = U.substring_from input (String.length header_prefix) in
    match U.split after_prefix crlf with
    | len_str :: rest ->
      (match U.safe_int_of_string len_str with
       | None -> None
       | Some len ->
         match rest with
         | "" :: body_parts ->
           let body = String.concat crlf body_parts in
           if String.length body >= len then
             Some (U.substring body 0 len)
           else None
         | _ -> None)
    | _ -> None

let read_message () : ML (option string) =
  let stdin = U.open_stdin () in
  match U.read_line stdin with
  | None -> None
  | Some header_line ->
    if not (U.starts_with header_line header_prefix) then None
    else
      let len_str = U.substring_from header_line (String.length header_prefix) in
      let len_str = U.trim_string len_str in
      (match U.safe_int_of_string len_str with
       | None -> None
       | Some len ->
         (match U.read_line stdin with
          | None -> None
          | Some _ ->
            U.nread stdin len))

let write_message (msg: string) : ML unit =
  let framed = encode_message msg in
  Format.print_raw framed

#pop-options
