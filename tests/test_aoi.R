# test_aoi.R — guards in scripts/aoi.R that must fail toward abort
#
# Run:
#   Rscript tests/test_aoi.R
#
# Every guard here is exercised against BOTH answers. One that has only ever been
# seen to pass is decoration, so `aoi_require_fly()` takes the formal names as an
# argument: the refusing cases are reachable without a second fly installed, and
# the accepting case is still driven against the real one as a positive control.

suppressPackageStartupMessages({
  library(sf)
  library(arrow)
})

source("scripts/aoi.R")

failures <- 0L
skipped  <- 0L

ok <- function(label, expr) {
  res <- tryCatch({
    stopifnot(isTRUE(expr))
    "PASS"
  }, error = function(e) paste0("FAIL — ", conditionMessage(e)))
  if (!identical(res, "PASS")) failures <<- failures + 1L
  message(sprintf("%-58s %s", label, res))
}

# Returns the error message, or NA when the expression did not abort. Testing
# "did it stop" alone is not enough: a suite with several guards has several ways
# to abort and only one of them is the evidence, so every refusal below is
# matched on its text.
refusal <- function(expr) {
  tryCatch({
    force(expr)
    NA_character_
  }, error = function(e) {
    m <- conditionMessage(e)
    # An abort carrying no message is not a usable refusal, and returning "" here
    # would let `!is.na(msg)` bless it. Name it instead, so the assertion that
    # matches on text fails rather than the one that only checks it stopped.
    if (!nzchar(m)) "<abort with empty message>" else m
  })
}

# --- aoi_require_fly() ----------------------------------------------------
# A capability check, not a version comparison. #20 as filed prescribed a floor
# of fly 0.6.0; that was written the day 0.6.0 shipped and four releases have
# landed since, so the number was stale before the work started. What the
# pipeline actually needs is that `dem` reaches the three functions that size a
# footprint -- which is true from fly 0.5.1 through 0.10.0 and has no ceiling.

message("\n# aoi_require_fly()\n")

# The real installed fly must pass. This is the positive control: without it a
# guard that refuses everything would look identical to a guard that works.
ok("accepts the installed fly",
   is.na(refusal(aoi_require_fly())))

# Every one of the three has to be checked. A guard that reads only the first is
# indistinguishable from a working one until the day fly moves one of the others.
complete <- list(
  fly_filter    = c("photos_sf", "aoi_sf", "method", "buffer", "dem"),
  fly_footprint = c("centroids_sf", "negative_size", "format_size", "dem"),
  fly_georef    = c("fetch_result", "photos_sf", "dest_dir", "overwrite",
                    "srcnodata", "rotation", "dem")
)

ok("accepts a complete formal set", is.na(refusal(aoi_require_fly(complete))))

# An empty or unnamed list must not sail through. `names(NULL)` is NULL and
# vapply() over an empty list is logical(0), so the naive form falls out of the
# bottom reporting a fly it never inspected as capable.
for (bad in list(list(), stats::setNames(list(), character(0)),
                 list(c("a", "dem")), complete[c("fly_filter")])) {
  ok("refuses a formal set that is empty or under-named",
     !is.na(refusal(aoi_require_fly(bad))))
}

for (fn in names(complete)) {
  broken <- complete
  broken[[fn]] <- setdiff(broken[[fn]], "dem")
  msg <- refusal(aoi_require_fly(broken))
  ok(paste0("refuses a fly whose ", fn, "() has no `dem`"), !is.na(msg))
  # Naming the offending function is the difference between a message someone
  # can act on and one that sends them to read three signatures.
  ok(paste0("  ... names ", fn),
     !is.na(msg) && grepl(fn, msg, fixed = TRUE))
  # And names ONLY it. Without this the assertion above passes just as well for
  # a message that always lists all three, which would tell the reader nothing.
  ok(paste0("  ... and names no other function for ", fn),
     !is.na(msg) && !any(vapply(setdiff(names(complete), fn),
                                function(o) grepl(o, msg, fixed = TRUE),
                                logical(1))))
}

