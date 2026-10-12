# Undercurrent: the app's design language

Borrowed from [qoves.com](https://www.qoves.com/): clinical-editorial, slate and white, thin large
numerals, mono uppercase labels, hairline cards, pill buttons. The site reads like a lab report
about you; the app reads like a lab report about your board.

## Tokens (`Design/Theme.swift`)

| Token | Light | Dark | Used for |
|---|---|---|---|
| `ink` | `#233137` | `#F2F5F5` | body text |
| `inkDeep` | `#0B1315` | `#FFFFFF` | display headings, primary buttons |
| `muted` | `#758084` | `#9AAEB5` | secondary text, mono labels |
| `slate` | `#9AAEB5` | `#758084` | the second line of a two-tone title |
| `slateLight` | `#CDDBE1` | `#2D3B41` | tracks, chart fills |
| `slateFill` | `#AEC2C9` | `#5D767E` | the IDEAL band on a track |
| `hairline` | `#E8E8E8` | `#233137` | card borders, row dividers |
| `canvas` | `#F9FBFB` | `#0B1315` | page background |
| `canvasDeep` | `#F2F5F5` | `#111B1E` | inset surfaces, chips |
| `surface` | `#FFFFFF` | `#16222A` | cards |
| `accent` | `#DEFFFF` | `#1E3A3F` | the one highlight (error banner) |

Type: the web uses PP Neue Montreal (sans, weights 200–500) and F37 Zagma Mono. The app uses SF Pro
at `.light`/`.regular`/`.medium` and SF Mono. Display text is 24–34pt light; numerals are 40pt light
monospaced-digit; eyebrow and axis labels are 9–11pt mono uppercase with 1pt tracking.

Shape: cards 16pt radius with a 1px hairline and a 4% shadow; insets 10pt; chips 6pt; buttons are
capsules. Gutter 16pt. One spring (`Theme.spring`), one press style (`.pressable`).

## Components (`Design/Components.swift`)

- `Eyebrow`: `THE BOARD` in a hairline pill, above every screen title.
- `TwoToneTitle`: first line ink, second line slate ("Track the board / read the current").
- `Card`: the white surface everything sits in.
- `Chip`: tag, count, status; `mono: true` for uppercase status chips.
- `PillButtonStyle`: primary (dark), secondary (white, hairline), quiet (inset), destructive.
- `NumberedRow`: `[1]` mono index then content, the site's numbered lists.
- `StatTile` + `TrackBar`: the biometrics tile: title, verdict chip, big number, a track with a
  `YOU` marker and an `IDEAL` band and mono scale labels.
- `RingGauge`: a thin ring with a number in it.

## Screens

Home (the board) → Task → Stage / Retransform / Run sheets; Closed sheet; Add sheet; Call cover;
Insights (biometrics) and Settings off the toolbar. See `../MOBILE_APP.md` for what each one does.

## Rules

- No raw colors or fonts in views; everything goes through `Theme`.
- Every measure on Insights is computed from the real board. There is no illustrative data.
- Error states say what happened and what is still true ("The task stays staged.").
- A 501 from the backend is a state, not an error: the screen says "not built yet".
