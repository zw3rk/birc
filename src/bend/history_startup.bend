# SPDX-License-Identifier: Apache-2.0
# Import a completed startup snapshot into the current preconnect client.
import Base
import ./buffer.bend as Cl
import ./history.bend as H
import ./irc.bend as Irc

# Temporary archive IDs establish file order only. Import assigns new global
# IDs after all current local events, without replaying diagnostic mirrors.
type Import is Data:
  Import{client: Cl.Client, entries: List<&2, H.HistEntry>, seen: List<&2, String>}

def operation_ids.keep(nonzero: Bool, id: Nat, rest: List<&2, Nat>) -> List<&2, Nat>:
  match nonzero:
    case True{}: id <> rest
    case False{}: rest

def operation_ids.lines(lines: List<&2, Cl.Line>) -> List<&2, Nat>:
  match lines:
    case Nil{}: Nil{}
    case Con{Cl.Line{Cl.Error{}, _, _, _, +id}, rest}:
      operation_ids.keep(Bool.not(Nat.is_eq(id, 0n)), id, operation_ids.lines(rest))
    case Con{_, rest}: operation_ids.lines(rest)

def operation_ids.buffers(bufs: List<&2, Cl.Buffer>) -> List<&2, Nat>:
  match bufs:
    case Nil{}: Nil{}
    case Con{Cl.Buffer{_, _, _, lines, _, _, _, _}, rest}:
      List.append(&2, Nat, operation_ids.lines(lines), operation_ids.buffers(rest))

def operation_ids(snapshot: Cl.Client) -> List<&2, Nat>:
  operation_ids.buffers(Cl.log_buffers(snapshot))

# `ids` is ascending (install.allowed sorts operation_ids once below), so
# the scan stops past the target instead of walking the whole ledger per
# line. Membership results match the old linear scan on sorted input.
def operation_id.go(eq: Bool, past: Bool, rest: Unit -> Bool) -> Bool:
  match eq:
    case True{}: True{}
    case False{}:
      match past:
        case True{}: False{}
        case False{}: rest(Unit{})

def operation_id(ids: List<&2, Nat>, +id: Nat) -> Bool:
  match ids:
    case Nil{}: False{}
    case Con{+head, rest}: operation_id.go(Nat.is_eq(head, id), Nat.is_gt(head, id), _ => operation_id(rest, id))

def operation_line(line: Cl.Line, ids: List<&2, Nat>) -> Bool:
  match line:
    case Cl.Line{_, _, _, _, +id}: Bool.not(Nat.is_eq(id, 0n)) && operation_id(ids, id)

def strip_operations.keep(skip: Bool, line: Cl.Line, rest: List<&2, Cl.Line>) -> List<&2, Cl.Line>:
  match skip:
    case True{}: rest
    case False{}: line <> rest

def strip_operations(lines: List<&2, Cl.Line>, +ids: List<&2, Nat>) -> List<&2, Cl.Line>:
  match lines:
    case Nil{}: Nil{}
    case Con{+line, rest}: strip_operations.keep(operation_line(line, ids), line, strip_operations(rest, ids))

def snapshot.buffers(bufs: List<&2, Cl.Buffer>, +ids: List<&2, Nat>) -> List<&2, Cl.Buffer>:
  match bufs:
    case Nil{}: Nil{}
    case Con{Cl.Buffer{name, channel, topic, lines, nicks, scroll, _, _}, rest}:
      Cl.buf_indexed(name, channel, topic, strip_operations(lines, ids), nicks, scroll) <> snapshot.buffers(rest, ids)

def archive_lines.keep(skip: Bool, line: Cl.Line, rest: List<&2, Cl.Line>) -> List<&2, Cl.Line>:
  match skip:
    case True{}: rest
    case False{}: line <> rest

def archive_lines(lines: List<&2, Cl.Line>) -> List<&2, Cl.Line>:
  match lines:
    case Nil{}: Nil{}
    case Con{+line, rest}:
      match line:
        case Cl.Line{+kind, _, _, _, _}:
          archive_lines.keep(Cl.is_reconnect(kind) || Cl.is_link_result(kind), line, archive_lines(rest))