# All three missing at once must still name all three, not just the first found.
none <- lapply(complete, setdiff, "dem")
msg <- refusal(aoi_require_fly(none))
ok("refuses when all three lack `dem`", !is.na(msg))
ok("  ... names all three",
   !is.na(msg) && all(vapply(names(complete),
                             function(f) grepl(f, msg, fixed = TRUE), logical(1))))

# The remedy has to be in the message. A refusal that says what is wrong and not
# what to do sends the reader to the git log.
ok("  ... names the remedy",
   !is.na(msg) && grepl("install_github", msg, fixed = TRUE))
ok("  ... names the release the rebuild needs",
   !is.na(msg) && grepl("0.12.0", msg, fixed = TRUE))

# --- aoi_check_footprint_cols() -------------------------------------------
# The fly#35 guard. It was hoisted out of 01_fetch.R specifically so it could be
# driven here: inline in a stage script it could only ever be exercised by a full
# run against a fly old enough to have the bug.

message("\n# aoi_check_footprint_cols()\n")

fp_full <- as.data.frame(stats::setNames(
  rep(list(logical(0)), length(aoi_footprint_cols())), aoi_footprint_cols()))

ok("accepts a complete fly_footprint() result",
   is.na(refusal(aoi_check_footprint_cols(fp_full))))

# fly#35 dropped all four together, so that is the case to reach; each one alone
# is checked too, since a future regression need not drop the whole set.
msg <- refusal(aoi_check_footprint_cols(fp_full[, 0, drop = FALSE]))
ok("refuses a result with all four missing", !is.na(msg))
ok("  ... names fly#35", !is.na(msg) && grepl("fly#35", msg, fixed = TRUE))
ok("  ... names every missing column",
   !is.na(msg) && all(vapply(aoi_footprint_cols(),
                             function(c) grepl(c, msg, fixed = TRUE),
                             logical(1))))

for (col in aoi_footprint_cols()) {
  m <- refusal(aoi_check_footprint_cols(
    fp_full[, setdiff(aoi_footprint_cols(), col), drop = FALSE]))
  ok(paste0("refuses a result missing ", col), !is.na(m))
  ok(paste0("  ... names ", col), !is.na(m) && grepl(col, m, fixed = TRUE))
}

# The real result must pass. Positive control against fly itself rather than a
# constructed frame -- the whole point of fly#35 was that a CONSTRUCTED input
# behaved differently from the tibble bcdata returns, so a fixture built here
# cannot reach the failure this guard exists for.
#
# The cache is gitignored, so on a fresh clone this arm cannot run. Reported as
# SKIPPED rather than quietly dropped: an absent arm and a passing one look
# identical in a green summary, and this is the only assertion that drives fly.
# --- Pinned against the INSTALLED fly, with no cache ----------------------
# Both of these are fly's facts copied into aoi.R, and both were first written
# behind the centroid-cache gate below — which is gitignored, so they ran on one
# machine and nowhere else. Read from the installed package they need no data at
# all, which is what makes them run on a fresh clone.

message("\n# fly's own values, read from the installed package\n")

# NOT wrapped in a handler that downgrades a miss to a skip. A fly that renames
# this internal is exactly the fly whose threshold may have moved, so masking the
# rename disarms the pin on the one event it exists for.
ok("aoi_dem_coverage_min() matches fly's",
   identical(aoi_dem_coverage_min(), fly:::fly_dem_coverage_min()))

# The vocabulary, read out of fly_footprint()'s own source rather than re-typed.
# `dem_agl` and `no_dem_coverage` are emitted only under a DEM, so while
# aoi_dem_enabled() is FALSE no run and no fixture can reach them — this is the
# only check that does, and it is the one that matters the day #23 flips it.
fp_src <- paste(deparse(fly::fly_footprint), collapse = "\n")
for (v in aoi_terrain_values()) {
  ok(paste0("fly_footprint() still emits '", v, "'"),
     grepl(paste0('"', v, '"'), fp_src, fixed = TRUE))
}

