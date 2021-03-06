#!/usr/bin/env nextflow

nextflow.enable.dsl=2

/*
========================================================================================
                         nibscbioinformatics/nanoprofiler
========================================================================================
 nibscbioinformatics/nanoprofiler Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nibscbioinformatics/nanoprofiler
----------------------------------------------------------------------------------------
*/

/*#####################################################
              DEFAULT PARAMS
#################################################################*/

params.publish_dir_mode = "copy"
params.single_end = false
params.conda = false
params.trim_quality = 30
params.trim_minlength = 50
params.trim_adaptertimes = 2
params.trim_maxerror = 0.1
params.trim_maxn = 0.4
params.flash_max_overlap = 300
params.cdhit_seq_identity = 0.9
params.cluster_size_threshold = 5000
params.calculate_tree = true


/*============================================
### INCLUDE MODULES SECTION ###############
==============================================*/

// general use modules 
include { CUTADAPT } from './software/nibscbioinformatics/cutadapt/main.nf' params(params)
include { FLASH } from './software/nibscbioinformatics/flash/main.nf' params(params)
include { CDHIT } from './software/nibscbioinformatics/cd-hit/main.nf' params(params)
include { MAFFT } from './software/nibscbioinformatics/mafft/main.nf' params(params)

// nf-core modules
include { FASTQC } from './software/nf-core/fastqc/main.nf' params(params)

// local use modules
include { RENAME } from './software/local/rename/main.nf' params(params)
include { NANOTRANSLATE } from './software/local/nanotranslate/main.nf' params(params)
include { READCDHIT } from './software/local/readcdhit/main.nf' params(params)
include { GETCDR3 } from './software/local/getcdr3/main.nf' params(params)
include { REPORT } from './software/local/report/main.nf' params(params)

// Import generic functions for in-script modules
include { initOptions; saveFiles; getSoftwareName } from './functions'


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nibscbioinformatics/nanoprofiler --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                Path to TSV file with metadata and location of reads
      -profile [str]                Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --single_end [bool]             Specifies that the input is single-end reads
      --conda                         Boolean. Uses conda instead of other containers for some processes.
                                      Default: false
      --trim_quality                  Integer. Cutadapt setting, indicating the trim quality threshold. 
                                      Default: 30
      --trim_minlength                Cutadapt setting, indicating the minimum length of the read after trimming.
                                      Default: 50
      --trim_adaptertimes             Integer. Cutadapt setting, indicating how many time an adapter can be trimmed from the sequence.
                                      Default: 2
      --trim_maxerror                 Number. Cutadapt setting, indicating the maximum error rate for the adapter match.
                                      Default: 0.1
      --trim_maxn                     Number. Cutadapt setting, indicating filtering value for the reads: discards those with higher fraction of Ns in the sequence.
                                      Default: 0.4
      --flash_max_overlap             Integer. FLASH setting, indicating the maximum overlap in bases allowed between the forward and reverse reads to be merged.
                                      Default: 300
      --cdhit_seq_identity            Number. CH-HIT setting, indicating the minimum sequence identity to identify cluster membership.s
                                      Default: 0.9
      --cluster_size_threshold        Integer. Threshold to filter cluster representative CDR3 sequences, by membership size they represent, when 
                                      selecting sequences to build a phylogenetic tree.
                                      Default: 5000
      --calculate_tree                Boolean. Indicates if the reporting process should perform multiple sequence alignment of selected CDR3 cluster representative sequences,
                                      and plot the resulting phylogenetic tree.
                                      Default: true

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */
// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)



// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['TSV file']         = params.input
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nibscbioinformatics-nanoprofiler-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nibscbioinformatics/nanoprofiler Workflow Summary'
    section_href: 'https://github.com/nibscbioinformatics/nanoprofiler'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
    THIS WILL HAVE TO CHANGE TO COLLECT ALL VERSIONS FROM MODULES
 */
process GETVERSIONS {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    container "ghcr.io/nibscbioinformatics/biopython:v1.78"
    
    output:
    path 'software_versions_mqc.yaml', emit: ch_software_versions_yaml
    path 'software_versions.csv', emit: versions

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}





/*
 * STEP 3 - Output Description HTML
 */
