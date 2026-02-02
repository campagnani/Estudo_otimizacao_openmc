#!/bin/bash

set -e
set -x

# --- TRATAMENTO DE ARGUMENTOS ---
# 1° Parâmetro: Cores (se vazio ou não-numérico, usa nproc)
CORES_INPUT=$1
# 2° Parâmetro: Ação (se "install", instala. Caso contrário, apenas compila)
ACTION_INPUT=$2

# Lógica para definir o número de cores de compilação
if [[ "$CORES_INPUT" =~ ^[0-9]+$ ]]; then
    MAKE_CORES=$CORES_INPUT
else
    MAKE_CORES=$(nproc)
fi


#git clone --recurse-submodules https://github.com/openmc-dev/openmc.git
cd openmc
#git checkout master


function compilar_openmc() {
    echo "----------------------------------------INICIO"
    local BUILD_NAME="$1"
    local MPI="$2"
    local OPT_FLAGS="$3"


    # Verifica se os parametros foram passados
    if [ -z "$BUILD_NAME" ] || [ -z "$MPI" ] || [ -z "$OPT_FLAGS" ]; then
        echo "Erro: Uso correto -> compilar_openmc <nome_da_pasta> <mpi> <flags>"
        echo "----------------------------------------FIM"
        return 1
    fi

    echo "--- Iniciando compilação em: $BUILD_NAME ---"
    echo "--- MPI: $MPI ---"
    echo "--- Flags: $OPT_FLAGS ---"

    # Cria a pasta se não existir e entra nela
    BUILD_DIR="build_$BUILD_NAME"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR" || { echo "Falha ao entrar no diretório $BUILD_DIR"; return 1; }

    if [[ "$OPT_FLAGS" == *"-flto"* ]]; then
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=TRUE"
    else
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=FALSE"
    fi

    if [[ "$OPT_FLAGS" == *"rv64gcv"* ]] && [[ "$OPT_FLAGS" == *"-O3"* || "$OPT_FLAGS" == *"-Ofast"* ]]; then
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DXTENSOR_USE_XSIMD=OFF" #-DXTENSOR_USE_XSIMD=ON" #incompatível com -mrvv-vector-bits=zvl, e gcc não aceita número
    else
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DXTENSOR_USE_XSIMD=OFF"
    fi


    # 1. TENTA CONFIGURAR O CMAKE
    echo "Configurando CMake..."
    if ! cmake -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_CXX_FLAGS="$OPT_FLAGS" \
          -DCMAKE_C_FLAGS="$OPT_FLAGS" \
          -DHDF5_PREFER_PARALLEL=off \
          -DOPENMC_USE_MPI="$MPI" \
          -DOPENMC_USE_OPENMP=on \
          -DCMAKE_INSTALL_PREFIX="/opt/$BUILD_NAME" \
          $EXTRA_CMAKE_FLAGS \
          .. ; then
        echo "❌ ERRO CRÍTICO: CMake falhou para $BUILD_NAME"
        cd ..
        return 1  # <--- PARA A FUNÇÃO AQUI
    fi

    # 2. TENTA COMPILAR
    echo "Compilando..."
    if ! make -j "$MAKE_CORES"; then
        echo "❌ ERRO CRÍTICO: Make falhou para $BUILD_NAME"
        cd ..
        return 1 # <--- PARA A FUNÇÃO AQUI
    fi

    # --- BLOCO DE INSTALAÇÃO (OPCIONAL) ---
    if [ "$ACTION_INPUT" == "install" ]; then
        # Instalação
        sudo make install

        # --- PÓS-PROCESSAMENTO ---

        # Renomeia os arquivos dentro de /opt/$BUILD_NAME para evitar conflitos
        sudo mv "/opt/$BUILD_NAME/bin/openmc" "/opt/$BUILD_NAME/bin/$BUILD_NAME"

        # Cria o link simbólico com os nome customizado
        sudo ln -sf "/opt/$BUILD_NAME/bin/$BUILD_NAME" "/usr/local/bin/$BUILD_NAME"


        # Verifica se a lib existe (dependendo da versão do OpenMC e flags)
        if [ -f "/opt/$BUILD_NAME/lib/libopenmc.so" ]; then
            #Renomeia os arquivos dentro de /opt/$BUILD_NAME para evitar conflitos
            sudo mv "/opt/$BUILD_NAME/lib/libopenmc.so" "/opt/$BUILD_NAME/lib/lib$BUILD_NAME.so"

            # Atualiza o executável para procurar pelo novo nome da lib
            sudo patchelf --replace-needed libopenmc.so lib$BUILD_NAME.so "/opt/$BUILD_NAME/bin/$BUILD_NAME"

            # Cria o link simbólico com os nome customizado
            sudo ln -sf "/opt/$BUILD_NAME/lib/lib$BUILD_NAME.so" "/usr/local/lib/lib$BUILD_NAME.so"
        fi
    fi


    echo "--- Sucesso! Executável disponível como: $BUILD_NAME --- "
    echo "--- E a lib como: lib$BUILD_NAME.so --- "
    cd ..
    echo "----------------------------------------FIM"

}



