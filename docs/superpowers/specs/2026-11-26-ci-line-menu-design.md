# CI line detail as a plain menu

**Intent.** The owner finds the CI panel too heavy: on macOS 26 `NSPopover` is a large glass bubble with an
arrow, a headline and section captions around two rows. Its arrow also missed the line. They want it minimal.

**Approaches.**
- Native menu under the line (chosen): system size and font, no arrow, so no anchor defect.
- A slimmer popover: still the glass bubble and arrow.
- Click opens the single run directly: hides the PR and other runs.

**Design (owner-approved 2026-11-26).**
- A click that the CI line claims opens an `NSMenu` under the line, at its leading edge.
- Items, in order:
  - with a PR: `#<number> <title>` (opens the PR), then one disabled line per review state
    (`Approved: a, b`, `Changes requested: c`); `No reviews yet` when there are none; then a separator;
  - every run, failed, running, passed, skipped: the state glyph `✓ ✗ ◷` in the state's color, then the
    workflow name; a click opens the run. Skipped names are secondary.
- No `branch · sha` headline and no state captions.
- The menu closes when the line goes, as the panel did.
- Mac only; the owner did not ask for a Linux change.
- Control API and the line itself do not change.

**Left to the builder.** Exact glyph colors reuse the panel's; menu font is the system menu font.
