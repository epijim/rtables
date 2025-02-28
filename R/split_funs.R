## Generics and how they are used directly

## check_validsplit - Check if the split is valid for the data, error if not

## .apply_spl_extras - Generate Extras

## .apply_spl_datapart - generate data partition

## .apply_spl_rawvals - Generate raw (ie non SplitValue object) partition values



setGeneric(".applysplit_rawvals",
           function(spl, df) standardGeneric(".applysplit_rawvals"))

setGeneric(".applysplit_datapart",
           function(spl, df, vals) standardGeneric(".applysplit_datapart"))

setGeneric(".applysplit_extras",
           function(spl, df, vals) standardGeneric(".applysplit_extras"))

setGeneric(".applysplit_partlabels",
           function(spl, df, vals, labels) standardGeneric(".applysplit_partlabels"))

setGeneric("check_validsplit",
           function(spl, df) standardGeneric("check_validsplit"))

setGeneric(".applysplit_ref_vals",
          function(spl, df, vals) standardGeneric(".applysplit_ref_vals"))



## do various cleaning, and naming, plus
## ensure partinfo$values contains SplitValue objects only
.fixupvals = function(partinfo) {
    if(is.factor(partinfo$labels))
        partinfo$labels = as.character(partinfo$labels)

    vals = partinfo$values
    if(is.factor(vals))
        vals = levels(vals)[vals]
    extr = partinfo$extras
    dpart = partinfo$datasplit
    labels = partinfo$labels
    if(is.null(labels)) {
        if(!is.null(names(vals)))
            labels = names(vals)
        else if(!is.null(names(dpart)))
            labels = names(dpart)
        else if (!is.null(names(extr)))
            labels = names(extr)
    }

    if(is.null(vals) && !is.null(extr))
        vals = seq_along(extr)

    if(length(vals) == 0) {
        stopifnot(length(extr) == 0)
        return(partinfo)
    }
    ## length(vals) > 0 from here down

    if(are(vals, "SplitValue") && !are(vals, "LevelComboSplitValue")) {
        if(!is.null(extr)) {
            warning("Got a partinfo list with values that are ",
                    "already SplitValue objects and non-null extras ",
                    "element. This shouldn't happen")
        }
    } else {
        if(is.null(extr))
            extr = rep(list(list()), length(vals))
        ## strict is FALSE here cause fixupvals might be called repeatedly
        vals = make_splvalue_vec(vals, extr, labels = labels)
    }
    ## we're done with this so take it off
    partinfo$extras = NULL

    vnames <- value_names(vals)
    names(vals) = vnames
    partinfo$values = vals

    if(!identical(names(dpart), vnames)) {
        names(dpart) = vnames
        partinfo$datasplit = dpart
    }


    partinfo$labels = labels

    stopifnot(length(unique(sapply(partinfo, NROW))) == 1)
    partinfo
}

.add_ref_extras <- function(spl, df, partinfo) {
    ## this is only the .in_ref_col booleans
    refvals <- .applysplit_ref_vals(spl, df, partinfo$values)
    ref_ind <- which(unlist(refvals))
    stopifnot(length(ref_ind) == 1)

    vnames <- value_names(partinfo$values)
    if(is.null(partinfo$extras)) {
        names(refvals) <- vnames
        partinfo$extras <- refvals
    } else {
        newextras <- mapply(function(old, incol, ref_full)
            c(old, list(.in_ref_col = incol,
                        .ref_full = ref_full)),
            old = partinfo$extras,
            incol = unlist(refvals),
            MoreArgs = list(ref_full = partinfo$datasplit[[ref_ind]]),
                            SIMPLIFY = FALSE)
        names(newextras) <- vnames
        partinfo$extras <- newextras
    }
    partinfo
}

func_takes <- function(fun, argname, truefordots = FALSE) {
    fnames <- names(formals(fun))
    argname %in% fnames || (truefordots && "..." %in% fnames)
}

