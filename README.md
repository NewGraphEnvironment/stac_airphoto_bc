# stac_airphoto_bc

Historic BC airphoto mosaic pipeline: fetch thumbnails, georeference to footprints, convert to COGs, push to S3, and register as STAC items on images.a11s.one.

## Pipeline

| Step | Script | Description |
|------|--------|-------------|
| 1 | `scripts/01_fetch.R` | Query centroids from BC Data Catalogue, select photos per AOI/decade, download thumbnails via `fly::fly_fetch()` |
| 2 | `scripts/02_georef.R` | Warp thumbnails to estimated ground footprints via `fly::fly_thumb_georef()` |
| 3 | `scripts/03_cog.R` | Convert georeferenced TIFFs to Cloud-Optimized GeoTIFFs |
| 4 | `scripts/04_s3_upload.R` | Push COGs to S3 bucket |
| 5 | `scripts/05_stac_register.R` | Build STAC items from photo metadata and register on images.a11s.one via pypgstac |

## Dependencies

- [fly](https://github.com/NewGraphEnvironment/fly) — footprint estimation, photo selection, thumbnail fetch & georef
- [flooded](https://github.com/NewGraphEnvironment/flooded) — floodplain AOI delineation
- [drift](https://github.com/NewGraphEnvironment/drift) — land cover change detection (context for photo selection)

## Data flow

```
BC Data Catalogue (WFS)
  → fly::fly_fetch() thumbnails
  → fly::fly_thumb_georef() GeoTIFFs
  → gdal_translate COGs
  → S3 bucket
  → pypgstac STAC catalog
  → titiler on images.a11s.one
```

Photo metadata (`airp_id`, `photo_date`, `scale`, `focal_length`, etc.) flows through the pipeline via joins on `airp_id` and becomes STAC item properties.