function tente_compilar_tudo() {

    echo "=========================================="
    echo "INICIANDO BUILDS!"
    echo "=========================================="

    CORE_NUM=$(awk '{print $39}' /proc/self/stat)

    if [ "$CORE_NUM" -ge 0 ] && [ "$CORE_NUM" -le 7 ]; then
        CORE=X100
        VLEN=256
        CACHE_PARAMS="--param=l1-cache-size=64 --param=l1-cache-line-size=64 --param=l2-cache-size=1024"
        TUNE="" #"-mtune=native" Não funciona no K3 no GCC atual
    elif [ "$CORE_NUM" -ge 8 ] && [ "$CORE_NUM" -le 15 ]; then
        CORE=A100
        VLEN=1024
        CACHE_PARAMS="--param=l1-cache-size=32 --param=l1-cache-line-size=64 --param=l2-cache-size=256"
        TUNE="" #"-mtune=native" Não funciona no K3 no GCC atual
    else
        echo "Erro: Core desconhecido '$CORE_NUM'. Use X100 ou A100."
        exit 1
    fi

    echo "--- Hardware Detectado: SpacemiT K3 $CORE ---"
    echo "VLEN        : $VLEN bits"
    echo "Tuning      : "
    echo "Cache Setup : $CACHE_PARAMS"
    echo "=========================================="

    ADDITIONAL_EXT="zicbom_zawrs_zfh_zvfh_zvkg_zvkned_zvknha_zvknhb_zvksed_zvksh_zvkt_zvfbfwma"
    ISA_BASE_noV="rv64gc_zba_zbb_zbc_zbs_zfa_zicond_zicboz_zca_zcb_zcd_$ADDITIONAL_EXT"
    ISA_BASE_V="rv64gcv_zba_zbb_zbc_zbs_zfa_zicond_zicboz_zca_zcb_zcd_zvbb_zvbc_zvkb_$ADDITIONAL_EXT"

    VEC="-mrvv-vector-bits=zvl"
    ABI="-mabi=lp64d"
    #OTI="-flto=auto ...
    OTI="-flto -fno-plt -DNDEBUG -fno-math-errno -fno-trapping-math -fno-semantic-interposition -fno-signaling-nans -fno-signed-zeros -freciprocal-math -Wno-psabi" #-funroll-loops 
    UNROLL="-funroll-loops" #Pessímo, não usar
    UNROLLmax1="--param=max-unroll-times=1"
    UNROLLmax2="--param=max-unroll-times=2"
    UNROLLmax4="--param=max-unroll-times=4"
    UNROLLmax8="--param=max-unroll-times=8"

    ERR=0
    # Builds escalares
    compilar_openmc "openmc_${CORE}_noMpi_noVec_O0_noOti"           "off"   "-O0         $ABI       -march=${ISA_BASE_noV}" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_noVec_O1_noOti"           "off"   "-O1         $ABI       -march=${ISA_BASE_noV}" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_noVec_O2_noOti"           "off"   "-O2         $ABI       -march=${ISA_BASE_noV}" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_noVec_O3_noOti"           "off"   "-O3         $ABI       -march=${ISA_BASE_noV}" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_noVec_Ofast_noOti"        "off"   "-Ofast      $ABI       -march=${ISA_BASE_noV}" || ERR=1

    # Builds escalares com otimizações
    compilar_openmc "openmc_${CORE}_noMpi_noVec_O3"                 "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_noV}" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_noVec_Ofast"              "off"   "-Ofast $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_noV}" || ERR=1

    # Builds vetoriais com otimizações
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}_O3"           "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b  $VEC" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}_Ofast"        "off"   "-Ofast $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b  $VEC" || ERR=1
    
    # Builds vetoriais com otimizações e max unroll
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}_O3_maxU1"     "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b  $VEC $UNROLLmax1" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}_O3_maxU2"     "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b  $VEC $UNROLLmax2" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}_O3_maxU4"     "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b  $VEC $UNROLLmax4" || ERR=1
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}_O3_maxU8"     "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b  $VEC $UNROLLmax8" || ERR=1

    # Builds vetoriais automáticas com otimizações
    compilar_openmc "openmc_${CORE}_noMpi_v_O3"                     "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}" || ERR=1

    # Builds vetoriais menor com otimizações
    VLEN=128
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}min_O3"        "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b" || ERR=1
    VLEN=256
    compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}min_O3"        "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b" || ERR=1
    if [ "$CORE" == "A100" ]; then
        VLEN=512
        compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}min_O3"    "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b" || ERR=1
        VLEN=1024
        compilar_openmc "openmc_${CORE}_noMpi_vlen${VLEN}min_O3"    "off"   "-O3    $OTI $ABI $CACHE_PARAMS -march=${ISA_BASE_V}_zvl${VLEN}b" || ERR=1
    fi


    if [ $ERR == "0" ]; then
        echo "=========================================="
        echo "TODOS OS BUILDS CONCLUÍDOS!"
        echo "=========================================="
        return 0
    else
        echo "=========================================="
        echo "Alguns builds deram erro!"
        echo "=========================================="
        return 1
    fi

    #Aplicar Profile-Guided Optimization (PGO) no futuro
}

# --- LOOP INFINITO DE TENTATIVAS ---

TENTATIVA=1

while true; do
    echo "=========================================="
    echo "TENTATIVA DE COMPILAÇÃO #$TENTATIVA"
    echo "=========================================="

    if (tente_compilar_tudo); then
        echo "##########################################"
        echo "✅ SUCESSO TOTAL NA TENTATIVA #$TENTATIVA"
        echo "##########################################"
        exit 0
    else
        echo "❌ Falha na tentativa #$TENTATIVA."
        ((TENTATIVA++))
    fi
done