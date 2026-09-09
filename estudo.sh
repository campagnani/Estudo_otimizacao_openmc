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
DO_COMPILE_DEFAULT=false
DO_COMPILE_CONDA=false
DO_COMPILE_CAUSAL=false
DO_COMPILE_FATORIAL=false
DO_COMPILE_NOVAS=false
DO_INSTALL=false
DO_CLEAN=false
DO_RUN=false
DO_RUN_BUILD=false
SAW_CORES=false

# --- PARSING
# Enquanto houver argumentos ($# maior que 0)
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --deps)
            DO_DEPS=true
            ;;
        --clone)
            DO_CLONE=true
            ;;
        --compile)
            DO_COMPILE=true
            ;;
        --compile-default)
            DO_COMPILE_DEFAULT=true
            ;;
        --compile-conda)
            DO_COMPILE_CONDA=true
            ;;
        --compile-causal)
            DO_COMPILE_CAUSAL=true
            ;;
        --compile-fatorial)
            DO_COMPILE_FATORIAL=true
            ;;
        --compile-novas)
            DO_COMPILE_NOVAS=true
            ;;
        --cores)
            # Subparâmetro de qualquer modo de compilação.
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                MAKE_CORES="$2"
                SAW_CORES=true
                shift
            else
                echo "Erro: --cores exige um número inteiro (ex.: --cores 8)."
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
  --compile-default  Compila só o CMake Release default (sem flags extras) e sai.
  --compile-conda    Baixa o OpenMC 0.16.0 pré-compilado do conda-forge (nodagmc, sem MPI)
                     e deixa em openmc/build_openmc_conda/ como se tivesse sido compilado.
  --compile-causal   Compila Generic O3 + -fno-plt, e Generic O3 + flags conda-forge (fno-plt,
                     function-sections, gc-sections, mtune=haswell), para isolar o ganho do conda.
  --compile-fatorial Fatorial Native O3+NDEBUG: 3 flags de linker (2^3) e 5 de math (2^5), ± PGO.
  --compile-novas    A/B em cima de Native O3 oti: -fno-stack-protector, -fno-PIE,
                     gc-sections; no Clang também ThinLTO+lld e -ffp-contract=fast;
                     depois o pacote todas juntas. ± PGO.
       --cores N      Define manualmente o número de núcleos para o 'make'.
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

# --- Validação das combinações ---
N_COMPILE_MODES=0
[ "$DO_COMPILE" = true ] && N_COMPILE_MODES=$((N_COMPILE_MODES + 1))
[ "$DO_COMPILE_DEFAULT" = true ] && N_COMPILE_MODES=$((N_COMPILE_MODES + 1))
[ "$DO_COMPILE_CONDA" = true ] && N_COMPILE_MODES=$((N_COMPILE_MODES + 1))
[ "$DO_COMPILE_CAUSAL" = true ] && N_COMPILE_MODES=$((N_COMPILE_MODES + 1))
[ "$DO_COMPILE_FATORIAL" = true ] && N_COMPILE_MODES=$((N_COMPILE_MODES + 1))
[ "$DO_COMPILE_NOVAS" = true ] && N_COMPILE_MODES=$((N_COMPILE_MODES + 1))
if [ "$N_COMPILE_MODES" -gt 1 ]; then
    echo "Erro: use só um modo de compilação (--compile, --compile-default, --compile-conda, --compile-causal, --compile-fatorial ou --compile-novas)."
    exit 1
fi

if [ "$DO_RUN" = true ] && [ "$DO_RUN_BUILD" = true ]; then
    echo "Erro: use --run ou --run-build, não os dois."
    exit 1
fi

if [ -n "$CORE" ] && [ "$DO_COMPILE" != true ]; then
    echo "Erro: --A100 e --X100 só valem com --compile (perfil RISC-V K3)."
    exit 1
fi

if [ "$DO_INSTALL" = true ] && [ "$DO_COMPILE" != true ] && [ "$DO_COMPILE_DEFAULT" != true ]; then
    echo "Erro: --install só vale com --compile ou --compile-default."
    exit 1
fi

if [ "$CC" = "clang" ] && [ "$N_COMPILE_MODES" -eq 0 ]; then
    echo "Erro: --clang só vale com um modo de compilação."
    exit 1
fi

if [ "$SAW_CORES" = true ] && [ "$N_COMPILE_MODES" -eq 0 ]; then
    echo "Erro: --cores só vale com um modo de compilação."
    exit 1
