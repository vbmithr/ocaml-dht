(* The MIT License (MIT)

   Copyright (c) 2014 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

let debug ?exn fmt = Log.lprintlf ?exn ("DHT: " ^^ fmt)
    
let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)

let alpha = 3
    
type query =
  | Ping
  | FindNode of SHA1.t
  | GetPeers of SHA1.t
  | Announce of SHA1.t * int * string

let string_of_query = function
  | Ping -> "ping"
  | FindNode id ->
    Printf.sprintf "find_node %s" (SHA1.to_hex_short id)
  | GetPeers ih ->
    Printf.sprintf "get_peers %s" (SHA1.to_hex_short ih)                
  | Announce (ih, port, token) ->
    Printf.sprintf "announce %s %d %S" (SHA1.to_hex_short ih) port token

type node_info = SHA1.t * Addr.t

type response =
  | Pong
  | Nodes of node_info list
  | Peers of string * Addr.t list * node_info list

let string_of_node (id, addr) =
  Printf.sprintf "%s (%s)" (SHA1.to_hex_short id) (Addr.to_string addr)

let strl f l = "[" ^ String.concat " " (List.map f l) ^ "]"

let string_of_response r =
  match r with
  | Pong ->
    "pong"
  | Nodes nodes ->
    Printf.sprintf "nodes %s" (strl string_of_node nodes)
  | Peers (token, peers, nodes) ->
    Printf.sprintf "peers token=%S peers %s nodes %s"
      token (strl Addr.to_string peers) (strl string_of_node nodes)

let parse_query name args : SHA1.t * query =
  let sha1 k args = SHA1.of_bin (Bcode.to_string (List.assoc k args)) in
  let q = match name with
    | "ping" ->
      Ping
    | "find_node" ->
      FindNode (sha1 "target" args)
    | "get_peers" ->
      GetPeers (sha1 "info_hash" args)
    | "announce_peer" ->
      let ih = sha1 "info_hash" args in
      let port = Bcode.to_int (List.assoc "port" args) in
      let token = Bcode.to_string (List.assoc "token" args) in
      Announce (ih, port, token)
    | _ ->
      failwith (Printf.sprintf "DHT.parse_query name:%s" name)
  in
  let id = sha1 "id" args in
  id, q

let parse_nodes s =
  let s = Bitstring.bitstring_of_string s in
  let rec loop s =
    bitmatch s with
    | { id : 20 * 8 : string, bind (SHA1.of_bin id);
        addr : 6 * 8 : bitstring, bind (Addr.of_string_compact addr);
        rest : -1 : bitstring } ->
      (id, addr) :: loop rest
    | { _ } ->
      []
  in
  loop s

let parse_value s =
  let s = Bitstring.bitstring_of_string s in
  Addr.of_string_compact s

let parse_response q args =
  let sha1 k args = SHA1.of_bin (Bcode.to_string (List.assoc k args)) in
  let r = match q with
    | Ping ->
      Pong
    | FindNode _ ->
      let s = Bcode.to_string (List.assoc "nodes" args) in
      Nodes (parse_nodes s)
    | GetPeers _ ->
      let token = Bcode.to_string (List.assoc "token" args) in
      let peers =
        try
          let values = Bcode.to_list (List.assoc "values" args) in
          let values = List.map Bcode.to_string values in
          List.map parse_value values
        with
        | Not_found -> []
      in
      let nodes =
        try parse_nodes (Bcode.to_string (List.assoc "nodes" args)) with Not_found -> []
      in
      Peers (token, peers, nodes)
    | Announce _ ->
      Pong
  in
  let id = sha1 "id" args in
  id, r

let secret_timeout = 10.0 *. 60.0

module Secret : sig
  type t
  val create : float -> t
  val current : t -> string
  val previous : t -> string
  val is_valid : t -> string -> bool
end = struct
  type t = {
    mutable cur : string;
    mutable prev : string;
    mutable next_timeout : float;
    timeout_delay : float
  }
  let fresh () = string_of_int (Random.int 1_000_000)
  let create timeout_delay =
    let s = fresh () in
    { cur = s; prev = s; next_timeout = Unix.time () +. timeout_delay; timeout_delay }
  let check_timeout secret =
    let now = Unix.time () in
    if now > secret.next_timeout then begin
      secret.prev <- secret.cur;
      secret.cur <- fresh ();
      secret.next_timeout <- now +. secret.timeout_delay
    end
  let current secret = check_timeout secret; secret.cur
  let previous secret = check_timeout secret; secret.prev
  let is_valid secret str = check_timeout secret; str = secret.cur || str = secret.prev
end

module Peers = Map.Make (struct type t = Addr.t let compare = compare end)

type t = {
  mutable rt : Kademlia.table;
  torrents : (SHA1.t, float Peers.t) Hashtbl.t;
  id : SHA1.t;
  port : int;
  krpc : KRPC.t
}

