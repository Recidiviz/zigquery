# NUMERIC / BIGNUMERIC fidelity gaps

Known divergences between this engine and BigQuery for the two decimal types,
recorded while moving them to storage format 3 (fixed-scale, memcomparable BLOB).
None is a regression from that change unless noted — most predate it and were
inherited from go-zetasqlite, which represents both types as an unbounded
`math/big.Rat` and enforces nothing.

Baseline for all of this: NUMERIC is `decimal(38,9)`, BIGNUMERIC is
`decimal(76,38)`. Since format 3, `numericValue` (`src/internal/value.zig`) is the
single construction point and rounds every value to its declared scale, half away
from zero, and rejects out-of-range magnitudes.

## Fixed by format 3, for the record

These *were* gaps and no longer are. Listed so nobody re-derives them.

| | was | now |
|---|---|---|
| Division kept an exact rational | `(NUMERIC '1'/'7')*'7'` = `1` | `1.000000001` |
| `PARSE_NUMERIC` did not round, a folded `CAST` did | inconsistent | both round |
| Values rendering alike compared unequal | `(1/3) != 0.333333333` | equal |
| `GROUP BY` keyed on the rendering while `=` used exact `Rat.cmp` | disagreed | agree |
| Mixed-kind arithmetic was LHS-wins | `BIGNUMERIC + NUMERIC` narrowed to scale 9 | widens to BIGNUMERIC |
| Out-of-range values were accepted silently | any magnitude | `NumericOutOfRange` |

## Open gaps

### 1. `AVG` over NUMERIC returns FLOAT64

BigQuery returns NUMERIC. Ours goes through `toFloat64` and yields `.float`
(`AVG.done` in `src/internal/function/fn_aggregate.zig`, pinned by
`test "SUM keeps int typing; AVG divides as float"`). `WINDOW_AVG`
(`fn_window.zig`) does the same. This is now the largest
remaining precision leak in the numeric surface: every other arithmetic operator
stays exact at scale.

`SUM` is unaffected — it stays NUMERIC.

### 2. `ROUND` / `TRUNC` / `FLOOR` / `CEIL` / `ABS` / `MOD` / `SIGN` coerce to float

All go through `toFloat64` and return `.float` (`src/internal/function/fn_math.zig`).
A NUMERIC argument therefore loses precision beyond f64's 53 bits, and the result
type is wrong. `ROUND(NUMERIC '1.5')` happens to give `2`, but only because the
value is small.

### 3. `SAFE_ADD` / `SAFE_SUBTRACT` / `SAFE_MULTIPLY` / `SAFE_DIVIDE` / `SAFE_NEGATE` coerce to float

Same mechanism (`safeAdd` through `safeNegate` in `fn_math.zig`), so the `SAFE_`
variants are *less* precise
than the bare operators, which stay exact. Surprising, and the opposite of what
the names suggest.

### 4. `PARSE_NUMERIC` accepts a fraction grammar BigQuery rejects

`unscaledFromString` (`src/internal/value.zig`) checks for `/` first and parses an
`"n/d"` fraction, so `PARSE_NUMERIC('1/3')` succeeds and rounds to `0.333333333`.
BigQuery raises. The same parser backs every STRING-to-numeric conversion through
`Value.toUnscaled`.

Nothing stored depends on the fraction form: nested numerics are fixed-width
integers in `codec_binary.zig`, not text. Closing this is deleting the `/` branch,
plus respelling the off-grid input in `codec_binary.zig`'s round-trip test, which
builds its value from `"1/3"`.

### 5. Non-numeric-LHS arithmetic does not widen

The mixed-kind fix covers `.numeric` on the left. `INT64 + NUMERIC` still routes
through the `.int` arm and `toInt64`, which rounds the NUMERIC to a whole
integer, so `1 + NUMERIC '1.5'` = `3` as an INT64 rather than `2.5` as a NUMERIC.
Analyzer-unreachable (GoogleSQL inserts a cast), so this only bites `rawQuery`
and any future path that skips the analyzer.