### NB This is called at EACH level of recursive splitting
do_split = function(spl, df, vals = NULL, labels = NULL, trim = FALSE, prev_splvals) {
    ## this will error if, e.g., df doesn't have columns
    ## required by spl, or generally any time the spl
    ## can't be applied to df
    check_validsplit(spl, df)
    ## note the <- here!!!
    if(!is.null(splfun<-split_fun(spl))) {
        ## Currently the contract is that split_functions take df, vals, labels and
        ## return list(values=., datasplit=., labels = .), optionally with
        ## an additional extras element
        if(func_takes(splfun, ".prev_splvals")) {
            stopifnot(is.null(prev_splvals) || identical(names(prev_splvals), c("split", "value")))
            ret <- splfun(df, spl, vals, labels, trim = trim, .prev_splvals = prev_splvals) ## rawvalues(prev_splvals ))
        } else {
            ret <- splfun(df, spl, vals, labels, trim = trim)
        }
    } else {
        ret <- .apply_split_inner(df = df, spl = spl, vals = vals, labels = labels, trim = trim)
    }

    ## this adds .ref_full and .in_ref_col
    if(is(spl, "VarLevWBaselineSplit"))
        ret <- .add_ref_extras(spl, df, ret)

    ## this:
    ## - guarantees that ret$values contains SplitValue objects
    ## - removes the extras element since its redundant after the above
    ## - Ensures datasplit and values lists are named according to labels
    ## - ensures labels are character not factor
    ret <- .fixupvals(ret)

    ret
}

.apply_split_inner = function(spl, df, vals = NULL, labels = NULL, trim = FALSE) {

    ## try to calculate values first. Most of the time we can
    if(is.null(vals))
        vals = .applysplit_rawvals(spl, df)
    extr = .applysplit_extras(spl, df, vals)

    ## in some cases, we don't know the
    ## values until after we know the extra args, since the values
    ## themselves are meaningless. If this is the case, fix them
    ## before generating the data partition

    ## I don't know if the above is still true... ~G
    if(is.null(vals) && length(extr) > 0) {
        vals = seq_along(extr)
        names(vals) = names(extr)
    }

    if(is.null(vals)) {
        return(list(values = list(),
                    datasplit = list(),
                    labels = list(),
                    extras = list()))
    }

    dpart = .applysplit_datapart(spl, df, vals)

    if(is.null(labels))
        labels = .applysplit_partlabels(spl, df, vals, labels)
    else
        stopifnot(names(labels)== names(vals))
    ## get rid of columns that would not have any
    ## observations.
    ##
    ## But only if there were any rows to start with
    ## if not we're in a manually constructed table
    ## column tree
    if(trim) {
        hasdata = sapply(dpart, function(x) nrow(x) >0)
        if(nrow(df) > 0 && length(dpart) > sum(hasdata)) { #some empties
            dpart = dpart[hasdata]
            vals = vals[hasdata]
            extr = extr[hasdata]
            labels = labels[hasdata]
        }
    }

    if(is.null(spl_child_order(spl)) || is(spl, "AllSplit")) {
        vord = seq_along(vals)
    } else {
        vord = match(spl_child_order(spl),
                     vals)
        vord = vord[!is.na(vord)]
    }


    ## FIXME: should be an S4 object, not a list
    ret = list(values = vals[vord],
               datasplit = dpart[vord],
               labels = labels[vord],
               extras = extr[vord])
    ret
}


.checkvarsok = function(spl, df) {

    vars = spl_payload(spl)
    ## could be multiple vars in the future?
    ## no reason not to make that work here now.
    if(!all(vars %in% names(df)))
        stop( " variable(s) [",
             paste(setdiff(vars, names(df)),
                   collapse = ", "),
             "] not present in data. (",
             class(spl), ")")
    invisible(NULL)

}

### Methods to verify a split appears to be valid, applicable
### to the ***current subset*** of the df.
###
### This is called at each level of recursive splitting so
### do NOT make it check, e.g., if the ref_group level of
### a factor is present in the data, because it may not be.



setMethod("check_validsplit", "VarLevelSplit",
          function(spl, df) {
    .checkvarsok(spl, df)
})


setMethod("check_validsplit", "MultiVarSplit",

          function(spl, df) {
    .checkvarsok(spl, df)
})

setMethod("check_validsplit", "VAnalyzeSplit",

          function(spl, df) {
    if(!is.na(spl_payload(spl))) {
        .checkvarsok(spl, df)
    } else {
        TRUE
    }
})

