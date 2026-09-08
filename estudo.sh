#!/bin/bash

set -e
#set -x

#######################
##### TRATAMENTO DE ARGUMENTOS
#######################

# --- Definições padrões
# Padrão: usar todos os processadores disponíveis
MAKE_CORES=$(nproc)

# Selecionar manualmente os cores do processador k3
CORE=""

# Compilador padrão
CC=gcc
CXX=g++

# Flags booleanas
DO_DEPS=false
DO_CLONE=false
DO_COMPILE=false
DO_INSTALL=false
DO_CLEAN=false
DO_RUN=false
DO_RUN_BUILD=false

# --- PARSING
# Enquanto houver argumentos ($# maior que 0)
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --deps)
            DO_DEPS=true
            ;;
        --clone)
            DO_CLONE=true
            ;;
        --compile)
            DO_COMPILE=true
            ;;
            --cores)
                # Verifica se o próximo argumento existe e é um número
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    MAKE_CORES="$2"
                    shift # Remove o valor do número da fila de argumentos
                else
                    echo "Erro: O argumento --cores requer um número inteiro."
                    exit 1
                fi
                ;;
            --X100)
                CORE=X100
                ;;
            --A100)
                CORE=A100
                ;;
            --install)
                DO_INSTALL=true
                ;;
            --clang)
                CC=clang
                CXX=clang++
                ;;
        --clean)
            DO_CLEAN=true
            ;;
        --run)
            DO_RUN=true
            ;;
        --run-build)
            DO_RUN_BUILD=true
            ;;
        --help|-h) # Aceita --help ou -h
            echo "Uso: $0 [OPÇÕES]"
            echo ""
            cat << EOF
Descrição:
  Script para clonar / compilar / instalar / rodar o OpenMC.

Opções Disponíveis:
  --deps       Instala dependencias para clonar e compilar o openmc.
  --clone      Remove a pasta 'openmc' atual, clona o OpenMC v0.16.0 (tag estável) e sai.
  --compile    Compila os vários casos de estudo do openmc e sai.
       --cores N      Define manualmente o número de núcleos para o 'make'.
       --A100         Define manualmente a otimização para o A100.
       --X100         Define manualmente a otimização para o X100.
       --install      Ativa a instalação após a compilação.
       --clang        Muda o compilador de GCC para Clang
  --run        Roda os casos instalados e saí.
  --run-build  Roda os casos da pasta build e saí.
  --clean      Remove os diretórios de build (openmc/build*) existentes e saí.
  --help, -h   Exibe esta mensagem de ajuda e sai.
EOF
            exit 0 # Sai do script com sucesso após mostrar a ajuda
            ;;
        *)
            echo "Opção desconhecida: $1"
            echo "Use '$0 --help' para ver as opções disponíveis."
            exit 1
            ;;
    esac
    shift # Remove o argumento atual e passa para o próximo
done



# Instalar dependências de compilação (--deps)
if [ "$DO_DEPS" = true ]; then
    # Detectar distribuição
    if [ -f /etc/debian_version ]; then
        echo "Distribuição baseada em Debian detectada."
        sudo apt-get update
        sudo apt-get install -y build-essential cmake libhdf5-dev libpng-dev libxml2-dev libpugixml-dev libeigen3-dev openmpi-bin libopenmpi-dev libomp-dev patchelf
    elif [ -f /etc/arch-release ]; then
        echo "Arch Linux detectado."
        sudo pacman -S --noconfirm gcc cmake hdf5 libpng pugixml eigen openmpi
    else
        echo "Distribuição não detectada. Instale manualmente."
        echo ""
        echo "Para Debian e derivados:"
        echo "sudo apt-get update ; sudo apt-get install -y build-essential cmake libhdf5-dev libpng-dev libxml2-dev libpugixml-dev libeigen3-dev openmpi-bin libopenmpi-dev libomp-dev patchelf"
        echo ""
        echo "Para ArchLinux e derivados:"
        echo "sudo pacman -S --noconfirm gcc cmake hdf5 libpng pugixml eigen openmpi"
        exit 1
    fi
    exit 0
