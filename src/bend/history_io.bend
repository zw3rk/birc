# Private history writes. Keep foreign IO outside the proof-facing History.
import Base
import ./history.bend as H
import ./buffer.bend as Cl

# Durable write vs intentional skip vs failed append. Empty path/data (and
# caller-supplied skip) are Skip, not Ok: notice-only callers collapse both
# via append_notice, but checkpoint/save claims must not treat Skip as a write.
type Append is Data:
  Ok{}
  Skip{}
  Err{msg: String}

def append_notice(got: Append) -> Maybe<&2, String>:
  match got:
    case Ok{}: None{}
    case Skip{}: None{}
    case Err{+msg}: Some{msg}

# True only when bytes were written. Skip and Err must not advance durable claims.
def append_ok(got: Append) -> Bool:
  match got:
    case Ok{}: True{}
    case _: False{}

def append_err(got: Append) -> Bool:
  match got:
    case Err{_}: True{}
    case _: False{}

# Test seam for a failed write after a descriptor was acquired.
def history_append_file.done(pair: File & Result<&1, &1, U32 & String, Unit>) -> IO(Maybe<&2, String>):
  match pair:
    case (f, result):
      do IO<Maybe<&2, String>>:
        Unit <- File.close(f)
        return H.save_result(result)

# Native append owns descriptor validation, per-file 0600 repair, write and
# close. Stage/errno alone cross the seam; neither paths nor file text leak
# into diagnostics. Blocking file work runs on the runtime helper thread.
law append_private:
  String -> String -> IO(U32 & U32)

def append_private(path, data):
  import "../ffi/history_ffi.c"

def history_append_file.skip(+path: String, +data: String) -> Bool:
  String.is_empty(path) || String.is_empty(data)

def history_append_file.err(+msg: String) -> Append:
  Err{msg}

def history_append_file.private_append(pair: U32 & U32) -> Append:
  match pair:
    case (0, _): Ok{}
    case (stage, code):
      history_append_file.err(H.save_error((code, ""), Bool.pick(String, U32.is_eq(stage, 1), "open failed", "write failed")))

def history_append_file.outcome(skip: Bool, +path: String, +data: String) -> IO(Append):
  match skip:
    case True{}: IO.pure(Append, Skip{})
    case False{}:
      do IO<Append>:
        pair : U32 & U32 <- append_private(path, data)
        return history_append_file.private_append(pair)

# Characterization: empty path or data is Skip (collapsed to None by
# append_notice). Fail-closed symlink/ownership rejection stays in the native
# write path (skip=False).
def history_append_file.check(skip: Bool, +path: String, +data: String) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    got : Append <- history_append_file.outcome(skip, path, data)
    return append_notice(got)

def history_append_file(+path: String, +data: String) -> IO(Maybe<&2, String>):
  history_append_file.check(history_append_file.skip(path, data), path, data)

def history_append_file.typed(+path: String, +data: String) -> IO(Append):
  history_append_file.outcome(history_append_file.skip(path, data), path, data)

# Durable claim entry: empty data is Skip (nothing to write). Nonempty always
# attempts the native write so an empty path fails closed as Err, never a
# silent Skip success that advances checkpoint/hold/ack.
def history_append_file.claim(+path: String, +data: String) -> IO(Append):
  history_append_file.outcome(String.is_empty(data), path, data)

def maybe_save_history.outcome(enabled: Bool, +path: String, +endpoint: String, +old_cl: Cl.Client, +new_cl: Cl.Client) -> IO(Append):
  match enabled:
    case False{}: IO.pure(Append, Skip{})
    case True{}: history_append_file.claim(path, H.extract_new_history_for(endpoint, old_cl, new_cl))

def maybe_save_history.outcome_except(enabled: Bool, +path: String, +endpoint: String, +old_cl: Cl.Client, +new_cl: Cl.Client, +excluded: List<&2, Nat>) -> IO(Append):
  match enabled:
    case False{}: IO.pure(Append, Skip{})
    case True{}: history_append_file.claim(path, H.extract_new_history_for_except(endpoint, old_cl, new_cl, excluded))

def maybe_save_history.check(enabled: Bool, +path: String, +endpoint: String, +old_cl: Cl.Client, +new_cl: Cl.Client) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    got : Append <- maybe_save_history.outcome(enabled, path, endpoint, old_cl, new_cl)
    return append_notice(got)

# Exclusion variant: imported archive rows (the drain's claimed IDs,
# installed in the session owner) become the next baseline instead of
# being appended again. Live rows always save.
def maybe_save_history.check_except(enabled: Bool, +path: String, +endpoint: String, +old_cl: Cl.Client, +new_cl: Cl.Client, +excluded: List<&2, Nat>) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    got : Append <- maybe_save_history.outcome_except(enabled, path, endpoint, old_cl, new_cl, excluded)
    return append_notice(got)

