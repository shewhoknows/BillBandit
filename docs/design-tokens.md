# BillBandit design tokens

Source of truth for the DesignSystem layer. Derived from the BillBandit design system
reference (originally `InkReceiptTheme.swift`). Values are exact.

## Colors

| Token | Hex | Use |
|---|---|---|
| `blue` (brand) | `#0F45D6` | THE cobalt — app backgrounds, CTAs, perforation holes, ₹ amounts |
| `cream` (brand) | `#FFF5DE` | text on blue, button faces, inputs, mascot fill |
| `blueDark` (ink navy) | `#082B8F` | text/borders on paper, mascot outlines, dark buttons |
| `blueXDark` (deep navy) | `#071245` | pressed/shadow states only, sparingly |
| `paper` | `#F7F2DE` | receipt card & tab bar surfaces (one step warmer than cream) |
| `success` (settled green) | `#1F8F66` | positive amounts, settled state |
| `danger` (danger ink) | `#A81F33` | debit amounts, destructive actions |
| `faded` (faded ink) | `#54638C` | labels, secondary text |
| `divider` | `#082B8F` @ 20% | dashed perforation lines |
| border (receipt) | `#082B8F` @ 28% | 1pt dashed receipt card border |
| border (field) | `#082B8F` @ 26% | 1pt solid input border |
| border (chip) | `#0F45D6` @ 28% | 1pt solid chip border |

Avatar palette: plum `#6D47C6`, teal `#1A9BA3`, coral `#F26B5C`, sun `#F4BC3D`, leaf `#3DAB6E`.

Aliases: background = blue, surface = paper, textPrimary/body = blueDark,
textFaded = faded, textOnBlue = cream, accent = blue, shadow = black @ 8%.

## Typography roles

iOS uses system font designs; only the handwriting font is bundled.

| Role | Font | Use |
|---|---|---|
| display | system `.serif` (Playfair-like), weights 400–900 | hero titles, card titles, big amounts |
| label / amount / barcode | system `.monospaced` (Space Mono-like) | typewriter labels, ALL-CAPS section headers, stamps, amounts, receipt metadata |
| body | system default/`.rounded` (DM Sans-like) | navigation, buttons, body copy, totals, summaries |
| input (handwritten) | **Caveat** (bundled, `Fonts/Caveat-VariableFont.ttf`) | ALL user-entered values: trip names, destinations, expense titles, notes, nicknames, invite details |

Type scale (pt): 10 barcode label · 11 tab label · 14 body · 16 body emphasis ·
18 section head · 22 card title · 28 amount · 36 display · 48 hero · 64 jumbo amount.
Handwritten text renders ~20–30% larger than the equivalent body size for legibility.

Tracking: +0.05em body mono labels · +0.08em ALL-CAPS section labels · +0.12em stamp/seal text.

Do NOT use handwriting for: dense tables, totals, legal text, buttons, long paragraphs.

## Spacing & shape

- Spacing scale (pt): 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 64, 80.
- Radii: 4 stamp badge · 8 receipt card, in-card buttons, fields · 12 tab bar ·
  18 metric tiles · 22 panels · capsule for main CTAs and chips.
- Shadows: card `y10 blur18 black@8%` · tab `y6 blur14 black@8%` · float `y4 blur12 black@12%`.
- Borders: receipt 1pt dashed navy@28% · divider 1pt dashed navy@20% ·
  field 1pt solid navy@26% · stamp 2pt dashed · chip 1pt solid blue@28%.
- Perforated receipt edge: 12pt notch circles, 22pt gap (punched in brand blue).

## Assets (in `BillBanditApp/Resources/Assets.xcassets`)

`BillBanditRaccoon`, `MascotWelcome`, `MascotPeek`, `MascotThinking`, `MascotLedger`,
`MascotBadge`, `MascotFinal`, `StampFinal`, `AppIcon`. The reformed-raccoon mascot
supports the experience (empty states, welcome, final bill) but never overpowers it.

## Tone

Warm, clever, slightly mischievous, polished. Not corporate, not generic fintech,
not spreadsheet-like. Light mode is primary; dark mode must not damage the warm
receipt aesthetic. Respect Dynamic Type; keep tap targets ≥ 44pt.
