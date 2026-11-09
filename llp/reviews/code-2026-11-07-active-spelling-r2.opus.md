# Press-paint spelling retirement: Opus review, round 2

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Ocho account `claude:ide@expo.dev`, in a frozen worktree at `e41f6d6b37` on `90ce66d41f`.
- **Method:** one follow-up brief (sha256 `bf41d91c9f1c213be06c5e736b689fef6da028057a98782375687e469f5c2f6c`), one reviewer, with four passes: correctness, simplification, writing and verification. The reviewer read source only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited.

---

# Press-paint spelling retirement: Opus review, round 2

I reviewed HEAD `e41f6d6b3709c70ba6efbb727e3b3d56c45f6ffa` against base `90ce66d41fbb7af2b6e9f4b9d8eb60d909b976e1`. I read the whole layer again and focused on the delta since `ed8c8c2c93`. This is a source review only. I ran no builds, tests or apps, I changed no files and I started no agents. I used Git, `wc` and `grep` only. All runtime results below are your supplied evidence, not mine.

**Result: no defect remains. I agree with all three R1 settlements and with the gallery fix.**

Delta since `ed8c8c2c93`: `contract/cli/src/gallery/inert.rs` (+2/−1), `docs/reference.md`, two Linux fixture strings, one paragraph in `llp/1115.000`, and the R1 record. No lowering, syntax, host or schema source changed.

## R1 settlements

**1. Migration target boundary: agree.** `docs/reference.md:198-201` now states exactly what `press.rs` checks:
- conflicting active rows (`press.rs:120-121`);
- directly nested inline text (`press.rs:68`, propagated through `Use`, `When`, `Each` and `Match`);
- literal `appearance="auto"` on tags other than `button` (`press.rs:62-67`).

It says that classes and component uses are checked at compile time, and it names `contract build` and `contract fmt`. Both commands exist (`contract/cli/src/main.rs:76` for `build`).

Leaving those cases to the compiler is the right split. The syntax crate cannot depend on lowering. `:active` on a run is refused by design, and `lower-state-target` (`nodes.rs:408-413`) tells the author what to do. Your probe agrees with my R1 trace: the class compiled on the base, migrated, and then failed with that diagnostic. That probe result is supplied evidence.

**2. Stale working-set guideline: agree.** `llp/1115.000-no-tells-on-every-host.rfc.md:597-598` now names `background-color` and `color` in `:active`. The other references I named in R1 are historical or mechanism records, so keeping them is correct. Optional wording only: "`-exact-press-opacity`, and `background-color` and `color` in `:active`" has two "and"s in a row.

**3. Cosmetic notes: agree.**
- `press_paint_tests.rs:14` and `:142` now have single spaces.
- The exact-output migration test is acceptable, given that `contract migrate` keeps the source as written and leaves formatting to `contract fmt` (`contract/cli/src/migrate.rs:25-31`). I said in R1 that the old repairs also wrote unformatted text, so I make no claim about formatting.

## Gallery regression fix

`contract/cli/src/gallery/inert.rs:389-392` now removes the state prefix before it calls `style_names::lookup`.
- `:active background-color` and `:active color` resolve to colour codecs.
- `:active opacity` resolves to a float, which is neither a colour nor a length. This matches its private carrier.
- `:active -exact-press-scale` resolves as before.
- `::placeholder …` still returns `None` from `state_of` and fails the lookup, as before.

This is the correct cause. Before this layer, the fixture's press paints were plain public rows that `lookup` resolved by name. After the move into `:active`, the raw name `:active color` resolves to nothing. Using `tags::attr` would also work, because it routes `:active` through `active_target`. The fix chosen gives every state the base property's codec, which is what a sample value needs.

**Sweep for other consumers of the retired names:**
- There are only two other direct `style_names::lookup` callers. `tags.rs:418` is reached only after `tags::attr` has handled `:active`, so it is correct. `warnings.rs:1003` (`Paints::of`, the scheme-fixed colour warning) never matched the private `PressColor` or `PressBackgroundColor`, and it does not match `:active` names now. Its behavior is unchanged, so this is no regression.
- Every other name-based consumer in `contract/cli` and `contract/lower` goes through `tags::attr` or `tags::attr_valued`, which resolve `:active <row>`. These include `lean.rs:873`, `snapshot/paragraphs.rs:80`, `theme/rows.rs:425`, `controls.rs:980`, `fields.rs:168`, `svg.rs` and `native.rs`.
- `git grep` finds no remaining source consumer of `-exact-press-background-color` or `-exact-press-color`, apart from the intentional `renamed` arms, the migrator, the hint and the tests. The `--exact-press-*` wire names in `host/web*` are unchanged, as specified.

## Passes

- **Correctness:** No defect. My R1 conclusions on the full layer still hold: the typed `ACTIVE_ROWS`, folded `:active` names resolved by ID, the opacity and scale conflicts, the hint split, the migration's spans, merging, edit order and atomicity, and admission of native buttons. The delta adds no new path.
- **Simplification:** No finding. The gallery fix is the smallest local change, and the docs fix adds no apparatus.
- **Writing:** No defect. The `reference.md` sentence now matches the code. The `1115.000` wording note above is optional.
- **Verification:**
  - The tree is clean at HEAD, and `git diff --check` is clean against the base.
  - `inert.rs` is 520 lines, and the other changed counted sources are within the cap.
  - The R1 record's header and opening match my R1 message. I did not compare the whole record line by line.
  - Supplied, not run by me: syntax (39 tests), focused `native_state`, the migration negatives, difftest quick (70.1 s), Chrome and WebKit press-paint conformance, and the R1-tree build, clippy, fmt, workspace and boot. The test run there had only the gallery failure, and caps reported only the unchanged foldables recipe.
  - Still pending in your report: the Linux suite, `TableFeedKeyMacTests`, and the final Rust checks with the gallery fix. No test I can see pins the gallery fix besides the existing `a_string_written_as_a_style_row_gets_a_value_of_its_kind`, which you report now passes. Firefox was skipped.