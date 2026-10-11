# Plan review — #47 (Plan agent, read-only; written here from its reply)

Checked against HEAD c2d11eb. No Blockers.

- **Gap — publishing can mix `nge:` and `processing:` items.** 05 merges collection links, not item bodies (`05_stac_register.py:376-378`); items it did not rebuild keep their S3 JSON, and only `--require-all-published` fails on them. `stac_validate.py` sees only local items. → Publish with `05 --require-all-published`, then `stacs verify` and a check for no live `nge:` key. **Fixed** (CLAUDE.md publish order; plan out-of-scope line).
- **Assumption — NEWS filter advice unproven.** `"processing:software.fly" LIKE '0.19.0+%'` returns 0 today (nothing published), proving nothing; queryables list only id/datetime/geometry. **Fixed**: NEWS makes no syntax claim.
- **Assumption/Scope — no checked-in schema copies**, which the edited #47 body asks for. **Resolved**: pointcloud#2 vendors only crate schemas; this mapping uses none (findings.md).
- **Gap — tests miss the core-key skip and the projection pairing.** **Fixed**: `datetime`/`title` in `_props()`, asset case asserts exactly one problem, `proj:*` without projection refused.
- **Gap (minor) — validator docstring and `scripts/README.md` row.** **Fixed.**
- **Gap (minor) — empty-string fly parts write `"+abc"`.** **Fixed** (`_blank()`); `"None+None"` for an untagged COG is cosmetic and fails toward reporting, left.
- **Acceptance — NEWS says "next rebuild", CLAUDE.md "next sync".** **Fixed**: both say the next sync.
- **Ordering — 05 before any 04 after merge.** **Fixed** in the CLAUDE.md publish order.
- **Scope (minor) — the 06 out-of-scope reason was wrong.** **Fixed** in task_plan.md.
