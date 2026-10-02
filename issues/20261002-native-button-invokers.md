# Native buttons that open menus and dialogs: the alternatives

**Status:** Draft for discussion, 2026-10-02. Nothing here is built.
**Context:** main at `220c2128`. LLP 1069.011 (native buttons), LLP
1069.011.000 (native buttons everywhere; D5 and D9 keep native *invokers*
refused), LLP 1021 (menus: the popover, its invoker, the native pull-down),
`QUEUE.md` "Native buttons as menu invokers".

## 1. The problem

A native button (`button appearance="auto"`) cannot open a popover or a
dialog. Contract refuses an opening `popovertarget` or `commandfor` on one; a
row that only *closes* its popover or dialog is admitted. So any button whose
job is to open something has to be a custom button, and loses the platform's
look.

The use cases, each a button you would want native:

| Use case | Written today | Opens |
|---|---|---|
| Confirm a consequential action (Delete, Sign Out, a remote command) | `button commandfor=confirm-delete command="show-modal"` | a modal `dialog` with the action and Cancel |
| Choose a destination ("Open in…" Apple Maps, Google Maps, Waze) | `button popovertarget="open-in"` | a menu-shaped popover of choices |
| The same choice from a settings row, or a "nothing installed" notice when there is no choice | the same, `commandfor` when there is no choice | the popover, or a `dialog` |
| Explain a value inline ("Updated 2 min ago") | `button popovertarget="updated-at"` | a small content popover |

A related case is not opened by a button: an alert for an error the app
learns about later, shown from state (`dialog open=(error != "")`).

## 2. What exists on main

- **Menus (LLP 1021).** A container with `popover` and a `button` naming it
  with `popovertarget`, by `id`. The host owns the open state, the top layer,
  light dismiss and Escape. A menu-shaped popover (button rows and `hr`, no
  other content) is presented natively: on iOS, `MenuHost.sync` lays a
  transparent `UIButton` over the invoker with `showsMenuAsPrimaryAction` and
  a `UIMenu` built from a `UIDeferredMenuElement`, which first presses the
  invoker's own `press` and reads the rows 80 ms later
  (`MenusIOS.swift:106-130`). macOS uses `NSMenu`.
- **Confirmations.** A `dialog`, or a popover with `role="alertdialog"`,
  opened by `commandfor`/`popovertarget`, is a `UIAlertController` action
  sheet: a transparent overlay button's touch-up calls `openConfirmation`
  (`MenusIOS.swift:88-104`, `:239`). Its rows are the action and cancel.
