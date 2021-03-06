
# Make sure data.table knows we know we're using it
.datatable.aware = TRUE

new_rddt <- function(data, partition_by = NULL, cluster = get_cl()) {

  stopifnot(inherits(cluster, "cluster"))

  if (is.character(data)) {
    stopifnot(length(data) == 1L)
    info <- list(
      heads = cluster$eval(call("head", as.symbol(data), n = 10L)),
      nrows = as.integer(cluster$eval(call("nrow", as.symbol(data)))),
      cluster = cluster,
      id = data,
      partition = partition_by
    )
  } else if (data.table::is.data.table(data)) {
    if (is.null(partition_by)) {
      data <- split(data, group_indices(nrow(data), cluster$n_workers))
    } else {
      data <- grouped_split_by(data, partition_by, cluster$n_workers)
    }
    info <- list(
      heads = lapply(data, head, n = 10L),
      nrows = vapply(data, nrow, integer(1L)),
      cluster = cluster,
      id = rand_name(),
      partition = partition_by
    )
    cluster$scatter(data, name = info$id)
  } else {
    stop("data can either be character or data.table")
  }

  res <- list2env(info)

  reg.finalizer(res, function(x) {
    x$cluster$call(rm, list = x$id, envir = .GlobalEnv)
  })

  structure(res, class = "rddt")
}

#' @export
read_rddt <- function(files, read_fun, partition = NULL,
                      cluster = get_cl(), ...) {

  stopifnot(
    length(files) >= cluster$n_workers, all(file.exists(files)),
    is.function(read_fun)
  )

  id <- rand_name()
  dots <- match.call(expand.dots = FALSE)$`...`
  files <- split(files, group_indices(length(files), cluster$n_workers))

  exprs <- lapply(files, function(x) {
    call <- as.call(c(read_files, list(x), read_fun, dots))
    substitute(
      expression({assign(id, call); TRUE}),
      list(id = id, call = call)
    )
  })

  res <- Map(cluster$eval, exprs, seq_len(cluster$n_workers) + 1L)
  stopifnot(all(unlist(res)))

  new_rddt(id, partition = partition, cluster = cluster)
}

#' @export
rddt <- function(..., partition_by = NULL, cluster = get_cl()) {
  new_rddt(data.table::data.table(...), partition_by, cluster)
}

#' @export
as_rddt <- function(data, partition_by = NULL, cluster = get_cl()) {
  new_rddt(data.table::as.data.table(data), partition_by, cluster)
}

#' @export
collect <- function(data) {
  stopifnot(inherits(data, "rddt"))
  data.table::rbindlist(
    data$cluster$gather(data$id)
  )
}

#' @export
`[.rddt` <- function(x, ..., in_place = TRUE) {

  dots <- match.call(expand.dots = FALSE)$`...`
  dt_call <- as.call(c(list(as.symbol("["), x = as.name(x$id)), dots))

  if (in_place) {
    expr <- substitute(expression({dt_call; TRUE}))
  } else {
    new_id <- rand_name()
    expr <- substitute(expression({assign(new_id, dt_call); TRUE}))
  }

  res <- x$cluster$eval(expr)
  stopifnot(all(unlist(res)))

  if (in_place) {
    invisible(x)
  } else {
    invisible(new_rddt(new_id))
  }
}

#' @export
print.rddt <- function(x, n = 10L, width = NULL, ...) {

  lens <- vapply(x$heads, nrow, integer(1L))

  if (min(lens) < n) {
    dat <- x$cluster$eval(call("head", as.symbol(x$id), n = n))
  } else {
    dat <- lapply(x$heads, head, n = n)
  }

  lens <- vapply(dat, nrow, integer(1L))
  dat <- data.table::rbindlist(dat)

  real_inds <- Map(
    function(start, length) seq.int(start, length.out = length),
    cumsum(x$nrows) - x$nrows + 1L, lens
  )

  real_inds <- list(
    capital_format = rep(
      paste(rep(" ", nchar(sum(x$nrows))), collapse = ""), 2L
    ),
    shaft_format = pillar::style_subtle(
      format(unlist(real_inds, use.names = FALSE))
    )
  )

  term_width <- getOption("width")
  options(width = term_width - nchar(sum(x$nrows)))
  on.exit(options(width = term_width))

  dat <- pillar::colonnade(dat, has_row_id = FALSE, width = width)
  dat <- pillar::squeeze(dat)
  extra <- pillar::extra_cols(dat)
  tmp <- lapply(dat, function(x) c(list(real_inds), x))
  attributes(tmp) <- attributes(dat)

  n_tables <- length(tmp)
  dat <- format(tmp)
  max_width <- pillar::get_max_extent(dat)

  header <- paste0(
    "# An rddt [", big_mark(sum(x$nrows)), " x ",
    big_mark(ncol(x$heads[[1L]])), "] with ", length(x$nrows), " partitions"
  )
  header <- pillar::style_subtle(wrap(header, max_width))
  extra_rows <- paste("# with", big_mark(x$nrows - lens), "more rows")
  footer <- extra_rows[length(extra_rows)]
  if (length(extra) > 0L) {
    footer <- paste0(
      footer, ", and ", length(extra),
      if (length(extra) > 1L) " more variables: " else " more variable: ",
      paste0(extra, collapse = ", ")
    )
  }
  footer <- pillar::style_subtle(wrap(footer, max_width))
  extra_rows <- pillar::style_subtle(wrap(extra_rows, max_width))

  tmp <- split(dat, rep(seq_len(n_tables), each = 2L + sum(lens)))
  tmp <- lapply(tmp, split, c(1L, 1L, rep(seq_along(lens), lens)))
  tmp <- lapply(tmp, function(y) Map(c, y, extra_rows))
  tmp <- c(header, unlist(tmp, recursive = TRUE))
  tmp[length(tmp)] <- footer
  class(tmp) <- class(dat)
  print(tmp)

  invisible(x)
}

big_mark <- function(x, ...) {
  mark <- if (identical(getOption("OutDec"), ",")) "." else ","
  ret <- formatC(x, big.mark = mark, ...)
  ret[is.na(x)] <- "??"
  ret
}

wrap <- function(x, width, insert = "\n# ") {
  vapply(x, 
    function(y) paste0(fansi::strwrap_ctl(y, width = width), collapse = insert),
    character(1L), USE.NAMES = FALSE
  )
}