cache <- "data/centroids/se_c.parquet"
if (file.exists(cache)) {
  real <- aoi_centroids_as_sf(arrow::read_parquet(cache))
  ok("the real bcdata-shaped input is tibble-backed",
     inherits(real, "tbl_df"))

  fp_real <- suppressWarnings(fly::fly_footprint(real))
  ok("fly_footprint() returns every declared column on it",
     is.na(refusal(aoi_check_footprint_cols(fp_real))))

  # Every literal below describes FLY, and a real fly object is in hand — so the
  # expectation comes from the object rather than from another repo literal.
  # This is the block round 4 named: four literals close here, not in four
  # separate designs.

  # The OTHER direction. `aoi_check_footprint_cols()` is a one-way setdiff, so a
  # seventh column fly adds is invisible to it — which is exactly how the set went
  # two columns stale between fly 0.8.0 and 0.10.0.
  added <- setdiff(names(fp_real), names(real))
  ok("aoi_footprint_cols() is fly's reporting set exactly, not a subset",
     setequal(added, aoi_footprint_cols()))
  if (!setequal(added, aoi_footprint_cols())) {
    message("      fly adds: ", paste(sort(added), collapse = ", "))
    message("      we declare: ",
            paste(sort(aoi_footprint_cols()), collapse = ", "))
  }

  # The terrain vocabulary, against what fly actually emits.
  ok("every footprint_terrain fly emits is in aoi_terrain_values()",
     length(setdiff(stats::na.omit(unique(fp_real$footprint_terrain)),
                    aoi_terrain_values())) == 0)

} else {
  # Name every assertion the gate withholds, not just the first, and COUNT them —
  # a fresh clone used to lose five of these and still print "All assertions
  # passed." An arm that did not run is a third state beside pass and fail.
  for (lab in c("the real bcdata-shaped input is tibble-backed",
                "fly_footprint() returns every declared column on it",
                "aoi_footprint_cols() is fly's reporting set exactly",
                "every footprint_terrain fly emits is in aoi_terrain_values()")) {
    skipped <<- skipped + 1L
    message(sprintf("%-58s %s", lab,
                    "SKIPPED - no centroid cache; run 01_fetch.R se_c"))
  }
}

# --- aoi_ledger_cols() ----------------------------------------------------

message("\n# aoi_ledger_cols()\n")

cols <- aoi_ledger_cols()

# Hardcoded on purpose, and independently of aoi_ledger_cols(). The ledger
# schema is a contract this repo chose, not a fact about a third party, so a
# expectation *derived* from the thing under test moves with it and can never go
# red -- which is exactly what happened to the first version of this block:
# building the fixture from aoi_ledger_cols() made the check setdiff(x, x), and
# appending a bogus column to aoi_ledger_cols() left the whole suite green.
expected_cols <- c(
  "aoi_id", "airp_id", "film_roll", "frame_number",
  "photo_year", "era", "footprint_basis",
  "footprint_terrain", "width_source", "footprint_bearing",
  "height_agl", "dem_coverage", "height_source",
  "dem_shortfall_m", "dem_elev_sd",
  "rotation", "rotation_source",
  "placement_source", "shift_x_m_3005", "shift_y_m_3005",
  "thumbnail_image_url", "selection_basis", "rejected_reason"
)

ok("schema matches the declared contract", identical(cols, expected_cols))
ok("carries every column fly_footprint() reports",
   all(aoi_footprint_cols() %in% cols))
ok("no duplicates", !anyDuplicated(cols))

