# Replay a bounded file snapshot through the live byte framer. Reads are small;
# UTF-8 and CRLF may cross chunks, and an unterminated final record is retained.
import Base
import ./buffer.bend as Cl
import ./client.bend as Feed
import ./frame.bend as Fr
import ./irc.bend as Irc
import ./clock.bend as Clock

type ReadState is Data:
  ReadState{cl: Cl.Client, rem: List<&2, U32>, drop: Bool}

def die(+path: String, +msg: String) -> IO(Cl.Client):
  IO.die(Cl.Client, 1, "birc: cannot read replay " ++ path ++ ": " ++ msg)

def fail(f: File, +path: String, +msg: String) -> IO(Cl.Client):
  do IO<Cl.Client>:
    Unit <- File.close(f)
    die(path, msg)

def fail_error(f: File, +path: String, error: U32 & String) -> IO(Cl.Client):
  match error:
    case (_, +msg): fail(f, path, msg)

def chunk.got(cl: Cl.Client, got: List<&2, String> & List<&2, U32> & Bool) -> ReadState:
  match got:
    case (lines, rem, drop): ReadState{Feed.feed_all(cl, lines), rem, drop}

def chunk(state: ReadState, bytes: List<&2, U32>) -> ReadState:
  match state:
    case ReadState{cl, drop_rem, dropping}:
      chunk.got(cl, Fr.push_ex(dropping, drop_rem, bytes))

def finish_client(drop: Bool, cl: Cl.Client, rem: List<&2, U32>) -> Cl.Client:
  match drop:
    case True{}: cl
    case False{}: Feed.feed_all(cl, Cl.replay_lines(Irc.sanitize_keep_style(Fr.line_from_octets(rem))))

def finish(f: File, state: ReadState) -> IO(Cl.Client):
  match state:
    case ReadState{cl, rem, drop}:
      do IO<Cl.Client>:
        Unit <- File.close(f)
        return finish_client(drop, cl, rem)

# Same yield as history reads: the replay framer stays on the event
# thread, so a 4096-byte push would stall every other fiber. Slice,
# park, then continue. The framer already keeps a cross-chunk remainder.
# One slice shares one framer reopen and one feed fold: pushing byte by
# byte would reopen per byte and fold per byte (~256x more calls).
def read_pace.slice(+bytes: List<&2, U32>, state: ReadState) -> ReadState & List<&2, U32>:
  +head = List.take(&2, U32, bytes, 256n)
  (chunk(state, head), List.drop(&2, U32, bytes, 256n))

def read_pace.step(fuel: Nat, +bytes: List<&2, U32>, state: ReadState) -> ReadState & List<&2, U32>:
  match fuel:
    case 0n: (state, bytes)
    case 1n+p:
      match bytes:
        case Nil{}: (state, Nil{})
        case Con{_, _}: read_pace.slice(bytes, state)

def read_pace.unpack(pair: ReadState & List<&2, U32>, k: List<&2, U32> -> ReadState -> IO(Cl.Client)) -> IO(Cl.Client):
  match pair:
    case (state, +bytes): k(bytes, state)

