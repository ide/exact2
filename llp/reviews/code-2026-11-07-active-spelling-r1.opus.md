# Press-paint spelling retirement: Opus review, round 1

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Ocho account `claude:ide@expo.dev`, in a frozen worktree at `ed8c8c2c93` on `90ce66d41f`.
- **Method:** one brief (sha256 `dcc725896313361a46ca54311eaba5212e0fb458e27e0510f2ad08b1a994d683`), one reviewer, with four passes: correctness, simplification, writing and verification. The reviewer read source only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited.

---

# Press-paint spelling retirement: Opus review, round 1

I reviewed HEAD `ed8c8c2c93b06fd39caae253c4b76ff69efc7c7d` against its base `90ce66d41fbb7af2b6e9f4b9d8eb60d909b976e1` (32 files). This is a source review only. I ran no builds, tests or apps, I changed no files and I started no agents. I used Git, `wc` and `grep` only. All runtime results below are your supplied evidence, not mine.

**Result: no P1 or P2 defect. One plausible P3 in the migration's target check and its documentation. One P3 stale guideline. Two cosmetic notes.**

## Findings

### 1. [P3, plausible] Migrating a `style` block checks no target, and `reference.md` says more than the code does

- **Where:** `contract/syntax/src/migrate/press.rs:16-18` calls `owner(&style.attrs, style.span, false)`, so a class is never treated as an unsupported target. The node check (`press.rs:62-67`) sees only two explicit cases:
  - a tag other than `button` with a literal `appearance="auto"`;
  - a direct child of `text`, `time` or `option`, propagated through `Use`, `When`, `Each` and `Match`.
- **Possible failure:** A class whose old `-exact-press-color` was applied to a paragraph run becomes `:active color` in that class. Class rows are part of the run's `expanded` attributes (`nodes.rs:63`, `:96-99`). `nodes.rs:400-414` then refuses any `:active` row on a run with `lower-state-target`. So `contract migrate` can write a file that compiled before and now fails to lower. A component whose root element is used as a run is the same case.
- **Uncertain step:** Whether the old plain row compiled on a run. The comment at `nodes.rs:396-397` ("D7's press rows paint no run on Apple or Linux either") suggests that it did, but I did not confirm it by running the compiler.
- **Brief:** The brief asks only for *explicit* targets, so the code matches it. The documentation does not.
- **Writing defect (concrete):** `docs/reference.md:198-199` says "unsupported native or inline-text targets are refused without writing the file". That is true only for explicit targets on the node itself.
- **Smallest fix:** Change that sentence to "explicit … targets on the node". As an alternative, say that a class used on an unsupported target is reported at compile time, not by `migrate`.

### 2. [P3] A working-set LLP still prescribes the retired spellings

- **Where:** `llp/1115.000-no-tells-on-every-host.rfc.md:597-598` is linked from `llp/current/`. It names `-exact-press-background-color` and `-exact-press-color` as current authored press feedback.
- **Why it matters:** The other references the layer did not update are records:
  - `1061:410`, an "as built" observation;
  - `1035.005.002:419`, the retirement rationale;
  - `1128:65`, a mechanism note.

  `1115.000` gives present-tense guidance, so it contradicts the guide.
- **Fix:** Rewrite it as "`:active` `background-color` and `color`".

### 3. [Cosmetic] Spacing left by the mechanical edits

- `host/linux/src/presenter/press_paint_tests.rs:14` (`0.5   background-color`) and `:142` (`press=go  color`) keep extra spaces.
- The syntax test at `contract/syntax/tests/it/migrate.rs:23`, `:30` and `:34` asserts the migration's unformatted output exactly ("`   padding=8`", "`column  testId`", the comment indented to column 8). `contract migrate` writes that output as is (`contract/cli/src/migrate.rs:25-31`). This is no regression: earlier repairs also wrote unformatted text, and `contract fmt` normalizes it. But the exact-string test fixes the artifacts in place. If the deletion later takes one adjacent space, this test must change.

## Correctness pass