setMethod("check_validsplit", "CompoundSplit",
          function(spl, df) {
    all(sapply(spl_payload(spl), df))
})




## default does nothing, add methods as they become
## required
setMethod("check_validsplit", "Split",
          function(spl, df)
    invisible(NULL))



setMethod(".applysplit_rawvals", "VarLevelSplit",
          function(spl, df) {
    varvec = df[[spl_payload(spl)]]
    if(is.factor(varvec))
        levels(varvec)
    else
        unique(varvec)
})

setMethod(".applysplit_rawvals", "MultiVarSplit",
          function(spl, df) {
##    spl_payload(spl)
    spl_varnames(spl)
})

setMethod(".applysplit_rawvals", "AllSplit",
          function(spl, df) obj_name(spl)) #"all obs")

setMethod(".applysplit_rawvals", "ManualSplit",
          function(spl, df) spl@levels)


setMethod(".applysplit_rawvals", "NULLSplit",
          function(spl, df) "")

setMethod(".applysplit_rawvals", "VAnalyzeSplit",
          function(spl, df) spl_payload(spl))


## formfactor here is gross we're gonna have ot do this
## all again in tthe data split part :-/
setMethod(".applysplit_rawvals", "VarStaticCutSplit",
          function(spl, df) {
    spl_cutlabels(spl)
})


setMethod(".applysplit_datapart", "VarLevelSplit",
          function(spl, df, vals) {
    if(!(spl_payload(spl) %in% names(df))) {
        stop("Attempted to split on values of column (", spl_payload(spl), ") not present in the data")
    }
    ret = lapply(seq_along(vals), function(i) {
        df[df[[spl_payload(spl)]] == vals[[i]],]
    })
    names(ret) = as.character(vals)
    ret
})


setMethod(".applysplit_datapart", "MultiVarSplit",
          function(spl, df, vals) {
    allvnms <- spl_varnames(spl)
    if(!is.null(vals) && !identical(allvnms, vals)) {
        incl <- match(vals, allvnms)
    } else {
        incl <- seq_along(allvnms)
    }
    vars <- spl_payload(spl)[incl]
    ## don't remove  nas
    ## ret = lapply(vars, function(cl) {
    ##     df[!is.na(df[[cl]]),]
    ## })
    ret <- rep(list(df), length(vars))
    names(ret) = vals
    ret
})

setMethod(".applysplit_datapart", "AllSplit",
          function(spl, df, vals) list(df))

## not sure I need this
setMethod(".applysplit_datapart", "ManualSplit",
          function(spl, df, vals) rep(list(df), times = length(vals)))



setMethod(".applysplit_datapart", "NULLSplit",
          function(spl, df, vals) list(df[FALSE,]))


setMethod(".applysplit_datapart", "VarStaticCutSplit",
          function(spl, df, vals) {
  #  lbs = spl_cutlabels(spl)
    var = spl_payload(spl)
    varvec = df[[var]]
    cts = spl_cuts(spl)
    cfct = cut(varvec, cts, include.lowest = TRUE)#, labels = lbs)
    split(df, cfct, drop = FALSE)

})
## XXX TODO *CutSplit Methods


setClass("NullSentinel", contains = "NULL")
nullsentinel = new("NullSentinel")
noarg = function() nullsentinel

## Extras generation methods
setMethod(".applysplit_extras", "Split",
          function(spl, df, vals) {
    splex <- split_exargs(spl)
    nextr <- length(splex)
    nvals <- length(vals)
    ## stopifnot(nvals > 0,
    ##           nextr <= nvals)
    lapply(seq_len(nvals), function(vpos) {
        one_ex <- lapply(splex, function(arg) {
            if(length(arg) >= vpos)
                arg[[vpos]]
            else
                noarg()
            })
        names(one_ex) <- names(splex)
        one_ex <- one_ex[!sapply(one_ex, is, "NullSentinel")]
        one_ex
    })

})



setMethod(".applysplit_ref_vals", "Split",
          function(spl, df, vals) rep(list(NULL), length(vals)))

setMethod(".applysplit_ref_vals", "VarLevWBaselineSplit",
          function(spl, df, vals) {
    var <- spl_payload(spl)
    bl_level <- spl@ref_group_value #XXX XXX
    bldata <- df[df[[var]] %in% bl_level,]
    vnames <- value_names(vals)
    ret <- lapply(vnames, function(vl) {
        list(.in_ref_col = vl == bl_level)
    })
    names(ret) <- vnames
    ret
})

