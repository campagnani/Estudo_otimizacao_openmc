mkdir -p log

for sim in \
  openmc_generic_O0 \
  openmc_generic_O1 \
  openmc_generic_O2 \
  openmc_generic_O3 \
  openmc_generic_v2_O3 \
  openmc_generic_v3_O3 \
  openmc_native_O3 \
  openmc_native_O3_unroll \
  openmc_native_O3_oti \
  openmc_native_O3_oti_unroll \
  openmc_native_O3_oti_xmid \
  openmc_native_O3_oti_unroll_xmid \
  openmc_native_Ofast_oti_xmid \
  openmc_native_Ofast_oti_unroll_xmid
do
  echo "Executando: $sim"
  ./openmc/build_"$sim"/bin/openmc > log/"$sim".log 2> log/"$sim".err
done

echo "FIM!"
