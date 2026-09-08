#!/usr/bin/env python3
"""Lê os logs do estudo OpenMC, imprime a tabela e gera os gráficos.

Uso:
  python3 extrair.py
  python3 extrair.py --logs log --saida resultados
"""

from __future__ import annotations

import argparse
import glob
import os
import re
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

PADROES = {
    "t_init": re.compile(r"Total time for initialization\s*=\s*([\d.eE+-]+)"),
    "t_sim": re.compile(r"Total time in simulation\s*=\s*([\d.eE+-]+)"),
    "t_total": re.compile(r"Total time elapsed\s*=\s*([\d.eE+-]+)"),
    "keff": re.compile(r"Combined k-effective\s*=\s*([\d.eE+-]+)"),
    "leakage": re.compile(r"Leakage Fraction\s*=\s*([\d.eE+-]+)"),
}

# Tokens do nome do binário (estudo.sh) -> rótulo do gráfico
ROTULOS = {
    "generic": "Generic",
    "genericV2": "Generic v2",
    "genericV3": "Generic v3",
    "native": "Native",
    "Ofast": "Ofast",
    "oti": "oti",
    "pgo": "pgo",
    "NU": "no-unroll",
    "Uauto": "unroll",
    "maxU2": "unroll×2",
    "maxU4": "unroll×4",
    "maxU8": "unroll×8",
}


def nome_legivel(arquivo: str) -> str:
    """openmc_gcc_native_O3_oti_pgo.log -> Native O3 oti pgo"""
    nome = Path(arquivo).stem
    if nome.startswith("openmc_"):
        nome = nome[len("openmc_") :]
    partes = nome.split("_")
    if partes and partes[0] in {"gcc", "clang"}:
        partes = partes[1:]
    return " ".join(ROTULOS.get(p, p) for p in partes)


def _float(match: re.Match | None) -> float | None:
    return float(match.group(1)) if match else None


def extrair_logs(diretorio: str) -> pd.DataFrame:
    arquivos = sorted(glob.glob(os.path.join(diretorio, "*.log")))
    linhas = []
    for caminho in arquivos:
        texto = Path(caminho).read_text(encoding="utf-8", errors="replace")
        linhas.append(
            {
                "arquivo": os.path.basename(caminho),
                "config": nome_legivel(caminho),
                "t_init": _float(PADROES["t_init"].search(texto)),
                "t_sim": _float(PADROES["t_sim"].search(texto)),
                "t_total": _float(PADROES["t_total"].search(texto)),
                "keff": _float(PADROES["keff"].search(texto)),
                "leakage": _float(PADROES["leakage"].search(texto)),
            }
        )
    return pd.DataFrame(linhas)


def escolher_baseline(df: pd.DataFrame) -> pd.Series | None:
    """Prefere Generic O0 (sem v2/v3); senão, o caso mais lento."""
    exato = df["arquivo"].str.contains(r"(?:^|_)generic_O0\.log$", regex=True)
    if exato.any():
        return df.loc[exato].iloc[0]
    validos = df.dropna(subset=["t_sim"])
    if validos.empty:
        return None
    return validos.loc[validos["t_sim"].idxmax()]


def imprimir_tabela(df: pd.DataFrame) -> None:
    header = ["Arquivo", "T. Init(s)", "T. Sim(s)", "T. Total(s)", "K-eff", "Leakage"]
    print(f"{header[0]:<44} | {header[1]:<10} | {header[2]:<10} | {header[3]:<10} | {header[4]:<8} | {header[5]:<8}")
    print("-" * 114)
    for _, row in df.iterrows():
        def fmt(valor, spec):
            return format(valor, spec) if pd.notna(valor) else "—"

        print(
            f"{row['arquivo']:<44} | {fmt(row['t_init'], '<10.4f')} | "
            f"{fmt(row['t_sim'], '<10.4f')} | {fmt(row['t_total'], '<10.4f')} | "
            f"{fmt(row['keff'], '<8.5f')} | {fmt(row['leakage'], '<8.5f')}"
        )