# And the producer must actually build them. Weak as a parse, but it always runs
# and it catches the drift that matters: a column declared here and never
# assigned in the transmute() that writes the ledger.
#
# Two ways the first version of this was defeatable, both proven by mutation:
#
#   1. `sub()` returns its input UNCHANGED when the anchor does not match, so a
#      reformatted pipe or a renamed `ledger` silently made `block` the whole
#      file — where all 13 names appear and the assertion passes having checked
#      nothing. The failure path and the pass path were indistinguishable.
#   2. The extracted block carries the transmute's own COMMENTS, and those name
#      `footprint_basis` and `footprint_terrain` — the two columns whose loss
#      #20 exists to prevent. Deleting both from the code left this green.
fetch_src <- paste(readLines("scripts/01_fetch.R", warn = FALSE), collapse = "\n")
block <- sub(".*ledger <- window\\[window\\$in_window, \\] \\|>", "", fetch_src)
ok("the transmute block was actually located",
   nchar(block) < nchar(fetch_src))
block <- sub("sel_ids <-.*", "", block)

# Code only. A column named in a comment is not a column the ledger carries.
block <- paste(grep("^\\s*#", strsplit(block, "\n")[[1]],
                    value = TRUE, invert = TRUE), collapse = "\n")

# Cut at `rejected_reason =`. Everything after it is the case_when, whose body
# REFERENCES columns as inputs — `is.na(footprint_terrain)` — and a reference is
# not a declaration. Round 3 proved the cost: dropping only `footprint_terrain`
# from the output list left this green, because the name survives in the
# case_when. `rejected_reason` is checked on its own below, since it is declared
# by the very line being cut at.
outputs <- sub("rejected_reason\\s*=.*", "", block)
ok("the output list was separated from the case_when",
   nchar(outputs) < nchar(block))

declared <- setdiff(cols, "rejected_reason")
absent <- declared[!vapply(declared,
                           function(c) grepl(c, outputs, fixed = TRUE),
                           logical(1))]
ok("01_fetch.R's transmute() names every declared column",
   length(absent) == 0)
if (length(absent)) message("      absent: ", paste(absent, collapse = ", "))

ok("... and declares rejected_reason",
   grepl("rejected_reason\\s*=", block))

# #32. The window carries the catalogue's own `id` column, so a bare
# `aoi_id = id` inside transmute() resolves to the WFS feature id, not the loop
# variable. Only an injected value names the AOI. `outputs` is comment-free, so
# a bare assignment kept in a comment does not satisfy either line.
ok("the transmute assigns aoi_id from an injected id (#32)",
   grepl("aoi_id\\s*=\\s*(!!\\s*id|\\.env\\$id)\\b", outputs, perl = TRUE))
ok("  ... and never from a bare, data-masked `id`",
   !grepl("aoi_id\\s*=\\s*id\\b", outputs, perl = TRUE))

# --- The guard is actually wired in ---------------------------------------
# A guard nothing calls is decoration, and no unit test of the function itself
# can see it being dropped from a stage.

message("\n# aoi_require_fly() is called by every fly caller\n")

# Comments stripped first. Round 2 applied that to the transmute scan and not to
# these, and round 3 proved the gap: deleting the real call from 01_fetch.R and
# leaving `# guarded by aoi_require_fly() in aoi.R` left the whole suite green.
# A mention is not a call.
# Ask the parser rather than a regex. `^\s*#` drops comment LINES and keeps a
# code line's trailing comment whole, so `x <- NULL  # aoi_require_fly()` passed
# the scan below — round 2 closed total removal, round 3 closed the whole-line
# comment, and that was the third spelling of one defect. A wider regex is not
# the fix either: `sub("#.*", "", line)` truncates a `#` inside a string literal,
# and 01_fetch.R has one. `parse()` drops comments by construction and proves the
# file parses while it is at it.
# Ask the parse tree for a CALL, not the file for text. Four spellings of one
# defect were closed one at a time: total removal (round 2), a whole-line comment
# (round 3), a trailing comment (round 4), and a mention inside a STRING LITERAL
# (round 5) — `message("... guarded by aoi_require_fly() ...")` passed a
# `deparse(parse(f))` scan, and `scripts/aoi.R:59` is a live example of that
# shape. `all.names()` walks the tree and returns symbols; a string constant is
# not a symbol, so no spelling of a mention can survive it.
#
# Wrapped, because a file that does not parse must be a finding rather than an
# abort: uncaught, one syntax error in any stage script killed the suite mid-run
# and the summary never printed.
guarded <- function(f) {
  tryCatch(
    any(unlist(lapply(parse(f), all.names)) == "aoi_require_fly"),
    error = function(e) {
      message("      ", basename(f), " does not parse: ", conditionMessage(e))
      FALSE
    }
  )
}

