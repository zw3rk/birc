# Pure composer key, panel, and input-recall decisions.
# Hist/Comp/Keys constructors stay in session.bend. Session applies KeyPlan.
import Base
import ./composer_ui.bend as Cu
import ./submit.bend as Sub
import ./view.bend as View

type CView is Data:
  CNone{}
  CActive{}
  CUpload{}
  CHelp{topic: String}
  CHidden{}
  CPick{idx: Nat}

type HistStep is Data:
  StepStay{}
  StepPrev{}
  StepNext{}

type KeyPlan is Data:
  KeyApply{halt: Bool, seed: U32, view: CView, pos: Nat, draft: String, stash: String}
  KeyCycle{}

# Recall step result: the new ring position, the shown draft, and the
# carried stash. A Data constructor (not a &-tuple) so both String fields
# keep their names through the match.
type Recall is Data:
  Recall{pos: Nat, shown: String, stash: String}

def line_at(+xs: List<&2, String>, +i: Nat) -> String:
  Maybe.default(&2, String, List.get(&2, String, xs, i), "")

def hist_prev.on(+lines: List<&2, String>, +pos: Nat, z: Bool) -> Nat & String:
  match z:
    case True{}:
      (pos, line_at(lines, pos))
    case False{}:
      +p = Nat.sub(pos, 1n)
      (p, line_at(lines, p))

def hist_prev(+lines: List<&2, String>, +pos: Nat) -> Nat & String:
  hist_prev.on(lines, pos, Nat.is_eq(pos, 0n))

# Single index pass: one walk yields both the ring length and the entry
# at the recall target, so a recall step pays no separate length/get walks.
def hist_next.kept(at: Bool, +h: String, +kept: String) -> String:
  match at:
    case True{}: h
    case False{}: kept

def hist_next.scan.done(past_end: Bool, +p: Nat, +n: Nat, +kept: String) -> Nat & String:
  match past_end:
    case True{}: (n, "")
    case False{}: (p, kept)

def hist_next.scan.go(+xs: List<&2, String>, +p: Nat, +i: Nat, +kept: String) -> Nat & String:
  match xs:
    case Nil{}: hist_next.scan.done(Nat.is_ge(p, i), p, i, kept)
    case Con{+h, +t}: hist_next.scan.go(t, p, Nat.add(i, 1n), hist_next.kept(Nat.is_eq(i, p), h, kept))

def hist_next.scan(+lines: List<&2, String>, +p: Nat) -> Nat & String:
  hist_next.scan.go(lines, p, 0n, "")

def hist_next(+lines: List<&2, String>, +pos: Nat) -> Nat & String:
  hist_next.scan(lines, Nat.add(pos, 1n))

# Recall shelves the unsubmitted composer text on the first step back from
# the bottom and restores it on the step past the newest entry. Browsing
# deeper keeps the shelved text; typing reseeds it. Returns pos, shown
# draft, and the carried stash.
def hist_prev.shelve(at_bottom: Bool, +draft: String, +stash: String) -> String:
  match at_bottom:
    case True{}: draft
    case False{}: stash

def hist_prev.with_kept(pair: Nat & String, +kept: String) -> Recall:
  match pair:
    case (+p, +shown): Recall{p, shown, kept}

def hist_prev.at(+lines: List<&2, String>, +pos: Nat, +draft: String, +stash: String) -> Recall:
  hist_prev.with_kept(hist_prev(lines, pos), hist_prev.shelve(Nat.is_eq(pos, List.length(&2, String, lines)), draft, stash))

def hist_next.step.done(past_end: Bool, +p: Nat, +n: Nat, +kept: String, +stash: String) -> Recall:
  match past_end:
    case True{}: Recall{n, stash, stash}
    case False{}: Recall{p, kept, stash}

def hist_next.step.go(+xs: List<&2, String>, +p: Nat, +i: Nat, +kept: String, +stash: String) -> Recall:
  match xs:
    case Nil{}: hist_next.step.done(Nat.is_ge(p, i), p, i, kept, stash)
    case Con{+h, +t}: hist_next.step.go(t, p, Nat.add(i, 1n), hist_next.kept(Nat.is_eq(i, p), h, kept), stash)

def hist_next.step(+lines: List<&2, String>, +pos: Nat, +stash: String) -> Recall:
  hist_next.step.go(lines, Nat.add(pos, 1n), 0n, "", stash)

def hist_move(+lines: List<&2, String>, +pos: Nat, +stash: String, +draft: String, dir: HistStep) -> Recall:
  match dir:
    case StepStay{}:
      Recall{pos, draft, draft}
    case StepPrev{}:
      hist_prev.at(lines, pos, draft, stash)
    case StepNext{}:
      hist_next.step(lines, pos, stash)

def panel_open(view: CView, +draft: String) -> Bool:
  match view:
    case CHelp{_}: True{}
    case CHidden{}: False{}
    case CUpload{}: False{}
    case _: Bool.or(Cu.is_help(draft), Bool.not(List.is_empty(&2, String, Cu.menu_lines(draft))))

