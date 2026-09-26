# Progress — Rebuild the collection on current fly (#23)

## Session 2026-09-26

- Plan-mode exploration — phases approved by user; "go all phases to PR"
- Issues: filed #30 (checksums/provenance) and stac_orthophoto_bc#45 (baseline reads live S3); #23 body de-staled and retitled; #30 body gained the COG-layout finding; #28/#29 noted as folded in
- Created branch `23-rebuild-the-collection-on-current-fly` off main
- Next: Phase 1
- Phase 1 code-check: round 1 (disputed rolls mislabelled `measured`; git failure read as clean) → fixed, `disputed` added by user decision; round 2 found a defect inside that fix (DISPUTED list would relabel a settled roll) plus two guard premises → fixed, each guard shown to fire on a scratch copy. Ended by enumeration of every hardcoded source fact in the import (disputed list, verdict map, pinned counts, placement vocabulary, column names, tracked paths): each is now checked against the source or fails loud.
