open Lwt.Infix

exception Failure of Yojson.Basic.json

type 'a result =
  | Ok of 'a
  | Error of Yojson.Basic.json

module YB = Yojson.Basic

module Priv = struct
  type data =
    | Rsa of Nocrypto.Rsa.priv
  type t = {
    purpose: string;
    data: data;
  }
end

type priv = Priv.t

module Pub = struct
  type data =
    | Rsa of Nocrypto.Rsa.pub
  type t = {
    purpose: string;
    data: data;
  }
end

type pub = Pub.t

module Padding = struct
  type t =
    | None
    | PKCS1
    (* | OAEP *)
    (* | PSS *)
end

type storage = (string * Priv.t) list Lwt_mvar.t


(* helper functions *)

let failwith json:YB.json =
  raise (Failure json)

let failwith_desc desc =
  raise (Failure (`Assoc [
    ("description", `String desc)
  ]))

let failwith_missing keys =
  let l = List.map (fun x -> `String x) keys in
  raise (Failure (`Assoc [
    ("description", `String "JSON keys are missing");
    ("missing", `List l)
  ]))

let rem_opt = function
  | Some x -> x
  | None -> assert false

let pub_of_priv { Priv.purpose; data } =
  let data = match data with
    | Priv.Rsa d -> Pub.Rsa (Nocrypto.Rsa.pub_of_priv d)
  in
  { Pub.purpose; data }

let trim_tail s =
  let rec f n = if n>=0 && s.[n]='\000' then f (pred n) else n in
  let len = String.length s |> pred |> f |> succ in
  String.sub s 0 len

let b64_encode = B64.encode ~alphabet:B64.uri_safe_alphabet

let b64_decode = B64.decode ~alphabet:B64.uri_safe_alphabet

let b64_of_z z =
  Nocrypto.Numeric.Z.to_cstruct_be z |> Cstruct.to_string |> b64_encode

let z_of_b64 s =
  b64_decode s |> Cstruct.of_string |> Nocrypto.Numeric.Z.of_cstruct_be

(* let pq_of_ned n e d =
  let open Z in
  let de = e*d in
  let modplus1 = n + one in
  let deminus1 = de - one in
  let kprima = de/n in
  let ks = [kprima; kprima + one; kprima - one] in
  let rec f = function
    | [] -> assert false
    | k :: rest -> let fi = deminus1 / k in
      let pplusq = modplus1 - fi in
      let delta = pplusq*pplusq - n*(of_int 4) in
      let sqr = sqrt delta in
      let p = (pplusq + sqr)/(of_int 2) in
      if (n mod p) = Z.zero && p > zero
        then let q = (pplusq - sqr)/(of_int 2) in
          (p, q)
        else f rest
  in
  f ks *)

let string_of_json_key json key =
  try
    YB.Util.member key json |> YB.Util.to_string
  with
    YB.Util.Type_error _ -> failwith_missing [key]

let rsa_priv_of_json json =
  let e = string_of_json_key json "publicExponent" |> z_of_b64 in
  let p = string_of_json_key json "primeP" |> z_of_b64 in
  let q = string_of_json_key json "primeQ" |> z_of_b64 in
  Priv.Rsa (Nocrypto.Rsa.priv_of_primes e p q)