fi



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
        if [ "$CC" != "gcc" ]; then
            # %m: um .profraw por processo/módulo (OpenMP).
            export LLVM_PROFILE_FILE="$(pwd)/default-%m.profraw"
        fi
        if ! ./bin/openmc; then
            echo "❌ ERRO CRÍTICO: OpenMC falhou na simulação de perfil PGO."
            unset LLVM_PROFILE_FILE
            cd ..
            return 1
        fi
        unset LLVM_PROFILE_FILE

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
            PROFRAW_FILES=( ./*.profraw )
            shopt -u nullglob
            if [ ${#PROFRAW_FILES[@]} -eq 0 ]; then
                echo "❌ ERRO: Nenhum arquivo .profraw encontrado após a simulação PGO."
                cd ..
                return 1
            fi

            # Caminho absoluto: o Make do CMake entra em vendor/fmt etc. e o
            # Clang resolve -fprofile-use= relativamente ao cwd de cada compile.
            PROFDATA_ABS="$(pwd)/default.profdata"
            if ! $PROFDATA_TOOL merge -output="$PROFDATA_ABS" "${PROFRAW_FILES[@]}"; then
                echo "❌ ERRO: Falha ao converter o perfil do Clang."
                cd ..
                return 1
            fi

            OPT_FLAGS="$OPT_FLAGS -fprofile-use=${PROFDATA_ABS}"
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


# Default CMake Release: sem CMAKE_C/CXX_FLAGS. Só troca o compilador via $CC/$CXX.
function compilar_openmc_default() {
    echo "----------------------------------------INICIO"
    local BUILD_NAME="openmc_${CC}_default"
    local BUILD_DIR="build_$BUILD_NAME"

    echo "--- Default Release (sem flags extras) ---"
    echo "--- Compilador: $CC / $CXX ---"
    echo "--- Pasta: $BUILD_NAME ---"

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR" || { echo "Falha ao entrar no diretório $BUILD_DIR"; return 1; }

    local EXTRA_CMAKE_FLAGS="-DOPENMC_BUILD_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DGIT_SUBMODULE=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=FALSE"

    echo "⚙️  Configurando CMake (BUILD_TYPE=Release)..."
    if ! cmake -DCMAKE_C_COMPILER="$CC" \
          -DCMAKE_CXX_COMPILER="$CXX" \
          -DCMAKE_BUILD_TYPE=Release \
          -DHDF5_PREFER_PARALLEL=off \
          -DOPENMC_USE_MPI=off \
          -DOPENMC_USE_OPENMP=on \
          -DOPENMC_FORCE_VENDORED_LIBS=ON \
          -DCMAKE_INSTALL_PREFIX="/opt/$BUILD_NAME" \
          $EXTRA_CMAKE_FLAGS \
          .. ; then
        echo "❌ ERRO CRÍTICO: CMake falhou para $BUILD_NAME"
        cd ..
        return 1
    fi

    echo "🔨 Compilando default..."
    if ! make -j "$MAKE_CORES"; then
        echo "❌ ERRO CRÍTICO: Make falhou para $BUILD_NAME"
        cd ..
        return 1
    fi

    if [ "$DO_INSTALL" == true ]; then
        echo "📦 Instalando..."
        sudo make install
        sudo mv "/opt/$BUILD_NAME/bin/openmc" "/opt/$BUILD_NAME/bin/$BUILD_NAME"
        sudo ln -sf "/opt/$BUILD_NAME/bin/$BUILD_NAME" "/usr/local/bin/$BUILD_NAME"
        if [ -f "/opt/$BUILD_NAME/lib/libopenmc.so" ]; then
            sudo mv "/opt/$BUILD_NAME/lib/libopenmc.so" "/opt/$BUILD_NAME/lib/lib$BUILD_NAME.so"
            sudo patchelf --replace-needed libopenmc.so lib$BUILD_NAME.so "/opt/$BUILD_NAME/bin/$BUILD_NAME"
            sudo ln -sf "/opt/$BUILD_NAME/lib/lib$BUILD_NAME.so" "/usr/local/lib/lib$BUILD_NAME.so"
        fi
    fi

    echo "--- Sucesso! Executável disponível como: $BUILD_NAME --- "
    cd ..
    echo "----------------------------------------FIM"
}


# Binário pré-compilado do conda-forge, no mesmo layout CMake:
#   openmc/build_openmc_conda/bin/openmc
# Variante: 0.16.0, sem DAGMC, sem MPI (igual aos builds locais).
# Prefixo isolado: o --run-build acha o executável pelo glob build_*/bin/openmc.
function baixar_openmc_conda() {
    echo "----------------------------------------INICIO"
    local BUILD_NAME="openmc_conda"
    local BUILD_DIR="build_$BUILD_NAME"
    local OPENMC_CONDA_VERSION="${OPENMC_CONDA_VERSION:-0.16.0}"
    local SPEC="openmc=${OPENMC_CONDA_VERSION}=nodagmc_nompi_*"
    local ARCH_SYSTEM
    ARCH_SYSTEM=$(uname -m)
    local MM_ARCH=""

    echo "--- OpenMC conda-forge (binário pré-compilado) ---"
    echo "--- Spec: $SPEC ---"
    echo "--- Pasta: $BUILD_DIR ---"

    case "$ARCH_SYSTEM" in
        x86_64)  MM_ARCH="linux-64" ;;
        aarch64|arm64) MM_ARCH="linux-aarch64" ;;
        *)
            echo "❌ conda-forge/openmc não publica binário para '$ARCH_SYSTEM'."
            echo "   Plataformas: linux-64, linux-aarch64, osx-64."
            echo "----------------------------------------FIM"
            return 1
            ;;
    esac

    local ROOT
    ROOT="$(pwd)/.mamba_root"
    mkdir -p "$ROOT/bin"
    export MAMBA_ROOT_PREFIX="$ROOT"

    local MM=""
    if command -v micromamba >/dev/null 2>&1; then
        MM="$(command -v micromamba)"
    elif command -v mamba >/dev/null 2>&1; then
        MM="$(command -v mamba)"
    elif command -v conda >/dev/null 2>&1; then
        MM="$(command -v conda)"
    else
        echo "⚙️  micromamba/mamba/conda não encontrado. Baixando micromamba ($MM_ARCH)..."
        MM="$ROOT/bin/micromamba"
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            echo "❌ Precisa de curl ou wget para baixar o micromamba."
            echo "----------------------------------------FIM"
            return 1
        fi
        if command -v curl >/dev/null 2>&1; then
            if ! curl -fsSL "https://micro.mamba.pm/api/micromamba/${MM_ARCH}/latest" \
                    | tar -xj -C "$ROOT/bin" --strip-components=1 bin/micromamba; then
                echo "❌ Falha ao baixar/extrair o micromamba."
                echo "----------------------------------------FIM"
                return 1
            fi
        else
            if ! wget -qO- "https://micro.mamba.pm/api/micromamba/${MM_ARCH}/latest" \
                    | tar -xj -C "$ROOT/bin" --strip-components=1 bin/micromamba; then
                echo "❌ Falha ao baixar/extrair o micromamba."
                echo "----------------------------------------FIM"
                return 1
            fi
        fi
        chmod +x "$MM"
    fi

    echo "--- Instalador: $MM ---"
    rm -rf "$BUILD_DIR"
    local PREFIX
    PREFIX="$(pwd)/$BUILD_DIR"

    echo "📦 Criando prefixo $BUILD_DIR a partir do conda-forge..."
    if ! "$MM" create -y -p "$PREFIX" -c conda-forge --override-channels "$SPEC"; then
        echo "❌ Falha ao instalar $SPEC do conda-forge."
        echo "----------------------------------------FIM"
        return 1
    fi

    if [ ! -x "$PREFIX/bin/openmc" ]; then
        echo "❌ Prefixo criado, mas $PREFIX/bin/openmc não existe."
        echo "----------------------------------------FIM"
        return 1
    fi

    echo "--- binário: $PREFIX/bin/openmc ---"
    "$PREFIX/bin/openmc" --version 2>/dev/null || true
    echo "--- Sucesso! Executável disponível como: $BUILD_NAME --- "
    echo "----------------------------------------FIM"
}