process OUTDOCS {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    container "ghcr.io/nibscbioinformatics/biopython:v1.78"
    
    input:
    file(output_docs)

    output:
    path "results_description.html", emit: html

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

// multi-qc is deprecated in nf-core modules
// therefore we design a custom module here for this pipeline
// which might not be suitable for general use

process MULTIQC {
    
    label 'process_low'

    publishDir "${params.outdir}",
        mode: params.publish_dir_mode,
        
        saveAs: { filename ->
          saveFiles(filename:filename, options:options, publish_dir:getSoftwareName(task.process), publish_id:'')
        }


    container "quay.io/biocontainers/multiqc:1.9--pyh9f0ad1d_0"

    conda (params.conda ? "bioconda::multiqc=1.9" : null)

    input:
    path (multiqc_config)
    path ('fastqc/*')
    path ('cutadapt/*')
    val options

    output:
    path "*multiqc_report.html", emit: report
    path "*_data", emit: data
    path "multiqc_plots", emit: plots

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = "--config ${multiqc_config}"

    """
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}


workflow {
  input = file(params.input)
  inputSample = Channel.empty()
  inputSample = readInputFile(input, params.single_end)

  //GETVERSIONS()
  //OUTDOCS(ch_output_docs)

  FASTQC(inputSample)
  
  adapter = params.adapterfile ? Channel.value(file(params.adapterfile)) : "null"
  def Map cutoptions = [:]
  cutoptions.args = "-q ${params.trim_quality} --minimum-length ${params.trim_minlength} --times ${params.trim_adaptertimes} -e ${params.trim_maxerror} --max-n ${params.trim_maxn}"
  cutoptions.args2 = "-q ${params.trim_quality},${params.trim_quality} --minimum-length ${params.trim_minlength} --times ${params.trim_adaptertimes} -e ${params.trim_maxerror} --max-n ${params.trim_maxn}"

  CUTADAPT(inputSample, adapter, cutoptions)

  def Map flashoptions = [:]
  flashoptions.args = "--max-overlap ${params.flash_max_overlap}"
  flashoptions.args2 = ''
  FLASH(CUTADAPT.out.reads, flashoptions)

  def Map nulloptions = [:]
  nulloptions.args = ""
  nulloptions.args2 = ""

  def Map renameoptions = [:]
  renameoptions.args = ""
  renameoptions.args2 = ""
  renameoptions.single_end = true // this is because output of FLASH merges R1 and R2

  RENAME(FLASH.out.reads, renameoptions)

  NANOTRANSLATE(RENAME.out.renamed, nulloptions)

  def Map cdhitoptions = [:]
  cdhitoptions.args = "-c ${params.cdhit_seq_identity}"

  CDHIT(NANOTRANSLATE.out.fasta, cdhitoptions)


  // this process needs to access CD-HIT summary file
  // which has extension .clstr
  READCDHIT(CDHIT.out.clusters, nulloptions)

  // this process needs to access the other output of cd-hit
  // which are the raw sequences for the clusters, with
  // extension .clusters
  GETCDR3(CDHIT.out.clusterseq, nulloptions)
  //GETCDR3.out.fasta

  def Map mafftoptions = [:]
  mafftoptions.args = "--retree 0 --treeout --localpair --reorder"
  mafftoptions.args2 = ''

  sampleFasta = GETCDR3.out.fasta.groupTuple(by:[1, 2])
  sampleFasta = sampleFasta.dump(tag: 'MAFFT input')

  MAFFT(sampleFasta, mafftoptions)

  //MAFFT.out.tree
  //MAFFT.out.fasta

  MULTIQC(
      ch_multiqc_config,
      FASTQC.out.ziponly.collect(),
      CUTADAPT.out.logsonly.collect(),
      nulloptions
  )

  
  REPORT(
      READCDHIT.out.summaryonly.collect(),
      GETCDR3.out.histonly.collect(),
      GETCDR3.out.tsvonly.collect(),
      GETCDR3.out.metaonly.collect(),
      nulloptions
  )

}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nibscbioinformatics/nanoprofiler] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nibscbioinformatics/nanoprofiler] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nibscbioinformatics/nanoprofiler] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nibscbioinformatics/nanoprofiler] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nibscbioinformatics/nanoprofiler] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nibscbioinformatics/nanoprofiler] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nibscbioinformatics/nanoprofiler]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nibscbioinformatics/nanoprofiler]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nibscbioinformatics/nanoprofiler v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}



// ############## WARNING !!! #########################
// the part below is going to be transferred to a module soon
// ############## UTILITIES AND SAMPLE LOADING ######################

// ### preliminary check functions

def checkExtension(file, extension) {
    file.toString().toLowerCase().endsWith(extension.toLowerCase())
}

def checkFile(filePath, extension) {
  // first let's check if has the correct extension
  if (!checkExtension(filePath, extension)) exit 1, "File: ${filePath} has the wrong extension. See --help for more information"
  // then we check if the file exists
  if (!file(filePath).exists()) exit 1, "Missing file in TSV file: ${filePath}, see --help for more information"
  // if none of the above has thrown an error, return the file
  return(file(filePath))
}

// the function expects a tab delimited sample sheet, with a header in the first line
// the header will name the variables and therefore there are a few mandatory names
// sampleID to indicate the sample name or unique identifier
// read1 to indicate read_1.fastq.gz, i.e. R1 read or forward read
// read2 to indicate read_2.fastq.gz, i.e. R2 read or reverse read
// any other column should fulfill the requirements of modules imported in main
// the function also expects a boolean for single or paired end reads from params

def readInputFile(tsvFile, single_end) {
    Channel.from(tsvFile)
        .splitCsv(header:true, sep: '\t')
        .map { row ->
            def meta = [:]
            def reads = []
            def sampleinfo = []
            meta.sampleID = row.sampleID
            if (row.immunisation) {
                meta.immunisation = row.immunisation
            }
            if (row.boost) {
                meta.boost = row.boost
            }
            if (row.individualID) {
                meta.individualID = row.individualID
            }
            if (single_end) {
              reads = checkFile(row.read1, "fastq.gz")
            } else {
              reads = [ checkFile(row.read1, "fastq.gz"), checkFile(row.read2, "fastq.gz") ]
            }
            sampleinfo = [ meta, reads ]
            return sampleinfo
        }
}