# Presence probe without allocating a filtered copy: admit only needs to
# know whether any importable row exists. The single filtered copy is built
# once downstream in collect.buffer; the admit pass keeps no copy. The
# recursion rides a lazy Unit thunk so the match stays on parameters.
def archive_has.go(skip: Bool, more: Unit -> Bool) -> Bool:
  match skip:
    case True{}: more(Unit{})
    case False{}: True{}

def archive_has(lines: List<&2, Cl.Line>) -> Bool:
  match lines:
    case Nil{}: False{}
    case Con{Cl.Line{+kind, _, _, _, _}, rest}:
      archive_has.go(Cl.is_reconnect(kind) || Cl.is_link_result(kind), _ => archive_has(rest))

def seen(names: List<&2, String>, +name: String) -> Bool:
  match names:
    case Nil{}: False{}
    case Con{head, rest}: Irc.ieq(head, name) || seen(rest, name)

# Clamp the cap in the U32 domain before any Nat conversion, and size the
# room from the stored buffer count instead of re-walking the spine.
def capped_cap(+cap: U32) -> U32:
  Bool.pick(U32, U32.is_ge(cap, 1024), 1024, cap)

def room(got: Maybe<&2, Cl.Buffer>, +cap: U32) -> Nat:
  match got:
    case None{}: 0n
    case Some{Cl.Buffer{_, _, _, _, _, _, _, +count}}:
      Cl.clamp_nat(U32.to_nat(capped_cap(cap)), Nat.sub(Cl.SCROLL_CAP(), count))

def target.create(ok: Bool, +cl: Cl.Client, +name: String) -> Cl.Client & Maybe<&2, Nat>:
  match ok:
    case False{}: (cl, None{})
    case True{}: Cl.buf_get(cl, name, Cl.target_channel(name), True{})

def target.found(found: Maybe<&2, Nat>, +cl: Cl.Client, +name: String) -> Cl.Client & Maybe<&2, Nat>:
  match found:
    case Some{index}: (cl, Some{index})
    case None{}:
      +bufs = Cl.client_bufs(cl)
      target.create(Nat.is_lt(Cl.buf_count(bufs), Cl.MAX_BUFFERS()) && Nat.is_lt(Cl.normal_buffer_count(bufs), Cl.NORMAL_BUFFERS()), cl, name)

def target(control: Bool, +cl: Cl.Client, +name: String) -> Cl.Client & Maybe<&2, Nat>:
  match control:
    case True{}: (cl, Some{0n})
    case False{}: target.found(Cl.buf_find(cl, name), cl, name)

# Single indexed tail pass: one recursion returns (length, suffix), so the
# trim needs no separate length walk plus drop walk. The suffix decision is
# a match (lazy arms), not a Bool.pick over two recursive values.
def trim_tail.pick(over: Bool, +h: Cl.Line, +suffix: List<&2, Cl.Line>) -> List<&2, Cl.Line>:
  match over:
    case True{}: suffix
    case False{}: h <> suffix

def trim_tail.len(+len: Nat, +h: Cl.Line, +suffix: List<&2, Cl.Line>, +keep: Nat) -> Nat & List<&2, Cl.Line>:
  (len, trim_tail.pick(Nat.is_gt(len, keep), h, suffix))

def trim_tail.up(pair: Nat & List<&2, Cl.Line>, +h: Cl.Line, +keep: Nat) -> Nat & List<&2, Cl.Line>:
  match pair:
    case (+len_t, +suffix_t): trim_tail.len(1n+len_t, h, suffix_t, keep)

def trim_tail.go(lines: List<&2, Cl.Line>, +keep: Nat) -> Nat & List<&2, Cl.Line>:
  match lines:
    case Nil{}: (0n, Nil{})
    case Con{+h, t}: trim_tail.up(trim_tail.go(t, keep), h, keep)

def trim_tail.out(pair: Nat & List<&2, Cl.Line>) -> List<&2, Cl.Line>:
  match pair:
    case (_, +suffix): suffix

def trim_tail(lines: List<&2, Cl.Line>, +keep: Nat) -> List<&2, Cl.Line>:
  trim_tail.out(trim_tail.go(lines, keep))

def collect.target(pair: Cl.Client & Maybe<&2, Nat>, entries: List<&2, H.HistEntry>, +names: List<&2, String>, +name: String, +lines: List<&2, Cl.Line>, +control: Bool, cap: U32) -> Import:
  match pair:
    case (cl, None{}): Import{cl, entries, names}
    case (+cl, Some{+index}):
      +kept = trim_tail(lines, room(Cl.nth_buf(Cl.client_bufs(cl), index), cap))
      Import{cl, List.append(&2, H.HistEntry, H.new_entries.lines(kept, name, control), entries),
        Bool.pick(List<&2, String>, control, names, name <> names)}

