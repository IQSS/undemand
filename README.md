# undemand

This generate(s) a self-contained Slurm batch script from an Open OnDemand

```
ruby undemand.rb -r https://github.com/fasrc/ood-rstudio-rocker \
bc_queue=shared \
custom_time=01:00:00 \
custom_memory_per_node=4 \
custom_num_cores=2 \
r_version='R 4.3.3 (Bioconductor 3.18, RStudio 2023.09.1)' \
custom_reservation='weird job name' \
custom_email_address=evansarm@gmail.com \
extra_slurm='' \
work_dir="$HOME/.fasood/.../${uuidv4}" > submit.sh; sbatch submit.sh
```

You'll need to set the `work_dir` yourself for now, make it a UUID, pass the path on `undemand.rb`
