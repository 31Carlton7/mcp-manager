# Design Language Brief — Dense Translucent Utility Panel

**Design language study; branding excluded deliberately.**

**Date:** 2026-08-24 · **Status:** reference · **Scope:** visual language only. No behaviour, no architecture.

## 0. What this document is

A neutral, measured description of a visual language observed in a shipping macOS
menu-bar utility, written so it can be implemented without reference to the app it
was measured from. Everything below is either a number, a colour value, or a
structural description.

Three ground rules governed the writing, and they govern the reading too:

1. **No identity.** Names, marks, icons, logotypes, badge treatments and anything
   else that says *which* app this was are excluded on purpose. Where the observed
   app placed a brand mark, this brief says "a header slot" and moves on. The
   studied project reserves its name, logo, icon, bundle identity and trade dress
   separately from its source licence, so identity is out of scope by both law and
   intent. We are taking a **measurement system**, not a look-and-feel.
2. **Facts only.** Spacing, radii, opacities, type sizes, weights, tracking, colour
   values, column widths, structural prose. No opinions smuggled in as observations.
3. **Generic is labelled generic.** Much of what makes a macOS app feel native is
   just macOS. Where a choice is stock platform practice — the system font, system
   materials, the system accent colour, a standard split-view sidebar — this brief
   says so, so the implementer knows it is a default to accept rather than a
   decision to reproduce.

The short version of the language: **small type, heavy weights, three tiers of
translucent fill, sub-pixel hairlines instead of shadows, positive tracking on tiny
uppercase labels, and a semantic colour palette that is defined twice — once for
light and once for dark.**

---

## 1. Window and panel structure

### 1.1 The menu-bar panel

A fixed-width panel, **332 pt** wide overall with a **308 pt** content column
inside a **12 pt** frame padding on all four sides. Width never varies. Height is
computed: it is clamped to a minimum of **220 pt** and a maximum derived from the
available screen height, and otherwise tracks the measured height of its content,
so a short section produces a short panel.

Vertical composition, top to bottom, at **12 pt** between blocks:

1. Optional full-width notice banner (see §8).
2. A header slot, **28 pt** tall plus **4 pt** vertical padding.
3. A persistent navigation strip (icon tabs).
4. A scrolling content region, fixed at the 308 pt column width, whose height is
   measured from its content.
5. A persistent footer of two actions.

The chrome above and below the scroll region is budgeted at a constant **180 pt**
(plus banner height plus 12 pt when a banner is present). The scroll region gets
whatever is left, and never less than 80 pt.

Per-section content heights are pre-estimated in the range **140–500 pt** and used
for the first frame, so the panel opens at roughly its final size rather than
snapping after layout.

### 1.2 Drill-down mode

Selecting a detail target swaps the navigation strip for a back-row while keeping
the header and footer fixed in place. The back-row is a **24 × 24** button at
radius **7** on the card fill with a **0.7** hairline, followed by a title at
**12.5 pt semibold** with a leading glyph. The panel width and padding do not change.

### 1.3 The settings window

A standard macOS split view: sidebar left, page right, minimum **772 × 528**, with
the sidebar column constrained to min **198** / ideal **210** / max **240**. The
sidebar is a stock system sidebar list with grouped sections and a search field
pinned above it. **This is generic macOS practice** — a plain platform split view
with platform list styling, not a custom construction — and should be adopted as a
default rather than rebuilt.

### 1.4 Floating command surface

A separate centred palette, **560 pt** wide at radius **22**, on a high-contrast
HUD backdrop, with rows at radius **10**. Included here only because its radius and
width sit at the top of the scale and establish its outer bound.

### 1.5 First-run window

Fixed **540 × 600**. Page indicator dots are **7 × 7**, with the active dot
stretched to **18 × 7** — a pill, not a larger circle. Frame padding **16**;
content padding **24**; body columns inset **28** from the frame edge.

---

## 2. Surface system

Depth is built from **fill plus hairline**. There are essentially no shadows: a
survey of the interface turns up exactly one, a **2 pt** coloured glow at **0.6**
opacity behind a status dot. Cards do not lift, hover does not raise, and selection
does not cast. Everything separates by tinted fill and a sub-pixel border.

### 2.1 Three fill tiers

| Tier | Role | Light | Dark |
|---|---|---|---|
| Base | The panel shell itself | white @ **0.68** | black @ **0.42** |
| Card | Grouped content inside the shell | white @ **0.38** | white @ **0.075** |
| Control | Inset wells, fields, pressable chrome | black @ **0.055** | white @ **0.085** |

