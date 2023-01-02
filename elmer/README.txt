ELMER/ICE Scripts + Google Cloud infrastructure

########################################
Files:
	environment.yml - Environment file for generating conda environment to launch and work with Google CLI
	
	flux_driven_template.sif - Template SIF for flux-driven migration models
	
	accum_driven_template.sif - Template SIF for flux-driven migration models

	run_divide_migration.sh - Shell script that enters ELMER/ICE docker container, runs model, saves model results in Google Bucket. Model Run parameters set using runvalues.txt

	runvalues.txt - Text file with parameters for ELMER/ICE model run

	initialcond.dat - Results.dat file from spin up, used as restart file for all other runs.

	run_spin_up.sh - Run once: produces initialcond.dat

	spin_up_template.sif - Template for spin up stage

	spin_up.txt - Text file with parameters for the spin-up stage.

	elmer_icerise_base/ 
		> mesh.grd - Mesh grid file for Width = 20000 m Height = 600 m, resolution 20m
		> src/ - Directory of solvers 