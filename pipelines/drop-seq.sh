#!/bin/bash

#SBATCH --job-name=drop-seq.v3
#SBATCH --partition=super
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=02:00:30
#SBATCH --output=job_log.%j.out
#SBATCH --error=job_log.%j.err
#SBATCH --mail-user=
#SBATCH --mail-type=ALL

# dropseq tools
DROPSEQ_TOOLS_DIR=

# utilities
SAMTOOLS=
FEATURE_COUNTS=
PICARD=

# genome parameters
STAR=
STAR_REFERENCE_DIR=
STAR_REFERENCE_FASTA=
STAR_REFERENCE_FASTA_FAI=
REFERENCE_ANNOTATION_GTF=

# scripts
SCRIPTS_DIR=
SCRIPTS_DIR2=
evaluate_STAMPs_by_cumulative_reads=${SCRIPTS_DIR2}/evaluate_STAMPs_by_cumulative_reads_10x.py
get_inflection_point=${SCRIPTS_DIR2}/get_inflection_point_umi.R
compare_cell_barcodes=${SCRIPTS_DIR2}/compare_cell_barcodes.py
clean_cell_barcodes=${SCRIPTS_DIR2}/clean_cell_barcodes.py
split_sc_bam=${SCRIPTS_DIR2}/split_sc_bam.py
add_strand_tag=${SCRIPTS_DIR2}/add_strand_tag.py

# pipeline parameters
SEQ_DIR=
MIN_UMIS_PER_CELL=25
PRIMER_SEQ=AAGCAGTGGTATCAACGCAGAGTAC
INFLECTION_END_POINT=3000

# modules
module load java
module add python/3.4.x-anaconda
source activate py36
module load R

# begin
export libraries="
JD149A
JD149B
JD150A
JD150B
"