Note the inversion: the light scheme lightens the shell and the card but *darkens*
the control tier, so an inset control reads as a recess in both schemes.

### 2.2 The shared hairline

| | Light | Dark |
|---|---|---|
| Border colour | black @ **0.09** | white @ **0.11** |

Applied as an inside stroke at **0.8 pt** on the panel shell and on footer buttons,
and at **0.7 pt** on cards and inline controls. Both are sub-pixel at 2× and read
as a seam rather than an outline.

### 2.3 Panel shell composition

Radius **18**, continuous corners. Two construction paths:

- **Standard:** the system *regular* material, overlaid with the base fill from
  §2.1, overlaid with the 0.8 hairline. The tint over the material is deliberate —
  it stabilises contrast so text does not depend on the wallpaper behind it.
- **Modern (macOS 26+, opt-in):** the system glass effect in place of the material,
  with the base fill applied at reduced strength — multiplied by **0.35** in light
  and **0.45** in dark — plus the same 0.8 hairline.

The modern path falls back to the standard path whenever the option is off or
**Reduce Transparency** is enabled. Both materials are stock system materials; the
tint-over-material technique is the only non-generic part.

Material usage across the whole interface is narrow: *regular* material 12 times,
*ultra-thin* 3 times. Nothing else.

### 2.4 Card composition

Radius **10**, continuous. Padding **10** on all sides. Card fill plus the **0.7**
hairline. This one construction is reused roughly **50 times** across the
interface — it is the workhorse of the language.

### 2.5 Inline fills not in the token set

Observed one-off fills, all as an opacity over the primary or accent colour:

| Use | Fill | Radius |
|---|---|---|
| Inset value tile | primary @ 0.045 | 7 |
| Keyboard-hint chip | primary @ 0.06 | 5 |
| Progress well | primary @ 0.06 | 10 |
| De-emphasised row | primary @ 0.035 | 7 |
| Small icon button | primary @ 0.07 | 7 |
| Toggled icon button | primary or accent @ 0.10 | 7 |
| Bar track | primary @ 0.08 | capsule |
| Neutral badge | primary @ 0.08–0.12 | capsule |
| Grouped card (settings) | secondary @ 0.08 | 8 |
| Selected row | accent @ 0.12–0.14 | 8–10 |
| Hover backing | primary @ 0.10 | circle |

The pattern worth extracting: **structural fills come from the token set; incidental
fills are a low opacity of primary, between 0.035 and 0.12.**

### 2.6 Radius scale

By frequency of use: **7** (46), **8** (38), **6** (33), **10** (30), **14** (27),
**12** (17), **9** (14), **18** (13), **4** (10), **22** (8), **16** (8), **5** (7),
**13** (7). Every rounded rectangle uses **continuous** ("squircle") corners; not a
single circular-corner rectangle appears.

Read as a system: **5–7** for chips and small buttons, **8–10** for cards and rows,
**12–14** for containers, **18** for the panel shell, **22** for the floating
palette.

### 2.7 Stroke widths

**1.0** (50), **0.8** (10), **1.5** (6), **2.0** (5), **0.5** (5), **1.2** (4),
**0.7** (3). The sub-pixel values (0.5–0.8) are reserved for surface borders; 1.0
and above are for drawn content such as graph strokes and dividers.

---

## 3. Typography

### 3.1 Family

The system sans throughout — **SF Pro**, via the platform's system font. No custom
typeface is bundled. **This is generic macOS practice.** One deliberate exception:
the *rounded* system design is used for large numeric readouts and for keyboard-hint
chips (§3.4).

### 3.2 Size distribution

Point sizes by frequency:

| Size | Uses | | Size | Uses |
|---|---|---|---|---|
| 11 | 122 | | 12.5 | 17 |
| 10.5 | 114 | | 8 | 15 |
| 12 | 105 | | 16 | 15 |
| 10 | 100 | | 13.5 | 15 |
| 9.5 | 55 | | 15 | 13 |
| 9 | 55 | | 8.5 | 7 |
| 13 | 49 | | 22 | 7 |
| 11.5 | 29 | | 19 | 6 |
| 14 | 28 | | 26–54 | rare |

The working range is **9–13 pt**, centred on **10.5–12**. Sizes of 16 and above
appear almost exclusively in first-run and about surfaces. This is a **denser
register than the macOS default** (13 pt body); adopting it is a real decision, not
an inherited default.

