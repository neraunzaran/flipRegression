#' @importFrom flipTransformations RemoveMissingLevelsFromFactors
#' @importFrom flipData DataFormula
#' @importFrom stats update.formula
computeInteractionCrosstab <- function(result, interaction.name, interaction.label,
                                       formula.with.interaction, importance,
                                       importance.absolute, internal.loop, ...)
{
    net.coef <- summary(result$original)$coef[,1]
    missing <- result$missing
    if (missing == "Dummy variable adjustment")
        net.coef <- net.coef[!grepDummyVars(names(net.coef))]
    correction <- result$correction
    if (internal.loop)
        correction <- "None"
    num.var <- length(net.coef)
    split.labels <- levels(result$estimation.data[,interaction.name])
    num.split <- length(split.labels)
    split.names <- paste0(interaction.name, split.labels)
    split.size <- table(result$estimation.data[,interaction.name])
    var.names <- CleanBackticks(names(net.coef))
    var.labels <- if (result$show.labels) Labels(result$model, var.names)
                  else                    var.names
    names(net.coef) <- var.labels
    names(split.size) <- split.labels

    weights <- result$weights[result$subset]
    original.r2 <- if (result$type == "Linear" & is.null(weights)) summary(result$original)$r.square
                   else 1 - deviance(result$original)/nullDeviance(result)

    res <- list(label = interaction.label, split.size = c(split.size, NET=sum(split.size)),
                pvalue = NA, original.r2 = original.r2, full.r2 = NA, fit = NULL,
                net.coef = net.coef, importance = importance)

    if (is.null(importance))
    {
        fit2 <- FitRegression(formula.with.interaction, result$estimation.data, weights,
                              result$type, result$robust.se, result$outlier.prop.to.remove, ...)
        atest <- ifelse (result$type %in% c("Linear", "Quasi-Poisson"), "F", "Chisq")
        if (!is.null(weights))
        {
            .design <- fit2$design
            assign(".design", .design, envir=.GlobalEnv)
        }
        atmp <- anova(result$original, fit2$original, test=atest)
        res$anova.output <- atmp
        res$full.r2 <- ifelse (result$type == "Linear" & is.null(weights), summary(fit2$original)$r.square,
                                                        1 - deviance(fit2$original)/nullDeviance(result))
        if (!is.null(weights))
            remove(".design", envir=.GlobalEnv)

        if (!internal.loop)
        {
            res$fit <- fit2$original
            res$anova.test <- switch(atest, F="F-test", Chisq="Chi-square test")
            res$pvalue <- if(is.null(weights)) atmp$Pr[2]
                          else atmp$p

        } else
        {
            res$anova.fstat <- atmp[2,5]
            res$anova.dev <- atmp[2,4]
            res$anova.df1 <- -diff(as.numeric(atmp[,1]))
            res$anova.df2 <- atmp[2,1]
        }
    }

    if (!is.null(importance))
    {
        importance.scores <- result$importance$importance
        var.names <- result$importance.names
        var.labels <- result$importance.labels
        res$net.coef <- importance.scores
        num.var <- length(importance.scores)
    }
    coef.sign <- matrix(0, num.var, num.split)
    bb <- matrix(NA, num.var, num.split, dimnames=list(var.names, NULL))
    bc <- matrix(NA, num.var, num.split, dimnames=list(var.names, NULL))
    ss <- matrix(NA, num.var, num.split, dimnames=list(var.names, NULL))
    sc <- matrix(NA, num.var, num.split, dimnames=list(var.names, NULL))

    if (!is.null(importance))
    {
        signs <- if (importance.absolute) 1 else NA
        for (j in 1:num.split)
        {
            is.split <- which(result$estimation.data[,interaction.name] == split.labels[j])
            if (length(unique(result$estimation.data[is.split,1])) < 2 ||
                length(unique(result$estimation.data[-is.split,1])) < 2)
                next
            estimation.data   <- RemoveMissingLevelsFromFactors(result$estimation.data[is.split,])
            estimation.data.C <- RemoveMissingLevelsFromFactors(result$estimation.data[-is.split,])
            # Check data suitable and throw warning if it isn't and skip the current computation
            if (importance %in% c("Shapley Regression", "Relative Importance Analysis"))
            {
                data.invalid <- tryCatch(validateDataForRIA(result$formula, estimation.data,
                                                            result$outcome.name, result$show.labels,
                                                            output = importance, group.name = split.labels[j]),
                                         error = function(e) warning(e$message))
                # Skip the attempt at RIA/Shapley if error detected here
                if (!is.null(data.invalid))
                    next
            }
            tmp.ri <- try(estimateImportance(result$formula, estimation.data,
                                             weights[is.split], result$type, signs, NA, NA, result$robust.se,
                                             result$outlier.prop.to.remove, FALSE, correction, importance),
                          silent = TRUE)
            tmpC.ri <- try(estimateImportance(result$formula, estimation.data.C,
                                              weights[-is.split], result$type, signs, NA, NA, result$robust.se,
                                              result$outlier.prop.to.remove, FALSE, correction, importance),
                           silent = TRUE)
            if (!inherits(tmp.ri, "try-error") && !inherits(tmpC.ri, "try-error"))
            {
                tmp.sign <- sign(tmp.ri$importance)
                tmpC.sign <- sign(tmpC.ri$importance)
                bb[names(tmp.ri$raw.importance),j] <- tmp.ri$raw.importance * tmp.sign
                ss[names(tmp.ri$raw.importance),j] <- tmp.ri$standard.errors
                bc[names(tmpC.ri$raw.importance),j] <- tmpC.ri$raw.importance * tmpC.sign
                sc[names(tmpC.ri$raw.importance),j] <- tmpC.ri$standard.errors
            }
        }
    } else
    {
        base.error.msg <- paste0("Cannot perform regression split by interaction term. Settings require fitting ",
                                 "the model for all sub-groups determined by the interaction variable ",
                                 interaction.name, ".")
        ## in case original formula has ., need to remove interaction
        ## term from formula
        formula2 <- update.formula(result$terms, paste0("~.-", interaction.name))
        for (j in 1:num.split)
        {
            is.split <- which(result$estimation.data[,interaction.name] == split.labels[j])
            if (length(unique(result$estimation.data[is.split,1])) < 2 ||
                length(unique(result$estimation.data[-is.split,1])) < 2)
                next

            tmp.fit <- try(FitRegression(formula2, result$estimation.data[is.split,],
                                         weights[is.split], result$type, result$robust.se,
                                         result$outlier.prop.to.remove),
                           silent = TRUE)
            if (inherits(tmp.fit, "try-error"))
                stop(base.error.msg, " The model cannot be computed for the sub-group when ", interaction.name,
                     " takes the value ", split.labels[j], ". ", attr(tmp.fit, "condition")$message, "\n")

            tmpC.fit <- try(FitRegression(formula2, result$estimation.data[-is.split,],
                                          weights[-is.split], result$type, result$robust.se,
                                          result$outlier.prop.to.remove),
                            silent = TRUE)
            if (inherits(tmpC.fit, "try-error"))
                stop(base.error.msg, " The model cannot be computed for the sub-group when ", interaction.name,
                     " doesn't take the value ", split.labels[j], ". ", attr(tmpC.fit, "condition")$message, "\n")
            tmp.coefs <- tidySummary(summary(tmp.fit$original), tmp.fit$original, result)$coef
            tmpC.coefs <- tidySummary(summary(tmpC.fit$original), tmpC.fit$original, result)$coef

            if (result$missing == "Dummy variable adjustment")
            {
                tmp.coefs <- tmp.coefs[!grepDummyVars(row.names(tmp.coefs)), ]
                tmpC.coefs <- tmpC.coefs[!grepDummyVars(row.names(tmpC.coefs)), ]
            }

            if (!inherits(tmp.fit, "try-error") && !inherits(tmpC.fit, "try-error"))
            {
                bb[rownames(tmp.coefs),j] <- tmp.coefs[,1]
                ss[rownames(tmp.coefs),j] <- tmp.coefs[,2]
                bc[rownames(tmpC.coefs),j] <- tmpC.coefs[,1]
                sc[rownames(tmpC.coefs),j] <- tmpC.coefs[,2]
            }
        }
    }
    if (internal.loop)
    {
        res$bb <- bb
        res$ss <- ss
        res$bc <- bc
        res$sc <- sc
        return(res)
    }

    coef.sign <- compareCoef(bb, bc, ss^2, sc^2, split.size, correction, importance)
    res$coef.pvalues <- coef.sign$pvalues
    res$coef.tstat <- coef.sign$tstat
    if (!is.null(importance))
        res$coef.pFDR <- coef.sign$pFDR

    # Report normalised relative importance scores but use raw scores for p-values
    if (!is.null(importance))
        bb <- apply(bb, 2, function(x){x/sum(abs(x), na.rm=T)*100})
    # Catch case when single predictor used and bb reduces to vector
    if (length(var.labels) == 1)
        bb <- matrix(bb, nrow = 1)
    combined.coefs <- cbind(bb, res$net.coef)
    colnames(combined.coefs) <- c(split.labels, "NET")
    rownames(combined.coefs) <- var.labels
    res$coefficients <- combined.coefs
    return(res)
}

