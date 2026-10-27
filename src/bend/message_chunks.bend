# SPDX-License-Identifier: Apache-2.0
# Lossless UTF-8 byte chunks at the same common-cluster boundaries as TimUI.
# An indivisible cluster larger than the envelope rejects the entire message.
import Base
import ./irc.bend as Irc
import ./columns.bend as Columns

def finish(+head: String, +chunks: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  Some{List.reverse(&2, String,
    Bool.pick(List<&2, String>, String.is_empty(head) && Bool.not(List.is_empty(&2, String, chunks)),
      chunks, String.reverse(head) <> chunks))}

# One utf8_len per cluster (D239): the cluster is sized once per call and the
# checks below reuse that size instead of re-walking the text per check.
def piece.sized_used(fitsok: Bool, +used: Nat, source: String, +text: String, tail: String, head: String, chunks: List<&2, String>, +bound: Nat, k: String -> Nat -> String -> List<&2, String> -> Nat -> Maybe<&2, List<&2, String>>, +size: Nat) -> Maybe<&2, List<&2, String>>:
  match fitsok:
    case False{}:
      k(source, 0n, "", String.reverse(head) <> chunks, bound)
    case True{}:
      k(tail, Nat.add(used, size), String.reverse(text) ++ head, chunks, Nat.sub(bound, String.length(text)))

def piece.sized_cap(ok: Bool, +cap: Nat, +used: Nat, source: String, +text: String, tail: String, head: String, chunks: List<&2, String>, +bound: Nat, k: String -> Nat -> String -> List<&2, String> -> Nat -> Maybe<&2, List<&2, String>>, +size: Nat) -> Maybe<&2, List<&2, String>>:
  match ok:
    case False{}: None{}
    case True{}:
      piece.sized_used(Nat.is_le(Nat.add(used, size), cap), used, source, text, tail, head, chunks, bound, k, size)

def piece(+cap: Nat, used: Nat, source: String, cut: Columns.Cut, head: String, chunks: List<&2, String>, +bound: Nat, k: String -> Nat -> String -> List<&2, String> -> Nat -> Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match cut:
    case Columns.Cut{+text, tail, _}:
      +size = Irc.utf8_len(text)
      piece.sized_cap(Nat.is_le(size, cap), cap, used, source, text, tail, head, chunks, bound, k, size)

# `bound` is the residual scalar count from the one String.length in split.
# Each taken cluster shrinks it. A chunk break retries the same bound.
def split.go(fuel: Nat, s: String, +cap: Nat, used: Nat, head: String, chunks: List<&2, String>, +bound: Nat) -> Maybe<&2, List<&2, String>>:
  match fuel:
    case 0n: None{}
    case 1n+p:
      match s:
        case SNil{}: finish(head, chunks)
        case SCon{+h, +t}:
          piece(cap, used, SCon{h, t}, Columns.cluster_bounded(SCon{h, t}, bound), head, chunks, bound,
            rest => bytes => acc => done => next => split.go(p, rest, cap, bytes, acc, done, next))

def split(+s: String, cap: Nat) -> Maybe<&2, List<&2, String>>:
  +n = String.length(s)
  split.go(Nat.add(2n, Nat.mul(2n, n)), s, cap, 0n, "", Nil{}, n)