### 3.3 Weight distribution

**semibold** (304), **medium** (160), **bold** (63), **light** (10), **regular** (4).

Regular is almost never named — a size given without a weight *is* regular. The
consequence: hierarchy is carried by **weight at a constant size**, not by size.
A 12 pt semibold title sits above a 10 pt regular caption; the same title at
regular would disappear.

### 3.4 Roles

| Role | Spec |
|---|---|
| Section label | **10 pt semibold, uppercased, kerning +0.5, secondary** |
| Row title | 12 pt semibold |
| Row caption | 10 pt regular, secondary |
| List body | 10.5–11 pt |
| Numeric readout | 11 pt medium, monospaced digits, right-aligned |
| Inset tile value | 15 pt semibold, **rounded design**, monospaced digits |
| Micro badge | 8–9.5 pt bold, uppercased, tracking +0.4 |
| Keyboard chip | 9 pt semibold, **rounded design**, tertiary |
| Disclosure chevron | 8–9 pt semibold/bold, tertiary |
| Footer action | 11 pt medium |
| First-run title | 26 pt bold |
| First-run body | 12 pt |

The **10 pt uppercase semibold section label with +0.5 kerning** is the single most
repeated typographic gesture in the language and the clearest identifying trait.

### 3.5 Monospace

Two distinct uses, and the distinction matters:

- **Monospaced digits** — 63 occurrences. Applied to *every* number that changes:
  percentages, byte counts, temperatures, durations, progress values. Prevents
  column jitter as values tick.
- **Full monospace** — 39 occurrences. Applied to technical values: paths, commands,
  identifiers, raw configuration.

Prose is never monospaced.

### 3.6 Tracking

All observed tracking is **positive**: +0.5 (5 uses), +1.2 (2), +1.0, +0.6, +0.4
(1 each). It appears only on small uppercase labels, where it is doing the standard
job of opening up capitals at small sizes. **No negative tracking appears anywhere**
in this language — but note that negative tracking on large numerals is unrelated
standard practice and is not contradicted by this observation (see §9.2).

### 3.7 Overflow behaviour

Single-line labels truncate at the tail; process and file names truncate in the
**middle** so the informative end survives. Footer buttons carry a minimum scale
factor of **0.78**, so a long localised string shrinks before it truncates. Two-line
titles are allowed in navigation rows and use a fixed vertical sizing so the row
height is stable.

---

## 4. Colour

### 4.1 Accent

The **system accent colour**, read from the user's macOS setting. It is not a
hardcoded brand hue. **This is generic macOS practice.** One page-local exception
tints a single control with a fixed indigo at RGB **0.35, 0.40, 0.94** (89, 102, 240).

Accent appears as:

| Use | Treatment |
|---|---|
| Active tab glyph | accent foreground |
| Active tab backing | accent @ **0.13** light / **0.20** dark |
| Selected row | accent @ **0.12–0.14** |
| Enabled icon tile | accent fill, white glyph |
| Primary badge | accent capsule fill, contrasting text |
| Small circular badge | accent @ **0.12** fill, accent glyph |
| Confirm button | accent fill, white label |

The two-value active-tab tint (0.13 / 0.20) is worth noting: the dark scheme needs
more opacity for the same perceived presence.

### 4.2 The dual-tone metric palette

The most transferable idea in the language. Seven semantic hues, each defined
**twice** — a hand-darkened value for the light scheme, and the plain system colour
for dark. The stated reason is that the system's default hues are too bright to read
as *text* on a light translucent surface.

| Hue | Light (0–1) | Light (0–255) | Dark |
|---|---|---|---|
| green | 0.00, 0.44, 0.18 | **0, 112, 46** | system green |
| cyan | 0.00, 0.43, 0.54 | **0, 110, 138** | system cyan |
| mint | 0.00, 0.44, 0.40 | **0, 112, 102** | system mint |
| yellow | 0.56, 0.36, 0.00 | **143, 92, 0** | system yellow |
| orange | 0.68, 0.30, 0.00 | **173, 77, 0** | system orange |
| red | 0.68, 0.08, 0.10 | **173, 20, 26** | system red |
| pink | 0.68, 0.06, 0.34 | **173, 15, 87** | system pink |

The generative pattern is consistent: **at least one channel at 0.00, a dominant
channel at 0.56–0.68, and a mid channel around 0.44 or below.** These are deep,
fully-saturated, low-lightness colours — they behave as ink, not as fills. The dark
column is simply the system palette, which is already tuned for dark surfaces.