def grafico_tempos(df: pd.DataFrame, saida: Path) -> None:
    plot_df = df.dropna(subset=["t_sim"]).sort_values("t_sim", ascending=False)
    plt.figure(figsize=(12, 7))
    barras = plt.bar(plot_df["config"], plot_df["t_sim"], color="#4c72b0", edgecolor="black")
    plt.ylabel("Tempo de simulação (s)")
    plt.title("Comparativo de performance OpenMC")
    plt.xticks(rotation=45, ha="right")
    max_y = plot_df["t_sim"].max()
    for barra, valor in zip(barras, plot_df["t_sim"]):
        plt.text(
            barra.get_x() + barra.get_width() / 2,
            valor + max_y * 0.01,
            f"{valor:.1f}s",
            ha="center",
            va="bottom",
            fontsize=9,
            fontweight="bold",
        )
    plt.tight_layout()
    plt.savefig(saida, dpi=300)
    plt.close()
    print(f"Gráfico de tempos: {saida}")


def grafico_speedup(df: pd.DataFrame, baseline: pd.Series, saida: Path) -> None:
    plot_df = df.dropna(subset=["t_sim"]).copy()
    plot_df["speedup"] = baseline["t_sim"] / plot_df["t_sim"]
    plot_df["ganho_pct"] = (plot_df["speedup"] - 1.0) * 100.0
    plot_df = plot_df.sort_values("speedup", ascending=False)

    plt.figure(figsize=(14, 8))
    sns.set_style("whitegrid")
    ax = sns.barplot(
        data=plot_df,
        x="speedup",
        y="config",
        hue="config",
        palette="viridis",
        legend=False,
    )
    plt.axvline(x=1.0, color="red", linestyle="--", label=f"Baseline ({baseline['config']})")
    for barra, (_, row) in zip(ax.patches, plot_df.iterrows()):
        ax.text(
            barra.get_width() + 0.01,
            barra.get_y() + barra.get_height() / 2,
            f"{row['speedup']:.2f}x ({row['ganho_pct']:+.1f}%) [{row['t_sim']:.1f}s]",
            va="center",
            fontsize=10,
            fontweight="bold",
            color="#333333",
        )
    plt.title(f"Speedup relativo a '{baseline['config']}' (maior é melhor)")
    plt.xlabel("Fator de speedup")
    plt.ylabel("Configuração")
    plt.xlim(0.95, plot_df["speedup"].max() * 1.18)
    plt.legend()
    plt.tight_layout()
    plt.savefig(saida, dpi=300)
    plt.close()
    print(f"Gráfico de speedup: {saida}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Extrai métricas dos logs do OpenMC e gera gráficos.")
    parser.add_argument("--logs", default="log", help="Pasta com os arquivos .log (padrão: log)")
    parser.add_argument("--saida", default=".", help="Pasta onde gravar CSV e PNGs (padrão: .)")
    args = parser.parse_args()

    df = extrair_logs(args.logs)
    if df.empty:
        print(f"Nenhum .log em '{args.logs}'.")
        raise SystemExit(1)

    print(f"Encontrados {len(df)} arquivos em '{args.logs}'.\n")
    imprimir_tabela(df)

    saida = Path(args.saida)
    saida.mkdir(parents=True, exist_ok=True)
    csv_path = saida / "resultados_openmc.csv"
    df.to_csv(csv_path, index=False)
    print(f"\nCSV: {csv_path}")

    grafico_tempos(df, saida / "benchmark_openmc.png")
    baseline = escolher_baseline(df)
    if baseline is None or pd.isna(baseline["t_sim"]):
        print("Sem tempo de simulação para calcular speedup.")
        return
    print(f"Baseline: {baseline['config']} ({baseline['t_sim']:.4f} s)")
    grafico_speedup(df, baseline, saida / "analise_speedup_openmc.png")


if __name__ == "__main__":
    main()
