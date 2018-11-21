#!/bin/bash

#SBATCH --job-name=10x
#SBATCH --partition=256GB
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=40:00:30
#SBATCH --output=job_log.%j.out
#SBATCH --error=job_log.%j.err
#SBATCH --mail-user=
#SBATCH --mail-type=ALL

# utilities
CELLRANGER=

# 10 parameters
GENOME_REFERENCE_DIR=
SEQ_DIR=
NUMBER_CELLS_EXPECTED=10000

# scripts
SCRIPTS_DIR0=
SUMMARIZE_BARCODES_FROM_10X_ALIGNMENT=${SCRIPTS_DIR0}/summarize_barcodes_from_10x_alignment.py
DUMP_UMIS=${SCRIPTS_DIR0}/dump_umis.py

# modules
module add python/3.4.x-anaconda
source activate py36
module load R


# begin
export libraries="
BL18
BL19
"
echo $SLURM_CPUS_ON_NODE
RESULTS_DIR=$PWD

for library_name in $libraries; do
    echo $library_name

    LIBRARY_DIR=${library_name}_10x
    # rm -rf $LIBRARY_DIR

    $CELLRANGER count \
        --id=$LIBRARY_DIR \
        --fastqs=$SEQ_DIR \
        --sample=$library_name \
        --transcriptome $GENOME_REFERENCE_DIR \
        --expect-cells $NUMBER_CELLS_EXPECTED \
        --localcores=$SLURM_CPUS_ON_NODE

    $SUMMARIZE_BARCODES_FROM_10X_ALIGNMENT \
        -i ${LIBRARY_DIR}/outs/possorted_genome_bam.bam \
        -o ${LIBRARY_DIR}/outs/possorted_genome_bam.bam_umi_counts.txt

    $DUMP_UMIS \
        ${LIBRARY_DIR}/outs/filtered_gene_bc_matrices_h5.h5 \
        > ${LIBRARY_DIR}/outs/filtered_gene_bc_matrices_h5_umis.txt
done
