# A Turbo-style IDE in UPLNC — feasibility assessment and design plan

Assessed 2026-07. Status: **in progress; phase 1 landed** (slice 1a 2026-08,
slice 1b 2026-10, slice 1c 2026-11) —
this document records the settled design and its implementation progress (the
ROADMAP links here from the M6 tooling item). The goal: a full-screen text-mode
IDE in the spirit
of Borland's Turbo Pascal / Turbo C++ — blue desktop, pull-down menus,
double-line window borders, F-key bindings — written **in UPLNC**, editing and
building UPLNC (and other languages), with **integrated debugging**. It would
be the largest UPLNC program ever written and the ultimate M7 dogfood: an IDE
written in UPLNC, debugging programs compiled by the compiler written in
UPLNC, through debug information that compiler emits.

## 1. Verdict

Feasible now. Every capability the design needs either exists (most were
built in 2026-07) or has a pragmatic v1 fallback. The known constraints it
will hit (§6) are survivable, and two of them are exactly the kind of finding
dogfooding exists to force.

## 2. Look & feel: the easy part

Borland's UI is character cells. On a modern terminal:

- **Rendering**: ANSI escape sequences — 16-color SGR (the Borland palette
  maps directly: blue desktop, cyan/white menus, black shadows), cursor
  addressing, the alternate screen. Shadows are repainted cells offset by
  one.
- **Compositor**: every widget draws into an in-memory cell grid (glyph ID,
  foreground/background color, attributes). A diff pass flushes only changed
  *cells*. ASCII glyph IDs emit one byte; box-drawing IDs map to the UTF-8 byte
  strings for `═ ║ ╔ ╗ ╚ ╝`. This keeps a three-byte UTF-8 encoding from being
  mistaken for three screen cells and leaves room for an ASCII-border mode.
- **Input**: `read(0, &c, 1)` plus an escape-sequence state machine for
  arrows, F-keys, and Alt (ESC-prefixed) — a calc-sized parser.
- **Terminal lifecycle**: a narrow C portability shim is a v1 requirement,
  not a later refinement. It snapshots the exact `termios`, enters raw mode,
  restores the snapshot on normal teardown/`atexit`, reads `TIOCGWINSZ`, and
  turns SIGWINCH into a flag plus a wakeup byte for the event loop. A hard
  kill cannot be recovered from, but ordinary exits and handled termination
  must not replace the user's settings with a generic `stty sane` preset.

### 2.1 The platform ABI shim

UPLNC's word-sized `int` is 64 bits on four targets, while C `int` remains 32
bits. This affects pointers to C integers even when scalar integer calls happen
to marshal correctly: calling `pipe(fds)` with a UPLNC `[2]int` would place two
adjacent C descriptors inside `fds[0]` on a 64-bit target. A negative C `int`
return can likewise arrive as an unextended 32-bit value on x86_64/arm64. The
shim therefore owns every C-width return/output or C-structure interface used
by the IDE: process/descriptor operations, `termios`, `winsize`, `pollfd`, and
`sigaction`.

Its UPLNC-facing functions use scalar values, ordinary byte buffers, and
`intptr_t` returns/output slots (the same width as a UPLNC `int`). For example,
`ide_pipe(readfd:*int,writefd:*int)` creates a C `int p[2]` internally and
writes each descriptor to a separate `intptr_t`; wrappers for `fork`, `dup2`,
`close`, and child status sign-extend C results before returning them. The shim
contains no editor, terminal-rendering, or debugger policy; it is a small
target portability layer compiled and linked as one additional object.

## 3. Why the language is ready (2026-07 inventory)

