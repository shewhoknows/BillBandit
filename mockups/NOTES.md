# Mockup verdict (2026-07-17)

**Question:** which visual direction for the BillBandit iOS app?
**Answer:** **B — Cobalt Club.** Full-bleed cobalt `#1F3FC3` screens, cream `#EFEFD7` line-art
raccoon + display type, cream cards/sheets with cobalt ink where content needs
to be quiet (group cards, add-expense sheet, recent-activity card).

- Raccoon mascot: approved direction — bandit-mask line-art raccoon, poses:
  wave / peek / receipt / celebrate / friend. Final app assets to be hand-tuned
  further but keep this construction (6pt strokes, rounded caps, single colour).
- Typography: chunky rounded display (Fredoka-like) + handwritten script
  accents (Caveat-like) + clean rounded sans for body.
- Key animation moments: onboarding intro, settle-up celebration (confetti pop,
  raccoon hop, coin spin, success haptic).

Plan approved **with changes** — see conversation for the change list
(to be filled in once the user specifies them).

The mockup board (`index.html`) is throwaway — do not port its code to the app;
port the decisions above.

# Outline contract locked (2026-07-19)

- Capsule, pill and rounded-control outlines must use the shared
  `BrandOutline.control` width and an inset `strokeBorder`. Do not introduce
  ad-hoc thin or centred strokes for this class of component.
- Achievement artwork must use `AchievementBadgeView` everywhere, including
  Profile, unlock toasts and future achievement surfaces. Its source keyline is
  cropped beneath one app-owned circular ring, so the art stays flush with the
  outline without a visible gap or double ring.

# Product defaults locked (2026-07-18)

- **Currency:** Indian rupee (`₹`) is the v1 default across dashboard, invoices,
  balances, settlement, activity, and expense entry. Multi-currency stays v1.1.
- **Form capitalization:** names use word-capitalized keyboards; group names,
  expense titles, and notes use sentence capitalization. Saved values also
  normalize their first character so paste/hardware keyboards cannot bypass it.

# Mascot assets locked (2026-07-18)

**Question:** keep the mockup's hand-drawn inline raccoon art, or switch to the
official SVG set?
**Answer:** **official set.** All old hand-drawn raccoon art removed from the
board; every screen now uses the production files from
`../BillBandit-Raccoon-SVG/`, **inlined** into `index.html` as `<symbol>`s
(`#m-greeting` etc.) because Safari refuses to `<img>` local SVG files from a
`file://` page. Source of truth remains the external files; colours untouched.

- Six poses: `neutral` · `greeting` · `celebrating` · `grumpy` · `thinking` ·
  `confused` — two flat colours: cobalt ink `#2942C9` on warm cream `#F7F1DD`,
  transparent background, 1280×1280 viewBox.
- Files used **untouched** (no recolour to the mockup's `#1F3FC3`/`#EFEFD7`).
  On cobalt screens the ink details go tone-on-tone and the mascot reads as a
  cream silhouette — accepted, echoes the original line-art direction.
- Screen mapping: B1 onboarding → greeting · B2 home/activity → confused ·
  B3 invoice → grumpy (pairs with the YOU OWE stamp) · B4 add expense →
  thinking · B5 settle celebration → celebrating · B6 friends → greeting
  (reused) · B7 mood sheet → all six.
- Old poses retired: cool (skateboard), peek, receipt, friend. Full-body square
  art can't half-peek over cards — mascots now sit/stand on card edges instead.