Usage frequency: green (12), red (7), orange (6), yellow (5), pink (4), cyan (3),
mint (2). Green dominates because it is the resting state.

### 4.3 Status semantics

A three-step ladder plus an unknown state:

| State | Hue |
|---|---|
| Normal / healthy / resting | green |
| Warning / elevated | yellow |
| Critical / failed | red |
| Unknown / unavailable | secondary grey |

Observed thresholds, as examples of the granularity: a charge readout turns **red
below 20**, **yellow below 40**, green above. A pressure readout turns **yellow at
0.85** of its range and **red above**. Two-step and three-step ladders both appear;
the ladder is always evaluated against the *value*, and the resulting hue then
colours the label, the bar fill and the dot together.

**Orange is reserved for "experimental / prerelease"** and is not part of the health
ladder: fill @ **0.16**, border @ **0.35** at 0.5 pt, orange text.

### 4.4 Neutral text ramp

Primary / secondary / tertiary, from the platform's semantic hierarchy — **generic
macOS practice**. Tertiary is used consistently for chevrons, keyboard chips and
inactive hints; secondary for captions and section labels; primary for row titles
and values.

---

## 5. Controls

### 5.1 Style distribution

| Button style | Uses | Picker style | Uses |
|---|---|---|---|
| plain (custom-drawn backing) | 130 | segmented | 34 |
| bordered-prominent | 58 | menu | 15 |
| bordered | 55 | radio group | 1 |
| borderless | 42 | inline | 1 |

**Segmented is the default picker.** Plain is used wherever the control draws its
own background — which is most of the panel. Bordered and bordered-prominent are
platform-standard and appear mostly in settings pages. **All of these are stock
platform control styles.**

### 5.2 Toggles

The system switch, at **mini** control size inside dense panel rows and at default
size in settings. Checkboxes (28 uses) are used for multi-option lists in settings,
switches (14 explicit) for single on/off features. Labels are hidden on the control
and supplied by the row.

### 5.3 Buttons — measured

| Control | Size | Radius | Glyph | Backing |
|---|---|---|---|---|
| Small icon button | 22–24 sq | 6–7 | 10.5–11 semibold | primary @ 0.07, or card fill + 0.7 hairline |
| Toggled icon button | 24 × 22 | 7 | 11 bold | primary or accent @ 0.10 |
| Inline confirm | h 24, pad-x 8 | 8 | 10.5 bold + label | accent fill, white content |
| Footer action | min-h 28, pad-x 7 | 7 | 11 medium + label | card fill + 0.8 hairline, secondary content |
| Tab segment | h 30, equal widths | 8 | 13.5 semibold | accent @ 0.13/0.20 when active, clear when not |

### 5.4 Navigation strip

A row of icon-only segments at **2 pt** spacing, inside a container with **4 pt**
padding, radius **12**, card fill and a **0.7** hairline. Segments divide the width
equally. Active segment takes the accent foreground and the accent tint at radius
**8**; inactive takes secondary at **0.86** opacity over a clear background.

### 5.5 Bars and graphs

**Progress bar:** a capsule track at primary @ **0.08**, a capsule fill in the
current semantic hue, height **5 pt**, with the fill clamped to a **3 pt minimum
width** so a near-zero value is still visible as a dot rather than vanishing.

**History graph:** height **22 pt**. A polyline stroked at **1.5 pt** with round caps
and round joins, over a filled area beneath it — a vertical gradient from the hue at
**0.16** opacity down to the hue at **0**. An optional zero baseline at **1 pt**,
secondary @ **0.28**. Drawn as a plain path; no charting framework is involved.
Vertical scale is either pinned to an absolute maximum (for percentage metrics) or
auto-scaled to the series peak (for unbounded ones).

### 5.6 Search

In panels, a search affordance is composed inline: a magnifier glyph beside a plain
text field on a control-tier fill. In settings, the stock platform search modifier
is used against the sidebar. **The settings case is generic macOS practice.**

### 5.7 Motion

Durations by frequency: **0.15 s** (21), **0.12** (9), **0.18** (8), **0.20** (4),
**0.16** (3), **0.22** (2), **0.14** (2), **0.10** (2), **0.30** (2). Nothing above
0.3 s for a state change. Ease-out is the named curve for hover transitions. The
overall character is **fast and unshowy** — 0.12–0.18 s is the operating band.

