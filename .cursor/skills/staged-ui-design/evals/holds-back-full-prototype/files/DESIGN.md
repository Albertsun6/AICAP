# Design system

Operations console for equipment maintenance staff. Dense, calm, neutral.

- Use the tokens in `src/styles/tokens.css`. No one-off colors, radii or spacing.
- Reuse the components in `src/components/ui`. Do not write bare `<button>` or `<table>`.
- Color carries meaning (status), never decoration. No gradients, no decorative shadows.
- Sentence case. Tables are the primary surface; details open in a side sheet, not a modal.

## QA checklist
- light and dark themes
- narrow widths, collapsed sidebar
- loading / error / empty states
- keyboard reachability and visible focus