# Isola o ganho do binário conda-forge: mesmo Generic O3 (x86-64, GCC local),
# mudando só as flags de linking/tune que o conda-forge injeta por padrão.
function compilar_casos_causal() {
    echo "=========================================="
    echo "ISOLAMENTO CAUSAL (flags conda-forge)"
    echo "=========================================="
    local GENERIC="-march=x86-64 -mtune=generic"
    local ERR=0

    # Controle já existe: openmc_${CC}_generic_O3  (~309 s)
    # 1) só -fno-plt
    compilar_openmc "openmc_${CC}_generic_O3_fnoplt" "off" "off" \
        "-O3 ${GENERIC} -fno-plt" || ERR=1

    # 2) pacote típico conda-forge (sem mudar ISA para nocona/SSE3)
    compilar_openmc "openmc_${CC}_generic_O3_condaflags" "off" "off" \
        "-O3 -march=x86-64 -mtune=haswell -fno-plt -ffunction-sections -Wl,--gc-sections" || ERR=1

    return "$ERR"
}


# A/B de flags ainda não medidas em cima do Native O3 oti (controle já existe
# como openmc_${CC}_native_O3_oti). Uma alteração por build, ± PGO.
function teste_flags_novas_amd64() {
    echo "=========================================="
    echo "TESTE FLAGS NOVAS (sobre Native O3 oti)"
    echo "Controle: openmc_${CC}_native_O3_oti (± PGO)"
    echo "=========================================="

    local NATIVE="-march=native -mtune=native"
    local LINKER_OPTS="-flto=auto -fno-plt -fno-semantic-interposition"
    local MATH_OPTS="-fno-math-errno -fno-trapping-math -fno-signaling-nans -fno-signed-zeros -freciprocal-math"
    local GEN_OPTS="-DNDEBUG"
    local OTI="${LINKER_OPTS} ${MATH_OPTS} ${GEN_OPTS}"
    local BASE="-O3 ${NATIVE} ${OTI}"
    local ERR=0

    _caso_nova() {
        local tag="$1"
        local pgo="$2"
        local flags="$3"
        local name="openmc_${CC}_native_O3_oti_${tag}"
        [ "$pgo" = "on" ] && name="${name}_pgo"
        echo ">>> ${name}"
        echo "    PGO=${pgo}  flags:${flags}"
        compilar_openmc "$name" "off" "$pgo" "$flags" || ERR=1
    }

    # 1) Arch/GCC costuma ligar SSP mesmo em -O3
    _caso_nova "nossesp" "off" "${BASE} -fno-stack-protector"
    _caso_nova "nossesp" "on"  "${BASE} -fno-stack-protector"

    # 2) Executável não-PIE
    _caso_nova "nopie" "off" "${BASE} -fno-PIE -no-pie"
    _caso_nova "nopie" "on"  "${BASE} -fno-PIE -no-pie"

    # 3) gc-sections (pacote conda) agora em cima do oti, não no Generic
    _caso_nova "gcsec" "off" "${BASE} -ffunction-sections -fdata-sections -Wl,--gc-sections"
    _caso_nova "gcsec" "on"  "${BASE} -ffunction-sections -fdata-sections -Wl,--gc-sections"

    if [ "$CC" = "clang" ]; then
        # 4) ThinLTO + lld no lugar de -flto=auto; vtables só com LTO
        local LINKER_THIN="-flto=thin -fuse-ld=lld -fno-plt -fno-semantic-interposition -fwhole-program-vtables"
        local BASE_THIN="-O3 ${NATIVE} ${LINKER_THIN} ${MATH_OPTS} ${GEN_OPTS}"
        _caso_nova "thinlto" "off" "${BASE_THIN}"
        _caso_nova "thinlto" "on"  "${BASE_THIN}"

        # 5) Contrair FMA de forma explícita (GCC -O3 native já faz)
        _caso_nova "fpcontract" "off" "${BASE} -ffp-contract=fast"
        _caso_nova "fpcontract" "on"  "${BASE} -ffp-contract=fast"
    fi

    # 6) Todas as flags novas juntas (± PGO). No GCC omite -no-pie:
    #    o link da libopenmc.so falha com -fno-PIE/-no-pie.
    local TODAS_COMUM="-fno-stack-protector -ffunction-sections -fdata-sections -Wl,--gc-sections"
    if [ "$CC" = "clang" ]; then
        local TODAS="${BASE_THIN} ${TODAS_COMUM} -fno-PIE -no-pie -ffp-contract=fast"
    else
        local TODAS="${BASE} ${TODAS_COMUM}"
    fi
    _caso_nova "todas" "off" "${TODAS}"
    _caso_nova "todas" "on"  "${TODAS}"

    if [ "$ERR" -eq 0 ]; then
        echo "=========================================="
        echo "🎉 TESTE FLAGS NOVAS CONCLUÍDO!"
        echo "=========================================="
        return 0
    fi
    echo "=========================================="
    echo "⚠️ Alguns builds de flags novas deram erro!"
    echo "=========================================="
    return 1
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


function compilar_fatorial_amd64() {

    echo "=========================================="
    echo "FATORIAL OTI: linker 2^3 e math 2^5, ± PGO"
    echo "Base: -O3 -march=native -mtune=native -DNDEBUG"
    echo "=========================================="

    local BASE="-O3 -march=native -mtune=native -DNDEBUG"
    local LINKER_TAGS=(flto fnoplt fnosi)
    local LINKER_FLGS=("-flto=auto" "-fno-plt" "-fno-semantic-interposition")
    local MATH_TAGS=(fnome fnotm fnosn fnosz frecp)
    local MATH_FLGS=("-fno-math-errno" "-fno-trapping-math" "-fno-signaling-nans" "-fno-signed-zeros" "-freciprocal-math")

    ERR=0

    _caso() {
        local tag="$1"
        local extra="$2"
        local pgo="$3"
        local name="openmc_${CC}_native_O3"
        [ -n "$tag" ] && name="${name}_${tag}"
        [ "$pgo" = "on" ] && name="${name}_pgo"
        echo ">>> ${name}"
        echo "    PGO=${pgo}  flags:${BASE}${extra}"
        compilar_openmc "$name" "off" "$pgo" "${BASE}${extra}" || ERR=1
    }

    # Itera o fatorial 2^n. start=1 pula o ponto 0 (baseline já compilado).
    _fatorial() {
        local -n _tags=$1
        local -n _flgs=$2
        local start=${3:-0}
        local n=${#_tags[@]}
        local max=$((1 << n))
        local i j tag extra
        for ((i = start; i < max; i++)); do
            tag=""
            extra=""
            for ((j = 0; j < n; j++)); do
                if ((i & (1 << j))); then
                    [ -n "$tag" ] && tag="${tag}_"
                    tag="${tag}${_tags[j]}"
                    extra="${extra} ${_flgs[j]}"
                fi
            done
            _caso "$tag" "$extra" "off"
            _caso "$tag" "$extra" "on"
        done
    }

    echo "--- Baseline (sem flags extras de linker/math) ---"
    _caso "" "" "off"
    _caso "" "" "on"

    echo "--- Fatorial LINKER (2^3 − 1) × ±PGO ---"
    _fatorial LINKER_TAGS LINKER_FLGS 1

    echo "--- Fatorial MATH (2^5 − 1) × ±PGO ---"
    _fatorial MATH_TAGS MATH_FLGS 1

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

    compilar_openmc_default || ERR=1

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






# Fatorial linker/math Native O3 (--compile-fatorial)
if [ "$DO_COMPILE_FATORIAL" = true ]; then
    cd openmc || exit 1
    echo "=========================================="
    echo "COMPILANDO FATORIAL AMD64"
    echo "=========================================="
    if compilar_fatorial_amd64; then
        echo "✅ Fatorial amd64 compilado."
        exit 0
    else
        echo "❌ Falha no fatorial amd64."
        exit 1
    fi
fi


# Flags novas sobre Native O3 oti (--compile-novas)
if [ "$DO_COMPILE_NOVAS" = true ]; then
    cd openmc || exit 1
    echo "=========================================="
    echo "COMPILANDO FLAGS NOVAS AMD64"
    echo "=========================================="
    if teste_flags_novas_amd64; then
        echo "✅ Flags novas amd64 compiladas."
        exit 0
    else
        echo "❌ Falha nas flags novas amd64."
        exit 1
    fi
fi


# Isolamento causal das flags conda-forge (--compile-causal)
if [ "$DO_COMPILE_CAUSAL" = true ]; then
    cd openmc || exit 1
    if compilar_casos_causal; then
        echo "✅ Isolamento causal compilado."
        exit 0
    else
        echo "❌ Falha no isolamento causal."
        exit 1
    fi
fi


# Baixar o binário conda-forge (--compile-conda)
if [ "$DO_COMPILE_CONDA" = true ]; then
    mkdir -p openmc
    cd openmc || exit 1
    echo "=========================================="
    echo "BAIXANDO OPENMC DO CONDA-FORGE"
    echo "=========================================="
    if baixar_openmc_conda; then
        echo "✅ Conda-forge instalado em openmc/build_openmc_conda/"
        exit 0
    else
        echo "❌ Falha ao baixar o OpenMC do conda-forge."
        exit 1
    fi
fi


# Compilar apenas o Release default (--compile-default)
if [ "$DO_COMPILE_DEFAULT" = true ]; then
    cd openmc || exit 1
    echo "=========================================="
    echo "COMPILANDO DEFAULT (CMAKE_BUILD_TYPE=Release)"
    echo "=========================================="
    if compilar_openmc_default; then
        echo "✅ Default compilado."
        exit 0
    else
        echo "❌ Falha na compilação default."
        exit 1
    fi
fi


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




# Executar os diversos casos do openmc (--run ou --run-build)
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