## XXX TODO FIXME
setMethod(".applysplit_partlabels", "Split",
          function(spl, df, vals, labels) as.character(vals))

setMethod(".applysplit_partlabels", "VarLevelSplit",
          function(spl, df, vals, labels) {

    varname <- spl_payload(spl)
    vlabelname <- spl_labelvar(spl)
    varvec = df[[varname]]
    if(is.null(vals)) {
        vals = if(is.factor(varvec))
                   levels(varvec)
               else
                   unique(varvec)
    }
    if(is.null(labels)) {
        if(varname == vlabelname) {
            labels = vals
            ## } else if (is.factor(df[[vlabelname]])) {
            ##     labels = levels(df[varvec %in% vals, ][[vlabelname]])
        } else {
            labfact <- is.factor(df[[vlabelname]])
            lablevs <- if(labfact) levels(df[[vlabelname]]) else NULL
            labels = sapply(vals, function(v) {
                vlabel = unique(df[varvec == v,
                                   vlabelname, drop = TRUE])
                ## TODO remove this once 1-to-1 value-label map is enforced elsewhere.
                stopifnot(length(vlabel) < 2)
                if(length(vlabel) == 0)
                vlabel = ""
                else if(labfact)
                    vlabel <- lablevs[vlabel]
                vlabel
            })
        }
    }
    names(labels) = as.character(vals)
    labels
})

setMethod(".applysplit_partlabels", "MultiVarSplit",
          function(spl, df, vals, labels) value_labels(spl))



## subsets_from_factory = function(df, fact) {
##    if(is.character(fact)) {
##        tmpvals = unique(df[[fact]])
##        fctor = factor(df[[fact]], levels = tmpvals)
##        ssets = split(df, fctor)
##        ## I think split already does this...
##        names(ssets) = tmpvals
##    } else {
##        ssets = fact(df)
##    }

##    ssets
## }


make_splvalue_vec = function(vals, extrs = list(list()), labels = vals) {
    if(length(vals) == 0)
        return(vals)

    if(is(extrs, "AsIs"))
        extrs = unclass(extrs)
    ## if(are(vals, "SplitValue")) {

    ##     return(vals)
    ## }

    mapply(SplitValue, val = vals, extr = extrs,
           label = labels,
           SIMPLIFY=FALSE)
}


#' Split functions
#' @inheritParams sf_args
#' @inheritParams gen_args
#' @param vals ANY. For internal use only.
#' @param labels character. Labels to use for the remaining levels instead of the existing ones.
#' @param excl character. Levels to be excluded (they will not be reflected in the resulting table structure regardless
#'   of presence in the data).
#'
#' @rdname split_funcs
#' @export
#' @inherit add_overall_level return
#' @examples
#' l <- basic_table() %>%
#'   split_cols_by("ARM") %>%
#'   split_rows_by("COUNTRY", split_fun = remove_split_levels(c("USA", "CAN", "CHE", "BRA"))) %>%
#'   analyze("AGE")
#'
#' build_table(l, DM)
#'
remove_split_levels <- function(excl) {
    stopifnot(is.character(excl))
    function(df, spl, vals = NULL, labels = NULL, trim = FALSE) {
        var = spl_payload(spl)
        df2 = df[!(df[[var]] %in% excl), ]
        if(is.factor(df2[[var]])) {
          levels = levels(df2[[var]])
          levels = levels[!(levels %in% excl)]
          df2[[var]] = factor(df2[[var]], levels = levels)
        }
        .apply_split_inner(spl, df2, vals = vals,
                           labels = labels,
                           trim = trim)
    }
}

