/*
========================================================================================
    VALIDATE INPUTS
========================================================================================
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowRadseq.initialise(params, log)

// TODO nf-core: Add all file path parameters for the pipeline to the list below
// Check input path parameters to see if they exist
def checkPathParamList = [ params.input, params.multiqc_config ]
for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters
if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }

/*
========================================================================================
    CONFIG FILES
========================================================================================
*/

ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

/*
========================================================================================
    IMPORT LOCAL MODULES/SUBWORKFLOWS
========================================================================================
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK                            } from '../subworkflows/local/input_check'
include { PROCESS_RAD                            } from '../subworkflows/local/fastp_processradtags'
include { CDHIT_RAINBOW as DENOVO                } from '../subworkflows/local/cdhit_rainbow'
include { FASTQ_INDEX_ALIGN_BWA_MINIMAP as ALIGN } from '../subworkflows/local/fastq_index_align_bwa_minimap'
include { BAM_MERGE_INDEX_SAMTOOLS               } from '../subworkflows/nf-core/bam_merge_index_samtools/main.nf'
include { BAM_INTERVALS_BEDTOOLS                 } from '../subworkflows/local/bam_intervals_bedtools'
include { BAM_VARIANT_CALLING_FREEBAYES          } from '../subworkflows/local/bam_variant_calling_freebayes'

/*
========================================================================================
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
========================================================================================
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { FASTQC                      } from '../modules/nf-core/fastqc/main'
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'
include { SAMTOOLS_FAIDX              } from '../modules/nf-core/samtools/faidx/main.nf'

/*
========================================================================================
    RUN MAIN WORKFLOW
========================================================================================
*/

// Info required for completion email and summary
def multiqc_report = []

workflow RADSEQ {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        ch_input
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions.first())

    //
    // SUBWORKFLOW: REMOVE LOW QUALITY READS, TRIM UMI's, DEMULTIPLEX POOLED FILES
    //
    PROCESS_RAD (
        INPUT_CHECK.out.reads
    )
    //ch_versions = ch_versions.mix(PROCESS_RAD.out.versions)

    // assign fasta channel based on method in config file
    switch ( params.method ) {
        // assign ch_reference (input for aligning subworkflow) to the reference in the params
        case 'reference':
            ch_reference = Channel.fromPath(params.genome)
                .map{genome -> tuple (genome.simpleName, genome)} 
            break
        case 'denovo':
            /* SUBWORKFLOW: Cluster READS after applying unique read thresholds within and among samples.
            *   option to provide a list of minimum depth thresholds. See nextflow.config for more details*/
            ch_reference = DENOVO (
                INPUT_CHECK.out.reads, 
                params.sequence_type // sequence type exe.: 'SE', 'PE', ''
            ).fasta
            //ch_versions = ch_versions.mix(DENOVO.out.versions.first())
            break
        // exit 1 (container shut down: application failure or invalid file) ends the process using signal 7
        // if something other than the above cases is stated stop the workflow 
        default:
            exit 1, "unknown method: ${method} \n supported options:" + params.method_options
    }

    // nf-core module index reference for bedtools + freebayes
    ch_faidx = SAMTOOLS_FAIDX (
        ch_reference
        ).fai
    ch_versions = ch_versions.mix(SAMTOOLS_FAIDX.out.versions)

    //
    // SUBWORKFLOW: generate indexes, align input files, dedup reads, index bam, calculate statistics
    //      if denovo and paired then provide length_stats to bwa mem
    
    ch_bam_bai = ALIGN (
        PROCESS_RAD.out.trimmed_reads, 
        ch_reference, 
        ch_faidx,
        params.sequence_type, 
        PROCESS_RAD.out.read_lengths
        ).bam_bai

    /* Option to filter out poorly mapping individuals
    aln = bam_stats.out.stats
        .splitCsv(sep:'\t') // converts file into channel formating (each row). else prints file literal string
        .map { // assign variable to column subsets and convert 2nd col. to class float
            def key = it[0].toString().tokenize('.').get(0) // similar to cut -d
            def mappingrate = it[1].toFloat()
            [ key, mappingrate ]
            }
        .filter ({ key, mappingrate -> mappingrate >= .75}) // retain samples with a mapping greater than 75%
        .join( id_aln_file ) // outputs [key, stat, bam, bai]
        .map { it[2] } // retain only bam records (3rd column)
    */
    
    //
    // SUBWORKFLOW: Get read coverage to calculate intervals off of for freeabyes multithreading
    //

    ch_intervals = BAM_INTERVALS_BEDTOOLS (
        ch_bam_bai.map{meta, bam, bai -> [meta, bam]},
        ch_faidx.map{it[1]},
        PROCESS_RAD.out.read_lengths,
        params.splitByReadCoverage
        ).intervals

    ch_bam_bai_bed = ALIGN.out.mbam_bai
        .combine(ch_intervals.map{it[1]})
        .map { meta, bam, bai, bed -> 
            [[
                id:           meta.id,
                interval:     bed.getName().tokenize( '.' )[1]
            ],
            bam, bai, bed]
        }

    vcf = BAM_VARIANT_CALLING_FREEBAYES (
        ch_bam_bai_bed,
        true,
        ch_reference.map{it[1]},
        ch_faidx.map{it[1]}
    ).vcf

    
    //
    // MODULE: Run FastQC
    //
    FASTQC (
        INPUT_CHECK.out.reads
    )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowRadseq.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(Channel.from(ch_multiqc_config))
    ch_multiqc_files = ch_multiqc_files.mix(ch_multiqc_custom_config.collect().ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(PROCESS_RAD.out.fastp_json.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ALIGN.out.stats.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ALIGN.out.flagstat.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ALIGN.out.idxstats.collect{it[1]}.ifEmpty([]))

    MULTIQC (
        ch_multiqc_files.collect()
    )
    multiqc_report = MULTIQC.out.report.toList()
    ch_versions    = ch_versions.mix(MULTIQC.out.versions)
}

/*
========================================================================================
    COMPLETION EMAIL AND SUMMARY
========================================================================================
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
}

/*
========================================================================================
    THE END
========================================================================================
*/