- **Native buttons (LLP 1069.011).** A `Control` of type `button` whose face
  (title, symbol, label) is kernel data (`press_face`). The control takes the
  touch; its primary action runs the node's activation routine: resolve the
  target (own `press`, else an ancestor's), focus, dispatch `press` once.
- **Why invokers were deferred (QUEUE).** A native invoker's activation would
  have to be one routine across pointer, keys, shortcuts and the agent:
  resolve and press the target once, revalidate after the synchronous batch,
  then open exactly once from the control, with no second provider run under
  `presentMenu`. Today macOS's `Presenter.press` opens the menu before any
  revalidation (`PresenterMac.swift:684-689`), and iOS's deferred provider and
  `openConfirmation` press only the invoker's own handler.

**The hard part is ordering a press with an opening.** It is not the
presentation; that already exists for custom buttons.

## 3. The alternatives

Each is shown on the two main use cases: confirming an action, and
choosing a destination.

### A. Declarative, by reference (the HTML way, as main has it)

Keep `popovertarget` and `commandfor` on a native button. The host puts the
menu on the native control itself (`UIButton.menu`,
`showsMenuAsPrimaryAction`) instead of on an overlay, and a dialog's
presentation in the control's primary action.

```
button appearance="auto" buttonStyle="filled" commandfor=`confirm-${command}` command="show-modal" aria-label=label
  image `symbol:sf/${symbol}`
  text label
dialog id=`confirm-${command}` closedby="any"
  text `${label} ${item}?`
  button appearance="auto" destructive=destructive press=run(command) commandfor=`confirm-${command}` command="close"
    text label
  button appearance="auto" commandfor=`confirm-${command}` command="close"
    text "Cancel"

button appearance="auto" buttonStyle="filled" popovertarget="open-in"
  image "symbol:sf/map"
  text "Open in Maps"
column id="open-in" popover="auto" role="menu"
  button press=pick("apple") popovertarget="open-in" popovertargetaction="hide"
    text "Apple Maps"
  …
```

- **For:** the web's own names (LLP 1017 §8.1); the web host gets it by
  identity; no open state in the plan (LLP 1021); nothing new to learn; the
  agent's `tap` and the painted fallback stay as they are.
- **Against:** the ordering problem in §2, in full, if the invoker also has a
  `press`. Ids must be unique, so a loop builds them (`confirm-${command}`).
  The popover is far from its button in the source.
- **A cheap first slice:** admit a native invoker **only when nothing would
  press**: no `press` of its own and none on an ancestor that would take its
  activation. Then the activation routine is only "open", and every blocker
  the reviews found (pressing before revalidating, pressing twice) cannot
  arise. An invoker for any of the §1 use cases needs no `press`: opening is
  its whole job. An invoker that needs both stays custom until the full
  routine is built.

### B. Declarative, as a child of the button

The menu or dialog is a child of the button that opens it, read as data,
as the face already is (LLP 1069.011 D5). This is the shape of SwiftUI's
`Menu { … } label: { … }` and of UIKit's `UIButton.menu`.

```
button appearance="auto" buttonStyle="filled"
  image "symbol:sf/map"
  text "Open in Maps"
  menu
    button press=pick("apple")
      text "Apple Maps"
    button press=pick("google")
      text "Google Maps"

button appearance="auto" buttonStyle="filled" aria-label=label
  image `symbol:sf/${symbol}`
  text label
  confirm title=`${label} ${item}?`
    button destructive=destructive press=run(command)
      text label
```

- **For:** local, no ids, so loops need no string-built names. The button
  plainly owns what it opens. The face grammar already walks the button's
  children; it gains one optional `menu` or `confirm` child. One lowering
  covers every host. The ordering problem is the same as A's, but it is
  visible to Contract: it can refuse a `press` on a button that has a `menu`
  child.
- **Against:** not HTML: a `button` cannot own a popover on the web. Contract
  would lower B to A on the web (a generated `id`, `popovertarget`, a sibling
  popover), a declared deviation in LLP 1001. It is a second way to say A,
  so the docs, the agent and the projections all learn two spellings. And
  "buttons inside a button" needs care: today a native button inside a custom
  one is refused, and rows inside a `menu` child are a new context.
- **Variant B′:** sugar only. Contract rewrites B to A before lowering, so no
  host, kernel or agent change: one source of truth (A), a nicer spelling.

### C. Declarative, as props (data)

The menu or confirmation is a prop of the button, as data.

```
button appearance="auto" buttonStyle="filled"
  menu=(installed(apps) | map(app => {title: app.name, symbol: app.symbol, press: pick(app.id)}))
  text "Open in Maps"

button appearance="auto" buttonStyle="filled"
  confirm={title: `${label} ${item}?`, action: label, destructive: destructive, press: run(command)}
  text label
```

- **For:** it maps one-to-one onto the platform APIs (`UIMenu` children,
  `UIAlertController` actions), so projection is simple. The rows can be
  computed from data, with no `each` in the markup.
- **Against:** actions inside data (`press: pick(app.id)`) are a new kind of
  value for Contract. Every per-row feature (`disabled`, `aria-checked`,
  `destructive`, a submenu, a separator) becomes a schema field, re-inventing
  the markup the rows already have. The web would have to synthesize elements
  from data. The furthest from "the web is the standard".

### D. Imperative, from the press

The button only presses. Its action asks the host to present something and
gets the choice back, as `fetch` or the share sheet (LLP 1069.003) do.

```
button appearance="auto" buttonStyle="filled" press=remove
  text "Delete"

action remove
  choice = confirm(`Delete ${item}?`, actions: [{title: "Delete", destructive: true}])
  if choice == "Delete"
    run("delete")
```

- **For:** it removes the ordering problem entirely. The press runs first,
  the action decides whether to ask, and the host presents once, after the
  batch. It suits a confirmation decided at runtime, e.g. ask only when the
  engine is running. There are no ids and no popover nodes, and the agent
  sees the request as an effect it can answer.
- **Against:**
  - It cannot make a **pull-down menu**: iOS opens `UIButton.menu` from the
    control on touch-down, before any runner round trip. An imperative
    request can only produce an action sheet or alert after the press, which
    is a different and less native affordance for a chooser.
  - The open state becomes the plan's, not the host's (LLP 1021).
  - A new effect needs its web, Linux and agent arms.
  - It is a second model next to `dialog`.

### E. Declarative, from state (`open=`)

The button presses and sets state; a `dialog` (or popover) is shown while its
`open` expression holds, as an error alert already is (`dialog open=` on
this branch, 83ca7f34).

```
button appearance="auto" buttonStyle="filled" press=ask("delete")
  text "Delete"
dialog closedby="any" open=(asking == "delete") close=cancelAsk
  …
```

- **For:** it works with native buttons today, with nothing new in the
  invoker path. One presentation path for "opened by a button" and "opened by
  an event".
- **Against:**
  - The open state is in the plan, against LLP 1021's rule, with a write-back
    on dismissal (`close=`) and the two-sources-of-truth risk that brings.
  - A runner round trip before presenting.
  - Like D, it cannot make a pull-down that opens on touch-down.
  - Every author writes the same `asking` slot by hand, the "hand-rolled
    overlay" LLP 1021 §2 set out to end.

## 4. Comparison

| | Pull-down menu (touch-down, anchored) | Confirmation | Ordering problem | Web | New concepts |
|---|---|---|---|---|---|
| A by reference | yes | yes | yes (none in the first slice) | by identity | none |
| B child | yes | yes | yes, but Contract sees it | lowered to A | a `menu`/`confirm` child |
| C props | yes | yes | yes | synthesized | actions as data |
| D imperative | no (sheet only) | yes | none | new arm | a presentation effect |
| E state | no (sheet only) | yes | none | `open` attribute | plan-held open state |

## 5. Recommendation

1. **Now: A's first slice.** Admit `popovertarget`/`commandfor` on a native
   button that has no press to run (its own or an ancestor's). The control
   itself carries `UIButton.menu` with `showsMenuAsPrimaryAction` for a
   menu-shaped popover, and its primary action calls `openConfirmation` for a
   dialog or `alertdialog`. On macOS, the `NSButton`'s action opens the
   `NSMenu` or the dialog. No overlay over a native button. This covers all
   of §1's use cases and is the platform's own idiom. The tests:
   - one presentation per tap, key and agent `tap`
   - a menu that opens from the control on touch-down
   - an invoker with a `press` still refused, naming the custom button
2. **Next: the full routine**, as the QUEUE entry describes, for invokers that
   also press: resolve and press once, revalidate after the batch, open once.
3. **Then consider B′** (child syntax as sugar for A) if locality and loops
   keep producing `id` bookkeeping in apps. It adds no host work.
4. **Keep D in reserve** for confirmations decided at runtime. Do not use it
   for choosers: a pull-down from the button is the native affordance there,
   and only A/B/C produce it.
5. **E stays** for presentations not opened by a button: errors, prompts
   from events. It should not be how buttons open things.

## 6. Open questions

- Should a destination chooser be a pull-down menu (`role="menu"`, opens
  from the button) or a confirmation-style action sheet
  (`role="alertdialog"`)? The HIG says a chooser of destinations is a
  pull-down; marking it `alertdialog` asks for an action sheet.
- On macOS, should a native invoker with a menu be an `NSPopUpButton`
  (pull-down style) rather than an `NSButton` that opens an `NSMenu`?
- Should the first slice's rule ("no press to run") be checked by Contract
  statically, through ancestors, or at runtime by the host? Contract sees the
  ancestors (LLP 1069.011.000 D5's context walk), so statically seems
  possible.