| Need | Have |
|---|---|
| Widget/buffer objects | structs with methods, **typed method returns** (PR #113): `buf.line(n):*char` |
| Event-handler tables | function pointers via indirect calls — int/pointer args, `int` return: exactly an event handler's shape (a poor-man's Turbo Vision vtable; no virtual dispatch needed) |
| Text buffers | malloc/realloc/free with proven grow/teardown patterns (`sort_lines.e`); a line-pointer array, gap-style insertion by moving pointers |
| Status lines, dialogs | `lib/fmt.e`: `%d %u %x %c %s %f %e %g`, widths, exact float digits |
| Many-unit program | `langdrv.pl` multi-unit builds, per-unit linking proven by grep/sort |
| Error navigation | langc's `file:line: Error:` diagnostics with include-correct locations — parse stderr into an error window, jump to line |
| Debugging substrate | `-g`: DWARF line tables, CFI unwind, variable/type DIEs — gdb does file:line breakpoints, stepping, `info locals`, struct members, backtraces with parameters (PRs #101–#114) |
| Platform boundary | One narrow C shim for C-width output arrays/structures, exact terminal restoration, resize wakeups, and event polling (§2.1) |

## 4. Integrated debugging: the crown jewel

**v1 design: drive `gdb --interpreter=mi` as a child process.** The process
topology has three independent channels:

1. an IDE-to-gdb pipe for MI commands;
2. a gdb-to-IDE pipe for MI records; and
3. a dedicated pseudo-terminal for the inferior, selected with
   `-inferior-tty-set`, whose bytes appear in a console pane and whose input
   never enters the MI command stream.

The event loop monitors terminal input, gdb MI output, inferior PTY output,
child status, and the resize wakeup through the shim in §2.1. UPLNC owns the
topology and lifecycle; the shim's process primitives only normalize C-width
returns/outputs and keep descriptor arrays and polling structures from crossing
the ABI directly. The command translation is:

| Turbo key | gdb/MI |
|---|---|
| Ctrl-F8 toggle breakpoint | `-break-insert file:line` / `-break-delete` |
| F7 step into / F8 step over | `-exec-step` / `-exec-next` |
| F4 run to cursor | `-exec-until file:line` |
| Ctrl-F9 run | `-exec-run` / `-exec-continue` |
| Watch window | `-var-create`, `-data-evaluate-expression` |
| Call-stack window | `-stack-list-frames` |

MI output is record-oriented text, but it is not safely parsed by splitting on
commas or looking only for line prefixes. The parser must handle result/async/
stream records, optional numeric tokens, C-string escaping, tuples, and lists;
unknown fields are retained or skipped structurally. This works *because of*
the 2026-07 debug-info arc: the IDE presents, in our own UI, exactly what
langc's `-g` emits.

**Stretch (phase 4, compiler-sized project): a native ptrace debugger** —
`ptrace()` is int/pointer-arg (ABI-safe), INT3 breakpoints, single-step,
`.debug_line`/`.debug_frame` reading. Tractable only because we would read
the DWARF subset *we emit*, not general DWARF. Registers via
`PTRACE_GETREGS` need per-arch opaque-buffer offset tables. Do not start
here.

## 5. Other languages

The architecture is language-agnostic by construction: a language profile is
(1) a build-command template, (2) an error-message pattern (gcc emits the
same `file:line:` shape), (3) a keyword table for highlighting, (4) the same
gdb/MI backend (gcc's DWARF is richer than ours, which is fine). "For UPLNC
and other languages" reduces mostly to configuration.

## 6. Constraints it will hit (the dogfood value)

- ~~**15-char identifiers, and `Struct.method` mangles ≤ 15 total**~~ —
  raised (2026-10): identifiers and mangles now hold 63 characters
  (LANGUAGE.md §14).
- ~~**16,000-byte string-literal pool per unit**~~ — removed preemptively
  (2026-08): the per-unit pool grows on demand, so an IDE full of UI text no
  longer hits a wall. Borland's own approach — help/UI text in external files
  loaded at runtime (`TURBO.HLP` style) — remains worthwhile for other
  reasons, but it is no longer forced.
- **No internal linkage** — 15+ units share one namespace; keep the
  `grep_`/`sort_` prefix discipline.
- **Indirect calls return `int` only** — handler tables fit today; a
  pointer-returning handler would extend the typed-return story to indirect
  calls (a natural future language item).
- ~~158-byte source lines, 6000-byte macro pool~~ — raised (2026-10):
  lines hold 1023 bytes and lpp1's macro table grows on demand.

Found while writing slice 1a, both worth knowing before phase 1 continues:

- ~~**Plain braces are not a name scope**~~ — fixed (2026-10): a nested `{ }`
  block now closes its locals like a control-flow body (LANGUAGE.md §5), so two
  `{ var i; }` blocks in one function no longer collide. Shadowing an
  enclosing local is still an error.
- **A typed method must declare its return type in the struct slot**
  (`func line:*char;`); an annotation on the definition may repeat it but not
  introduce it. Nothing else about methods needed working around: sibling
  calls through `this`, `realloc`'d arrays of structs, and indexing a
  method's pointer result all behave.

## 7. Phasing

1. **Platform + screen/input slice** — ✅ landed 2026-07 (`ide/`): `tshim.c`
   (intptr_t-clean termios/winsize/poll/sigaction/pipe; C structs never cross
   the boundary), `tui.e`/`tui.he` (raw mode with exact restore via the
   alternate screen, CSI/SS3/lone-ESC key decoder, diff-rendering cell
   compositor with DEC line-drawing boxes and PC-style attributes), and
   `tuidemo.e`. `langdrv.pl` accepts `.c` units so cross builds compile the
   shim with the target's own cc — with the target's *default* code model
   (the mips64 asm-compat flags break C TLS: errno faulted until the shim
   compiled abicalls). Gated in `run_tests.sh` `[14]`: the pipe round-trip
   and sign-extended-failure checks run on every target with a toolchain,
   and PTY-hosted tests pin exact termios restore, a byte-exact 24x80
   transcript, all decoder forms, and SIGWINCH redraw.
2. **Phase 1 IDE** (~3–5k lines; langc is ~7k): menu bar, one editor window
   (open/save/search/block ops), F9 build with error-jump. *The Turbo feel
   arrives here.*
   - ✅ **Slice 1a: text buffer + editor window** (2026-08). `buf.e`/`buf.he`
     is an `sbuf` **struct with methods** — the design §3 promised, now
     exercised: a growable line array, each line a NUL-terminated string with
     its own capacity, with insert/delete character, split/join line, insert/
     delete line, and load/save. Every operation is bounds-checked and a
     out-of-range index is a no-op, so the editor's cursor arithmetic cannot
     corrupt the buffer. `ed.e` adds the Turbo-blue frame, cursor motion,
     scrolling, and F2/F10, driving the phase-1 compositor; `tui.e` gained
     `tuicurs` for the caret (hidden by default, so the pinned `tuidemo`
     transcript is unchanged), and Alt+key decoding, so **Alt-X** quits --
     Turbo's own binding, and the one that survives terminal emulators that
     capture F10 (MATE Terminal opens its menu bar with it). Gated in
     `run_tests.sh` `[15]`: `buftest.e`
     walks every primitive plus a save/load round trip **on all five
     backends**, and the editor is driven on a pseudo-terminal for
     edit/save, backspace-join, scrolling, and final-newline behaviour.
   - **Palette lesson**: the `C_*` constants are PC/CGA-numbered (bit 0 =
     blue, as Borland used) but ANSI SGR numbers colours in the opposite bit
     order, so `sgrfor` must *translate* rather than copy. Emitting them
     untranslated swapped red and blue: the desktop rendered red, and no test
     noticed, because every assertion checked which characters landed where
     and none ever checked a colour. A user noticed in one glance. The suite
     now pins the emitted SGR.
   - **Test lesson worth keeping**: assertions about the editor read the
     *rendered screen* (`tests/screen.py` replays the escape stream), never
     the raw byte stream. The compositor emits only changed cells, so after a
     scroll no whole line appears contiguously in the output even though the
     user plainly sees it — grepping the stream reports a phantom failure.
   - **Slice 1a file-safety follow-up** (2026-08): loads are transactional — a
     read or close error leaves the prior text and dirty state untouched — and
     saves write a same-directory temporary file, flush and close it, then
     atomically rename it over the destination. Existing modes and symlinks are
     preserved; new files observe the process umask. The editor rejects an
     existing path it cannot load, and F10 on a dirty buffer presents Save /
     Discard / Cancel rather than silently losing work. Terminal EOF performs
     a best-effort atomic save and reports failure after restoring the terminal.
   - ✅ **Slice 1b: menus, dialogs, search, blocks, F9 build** (2026-10),
     completing phase 1's list. `menu.e` is the menu bar with Turbo's
     pull-downs (File, Edit, Search, Compile: black on grey, red hotkeys,
     green selection, drop shadows), opened by F10 or Alt+title letter, and
     the modal dialogs: a one-line input whose starting text is preselected
     so typing replaces it, and a message box. `build.e` runs
     `perl langdrv.pl -march=<host> -o <exe> <file>` through a new shim
     call, `tsh_run` (fork/exec/waitpid with stdin from /dev/null and
     stdout+stderr captured through one pipe, so the child never touches
     the raw-mode terminal), and keeps every output line as a message: a
     line starting `<file>:<line>:` is a location. The editor gains the
     message pane, File Open/Save as (a modified buffer asks first), Find /
     Search again (Ctrl-L) / Go to line, Shift+arrow selection with Cut /
     Copy / Paste / Clear on Turbo's CUA keys, and F9: save, build, and land
     on the first error at langc's caret column (when the echoed line still
     matches), opening an `#include`d file when the error is in one;
     Alt-F8/Alt-F7 step through the errors. F10 now opens the menu, as in
     Turbo, so Alt-X is the quit key everywhere. The key decoder learned
     xterm's modifier parameter (Shift/Alt/Ctrl on arrows, navigation keys
     and F-keys, including `CSI 1;mP`-style F1-F4).
   - **Findings**: the shim grew exactly where §2.1 said it would -- process
     creation and the wait status are C-int and C-struct interfaces, as is
     `uname` (`tsh_machine`), which the build needs because the driver
     defaults to `-march=i386` and a 64-bit host may not be able to link
     that. Nothing in the language got in the way: three new units share
     state through `var extern`, menus are parallel arrays filled at
     startup, and commands are an `enum`. The PTY tests needed one new
     tool, a snapshot mark (`ptyrun.py`'s `s`, `screen.py --snap N`), to
     assert on a menu or dialog while it is open; build results are read
     from the final screen instead, so a slow build cannot race them.
   - ✅ **Slice 1c: undo, Replace, projects, Run** (2026-11), the items
     slice 1b left.
     **Undo/redo** lives in the buffer, not the editor: every primitive that
     changes text logs itself (`ulog`) before acting, so no editing command
     can bypass undo, and the editor only marks where one undo step ends
     (`mark`, with the cursor to put back). A step is one command, or one
     run of keys of a kind -- typing up to and including an Enter,
     Backspaces, Dels -- and undoing back to the saved text makes the
     buffer clean again, so Alt-X no longer asks. Alt-Backspace undoes (ESC
     DEL, or ESC BS where Backspace sends ^H); Redo is on the Edit menu,
     because no common terminal tells Turbo's Shift-Alt-Backspace apart.
     `buftest.e` proves undo and redo of every primitive, the cursors they
     report, and the saved-state bookkeeping on all five backends.
     **Replace** (Search menu) asks for the text and its replacement, then
     stops at each match with the question on the status line, so the
     highlighted match stays in view: Y replaces, N skips, A replaces the
     rest without asking, Esc stops. The whole command is one undo step, and
     Ctrl-L repeats the last Find *or* Replace, as Turbo's Search again did.
     **Projects** follow Turbo C 2.0, whose .PRJ was a plain text file: one
     unit per line (`.e` sources, and the `.c`/`.s`/`.o` files the driver
     also takes), relative to the project file's own directory, with blank
     and `#` lines skipped. F9 compiles every unit into the program named
     after the project (`app.prj` builds `app`), re-reading the list at each
     build, so a project is edited like any other file. `ed app.prj` opens
     its first unit with the project set (a project file that does not
     exist yet opens itself, to be filled in); Project/Open project sets one
     from inside, its menu item showing the current project's name as Turbo
     C's menus showed settings; Close project returns F9 to the open file.
     An error in a unit that is not open opens that unit at the error.
     `ide/ed.prj` is the IDE's own project, so the IDE rebuilds itself from
     inside -- `[15]` does exactly that, from a copy of `ide/`. For such
     steps `ptyrun.py` gained `u:TEXT`, a wait for text on the rendered
     screen, instead of trusting a fixed delay to outlast a build.
     **Run** (Ctrl-F9, or the new Run menu) builds as F9 does, then gives
     the program the terminal itself: the IDE leaves raw mode and the
     alternate screen, so the program writes to the shell's own screen --
     the user screen, as Turbo's was DOS's -- and when it ends the IDE takes
     the terminal back and reports its exit code, or the signal that ended
     it, on the status line. Alt-F5 shows that screen until a key is
     pressed, and Run/Arguments sets the program's arguments (split at
     blanks; a "double-quoted" stretch is one argument). The shim's new
     `tsh_spawn` waits as `system()` does, ignoring SIGINT and SIGQUIT
     while the program runs, so Ctrl-C ends the program and not the IDE;
     `tsh_rawon` now saves the terminal's state only the first time, so a
     program that leaves the terminal in an odd mode cannot change what the
     IDE restores at exit; and `tuiinit` can take the terminal back after
     `tuidone` (it used to leak its output buffer on a second call).
     `shimtest.e` proves `tsh_spawn`'s statuses and both halves of the
     signal handling on every backend with a toolchain; `[15]` runs a
     program, reads its output off the user screen (`screen.py --alt`
     models the primary and alternate screens apart), passes it quoted
     arguments, and stops a spinning one with a real Ctrl-C (`ptyrun.py`'s
     `ctty` makes the pty the controlling terminal).
   - **Findings**: undo belongs in the buffer. Logging there, before each
     primitive acts, makes completeness structural -- paste, cut, Replace
     and every later command are undoable without knowing about undo --
     and it is what makes undo provable on all five backends without a
     terminal. Everything else came from the terminal boundary, as §2.1
     predicted: handing the terminal to a child and back is three shim
     facts (who ignores which signal, which termios to restore, when to
     discard typed-ahead input), and testing it needed the harness to
     model what a real terminal does -- two screens, a controlling tty --
     rather than the IDE to change.
   - **Not yet**: case-insensitive search; Redo has no key (Turbo's
     Shift-Alt-Backspace is indistinguishable from Alt-Backspace in common
     terminals); a project always rebuilds every unit (Turbo's Make
     compared times; the driver has no incremental mode yet).
3. **Phase 2**: gdb/MI debugging — structured MI parser, dedicated inferior
   PTY and console pane, breakpoint margin, F7/F8, watch and call-stack
   windows.
4. **Phase 3**: overlapping/resizable windows, language profiles, help
   viewer from external files.
5. **Phase 4 (optional)**: native ptrace backend, x86_64 first.

## 8. Risks

- **Scale**: the largest UPLNC program by far; compiler robustness at this
  scale is itself part of the experiment (the sanitizer/fuzz + fixpoint
  gates are the safety net).
- **Terminal diversity**: stick to vt100/xterm sequences universally
  supported; degrade box glyphs to ASCII on request.
- **Platform boundary**: keep the C shim narrow and regression-test its public
  scalar/`intptr_t` ABI on every target; no UI or debugger policy belongs in
  it.
- **gdb/MI availability**: gdb is a run-time dependency for phase 2 only;
  the IDE without it is still a full editor/builder.