def collect.nonempty(empty: Bool, acc: Import, +name: String, lines: List<&2, Cl.Line>, +control: Bool, cap: U32) -> Import:
  match empty:
    case True{}: acc
    case False{}:
      match acc:
        case Import{cl, entries, names}: collect.target(target(control, cl, name), entries, names, name, lines, control, cap)

def collect.allowed(ok: Bool, acc: Import, +name: String, +lines: List<&2, Cl.Line>, +control: Bool, cap: U32) -> Import:
  match ok:
    case False{}: acc
    case True{}: collect.nonempty(List.is_empty(&2, Cl.Line, lines), acc, name, lines, control, cap)

def collect.buffer(+acc: Import, b: Cl.Buffer, +control: Bool, cap: U32) -> Import:
  match acc:
    case Import{_, _, names}:
      match b:
        case Cl.Buffer{+name, _, _, lines, _, _, _, _}:
          collect.allowed((control || (Cl.target_wire(name) && Bool.not(String.is_empty(name))))
            && (control || Bool.not(seen(names, name))), acc, name, archive_lines(lines), control, cap)

def collect.when(ok: Bool, +acc: Import, +b: Cl.Buffer, +cap: U32) -> Import:
  match ok:
    case False{}: acc
    case True{}: collect.buffer(acc, b, False{}, cap)

def import_client(acc: Import) -> Cl.Client:
  match acc:
    case Import{cl, _, _}: cl

def admit.present(got: Maybe<&2, Nat>) -> Bool:
  match got:
    case None{}: False{}
    case Some{_}: True{}

# Thread the presence-check index into the import: the gate find and the
# target find walk the same client spine with no mutation between them, so
# a present index is reused instead of re-walked.
def collect.target_reuse(+cl: Cl.Client, +index: Nat, entries: List<&2, H.HistEntry>, +names: List<&2, String>, +name: String, +lines: List<&2, Cl.Line>, +control: Bool, cap: U32) -> Import:
  +kept = trim_tail(lines, room(Cl.nth_buf(Cl.client_bufs(cl), index), cap))
  Import{cl, List.append(&2, H.HistEntry, H.new_entries.lines(kept, name, control), entries),
    Bool.pick(List<&2, String>, control, names, name <> names)}

def collect.nonempty_reuse(empty: Bool, acc: Import, +name: String, lines: List<&2, Cl.Line>, +control: Bool, cap: U32, +index: Nat) -> Import:
  match empty:
    case True{}: acc
    case False{}:
      match acc:
        case Import{cl, entries, names}: collect.target_reuse(cl, index, entries, names, name, lines, control, cap)

def collect.allowed_reuse(ok: Bool, acc: Import, +name: String, +lines: List<&2, Cl.Line>, +control: Bool, cap: U32, +index: Nat) -> Import:
  match ok:
    case False{}: acc
    case True{}: collect.nonempty_reuse(List.is_empty(&2, Cl.Line, lines), acc, name, lines, control, cap, index)

def collect.buffer_reuse(+acc: Import, b: Cl.Buffer, +control: Bool, cap: U32, +index: Nat) -> Import:
  match acc:
    case Import{_, _, names}:
      match b:
        case Cl.Buffer{+name, _, _, lines, _, _, _, _}:
          collect.allowed_reuse((control || (Cl.target_wire(name) && Bool.not(String.is_empty(name))))
            && (control || Bool.not(seen(names, name))), acc, name, archive_lines(lines), control, cap, index)

def collect.chosen_reuse(+found: Maybe<&2, Nat>, +acc: Import, +b: Cl.Buffer, +picked: List<&2, String>, +cap: U32) -> Import:
  match found:
    case Some{+index}: collect.buffer_reuse(acc, b, False{}, cap, index)
    case None{}:
      match b:
        case Cl.Buffer{+name, _, _, _, _, _, _, _}:
          collect.when(seen(picked, name), acc, b, cap)