def read_pace.more(fuel: Nat, +bytes: List<&2, U32>, +drop: Nat, f: File, +path: String, state: ReadState, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match fuel:
    case 0n: next(f, state, Nat.sub(remaining, drop))
    case 1n+p:
      match bytes:
        case Nil{}: next(f, state, Nat.sub(remaining, drop))
        case Con{+byte, +t}:
          do IO<Cl.Client>:
            Unit <- IO.sleep(0)
            read_pace.unpack(read_pace.step(256n, byte <> t, state), bs => st => read_pace.more(p, bs, drop, f, path, st, remaining, next))

def read_pace.launch(pair: ReadState & List<&2, U32>, +drop: Nat, f: File, +path: String, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match pair:
    # `drop` is the pre-step byte count, so it bounds the leftover suffix
    # without re-walking it to recompute `List.length(left)`.
    case (state, +left): read_pace.more(drop, left, drop, f, path, state, remaining, next)

def read_pace.begin(+bytes: List<&2, U32>, +drop: Nat, f: File, +path: String, state: ReadState, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  read_pace.launch(read_pace.step(256n, bytes, state), drop, f, path, remaining, next)

# Chunk-unit fill: one outer step accumulates a full 4096-byte chunk (or the
# remaining tail) before feeding the framer. Short non-empty reads keep
# filling instead of ending the step: every iteration appends at least one
# byte toward the 4096 cap (an empty read fails closed exactly as before), so
# the inner loop takes at most 4096 iterations and its 4097n fuel always
# covers it. Each outer step therefore consumes a full chunk or reaches
# remaining==0, so outer steps stay within 2n+size/4096. Ending the fill on a
# short read would leave a one-byte-per-step path with no fuel bound, which is
# the naive chunk-unit unsoundness this shape avoids. The loop-back edge is a
# lazy refill continuation built in the predecessor-fuel scope, the same shape
# as read_loop passing its own resume into read: dotted forward refs are
# forbidden, and only the decreased fuel `p` justifies the recursive call.
# `remaining` here is post-fill (`left`); `begin` needs the pre-fill outer
# count for its drop bookkeeping, which is `left + grown_len` by construction.
def read_loop.rest(done: Bool, refill: File -> ReadState -> List<&2, U32> -> Nat -> Nat -> (File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client), f: File, +path: String, state: ReadState, +acc: List<&2, U32>, +acc_len: Nat, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match done:
    case True{}: read_pace.begin(acc, acc_len, f, path, state, Nat.add(remaining, acc_len), next)
    case False{}: refill(f, state, acc, acc_len, remaining, next)

def read_loop.ready(full: Bool, done: Bool, refill: File -> ReadState -> List<&2, U32> -> Nat -> Nat -> (File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client), f: File, +path: String, state: ReadState, +acc: List<&2, U32>, +acc_len: Nat, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match full:
    case True{}: read_pace.begin(acc, acc_len, f, path, state, Nat.add(remaining, acc_len), next)
    case False{}: read_loop.rest(done, refill, f, path, state, acc, acc_len, remaining, next)

def read_loop.packed(f: File, +path: String, state: ReadState, +acc: List<&2, U32>, +bytes: List<&2, U32>, +acc_len: Nat, +remaining: Nat, refill: File -> ReadState -> List<&2, U32> -> Nat -> Nat -> (File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client), next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  +got = List.length(&2, U32, bytes)
  +grown = List.append(&2, U32, acc, bytes)
  +grown_len = Nat.add(acc_len, got)
  +left = Nat.sub(remaining, got)
  read_loop.ready(Nat.is_eq(grown_len, 4096n), Nat.is_eq(left, 0n), refill, f, path, state, grown, grown_len, left, next)

def read_loop.accum(empty: Bool, f: File, +path: String, state: ReadState, +acc: List<&2, U32>, +bytes: List<&2, U32>, +acc_len: Nat, +remaining: Nat, refill: File -> ReadState -> List<&2, U32> -> Nat -> Nat -> (File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client), next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match empty:
    case True{}: fail(f, path, "unexpected end of file")
    case False{}: read_loop.packed(f, path, state, acc, bytes, acc_len, remaining, refill, next)

def read_loop.filled(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>, +path: String, state: ReadState, +acc: List<&2, U32>, +acc_len: Nat, +remaining: Nat, refill: File -> ReadState -> List<&2, U32> -> Nat -> Nat -> (File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client), next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match pair:
    case (f, Fail{error}): fail_error(f, path, error)
    case (f, Done{+bytes}): read_loop.accum(Nat.is_eq(List.length(&2, U32, bytes), 0n), f, path, state, acc, bytes, acc_len, remaining, refill, next)

def read_loop.fill(fuel: Nat, f: File, +path: String, state: ReadState, +acc: List<&2, U32>, +acc_len: Nat, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match fuel:
    case 0n: fail(f, path, "read budget exhausted")
    case 1n+p:
      do IO<Cl.Client>:
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, U32.from_nat(Cl.clamp_nat(remaining, Nat.sub(4096n, acc_len))))
        read_loop.filled(pair, path, state, acc, acc_len, remaining, f2 => st2 => gr => gl => lf => nx => read_loop.fill(p, f2, path, st2, gr, gl, lf, nx), next)

def read_loop.read(done: Bool, f: File, +path: String, state: ReadState, +remaining: Nat, next: File -> ReadState -> Nat -> IO(Cl.Client)) -> IO(Cl.Client):
  match done:
    case True{}: finish(f, state)
    case False{}: read_loop.fill(4097n, f, path, state, Nil{}, 0n, remaining, next)

# The initial size bounds total work even if another process keeps appending.
# Positive short reads consume the snapshot; early EOF fails instead of painting
# a partial replay. File.size itself fails for a file larger than U32 can hold.
def read_loop(fuel: Nat, f: File, +path: String, state: ReadState, +remaining: Nat) -> IO(Cl.Client):
  match fuel:
    case 0n: fail(f, path, "read budget exhausted")
    case 1n+p:
      read_loop.read(Nat.is_eq(remaining, 0n), f, path, state, remaining,
        f2 => st2 => rest => read_loop(p, f2, path, st2, rest))

# Fuel stays in chunk units: each read_loop step fills a full 4096-byte chunk
# (or the remaining tail) before feeding the framer, so 2n+size/4096 covers
# every step plus the terminal finish. The inner fill keeps reading while
# bytes arrive, so short native reads take more inner iterations but never
# more outer steps; test-replay-stream covers split reads past chunk
# boundaries.
def sized(pair: File & Result<&1, &1, U32 & String, U32>, +path: String, cl: Cl.Client) -> IO(Cl.Client):
  match pair:
    case (f, Fail{error}): fail_error(f, path, error)
    case (f, Done{+size}): read_loop(2n+Nat.div(U32.to_nat(size), 4096n), f, path, ReadState{cl, Nil{}, False{}}, U32.to_nat(size))

def opened(+path: String, +nick: String, +server: String, result: Result<&1, &1, U32 & String, File>) -> IO(Cl.Client):
  match result:
    case Fail{(_, +msg)}: die(path, msg)
    case Done{f}:
      do IO<Cl.Client>:
        ts : String <- Clock.hhmmss()
        pair : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
        sized(pair, path, Cl.set_now(Cl.init(nick, server), ts))

def load(+path: String, +nick: String, +server: String) -> IO(Cl.Client):
  do IO<Cl.Client>:
    result : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    opened(path, nick, server, result)
