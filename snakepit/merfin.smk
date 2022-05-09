from pathlib import PurePath

rule all:
    input:
        'merfin_filtering.csv',
        expand('merfin/{sample}.{vcf}.merfin.{fitted}.filter.vcf',sample=config['samples'],vcf=config['vcfs'],fitted=config['modes'])

def get_fastq(sample):
    return (str(PurePath(config['fastq']) / f'{sample}_R{N}.fastq.gz') for N in (1,2))

rule meryl_count_reads:
    input:
        lambda wildcards: get_fastq(wildcards.sample)
    output:
        temp(directory('readmers/{sample}.readmers.SR.meryl'))
    threads: 24
    resources:
        mem_mb = 5000
    params:
        mem = lambda wildcards,resources,threads: resources['mem_mb']*threads/1100
    shell:
        '/cluster/work/pausch/alex/software/MERFIN_NEW/build/bin/meryl count k=21 memory={params.mem} threads={threads} output {output} {input}'

rule meryl_filter:
    input:
        'readmers/{sample}.readmers.SR.meryl'
    output:
        temp(directory('readmers/{sample}.readmers.gt1.SR.meryl'))
    resources:
        mem_mb = 5000
    shell:
        '''
        /cluster/work/pausch/alex/software/MERFIN_NEW/build/bin/meryl greater-than 1 {input} output {output}
        '''

rule meryl_count_asm:
    output:
        directory('readmers/ARS.seqmers.meryl')
    threads: 6
    resources:
        mem_mb = 3500
    params:
        mem = lambda wildcards,resources,threads: resources['mem_mb']*threads/1100
    shell:
        '/cluster/work/pausch/alex/software/MERFIN_NEW/build/bin/meryl count k=21 memory={params.mem} threads={threads} output {output} {config[reference]}'

rule meryl_print_histogram:
    input:
        'readmers/{sample}.readmers.SR.meryl'
    output:
        'readmers/{sample}.hist'
    shell:
        '/cluster/work/pausch/alex/software/MERFIN_NEW/build/bin/meryl histogram {input} > {output}'

rule merfin_lookup:
    input:
        'readmers/{sample}.hist'
    output:
        'readmers/{sample}/lookup_table.txt',
        'readmers/{sample}/model.txt'
    params:
        out = lambda wildcards, output: PurePath(output[0]).parent,
        ploidy = 1#lambda wildcards: 2 if wildcards.haplotype == 'asm' else 2
    envmodules:
        'gcc/8.2.0',
        'r/4.0.2'
    shell:
        'Rscript /cluster/work/pausch/alex/software/genomescope2.0/genomescope.R -i {input} -k 21 -o {params.out} --fitted_hist -p {params.ploidy}'

#rule bcftools_extract:
#    input:
#        vcf = lambda wildcards: config['vcfs'][wildcards.vcf]
#    output:
#        temp('


def merfin_fitting(wildcards,lookup,model):
    if wildcards.fitted == 'fitted':
        return f'-prob {lookup} -peak {float([line for line in open(model)][7].split()[1])}'
    elif wildcards.fitted == 'coverage':
        return f'-peak {config["samples"][wildcards.sample]}'
    else:
        return ''

rule merfin_filter:
    input:
        seqmers = 'readmers/ARS.seqmers.meryl',
        readmers = 'readmers/{sample}.readmers.gt1.SR.meryl',
        vcf = lambda wildcards: config['vcfs'][wildcards.vcf],
        lookup = lambda wildcards: 'readmers/{sample}/lookup_table.txt' if wildcards.fitted == 'fitted' else [],
        model = lambda wildcards: 'readmers/{sample}/model.txt' if wildcards.fitted == 'fitted' else []
    output:
        'merfin/{sample}.{vcf}.merfin.{fitted}.filter.vcf'
    params:
        out = lambda wildcards, output: PurePath(output[0]).with_suffix('').with_suffix(''),
        fitted = lambda wildcards, input: merfin_fitting(wildcards,input.lookup,input.model) #f'-peak {config["samples"][wildcards.sample]}' if wildcards.fitted != 'fitted' else f'-prob {input.lookup} -peak {float([line for line in open(input.model)][7].split()[1])}'# if wildcards.fitted == 'fitted' else ''
    threads: 8
    resources:
        mem_mb = 5000,
        walltime = '24:00'
    shell:
        '''
        /cluster/work/pausch/alex/software/MERFIN_NEW/build/bin/merfin -filter -sequence {config[reference]} -seqmers {input.seqmers} {params.fitted} -readmers {input.readmers} -threads {threads} -vcf <(bcftools view -s {wildcards.sample} {input.vcf} | bcftools view -i 'GT[*]="alt"') -output {params.out}
        '''

rule tabulate_results:
    input:
        expand('merfin/{sample}.{vcf}.merfin.{fitted}.filter.vcf',sample=config['samples'],vcf=config['vcfs'],fitted=config['modes'])
    output:
        'merfin_filtering.csv'
    params:
        samples = config['samples']
    shell:
        '''
        echo sample,DV,DV_merfin,GATK,GATK_merfin > {output}
        for sample in {params.samples};
        do
          echo $sample,$(grep "records:" $(ls -rt logs/merfin_filter/sample-$sample.vcf-DV.fitted-raw*err | head -n 1) | awk '{{print $2}}'),$(wc -l < <(grep -v "#" merfin/$sample.DV.merfin.raw.filter.vcf)),$(grep "records:" $(ls -rt logs/merfin_filter/sample-$sample.vcf-GATK.fitted-raw*err | head -n 1) | awk '{{print $2}}'),$(wc -l < <(grep -v "#" merfin/$sample.GATK.merfin.raw.filter.vcf)) >> {output}
        done
        '''

rule bcftools_sort:
    input:
        'merfin/{sample}.{vcf}.merfin.{fitted}.filter.vcf'
    output:
        'merfin/{sample}.{vcf}.merfin.{fitted}.filter.vcf.gz'
    resources:
        mem_mb = 2000,
        disk_scratch = 10
    shell:
        '''
        bcftools sort -T $TMPDIR -o {output} {input}
        tabix -fp vcf {output}
        '''

#rule bcftools_isec:
#    input:
#        expand('merfin/{{sample}}.{vcf}.merfin.{fitted}.filter.vcf.gz',vcf=config['vcfs'],fitted=config['modes'])
#    output:
#        directory('merfin/{sample}_merfin_isec')
#    shell:
#        '''
#        bcftools isec 
#        '''
#multiisec
