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

#rm -rf openmc
#git clone https://github.com/openmc-dev/openmc.git #--recurse-submodules
cd openmc
#git checkout master


function compilar_openmc() {
    echo "----------------------------------------INICIO"
    local BUILD_NAME="$1"
    local MPI="$2"
    local XSIMD="$3"
    local OPT_FLAGS="$4"


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

    EXTRA_CMAKE_FLAGS=""
    if [[ "$OPT_FLAGS" == *"-flto"* ]]; then
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=TRUE"
    else
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=FALSE"
    fi

    if [[ "$XSIMD" == "on" ]]; then
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DXTENSOR_USE_XSIMD=ON"
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
          -DOPENMC_FORCE_VENDORED_LIBS=ON \
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

    GENERIC_FLAGS="   -march=x86-64     -mtune=generic"
    GENERIC_FLAGSv2=" -march=x86-64-v2  -mtune=generic"
    GENERIC_FLAGSv3=" -march=x86-64-v3  -mtune=generic"
    NATIVE_FLAGS="    -march=native     -mtune=native"
    
    # Flags de Otimização Geral
    #OTI="-flto=auto ...
    OTI="-flto=auto -fno-plt -DNDEBUG -fno-math-errno -fno-trapping-math -fno-semantic-interposition -fno-signaling-nans -fno-signed-zeros" # Adicionado -mfma e -mavx2 caso native falhe
    UNROLL="-funroll-loops"
    # --- LISTA DE BUILDS ---
    ERR=0
    #               Nome do binário                         MPI     XSIMD   FLAGS
    compilar_openmc "openmc_generic_O0"                     "off"   "off"   "-O0        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_generic_O1"                     "off"   "off"   "-O1        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_generic_O2"                     "off"   "off"   "-O2        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_generic_O3"                     "off"   "off"   "-O3        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_generic_v2_O3"                  "off"   "off"   "-O3        $GENERIC_FLAGSv2"               ||   ERR=1
    compilar_openmc "openmc_generic_v3_O3"                  "off"   "off"   "-O3        $GENERIC_FLAGSv3"               ||   ERR=1

    compilar_openmc "openmc_native_O3"                      "off"   "off"   "-O3        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_native_O3_unroll"               "off"   "off"   "-O3        $NATIVE_FLAGS $UNROLL"          ||   ERR=1
    compilar_openmc "openmc_native_O3_oti"                  "off"   "off"   "-O3        $NATIVE_FLAGS $OTI"             ||   ERR=1
    compilar_openmc "openmc_native_O3_oti_unroll"           "off"   "off"   "-O3        $NATIVE_FLAGS $OTI $UNROLL"     ||   ERR=1
    compilar_openmc "openmc_native_O3_oti_xmid"             "off"   "on"    "-O3        $NATIVE_FLAGS $OTI"             ||   ERR=1
    compilar_openmc "openmc_native_O3_oti_unroll_xmid"      "off"   "on"    "-O3        $NATIVE_FLAGS $OTI $UNROLL"     ||   ERR=1
    compilar_openmc "openmc_native_Ofast_oti_xmid"          "off"   "on"    "-Ofast     $NATIVE_FLAGS $OTI"             ||   ERR=1
    compilar_openmc "openmc_native_Ofast_oti_unroll_xmid"   "off"   "on"    "-Ofast     $NATIVE_FLAGS $OTI $UNROLL"     ||   ERR=1

    #compilar_openmc "openmc_native_O3_oti_xmid_mpi"     "on"    "on"    "-O3        $NATIVE_FLAGS $OTI"   ||   ERR=1
    #compilar_openmc "openmc_native_Ofast_oti_xmid_mpi"  "on"    "on"    "-Ofast     $NATIVE_FLAGS $OTI"   ||   ERR=1

    if [ $ERR == "0" ]; then
        echo "=========================================="
        echo "🎉 TODOS OS BUILDS CONCLUÍDOS!"
        echo "=========================================="
        return 0
    else
        echo "=========================================="
        echo "⚠️ Alguns builds deram erro!"
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