def maybe_save_history.typed(+path: String, +endpoint: String, +old_cl: Cl.Client, +new_cl: Cl.Client) -> IO(Append):
  maybe_save_history.outcome(
    Bool.not(String.is_empty(path)) && Cl.settings_history(Cl.get_settings(new_cl)),
    path, endpoint, old_cl, new_cl
  )

def maybe_save_history(+path: String, +endpoint: String, +old_cl: Cl.Client, +new_cl: Cl.Client) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    got : Append <- maybe_save_history.typed(path, endpoint, old_cl, new_cl)
    return append_notice(got)

# Native framing keeps the last min(cap, 1024) lines of each target and the
# final channel order. Bend still accepts each record and plants it onto the
# client already in hand, including one that holds another buffer. Every load
# admits the path through read_kept first: no symlink, a regular file, and
# the euid. A refusal fails before any parse.
law read_kept:
  String -> String -> U32 -> IO(U32 & U32 & List<&2, String> & List<&2, List<&2, String>>)

def read_kept(path, endpoint, cap):
  import "../ffi/history_ffi.c"
  import "../ffi/history_read_kept.js"

def history_file.plant_one.got(pair: Cl.Client & Maybe<&2, Nat>) -> Cl.Client:
  match pair:
    case (+next, _): next

def history_file.plant_one(+name: String, +cl: Cl.Client) -> Cl.Client:
  history_file.plant_one.got(Cl.buf_get(cl, name, Cl.target_channel(name), True{}))

def history_file.plant(names: List<&2, String>, +cl: Cl.Client) -> Cl.Client:
  match names:
    case Nil{}: cl
    case Con{+name, +rest}: history_file.plant(rest, history_file.plant_one(name, cl))

def history_file.prepare(zero: Bool, +names: List<&2, String>, +cl: Cl.Client, +cap: U32) -> Cl.Client:
  match zero:
    case True{}: cl
    case False{}: history_file.plant(names, Cl.client_hist_open(cl, H.hist_keep(cap)))

def history_file.one(fields: List<&2, String>, +cl: Cl.Client, +endpoint: String, +cap: U32) -> Cl.Client:
  H.read_record.entry(H.parse_line_for.tokens(fields, endpoint), cl, cap)

def history_file.walk(lines: List<&2, List<&2, String>>, +cl: Cl.Client, +endpoint: String, +cap: U32) -> Cl.Client:
  match lines:
    case Nil{}: cl
    case Con{+fields, +rest}: history_file.walk(rest, history_file.one(fields, cl, endpoint, cap), endpoint, cap)

def history_file.restored(+names: List<&2, String>, +lines: List<&2, List<&2, String>>, +cl: Cl.Client, +endpoint: String, +cap: U32) -> Cl.Client:
  history_file.walk(lines, history_file.prepare(U32.is_eq(cap, 0), names, cl, cap), endpoint, cap)

def history_file.stage(stage: U32, +err: U32, +names: List<&2, String>, +lines: List<&2, List<&2, String>>, +snapshot: Bool, +cl: Cl.Client, +endpoint: String, +cap: U32, +now: String) -> Cl.Client:
  match stage:
    case 0:
      H.read_finish.client(snapshot, history_file.restored(names, lines, cl, endpoint, cap), now)
    case 1:
      cl
    case 2:
      H.read_error(snapshot, cl, (err, ""), "open failed")
    case 3:
      H.read_error(snapshot, H.read_finish.client(snapshot, cl, now), (err, ""), "size unavailable")
    case _:
      H.read_error(snapshot, H.read_finish.client(snapshot, history_file.restored(names, lines, cl, endpoint, cap), now), (err, ""), "read failed; only completed records were restored")

def history_file.names(rest: List<&2, String> & List<&2, List<&2, String>>, +stage: U32, +err: U32, +snapshot: Bool, +cl: Cl.Client, +endpoint: String, +cap: U32, +now: String) -> Cl.Client:
  match rest:
    case (+names, +lines): history_file.stage(stage, err, names, lines, snapshot, cl, endpoint, cap, now)

def history_file.err(rest: U32 & List<&2, String> & List<&2, List<&2, String>>, +stage: U32, +snapshot: Bool, +cl: Cl.Client, +endpoint: String, +cap: U32, +now: String) -> Cl.Client:
  match rest:
    case (+err, rest2): history_file.names(rest2, stage, err, snapshot, cl, endpoint, cap, now)

def history_file.apply(got: U32 & U32 & List<&2, String> & List<&2, List<&2, String>>, +snapshot: Bool, +cl: Cl.Client, +endpoint: String, +cap: U32, +now: String) -> Cl.Client:
  match got:
    case (+stage, rest): history_file.err(rest, stage, snapshot, cl, endpoint, cap, now)