def collect.chosen(+acc: Import, +b: Cl.Buffer, +picked: List<&2, String>, +cap: U32) -> Import:
  match b:
    case Cl.Buffer{+name, _, _, _, _, _, _, _}:
      collect.chosen_reuse(Cl.buf_find(import_client(acc), name), acc, b, picked, cap)

def collect.ordered(bufs: List<&2, Cl.Buffer>, acc: Import, +picked: List<&2, String>, +cap: U32) -> Import:
  match bufs:
    case Nil{}: acc
    case Con{+b, +rest}: collect.ordered(rest, collect.chosen(acc, b, picked, cap), picked, cap)

def recent_id(b: Cl.Buffer) -> Nat:
  match b:
    case Cl.Buffer{_, _, _, lines, _, _, _, _}: H.last_id(archive_lines(lines))

def recent(a: Cl.Buffer, b: Cl.Buffer) -> Bool:
  Nat.is_ge(recent_id(a), recent_id(b))

# Decorate once before sorting: the comparator above recomputed recent_id
# (a full archive-filter + last_id walk) per comparison, quadratic over the
# import set. Key each buffer once, sort by the key, strip the keys.
type RecentKey is Data:
  RecentKey{id: Nat, buf: Cl.Buffer}

def recent_key(+b: Cl.Buffer) -> RecentKey:
  RecentKey{recent_id(b), b}

def recent_key_buf(+k: RecentKey) -> Cl.Buffer:
  match k:
    case RecentKey{_, +buf}: buf

def recent_keyed_id(+k: RecentKey) -> Nat:
  match k:
    case RecentKey{+id, _}: id

def recent_key_le(a: RecentKey, b: RecentKey) -> Bool:
  Nat.is_ge(recent_keyed_id(a), recent_keyed_id(b))

def recent_keys(bufs: List<&2, Cl.Buffer>) -> List<&2, RecentKey>:
  match bufs:
    case Nil{}: Nil{}
    case Con{+b, t}: recent_key(b) <> recent_keys(t)

def recent_unkeyed(keys: List<&2, RecentKey>) -> List<&2, Cl.Buffer>:
  match keys:
    case Nil{}: Nil{}
    case Con{+k, t}: recent_key_buf(k) <> recent_unkeyed(t)

def sort_recent(bufs: List<&2, Cl.Buffer>) -> List<&2, Cl.Buffer>:
  recent_unkeyed(List.sort(~RecentKey, ~recent_key_le, recent_keys(bufs)))

def restore.at(got: Maybe<&2, Nat>, cl: Cl.Client, line: Cl.Line) -> Cl.Client:
  match got:
    case None{}: cl
    case Some{index}: H.apply_entry.bi(cl, index, line)

def restore(entry: H.HistEntry, +cl: Cl.Client) -> Cl.Client:
  match entry:
    case H.ServerEntry{line}: H.apply_entry.bi(cl, 0n, line)
    case H.Entry{+target, line}: restore.at(Cl.buf_find(cl, target), cl, line)

def install.collected(got: Import) -> Cl.Client:
  match got:
    case Import{cl, entries, _}:
      List.foldl(~&2, ~H.HistEntry, ~Cl.Client, ~(cl => entry => restore(entry, cl)), List.sort(~H.HistEntry, ~H.entry_id_le, entries), cl)

def admit.usable(+name: String, +lines: List<&2, Cl.Line>, +acc: List<&2, String>, +cl: Cl.Client) -> Bool:
  archive_has(lines)
    && Cl.target_wire(name)
    && Bool.not(String.is_empty(name))
    && Bool.not(seen(acc, name))
    && Bool.not(admit.present(Cl.buf_find(cl, name)))

# `left` is room-1. A skipped target does not spend a slot, so the next room
# is 1+left. The walk itself shrinks the buffer list, which is the recursive
# argument. Nat.sub stays behind the full-client match in room_for.
def admit.keep(
  ok: Bool,
  +name: String,
  +left: Nat,
  +acc: List<&2, String>,
  k: Nat -> List<&2, String> -> List<&2, String>
) -> List<&2, String>:
  match ok:
    case False{}: k(1n+left, acc)
    case True{}: k(left, name <> acc)

def admit.buffer(
  +b: Cl.Buffer,
  +left: Nat,
  +cl: Cl.Client,
  +acc: List<&2, String>,
  k: Nat -> List<&2, String> -> List<&2, String>
) -> List<&2, String>:
  match b:
    case Cl.Buffer{+name, _, _, +lines, _, _, _, _}:
      admit.keep(admit.usable(name, lines, acc, cl), name, left, acc, k)

