# stac_airphoto_bc

## v1.0.0 (2026-10-11)

### Item fields renamed (#47)

The run provenance moves from `nge:` fields to the
[processing extension](https://github.com/stac-extensions/processing) v1.2.0,
which items now list in `stac_extensions`. A saved filter on an old name no
longer matches. The `nge:`-named item JSONs are kept in
`s3://stac-airphoto-bc/backup/items-20261010T175309/`.

| was | now |
|---|---|
| `nge:produced_datetime` | `processing:datetime` |
| `nge:fly_version` | `processing:software` → `fly`, the part before `+` |
| `nge:fly_sha` | `processing:software` → `fly`, the part after `+` |
| `nge:pipeline_sha` | `processing:version` |

The fly build is one string, `<version>+<sha>` (semver build metadata), for
example `{"fly": "0.19.0+0eeb977c3893"}`. The fly version is the part of that
string before `+`, so a filter that compared `nge:fly_version` for equality has
to compare the start of the `fly` entry instead.

The rename changes no value, and no COG: their tags keep the names
`FLY_VERSION`, `FLY_SHA` and `PIPELINE_SHA`, so no `file:checksum` moves. Only
item JSON changes.