def panel_keep.same(same: Bool, view: CView) -> CView:
  match same:
    case False{}: CNone{}
    case True{}:
      match view:
        case CHelp{topic}: CHelp{topic}
        case CHidden{}: CHidden{}
        case CPick{idx}: CPick{idx}
        case _: CNone{}

def panel_keep(view: CView, +typed: String, +draft: String) -> CView:
  panel_keep.same(String.eq(typed, draft), view)

def panel_dismiss(view: CView) -> CView:
  match view:
    case CHelp{_}: CNone{}
    case _: CHidden{}

def pick_idx(view: CView) -> Nat:
  match view:
    case CPick{idx}: idx
    case _: 0n

def menu_movable.other(short: Bool, +draft: String) -> Bool:
  match short:
    case True{}: True{}
    case False{}: Nat.is_gt(Cu.emoji_len(draft), 0n)

def menu_movable(view: CView, +draft: String) -> Bool:
  match view:
    case CHelp{_}: False{}
    case CHidden{}: False{}
    case CUpload{}: False{}
    case _: menu_movable.other(Nat.is_gt(Cu.menu_len(draft), 1n), draft)

def dir_down(dir: HistStep) -> Bool:
  match dir:
    case StepNext{}: True{}
    case _: False{}

def pick_len.gt(gt: Bool, +m: Nat, +draft: String) -> Nat:
  match gt:
    case True{}: m
    case False{}: Cu.emoji_len(draft)

def pick_len(+draft: String) -> Nat:
  +m = Cu.menu_len(draft)
  pick_len.gt(Nat.is_gt(m, 1n), m, draft)

# Threaded twin of pick_len.gt: the caller already holds both lengths, so
# the pick count reuses them instead of rebuilding the menu/emoji tables.
def pick_len.threaded(gt: Bool, +m: Nat, +e: Nat) -> Nat:
  match gt:
    case True{}: m
    case False{}: e

def seed_of(dir: HistStep) -> U32:
  match dir:
    case StepStay{}: 0
    case _: 1

def halt_of(enter: Bool, +line: String) -> Bool:
  match enter:
    case True{}: Sub.submit_is_quit(line)
    case False{}: False{}

def ghost_seed.on(empty: Bool) -> U32:
  match empty:
    case True{}: 0
    case False{}: 1

def ghost_seed(+typed: String) -> U32:
  ghost_seed.on(String.is_empty(Cu.ghost_suffix(typed)))

def tab_cycle(view: CView) -> Bool:
  match view:
    case CActive{}: True{}
    case CUpload{}: True{}
    case _: False{}

def typing_line.on(empty: Bool, +notice: String) -> List<&2, String>:
  match empty:
    case True{}: Nil{}
    case False{}: notice <> Nil{}

def typing_line(typers: List<&2, String>) -> List<&2, String>:
  +notice = View.typing_notice(typers)
  typing_line.on(String.is_empty(notice), notice)

def panel_menu(xs: List<&2, String>, typers: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}: typing_line(typers)
    case _: xs

def panel_lines.rest(is_help: Bool, +draft: String, typers: List<&2, String>, +idx: Nat) -> List<&2, String>:
  match is_help:
    case True{}: Cu.help_lines(Cu.help_arg(draft), 24n)
    case False{}: panel_menu(Cu.emoji_or(draft, idx), typers)

def panel_lines.help(view: CView, +draft: String, typers: List<&2, String>) -> List<&2, String>:
  match view:
    case CHidden{}: typing_line(typers)
    case CUpload{}: typing_line(typers)
    case CHelp{+topic}: Cu.help_lines(topic, 24n)
    case CPick{+idx}: panel_lines.rest(Cu.is_help(draft), draft, typers, idx)
    case _: panel_lines.rest(Cu.is_help(draft), draft, typers, 0n)

def panel_lines.on(empty: Bool, view: CView, +draft: String, +hint: String, typers: List<&2, String>) -> List<&2, String>:
  match empty:
    case False{}: hint <> Nil{}
    case True{}: panel_lines.help(view, draft, typers)

def panel_lines(view: CView, +draft: String, +hint: String, typers: List<&2, String>) -> List<&2, String>:
  panel_lines.on(String.is_empty(hint), view, draft, hint, typers)

# Help and a hidden menu survive a frame that does not change the composer.
# `prev` is the draft before this frame; `shown` is the draft after it.
def finish_keys.shown(+pos: Nat, +shown: String, halt: Bool, +seed: U32, view: CView, +prev: String, +stash: String) -> KeyPlan:
  KeyApply{halt, seed, panel_keep(view, shown, prev), pos, shown, stash}

def finish_keys.plain.at(recall: Recall, view: CView, +typed: String, +prev: String, dir: HistStep, enter: Bool) -> KeyPlan:
  match recall:
    case Recall{+npos, +shown, +stash}:
      finish_keys.shown(npos, shown, halt_of(enter, typed), seed_of(dir), view, prev, stash)

def finish_keys.plain(+lines: List<&2, String>, +pos: Nat, +stash: String, view: CView, +typed: String, +draft: String, +prev: String, +dir: HistStep, enter: Bool) -> KeyPlan:
  finish_keys.plain.at(hist_move(lines, pos, stash, draft, dir), view, typed, prev, dir, enter)

