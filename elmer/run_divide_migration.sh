#!/bin/bash/

###takes files with input values for accumulation gradient,final divide position, and type of migration


####### Variables ##########
inputfil=runvalues.txt
outputbucket=gs://ldeo-glaciology/elmer_janie/run_outputs/
dockcont=elmertest_janie1
###############


while read -r a0 DivPos migrate remainder; do
# check migration type
if [["$migrate" == *[Ff]lux*]]; then
	filnam="flux_driven_template.sif"
	migtype="flux"
elif [["$migrate" == *[Aa]ccum*]]; then
	filnam="accum_driven_template.sif"
	migtype="accum"
else
	echo "No migration type defined."
	exit 1
fi

mkdir -p icerise_run
#touch Korff_run/examplefile.txt
mkdir -p icerise_run/mesh/
mkdir -p icerise_run/src/
bash update_sif_vardiv.sh ${a0} ${DivPos} ${filnam} #create new sif file from appropriate template
##cp Case_*.sif output/
cp elmer_icerise_base/mesh.grd icerise_run #template mesh grid
cp elmer_icerise_base/src/* icerise_run/src/ #template solvers into new folder
cp initialcond.dat icerise_run/mesh/initialcond.dat
mv Case_${a0}_${DivPos}.sif icerise_run/
chmod -R 777 icerise_run/
echo 'Entering docker container and running the script'
sudo service docker start
docker start ${dockcont}

echo [`date +"%D %T"`] Running Case_${a0}_${DivPos} | tee -a log.txt
echo [`date +"%D %T"`] ElmerGrid 1 2 icerise_run/mesh.grd | tee -a log.txt
docker exec ${dockcont} ElmerGrid 1 2 shared_directory/icerise_run/mesh.grd | tee -a log.txt

echo [`date +"%D %T"`] ElmerSolver shared_directory/icerise_run/Case_${a0}_${DivPos}.sif | tee -a log.txt
docker exec ${dockcont} ElmerSolver shared_directory/icerise_run/Case_${a0}_${DivPos}.sif | tee -a log.txt

echo [`date +"%D %T"`] gsutil cp icerise_run/mesh/*.vtu ${outputbucket}run_${a0}_${DivPos}_${migtype}/ | tee -a log.txt
gsutil cp icerise_run/mesh/*.vtu ${outputbucket}run_${a0}_${DivPos}_${migtype}/

echo [`date +"%D %T"`] Finished Case_${a0}_${DivPos}_${migtype} | tee -a log.txt
done < ${inputfil}