def history_file.load(+snapshot: Bool, +path: String, +endpoint: String, +cap: U32, +cl: Cl.Client, +now: String) -> IO(Cl.Client):
  do IO<Cl.Client>:
    got : U32 & U32 & List<&2, String> & List<&2, List<&2, String>> <- read_kept(path, endpoint, cap)
    return history_file.apply(got, snapshot, cl, endpoint, cap, now)

def history_load_client.pick(skip: Bool, +path: String, +endpoint: String, +cap: U32, +cl: Cl.Client, +now: String) -> IO(Cl.Client):
  match skip:
    case True{}: IO.pure(Cl.Client, cl)
    case False{}: history_file.load(False{}, path, endpoint, cap, cl, now)

def history_load_client(+path: String, +endpoint: String, +cap: U32, +cl: Cl.Client) -> IO(Cl.Client):
  match cl:
    case Cl.Client{_, _, _, _, +now, _, _, _, _}:
      history_load_client.pick(String.is_empty(path) || Bool.not(Cl.settings_history(Cl.get_settings(cl))), path, endpoint, cap, cl, now)

def history_snapshot_client(+path: String, +endpoint: String, +cap: U32, +cl: Cl.Client) -> IO(Cl.Client):
  history_file.load(True{}, path, endpoint, cap, cl, "")

def history_init_client.pick(empty: Bool, +path: String, +endpoint: String, +cap: U32, +nick: String, +host: String, +now: String) -> IO(Cl.Client):
  match empty:
    case True{}: IO.pure(Cl.Client, Cl.init_with_cap(nick, host, cap))
    case False{}: history_load_client(path, endpoint, cap, Cl.set_now(Cl.init_with_cap(nick, host, cap), now))

def history_init_client(+path: String, +endpoint: String, +cap: U32, +nick: String, +host: String, +now: String) -> IO(Cl.Client):
  history_init_client.pick(String.is_empty(path), path, endpoint, cap, nick, host, now)

# ---- POSIX retained-descriptor reader --------------------------------------
# The native read_kept path above is production. This bounded File chain
# parses the same framed records through the shared pure octet core
# (H.read_walk) for caller-held descriptors and failure-path probes; it
# lives in the IO layer, not the proof-facing history module.

# One native read. The pure walk of that chunk does not park, so the
# fiber yields once per chunk and then scans it straight through.
def hist_read_chunk() -> Nat:
  65536n

# A worker snapshot spends its bounded row capacity only on archive records.
# The UI adds its divider after import, when spare capacity is known.
def read_finish.mode(snapshot: Bool, f: File, state: H.ReadState, now: String) -> IO(Cl.Client):
  match state:
    case H.ReadState{cl, _, _, _}:
      do IO<Cl.Client>:
        Unit <- File.close(f)
        return H.read_finish.client(snapshot, cl, now)

def read_failure.mode(+snapshot: Bool, f: File, state: H.ReadState, now: String, error: U32 & String, stage: String) -> IO(Cl.Client):
  do IO<Cl.Client>:
    cl : Cl.Client <- read_finish.mode(snapshot, f, state, now)
    return H.read_error(snapshot, cl, error, stage)

def read_pace.unpack(pair: H.ReadState & List<&2, U32>, k: List<&2, U32> -> H.ReadState -> IO(Cl.Client)) -> IO(Cl.Client):
  match pair:
    case (state, +bytes): k(bytes, state)

def read_pace.spent(rest: List<&2, U32>, +drop: Nat) -> Nat:
  match rest:
    case Nil{}: drop
    case _: Nat.sub(drop, List.length(&2, U32, rest))