fi



# Clonagem (--clone)
if [ "$DO_CLONE" = true ]; then
    echo "--- Clonando OpenMC v0.16.0 ---"
    rm -rf openmc
    git clone --recurse-submodules --branch v0.16.0 https://github.com/openmc-dev/openmc.git
    cd openmc || exit
    git submodule update --init --recursive
    echo "--- Versão clonada: $(git describe --tags --always) ---"
    exit 0
fi



# Limpeza (--clean)
if [ "$DO_CLEAN" = true ]; then
    echo "--- Limpando diretórios de build ---"
    # Verifica se o diretório existe antes de tentar limpar
    if [ -d "openmc" ]; then
        rm -rf openmc/build*
        echo "Limpeza concluída."
    else
        echo "Aviso: Diretório openmc não encontrado, nada para limpar."
    fi
    exit 0
fi



function compilar_openmc() {
    echo "----------------------------------------INICIO"
    local BUILD_NAME="$1"
    local MPI="$2"
    local DO_PGO="$3"
    local OPT_FLAGS="$4"


    # Verifica se os parametros foram passados
    if [ -z "$BUILD_NAME" ] || [ -z "$MPI" ] || [ -z "$DO_PGO" ] || [ -z "$OPT_FLAGS" ]; then
        echo "Erro: Uso correto ->  compilar_openmc  <nome_da_pasta>  <mpi>  <pgo>  <flags>"
        echo "                                                        on/off on/off"
        echo "----------------------------------------FIM"
        return 1
    fi

    echo "--- Iniciando compilação em: $BUILD_NAME ---"
    echo "--- MPI: $MPI ---"
    echo "--- PGO: $DO_PGO ---"
    echo "--- Flags: $OPT_FLAGS ---"

    # Define diretório de build
    BUILD_DIR="build_$BUILD_NAME"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR" || { echo "Falha ao entrar no diretório $BUILD_DIR"; return 1; }

    # Flags comuns do CMake para 0.16.0:
    # - testes C++ (Catch2) vêm ON por padrão e atrasam cada variante
    # - CMAKE_POLICY_VERSION_MINIMUM cobre vendor/fmt e pugixml no CMake 4
    # - GIT_SUBMODULE=OFF: submódulos já foram inicializados no --clone
    EXTRA_CMAKE_FLAGS="-DOPENMC_BUILD_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DGIT_SUBMODULE=OFF"
    if [[ "$OPT_FLAGS" == *"-flto"* ]]; then
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=TRUE"
    else
        EXTRA_CMAKE_FLAGS="$EXTRA_CMAKE_FLAGS -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=FALSE"
    fi

    # ==============================================================================
    # FASE 1: PGO GENERATION
    # ==============================================================================
    if [ "$DO_PGO" == "on" ]; then
        echo "🚀 [PGO] Iniciando FASE 1: Geração de Perfil (Instrumentation)..."

        # -fprofile-update=atomic é necessário com OpenMP (contadores por thread).
        if [ "$CC" == "gcc" ]; then
            PGO_GEN_FLAGS="$OPT_FLAGS -fprofile-generate -fprofile-update=atomic"
        else
            PGO_GEN_FLAGS="$OPT_FLAGS -fprofile-generate"
        fi

        # CMAKE_BUILD_TYPE=None: não injeta -O3/-DNDEBUG do Release.
        echo "Configurando CMake (Instrumentação)..."
        if ! cmake -DCMAKE_C_COMPILER="$CC" \
              -DCMAKE_CXX_COMPILER="$CXX" \
              -DCMAKE_BUILD_TYPE=None \
              -DCMAKE_CXX_FLAGS="$PGO_GEN_FLAGS" \
              -DCMAKE_C_FLAGS="$PGO_GEN_FLAGS" \
              -DHDF5_PREFER_PARALLEL=off \
              -DOPENMC_USE_MPI="$MPI" \
              -DOPENMC_USE_OPENMP=on \
              -DOPENMC_FORCE_VENDORED_LIBS=ON \
              $EXTRA_CMAKE_FLAGS \
              .. ; then
            echo "❌ ERRO CRÍTICO: CMake falhou na fase de PGO Generation."
            cd ..
            return 1
        fi

        echo "Compilando para instrumentação..."
        if ! make -j "$MAKE_CORES"; then
            echo "❌ ERRO CRÍTICO: Make falhou na fase de PGO Generation."
            cd ..
            return 1
        fi

        echo "📥 [PGO] Copiando inputs para simulação de perfil..."
        cp ../../PGO/materials.xml  .
        cp ../../PGO/geometry.xml   .
        cp ../../PGO/settings.xml   .

        echo "🏃 [PGO] Rodando OpenMC para gerar perfil..."
        if [ ! -f "./bin/openmc" ]; then
            echo "❌ ERRO: Executável não encontrado em ./bin/openmc para rodar o PGO."
            cd ..
            return 1
        fi
        if ! ./bin/openmc; then
            echo "❌ ERRO CRÍTICO: OpenMC falhou na simulação de perfil PGO."
            cd ..
            return 1
        fi

        echo "🧹 [PGO] Limpando binários para forçar recompilação..."
        make clean

        if [ "$CC" == "gcc" ]; then
            # -fprofile-correction ajuda em casos multithread onde o contador não é exato
            OPT_FLAGS="$OPT_FLAGS -fprofile-use -fprofile-correction"
        else
            echo "🔄 [PGO-LLVM] Convertendo dados brutos (.profraw) para perfil (.profdata)..."

            PROFDATA_TOOL=""
            for candidate in llvm-profdata llvm-profdata-22 llvm-profdata-21 llvm-profdata-20 llvm-profdata-19; do
                if command -v "$candidate" &> /dev/null; then
                    PROFDATA_TOOL="$candidate"
                    break
                fi
            done
            if [ -z "$PROFDATA_TOOL" ]; then
                echo "❌ ERRO: Ferramenta 'llvm-profdata' não encontrada. Instale-a para usar PGO no Clang."
                cd ..
                return 1
            fi
            echo "--- llvm-profdata: $PROFDATA_TOOL ---"

            shopt -s nullglob
            PROFRAW_FILES=( default*.profraw )
            shopt -u nullglob
            if [ ${#PROFRAW_FILES[@]} -eq 0 ]; then
                echo "❌ ERRO: Nenhum arquivo .profraw encontrado após a simulação PGO."
                cd ..
                return 1
            fi

            if ! $PROFDATA_TOOL merge -output=default.profdata "${PROFRAW_FILES[@]}"; then
                echo "❌ ERRO: Falha ao converter o perfil do Clang."
                cd ..
                return 1
            fi

            OPT_FLAGS="$OPT_FLAGS -fprofile-use=default.profdata"
        fi

        echo "✅ [PGO] Perfil gerado. Configurando flags para recompilação: $OPT_FLAGS"
    fi


    # ==============================================================================
    # FASE 2: COMPILAÇÃO FINAL (Normal ou PGO-Use)
    # ==============================================================================
    
    # CMAKE_BUILD_TYPE=None: não injeta -O3/-DNDEBUG do Release.
    echo "⚙️  Configurando CMake (Build Final)..."
    if ! cmake -DCMAKE_C_COMPILER="$CC" \
          -DCMAKE_CXX_COMPILER="$CXX" \
          -DCMAKE_BUILD_TYPE=None \
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

    echo "🔨 Compilando Final..."
    if ! make -j "$MAKE_CORES"; then
        echo "❌ ERRO CRÍTICO: Make falhou para $BUILD_NAME"
        cd ..
        return 1 # <--- PARA A FUNÇÃO AQUI
    fi

    # ==============================================================================
    # INSTALAÇÃO E PÓS-PROCESSAMENTO
    # ==============================================================================
    
    if [ "$DO_INSTALL" == true ]; then
        echo "📦 Instalando..."
        sudo make install

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



function compilar_casos_amd64() {

    echo "=========================================="
    echo "INICIANDO BUILDS!"
    echo "=========================================="

    GENERIC_FLAGS="   -march=x86-64     -mtune=generic"
    GENERIC_FLAGSv2=" -march=x86-64-v2  -mtune=generic"
    GENERIC_FLAGSv3=" -march=x86-64-v3  -mtune=generic"
    NATIVE_FLAGS="    -march=native     -mtune=native"

    #Diagnosticado que unroll é irrelevante para o OpenMC
    #N_UNROLL="-fno-unroll-loops"
    #UNROLL_AUTO="-funroll-loops"
    #UNROLL_max2="-funroll-loops --param=max-unroll-times=2"
    #UNROLL_max4="-funroll-loops --param=max-unroll-times=4"
    #UNROLL_max8="-funroll-loops --param=max-unroll-times=8"
    
    #######################
    ##### OTIMIZAÇÕES
    #######################

    # --- Otimizações de Linkagem
    # -flto=auto: Paraleliza o processo de linkagem (LTO) usando todos os núcleos da CPU.
    # -fno-plt: Reduz overhead de chamadas de função (evita tabela de indireção).
    # -fno-semantic-interposition: Permite inlining mais agressivo em código C++ moderno.
    LINKER_OPTS="-flto=auto -fno-plt -fno-semantic-interposition"

    # --- Otimizações Matemáticas (Relaxamento do IEEE 754) [Essencial para vetorização]
    # -fno-math-errno: Funções matemáticas (sqrt, log) não setam a variável global errno.
    # -fno-trapping-math: Assume que operações flutuantes não vão gerar traps (exceções de hardware).
    # -fno-signaling-nans: Desativa suporte a NaNs especiais que causam sinais.
    # -fno-signed-zeros: Trata -0.0 como +0.0 (simplifica comparações e lógica vetorial).
    # -freciprocal-math: Permite transformar x/y em x*(1/y) (multiplicação é muito mais rápida que divisão).
    MATH_OPTS="-fno-math-errno -fno-trapping-math -fno-signaling-nans -fno-signed-zeros -freciprocal-math"

    # --- Preprocessador
    # -DNDEBUG: Desabilita macros assert(). Remove checagens de erro internas do código para evitar paradas desnecessárias na CPU.
    GEN_OPTS="-DNDEBUG"

    # --- Definição Final
    OTI="${LINKER_OPTS} ${MATH_OPTS} ${GEN_OPTS}"



    # --- LISTA DE BUILDS ---
    ERR=0
    ############### Nome do binário                         MPI     PGO     FLAGS

    # Gráfico 1: Curva de tempo Vs. arquitetura base para várias otimizações
    # A ideia desse gráfico é demonstrar que a mudança de arquitetura base só faz diferença com as otimizações

    ## Curva 1: Sem otimização
    compilar_openmc "openmc_${CC}_generic_O0"                     "off"   "off"   "-O0        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV2_O0"                   "off"   "off"   "-O0        $GENERIC_FLAGSv2"               ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV3_O0"                   "off"   "off"   "-O0        $GENERIC_FLAGSv3"               ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O0"                      "off"   "off"   "-O0        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O0_pgo"                  "off"   "on"    "-O0        $NATIVE_FLAGS"                  ||   ERR=1

    ## Curva 2: Otimização 1
    compilar_openmc "openmc_${CC}_generic_O1"                     "off"   "off"   "-O1        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV2_O1"                   "off"   "off"   "-O1        $GENERIC_FLAGSv2"               ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV3_O1"                   "off"   "off"   "-O1        $GENERIC_FLAGSv3"               ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O1"                      "off"   "off"   "-O1        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O1_pgo"                  "off"   "on"    "-O1        $NATIVE_FLAGS"                  ||   ERR=1

    ## Curva 3: Otimização 2
    compilar_openmc "openmc_${CC}_generic_O2"                     "off"   "off"   "-O2        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV2_O2"                   "off"   "off"   "-O2        $GENERIC_FLAGSv2"               ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV3_O2"                   "off"   "off"   "-O2        $GENERIC_FLAGSv3"               ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O2"                      "off"   "off"   "-O2        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O2_pgo"                  "off"   "on"    "-O2        $NATIVE_FLAGS"                  ||   ERR=1

    ## Curva 4: Otimização 3
    compilar_openmc "openmc_${CC}_generic_O3"                     "off"   "off"   "-O3        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV2_O3"                   "off"   "off"   "-O3        $GENERIC_FLAGSv2"               ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV3_O3"                   "off"   "off"   "-O3        $GENERIC_FLAGSv3"               ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O3"                      "off"   "off"   "-O3        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O3_pgo"                  "off"   "on"    "-O3        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O3_oti"                  "off"   "off"   "-O3        $NATIVE_FLAGS $OTI"             ||   ERR=1
    compilar_openmc "openmc_${CC}_native_O3_oti_pgo"              "off"   "on"    "-O3        $NATIVE_FLAGS $OTI"             ||   ERR=1

    ## Curva 5: Otimização fast
    compilar_openmc "openmc_${CC}_generic_Ofast"                  "off"   "off"   "-O3        $GENERIC_FLAGS"                 ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV2_Ofast"                "off"   "off"   "-O3        $GENERIC_FLAGSv2"               ||   ERR=1
    compilar_openmc "openmc_${CC}_genericV3_Ofast"                "off"   "off"   "-O3        $GENERIC_FLAGSv3"               ||   ERR=1
    compilar_openmc "openmc_${CC}_native_Ofast"                   "off"   "off"   "-O3        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_Ofast_pgo"               "off"   "on"    "-O3        $NATIVE_FLAGS"                  ||   ERR=1
    compilar_openmc "openmc_${CC}_native_Ofast_oti"               "off"   "off"   "-Ofast     $NATIVE_FLAGS $OTI"             ||   ERR=1
    compilar_openmc "openmc_${CC}_native_Ofast_oti_pgo"           "off"   "on"    "-Ofast     $NATIVE_FLAGS $OTI"             ||   ERR=1


    # Gráfico 2: Curva de tempo Vs. flag de otimização para arquitetura nativa comparando PGO ativo
    ## Curva 1: ñ
    #    "openmc_${CC}_generic_O0"
    #    "openmc_${CC}_generic_O1"
    #    "openmc_${CC}_generic_O2"
    #    "openmc_${CC}_generic_O3"
    #    "openmc_${CC}_generic_Ofast"

    ## Curva 2: PGO ativo
    #    "openmc_${CC}_native_O0_pgo"
    #    "openmc_${CC}_native_O1_pgo"
    #    "openmc_${CC}_native_O2_pgo"
    #    "openmc_${CC}_native_O3_pgo"
    #    "openmc_${CC}_native_Ofast_pgo"

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
}






function compilar_casos_rv64_k3() {
    # Processador K3, ou os núcleos X100/A100 não tem -mtune ou -march específico para o GCC atual, logo é preciso configurar manualmente

    echo "=========================================="
    echo "INICIANDO BUILDS!"
    echo "=========================================="


    # Se CORE não for definido manualmente, seleciona automaticamente se é X100 ou A100 baseado no core que está sendo compilado
    if [ "$CORE" == "" ]; then
        CORE_NUM=$(awk '{print $39}' /proc/self/stat)
        if [ "$CORE_NUM" -ge 0 ] && [ "$CORE_NUM" -le 7 ]; then
            CORE=X100
        elif [ "$CORE_NUM" -ge 8 ] && [ "$CORE_NUM" -le 15 ]; then
            CORE=A100
        else
            echo "Erro: Core desconhecido '$CORE_NUM'."
            exit 1
        fi
        echo "--- Hardware Detectado: SpacemiT K3 $CORE ---"
    else
        echo "--- Hardware Selecionado: SpacemiT K3 $CORE ---"
    fi

    # Parametros do processador para otimização "nativa"
    if [ "$CORE" == "X100" ]; then
        VLEN=256
        if [ "$CC" == "gcc" ]; then
            CACHE_PARAMS="--param=l1-cache-size=64 --param=l1-cache-line-size=64 --param=l2-cache-size=1024"
        fi
    else
        VLEN=1024
        if [ "$CC" == "gcc" ]; then
            CACHE_PARAMS="--param=l1-cache-size=32 --param=l1-cache-line-size=64 --param=l2-cache-size=256"
        fi
    fi

    echo "VLEN        : $VLEN bits"
    echo "Cache Setup : $CACHE_PARAMS"
    echo "=========================================="

    #######################
    ##### DEFINIÇÃO DE ISA
    #######################

    # --- Extensões Escalares

    # Manipulação de Bits (Scalar Bitmanip)
    # zba: Address generation
    # zbb: Basic bit manipulation
    # zbc: Carry-less multiplication
    # zbs: Single-bit instructions
    SCALAR_BITMANIP="_zba_zbb_zbc_zbs"

    # Ponto Flutuante Escalar (Scalar Floating Point)
    # zfa: Additional FP instructions
    # zfh: Half-precision (FP16) scalar
    SCALAR_FLOAT="_zfa_zfh"

    # Sistema e Cache (System & Cache Management)
    # zicond: Integer conditional ops (zero overhead branching)
    # zicboz/m: Cache Block Zero/Management
    # zawrs: Wait-on-reservation-set
    SCALAR_SYSTEM="_zicond_zicboz_zicbom_zawrs"

    # Instruções Comprimidas Adicionais (Compressed)
    # zca/b/d: Extensões compactas para ponto flutuante e instruções C
    SCALAR_COMPRESSED="_zca_zcb_zcd"

    # Agrupamento das Escalares
    COMMON_EXT="${SCALAR_BITMANIP}${SCALAR_FLOAT}${SCALAR_SYSTEM}${SCALAR_COMPRESSED}"


    # --- Extensões Vetoriais

    # Vector Crypto Base (Bitmanip Vectorial e Crypto Básico)
    # zvbb: Vector basic bitmanip
    # zvbc: Vector carry-less multiply
    # zvkb: Vector crypto bitmanip (subset of zvbb)
    VECTOR_CRYPTO_BASE="_zvbb_zvbc_zvkb"

    # Vector Crypto Avançado (Algoritmos Específicos)
    # zvkg: GCM/GHASH
    # zvkned: AES Encryption/Decryption
    # zvknha/b: SHA-2 hashing
    # zvksed: SM4, zvksh: SM3
    # zvkt: Data independent execution latency
    VECTOR_CRYPTO_ADV="_zvkg_zvkned_zvknha_zvknhb_zvksed_zvksh_zvkt"

    # Vector Floating Point Avançado
    # zvfh: Vector Half-precision (FP16)
    # zvfbfwma: Vector BF16 widening multiply-accumulate
    VECTOR_FLOAT="_zvfh_zvfbfwma"

    # Agrupamento das Vetoriais
    VECTOR_EXT="${VECTOR_CRYPTO_BASE}${VECTOR_CRYPTO_ADV}${VECTOR_FLOAT}"


    # --- Definições Finais das Bases

    # Base SEM Vetor
    ISA_BASE_noV="-mabi=lp64d -march=rv64gc${COMMON_EXT}"

    # Base COM Vetor
    ISA_BASE_V="-mabi=lp64d -march=rv64gcv${COMMON_EXT}${VECTOR_EXT}"





    #######################
    ##### OTIMIZAÇÕES
    #######################

    # --- Otimizações de Linkagem e Geração de Código
    # -flto: Link Time Optimization (permite inlining entre arquivos objetos diferentes).
    # -fno-plt: Evita a Procedure Linkage Table (chamadas diretas, menos overhead de indireção).
    # -fno-semantic-interposition: Permite que o compilador assuma que funções não serão substituídas (interposed) em runtime, permitindo inlining agressivo.
    if [ "$CC" == "gcc" ]; then
        LINKER_OPTS="-flto -fno-plt -fno-semantic-interposition" # Para acelerar mult-thread: -flto=auto
    else
        LINKER_OPTS="-flto -fuse-ld=lld -fno-semantic-interposition" # Para acelerar mult-thread: -flto=auto
    fi

    # --- Otimizações Matemáticas (Relaxamento do IEEE 754) [Essencial para vetorização]
    # -fno-math-errno: Funções matemáticas (sqrt, log) não setam a variável global errno.
    # -fno-trapping-math: Assume que operações flutuantes não vão gerar traps (exceções de hardware).
    # -fno-signed-zeros: Trata -0.0 como +0.0 (simplifica comparações e lógica vetorial).
    # -freciprocal-math: Permite transformar x/y em x*(1/y) (multiplicação é muito mais rápida que divisão).
    # -fno-signaling-nans: Desativa suporte a NaNs especiais que causam sinais.                             # NO LLVM
    if [ "$CC" == "gcc" ]; then
        MATH_OPTS="-fno-math-errno -fno-trapping-math -fno-signed-zeros -freciprocal-math -fno-signaling-nans"
    else
        MATH_OPTS="-fno-math-errno -fno-trapping-math -fno-signed-zeros -freciprocal-math"
    fi

    # --- Preprocessador e Debug
    # -DNDEBUG: Remove todas as macros assert(). Crítico para performance de produção.
    GEN_OPTS="-DNDEBUG"

    # --- Controle de Avisos (Warnings)
    # -Wno-psabi: Silencia o aviso chato sobre mudanças na ABI
    WARN_OPTS="-Wno-psabi"

    # --- Definição Final
    # Concatenar tudo na variável OTI
    OTI="${LINKER_OPTS} ${MATH_OPTS} ${GEN_OPTS} ${WARN_OPTS}"

    # Trava vlen do vetor no definido em zvl
    if [ "$CC" == "gcc" ]; then
        VEC_FIX="-mrvv-vector-bits=zvl"
    else
        VEC_FIX="-mrvv-vector-bits=$VLEN"
    fi
    
    #Diagnosticado que unroll é irrelevante para o OpenMC
    #N_UNROLL="-fno-unroll-loops"
    #UNROLL_AUTO="-funroll-loops"
    #UNROLL_max2="-funroll-loops --param=max-unroll-times=2"
    #UNROLL_max4="-funroll-loops --param=max-unroll-times=4"
    #UNROLL_max8="-funroll-loops --param=max-unroll-times=8"

    ERR=0
    ############### Nome do binário                                 MPI     PGO     FLAGS

    # Builds escalares
    compilar_openmc "openmc_${CORE}_${CC}_O0"                             "off"   "off"   "-O0                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O1"                             "off"   "off"   "-O1                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O2"                             "off"   "off"   "-O2                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O3"                             "off"   "off"   "-O3                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O3_oti"                         "off"   "off"   "-O3    $OTI $CACHE_PARAMS  $ISA_BASE_noV" || ERR=1

    # Builds vetoriais vlen=automático com otimizações extras
    compilar_openmc "openmc_${CORE}_${CC}_v_O0"                           "off"   "off"   "-O0                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O1"                           "off"   "off"   "-O1                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O2"                           "off"   "off"   "-O2                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O3"                           "off"   "off"   "-O3                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O3_oti"                       "off"   "off"   "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}"  || ERR=1

    # Builds vetoriais com vlen fixo
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O0"                 "off"   "off"   "-O0                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O1"                 "off"   "off"   "-O1                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O2"                 "off"   "off"   "-O2                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O3"                 "off"   "off"   "-O3                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O3_oti"             "off"   "off"   "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1



    # Builds escalares + PGO
    compilar_openmc "openmc_${CORE}_${CC}_O0_pgo"                             "off"   "on"    "-O0                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O1_pgo"                             "off"   "on"    "-O1                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O2_pgo"                             "off"   "on"    "-O2                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O3_pgo"                             "off"   "on"    "-O3                        $ISA_BASE_noV" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_O3_oti_pgo"                         "off"   "on"    "-O3    $OTI $CACHE_PARAMS  $ISA_BASE_noV" || ERR=1

    # Builds vetoriais vlen=automático com otimizações extras + PGO
    compilar_openmc "openmc_${CORE}_${CC}_v_O0_pgo"                           "off"   "on"    "-O0                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O1_pgo"                           "off"   "on"    "-O1                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O2_pgo"                           "off"   "on"    "-O2                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O3_pgo"                           "off"   "on"    "-O3                       ${ISA_BASE_V}"  || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_v_O3_oti_pgo"                       "off"   "on"    "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}"  || ERR=1

    # Builds vetoriais com vlen fixo + PGO
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O0_pgo"                 "off"   "on"    "-O0                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O1_pgo"                 "off"   "on"    "-O1                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O2_pgo"                 "off"   "on"    "-O2                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O3_pgo"                 "off"   "on"    "-O3                       ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}_O3_oti_pgo"             "off"   "on"    "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}_zvl${VLEN}b  $VEC_FIX" || ERR=1
    
    
    # Builds vetoriais vlen=min com otimizações extras
    VLEN=128
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}min_O3_oti"          "off"   "off"   "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}_zvl${VLEN}b"       || ERR=1
    VLEN=256
    compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}min_O3_oti"          "off"   "off"   "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}_zvl${VLEN}b"       || ERR=1
    if [ "$CORE" == "A100" ]; then
        VLEN=512
        compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}min_O3_oti"      "off"   "off"   "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}_zvl${VLEN}b"       || ERR=1
        VLEN=1024
        compilar_openmc "openmc_${CORE}_${CC}_vlen${VLEN}min_O3_oti"      "off"   "off"   "-O3    $OTI $CACHE_PARAMS ${ISA_BASE_V}_zvl${VLEN}b"       || ERR=1
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

}