def admit.go(bufs: List<&2, Cl.Buffer>, room: Nat, +cl: Cl.Client, +acc: List<&2, String>) -> List<&2, String>:
  match bufs:
    case Nil{}: acc
    case Con{+b, +rest}:
      match room:
        case 0n: acc
        case 1n+left:
          admit.buffer(b, left, cl, acc, next => acc2 => admit.go(rest, next, cl, acc2))

def room_for.normal(under: Bool, +count: Nat, +normal: Nat) -> Nat:
  match under:
    case False{}: 0n
    case True{}: Nat.min(Nat.sub(Cl.MAX_BUFFERS(), count), Nat.sub(Cl.NORMAL_BUFFERS(), normal))

def room_for.span(under: Bool, +count: Nat, +normal: Nat) -> Nat:
  match under:
    case False{}: 0n
    case True{}: room_for.normal(Nat.is_lt(normal, Cl.NORMAL_BUFFERS()), count, normal)

def room_for.counts(+count: Nat, +normal: Nat) -> Nat:
  room_for.span(Nat.is_lt(count, Cl.MAX_BUFFERS()), count, normal)

def room_for.bufs(+bufs: List<&2, Cl.Buffer>) -> Nat:
  room_for.counts(Cl.buf_count(bufs), Cl.normal_buffer_count(bufs))

def room_for(+cl: Cl.Client) -> Nat:
  match cl:
    case Cl.Client{_, _, +bufs, _, _, _, _, _, _}: room_for.bufs(bufs)

def install.picked(+rest: List<&2, Cl.Buffer>, +current: Cl.Client) -> List<&2, String>:
  admit.go(sort_recent(rest), room_for(current), current, Nil{})

def install.ordered(+server: Cl.Buffer, +rest: List<&2, Cl.Buffer>, +current: Cl.Client, +cap: U32) -> Cl.Client:
  +base = collect.buffer(Import{current, Nil{}, Nil{}}, server, True{}, cap)
  install.collected(collect.ordered(rest, base, install.picked(rest, current), cap))

def install.buffers(bufs: List<&2, Cl.Buffer>, +current: Cl.Client, +cap: U32) -> Cl.Client:
  match bufs:
    case Nil{}: current
    case Con{server, rest}:
      # Current tabs win. Spare slots go to the most recently used archive
      # targets, then those targets are appended in snapshot order. Accepted
      # rows still replay in file order.
      install.ordered(server, rest, current, cap)

def install.allowed(ok: Bool, +current: Cl.Client, +snapshot: Cl.Client) -> Cl.Client:
  match ok:
    case False{}: current
    case True{}:
      install.buffers(snapshot.buffers(Cl.client_bufs(snapshot), List.sort(~Nat, ~Nat.is_le, operation_ids(snapshot))), current, Cl.settings_hist_cap(Cl.get_settings(current)))

# Exact host:port strings. Outer archive_current / reload_match also check this;
# this defense rejects host-colliding different ports when a caller skips them.
def same_endpoint(+current_ep: String, +snapshot_ep: String) -> Bool:
  String.eq(current_ep, snapshot_ep)

# The outer startup gate owns ticket/generation checks and the checkpoint.
# This defense also rejects a changed endpoint (host or port) or a newly
# disabled history setting. Never cap current rows or evict current targets to
# make room for an archive. Startup-before-005 still imports with the default
# RFC1459 map. Live merges go through install_startup and that same map.
def install(+current: Cl.Client, +snapshot: Cl.Client, +current_ep: String, +snapshot_ep: String) -> Cl.Client:
  +settings = Cl.get_settings(current)
  install.allowed(same_endpoint(current_ep, snapshot_ep)
    && String.eq(Cl.server_of(current), Cl.server_of(snapshot))
    && Cl.settings_history(settings) && Bool.not(U32.is_zero(Cl.settings_hist_cap(settings))), current, snapshot)

