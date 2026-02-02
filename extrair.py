import glob
import re
import os

def extrair_dados_openmc(diretorio_logs):
    # Padrão de busca para os arquivos .log
    caminho_busca = os.path.join(diretorio_logs, "*.log")
    arquivos = glob.glob(caminho_busca)
    
    # Lista principal para armazenar os resultados
    # Formato: [Nome, Init Time, Sim Time, Elapsed Time, K-eff, Leakage]
    info = []

    # Compilando as regex para performance e clareza
    # Captura o número após o "=" e ignora o resto (unidades ou +/-)
    padroes = {
        'init_time': re.compile(r"Total time for initialization\s*=\s*([\d\.eE\+\-]+)"),
        'sim_time':  re.compile(r"Total time in simulation\s*=\s*([\d\.eE\+\-]+)"),
        'elapsed':   re.compile(r"Total time elapsed\s*=\s*([\d\.eE\+\-]+)"),
        'k_eff':     re.compile(r"Combined k-effective\s*=\s*([\d\.eE\+\-]+)"),
        'leakage':   re.compile(r"Leakage Fraction\s*=\s*([\d\.eE\+\-]+)")
    }

    print(f"Encontrados {len(arquivos)} arquivos de log em '{diretorio_logs}'. Processando...\n")

    for arquivo_path in sorted(arquivos):
        nome_arquivo = os.path.basename(arquivo_path)
        
        try:
            with open(arquivo_path, 'r', encoding='utf-8') as f:
                conteudo = f.read()
                
                # Função auxiliar para buscar e converter para float
                def buscar_valor(chave):
                    match = padroes[chave].search(conteudo)
                    return float(match.group(1)) if match else None

                # Extração dos dados
                t_init = buscar_valor('init_time')
                t_sim = buscar_valor('sim_time')
                t_elapsed = buscar_valor('elapsed')
                keff = buscar_valor('k_eff')
                leakage = buscar_valor('leakage')

                # Adiciona à lista info
                info.append([nome_arquivo, t_init, t_sim, t_elapsed, keff, leakage])

        except Exception as e:
            print(f"Erro ao ler {nome_arquivo}: {e}")

    return info

# --- Configuração ---
# Como você mostrou 'ls log', assumo que os arquivos estão na pasta 'log'
pasta_dos_logs = "log" 

# --- Execução ---
dados_extraidos = extrair_dados_openmc(pasta_dos_logs)

# --- Exibição dos Resultados ---
# Cabeçalho para visualização
header = ["Arquivo", "T. Init(s)", "T. Sim(s)", "T. Total(s)", "K-eff", "Leakage"]

print(f"{header[0]:<40} | {header[1]:<10} | {header[2]:<10} | {header[3]:<10} | {header[4]:<8} | {header[5]:<8}")
print("-" * 110)

for linha in dados_extraidos:
    # Formatação para exibição limpa (o dado bruto na lista 'dados_extraidos' continua numérico)
    fn, ti, ts, tt, ke, lk = linha
    print(f"{fn:<40} | {ti:<10.4f} | {ts:<10.4f} | {tt:<10.4f} | {ke:<8.5f} | {lk:<8.5f}")

# A variável 'dados_extraidos' agora contém sua lista de listas conforme solicitado:
# info[n] = [nome, init, sim, elapsed, keff, leakage]











import glob
import re
import os
import pandas as pd
import matplotlib.pyplot as plt

# --- 1. Função de Extração (Mesma lógica anterior) ---
def extrair_dados_openmc(diretorio_logs):
    caminho_busca = os.path.join(diretorio_logs, "*.log")
    arquivos = glob.glob(caminho_busca)
    
    dados = []
    # Regex para capturar o tempo de simulação
    regex_sim_time = re.compile(r"Total time in simulation\s*=\s*([\d\.eE\+\-]+)")

    print(f"Lendo {len(arquivos)} arquivos em '{diretorio_logs}'...")

    for arquivo_path in arquivos:
        nome_arquivo = os.path.basename(arquivo_path)
        try:
            with open(arquivo_path, 'r', encoding='utf-8') as f:
                conteudo = f.read()
                match = regex_sim_time.search(conteudo)
                if match:
                    tempo = float(match.group(1))
                    # Limpa o nome para o gráfico (remove prefixo e extensão)
                    nome_limpo = nome_arquivo.replace("openmc_", "").replace(".log", "")
                    dados.append({'Nome': nome_limpo, 'Tempo Simulação (s)': tempo})
        except Exception as e:
            print(f"Erro em {nome_arquivo}: {e}")

    return dados

