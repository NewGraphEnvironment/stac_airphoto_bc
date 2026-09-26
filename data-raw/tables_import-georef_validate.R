# tables_import-georef_validate.R — import the measured rotation and placement tables (#23)
#
# Usage (from the repo root):
#   Rscript data-raw/tables_import-georef_validate.R
#
# The rebuild needs two facts measured in the private `stac_orthophoto_bc` repo against
# provincial orthophotos and the catalogue's published photogrammetric solutions:
#
#   data-raw/rotation_roll.csv     one row per film roll whose scanning rotation is known
#   data-raw/placement_frame.csv   one row per catalogue frame on those rolls: the
#                                  translation to apply to its georeferenced footprint
#
# Reduced on purpose. The source tables carry reviewer notes and per-roll diagnostics that
# stay private; what ships here is the value, where it came from, and the source commit,
# so the rebuild is reproducible from this repo alone. Method and evidence:
# stac_orthophoto_bc `research/georeferencing-validation.md`, sections 14 and 15.
#
# Re-run when the source tables change. It refuses a dirty source tree, because the commit
# it stamps would then not describe the bytes it read.

# Override with STAC_ORTHOPHOTO_BC=/path/to/checkout where it is cloned elsewhere.
SRC_REPO <- path.expand(Sys.getenv("STAC_ORTHOPHOTO_BC", "~/Projects/repo/stac_orthophoto_bc"))
SRC_DIR  <- file.path(SRC_REPO, "data", "georef_validate")

