process RAINBOW_DIV {
    tag "${meta.id}"
    label 'process_medium'

    conda (params.enable_conda ? 'bioconda::rainbow=2.0.4' : null)
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/rainbow:2.0.4--hec16e2b_7' :
        'quay.io/biocontainers/rainbow:2.0.4--hec16e2b_7' }"

    input:
    tuple val (meta), path (cluster)

    output:
    tuple val (meta), path ("*_rbdiv.out")         , emit: rbdiv
    tuple val (meta), path ("*_rbdiv.out.*")       , emit: rbdiv_multi
    tuple val (meta), path ('*.log')               , emit: log
    path "versions.yml"                            , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    rainbow div -i ${cluster} -o ${prefix}_rbdiv.out \
    ${args} \
    2> rbdiv.log

    CLUST=(`tail -1 ${prefix}_rbdiv.out | cut -f5`)
	CLUST1=\$(( \$CLUST / 100 + 1))
	CLUST2=\$(( \$CLUST1 + 100 ))

    for i in \$(seq -w 1 \$CLUST2);
    do
        num=\$( echo \$i | sed -e 's/^0*//g')
        if [ "\$num" -le 100 ]; then
            j=\$num
            k=\$((\$num -1))
        else
            num=\$((\$num - 99))
            j=\$((\$num * 100))
            k=\$((\$j - 100))
        fi
        awk -v x=\$j -v y=\$k '\$5 <= x && \$5 > y' ${prefix}_rbdiv.out > ${prefix}_rbdiv.out.\$i;
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        rainbow: \$(rainbow | head -n 1 | cut -d ' ' -f 2)
    END_VERSIONS
    """
}