# --- 2. Processamento dos Dados ---
pasta_dos_logs = "log"  # Ajuste se necessário
dados = extrair_dados_openmc(pasta_dos_logs)

if not dados:
    print("Nenhum dado encontrado. Verifique o caminho da pasta.")
    exit()

# Cria DataFrame
df = pd.DataFrame(dados)

# Ordena do MAIOR para o MENOR tempo (Decrescente)
df = df.sort_values(by='Tempo Simulação (s)', ascending=False)

# --- 3. Geração do Gráfico ---
plt.figure(figsize=(12, 7))

# Cria as barras
barras = plt.bar(df['Nome'], df['Tempo Simulação (s)'], color='#4c72b0', edgecolor='black')

# Títulos e Rótulos
plt.ylabel('Tempo de Simulação (s)', fontsize=12)
plt.title('Comparativo de Performance de Compilação OpenMC\n(Ordem Decrescente de Tempo)', fontsize=14, pad=20)

# Ajuste do Eixo X (Rotação dos nomes longos)
plt.xticks(rotation=45, ha='right', fontsize=10)

# Adiciona o valor do tempo em cima de cada barra
max_y = df['Tempo Simulação (s)'].max()
for barra in barras:
    altura = barra.get_height()
    plt.text(
        barra.get_x() + barra.get_width() / 2, 
        altura + (max_y * 0.01),  # Um pouco acima da barra
        f'{altura:.1f}s', 
        ha='center', va='bottom', fontsize=9, fontweight='bold'
    )

# Ajusta margens para não cortar os nomes
plt.tight_layout()

# Salva e Mostra
nome_saida = "benchmark_openmc.png"
plt.savefig(nome_saida, dpi=300)
print(f"Gráfico salvo como '{nome_saida}'")
plt.show()



import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

# Dados extraídos do seu resultado
data = [
    ["Generic O0", 356.00],
    ["Generic O1", 355.23],
    ["Generic O2", 355.87],
    ["Generic O3", 351.84],
    ["Generic v2 O3", 356.34],
    ["Generic v3 O3", 350.39],
    ["Native O3", 350.04],
    ["Native O3 oti", 312.93],
    ["Native O3 oti unroll", 317.00],
    ["Native O3 oti unroll xmid", 318.40],
    ["Native O3 oti xmid", 312.59], # Melhor
    ["Native O3 unroll", 351.97],
    ["Native Ofast oti unroll xmid", 318.55],
    ["Native Ofast oti xmid", 313.94]
]

df = pd.DataFrame(data, columns=["Configuracao", "Tempo_Simulacao"])

# 1. Definir o Baseline (Generic O0)
baseline_time = df[df["Configuracao"] == "Generic O0"]["Tempo_Simulacao"].values[0]

# 2. Calcular Speedup (Baseline / Tempo Atual)
df["Speedup"] = baseline_time / df["Tempo_Simulacao"]

# 3. Calcular Ganho Percentual
df["Ganho_Percentual"] = (df["Speedup"] - 1) * 100

# Ordenar pelo Speedup (do maior para o menor)
df = df.sort_values(by="Speedup", ascending=False)

# --- Plotagem ---
plt.figure(figsize=(14, 8))
sns.set_style("whitegrid")

# Criar gráfico de barras horizontais
ax = sns.barplot(x="Speedup", y="Configuracao", data=df, palette="viridis")

# Linha de referência no 1.0 (Baseline)
plt.axvline(x=1.0, color='red', linestyle='--', label='Baseline (O0)')

# Adicionar rótulos nas barras
for i, p in enumerate(ax.patches):
    width = p.get_width()
    # Pega o ganho percentual correspondente
    ganho = df.iloc[i]["Ganho_Percentual"]
    tempo = df.iloc[i]["Tempo_Simulacao"]
    
    texto = f"{width:.2f}x (+{ganho:.1f}%) [{tempo:.1f}s]"
    ax.text(width + 0.01, p.get_y() + p.get_height()/2, texto, 
            va='center', fontsize=10, fontweight='bold', color='#333333')

plt.title("Speedup Relativo ao 'Generic O0' (Maior é Melhor)", fontsize=16, pad=20)
plt.xlabel("Fator de Speedup (x vezes mais rápido)", fontsize=12)
plt.ylabel("Configuração de Compilação", fontsize=12)
plt.xlim(0.95, df["Speedup"].max() * 1.15) # Espaço extra para o texto
plt.tight_layout()

plt.savefig("analise_speedup_openmc.png", dpi=300)
plt.show()