type query_type =
  | Ping
  | FindNode
  | GetPeers
  | Announce

let type_of_query : query -> query_type = function
  | Ping -> Ping
  | FindNode _ -> FindNode
  | GetPeers _ -> GetPeers
  | Announce _ -> Announce

let encode_query id (q : query) =
  let sha1 x = Bcode.String (SHA1.to_bin x) in
  let self = ("id", sha1 id) in
  match q with
  | Ping ->
    KRPC.Query ("ping", [self])
  | FindNode id ->
    KRPC.Query ("find_node", ["target", sha1 id; self])
  | GetPeers ih ->
    KRPC.Query ("get_peers", ["info_hash", sha1 ih; self])
  | Announce (ih, port, token) ->
    KRPC.Query ("announce",
      [ "info_hash", sha1 ih;
        "port", Bcode.Int (Int64.of_int port);
        "token", Bcode.String token;
        self ])

let query dht addr q =
  debug "query: %s %s" (Addr.to_string addr) (string_of_query q);
  KRPC.send_msg dht.krpc (encode_query dht.id q) addr >>= function
  | KRPC.Response (addr, args) ->
    let id, r = parse_response q args in
    debug "query: got response from %s (%s): %s"
      (SHA1.to_hex_short id) (Addr.to_string addr) (string_of_response r);
    Lwt.return ((id, addr), r)
  | KRPC.Timeout ->
    Lwt.fail (Failure "timeout")
  | KRPC.Error ->
    Lwt.fail (Failure "dht error")

let ping dht addr =
  Lwt.catch begin fun () ->
    query dht addr Ping >>= fun (n, r) ->
    match r with
    | Pong ->
      Lwt.return (Some n)
    | _ ->
      Lwt.return None
  end begin fun _ -> Lwt.return None end

let find_node dht addr id =
  query dht addr (FindNode id) >>= fun (n, r) ->
  match r with
  | Nodes nodes ->
    Lwt.return (n, nodes)
  | _ ->
    Lwt.fail (Failure "DHT.find_node")

let get_peers dht addr ih =
  query dht addr (GetPeers ih) >>= fun (n, r) ->
  match r with
  | Peers (token, peers, nodes) ->
    Lwt.return (n, token, peers, nodes)
  | _ ->
    Lwt.fail (Failure "DHT.get_peers")

let announce dht addr port token ih =
  query dht addr (Announce (ih, port, token)) >>= fun (n, r) ->
  match r with
  | Pong ->
    Lwt.return n
  | _ ->
    Lwt.fail (Failure "DHT.announce")

let encode_nodes l =
  let rec loop = function
    | [] -> Bitstring.empty_bitstring
    | (id, addr) :: nodes ->
      BITSTRING { SHA1.to_bin id : -1 : string;
                  Addr.to_string_compact addr : -1 : string;
                  loop nodes : -1 : bitstring }
  in
  Bitstring.string_of_bitstring (loop l)

let encode_values l =
  let rec loop = function
    | [] -> Bitstring.empty_bitstring
    | addr :: values ->
      BITSTRING { Addr.to_string_compact addr : -1 : string;
                  loop values : -1 : bitstring }
  in
  Bitstring.string_of_bitstring (loop l)

let encode_response id r : KRPC.msg =
  let sha1 x = Bcode.String (SHA1.to_bin x) in
  let self = ("id", sha1 id) in
  match r with
  | Pong ->
    KRPC.Response [ self ]
  | Nodes nodes ->
    KRPC.Response
      [ self; "nodes", Bcode.String (encode_nodes nodes) ]
  | Peers (token, peers, nodes) ->
    KRPC.Response
      [ self; "token", Bcode.String token;
        "values", Bcode.String (encode_values peers);
        "nodes", Bcode.String (encode_nodes nodes) ]

let self_get_peers dht h =
  let peers =
    try
      Peers.fold (fun p _ l -> p :: l) (Hashtbl.find dht.torrents h) []
    with
    | Not_found -> []
  in
  if List.length peers <= 100 then
    peers
  else
    let a = Array.of_list peers in
    Util.shuffle_array a;
    Array.to_list (Array.sub a 0 100)

let self_find_node dht h =
  Kademlia.find_node dht.rt h

(* do not hash port cause some broken implementations change it all the time *)
let make_token addr ih secret =
  string_of_int (Hashtbl.hash
      (Addr.Ip.to_string (Addr.ip addr), SHA1.to_bin ih, secret))

let valid_token addr ih secret token =
  let cur = Secret.current secret in
  let prev = Secret.previous secret in
  token = make_token addr ih cur || token = make_token addr ih prev

let store_peer_timeout = 30.0 *. 60.0

