# SPDX-License-Identifier: Apache-2.0
# Retained-fd disk search drivers. Production scans never reopen by
# pathname: the helper `scan` subcommand (or the native scan law) opens
# O_NOFOLLOW, gates on fstat, reads the exact bytes via that one checked
# descriptor, and closes it; Bend scans the bytes purely through the
# shared octet core (Hs.scan_content). No paths or file content cross the
# helper seam beyond the admitted bytes; refusals and helper failures
# fail closed with fixed diagnostics, never child output.
import Base
import ./buffer.bend as Cl
import ./history_search.bend as Hs
import ./history.bend as Hist
import ./session.bend as Sess
import ./helper_io.bend as H

# The scan output head ("SEbbbbb\n") is fixed width; the rest is content.
def SCAN_EVIDENCE_LEN() -> Nat:
  8n

def SCAN_OUTPUT_CAP() -> U32:
  8388672

def SCAN_NATIVE_CAP() -> U32:
  8388608

# Linked native scan is the default. BIRC_SEARCH_HELPER may name an
# optional process helper; the token "native" (also the unset default)
# selects the FFI scan instead of Process.run. Output cap stays the
# helper cap; the native scan keeps SCAN_NATIVE_CAP.
def search_spec() -> H.Spec:
  H.Spec{"BIRC_SEARCH_HELPER", "native", SCAN_OUTPUT_CAP(), 30000}

def program.default(got: Result<&1, &1, U32 & String, String>) -> String:
  H.name_got(got, "native")

def program() -> IO(String):
  H.name(search_spec())