---

## 6. Lists and cards

### 6.1 The navigation row — the repeated unit

Horizontal spacing **9 pt**:

- Leading glyph at **15 pt semibold** in a fixed **22 pt** column, accent-tinted.
- Text block, internal vertical spacing **1 pt**: title at **12 pt semibold**
  (wrapping to at most 2 lines), caption at **10 pt** secondary.
- Trailing: an optional keyboard-hint chip, then a **9 pt semibold tertiary**
  chevron.
- Keyboard-hint chip: 9 pt semibold rounded design, tertiary, padding **5 × 2**,
  radius **5**, fill primary @ **0.06**.

**Each row is wrapped in its own card** (§2.4 — radius 10, padding 10, card fill,
0.7 hairline), and rows are separated by the **12 pt** block gutter. Rows read as
discrete plates, not as a continuous divided list. This is the single most
recognisable layout trait after the section label.

### 6.2 The metric row

Spacing **8 pt**, built on fixed columns:

| Element | Width |
|---|---|
| Disclosure chevron | 8 pt glyph, semibold |
| Leading icon | fixed **10 pt** column |
| Label (11 pt) | fixed **52 pt**, leading-aligned |
| Bar | flexible, fills remainder |
| Value (11 pt medium, mono digits) | fixed **38 pt**, trailing-aligned |

Because the panel width is fixed, absolute column widths are safe and nothing
reflows as values change.

### 6.3 The process row

Spacing **7 pt**: a **15 pt** application icon, a name at **10.5 pt** with **middle**
truncation, and a value at **10.5 pt medium** monospaced-digit in secondary.

### 6.4 The inset value tile

Used in rows of three across the content column. Radius **7**, fill primary @
**0.045**, vertical padding **6**, internal spacing **3**. A caption line pairs a
**9 pt** glyph with a **10 pt** label, both secondary; below it the value sits at
**15 pt semibold rounded** with monospaced digits. Tiles expand to equal widths.

### 6.5 The settings feature row

A **30 × 30** icon tile at radius **8** — accent-filled when the feature is active,
secondary @ **0.22** when not — carrying a **13 pt semibold** glyph. Beside it: a
title with inline badge capsules, then a caption. A trailing action button closes
the row. Row spacing **10**, vertical padding **1–3**.

### 6.6 The grouped card (settings)

Padding **9**, minimum height **96**, radius **8**, fill secondary @ **0.08**. Title
at **12 pt semibold**, body at the platform caption size, action button at the
bottom.

### 6.7 Status indicators

- **Dot:** a **7 × 7** circle in the semantic hue, with a **2 pt** shadow of the
  same hue at **0.6** opacity — the only shadow in the language. A **6 × 6** variant
  without the glow is used in denser settings rows.
- **Labelled pill:** the dot plus an **11 pt medium** label, both in the hue,
  padding **8 × 3**, on a capsule filled with the hue at **0.13**.
- **Micro badge:** **8 pt bold uppercased** with **+0.4** tracking, padding
  **5 × 1.5**, capsule filled with the hue at **0.16** and stroked with the hue at
  **0.35**, 0.5 pt.

### 6.8 Hover and selection

**Hover is deliberately faint.** The full inventory: a primary @ **0.10** circle
behind an icon button, and a secondary → primary foreground change. Both animate
over **0.12 s** ease-out. No lift, no scale, no shadow change, no border brightening
on cards.

**Selection** is an accent tint — **0.14** in the floating palette, **0.12** on
settings list rows — at the row's own radius, with no border change.

### 6.9 Dividers

A **1 pt** rule at secondary @ **0.16**, or the stock platform divider, placed
*between blocks inside a single card* at **10 pt** spacing. Cards themselves are
separated by the 12 pt gutter, not by rules.

---

## 7. Density and whitespace philosophy

The spacing system is modular but not rigid, and the module changes with scale:

| Scope | Module |
|---|---|
| Panel frame and blocks between cards | **12** |
| Inside a card | **10** |
| Row internal horizontal rhythm | **8–9** |
| Tight pairs and label/value stacks | **1–6** |

Observed vertical stack spacings cluster at **1, 2, 3, 5, 6, 7, 8, 10, 12, 16**. The
small end is used generously: a title and its caption sit at spacing **1** or **2**,
which is what makes them read as one object; unrelated blocks sit at **10** or
**12**. The gap between "related" and "unrelated" spacing is roughly **5×**, and
that ratio is what does the grouping work — not rules, not boxes.

