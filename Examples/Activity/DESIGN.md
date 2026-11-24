# Weekly activity screen

One scrolling screen that shows a week of activity. The target is an iPhone with a 393 × 852 pt screen, in light mode.

## Code

- `ActivityView.swift` is the screen. It already has `week`, the data, and `range`, the selected segment of the range picker.
- `Week.swift` has the data. It is done.
- Put the palette and these small views in `Components.swift`:

  | View | Stored properties |
  |---|---|
  | `RangePicker` | `@Binding var selection: WeekRange`, `@Namespace private var thumb` |
  | `StatCard` | `title`, `value`, `unit`, `bottomLine`, `symbol` (`String`); `bottomColor`, `tint` (`Color`); `isFilled` (`Bool`) |
  | `WorkoutRow` | `workout` (`Workout`) |

- Show values from `week`. The strings in this document are what the sample data must show.
- Format numbers for the `en_US` locale: "18.4", "1,920".

## Page

- Background: `Color(.systemGroupedBackground)`, also behind the status bar.
- Side margins: 20 pt. Space between sections: 20 pt. Space above the header: 8 pt. Space below the last section: 32 pt.
- Font: SF Pro Rounded for all text. Set `.fontDesign(.rounded)` on the `ScrollView`.
- Cards: `Color.white`, corner radius 22, padding 16, no shadow.
- Without scrolling, the screen shows everything from the header to the bottom of the stats grid. History is below it, and the user scrolls to see it.

## Palette

| Name | Hex |
|---|---|
| pink | #FF0A66 |
| red | #FC0118 |
| orange | #FF6E00 |
| yellow | #F8C200 |
| green | #1CD822 |
| teal | #00C9B5 |
| blue | #0076FF |

A "tint background" is the tint color at 15% opacity.

## 1. Header

- Left, two lines:
  - "This week", 34 pt bold, primary.
  - "18 – 24 Nov", 17 pt medium, secondary.
- Right: a 36 pt white circle with `square.and.arrow.up`, 15 pt semibold, primary. Its accessibility label is "Share".
- The circle is vertically centered on the two lines.

## 2. Range picker

- A custom segmented control with three segments: "Week", "Month", "Year". It is bound to `range`.
- Full width, 36 pt high.
- Track: a capsule filled with `Color(.systemGray5)`.
- Thumb: a white capsule under the selected segment, 3 pt inside the track on all sides, with a shadow of black at 10% opacity, radius 4, y offset 2.
- Labels: 15 pt semibold. The selected label is primary, the others are secondary.
- A tap on a segment selects it. The thumb slides to it with `.spring(duration: 0.3)`.

## 3. Hero

Three lines, leading-aligned, 4 pt apart:

1. "Active time", 15 pt semibold, secondary.
2. "4 h 52 m". The numbers "4" and "52" are 48 pt bold, primary. The units "h" and "m" are 22 pt semibold, secondary. All parts share one baseline. There are 3 pt between a number and its unit, and 10 pt between "h" and "52".
3. `arrow.up.right` and "+38 m" in green, 15 pt semibold, then "vs last week", 15 pt regular, secondary.

## 4. Chart card

A card with a title row and a Swift Charts chart.

- Title row: "Daily minutes", 15 pt semibold, primary, on the left. "Goal 45 m", 13 pt medium, secondary, on the right.
- The chart is 12 pt below the title row and 140 pt high.
- Bars: one `BarMark` per day, 22 pt wide, corner radius 11.
  - Past days: `Color(.systemGray5)`.
  - Today: a linear gradient from pink at the top to orange at the bottom.
- Goal line: a `RuleMark` at 45 minutes. 1 pt wide, dashed with `[4, 4]`, `Color(.systemGray2)`.
- Today's value: "62 m" above today's bar, 13 pt bold, pink.
- Y axis: hidden. The y scale is 0 to 80 minutes.
- X axis: the day letters M T W T F S S under the bars, 13 pt. Past days are secondary, regular. Today is primary, bold. No grid lines and no ticks.

## 5. Stats

A grid of four cards in 2 columns, with 12 pt between columns and between rows. All four cards have the same height.

Each card has three rows, leading-aligned:

1. A 28 pt circle filled with the tint background, with the symbol at 13 pt semibold in the tint. 8 pt to its right, the title, 15 pt medium, secondary.
2. 12 pt below: the value, 28 pt bold, primary, then the unit, 15 pt semibold, secondary, on one baseline.
3. 2 pt below: the bottom line, 13 pt semibold.

| Position | Title | Value | Unit | Bottom line | Symbol | Tint |
|---|---|---|---|---|---|---|
| Top left | Distance | 18.4 | km | "+2.1 km", green | `figure.run` | blue |
| Top right | Energy | 1,920 | kcal | "+240 kcal", white | `flame.fill` | white |
| Bottom left | Workouts | 6 | | "+1", green | `checkmark.circle.fill` | green |
| Bottom right | Heart rate | 128 | bpm | "Resting 56 bpm", secondary | `heart.fill` | red |

The Energy card is different:

- Its fill is a linear gradient from orange at the top leading corner to pink at the bottom trailing corner.
- All its text is white. The title and the unit are white at 80% opacity.
- Its icon circle is white at 25% opacity, with a white symbol.

## 6. History

- Title: "History", 22 pt bold, primary.
- 12 pt below: one card with three rows and no padding of its own.
- Each row has 16 pt horizontal padding and 12 pt vertical padding:
  - Left: a 40 pt rounded square, corner radius 12, filled with the tint background, with the symbol at 18 pt semibold in the tint.
  - 12 pt to its right, two lines: the title, 17 pt semibold, primary, and "day · duration", 13 pt regular, secondary.
  - Right: the value, 17 pt semibold, primary.
- Between rows: a divider that starts at the title's leading edge (68 pt from the card's leading edge) and runs to the trailing edge. No divider after the last row.

| Title | Second line | Value | Symbol | Tint |
|---|---|---|---|---|
| Morning run | Sun · 32 min | 5.2 km | `figure.run` | orange |
| Yoga | Thu · 40 min | 180 kcal | `figure.mind.and.body` | green |
| Evening ride | Tue · 54 min | 12.6 km | `figure.outdoor.cycle` | blue |