#' @importFrom stats pt p.adjust
compareCoef <- function(bb, bc, ss, sc, nn, correction, importance)
{
    if (any(dim(bb) != dim(ss)))
        stop("Dimensions of bb and ss must be the same\n")
    if (length(nn) != ncol(bb))
        stop("Length of nn should match columns in bb\n")

    nc <- sum(nn, na.rm=T) - nn
    pp <- matrix(NA, nrow=nrow(bb), ncol=ncol(bb))
    tt <- matrix(NA, nrow=nrow(bb), ncol=ncol(bb))
    for (j in 1:ncol(bb))
    {
        vv <- (ss[,j] + sc[,j])^2/(ss[,j]^2/(nn[j]-1) + sc[,j]^2/(nc[j]-1))
        tt[,j] <- (bb[,j] - bc[,j])/sqrt(ss[,j] + sc[,j])

        for (i in 1:nrow(bb))
            pp[i,j] <- 2 * pt(abs(tt[i,j]), vv[i], lower.tail=F)
    }

    res <- list(tstat = tt)
    if (!is.null(importance))
        res$pFDR <- matrix(pvalAdjust(pp, "fdr"), nrow=nrow(bb), ncol=ncol(bb))
    res$pvalues <- matrix(pvalAdjust(pp, correction), nrow=nrow(bb), ncol=ncol(bb))
    return (res)
}