for (f in c("scripts/00_review_samples.R", "scripts/01_fetch.R",
            "scripts/02_georef.R", "scripts/test_pipeline.R")) {
  ok(paste0(basename(f), " calls aoi_require_fly()"),
     guarded(f))
}

# The complement: any script calling fly must be in the list above. Catches a
# new stage that quietly becomes a fly caller without a guard.
#
# Matched on `fly::` as well as `library(fly)`. Every stage script here calls fly
# as `fly::fly_*`, so a new one written without the `library()` line — the
# ordinary style in this repo — would have been invisible to a `library(fly)`
# filter. That is precisely the case this complement exists for: the caller
# round 1 caught being unguarded was found by a human reading, not by this.
fly_callers <- Filter(function(f) {
  grepl("library\\(fly\\)|fly::", paste(readLines(f, warn = FALSE),
                                        collapse = "\n"))
}, list.files("scripts", pattern = "\\.R$", full.names = TRUE))

# `all()` over an empty set is TRUE, so without this a wrong working directory or
# a renamed scripts/ turns the assertion below into a green no-op.
ok("found the fly callers at all", length(fly_callers) >= 4)

# aoi.R defines the guard rather than calling it, and mentions its own name in a
# stop() message — so it is excluded by name rather than being allowed to pass on
# that mention.
fly_callers <- setdiff(fly_callers, "scripts/aoi.R")

unguarded <- Filter(function(f) !guarded(f), fly_callers)

ok("no unguarded fly caller in scripts/", length(unguarded) == 0)
if (length(unguarded)) {
  message("      unguarded: ", paste(basename(unguarded), collapse = ", "))
}

# --- aoi_ledger_check_cols() ----------------------------------------------
# The schema check is what makes "the three columns actually reached the ledger"
# a measurement rather than an assertion. Both answers, and the refusal names the
# missing column and the remedy.

message("\n# aoi_ledger_check_cols()\n")

full <- as.data.frame(stats::setNames(
  rep(list(logical(0)), length(cols)), cols))

ok("accepts a complete ledger",
   is.na(refusal(aoi_ledger_check_cols(full, "se_a"))))

short <- full[, setdiff(cols, "dem_coverage"), drop = FALSE]
msg <- refusal(aoi_ledger_check_cols(short, "se_a"))
ok("refuses a ledger missing a terrain column", !is.na(msg))
ok("  ... names the missing column",
   !is.na(msg) && grepl("dem_coverage", msg, fixed = TRUE))
ok("  ... names the remedy",
   !is.na(msg) && grepl("01_fetch.R", msg, fixed = TRUE))

# A ledger predating this issue is the case that actually arrives: 02_georef.R
# reads data/select/<id>.csv from disk, and one written before #20 has none of
# the three.
pre20 <- full[, setdiff(cols, c("footprint_terrain", "height_agl",
                                "dem_coverage")), drop = FALSE]
msg <- refusal(aoi_ledger_check_cols(pre20, "se_a"))
ok("refuses a pre-#20 ledger", !is.na(msg))
ok("  ... names all three missing columns",
   !is.na(msg) && all(vapply(c("footprint_terrain", "height_agl", "dem_coverage"),
                             function(c) grepl(c, msg, fixed = TRUE),
                             logical(1))))

# Extra columns are not an error — the ledger is allowed to grow ahead of the
# readers, and refusing them would make every future addition a breaking change.
wide <- full
wide$width_source <- logical(0)
ok("tolerates an extra column",
   is.na(refusal(aoi_ledger_check_cols(wide, "se_a"))))

# --- aoi_ledger_check_id() ------------------------------------------------
# #32. The parse check above catches one spelling; this catches the class, in
# every stage that writes or reads a ledger. Fixtures carry rows, because every
# column check passes vacuously on the zero-row `full` above.

