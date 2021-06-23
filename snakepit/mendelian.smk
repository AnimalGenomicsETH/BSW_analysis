def read_trios(ext='.vcf.gz'):
    if 'trios' not in config:
        return []
    import pandas as pd
    df = pd.read_csv(config['trios'])
    df.fillna('missing',inplace=True)

    targets = []
    for _, row in df.iterrows():
        targets.append(get_dir('mendel',f'{"_".join(row)}{ext}'))
    return targets

rule GLnexus_merge_families:
    input:
        offspring = 'output/{offspring}.bwa.g.vcf.gz',
        sire  = lambda wildcards: 'output/{sire}.bwa.g.vcf.gz' if wildcards.sire != 'missing' else [],
        dam = lambda wildcards: 'output/{dam}.bwa.g.vcf.gz' if wildcards.dam != 'missing' else []
    output:
        get_dir('mendel','{offspring}_{sire}_{dam}.vcf.gz')
    params:
        gvcfs = lambda wildcards, input: list('/data/' / PurePath(fpath) for fpath in input),
        out = lambda wildcards, output: '/data' / PurePath(output[0]),
        DB = lambda wildcards, output: f'/tmp/GLnexus.DB',
        singularity_call = lambda wildcards: make_singularity_call(wildcards,'-B .:/data', input_bind=False, output_bind=False, work_bind=False),
        mem = lambda wildcards,threads,resources: threads*resources['mem_mb']/1500
    threads: 8
    resources:
        mem_mb = 6000,
        disk_scratch = 50,
        walltime = '4:00',
        use_singularity = True
    shell:
        '''
        ulimit -Sn 4096
        {params.singularity_call} \
        {config[GL_container]} \
        /bin/bash -c " /usr/local/bin/glnexus_cli \
        --dir {params.DB} \
        --config DeepVariantWGS \
        --threads {threads} \
        --mem-gbytes {params.mem} \
        {params.gvcfs} \
        | bcftools view - | bgzip -@ 2 -c > {params.out}"
        '''

rule rtg_pedigree:
    output:
        get_dir('mendel','{offspring}_{sire}_{dam}.ped')
    shell:
        '''
        FILE={output}
cat <<EOM >$FILE
#PED format pedigree
#
#fam-id/ind-id/pat-id/mat-id: 0=unknown
#sex: 1=male; 2=female; 0=unknown
#phenotype: -9=missing, 0=missing; 1=unaffected; 2=affected
#
#fam-id ind-id pat-id mat-id sex phen
1 {wildcards.offspring} {wildcards.sire} {wildcards.dam} 1 0
1 {wildcards.sire} 0 0 1 0
1 {wildcards.dam} 0 0 2 0
EOM
        '''

rule rtg_format:
    input:
        ref = lambda wildcards: multiext(config['reference'],'','.fai')
    output:
        sdf = get_dir('main','ARS.sdf')
    params:
        singularity_call = lambda wildcards,input: make_singularity_call(wildcards,extra_args=f'-B {PurePath(input.ref[0]).parent}:/reference/,.:/data',tmp_bind=False,output_bind=False,work_bind=False),
        ref = lambda wildcards,input: f'/reference/{PurePath(input.ref[0]).name}',
    shell:
        '''
        {params.singularity_call} \
        {config[RTG_container]} \
        rtg format -o /data/{output.sdf} {params.ref}
        '''

rule rtg_mendelian_concordance:
    input:
        sdf = get_dir('main','ARS.sdf'),
        vcf = get_dir('mendel','{offspring}_{sire}_{dam}.vcf.gz'),
        pedigree = get_dir('mendel','{offspring}_{sire}_{dam}.ped')
    output:
        temp = temp(get_dir('mendel','filled_{offspring}_{sire}_{dam}.vcf.gz')),
        results = multiext(get_dir('mendel','{offspring}_{sire}_{dam}'),'.inconsistent.vcf.gz','.inconsistent.stats','.mendel.log')
    params:
        vcf_in = lambda wildcards, input: '/data' / PurePath(input.vcf) if (wildcards.dam != 'missing' and wildcards.sire != 'missing') else '/data/mendel/filled_' + PurePath(input.vcf).name,
        vcf_annotated = lambda wildcards, output: '/data' / PurePath(output.results[0]),
        singularity_call = lambda wildcards: make_singularity_call(wildcards,'-B .:/data',input_bind=False,output_bind=False,work_bind=False)
    threads: 1
    resources:
        mem_mb = 10000,
        walltime = '30'
    shell:
        '''
        bcftools merge --no-index -o {output.temp} -Oz {input.vcf} {config[missing_template]}
        {params.singularity_call} \
        {config[RTG_container]} \
        /bin/bash -c "rtg mendelian -i {params.vcf_in} --output-inconsistent {params.vcf_annotated} --pedigree=/data/{input.pedigree} -t /data/{input.sdf} > /data/{output.results[2]}"
        bcftools stats {output.results[0]} | grep "^SN" > {output.results[1]}
        '''

rule mendel_summary:
    input:
        logs = read_trios('.mendel.log'),
        stats = read_trios('.inconsistent.stats')
    output:
        get_dir('main','mendel.summary.df')
    run:
        import pandas as pd

        rows = []
        for log_in, stat_in in zip(input.logs,input.stats):
            rows.append({k:v for k,v in zip(('offspring','sire','dam'),PurePath(log_in).with_suffix('').with_suffix('').name.split('_'))})
            with open(log_in,'r') as fin:
                for line in fin:
                    if 'violation of Mendelian constraints' in line:
                        violate, total = (int(i) for i in line.split()[0].split('/'))
                        rows[-1]['violate'] = violate
                        rows[-1]['total'] = total
            with open(stat_in,'r') as fin:
                for line in fin:
                    if 'number of SNPs' in line:
                        rows[-1]['SNP'] = int(line.rstrip().split()[-1])
                    elif 'number of indels' in line:
                        rows[-1]['indel'] = int(line.rstrip().split()[-1])
        
        df = pd.DataFrame(rows)
        df['rate']=df['violate']/df['total']
        df['duo']=(df == 'missing').any(axis=1)
        df.to_csv(output[0],index=False)