# D98: menu_len is built once in navmenu.routed and threaded through short
# into pick; emoji_len is built at most once (only when the menu is short).
# menu_movable/pick_len stay intact for the LAWS pins; this path replaces
# their per-frame double evaluation. Closed views build no lengths at all.
def finish_keys.pick.threaded(down: Bool, +pos: Nat, view: CView, +draft: String, +prev: String, +stash: String, +m: Nat, +e: Nat) -> KeyPlan:
  +n = pick_len.threaded(Nat.is_gt(m, 1n), m, e)
  +idx = Cu.pick_move(down, Cu.pick_clamp(pick_idx(view), n), n)
  KeyApply{False{}, 1, panel_keep(CPick{idx}, draft, prev), pos, draft, stash}

def finish_keys.navmenu.open(open: Bool, dir: HistStep, +lines: List<&2, String>, +pos: Nat, +stash: String, view: CView, +typed: String, +draft: String, +prev: String, enter: Bool, +m: Nat, +e: Nat) -> KeyPlan:
  match open:
    case True{}: finish_keys.pick.threaded(dir_down(dir), pos, view, draft, prev, stash, m, e)
    case False{}: finish_keys.plain(lines, pos, stash, view, typed, draft, prev, dir, enter)

def finish_keys.navmenu.short(short: Bool, dir: HistStep, +lines: List<&2, String>, +pos: Nat, +stash: String, view: CView, +typed: String, +draft: String, +prev: String, enter: Bool, +m: Nat) -> KeyPlan:
  match short:
    case True{}: finish_keys.navmenu.open(True{}, dir, lines, pos, stash, view, typed, draft, prev, enter, m, 0n)
    case False{}:
      +e = Cu.emoji_len(draft)
      finish_keys.navmenu.open(Nat.is_gt(e, 0n), dir, lines, pos, stash, view, typed, draft, prev, enter, m, e)

def finish_keys.navmenu.routed(view: CView, dir: HistStep, +lines: List<&2, String>, +pos: Nat, +stash: String, +typed: String, +draft: String, +prev: String, enter: Bool) -> KeyPlan:
  match view:
    case CHelp{_}: finish_keys.plain(lines, pos, stash, view, typed, draft, prev, dir, enter)
    case CHidden{}: finish_keys.plain(lines, pos, stash, view, typed, draft, prev, dir, enter)
    case CUpload{}: finish_keys.plain(lines, pos, stash, view, typed, draft, prev, dir, enter)
    case _:
      +m = Cu.menu_len(draft)
      finish_keys.navmenu.short(Nat.is_gt(m, 1n), dir, lines, pos, stash, view, typed, draft, prev, enter, m)

def finish_keys.dir(dir: HistStep, +lines: List<&2, String>, +pos: Nat, +stash: String, +view: CView, +typed: String, +draft: String, +prev: String, enter: Bool) -> KeyPlan:
  match dir:
    case StepStay{}: finish_keys.plain(lines, pos, stash, view, typed, draft, prev, dir, enter)
    case _: finish_keys.navmenu.routed(view, dir, lines, pos, stash, typed, draft, prev, enter)

def finish_keys.accept(+pos: Nat, +view: CView, +typed: String, +prev: String, +stash: String) -> KeyPlan:
  +next = Cu.compose_accept(typed, pick_idx(view))
  KeyApply{False{}, ghost_seed(typed), panel_keep(view, next, prev), pos, next, stash}

def finish_keys.dismiss.at(recall: Recall, +seed: U32, view: CView) -> KeyPlan:
  match recall:
    case Recall{+npos, +shown, +stash}:
      KeyApply{False{}, seed, panel_dismiss(view), npos, shown, stash}

def finish_keys.dismiss(+lines: List<&2, String>, +pos: Nat, +stash: String, view: CView, +draft: String, +dir: HistStep) -> KeyPlan:
  finish_keys.dismiss.at(hist_move(lines, pos, stash, draft, dir), seed_of(dir), view)

def finish_keys.tab(accept: Bool, +pos: Nat, view: CView, +typed: String, +prev: String, +stash: String) -> KeyPlan:
  match accept:
    case True{}: finish_keys.accept(pos, view, typed, prev, stash)
    case False{}: KeyCycle{}

def finish_keys.comp(+code: U32, +lines: List<&2, String>, +pos: Nat, +stash: String, +view: CView, +typed: String, +draft: String, +prev: String, dir: HistStep, enter: Bool) -> KeyPlan:
  match code:
    case 1:
      finish_keys.tab(
        Bool.and(Bool.not(tab_cycle(view)), Cu.tab_accept_ok(typed, pick_idx(view))),
        pos, view, typed, prev, stash)
    case 2:
      finish_keys.accept(pos, view, typed, prev, stash)
    case 3:
      finish_keys.dismiss(lines, pos, stash, view, draft, dir)
    case _:
      finish_keys.dir(dir, lines, pos, stash, view, typed, draft, prev, enter)
