# SPDX-License-Identifier: Apache-2.0
# Pure IPv4/DNS HOST[:PORT] syntax shared by CLI and /connect. IPv6 is not
# supported. Keep host spelling/root dot for endpoint and credential identity.
import Base
import ./dns_wire.bend as Wire

type Endpoint is Data:
  Endpoint{host: String, port: Maybe<&2, U32>}

def MAX_INPUT() -> Nat:
  260n

def ascii_word(+c: U32) -> Bool:
  (U32.is_ge(c, 65) && U32.is_le(c, 90))
    || (U32.is_ge(c, 97) && U32.is_le(c, 122))
    || (U32.is_ge(c, 48) && U32.is_le(c, 57)) || U32.is_eq(c, 45)

def chars(s: String, +endpoint: Bool) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{Chr{+c}, t}:
      (ascii_word(c) || (endpoint && (U32.is_eq(c, 46) || U32.is_eq(c, 58)))) && chars(t, endpoint)

def labels(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}: True{}
    case Con{+h, t}:
      Nat.is_ge(String.length(h), 1n) && Nat.is_le(String.length(h), 63n)
        && chars(h, False{}) && labels(t)

# Single validating walk (D157): one pass over the hostname checks the
# character class, counts every label (1..63) and the total (<=253), and
# collects the normalized labels. The old shape validated the same bytes
# three-plus times: without_root_dot reversed twice, host_ok walked the
# clean length twice, and labels re-walked every label with chars plus two
# length walks each. Only a terminal root dot is stripped; any other empty
# label (leading, doubled, or bare ".") fails closed, matching labels().
# Recursion lives only in host_labels.go; the step helpers take a
# continuation, so no helper calls a later definition.
def host_labels.done(ok: Bool, +labs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match ok:
    case True{}:
      Some{List.reverse(&2, String, labs)}
    case False{}:
      None{}

def host_labels.end(+cur: String, +labs: List<&2, String>, +lab_len: Nat, +total: Nat) -> Maybe<&2, List<&2, String>>:
  match lab_len:
    case 0n:
      None{}
    case 1n+p:
      host_labels.done(Nat.is_le(1n+p, 63n) && Nat.is_le(total, 253n), String.reverse(cur) <> labs)

def host_labels.mid(empty: Bool, bounded: Bool, +cur: String, +labs: List<&2, String>, +total: Nat, k: String -> List<&2, String> -> Nat -> Nat -> Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match empty:
    case True{}:
      None{}
    case False{}:
      match bounded:
        case True{}:
          k("", String.reverse(cur) <> labs, 0n, 1n+total)
        case False{}:
          None{}

def host_labels.step(dot: Bool, word: Bool, last: Bool, +h: Char, +t: String, +cur: String, +labs: List<&2, String>, +lab_len: Nat, +total: Nat, k: String -> List<&2, String> -> Nat -> Nat -> Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match dot:
    case True{}:
      match last:
        case True{}:
          host_labels.end(cur, labs, lab_len, total)
        case False{}:
          host_labels.mid(Nat.is_eq(lab_len, 0n), Nat.is_le(lab_len, 63n), cur, labs, total, k)
    case False{}:
      match word:
        case True{}:
          k(SCon{h, cur}, labs, 1n+lab_len, 1n+total)
        case False{}:
          None{}

def host_labels.go(+s: String, +cur: String, +labs: List<&2, String>, +lab_len: Nat, +total: Nat) -> Maybe<&2, List<&2, String>>:
  match s:
    case SNil{}:
      host_labels.end(cur, labs, lab_len, total)
    case SCon{+h, t}:
      +n = Char.to_u32(h)
      host_labels.step(U32.is_eq(n, 46), ascii_word(n), String.is_empty(t), h, t, cur, labs, lab_len, total, c2 => labs2 => len2 => tot2 => host_labels.go(t, c2, labs2, len2, tot2))

def host_labels(+host: String) -> Maybe<&2, List<&2, String>>:
  host_labels.go(host, "", Nil{}, 0n, 0n)

def host_labels.some(got: Maybe<&2, List<&2, String>>) -> Bool:
  match got:
    case Some{_}:
      True{}
    case None{}:
      False{}

def host_ok(+host: String) -> Bool:
  host_labels.some(host_labels(host))

# Shared IRC server-prefix shape for Auth and CapNotify. Empty prefixes carry
# no attestation and fail closed; peer binding stays at the transport/endpoint.
def server_source(+prefix: String) -> Bool:
  host_ok(prefix)

# ASCII digits only. Shared by endpoint ports and ISUPPORT numeric tokens.
def decimal(s: String) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{Chr{+c}, t}:
      U32.is_ge(c, 48) && U32.is_le(c, 57) && decimal(t)

def port.range(n: U32, valid: Bool) -> Maybe<&2, U32>:
  match valid:
    case True{}: Some{n}
    case False{}: None{}

def port.read(got: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match got:
    case None{}: None{}
    case Some{+n}: port.range(n, U32.is_ge(n, 1) && U32.is_le(n, 65535))

def port.valid(+text: String, valid: Bool) -> Maybe<&2, U32>:
  match valid:
    case False{}: None{}
    case True{}: port.read(U32.read(text))

# Leading zeros remain valid, as with the existing numeric CLI flags.
# Single validating read (D172): one walk rejects non-digits and accumulates
# the value, replacing the decimal pre-walk plus the U32.read re-walk. The
# accumulator saturates at 100000 (past any valid port), so over-long digit
# strings fail the same range gate; empty input yields 0 and fails closed
# like before. The digit helper takes a continuation, so no helper calls a
# later definition.
def port.cap(big: Bool, +v: U32) -> U32:
  match big:
    case True{}: 100000
    case False{}: v

def port.next(+acc: U32, +n: U32) -> U32:
  +d = U32.sub(n, 48)
  +v = U32.add(U32.mul(acc, 10), d)
  port.cap(U32.is_gt(v, 100000), v)

def port.digit(digit: Bool, +n: U32, +acc: U32, k: U32 -> Maybe<&2, U32>) -> Maybe<&2, U32>:
  match digit:
    case False{}: None{}
    case True{}: k(port.next(acc, n))

def port.go(+s: String, +acc: U32) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      port.range(acc, U32.is_ge(acc, 1) && U32.is_le(acc, 65535))
    case SCon{+h, t}:
      port.digit(U32.is_ge(Char.to_u32(h), 48) && U32.is_le(Char.to_u32(h), 57), Char.to_u32(h), acc, a2 => port.go(t, a2))

def port(+text: String) -> Maybe<&2, U32>:
  port.go(text, 0)

def parse.host(valid: Bool, host: String, port: Maybe<&2, U32>) -> Result<&2, &2, String, Endpoint>:
  match valid:
    case False{}: Fail{"bad endpoint"}
    case True{}: Done{Endpoint{host, port}}

def parse.port(got: Maybe<&2, U32>, +host: String) -> Result<&2, &2, String, Endpoint>:
  match got:
    case None{}: Fail{"bad port"}
    case Some{n}: parse.host(host_ok(host), host, Some{n})

def parse.parts(parts: List<&2, String>) -> Result<&2, &2, String, Endpoint>:
  match parts:
    case Con{+host, Nil{}}: parse.host(host_ok(host), host, None{})
    case Con{+host, Con{text, Nil{}}}: parse.port(port(text), host)
    case _: Fail{"bad endpoint"}

def parse.valid(+text: String, valid: Bool) -> Result<&2, &2, String, Endpoint>:
  match valid:
    case False{}: Fail{"bad endpoint"}
    case True{}: parse.parts(String.split(text, Chr{58}))

# The shorthand cap covers 254 host bytes, ':', and five canonical port digits.
# Shorter hosts may use extra leading zeros within the same bound.
def parse(+text: String) -> Result<&2, &2, String, Endpoint>:
  parse.valid(text, Nat.is_le(String.length(text), MAX_INPUT()) && chars(text, True{}))

def select_port.same(same: Bool, port: U32) -> Maybe<&2, U32>:
  match same:
    case False{}: None{}
    case True{}: Some{port}

def select_port(inline: Maybe<&2, U32>, separate: Maybe<&2, U32>, fallback: U32) -> Maybe<&2, U32>:
  match inline:
    case None{}:
      match separate:
        case None{}: Some{fallback}
        case Some{n}: Some{n}
    case Some{+n}:
      match separate:
        case None{}: Some{n}
        case Some{m}: select_port.same(U32.is_eq(n, m), n)

def resolve.selected(selected: Maybe<&2, U32>, host: String) -> Maybe<&1, String & U32>:
  match selected:
    case None{}: None{}
    case Some{n}: Some{(host, n)}

def resolve(endpoint: Endpoint, separate: Maybe<&2, U32>, fallback: U32) -> Maybe<&1, String & U32>:
  match endpoint:
    case Endpoint{host, port}: resolve.selected(select_port(port, separate, fallback), host)

# History records and credentials both scope on this string. Keep host
# spelling and a terminal DNS root dot byte-for-byte: no case folding, no
# dot stripping. SNI normalization is a different step.
def endpoint(+host: String, +port: U32) -> String:
  host ++ ":" ++ U32.show(port)