Five principles follow from the measurements:

1. **Small type, heavy weight.** The 10–12 pt working range is well below the macOS
   13 pt default. It only holds together because weight carries the hierarchy — see
   §3.3. Shrinking type without also leaning on semibold produces mush.
2. **Fixed columns over proportional layout.** Because the panel width never varies,
   numeric and label columns are pinned to absolute widths (52, 38, 22, 10). Nothing
   shifts as content changes.
3. **Monospaced digits everywhere a number changes.** See §3.5. This is what lets
   the fixed columns stay still.
4. **Shrink before truncating.** Minimum scale factors on constrained labels;
   middle-truncation where the tail is the informative part.
5. **Everything is hideable.** Sections collapse, reorder, and can be removed
   entirely — and a removed section leaves the navigation strip as well, so the
   chrome shrinks with the content rather than showing empty affordances.

---

## 8. Menu-bar popover patterns

Consolidating the panel-specific findings:

**Width and height.** Fixed **332 pt** outer / **308 pt** content. Height is
measured from content and clamped between **220 pt** and a screen-derived maximum.
The panel is genuinely self-sizing — a two-row section produces a small panel — which
is what keeps a dense design from feeling heavy.

**Sectioning by tabs, not by scroll.** One section is visible at a time, selected
from a persistent icon strip (§5.4), rather than all sections stacked in one long
scroll. A user preference switches between this tabbed mode and a stacked mode.

**Scrollers.** Overlay scrollers only, never a reserved gutter — otherwise a
fixed-width content column would shift off-centre when the system is set to always
show scrollbars.

**Footer.** Always present, always two low-emphasis actions in equal halves: row
height **30**, top padding **4**, spacing **8**. Buttons per §5.3. The footer never
carries a primary action.

**Header slot.** A **28 pt** tall centred slot with **4 pt** vertical padding. In
the observed app this holds a brand mark; **that use is excluded from this brief**.
Structurally it is simply a fixed-height centred header band, with room for a
leading badge and a trailing icon button when needed.

**Notice banner.** A full-width bar above the header when there is something to
announce: radius **10**, padding **12 × 9**, filled with the accent (or orange for a
prerelease), white content. A **16 pt** leading glyph, a **12 pt semibold** title
over a **10.5 pt** subtitle at white @ **0.85**, and a trailing action rendered as a
**white capsule** whose *label* takes the banner's tint colour — an inversion, so the
action reads as the brightest element. Padding **10 × 4** on the capsule.

A quieter variant for in-progress states drops the colour entirely: same geometry,
fill primary @ **0.06**, an **11.5 pt medium** label, a small platform progress
indicator, and a **10.5 pt medium** monospaced-digit percentage.

**Drill-down.** Replaces the tab strip only; header and footer stay fixed (§1.2).

---

## 9. Translation to MCP Manager

How the language above maps onto our existing surfaces. Where our current design
already agrees, this says so; where it differs, this says which way to move and why.

### 9.1 Token changes (foundation — do these first)

**Spacing.** Our scale is 4 / 8 / 12 / 16 / 20. Add **10** for card interiors. The
studied 12-outer / 10-inner / 8-row / 1–4-pairs cascade maps onto our scale cleanly
with that one addition.

**Surfaces.** We currently have a single card treatment: radius 16, regular
material, 1 pt border. Replace it with the three-tier fill system of §2.1 plus the
shared hairline of §2.2:

| Our surface | Change |
|---|---|
| Popover shell | radius **18**, regular material + base fill (white 0.68 / black 0.42) + **0.8** hairline |
| Cards (grid, catalog rows, inspector groups) | radius 16 → **12**, card fill (white 0.38 / white 0.075) + **0.7** hairline |
| Wells, fields, paste box | new control tier (black 0.055 / white 0.085) |
| Border width | 1 pt → **0.7** inside, **0.8** on the shell |

We keep radius 12 rather than the observed 10 for grid cards — our cards are larger
objects at a 220 pt minimum width and hold more content, so the slightly softer
corner is proportionate. Everything else adopts the observed values.

**Type.** Our label style is 11 pt medium at +0.4 tracking. Move it to the observed
**10 pt semibold uppercase at +0.5** and use it for *every* section label — popover
hero captions, main-window group headings, inspector group headings, settings page
sections. This one change does more than any other to make the surfaces read as one
system. Our body (13) and caption (11) stay; add **12 semibold** as the row-title
style and **10 secondary** as the row-caption style.