let store dht ih addr =
  let peers = try Hashtbl.find dht.torrents ih with Not_found -> Peers.empty in
  Hashtbl.replace dht.torrents ih (Peers.add addr (Unix.time () +. store_peer_timeout) peers)

let answer dht secret addr name args =
  let id, q = parse_query name args in
  let r = match q with
    | Ping ->
      Pong
    | FindNode nid ->
      Nodes (self_find_node dht nid)
    | GetPeers ih ->
      let token = make_token addr ih (Secret.current secret) in
      let peers = self_get_peers dht ih in
      let nodes = self_find_node dht ih in
      debug "answer: %d peers and %d nodes" (List.length peers) (List.length nodes);
      Peers (token, peers, nodes)
    | Announce (ih, port, token) ->
      if not (valid_token addr ih secret token) then
        failwith (Printf.sprintf "answer: invalid token %S" token);
      store dht ih (Addr.ip addr, port);
      Pong
  in
  debug "answer: %s (%s) : %s"
    (SHA1.to_hex_short id) (Addr.to_string addr) (string_of_response r);
  encode_response dht.id r

let update dht st id addr =
  let ping addr k = Lwt.async (fun () -> ping dht addr >|= k) in
  Kademlia.update dht.rt ping st id addr

let (!!) = Lazy.force

let create port =
  let id = SHA1.random () in
  let secret = Secret.create secret_timeout in
  let rec dht = lazy
    { rt = Kademlia.create id;
      krpc = KRPC.create (fun addr name args -> answer !!dht secret addr name args) port;
      port;
      id;
      torrents = Hashtbl.create 3 }
  in
  !!dht

let rec refresh dht =
  let ids = Kademlia.refresh dht.rt in
  debug "refresh: %d buckets" (List.length ids);
  let cb prev_id (n, l) =
    let id, addr = n in
    update dht Kademlia.Good id addr; (* replied *)
    if SHA1.compare id prev_id <> 0 then begin
      debug "refresh: node %s changed id (was %s)" (string_of_node n) (SHA1.to_hex_short prev_id);
      update dht Kademlia.Bad prev_id addr
    end;
    debug "refresh: got %d nodes from %s" (List.length l) (string_of_node n);
    List.iter (fun (id, addr) -> update dht Kademlia.Unknown id addr) l
  in
  Lwt_list.iter_p (fun (target, nodes) ->
    Lwt_list.iter_p (fun n ->
      Lwt.catch
        (fun () -> let id, addr = n in find_node dht addr target >|= cb id)
        (fun exn ->
           debug ~exn "refresh: find_node error %s" (string_of_node n);
           Lwt.return ()))
      nodes) ids >>= fun () ->
  Lwt_unix.sleep 60.0 >>= fun () -> refresh dht

let expire_timer = 60.0

let rec expire_old_peers h =
  let now = Unix.time () in
  let torrents = Hashtbl.fold (fun k peers l -> (k, peers) :: l) h [] in
  let rm = ref 0 in
  let total = ref 0 in
  List.iter (fun (id, peers) ->
    let m =
      Peers.fold begin fun peer expire m ->
        incr total;
        if expire < now then begin
          incr rm;
          Peers.remove peer m
        end
        else m
      end peers peers
    in
    if Peers.is_empty m then Hashtbl.remove h id else Hashtbl.replace h id m) torrents;
  debug "Removed %d of %d peers for announced torrents" !rm !total;
  Lwt_unix.sleep expire_timer >>= fun () -> expire_old_peers h

let start dht =
  debug "DHT size : %d self : %s" (Kademlia.size dht.rt) (SHA1.to_hex_short dht.id);
  KRPC.start dht.krpc;
  Lwt.async (fun () -> refresh dht);
  Lwt.async (fun () -> expire_old_peers dht.torrents)

module BoundedSet = struct
  module type S = sig
    type elt
    type t
    val create : int -> t
    val insert : t -> elt -> bool
    val elements : t -> elt list
    val iter : (elt -> unit) -> t -> unit
    val min_elt : t -> elt
    val is_empty : t -> bool
    val cardinal : t -> int
  end
  module Make (Ord : Set.OrderedType) : S with type elt = Ord.t = struct
    module S = Set.Make (Ord)
    type elt = Ord.t
    type t = int ref * S.t ref

    let create n = ref n, ref S.empty

    let insert (left, set) elem =
      if S.mem elem !set then false else
      if !left = 0 then
        let max = S.max_elt !set in
        if Ord.compare elem max < 0 then begin
          set := S.add elem (S.remove max !set);
          true
        end
        else false
      else begin
        set := S.add elem !set;
        decr left;
        true
      end

    let iter f (_, set) = S.iter f !set

    let elements (_, set) = S.elements !set

    let min_elt (_, set) = S.min_elt !set

    let is_empty (_, set) = S.is_empty !set

    let cardinal (_, set) = S.cardinal !set
  end