def install_startup.mark(on: Bool, cl: Cl.Client, index: Nat, now: String) -> Cl.Client:
  match on:
    case False{}: cl
    case True{}:
      match cl:
        case Cl.Client{nick, host, bufs, active, clock, settings, auth, seq, welcomed}:
          +next: Nat = 1n+seq
          +marker: Cl.Line = Cl.Line{Cl.Reconnect{}, "", Cl.now_hms(now), "", next}
          Cl.Client{nick, host, Cl.buf_modify(bufs, index, b => Cl.buf_append_line(b, marker)), active, clock, settings, auth, next, welcomed}

# One pass returns the last id and the length together: the divider gate
# needs both over the same spine, and the old strict && args walked it
# twice (last_id to the tail plus a full length walk).
def last_id_len.go(lines: List<&2, Cl.Line>, +n: Nat, +last: Nat) -> Nat & Nat:
  match lines:
    case Nil{}: (last, n)
    case Con{Cl.Line{_, _, _, _, +id}, rest}: last_id_len.go(rest, 1n+n, id)

def last_id_len(lines: List<&2, Cl.Line>) -> Nat & Nat:
  last_id_len.go(lines, 0n, 0n)

def divider_ok(+name: String, info: Nat & Nat, +cutoff: Nat) -> Bool:
  match info:
    case (+last, +len):
      Bool.not(Cl.target_is_synthetic(name)) && Nat.is_gt(last, cutoff)
        && Nat.is_lt(len, Cl.SCROLL_CAP())

def install_startup.buffers(bufs: List<&2, Cl.Buffer>, +index: Nat, +cutoff: Nat, cl: Cl.Client, +now: String) -> Cl.Client:
  match bufs:
    case Nil{}: cl
    case Con{Cl.Buffer{+name, _, _, +lines, _, _, _, _}, rest}:
      install_startup.buffers(rest, 1n+index, cutoff,
        install_startup.mark(divider_ok(name, last_id_len(lines), cutoff), cl, index, now), now)

def install_startup.marked(+cl: Cl.Client, cutoff: Nat, now: String) -> Cl.Client:
  install_startup.buffers(Cl.client_bufs(cl), 0n, cutoff, cl, now)

# The caller reports owned worker diagnostics first. Its current sequence is
# therefore the archive cutoff: local and operation-only targets get no marker.
# Never make room for a divider by removing a retained row.
def install_startup(+current: Cl.Client, snapshot: Cl.Client, +current_ep: String, +snapshot_ep: String) -> Cl.Client:
  match current:
    case Cl.Client{_, _, _, _, now, _, _, +cutoff, _}:
      install_startup.marked(install(current, snapshot, current_ep, snapshot_ep), cutoff, now)

# Fresh worker *log* rows describe only this read operation. Synthetic history
# records are rejected by the archive parser; archived Error imports never
# create these mirrors. Report them as current events, not restored log rows.
def diagnostics.lines(lines: List<&2, Cl.Line>) -> List<&2, String>:
  match lines:
    case Nil{}: Nil{}
    case Con{Cl.Line{Cl.Error{}, _, text, _, _}, rest}: text <> diagnostics.lines(rest)
    case Con{_, rest}: diagnostics.lines(rest)

def diagnostics.buffers(bufs: List<&2, Cl.Buffer>) -> List<&2, String>:
  match bufs:
    case Nil{}: Nil{}
    case Con{Cl.Buffer{_, _, _, lines, _, _, _, _}, rest}:
      List.append(&2, String, diagnostics.lines(lines), diagnostics.buffers(rest))

def diagnostics(snapshot: Cl.Client) -> List<&2, String>:
  diagnostics.buffers(Cl.log_buffers(snapshot))

def report_diagnostics.logs(messages: List<&2, String>, current: Cl.Client) -> Cl.Client:
  match messages:
    case Nil{}: current
    case Con{message, rest}: report_diagnostics.logs(rest, Cl.client_log(current, 0n, Cl.Error{}, message))

def report_diagnostics.allowed(ok: Bool, current: Cl.Client, snapshot: Cl.Client) -> Cl.Client:
  match ok:
    case False{}: current
    case True{}: report_diagnostics.logs(diagnostics(snapshot), current)

def report_diagnostics(+current: Cl.Client, +snapshot: Cl.Client, +current_ep: String, +snapshot_ep: String) -> Cl.Client:
  report_diagnostics.allowed(same_endpoint(current_ep, snapshot_ep)
    && String.eq(Cl.server_of(current), Cl.server_of(snapshot)), current, snapshot)