message("\n# aoi_ledger_check_id()\n")

wfs <- "WHSE_IMAGERY_AND_BASE_MAPS.AIMG_PHOTO_CENTROIDS_SP.1174688"

ok("accepts a ledger whose aoi_id is the AOI",
   is.na(refusal(aoi_ledger_check_id(
     data.frame(aoi_id = c("se_c", "se_c"), airp_id = 1:2), "se_c"))))
ok("accepts a zero-row ledger",
   is.na(refusal(aoi_ledger_check_id(
     data.frame(aoi_id = character(0)), "se_c"))))

msg <- refusal(aoi_ledger_check_id(
  data.frame(aoi_id = c(wfs, wfs), airp_id = 1:2), "se_c"))
ok("refuses WFS feature ids (the #32 ledger)", !is.na(msg))
ok("  ... names the AOI",
   !is.na(msg) && grepl("'se_c'", msg, fixed = TRUE))
ok("  ... names an offending value",
   !is.na(msg) && grepl(wfs, msg, fixed = TRUE))
ok("  ... names the remedy",
   !is.na(msg) && grepl("01_fetch.R", msg, fixed = TRUE))

ok("refuses a ledger mixing the AOI with another",
   !is.na(refusal(aoi_ledger_check_id(
     data.frame(aoi_id = c("se_c", "se_b"), airp_id = 1:2), "se_c"))))
ok("refuses an NA aoi_id",
   !is.na(refusal(aoi_ledger_check_id(
     data.frame(aoi_id = c("se_c", NA), airp_id = 1:2), "se_c"))))
# A missing column must not read as "no offending values".
ok("refuses a ledger with no aoi_id column",
   !is.na(refusal(aoi_ledger_check_id(data.frame(airp_id = 1:2), "se_c"))))

# Wired in, asked of the parse tree as for aoi_require_fly() above: the writer
# every stage goes through, and 02_georef.R's read, which must abort before any
# GeoTIFF is written rather than at the write after them.
#
# The writer must CALL it (a bare symbol reference is not a call) in a statement
# before the one that writes, or a mis-keyed ledger overwrites the good one on
# disk and is refused only afterwards. Both anchors must be found, as below.
calls_in <- function(e) {
  if (!is.call(e)) return(character(0))
  f <- e[[1]]
  nm <- if (is.name(f)) {
    as.character(f)
  } else if (is.call(f) && identical(f[[1]], as.name("::"))) {
    as.character(f[[3]])
  } else {
    character(0)
  }
  c(nm, unlist(lapply(as.list(e)[-1], calls_in)))
}
ok("aoi_ledger_write() calls aoi_ledger_check_id() before writing",
   tryCatch({
     stmts <- as.list(body(aoi_ledger_write))[-1]
     first <- function(fn) {
       min(which(vapply(stmts, function(st) fn %in% calls_in(st), logical(1))),
           Inf)
     }
     at <- first("aoi_ledger_check_id")
     wr <- first("write_csv")
     is.finite(at) && is.finite(wr) && at < wr
   }, error = function(e) FALSE))
# "On the read" means before any work: the check CALL must come after the
# ledger's read_csv() and before every call that touches files -- the per-year
# map_dfr() and, inside it, fly_footprint(), the stale-GeoTIFF unlink() and
# fly_georef(). Parse data, not text: a mention in a comment or a string is not
# a call token. Every anchor must be FOUND. An absent one is Inf, and a
# comparison against Inf passes any placement -- round 2 of the review showed
# fly_georef() passed as a value (do.call, purrr::map) does exactly that.
call_line <- function(pd, fn) {
  min(pd$line1[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == fn], Inf)
}
ok("02_georef.R calls aoi_ledger_check_id() on the read",
   tryCatch({
     pd <- utils::getParseData(parse("scripts/02_georef.R", keep.source = TRUE))
     at <- call_line(pd, "aoi_ledger_check_id")
     read <- call_line(pd, "read_csv")
     work <- vapply(c("map_dfr", "fly_footprint", "unlink", "fly_georef"),
                    function(fn) call_line(pd, fn), numeric(1))
     all(is.finite(c(at, read, work))) && read < at && at < min(work)
   }, error = function(e) FALSE))