**Colour.** Adopt the dual-tone palette of §4.2 wholesale as our semantic set. This
matters specifically for us: our client chips and health dots currently use system
green and red, which is exactly the case the dual-tone palette exists to fix —
coloured *text* on a light translucent card. Green becomes **(0, 112, 46)** in light
and system green in dark; red becomes **(173, 20, 26)** / system red; yellow becomes
**(143, 92, 0)** / system yellow.

**Motion.** Our 0.14–0.18 s snappy timings are already inside the observed
0.12–0.18 s band. No change.

### 9.2 Popover with hero numbers

Structure maps almost one-to-one. Our ~330 pt width and the observed 332 are the
same decision; adopt **332 / 308 / 12 pt padding** exactly.

- Replace our fixed `maxHeight` of 320 with the **measured, self-sizing scroll
  region** of §1.1, clamped to a 220 pt floor and a screen-derived ceiling. Budget
  the fixed chrome as a constant and give the rest to the list. This is a real
  improvement: with one client configured, our popover should be short.
- Our **Servers | Clients** picker becomes the navigation strip of §5.4 — 4 pt
  container padding, radius 12, card fill + 0.7 hairline, active segment at radius 8
  with accent @ 0.13 light / 0.20 dark. Keep **text** segments rather than icons;
  with two tabs, labels are clearer, and the container treatment is what carries the
  look.
- **Hero numbers stay at 34 pt** — see §10. Only their caption changes, to the
  10 pt uppercase semibold +0.5 label. Note the tracking directions do not conflict:
  the observed language uses positive tracking on *small uppercase labels*, which is
  what our caption becomes; our **−2% on the 34 pt numerals** is standard practice
  for large numerals and is unaffected by §3.6.
- Server rows adopt the metric-row column discipline (§6.2) rather than free layout:
  icon column, flexible name, trailing control at a fixed width.
- The **"Sign in" pill** becomes the labelled status pill of §6.7 — 7 pt dot plus
  11 pt medium label, capsule at hue @ 0.13, in the dual-tone yellow.
- Client rows: health dot per §6.7, "N servers" at 10.5 medium monospaced-digit.
- **Footer** already matches the pattern (two quiet actions). Adopt the measured
  spec: row height 30, top padding 4, buttons at min-height 28 / radius 7 / card
  fill + 0.8 hairline / 11 pt medium secondary.
- Our error captions become the quiet notice-banner variant of §8 — fill primary @
  0.06, radius 10, 11.5 medium label — with the hue coming from the dual-tone
  palette rather than raw red/orange.
- **Header slot:** we deliberately leave it empty. The observed app puts its mark
  there; we do not have one to place and do not want one. Our identity is the menu
  bar icon (§10).

### 9.3 Servers grid + inspector

**Grid cards.** Keep the adaptive 220 pt minimum and 10 pt grid spacing. Card
becomes: radius 12, card fill + 0.7 hairline, padding 10. Icon 26 at radius 7 (ours,
unchanged), name 12 semibold, subline 10 secondary. **Client chips** become the
status pill of §6.7 in dual-tone green when enabled and secondary grey when not.

**Selection and hover.** Keep our accent-border-on-selection and 0.18-on-hover
treatment rather than adopting the observed accent-fill selection. Reason: our cards
sit in a grid where a filled selection would fight the client chips inside the card
for the same accent colour; a border keeps the two separable. This is a considered
divergence, not an oversight.

**Inspector.** Adopt the fixed label/value column discipline of §6.2 — a **52 pt**
leading label column, values at 10.5–11 pt, monospaced digits for anything numeric.
The URL and command lines take **full monospace** per §3.5, which our spec already
called for and which the studied language confirms as the right register for
technical values. Group headings take the 10 pt uppercase label. The per-client
switch rows take the compact row form: 15 pt glyph in a fixed column, 11 pt medium
label, mini switch trailing.

### 9.4 Catalog

The clearest adoption target. Catalog entries become **rows-as-plates** (§6.1): each
entry its own radius-12 card at padding 10, separated by 12 pt gutters, containing a
22 pt icon column, a 12 semibold title, a 10 secondary description of up to two
lines, and a trailing chevron or Add button. This is a straight lift of the observed
pattern and suits a browsable list of installable things better than a divided list.

### 9.5 Add sheet

- The **smart-paste well** takes the control tier fill (black 0.055 / white 0.085)
  at radius 10 — the recessed reading is exactly what a paste target wants.