# stdout = TRUE drops stderr and turns a failing git into character(0) plus a
# warning, which reads as "clean" to the dirty check and stamps an empty commit.
# So the status is checked, and a non-checkout is refused.
git <- function(...) {
  out <- suppressWarnings(system2("git", c("-C", SRC_REPO, ...), stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop("git ", paste(c(...), collapse = " "), " failed in ", SRC_REPO, ":\n",
         paste(out, collapse = "\n"), call. = FALSE)
  }
  out
}

if (!dir.exists(SRC_DIR)) {
  stop("Source tables not found at ", SRC_DIR, " — clone stac_orthophoto_bc there.",
       call. = FALSE)
}
dirty <- git("status", "--porcelain", "--", "data/georef_validate")
if (length(dirty)) {
  stop("stac_orthophoto_bc has uncommitted changes under data/georef_validate/, so the ",
       "commit stamped on the import would not describe what was read:\n",
       paste(dirty, collapse = "\n"), call. = FALSE)
}
# `git -C` walks up to the nearest repository, so a copy nested inside another repo
# would stamp that repo's commit. Require SRC_REPO to be the top level itself.
top <- git("rev-parse", "--show-toplevel")
if (normalizePath(top) != normalizePath(SRC_REPO)) {
  stop(SRC_REPO, " is not the top of a git checkout (git resolves it to ", top, ").",
       call. = FALSE)
}
src_sha <- git("rev-parse", "--short", "HEAD")
stopifnot(length(src_sha) == 1L, nzchar(src_sha))

# `git status` does not show ignored files, and the source ignores
# data/georef_validate/* before un-ignoring *.csv. Require each table to be
# TRACKED, so the stamped commit is known to contain the bytes read.
for (f in c("rotation_table.csv", "placement_frame.csv")) {
  git("ls-files", "--error-unmatch", file.path("data", "georef_validate", f))
}

read <- function(f) {
  utils::read.csv(file.path(SRC_DIR, f), colClasses = "character", na.strings = c("", "NA"))
}

# --- Rotation, per roll ---------------------------------------------------
# `rotation_source` is the vocabulary #23 publishes on every item:
#   measured           the correlator decided it, and no person has looked
#   reviewed           a person looked: confirmed the correlator, or decided where it could not
#   disputed           the correlator decided it and a person disagrees; the value is kept
#                      and labelled so the frames can be found and checked (decided 2026-09-26)
#   assumed_by_series  not in this table — the series default in scripts/aoi.R applies
# The two rolls nobody could resolve are left OUT, so they reach the series rule exactly
# like an unmeasured roll, rather than carrying an NA that means something different.

rot <- read("rotation_table.csv")

# A person disputes these two rolls' rotation: bc81050 was twice marked right as
# published, and bcc668 "may be flipped" (research section 14; PLACEMENT_HOLD in
# georef_validate-functions.R). The verdict column cannot say so — it is the
# correlator's — so the dispute is named here, once, and both the label and the
# placement guard below read this one list. `disputed` means the CORRELATOR's value
# is kept against a reviewer's objection, so each roll must still carry a
# correlator verdict: once a person decides it upstream, this list is stale and
# the import stops rather than relabelling the reviewer's value as disputed.
DISPUTED <- c("bc81050", "bcc668")
still_correlator <- rot$verdict[match(DISPUTED, rot$film_roll)] %in% c("decided", "majority")
if (!all(still_correlator)) {
  stop("Disputed roll(s) ", paste(DISPUTED[!still_correlator], collapse = ", "),
       " no longer carry a correlator verdict upstream — the dispute was settled or ",
       "the roll is gone. Update DISPUTED here.", call. = FALSE)
}

verdict_source <- c(
  decided           = "measured",
  majority          = "measured",
  decided_confirmed = "reviewed",
  decided_by_eye    = "reviewed"
)
unresolved <- rot$verdict == "unresolved_no_confident_frame"

unknown_verdict <- setdiff(unique(rot$verdict[!unresolved]), names(verdict_source))
if (length(unknown_verdict)) {
  stop("rotation_table.csv carries verdict(s) this import has never seen: ",
       paste(unknown_verdict, collapse = ", "), ". Map them before importing.", call. = FALSE)
}

rotation_roll <- data.frame(
  film_roll       = rot$film_roll[!unresolved],
  rotation        = as.integer(rot$rotation[!unresolved]),
  rotation_source = unname(verdict_source[rot$verdict[!unresolved]])
)
rotation_roll$rotation_source[rotation_roll$film_roll %in% DISPUTED] <- "disputed"
rotation_roll <- rotation_roll[order(rotation_roll$film_roll), ]

# --- Placement, per frame -------------------------------------------------
# Every row, `none` included: a frame absent from this table is outside the measured
# rolls, which is a different statement from "measured, and left where it is".

pl <- read("placement_frame.csv")

placement_frame <- data.frame(
  airp_id          = pl$airp_id,
  film_roll        = pl$film_roll,
  placement_source = pl$placement_source,
  shift_x_m_3005   = as.numeric(pl$shift_x_m_3005),
  shift_y_m_3005   = as.numeric(pl$shift_y_m_3005)
)
placement_frame <- placement_frame[order(as.integer(placement_frame$airp_id)), ]

# --- Guards ---------------------------------------------------------------
# Counts are the ones the #23 body and research section 15 publish. A re-measured table
# will move them; update them here deliberately, with the issue body, rather than letting
# a changed table ride through unread.

src_counts <- table(placement_frame$placement_source)
checks <- c(
  "67 rolls with a known rotation" = nrow(rotation_roll) == 67L,
  "each roll once"                 = !anyDuplicated(rotation_roll$film_roll),
  "rotation in 0/90/180/270"       = all(rotation_roll$rotation %in% c(0L, 90L, 180L, 270L)),
  "10,239 frames"                  = nrow(placement_frame) == 10239L,
  "each frame once"                = !anyDuplicated(placement_frame$airp_id),
  "sources are the four known"     = all(names(src_counts) %in%
                                           c("manual", "correlator", "roll_model", "none")),
  "252 correlator frames"          = identical(unname(src_counts["correlator"]), 252L),
  "211 roll-model frames"          = identical(unname(src_counts["roll_model"]), 211L),
  "9,776 uncorrected frames"       = identical(unname(src_counts["none"]), 9776L),
  "every shift finite"             = all(is.finite(placement_frame$shift_x_m_3005) &
                                           is.finite(placement_frame$shift_y_m_3005)),
  "none means zero"                = with(placement_frame[placement_frame$placement_source == "none", ],
                                          all(shift_x_m_3005 == 0 & shift_y_m_3005 == 0)),
  # A shift measured on a disputed orientation is a shift of the wrong image.
  "both disputed rolls present"    = all(DISPUTED %in% rotation_roll$film_roll) &&
                                       all(DISPUTED %in% placement_frame$film_roll),
  "disputed rolls labelled"        = sum(rotation_roll$rotation_source == "disputed") == length(DISPUTED),
  "held rolls carry no shift"      = with(placement_frame[placement_frame$film_roll %in% DISPUTED, ],
                                          all(placement_source == "none"))
)
if (!all(checks)) {
  stop("Import guard(s) failed: ", paste(names(checks)[!checks], collapse = "; "),
       call. = FALSE)
}

# --- Write ----------------------------------------------------------------
# A provenance comment on line 1, then plain CSV. Readers skip it with `comment = "#"`
# (R) or by `comment="#"` (pandas).

write_with_header <- function(x, path, what) {
  con <- file(path, open = "w")
  on.exit(close(con))
  writeLines(sprintf(
    "# %s; imported from stac_orthophoto_bc@%s data/georef_validate by data-raw/tables_import-georef_validate.R",
    what, src_sha), con)
  utils::write.csv(x, con, row.names = FALSE, na = "")
}

write_with_header(rotation_roll, "data-raw/rotation_roll.csv",
                  "Per-roll scanning rotation for fly_georef(), #23")
write_with_header(placement_frame[, c("airp_id", "placement_source",
                                      "shift_x_m_3005", "shift_y_m_3005")],
                  "data-raw/placement_frame.csv",
                  "Per-frame placement shift, EPSG:3005 metres east/north, applied after georeferencing, #23")

message("Imported from stac_orthophoto_bc@", src_sha, ": ",
        nrow(rotation_roll), " rolls (",
        paste(names(table(rotation_roll$rotation_source)),
              table(rotation_roll$rotation_source), collapse = ", "), "), ",
        nrow(placement_frame), " frames (",
        paste(names(src_counts), src_counts, collapse = ", "), ")")