# --- aoi_rotation_default() -----------------------------------------------
# The series rule for rolls nobody measured (#23). Re-typed from the #23 body and
# research section 14, not derived from the function: a boundary moved by a year
# must go red here.

message("\n# aoi_rotation_default()\n")

ok("bc5xxx through 1974 is 0",
   identical(aoi_rotation_default(c("bc5281", "bc5420", "bc5596"), c(1968, 1972, 1974)),
             c(0L, 0L, 0L)))
ok("bc5xxx 1975-76 is 90",
   identical(aoi_rotation_default(c("bc5688", "bc5700"), c(1975, 1976)), c(90L, 90L)))
ok("  ... and is flagged for review",
   identical(aoi_rotation_needs_review(c("bc5688", "bc5700", "bc5596", "bc7796"),
                                       c(1975, 1976, 1974, 1976)),
             c(TRUE, TRUE, FALSE, FALSE)))
ok("bc5xxx after 1976 has no default, not a guess",
   is.na(aoi_rotation_default("bc5800", 1977)))
ok("bc5xxx with no year has no default",
   is.na(aoi_rotation_default("bc5300", NA)))
ok("bc7xxx on, bcb and bcc are 90",
   identical(aoi_rotation_default(c("bc7796", "bc78065", "bc83062", "bcb98013", "bcc00085", "bcc668"),
                                  c(1977, 1978, 1983, 1998, 2000, 1990)),
             rep(90L, 6)))
ok("an unknown series has no default",
   all(is.na(aoi_rotation_default(c("bcd12008", "xx5281", "bc5281a", NA), c(2012, 1968, 1968, 1968)))))
ok("empty in, empty out",
   identical(aoi_rotation_default(character(0), integer(0)), integer(0)))

# --- aoi_rotation_for() ---------------------------------------------------
# Film gets the roll's measured value, else the series default; digital gets NA,
# because a supplied rotation overrides the corner mapping fly measured.

message("\n# aoi_rotation_for()\n")

tab <- data.frame(film_roll = c("bc5282", "bc83062", "bc81050"),
                  rotation = c(90L, 0L, 90L),   # deliberately unlike the series rule
                  rotation_source = c("reviewed", "measured", "disputed"))

r <- aoi_rotation_for(
  media             = c("Film - BW", "Film - BW", "Film - Colour", "Digital - Colour", "Film - BW"),
  footprint_terrain = c("dem_agl", "dem_agl", "dem_agl", "gsd_scaled", "dem_agl"),
  film_roll         = c("bc5282", "bc83062", "bc7796", "bcd12008", "bc81050"),
  photo_year        = c(1968, 1983, 1977, 2012, 1981),
  table = tab)

ok("the table beats the series rule",
   identical(r$rotation[1:2], c(90L, 0L)))
ok("  ... and carries the table's source",
   identical(r$rotation_source[c(1, 2, 5)], c("reviewed", "measured", "disputed")))
ok("an unmeasured film roll takes the series default",
   identical(r$rotation[3], 90L) && identical(r$rotation_source[3], "assumed_by_series"))
ok("digital gets no rotation and no source",
   is.na(r$rotation[4]) && is.na(r$rotation_source[4]))
ok("film on an unknown series is left NA, unsourced",
   { u <- aoi_rotation_for("Film - BW", "dem_agl", "zz999", 1970, table = tab)
     is.na(u$rotation) && is.na(u$rotation_source) })
ok("NA media is not film",
   is.na(aoi_rotation_for(NA_character_, "dem_agl", "bc5282", 1968, table = tab)$rotation))
ok("anchored at the start of media",
   is.na(aoi_rotation_for("Digital Film - X", "dem_agl", "bc5282", 1968, table = tab)$rotation))