- The **detection summary line** sits at 10 pt secondary directly beneath the well
  at 4 pt spacing, so it groups with the field.
- **Advanced disclosure:** an 8–9 pt tertiary chevron beside an 11.5 pt semibold
  secondary label, with the disclosed contents indented **19 pt** from the leading
  edge — the observed indent for nested option groups.
- The env / headers key-value rows take the compact row form at 8 pt spacing.
- Disabled controls (the auth picker) take the observed **0.35 opacity** treatment
  for non-interactive elements rather than being hidden.

### 9.6 Settings

**Keep the stock split view.** The observed app uses a plain platform sidebar list
too — §1.3 — so there is nothing to adopt here beyond confirming that the generic
choice is the right one. Match the column constraint (min 198 / ideal 210 / max 240)
and the minimum window size (772 × 528) since ours is currently 820 × 520.

Page content adopts the settings feature row (§6.5): a **30 × 30** tile at radius 8,
accent-filled when the thing is enabled and secondary @ 0.22 when not, with a 13 pt
semibold glyph; title with inline badge capsules; 10 pt caption; trailing action.
Grouped explanatory blocks take the grouped card (§6.6) — padding 9, radius 8,
secondary @ 0.08.

### 9.7 Onboarding

Adopt the first-run geometry directly: fixed **540 × 600**, frame padding 16,
content padding 24, body columns inset 28. Title **26 bold**, body **12**. Page
indicator dots **7 × 7** with the active dot as an **18 × 7 pill**. Feature rows
pair a 30 pt tile at radius 8 with a 13 semibold title and an 11.5 caption. Choice
rows are radius-10 plates at 14 × 10 padding with a card fill and a hairline that
takes the accent when selected.

---

## 10. Keep from the current design

These are ours, they work, and nothing in the studied language should displace them.

1. **The menu bar icon.** A template PDF at 18 × 18, recoloured by macOS to match
   the bar like the system glyphs beside it, with the daemon health dot at the
   bottom-right corner shown only when health is *not* ok. This is our identity in
   the one place the user always sees us, and the studied language has nothing to say
   about it — it places a mark *inside* its popover header, which we deliberately do
   not do. **Unchanged.**

2. **Health-dot semantics.** Green healthy / red unhealthy per client; a
   daemon-level dot on the menu bar icon, hidden when everything is fine; the
   hairline ring against the bar background so the dot reads at any wallpaper. The
   *meaning* is ours and stays exactly as it is. Adopt only the **rendering** — the
   7 × 7 size, the 2 pt glow at 0.6 opacity, the labelled-pill form when a dot
   carries text — and swap the raw system green/red for the dual-tone pair so the
   light scheme holds up. Semantics unchanged; pixels upgraded.

3. **Hero numbers.** 34 pt semibold, −2% tracking, monospaced digits, numeric-text
   content transition, under a small-caps label: *Active*, *Clients*, *Needs
   attention*, with the third turning yellow when non-zero. The studied language has
   no equivalent — its largest readout is 15 pt — because it is showing many live
   metrics at once, while we are showing three counts that answer "is everything
   fine?" at a glance. That is a different job and it earns the size. **Keep the
   numbers; change only the caption style** to the 10 pt uppercase semibold +0.5
   label, and take the *Needs attention* yellow from the dual-tone palette.

4. **Cards as material, not glass.** We already reasoned that glass samples and
   refracts every frame, that a scrolling grid of them is a real cost, and that the
   platform reserves glass for controls floating *above* content — so our cards are a
   material and glass stays on header pills and the popover. The studied app arrived
   at the same split independently: a material-plus-tint shell, and no glass on
   scrolling content. **Confirmed, keep.**

5. **System accent, not a brand hue.** Both designs read the user's macOS accent
   setting. **Keep.**

6. **Our spacing scale.** 4 / 8 / 12 / 16 / 20 survives intact; it only gains a 10
   for card interiors. **Keep.**

7. **Press feedback on chips.** Our 0.96 scale plus 0.75 opacity on press, skipped
   under Reduce Motion. The studied language has no press treatment to offer — it
   relies on platform button styles — and ours is better for custom-drawn chips.
   **Keep.**

8. **Reduce Motion and Reduce Transparency respect.** Both designs gate their
   effects on the accessibility settings. Ours already does. **Keep**, and extend the
   Reduce Transparency gate to the new shell treatment per §2.3.
