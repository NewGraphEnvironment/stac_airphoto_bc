# NEWS

## Unreleased — publishes with the next rebuild

### Item fields renamed (#47)

The run provenance moves from `nge:` fields to the
[processing extension](https://github.com/stac-extensions/processing) v1.2.0,
which items now list in `stac_extensions`. A saved filter on an old name stops
matching once the rebuild is published.

| was | now |
|---|---|
| `nge:produced_datetime` | `processing:datetime` |
| `nge:fly_version` | `processing:software` → `fly`, the part before `+` |
| `nge:fly_sha` | `processing:software` → `fly`, the part after `+` |
| `nge:pipeline_sha` | `processing:version` |

The fly build is one string, `<version>+<sha>` (semver build metadata), for
example `{"fly": "0.19.0+0eeb977c3893"}`. To select every item built by one fly
version, match the start of the `fly` entry (`0.19.0+`) rather than the whole
value.

Values are unchanged, and so are the COGs: their tags keep the names
`FLY_VERSION`, `FLY_SHA` and `PIPELINE_SHA`, so no `file:checksum` moves. Only
item JSON changes.