ok("empty input gives zero rows",
   nrow(aoi_rotation_for(character(0), character(0), character(0), integer(0), table = tab)) == 0L)

# The real table reads and uses the committed vocabulary.
real_tab <- aoi_rotation_table()
ok("the committed rotation table carries only known sources",
   all(real_tab$rotation_source %in% c("measured", "reviewed", "disputed")))
ok("  ... and only quarter turns",
   all(real_tab$rotation %in% c(0L, 90L, 180L, 270L)))

# NULL is a THIRD state: the column is absent. Without the guard every frame
# would be classified digital and every film frame sent to fly's refusal.
for (args in list(list(NULL, "dem_agl", "bc5282", 1968),
                  list("Film - BW", "dem_agl", NULL, 1968))) {
  msg <- refusal(do.call(aoi_rotation_for, c(args, list(table = tab))))
  ok("refuses an absent media or film_roll column", !is.na(msg))
  ok("  ... names the remedy",
     !is.na(msg) && grepl("FORCE_REFRESH", msg, fixed = TRUE))
}

# An unrecognised terrain route must abort, not be classified.
msg <- refusal(aoi_rotation_for("Film - BW", "gsd_scaled_v2", "bc5282", 1968, table = tab))
ok("refuses an unrecognised footprint_terrain", !is.na(msg))
ok("  ... names the offending value",
   !is.na(msg) && grepl("gsd_scaled_v2", msg, fixed = TRUE))
# Re-typed so a widening or narrowing of aoi_terrain_values() goes red. A
# change-detector, not a validation: the fly-side pin above is what validates it.
expected_terrain <- c("nominal_scale", "gsd_scaled", "dem_agl", "no_dem_coverage")
ok("terrain vocabulary matches the declared contract",
   setequal(aoi_terrain_values(), expected_terrain))
ok("every known value is accepted",
   is.na(refusal(aoi_rotation_for(rep("Digital - Colour", 4), expected_terrain,
                                  rep("bcd12008", 4), rep(2012, 4), table = tab))))
ok("NA terrain is not unrecognised",
   is.na(refusal(aoi_rotation_for("Film - BW", NA_character_, "bc5282", 1968, table = tab))))

# Film by the catalogue, digital route by fly: one of the two is wrong.
msg <- refusal(aoi_rotation_for(c("Film - BW", "Digital - Colour"),
                                c("gsd_scaled", "gsd_scaled"),
                                c("bc5282", "bcd12008"), c(1968, 2012), table = tab))
ok("refuses film sized by fly's digital route", !is.na(msg))
ok("  ... counts only the clashing frame",
   !is.na(msg) && grepl("^1 frame", msg))

# --- aoi_match_types() ---------------------------------------------------
# A WFS batch typed on its own contents (an all-null column arrives character)
# must be cast to the cache's types, and a cast that drops a value must abort.

message("\n# aoi_match_types()\n")

ref <- data.frame(g = 2L, d = as.Date("2000-01-01"), s = "x", n = 1.5)
got <- aoi_match_types(data.frame(g = NA_character_, d = "2001-02-03", s = 7L, n = "2.25"), ref)
ok("an all-null character column becomes the reference integer",
   is.integer(got$g) && is.na(got$g))
ok("dates, characters and doubles follow the reference",
   inherits(got$d, "Date") && is.character(got$s) && identical(got$n, 2.25))
msg <- refusal(aoi_match_types(data.frame(g = c("3", "three")), ref))
ok("a cast that would drop a value aborts", !is.na(msg))
ok("  ... naming the column and the value",
   !is.na(msg) && grepl("`g`", msg, fixed = TRUE) && grepl("three", msg, fixed = TRUE))

# --- Result ---------------------------------------------------------------

message("")
if (skipped > 0L) {
  message(skipped, " assertion(s) SKIPPED - see above. They are not passes.")
}
if (failures > 0L) {
  stop(failures, " assertion(s) failed", call. = FALSE)
}
message("All assertions passed",
        if (skipped > 0L) paste0(" (", skipped, " skipped).") else ".")