#' @rdname split_funcs
#' @param only character. Levels to retain (all others will be dropped).
#' @param reorder logical(1). Should the order of \code{only} be used as the order of the children of the split. defaults to \code{TRUE}
#' @export
#'
#' @examples
#' l <- basic_table() %>%
#'   split_cols_by("ARM") %>%
#'   split_rows_by("COUNTRY", split_fun = keep_split_levels(c("USA", "CAN", "BRA"))) %>%
#'   analyze("AGE")
#'
#' build_table(l, DM)
keep_split_levels = function(only, reorder = TRUE) {
    function(df, spl, vals = NULL, labels = NULL, trim = FALSE) {
        var = spl_payload(spl)
        varvec = df[[var]]
        if(is.factor(varvec) && !all(only %in% levels(varvec)))
            stop("Attempted to keep invalid factor level(s) in split ", setdiff(only, levels(varvec)))
        df2 = df[df[[var]] %in% only,]
        if(reorder)
            df2[[var]] = factor(df2[[var]], levels = only)
        spl_child_order(spl) <- only
        .apply_split_inner(spl, df2, vals = only,
                           labels = labels,
                           trim = trim)
    }
}

#' @rdname split_funcs
#' @export
#'
#' @examples
#' l <- basic_table() %>%
#'   split_cols_by("ARM") %>%
#'   split_rows_by("SEX", split_fun = drop_split_levels) %>%
#'   analyze("AGE")
#'
#' build_table(l, DM)
drop_split_levels <- function(df, spl, vals = NULL, labels = NULL, trim = FALSE) {
        var = spl_payload(spl)
        df2 = df
        df2[[var]] = factor(df[[var]])
        .apply_split_inner(spl, df2, vals = vals,
                           labels = labels,
                           trim = trim)
}

#' @rdname split_funcs
#' @export
#'
#' @examples
#' l <- basic_table() %>%
#'   split_cols_by("ARM") %>%
#'   split_rows_by("SEX", split_fun = drop_and_remove_levels(c("M", "U"))) %>%
#'   analyze("AGE")
#'
#' build_table(l, DM)
drop_and_remove_levels <- function(excl) {
  stopifnot(is.character(excl))
  function(df, spl, vals = NULL, labels = NULL, trim = FALSE) {
    var <- spl_payload(spl)
    df2 <- df[!(df[[var]] %in% excl), ]
    df2[[var]] = factor(df2[[var]])
    .apply_split_inner(
      spl,
      df2,
      vals = vals,
      labels = labels,
      trim = trim
    )
  }
}


#' @rdname split_funcs
#' @param neworder character. New order or factor levels.
#' @param newlabels character. Labels for (new order of) factor levels
#' @param drlevels logical(1). Should levels in the data which do not appear in \code{neworder} be dropped. Defaults to \code{TRUE}
#' @export
#'
reorder_split_levels = function(neworder, newlabels = neworder, drlevels = TRUE) {
    if(length(neworder) != length(newlabels)) {
        stop("Got mismatching lengths for neworder and newlabels.")
    }
    function(df, spl,  trim, ...) {
         df2 <- df
        valvec <- df2[[spl_payload(spl)]]
        vals <- if(is.factor(valvec)) levels(valvec) else unique(valvec)
        if(!drlevels)
            neworder <- c(neworder, setdiff(vals, neworder))
        df2[[spl_payload(spl)]] = factor(valvec, levels = neworder)
        if(drlevels) {
            orig_order <- neworder
            df2[[spl_payload(spl)]] <- droplevels(df2[[spl_payload(spl)]] )
            neworder <- levels(df2[[spl_payload(spl)]])
            newlabels <- newlabels[orig_order %in% neworder]
        }
        spl_child_order(spl) <- neworder
        .apply_split_inner(spl, df2, vals = neworder, labels = newlabels, trim = trim)
    }
}


#' @rdname split_funcs
#' @param innervar character(1). Variable whose factor levels should be trimmed (e.g., empty levels dropped) \emph{separately within each grouping defined at this point in the structure}
#' @param drop_outlevs logical(1). Should empty levels in the variable being split on (ie the 'outer' variable, not \code{innervar})
#' be dropped? Defaults to \code{TRUE}
#' @export
trim_levels_in_group = function(innervar, drop_outlevs = TRUE) {
    myfun = function(df, spl, vals = NULL, labels = NULL, trim = FALSE) {
        if(!drop_outlevs)
            ret <- .apply_split_inner(spl, df, vals = vals, labels = labels, trim = trim)
        else
            ret <- drop_split_levels(df = df, spl = spl, vals = vals, labels = labels, trim = trim)

        ret$datasplit = lapply(ret$datasplit, function(x) {
            coldat = x[[innervar]]
            if(is(coldat, "character")) {
                if(!is.null(vals))
                    lvs = vals
                else
                    lvs = unique(coldat)
                coldat = factor(coldat, levels = lvs) ## otherwise
            } else {
                coldat = droplevels(coldat)
            }
            x[[innervar]] = coldat
            x
        })
        ret$labels <- as.character(ret$labels) # TODO
        ret
    }
    myfun
}