end

let lookup_node dht ?nodes target =
  debug "lookup_node: %s" (SHA1.to_hex_short target);
  let start = Unix.time () in
  let queried = Hashtbl.create 13 in
  let module BS = BoundedSet.Make
      (struct
        type t = SHA1.t * Addr.t
        let compare (h1, _) (h2, _) =
          Z.compare (SHA1.distance target h1) (SHA1.distance target h2)
      end)
  in
  let found = BS.create Kademlia.bucket_nodes in
  let next_node () =
    let x = ref None in
    try
      BS.iter begin fun node ->
        if not (Hashtbl.mem queried node) then begin
          x := Some node;
          raise Exit
        end
      end found;
      None
    with
    | Exit -> !x
  in
  let add_nodes nodes =
    List.fold_left (fun acc node -> if BS.insert found node then acc+1 else acc) 0 nodes
  in
  let query store n =
    Hashtbl.add queried n true;
    debug "lookup_node: will query node %s" (string_of_node n);
    Lwt.catch begin fun () ->
      let _, addr = n in
      find_node dht addr target >>= fun (n, nodes) ->
      let id, addr = n in
      if store then update dht Kademlia.Good id addr;
      let inserted = add_nodes nodes in
      let best =
        if BS.is_empty found then ""
        else Printf.sprintf ", best %s" (SHA1.to_hex_short (fst (BS.min_elt found)))
      in
      debug "lookup_node: got %d nodes from %s, useful %d%s"
        (List.length nodes) (string_of_node n) inserted best;
      Lwt.return ()
    end begin fun exn ->
      debug "lookup_node: timeout from %s" (string_of_node n);
      Lwt.return ()
    end
  in
  let query_loop () =
    let rec loop () =
      match next_node () with
      | Some n -> query true n >>= loop
      | None -> Lwt.return ()
    in
    let a = Array.init alpha (fun _ -> loop ()) in
    Lwt.join (Array.to_list a)
  in
  begin match nodes with
  | None ->
    let _ = add_nodes (self_find_node dht target) in
    Lwt.return ()
  | Some nodes ->
    Lwt_list.iter_p (query false) nodes
  end >>=
  query_loop >>= fun () ->
  let result = BS.elements found in
  debug "lookup_node %s done, queried %d, found %d, elapsed %ds"
    (SHA1.to_hex_short target) (Hashtbl.length queried) (List.length result)
    (truncate (Unix.time () -. start));
  Lwt.return result

let query_peers dht id k =
  debug "query_peers: start %s" (SHA1.to_hex_short id);
  lookup_node dht id >>= fun nodes ->
  debug "query_peers: found nodes %s" (strl string_of_node nodes);
  Lwt_list.iter_p begin fun n ->
    Lwt.catch
      (fun () ->
         get_peers dht (snd n) id >|= fun (node, token, peers, nodes) ->
         debug "query_peers: got %d peers and %d nodes from %s with token %S"
           (List.length peers) (List.length nodes) (string_of_node node) token;
         k n token peers)
      (fun exn ->
         debug ~exn "query_peers: get_peers error from %s" (string_of_node n);
         Lwt.return ())
  end nodes
    
let bootstrap dht addr =
  ping dht addr >>= function
  | Some n ->
    debug "bootstrap node %s (%s) is up" (string_of_node n) (Addr.to_string addr);
    lookup_node dht ~nodes:[n] dht.id >>= fun l ->
    debug "bootstrap via %s : found %s" (Addr.to_string addr) (strl string_of_node l);
    Lwt.return (List.length l >= Kademlia.bucket_nodes)
  | None ->
    debug "bootstrap node %s is down" (Addr.to_string addr);
    Lwt.return false

let bootstrap dht (host, port) =
  Lwt.catch
    (fun () -> Addr.Ip.of_string_noblock host >>= fun ip -> bootstrap dht (ip, port))
    (fun exn -> debug ~exn "bootstrap error"; Lwt.return false)

let rec auto_bootstrap dht routers =
  lookup_node dht dht.id >>= fun l ->
  debug "auto bootstrap : found %s" (strl string_of_node l);
  let rec loop l ok =
    match l, ok with
    | _, true ->
      debug "bootstrap ok, total nodes : %d" (Kademlia.size dht.rt);
      Lwt.return ()
    | [], false ->
      debug "bootstrap failed, total nodes : %d; retrying" (Kademlia.size dht.rt);
      auto_bootstrap dht routers
    | n :: ns, false ->
      bootstrap dht n >>= loop ns
  in
  loop routers (List.length l >= Kademlia.bucket_nodes)

let bootstrap_nodes =
  [ "router.bittorrent.com", 6881;
    "dht.transmissionbt.com", 6881 ]
   