# The Bend event loop is one thread. Yield once, then walk this chunk,
# so a resize or a key can run between chunks without a park per 256 bytes.
def read_pace.begin(+bytes: List<&2, U32>, +drop: Nat, f: File, state: H.ReadState, +endpoint: String, +cap: U32, +remaining: Nat, next: File -> H.ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  do IO<Cl.Client>:
    Unit <- IO.sleep(0)
    read_pace.unpack(H.read_walk(drop, bytes, state, endpoint, cap), rest => st => next(f, st, Nat.sub(remaining, read_pace.spent(rest, drop))))

# D214: one length walk per chunk. Emptiness reuses the same drop size through
# Nat.is_eq (constant on 0n); the leftover walk inside read_pace.spent stays
# because the remaining decrement needs the consumed count and read_walk
# (pure module) returns only the leftover list.
def read_loop.empty.mode(len: Nat, snapshot: Bool, f: File, +bytes: List<&2, U32>, state: H.ReadState, endpoint: String, cap: U32, now: String, remaining: Nat, next: File -> H.ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match len:
    case 0n: read_finish.mode(snapshot, f, state, now)
    case 1n+_: read_pace.begin(bytes, len, f, state, endpoint, cap, remaining, next)

def read_loop.got.mode(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>, snapshot: Bool, state: H.ReadState, endpoint: String, cap: U32, now: String, remaining: Nat, next: File -> H.ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match pair:
    case (f, Fail{error}): read_failure.mode(snapshot, f, state, now, error, "read failed; only completed records were restored")
    case (f, Done{+bytes}): read_loop.empty.mode(List.length(&2, U32, bytes), snapshot, f, bytes, state, endpoint, cap, now, remaining, next)

def read_loop.got(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>, state: H.ReadState, endpoint: String, cap: U32, now: String, remaining: Nat, next: File -> H.ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  read_loop.got.mode(pair, False{}, state, endpoint, cap, now, remaining, next)

def read_loop.read.mode(done: Bool, +snapshot: Bool, f: File, state: H.ReadState, +endpoint: String, +cap: U32, +now: String, +remaining: Nat, next: File -> H.ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match done:
    case True{}: read_finish.mode(snapshot, f, state, now)
    case False{}:
      do IO<Cl.Client>:
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, U32.from_nat(Cl.clamp_nat(remaining, hist_read_chunk())))
        read_loop.got.mode(pair, snapshot, state, endpoint, cap, now, remaining, next)

# The file's initial size bounds the loop. Appends during loading cannot keep it
# alive forever. Short reads still consume the full snapshot; state holds at most 8192 bytes and
# MAX_BUFFERS * min(cap, SCROLL_CAP) lines, regardless of file size.
# D167/D212: fuel stays byte-seeded (1n+size, converted once in read_size.sized).
# Chunk-unit fuel is unsound here: a short native read can consume fewer than
# 64 KiB per step, so only the byte count covers the maximum step count.
def read_loop.mode(fuel: Nat, +snapshot: Bool, f: File, state: H.ReadState, +endpoint: String, +cap: U32, +now: String, +remaining: Nat) -> IO(Cl.Client):
  match fuel:
    case 0n: read_finish.mode(snapshot, f, state, now)
    case 1n+p:
      read_loop.read.mode(Nat.is_eq(remaining, 0n), snapshot, f, state, endpoint, cap, now, remaining,
        f2 => st2 => rest => read_loop.mode(p, snapshot, f2, st2, endpoint, cap, now, rest))

# Cap 0 restores nothing and must leave an existing client unchanged.
def read_prepare.mode(zero: Bool, cl: Cl.Client, +cap: U32) -> Cl.Client:
  match zero:
    case True{}: cl
    case False{}: Cl.client_hist_open(cl, H.hist_keep(cap))

# One U32->Nat conversion shared by fuel and remaining (was computed twice).
def read_size.sized(+size: Nat, snapshot: Bool, f: File, cl: Cl.Client, endpoint: String, +cap: U32, now: String) -> IO(Cl.Client):
  read_loop.mode(1n+size, snapshot, f, H.ReadState{read_prepare.mode(U32.is_eq(cap, 0), cl, cap), Nil{}, 0n, False{}}, endpoint, cap, now, size)

def read_size.mode(pair: File & Result<&1, &1, U32 & String, U32>, snapshot: Bool, cl: Cl.Client, endpoint: String, +cap: U32, now: String) -> IO(Cl.Client):
  match pair:
    case (f, Fail{error}): read_failure.mode(snapshot, f, H.ReadState{cl, Nil{}, 0n, False{}}, now, error, "size unavailable")
    case (f, Done{+size}): read_size.sized(U32.to_nat(size), snapshot, f, cl, endpoint, cap, now)

# ENOENT is the normal first-run case on this POSIX runtime. Other open
# failures must be visible; an inaccessible history file is not an empty one.
def read_open.error.mode(missing: Bool, snapshot: Bool, cl: Cl.Client, error: U32 & String) -> IO(Cl.Client):
  match missing:
    case True{}: IO.pure(Cl.Client, cl)
    case False{}: IO.pure(Cl.Client, H.read_error(snapshot, cl, error, "open failed"))

def read_open.failed.mode(error: U32 & String, snapshot: Bool, cl: Cl.Client) -> IO(Cl.Client):
  match error:
    case (+code, +msg): read_open.error.mode(U32.is_eq(code, 2), snapshot, cl, (code, msg))

def read_open.mode(result: Result<&1, &1, U32 & String, File>, +snapshot: Bool, cl: Cl.Client, +endpoint: String, +cap: U32, +now: String) -> IO(Cl.Client):
  match result:
    case Fail{error}: read_open.failed.mode(error, snapshot, cl)
    case Done{f}:
      do IO<Cl.Client>:
        pair : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
        read_size.mode(pair, snapshot, cl, endpoint, cap, now)