## #' @rdname split_funcs
## #' @param outervar character(1). Parent split variable to trim \code{innervar} levels within. Must appear in map
## #' @param map data.frame. Data frame mapping \code{outervar} values  to allowable \code{innervar} values. If no map exists a-priori, use
## #' @export
## trim_levels_by_map = function(innervar, outervar, map = NULL) {
##     if(is.null(map))
##         stop("no map dataframe was provided. Use trim_levels_in_group to trim combinations present in the data being tabulated.")
##     myfun = function(df, spl, vals = NULL, labels = NULL, trim = FALSE) {
##         ret = .apply_split_inner(spl, df, vals = vals, labels = labels, trim = trim)

##         outval <- unique(as.character(df[[outervar]]))
##         oldlevs <- spl_child_order(spl)
##         newlevs <- oldlevs[oldlevs %in% map[as.character(map[[outervar]]) == outval, innervar, drop =TRUE]]

##         keep <- ret$values %in% newlevs
##         ret <- lapply(ret, function(x) x[keep])
##         ret$datasplit <- lapply(ret$datasplit, function(df) {
##             df[[innervar]] <- factor(as.character(df[[innervar]]), levels = newlevs)
##             df
##         })
##         ret$labels <- as.character(ret$labels) # TODO
##         ret
##     }
##     myfun
## }


.add_combo_part_info = function(part, df, valuename, levels, label, extras, first = TRUE) {

    ##    value = LevelComboSplitValue(levels, extras, comboname = valuename, label = label)
    value = LevelComboSplitValue(valuename, extras, combolevels = levels, label = label)
    newdat = setNames(list(df), valuename)
    newval = setNames(list(value), valuename)
    newextra = setNames(list(extras), valuename)
    if(first) {
        part$datasplit = c(newdat, part$datasplit)
        part$values = c(newval, part$values)
        part$labels = c(setNames(label, valuename), part$labels)
        part$extras = c(newextra, part$extras)
    } else {
        part$datasplit = c(part$datasplit, newdat)
        part$values = c(part$values, newval)
        part$labels = c(part$labels, setNames(label, valuename))
        part$extras = c(part$extras, newextra)
    }
    ## not needed even in custom split function case.
    ##   part = .fixupvals(part)
    part
}

#' Add an virtual 'overall' level to split
#'
#' @inheritParams lyt_args
#' @inheritParams sf_args
#' @param valname character(1). 'Value' to be assigned to the implicit all-observations split level. Defaults to \code{"Overall"}
#' @param first logical(1). Should the implicit level appear first (\code{TRUE}) or last \code{FALSE}. Defaults to \code{TRUE}.
#'
#' @return a closure suitable for use as a splitting function (\code{splfun}) when creating a table layout
#'
#' @export
#'
#' @examples
#'
#' l <- basic_table() %>%
#'    split_cols_by("ARM", split_fun = add_overall_level("All Patients", first = FALSE)) %>%
#'    analyze("AGE")
#'
#' build_table(l, DM)
#'
#'
#' l <- basic_table() %>%
#'    split_cols_by("ARM") %>%
#'    split_rows_by("RACE", split_fun = add_overall_level("All Ethnicities")) %>%
#'    summarize_row_groups(label_fstr = "%s (n)") %>%
#'    analyze("AGE")
#'
#' l
#'
#' build_table(l, DM)
#'
add_overall_level = function(valname = "Overall", label = valname, extra_args = list(), first = TRUE, trim = FALSE) {
    combodf <- data.frame(valname = valname,
                          label = label,
                          levelcombo = I(list(select_all_levels)),
                          exargs = I(list(extra_args)),
                          stringsAsFactors = FALSE)
    add_combo_levels(combodf,
                     trim = trim, first = first)
    }

