(* The MIT License (MIT)

   Copyright (c) 2015-2017 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
   FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
   COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
   IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. *)

type event =
  | EVENT_VALUES of Unix.sockaddr list
  | EVENT_SEARCH_DONE

type nodes =
  {
    good: int;
    dubious: int;
    cached: int;
    incoming: int;
  }

type callback =
  event -> string -> unit

external dht_init: Unix.file_descr option -> Unix.file_descr option -> string -> unit = "caml_dht_init"
external dht_insert_node: string -> Unix.sockaddr -> unit = "caml_dht_insert_node"
external ping_node: Unix.sockaddr -> unit = "caml_dht_ping_node"
external periodic: (bytes * int * Unix.sockaddr) option -> callback -> float = "caml_dht_periodic"
external dht_search: string -> int -> Unix.socket_domain -> callback -> unit = "caml_dht_search"
external nodes: Unix.socket_domain -> nodes = "caml_dht_nodes"
external get_nodes: ipv4:int -> ipv6:int -> Unix.sockaddr list = "caml_dht_get_nodes"

let init ?ipv4 ?ipv6 id =
  if String.length id <> 20 then invalid_arg "init";
  dht_init ipv4 ipv6 id

let insert_node id sa =
  if String.length id <> 20 then invalid_arg "insert_node";
  dht_insert_node id sa

let search id ?(port = 0) ?(af = Unix.PF_INET) cb =
  if String.length id <> 20 then invalid_arg "search";
  dht_search id port af cb