let priv_of_json json =
  let purpose = string_of_json_key json "purpose" in
  let algorithm = string_of_json_key json "algorithm" in
  let data_json = YB.Util.member "privateKey" json in
  let length =
    try
      Some (YB.Util.member "length" json |> YB.Util.to_int)
    with
      YB.Util.Type_error _ -> None
  in
  let data = match (algorithm, data_json, length) with
    | ("RSA", (`Assoc _ as j), None) -> rsa_priv_of_json j
    | ("RSA", `Null, Some l) -> Priv.Rsa (Nocrypto.Rsa.generate l)
    | ("RSA", _, _)
      -> failwith_missing ["privateKey"; "length"]
    | _ -> failwith_desc ("Unknown key type: " ^ algorithm)
  in
  { Priv.purpose; data }

(* let priv_of_pem s =
  Cstruct.of_string s |> X509.Encoding.Pem.Private_key.of_pem_cstruct1
    |> function `RSA key -> key *)



(* Simple database to store the items *)

module Db = struct
  let create () =
    Random.init @@ Nocrypto.Rng.Int.gen_bits 32;
    Lwt_mvar.create []

  (* let id  = ref 0 *)
  let rec new_id l =
    let n = 20 in
    let alphanum =
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" in
    let len = String.length alphanum in
    let id = Bytes.create n in
    for i=0 to pred n do
      Bytes.set id i alphanum.[Random.int len]
    done;
    if (List.mem_assoc id l) then
      new_id l
    else
      id

  let with_db db ~f =
    Lwt_mvar.take db   >>= fun l ->
      let result, l' = f l in
      Lwt_mvar.put db l' >|= fun () ->
        result

  let get db id =
    with_db db ~f:(fun l ->
      if (List.mem_assoc id l) then
        (Some (List.assoc id l), l)
      else
        (None, l))

  let get_all db =
    with_db db ~f:(fun l -> (l, l))

  let add db e =
    with_db db ~f:(fun l ->
      let id = new_id l in
      let l' = List.merge (fun x y -> compare (fst x) (fst y)) [id, e] l in
      (id, l'))

  let put db id e =
    let found = ref false in
    with_db db ~f:(fun l ->
      let l' = List.map (fun (id', e') ->
        if id' = id
          then begin found := true; (id', e) end
          else (id', e'))
        l
      in
      (!found, l'))

  let delete db id =
    let deleted = ref false in
    with_db db ~f:(fun l ->
      let l' = List.filter (fun (id', _) ->
        if id' = id
          then begin deleted := true; false end
          else true)
        l
      in
      (!deleted, l'))
end



(******************** public functions ********************)

let pem_of_pub { Pub.data } =
  let Pub.Rsa k = data in
  `RSA k |> X509.Encoding.Pem.Public_key.to_pem_cstruct1 |> Cstruct.to_string

let json_of_pub { Pub.purpose; data } =
  let json_hd = [
    ("purpose", `String purpose);
    ]
  in
  let json_data = match data with
    | Pub.Rsa { Nocrypto.Rsa.e; n} -> [
      ("algorithm", `String "RSA");
      ("publicKey", `Assoc [
        ("modulus", `String (b64_of_z n));
        ("publicExponent", `String (b64_of_z e));
        ])
      ]
  in
  `Assoc (json_hd @ json_data)

let create () = Db.create ()

let add ks ~key =
  try
    priv_of_json key |> Db.add ks >|= fun x -> Ok x
  with
  | Failure json -> Lwt.return (Error json)

let put ks ~id ~key =
  try
    priv_of_json key |> Db.put ks id >|= fun x -> Ok x
  with
  | Failure json -> Lwt.return (Error json)

let del ks ~id = Db.delete ks id

let get ks ~id = Db.get ks id >|= function
  | None -> None
  | Some k -> Some (pub_of_priv k)

let get_all ks = Db.get_all ks >|= List.map (fun (id, key) ->
    (id, pub_of_priv key))

let decrypt ks ~id ~padding ~data =
  Db.get ks id
  >|= rem_opt
  >|= fun key ->
  try
    let encrypted =
      try
        YB.Util.member "encrypted" data
        |> YB.Util.to_string
        |> b64_decode
        |> Cstruct.of_string
      with
        | YB.Util.Type_error _
          -> failwith_missing ["encrypted"]
    in
    let decrypted_opt =
      match (key, padding) with
      | ({ Priv.data=(Priv.Rsa key) }, Padding.None)
        -> Some (Nocrypto.Rsa.decrypt ~key ~mask:`Yes encrypted)
      | ({ Priv.data=(Priv.Rsa key) }, Padding.PKCS1)
        -> Nocrypto.Rsa.PKCS1.decrypt ~key ~mask:`Yes encrypted
    in
    match decrypted_opt with
      | Some decrypted ->
        let decrypted_b64 = Cstruct.to_string decrypted |> b64_encode in
        Ok (`Assoc [
          ("decrypted", `String decrypted_b64)
        ])
      | None -> failwith_desc "decryption failed"
  with
    | Failure json -> Error json

let sign ks ~id ~padding ~data =
  Db.get ks id
  >|= rem_opt
  >|= fun key ->
  try
    let message =
      try
        YB.Util.member "message" data
        |> YB.Util.to_string
        |> b64_decode
        |> Cstruct.of_string
      with
        | YB.Util.Type_error _
          -> failwith_missing ["message"]
    in
    let signed =
      match (key, padding) with
      | ({ Priv.data=(Priv.Rsa key) }, Padding.PKCS1) ->
        begin
          try Nocrypto.Rsa.PKCS1.sig_encode ~key ~mask:`Yes message
          with Nocrypto.Rsa.Insufficient_key
            -> failwith_desc "insufficient key for message"
        end
      | (_, Padding.None)
        -> failwith_desc "invalid padding"
    in
    let signed_b64 = Cstruct.to_string signed |> b64_encode in
      Ok (`Assoc ["signedMessage", `String signed_b64])
  with
    | Failure json -> Error json