setClass("AllLevelsSentinel", contains = "character")
#' @export
#' @rdname add_combo_levels
select_all_levels = new("AllLevelsSentinel")

#' Add Combination Levels to split
#' @inheritParams sf_args
#' @inherit add_overall_level return
#' @param combosdf data.frame/tbl_df. Columns valname, label, levelcombo, exargs. Of which levelcombo and exargs are list columns. Passing the \code{select_all_levels} object as a value in the \code{comblevels} column indicates that an overall/all-observations level should be created.
#' @param keep_levels character or NULL. If non-NULL, the levels to retain across both combination and individual levels.
#' @note Analysis or summary functions for which the order matters should never be used within the tabulation framework.
#' @export
#' @examples
#' library(tibble)
#' combodf <- tribble(
#'     ~valname, ~label, ~levelcombo, ~exargs,
#'     "A_B", "Arms A+B", c("A: Drug X", "B: Placebo"), list(),
#'     "A_C", "Arms A+C", c("A: Drug X", "C: Combination"), list())
#'
#' l <- basic_table() %>%
#'     split_cols_by("ARM", split_fun = add_combo_levels(combodf)) %>%
#'     add_colcounts() %>%
#'     analyze("AGE")
#'
#' build_table(l, DM)
#'
#' la <- basic_table() %>%
#'     split_cols_by("ARM", split_fun = add_combo_levels(combodf, keep_levels = c("A_B", "A_C"))) %>%
#'     add_colcounts() %>%
#'     analyze("AGE")
#'
#' build_table(la, DM)
#'
#' smallerDM <- droplevels(subset(DM, SEX %in% c("M", "F") &
#'                         grepl("^(A|B)", ARM)))
#' l2 <- basic_table() %>%
#'     split_cols_by("ARM", split_fun = add_combo_levels(combodf[1,])) %>%
#'     split_cols_by("SEX", split_fun = add_overall_level("SEX_ALL", "All Genders")) %>%
#'     add_colcounts() %>%
#'     analyze("AGE")
#'
#' l3 <-  basic_table() %>%
#'     split_cols_by("ARM", split_fun = add_combo_levels(combodf)) %>%
#'     add_colcounts() %>%
#'     split_rows_by("SEX", split_fun = add_overall_level("SEX_ALL", "All Genders")) %>%
#'     summarize_row_groups() %>%
#'     analyze("AGE")
#'
#' build_table(l3, smallerDM)
add_combo_levels = function(combosdf, trim = FALSE, first = FALSE, keep_levels = NULL) {
    myfun = function(df, spl, vals = NULL, labels = NULL, ...) {
        ret = .apply_split_inner(spl, df, vals = vals, labels = labels, trim = trim)
        for(i in 1:nrow(combosdf)) {
            lcombo = combosdf[i, "levelcombo", drop = TRUE][[1]]
            spld = spl_payload(spl)
            if(is(lcombo, "AllLevelsSentinel"))
                subdf = df
            else if (is(spl, "VarLevelSplit")) {
                 subdf = df[df[[spld]] %in% lcombo,]
            } else {
                stopifnot(all(lcombo %in% c(ret$labels, ret$vals)))
                subdf = do.call(rbind, ret$datasplit[names(ret$datasplit) %in% lcombo |
                                                     ret$vals %in% lcombo])
            }
            ret = .add_combo_part_info(ret, subdf,
                                       combosdf[i, "valname", drop=TRUE],
                                       lcombo,
                                       combosdf[i,"label", drop = TRUE],
                                       combosdf[i, "exargs", drop = TRUE][[1]],
                                       first)
        }
        if(!is.null(keep_levels)) {
            keep_inds <- value_names(ret$values) %in% keep_levels
            ret <- lapply(ret, function(x) x[keep_inds])
        }

        ret
    }
  myfun
}


