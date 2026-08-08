# UX review — twelve real scenarios

Each scenario was walked through against the actual screens and stores, looking
for the moment a user would get stuck. Findings that led to a change are marked
**Fixed**; ones that remain are stated as limits rather than glossed over.

---

## 1. First launch, nothing set up

**Path:** Setup wizard → address → connection test → optional token → camera →
power provider → done.

The wizard tests the connection before letting you past it, so a typo is caught
where it happened rather than three screens later. The default address is the
documented Tailscale IP, which is right for this user and editable for anyone
else.

**Finding — Fixed.** Demo mode is offered in the wizard, so the app is explorable
before the Pi is ready.

**Remaining limit:** the wizard cannot verify the Tuya credentials without the
plug being reachable. It says so instead of implying success.

---

## 2. "I want to print something" — the core loop

**Path:** Home (READY) → *Choose a model* → tap a card → *Slice and print* →
material/quality/infill/supports → checklist → progress.

Four taps from launch to slicing. No G-code jargon appears anywhere on this
path: no layer heights in millimetres, no profile ids, no infill patterns.

**Finding — Fixed.** The first draft showed the estimate from the library
record, which is wrong once you change infill or quality. The estimate now
scales with both, so the number on screen matches what you chose.

---

## 3. Watching a print from bed

**Path:** Home → the state card → *Printing*.

The model picture is the largest element. Progress, layer and remaining time sit
under it. The camera is one segment away, and side-by-side works one-handed in
portrait.

**Finding — Fixed.** The filename was originally the headline. It is now
`caption2`, tertiary colour, truncated in the middle, and last in the stack —
present for the moment you need it, never competing with the picture.

---

## 4. A print that did not come from the library

**Path:** someone uploads G-code through Mainsail; the app is watching.

The honest failure. The app cannot know what that G-code looks like.

**Finding — Fixed.** Rather than filling the picture area with the filename, the
screen shows a dashed placeholder, "Unknown model", and one line explaining why.
The filename still appears in its normal small position.

---

## 5. Searching in Arabic, with a typo

**Path:** Library → "ميدليه".

Results appear as you type, debounced at 280 ms. Each result carries a one-word
reason — "close spelling" — so a fuzzy match does not look like a bug.

**Finding — Fixed.** The backend emits detailed reasons (`fuzzy:0.83`,
`coverage:2/3`, `alias-partial`) which would have rendered as missing
localisation keys. They now collapse to six stable labels, and an unrecognised
reason shows nothing rather than a raw key.

---

## 6. Coming back to a finished print

**Path:** notification → Home (COMPLETE).

The state card says the print finished and, in one line, that the bed needs
clearing before the next one. The primary action is the queue; power-off is
secondary and refuses while the bed is still hot, naming the temperature.

**Finding — Fixed.** Power-off originally sat next to the queue as an equal
action. Turning the printer off is the less common intent and the more
consequential one, so it is now visually secondary.

---

## 7. Queueing three prints overnight

**Path:** Library → *Add to queue* ×3 → Queue.

The intent that must not be satisfied. The user wants three prints to run
unattended; the printer cannot clear its own bed.

**Design decision, not a finding.** The queue screen states this in one sentence
("Nothing starts automatically. Confirm the bed is empty first."), disables the
start button, and names the blocker. Frustrating by design, and the frustration
is explained rather than left as a dead button.

---

## 8. The monitor flags something at 2 a.m.

**Path:** notification → Printing screen.

The banner names what was seen, what was done about it, and the confidence. When
the detection came from the heuristic it says so in the banner itself, so nobody
mistakes a rough edge-density reading for a trained model's judgement.

Two actions: *Got it* dismisses, *First layer looks fine* resets the baseline.
The second is the one that stops repeats, so it is offered right there.

**Finding — Fixed.** The first version only had *Got it*, which dismissed the
symptom and left the cause. The baseline reset is now one tap from the alert.

---

## 9. Filament runs out mid-print

**Path:** Home → the *Running low* card → Filament.

The one-tap print flow checks before slicing and shows "Only just enough" or
"Not enough filament" with the numbers.

**Finding — Fixed.** The check must not block when no spool is configured — the
app simply does not know, and refusing to print because of missing bookkeeping
would be worse than the risk. It reports "No spool configured - not checking".

---

## 10. Something breaks and the user is not an expert

**Path:** Home (ERROR) → *Help* → paste the message, or tap the current error.

The translator keeps the original text visible under the Arabic explanation,
always. Someone who ends up on a forum needs that string verbatim.

**Finding — Fixed.** An unmatched message originally showed nothing useful. It
now returns `matched: false` with an explicit "No stored explanation for this
message" and the original, rather than an empty card.

---

## 11. Sharing an STL from another app

**Path:** Files → share sheet → Neptune Remote.

The extension saves the file and says how many, then offers to open the app.

**Finding — accepted limit.** The extension cannot upload directly, because the
backend token is in the app's Keychain and putting it somewhere the extension
could read would weaken the whole scheme. The extension says the model is saved
and that opening the app finishes the job — and the app does finish it, on
launch or on foreground, retrying anything that failed.

---

## 12. Using the app on a bad connection

**Path:** mobile data, Tailscale flapping.

Sockets reconnect with exponential backoff capped at 30 s. The last snapshot
stays on screen with an offline banner rather than blanking.

**Finding — Fixed.** Errors originally accumulated as a stack of banners. There
is now one dismissible banner per store with a *Try again* button, so a flapping
link produces one message, not twenty.

---

## Cross-cutting notes

**Simple vs Advanced.** Simple Mode is the default and hides jog, terminal,
speed factors and velocity limits — but hides nothing permanently: everything is
still reachable under *More*. A beginner is not blocked, and an expert is not
made to hunt.

**Arabic first.** Arabic is the primary language, and the phrasing is Egyptian
colloquial rather than formal Arabic, because that is how the user actually
speaks. RTL is driven by the app's own language setting, not just the system's.

**Where the app says "no".** Every disabled control has a reason attached in the
same view — no camera, no FFmpeg, no slicer, bed not confirmed, printer hot,
print running. A greyed-out button with no explanation appears nowhere.
