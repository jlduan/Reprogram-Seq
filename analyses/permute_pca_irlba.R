#!/usr/bin/env Rscript
library(tidyverse)
library(irlba)


# load data --------------------------------------------------------------------


# drop-seq data
data_directory <- "../data/drop-seq/"
# 10x data
data_directory <- "../data/10x/"


expr_readcount_norm_log_corrected_scaled <- readRDS(file.path(
    data_directory,
    "expr_readcount_norm_log_corrected_scaled.rds"
))
object.size(expr_readcount_norm_log_corrected_scaled)


# inspect
pc_genes_var <- apply(expr_readcount_norm_log_corrected_scaled, 1, var)
genes_use <- rownames(expr_readcount_norm_log_corrected_scaled)[pc_genes_var > 0]
length(genes_use)


# compute the first a few principal components based on permuated matrices -----


proportion_of_transcripts <- 0.1
n_use <- 40
num_replicates <- 500


dir.create(file.path(data_directory, "permutations"), showWarnings = FALSE)


for (i in seq_len(num_replicates)) {
    message("computing replicate ", i, sep = "")


    data_use <- expr_readcount_norm_log_corrected_scaled
    transcripts_to_permute <-
        sample(
            rownames(data_use),
            nrow(data_use) * proportion_of_transcripts
        )

    data_use[transcripts_to_permute, ] <-
        t(apply(
            data_use[transcripts_to_permute, ],
            1,
            sample
        ))

    prcomp_irlba_out <-
        prcomp_irlba(t(data_use),
            n = n_use,
            center = FALSE,
            scale. = FALSE
        )

    if (FALSE) {
        saveRDS(data_use,
            file = file.path(
                data_directory, "permutations",
                paste0(
                    "prcomp_irlba_input_",
                    "proportion",
                    proportion_of_transcripts,
                    "_n",
                    n_use,
                    "_replicate",
                    i,
                    ".rds"
                )
            )
        )
    }

    saveRDS(prcomp_irlba_out,
        file = file.path(
            data_directory, "permutations",
            paste0(
                "prcomp_irlba_out_",
                "proportion",
                proportion_of_transcripts,
                "_n",
                n_use,
                "_replicate",
                i,
                ".rds"
            )
        )
    )
}


# compute PCs on orig matrix ---------------------------------------------------


prcomp_irlba_out <-
    prcomp_irlba(t(expr_readcount_norm_log_corrected_scaled),
        n = n_use,
        center = FALSE,
        scale. = FALSE
    )


pc_sdev_irlba <- prcomp_irlba_out$sdev
pc_eigenvalues_irlba <- pc_sdev_irlba^2
pc_var_explained_irlba <- pc_sdev_irlba^2 / sum(pc_sdev_irlba^2)


# summarize permutations --------------------------------------------------------


summarize_permutations <- function(permutation_files_dir,
                                   permutation_files_prefix,
                                   num_replicates) {
    pb <- txtProgressBar(min = 0, max = num_replicates, style = 3)

    pc_sdev_perm <-
        lapply(seq_len(num_replicates), function(i) {
            permutation_file <-
                file.path(
                    permutation_files_dir,
                    paste0(
                        permutation_files_prefix,
                        i,
                        ".rds"
                    )
                )


            permutation_prcomp_irlba_out <-
                readRDS(file = permutation_file)

            Sys.sleep(0.1)
            setTxtProgressBar(pb, i)
            permutation_prcomp_irlba_out$sdev
        })

    pc_sdev_perm <- do.call(rbind.data.frame, pc_sdev_perm)
    close(pb)
    colnames(pc_sdev_perm) <- paste("PC", 1:ncol(pc_sdev_perm), sep = "")

    return(pc_sdev_perm)
}


permutation_files_dir <- file.path(data_directory, "permutations")
permutation_files_prefix <- paste0(
    "prcomp_irlba_out_",
    "proportion",
    proportion_of_transcripts,
    "_n",
    n_use,
    "_replicate"
)


summarized_permutations <-
    summarize_permutations(
        permutation_files_dir = permutation_files_dir,
        permutation_files_prefix = permutation_files_prefix,
        num_replicates = num_replicates
    )


# var explained in perm
pc_var_explained_perm <-
    summarized_permutations^2 / rowSums(summarized_permutations^2)


# var explained, orignial
pc_var_explained <- pc_var_explained_irlba


# determine num of pcs
pc_var_explained >= colMeans(pc_var_explained_perm)


# plot -------------------------------------------------------------------------


data.frame(
    orig = pc_var_explained,
    perm = colMeans(pc_var_explained_perm)
) %>%
    mutate(x = rownames(.)) %>%
    gather(
        key = "category",
        value = "var_exp",
        -x
    ) %>%
    mutate(category = factor(category,
        levels = c("orig", "perm")
    )) %>%
    mutate(x = factor(x,
        levels = unique(x)
    )) %>%
    ggplot(aes(
        x = x,
        y = var_exp,
        group = category,
        color = category
    )) +
    geom_line() +
    geom_point() +
    scale_x_discrete(label = seq_len(n_use)) +
    labs(
        x = "Principal components",
        y = "Variance explained",
        color = NULL
    ) +
    # theme(axis.text.x = element_text(angle = 90, hjust = 0)) +
    geom_hline(
        yintercept = pc_var_explained[
            which(!pc_var_explained >= colMeans(pc_var_explained_perm))[1] - 1
        ],
        linetype = "dashed",
        color = "steelblue"
    )