RESULTS_DIR=$PWD
for library_name in $libraries; do
    echo $library_name

    LIBRARY_DIR=${library_name}_dropseq
    rm -rf $LIBRARY_DIR
    mkdir $LIBRARY_DIR

    cd $LIBRARY_DIR

    RAW_READS_DIR=raw_reads
    ALIGNMENT_DIR=alignments
    TMPDIR=tmpdir
    REPORTS_DIR=reports
    SPLITTED_BAM_DIR=${ALIGNMENT_DIR}/splitted
    EXPR_DIR=matrices

    rm -rf $RAW_READS_DIR $REPORTS_DIR $ALIGNMENT_DIR $TMPDIR $EXPR_DIR
    mkdir $RAW_READS_DIR $REPORTS_DIR $ALIGNMENT_DIR $TMPDIR $EXPR_DIR

    # merge reads
    for read in {1,2}; do
        cat $SEQ_DIR/${library_name}_L001_R${read}_001.fastq.gz \
            $SEQ_DIR/${library_name}_L002_R${read}_001.fastq.gz \
            $SEQ_DIR/${library_name}_L003_R${read}_001.fastq.gz \
            $SEQ_DIR/${library_name}_L004_R${read}_001.fastq.gz \
            > ${RAW_READS_DIR}/${library_name}_combined_R${read}.fastq.gz
    done

    # make BAM file
    java -Xmx120g -jar $PICARD FastqToSam \
        SAMPLE_NAME=$library_name \
        READ_GROUP_NAME=$library_name \
        FASTQ=${RAW_READS_DIR}/${library_name}_combined_R1.fastq.gz \
        FASTQ2=${RAW_READS_DIR}/${library_name}_combined_R2.fastq.gz \
        OUTPUT=${RAW_READS_DIR}/${library_name}_unaligned.bam \
        SORT_ORDER=queryname

    # tag cell barcodes
    ${DROPSEQ_TOOLS_DIR}/TagBamWithReadSequenceExtended \
        INPUT=${RAW_READS_DIR}/${library_name}_unaligned.bam \
        OUTPUT=${TMPDIR}/unaligned_cell_barcoded.bam \
        SUMMARY=${REPORTS_DIR}/unaligned_cell_barcoded.bam_summary.txt \
        BASE_RANGE=1-12 \
        BASE_QUALITY=10 \
        BARCODED_READ=1 \
        DISCARD_READ=False \
        TAG_NAME=XC \
        NUM_BASES_BELOW_QUALITY=1

    # tag UMIs
    ${DROPSEQ_TOOLS_DIR}/TagBamWithReadSequenceExtended \
        INPUT=${TMPDIR}/unaligned_cell_barcoded.bam \
        OUTPUT=${TMPDIR}/unaligned_cell_molecule_barcoded.bam \
        SUMMARY=${REPORTS_DIR}/unaligned_cell_molecule_barcoded.bam_summary.txt \
        BASE_RANGE=13-20 \
        BASE_QUALITY=10 \
        BARCODED_READ=1 \
        DISCARD_READ=True \
        TAG_NAME=XM \
        NUM_BASES_BELOW_QUALITY=1

    # filter low quality cell barcodes and UMIs
    ${DROPSEQ_TOOLS_DIR}/FilterBAM \
        TAG_REJECT=XQ \
        INPUT=${TMPDIR}/unaligned_cell_molecule_barcoded.bam \
        OUTPUT=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered.bam

    # trim 5' ends
    ${DROPSEQ_TOOLS_DIR}/TrimStartingSequence \
        INPUT=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered.bam \
        OUTPUT=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed.bam \
        OUTPUT_SUMMARY=${REPORTS_DIR}/unaligned_adapter_trimming_report.txt \
        SEQUENCE=AAGCAGTGGTATCAACGCAGAGTGAATGGG \
        MISMATCHES=0 \
        NUM_BASES=5

    # trim ployA tails
    ${DROPSEQ_TOOLS_DIR}/PolyATrimmer \
        INPUT=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed.bam \
        OUTPUT=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed_polyA_filtered.bam \
        OUTPUT_SUMMARY=${REPORTS_DIR}/unaligned_polyA_trimming_report.txt \
        MISMATCHES=0 \
        NUM_BASES=6

    # re-generate fastq for alignment
    java -Xmx120g -jar $PICARD SamToFastq \
        INPUT=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed_polyA_filtered.bam \
        FASTQ=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed_polyA_filtered.fastq

    # align
    mkdir -p ${ALIGNMENT_DIR}/star
    $STAR \
        --runMode alignReads \
        --runThreadN $SLURM_CPUS_ON_NODE \
        --genomeDir  $STAR_REFERENCE_DIR \
        --readFilesIn ${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed_polyA_filtered.fastq \
        --outFileNamePrefix ${ALIGNMENT_DIR}/star/ \
        --outSAMtype BAM SortedByCoordinate
        # --outSAMattrRGline ID:${libraries} SM:${libraries} LB:${libraries} PL:ILLUMINA

    # tag aligned reads with cell barcodes and UMIs
    prefix=aligned_tagged
    tagged_mapped_sorted_bam=${prefix}.bam
    java -Xmx120g -jar $PICARD MergeBamAlignment \
        ALIGNED_BAM=${ALIGNMENT_DIR}/star/Aligned.sortedByCoord.out.bam \
        UNMAPPED_BAM=${TMPDIR}/unaligned_cell_molecule_barcoded_filtered_trimmed_polyA_filtered.bam \
        OUTPUT=${ALIGNMENT_DIR}/${tagged_mapped_sorted_bam} \
        REFERENCE_SEQUENCE=$STAR_REFERENCE_FASTA \
        INCLUDE_SECONDARY_ALIGNMENTS=false \
        PAIRED_RUN=false
    $SAMTOOLS index ${ALIGNMENT_DIR}/${prefix}.bam

    # get histogram, tagged
    $DROPSEQ_TOOLS_DIR/BAMTagHistogram -m 4g \
        I=${ALIGNMENT_DIR}/${tagged_mapped_sorted_bam} \
        O=${REPORTS_DIR}/${tagged_mapped_sorted_bam}.barcode_counts \
        TAG=XC

    # remove low quality mapping
    quality_filtered_bam=${prefix}_q10.bam
    $SAMTOOLS view \
        -bq10 \
        -o ${ALIGNMENT_DIR}/${quality_filtered_bam} \
        ${ALIGNMENT_DIR}/${tagged_mapped_sorted_bam}

    # get histogram, after mapping quality filtering
    $DROPSEQ_TOOLS_DIR/BAMTagHistogram -m 4g \
        I=${ALIGNMENT_DIR}/${quality_filtered_bam} \
        O=${REPORTS_DIR}/${quality_filtered_bam}.barcode_counts \
        TAG=XC

    $evaluate_STAMPs_by_cumulative_reads \
        ${ALIGNMENT_DIR}/${quality_filtered_bam}
    mv ${ALIGNMENT_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_* ${REPORTS_DIR}

    # get inflection point
    $get_inflection_point \
        ${REPORTS_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_info.txt \
        $INFLECTION_END_POINT \
        ${REPORTS_DIR}/${quality_filtered_bam}_inflection_point.txt \
        ${REPORTS_DIR}/Rplot_${quality_filtered_bam}_inflection_point.pdf

    # compare cell barcodes
    est_num_cells=`cat ${REPORTS_DIR}/${quality_filtered_bam}_inflection_point.txt`
    sort -k7nr ${REPORTS_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_info.txt \
        | grep -v "#" > ${REPORTS_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_info_umi_sorted.txt

    $compare_cell_barcodes \
        ${REPORTS_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_info_umi_sorted.txt \
        `expr $est_num_cells \* 2` \
        $MIN_UMIS_PER_CELL > ${REPORTS_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_barcodes_comparisons.txt

    # merge cell barcodes
    $clean_cell_barcodes \
        ${ALIGNMENT_DIR}/${quality_filtered_bam} \
        ${REPORTS_DIR}/${quality_filtered_bam}_mapQ10_STAMPs_barcodes_comparisons.txt

    # re-label reads using featureCounts
    gene_tagged_bam=${prefix}_q10_cleaned_featureCounts.bam
    mkdir -p ${EXPR_DIR}/combined
    $FEATURE_COUNTS \
        -O \
        -a $REFERENCE_ANNOTATION_GTF \
        -g gene_id \
        -o ${EXPR_DIR}/combined/${library_name}_q10_cleaned_gene_id.featureCounts \
        -R BAM ${ALIGNMENT_DIR}/${prefix}_q10_cleaned.bam

    $SAMTOOLS sort \
        -o ${ALIGNMENT_DIR}/${gene_tagged_bam} \
        ${EXPR_DIR}/combined/${prefix}_q10_cleaned.bam.featureCounts.bam
    $SAMTOOLS index ${ALIGNMENT_DIR}/${gene_tagged_bam}
    rm ${EXPR_DIR}/combined/${prefix}_q10_cleaned.bam.featureCounts.bam

    # add back GS tag
    $add_strand_tag ${ALIGNMENT_DIR}/${gene_tagged_bam} \
        $REFERENCE_ANNOTATION_GTF
    mv ${ALIGNMENT_DIR}/${gene_tagged_bam%.bam}_modified.bam \
        ${ALIGNMENT_DIR}/${gene_tagged_bam}

    # fix bead synthesis error
    bead_synthesis_fixed_bam=${prefix}_q10_cleaned_featureCounts_fixed.bam
    $DROPSEQ_TOOLS_DIR/DetectBeadSynthesisErrors -m 4g \
        I=${ALIGNMENT_DIR}/${gene_tagged_bam} \
        O=${ALIGNMENT_DIR}/${bead_synthesis_fixed_bam} \
        OUTPUT_STATS=${REPORTS_DIR}/${bead_synthesis_fixed_bam}_synthesis_stats.txt \
        SUMMARY=${REPORTS_DIR}/${bead_synthesis_fixed_bam}_synthesis_stats_summary.txt \
        NUM_BARCODES=`expr $est_num_cells \* 2` \
        PRIMER_SEQUENCE=$PRIMER_SEQ \
        MIN_UMIS_PER_CELL=$MIN_UMIS_PER_CELL\
        GENE_EXON_TAG=XT \
        STRAND_TAG=GS # null

    # get histogram, after bead synthesis fix
    $DROPSEQ_TOOLS_DIR/BAMTagHistogram -m 4g \
        I=${ALIGNMENT_DIR}/${bead_synthesis_fixed_bam} \
        O=${REPORTS_DIR}/${bead_synthesis_fixed_bam}.barcode_counts \
        TAG=XC

    $evaluate_STAMPs_by_cumulative_reads \
        ${ALIGNMENT_DIR}/${bead_synthesis_fixed_bam}
    mv ${ALIGNMENT_DIR}/${bead_synthesis_fixed_bam}_mapQ10_STAMPs_* ${REPORTS_DIR}

    # deduplicate based on UMIs per cell
    deduplicated_bam=${prefix}_q10_cleaned_featureCounts_fixed_dedupped.bam
    umi_tools dedup \
        -I ${ALIGNMENT_DIR}/${bead_synthesis_fixed_bam} \
        -S ${ALIGNMENT_DIR}/${deduplicated_bam} \
        --extract-umi-method tag \
        --umi-tag XM \
        --method directional \
        --per-cell \
        --cell-tag XC \
        --per-gene \
        --gene-tag XT \
        --log ${ALIGNMENT_DIR}/${deduplicated_bam}.log

    # get histogram, after deduplication
    $DROPSEQ_TOOLS_DIR/BAMTagHistogram -m 4g \
        I=${ALIGNMENT_DIR}/${deduplicated_bam} \
        O=${REPORTS_DIR}/${deduplicated_bam}.barcode_counts \
        TAG=XC

    $evaluate_STAMPs_by_cumulative_reads \
        ${ALIGNMENT_DIR}/${deduplicated_bam}
    mv ${ALIGNMENT_DIR}/${deduplicated_bam}_mapQ10_STAMPs_* ${REPORTS_DIR}

    sort -k7nr ${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info.txt \
        | grep -v "#" > ${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info_umi_sorted.txt

    # get inflection point
    $get_inflection_point \
        ${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info.txt \
        $INFLECTION_END_POINT \
        ${REPORTS_DIR}/${deduplicated_bam}_inflection_point.txt \
        ${REPORTS_DIR}/Rplot_${deduplicated_bam}_inflection_point.pdf

    # split single cell alignments
    sort -k7nr ${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info.txt \
        | grep -v "#" > ${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info_umi_sorted.txt

    mkdir -p $SPLITTED_BAM_DIR
    cd $SPLITTED_BAM_DIR

    $split_sc_bam \
        ../${deduplicated_bam} \
        ${RESULTS_DIR}/${LIBRARY_DIR}/${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info_umi_sorted.txt \
        `cat ${RESULTS_DIR}/${LIBRARY_DIR}/${REPORTS_DIR}/${deduplicated_bam}_inflection_point.txt`

    grep -v "#" ${RESULTS_DIR}/${LIBRARY_DIR}/${REPORTS_DIR}/${deduplicated_bam}_mapQ10_STAMPs_info_umi_sorted.txt \
        | head -`cat ${RESULTS_DIR}/${LIBRARY_DIR}/${REPORTS_DIR}/${deduplicated_bam}_inflection_point.txt` \
        | cut -f2 | sed 's/$/.bam/g' > ../bam_list

    # est_num_cells=`cat ${RESULTS_DIR}/${LIBRARY_DIR}/${REPORTS_DIR}/${deduplicated_bam}_inflection_point.txt`
    mkdir -p ${RESULTS_DIR}/${LIBRARY_DIR}/${EXPR_DIR}/selected_cells
    $FEATURE_COUNTS \
        -O \
        -T $SLURM_CPUS_ON_NODE \
        -a $REFERENCE_ANNOTATION_GTF \
        -g gene_id \
        -o ${RESULTS_DIR}/${LIBRARY_DIR}/${EXPR_DIR}/selected_cells/${library_name}_q10_cleaned_fixed_dedupped_gene_id.featureCounts \
        `cat ${RESULTS_DIR}/${LIBRARY_DIR}/${ALIGNMENT_DIR}/bam_list`

    $FEATURE_COUNTS \
        -O \
        -T $SLURM_CPUS_ON_NODE \
        -a $REFERENCE_ANNOTATION_GTF \
        -g transcript_id \
        -o ${RESULTS_DIR}/${LIBRARY_DIR}/${EXPR_DIR}/selected_cells/${library_name}_q10_cleaned_fixed_dedupped_transcript_id.featureCounts \
        `cat ${RESULTS_DIR}/${LIBRARY_DIR}/${ALIGNMENT_DIR}/bam_list`
    cd $RESULTS_DIR
done