# Compilar os diversos casos do openmc (--compile)
if [ "$DO_COMPILE" = true ]; then
    cd openmc

    # --- DETECÇÃO DE ARQUITETURA ---
    ARCH_SYSTEM=$(uname -m)
    FUNCAO_COMPILACAO=""

    echo "Arquitetura detectada: $ARCH_SYSTEM"
    if [[ "$ARCH_SYSTEM" == "x86_64" ]]; then
        echo "--> Selecionando perfil AMD64"
        FUNCAO_COMPILACAO="compilar_casos_amd64"
        
    elif [[ "$ARCH_SYSTEM" == "riscv64" ]]; then
        echo "--> Selecionando perfil RISC-V (K3)"
        FUNCAO_COMPILACAO="compilar_casos_rv64_k3"
        
    else
        echo "❌ Erro: Arquitetura '$ARCH_SYSTEM' não suportada ou desconhecida."
        exit 1
    fi

    echo "=========================================="
    echo "INICIANDO COMPILAÇÃO"
    echo "Modo: $FUNCAO_COMPILACAO"
    echo "=========================================="

    if $FUNCAO_COMPILACAO; then
        echo "##########################################"
        echo "✅ SUCESSO TOTAL"
        echo "##########################################"
        exit 0
    else
        echo "❌ Falha na compilação de um ou mais casos."
        exit 1
    fi
fi




# Compilar os diversos casos do openmc (--run ou --run-build)
if [ "$DO_RUN" = true ] || [ "$DO_RUN_BUILD" = true ]; then
    mkdir -p log

    if [ "$DO_RUN" = true ]; then
        pattern="/bin/openmc_*"
    else
        pattern="openmc/build_*/bin/openmc"
    fi

    # Inicializar um array com os arquivos que correspondem ao padrão
    shopt -s nullglob
    binaries=( $pattern )
    shopt -u nullglob

    # Verificar se o array está vazio
    if [ ${#binaries[@]} -eq 0 ]; then
        echo "Nenhum binário encontrado com o padrão: $pattern"
        exit 1
    fi

    for binary in "${binaries[@]}"; do
        if [ "$DO_RUN" = true ]; then
            sim=$(basename "$binary")
        else
            sim=${binary#openmc/build_}
            sim=${sim%/bin/openmc}
        fi

        echo "Executando: $binary"
        $binary 2>&1 | tee log/"$sim".log
    done

    echo "FIM!"
    exit 0
fi


echo ""
echo ""
echo "Nada há fazer! Rode com o parametro --help para ajuda."