**Typed lowering.**
- `ACTIVE_ROWS` maps to `StyleId`s (`states.rs:42-50`), and `active_target` returns `AttrTarget::Styles` directly (`:61-64`). It no longer depends on `style_names`.
- Folded rows keep the name `:active <row>` (`states.rs:608-616`).
- `tags::attr` resolves those names through `active_target` (`tags.rs:414-417`). `tags::rows`, `NATIVE_ROWS` admission (`controls.rs:795`, `:812`) and the value checks (`style_names.rs:338`, which tests `PressScale` by ID) all use `StyleId`s.
- The filters that skip state-part names (`states.rs:446`, `:589`, `nodes.rs:405`) run on `expanded` before the fold, so they do not drop the folded rows.
- `checked_as` now returns `:active <row>` (`states.rs:176-181`); `lint.rs:573-586` resolves that name to the same IDs.
- The class-then-node override in the fold uses the new names consistently.
- `lower-state-press-paint` now covers only `opacity` and `-exact-press-scale` (`states.rs:460-464`). The opacity case still compares against the multiplicative base row, as before.
- `popover_surface.rs` no longer strips the prefix, and still counts `:active background-color` as a surface.
- No consumer outside `contract` matches the retired author names. The `--exact-press-*` CSS custom properties in `host/web*` are wire names, which the brief keeps.

**Diagnostics.**
- The shared `active_migration_hint` (`lint.rs:309-317`) serves both node attributes (`unknown_attr`, `lint.rs:332`) and style blocks (`lib.rs:549-552`).
- Only the two canonical names promise `contract migrate`. `underlayColor` and the other nicknames get the manual hint.
- `native.rs:66` and `vocab.rs:394-398` keep working: `renamed` returns a value for the retired names, and the build-time scan picks up the new match arms.

**Migration.** The supplied tests cover these cases, and the code supports them:
- **Spans:** Lexer columns are byte offsets (`lexer.rs:224-227`). `offset` uses `\n` line starts, so non-ASCII text earlier in the line and CRLF line endings work. The lexer and the parser both number from line 1 with `source_id` 0, so the `t.span == owner` and `t.span == attr.span` lookups are sound.
- **Value end:** `attribute_value_end` re-parses the value with the expression grammar from `start + 2`. Ternaries over several lines and following positional values (`text -exact-press-color="red" "title"`) stay correct.
- **Order and repairs:** The rewrite runs after the parser's own repairs and then parses again (`migrate.rs:52-55`), so `trim(text)` → `(text).trim()` inside a moved value is kept.
- **Merging:** The parser allows one `:active` block, written in block form only (`parser/states.rs:57-67`). Inserting at the first active row's line start is therefore always inside that block.
- **Several edits:** A parent's insertion is at a line start, and a child's deletion on that line is always at a later offset. The reverse application is therefore safe. Two insertions cannot share an offset.
- **Atomicity:** Any refusal returns `Err` before anything is written. Edits for earlier owners are discarded, and the CLI writes only on `Ok`.
- **Native buttons:** They are allowed (`tag != "button"`). Each keeps `appearance="auto"`, as the base layer admits.
- **Traversal:** `members` is covered. Decorations and atoms are not traversed; they do not take press rows.

## Simplification pass

No finding. The migration reuses the parser's value grammar and the existing migrate pipeline. It adds no registry and no runtime alias.

## Writing pass

Findings 1 (the `reference.md` sentence) and 2. The guide's new press paragraph (`contract-for-agents.md:3066-3077`) and its state-part paragraph (`:4333-4335`) agree with the code:
- the opacity multiplier versus the absolute value;
- the scale conflict;
- native timing and ownership kept as in the base layer.

The kernel spec, LLP 1061 D7, the LLP 1121 mapping and refusal lists, and the schema comments name private carriers now. Their conflict lists name only opacity and scale.

## Verification pass

- The tree is clean at HEAD, and `git diff --check` is clean.
- Changed counted sources are within the cap. The largest is `contract/lower/src/lib.rs` at 1,485 lines.
- Supplied, not run by me:
  - the syntax suite (39 tests);
  - the native-button migration negative and positive;
  - `native_state` (node and style, with the migrated output compiling);
  - the five migration regressions failing without the call;
  - the retirement regression failing with the old `style_names` rows.
- Not yet available for this child: the full compiler `--tests` run (still compiling), the six checks, difftest, the affected host tests and browser conformance. Firefox was skipped.
- No test covers finding 1's class-on-run case.