#' Trim Levels to map
#'
#' This split function constructor creatse a split function which trims
#' levels of a variable to reflect restrictions on the possible
#' combinations of two or more variables which are split by
#' (along the same axis) within a layout.
#'
#' @details When splitting occurs, the map is subset to the values of all previously
#' performed splits. The levels of the variable being split are then pruned to only
#' those still present within this subset of the map representing the current hierarchical
#' splitting context.
#'
#' Splitting is then performed via the \code{\link{keep_split_levels}} split function.
#'
#' Each resulting element of the partition is then further trimmed by pruning values of
#' any remaining variables specified in the map to those values allowed under the combination
#' of the previous and current split.
#' @param map data.frame. A data.frame defining allowed combinations of variables. Any
#' combination at the level of this split not present in the map will be removed from the
#' data, both for the variable being split and those present in the data but not associated
#' with this split or any parents of it.
#' @return a fun
#' @export
#' @examples
#'  map <- data.frame(
#'        LBCAT = c("CHEMISTRY", "CHEMISTRY", "CHEMISTRY", "IMMUNOLOGY"),
#'        PARAMCD = c("ALT", "CRP", "CRP", "IGA"),
#'        ANRIND = c("LOW", "LOW", "HIGH", "HIGH"),
#'        stringsAsFactors = FALSE
#'    )
#'
#'    lyt <- basic_table() %>%
#'        split_rows_by("LBCAT") %>%
#'        split_rows_by("PARAMCD", split_fun = trim_levels_to_map(map = map)) %>%
#'        analyze("ANRIND")
#'    tbl1 <- build_table(lyt, ex_adlb)
trim_levels_to_map <- function(map = NULL) {

    if (is.null(map) || any(sapply(map, class) != "character"))
        stop("No map dataframe was provided or not all of the columns are of type character.")

    myfun <- function(df, spl, vals = NULL, labels = NULL, trim = FALSE, .prev_splvals) {

        allvars <- colnames(map)
        splvar <- spl_payload(spl)

        allvmatches <- match(.prev_splvals, allvars)
        outvars <- allvars[na.omit(allvmatches)]
        ## invars are variables present in data, but not in
        ## previous or current splits
        invars <- intersect(setdiff(allvars, c(outvars, splvar)),
                            names(df))
        ## allvarord <- c(na.omit(allvmatches), ## appear in prior splits
        ##                which(allvars == splvar), ## this split
        ##                allvars[-1*na.omit(allvmatches)]) ## "outvars"

        ## allvars <- allvars[allvarord]
        ## outvars <- allvars[-(which(allvars == splvar):length(allvars))]
        if(length(outvars) > 0) {
            indfilters <- vapply(outvars, function(ivar) {
                obsval <- .prev_splvals$value[match(ivar, .prev_splvals$split)]
                sprintf("%s == '%s'", ivar, obsval)
            }, "")

            allfilters <- paste(indfilters, collapse = " & ")
            map <- map[eval(parse(text = allfilters), envir = map),]
        }
        map_splvarpos <- which(names(map) == splvar)
        nondup <- !duplicated(map[[splvar]])
        ksl_fun <- keep_split_levels(only = map[[splvar]][nondup], reorder = TRUE)
        ret <- ksl_fun(df, spl, vals, labels, trim = trim)

  ##      browser()
        if(length(ret$datasplit) == 0) {
            msg <- paste(sprintf("%s[%s]", .prev_splvals$split, .prev_splvals$value),
                         collapse = "->")
            stop("map does not allow any values present in data for split variable ", splvar, " under the following parent splits:\n\t", msg)
        }

        ## keep non-split (inner) variables levels
        ret$datasplit <- lapply(ret$values, function(splvar_lev) {
            df3 <- ret$datasplit[[splvar_lev]]
            curmap <- map[map[[map_splvarpos]] == splvar_lev,]
            ## loop through inner variables
            for (iv in invars) { ##setdiff(colnames(map), splvar)) {
                iv_lev <- df3[[iv]]
                levkeep <- as.character(unique(curmap[[iv]])) ## na.omit(unique(map[map[, splvar] == splvar_lev, iv])))
                if (is.factor(iv_lev) && !all(levkeep %in% levels(iv_lev)))
                    stop("Attempted to keep invalid factor level(s) in split ", setdiff(levkeep, levels(iv_lev)))

                df3 <- df3[iv_lev %in% levkeep, , drop = FALSE]

                if (is.factor(iv_lev))
                    df3[[iv]] <- factor(as.character(df3[[iv]]), levels = levkeep)
            }

            df3
        })
        names(ret$datasplit) <- ret$values
        ret
    }

    myfun
}