def disk_search_bytes.admitted(admitted: Bool, +content: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match admitted:
    case True{}: Hs.DiskFound{Hs.scan_content(content, query, endpoint, cursor)}
    case False{}: Hs.DiskFailed{"history search refused: file not admitted"}

def disk_search_bytes.missing(missing: Bool, +ev: Hs.SearchEvidence, +content: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match missing:
    case True{}: Hs.DiskFound{Hs.empty_page()}
    case False{}:
      disk_search_bytes.admitted(Hs.search_evidence_admitted(ev), content, endpoint, query, cursor)

def disk_search_bytes(+ev: Hs.SearchEvidence, +content: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match ev:
    case Hs.SearchEvidence{_, _, _, _, +missing}:
      disk_search_bytes.missing(missing, ev, content, endpoint, query, cursor)

def disk_search_failed.too_large(huge: Bool) -> Hs.DiskResult:
  match huge:
    case True{}: Hs.DiskFailed{"history search refused: file too large"}
    case False{}: Hs.DiskFailed{"history search refused: file not admitted"}

def disk_search_result.code(+code: U32, +out: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match code:
    case 0:
      disk_search_bytes(Hs.parse_search_evidence(String.take(out, SCAN_EVIDENCE_LEN())),
        String.drop(out, SCAN_EVIDENCE_LEN()), endpoint, query, cursor)
    case 5:
      Hs.DiskFailed{Hs.scan_changed_text()}
    case _: disk_search_failed.too_large(U32.is_eq(code, 3))

def disk_search_result.out(rest: String & String, +code: U32, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match rest:
    case (+out, _): disk_search_result.code(code, out, endpoint, query, cursor)

def disk_search_result.pair(pair: U32 & (String & String), +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match pair:
    case (+code, rest):
      disk_search_result.out(rest, code, endpoint, query, cursor)

def disk_search_result(got: Result<&1, &1, U32 & String, U32 & (String & String)>, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match got:
    case Fail{_}: Hs.DiskFailed{"history search refused: file not admitted"}
    case Done{pair}: disk_search_result.pair(pair, endpoint, query, cursor)

law search_scan:
  String -> U32 -> IO(U32 & U32 & String)

def search_scan(path, cap):
  import "../ffi/history_search_ffi.c"

def scan_native_failed(huge: Bool) -> Hs.DiskResult:
  match huge:
    case True{}: Hs.DiskFailed{"history search refused: file too large"}
    case False{}: Hs.DiskFailed{"history search refused: file not admitted"}

def scan_native_shrunk(shrunk: Bool, +bits: U32, +content: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match shrunk:
    case True{}: Hs.DiskFailed{Hs.scan_changed_text()}
    case False{}: disk_search_bytes(Hs.search_evidence_bits(bits), content, endpoint, query, cursor)

def scan_native_done(+bits: U32, +err: U32, +content: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match err:
    case 0: scan_native_shrunk(Hs.search_evidence_truncated(bits), bits, content, endpoint, query, cursor)
    case _: scan_native_failed(U32.is_eq(err, 27))

def scan_native_rest(rest: U32 & String, +bits: U32, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match rest:
    case (+err, +content): scan_native_done(bits, err, content, endpoint, query, cursor)

def scan_native_triple(triple: U32 & U32 & String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> Hs.DiskResult:
  match triple:
    case (+bits, rest): scan_native_rest(rest, bits, endpoint, query, cursor)

def scan_native(+path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> IO(Hs.DiskResult):
  do IO<Hs.DiskResult>:
    triple : U32 & U32 & String <- search_scan(path, SCAN_NATIVE_CAP())
    return scan_native_triple(triple, endpoint, query, cursor)

def disk_search_checked.gated(disabled: Bool, +path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> IO(Hs.DiskResult):
  match disabled:
    case True{}: IO.pure(Hs.DiskResult, Hs.DiskFound{Hs.empty_page()})
    case False{}:
      do IO<Hs.DiskResult>:
        got : Result<&1, &1, U32 & String, U32 & (String & String)> <- H.run(search_spec(), ["scan", path], "")
        return disk_search_result(got, endpoint, query, cursor)

def disk_search_checked(+path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +history_on: Bool) -> IO(Hs.DiskResult):
  disk_search_checked.gated(String.is_empty(path) || Bool.not(history_on), path, endpoint, query, cursor)

# ---- retained-descriptor scan -------------------------------------------
# The helper and native scans above are production. This bounded File chain
# runs the same octet core (Hs.scan_chunk) for caller-held descriptors; it
# lives in the IO layer, not the proof-facing search module.
# Open-result mapping for the affine-FD seam: the checked native open
# reports missing as ENOENT (2) and every refusal (symlink, non-regular,
# foreign, non-private) as EACCES (13) on both backends.

def search_finish(state: Hs.ScanState, f: File) -> IO(Hs.DiskResult):
  do IO<Hs.DiskResult>:
    Unit <- File.close(f)
    return Hs.DiskFound{Hs.search_finish_page(state)}

def search_failure(f: File, +stage: String, error: U32 & String) -> IO(Hs.DiskResult):
  do IO<Hs.DiskResult>:
    Unit <- File.close(f)
    return Hs.DiskFailed{Hist.read_failure_text(error, stage)}

def search_loop.truncated(f: File, state: Hs.ScanState) -> IO(Hs.DiskResult):
  do IO<Hs.DiskResult>:
    Unit <- File.close(f)
    return Hs.DiskFailed{Hs.scan_changed_text()}

def search_loop.eof(truncated: Bool, f: File, state: Hs.ScanState) -> IO(Hs.DiskResult):
  match truncated:
    case True{}: search_loop.truncated(f, state)
    case False{}: search_finish(state, f)

def search_loop.empty(empty: Bool, f: File, +bytes: List<&2, U32>, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat, state: Hs.ScanState, +remaining: Nat, next: File -> Hs.ScanState -> Nat -> IO(Hs.DiskResult)) -> IO(Hs.DiskResult):
  match empty:
    case True{}: search_loop.eof(Hs.scan_eof_truncated(remaining, True{}), f, state)
    case False{}:
      next(f, Hs.scan_chunk(bytes, state, query, endpoint, cursor), Nat.sub(remaining, List.length(&2, U32, bytes)))

def search_loop.got(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat, state: Hs.ScanState, +remaining: Nat, next: File -> Hs.ScanState -> Nat -> IO(Hs.DiskResult)) -> IO(Hs.DiskResult):
  match pair:
    case (f, Fail{error}): search_failure(f, "read failed; partial matches were discarded", error)
    case (f, Done{+bytes}):
      search_loop.empty(Nat.is_eq(List.length(&2, U32, bytes), 0n), f, bytes, query, endpoint, cursor, state, remaining, next)

def search_loop.read(done: Bool, f: File, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat, state: Hs.ScanState, +remaining: Nat, next: File -> Hs.ScanState -> Nat -> IO(Hs.DiskResult)) -> IO(Hs.DiskResult):
  match done:
    case True{}: search_finish(state, f)
    case False{}:
      do IO<Hs.DiskResult>:
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, U32.from_nat(Cl.clamp_nat(remaining, Hs.SCAN_CHUNK())))
        search_loop.got(pair, query, endpoint, cursor, state, remaining, next)

def search_loop(fuel: Nat, f: File, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat, state: Hs.ScanState, +remaining: Nat) -> IO(Hs.DiskResult):
  match fuel:
    case 0n: search_finish(state, f)
    case 1n+p:
      search_loop.read(Nat.is_eq(remaining, 0n), f, query, endpoint, cursor, state, remaining,
        f2 => st2 => rest => search_loop(p, f2, query, endpoint, cursor, st2, rest))

# The production chunked loop inherits the snapshot path's cap: past
# SCAN_NATIVE_CAP the scan refuses closed like the native EFBIG refusal
# instead of walking the whole file with an unbounded remaining budget.
def search_size.capped(big: Bool, f: File, +size: Nat, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat) -> IO(Hs.DiskResult):
  match big:
    case True{}:
      do IO<Hs.DiskResult>:
        Unit <- File.close(f)
        return Hs.DiskFailed{"history search refused: file too large"}
    case False{}: search_loop(1n+size, f, query, endpoint, cursor, Hs.scan_initial(), size)

def search_size.over(moved: Bool, f: File, +size: Nat, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat) -> IO(Hs.DiskResult):
  match moved:
    case True{}:
      do IO<Hs.DiskResult>:
        Unit <- File.close(f)
        return Hs.DiskFailed{Hs.scan_changed_text()}
    case False{}: search_size.capped(Nat.is_gt(size, U32.to_nat(SCAN_NATIVE_CAP())), f, size, query, endpoint, cursor)

# One U32->Nat conversion shared by the cursor check and the scan fuel
# (was computed twice in the Done arm).
def search_size.sized(+size: Nat, f: File, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat) -> IO(Hs.DiskResult):
  search_size.over(Nat.is_gt(cursor, size), f, size, query, endpoint, cursor)

def search_size(pair: File & Result<&1, &1, U32 & String, U32>, +query: Hs.DiskQuery, +endpoint: String, +cursor: Nat) -> IO(Hs.DiskResult):
  match pair:
    case (f, Fail{error}): search_failure(f, "size unavailable", error)
    case (f, Done{+size}):
      search_size.sized(U32.to_nat(size), f, query, endpoint, cursor)

def search_open.refused(refused: Bool, +code: U32, +msg: String) -> IO(Hs.DiskResult):
  match refused:
    case True{}: IO.pure(Hs.DiskResult, Hs.DiskFailed{"history search refused: file not admitted"})
    case False{}: IO.pure(Hs.DiskResult, Hs.DiskFailed{Hist.read_failure_text((code, msg), "open failed")})

def search_open.missing(missing: Bool, +code: U32, +msg: String) -> IO(Hs.DiskResult):
  match missing:
    case True{}: IO.pure(Hs.DiskResult, Hs.DiskFound{Hs.DiskPage{Nil{}, 0n, 0n, True{}}})
    case False{}: search_open.refused(U32.is_eq(code, 13), code, msg)

def search_open.failed(error: U32 & String) -> IO(Hs.DiskResult):
  match error:
    case (+code, +msg): search_open.missing(U32.is_eq(code, 2), code, msg)

def search_open_file(f: File, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> IO(Hs.DiskResult):
  do IO<Hs.DiskResult>:
    pair : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
    search_size(pair, query, endpoint, cursor)

def search_opened(+query: Hs.DiskQuery, +endpoint: String, +cursor: Nat, result: Result<&1, &1, U32 & String, File>) -> IO(Hs.DiskResult):
  match result:
    case Fail{error}: search_open.failed(error)
    case Done{f}: search_open_file(f, endpoint, query, cursor)

# Affine-FD seam: one checked native open (lstat, O_NOFOLLOW, fstat
# admission) hands the retained descriptor out as an affine File; refusals
# arrive already closed. No probe-then-reopen window remains: the scan runs
# on the checked descriptor itself. Both backends link (C effect plus its
# numeric-fd JS twin), so suites prove the seam on the JS backend too.
law open_private:
  String -> IO(Result<&1, &1, U32 & String, File>)

def open_private(path):
  import "../ffi/history_search_ffi.c"
  import "../ffi/history_search_open.js"

def search_file_checked.gated(disabled: Bool, +path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat) -> IO(Hs.DiskResult):
  match disabled:
    case True{}: IO.pure(Hs.DiskResult, Hs.DiskFound{Hs.empty_page()})
    case False{}:
      do IO<Hs.DiskResult>:
        result : Result<&1, &1, U32 & String, File> <- open_private(path)
        search_opened(query, endpoint, cursor, result)

def search_file_checked(+path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +history_on: Bool) -> IO(Hs.DiskResult):
  search_file_checked.gated(String.is_empty(path) || Bool.not(history_on), path, endpoint, query, cursor)

# Async completion owner: the worker scans and posts SearchDone; the loop
# completes it against the CURRENT session (ticket/gen/endpoint must match
# the live owner). The wgen incarnation passes through untouched for the
# loop's incarnation fence. No scan runs, and nothing posts, when disabled.
def post_search_done(+result: Hs.DiskResult, +ticket: Nat, +gen: Nat, +wgen: U32, +endpoint: String, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  do IO<Unit>:
    _ : Result<&1, &1, Sess.UiMsg, Unit> <- Chan.send(Sess.UiMsg, evt, Sess.SearchDone{ticket, gen, wgen, endpoint, orig, result})
    return Unit{}

def search_run.post.go(post: Bool, +path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +ticket: Nat, +gen: Nat, +wgen: U32, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        result : Hs.DiskResult <- disk_search_checked(path, endpoint, query, cursor, True{})
        post_search_done(result, ticket, gen, wgen, endpoint, orig, evt)
    case False{}: IO.pure(Unit, Unit{})

def search_run.post(+history_on: Bool, +path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +ticket: Nat, +gen: Nat, +wgen: U32, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  search_run.post.go(history_on && Bool.not(String.is_empty(path)), path, endpoint, query, cursor, ticket, gen, wgen, orig, evt)

def search_run(+endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +history_on: Bool, +ticket: Nat, +gen: Nat, +wgen: U32, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  do IO<Unit>:
    path : String <- Hist.resolve_history_path()
    search_run.post(history_on, path, endpoint, query, cursor, ticket, gen, wgen, orig, evt)

# Native twin of the worker for BIRC_SEARCH_HELPER=native (linked builds
# without a helper process). Called only from the loop's emit arm, never
# from suite-reachable code: the C law cannot link on the JS backend.
# Production native path runs the retained-descriptor chunked scan loop
# (open_private + search_loop), not the whole-file scan_native materializer.
# scan_native stays for the FFI law; production never materializes the file.
def search_run_native.post.go(post: Bool, +path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +ticket: Nat, +gen: Nat, +wgen: U32, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        result : Hs.DiskResult <- search_file_checked(path, endpoint, query, cursor, True{})
        post_search_done(result, ticket, gen, wgen, endpoint, orig, evt)
    case False{}: IO.pure(Unit, Unit{})

def search_run_native.post(+history_on: Bool, +path: String, +endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +ticket: Nat, +gen: Nat, +wgen: U32, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  search_run_native.post.go(history_on && Bool.not(String.is_empty(path)), path, endpoint, query, cursor, ticket, gen, wgen, orig, evt)

def search_run_native(+endpoint: String, +query: Hs.DiskQuery, +cursor: Nat, +history_on: Bool, +ticket: Nat, +gen: Nat, +wgen: U32, +orig: String, evt: Chan(Sess.UiMsg)) -> IO(Unit):
  do IO<Unit>:
    path : String <- Hist.resolve_history_path()
    search_run_native.post(history_on, path, endpoint, query, cursor, ticket, gen, wgen, orig, evt)
