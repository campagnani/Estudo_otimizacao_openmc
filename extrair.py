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
from matplotlib.patches import Patch

PADROES = {
    "t_init": re.compile(r"Total time for initialization\s*=\s*([\d.eE+-]+)"),
    "t_sim": re.compile(r"Total time in simulation\s*=\s*([\d.eE+-]+)"),
    "t_total": re.compile(r"Total time elapsed\s*=\s*([\d.eE+-]+)"),
    "keff": re.compile(r"Combined k-effective\s*=\s*([\d.eE+-]+)"),
    "leakage": re.compile(r"Leakage Fraction\s*=\s*([\d.eE+-]+)"),
}

# Tokens do nome do binário (estudo.sh) -> rótulo do gráfico
COMPILADORES = {"gcc": "GCC", "clang": "Clang"}

ROTULOS = {
    "gcc": "GCC",
    "clang": "Clang",
    "default": "Default",
    "conda": "Conda",
    "condaflags": "conda-flags",
    "generic": "Generic",
    "genericV2": "Generic v2",
    "genericV3": "Generic v3",
    "genericV4": "Generic v4",
    "native": "Native",
    "Ofast": "Ofast",
    "oti": "oti",
    "nossesp": "no-ssp",
    "nopie": "no-pie",
    "gcsec": "gc-sections",
    "thinlto": "ThinLTO",
    "fpcontract": "fp-contract",
    "pgo": "pgo",
    "flto": "LTO",
    "fnoplt": "fno-plt",
    "fnosi": "no-interposition",
    "fnome": "no-math-errno",
    "fnotm": "no-trapping-math",
    "fnosn": "no-signaling-nans",
    "fnosz": "no-signed-zeros",
    "frecp": "reciprocal-math",
    "NDEBUG": "NDEBUG",
    "linker": "linker",
    "math": "math",
    "linkermath": "linker+math",
    "linkernd": "linker+NDEBUG",
    "mathnd": "math+NDEBUG",
    "NU": "no-unroll",
    "Uauto": "unroll",
    "maxU2": "unroll×2",
    "maxU4": "unroll×4",
    "maxU8": "unroll×8",
}


def compilador_do_arquivo(arquivo: str) -> str | None:
    """openmc_gcc_native_O3.log -> 'gcc'; openmc_conda.log -> None."""
    nome = Path(arquivo).stem
    if nome.startswith("openmc_"):
        nome = nome[len("openmc_") :]
    token = nome.split("_", 1)[0]
    return token if token in COMPILADORES else None


def partes_config(arquivo: str) -> list[str]:
    nome = Path(arquivo).stem
    if nome.startswith("openmc_"):
        nome = nome[len("openmc_") :]
    partes = nome.split("_")
    if partes and partes[0] in COMPILADORES:
        partes = partes[1:]
    return partes


def nome_legivel(arquivo: str, incluir_compilador: bool = False) -> str:
    """openmc_gcc_native_O3_oti_pgo.log -> Native O3 oti pgo (ou GCC Native ...)."""
    corpo = " ".join(ROTULOS.get(p, p) for p in partes_config(arquivo))
    cc = compilador_do_arquivo(arquivo)
    if incluir_compilador and cc:
        return f"{COMPILADORES[cc]} {corpo}".strip()
    return corpo


def dois_compiladores(df: pd.DataFrame) -> bool:
    presentes = set(df["compilador"].dropna().unique())
    return {"gcc", "clang"} <= presentes


def _float(match: re.Match | None) -> float | None:
    return float(match.group(1)) if match else None


def extrair_logs(diretorio: str) -> pd.DataFrame:
    arquivos = sorted(glob.glob(os.path.join(diretorio, "openmc_*.log")))
    if not arquivos:
        arquivos = sorted(glob.glob(os.path.join(diretorio, "*.log")))
    linhas = []
    for caminho in arquivos:
        texto = Path(caminho).read_text(encoding="utf-8", errors="replace")
        linhas.append(
            {
                "arquivo": os.path.basename(caminho),
                "compilador": compilador_do_arquivo(caminho),
                "config": nome_legivel(caminho),
                "t_init": _float(PADROES["t_init"].search(texto)),
                "t_sim": _float(PADROES["t_sim"].search(texto)),
                "t_total": _float(PADROES["t_total"].search(texto)),
                "keff": _float(PADROES["keff"].search(texto)),
                "leakage": _float(PADROES["leakage"].search(texto)),
            }
        )
    df = pd.DataFrame(linhas)
    if df.empty:
        return df
    prefixar = dois_compiladores(df)
    df["config"] = [
        nome_legivel(arq, incluir_compilador=prefixar) for arq in df["arquivo"]
    ]
    return df


def escolher_baseline(df: pd.DataFrame) -> pd.Series | None:
    """Prefere GCC Generic O0; senão qualquer Generic O0; senão o mais lento."""
    exato_gcc = df["arquivo"].str.contains(r"(?:^|_)gcc_generic_O0\.log$", regex=True)
    if exato_gcc.any():
        return df.loc[exato_gcc].iloc[0]
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


# Eixo X: PGO é curva (tracejada), não ponto. Dois PNGs (com O0 e sem O0).
PONTOS_CURVA = [
    "O0",
    "O1",
    "O2",
    "O3",
    "Ofast",
    "O3 oti",
    "Ofast oti",
]
SUFIXO_PONTO = {
    "O0": "O0",
    "O1": "O1",
    "O2": "O2",
    "O3": "O3",
    "Ofast": "Ofast",
    "O3_oti": "O3 oti",
    "Ofast_oti": "Ofast oti",
}
SERIES_ARCH = (
    ("genericV4", "Generic v4"),
    ("genericV3", "Generic v3"),
    ("genericV2", "Generic v2"),
    ("generic", "Generic"),
    ("native", "Native"),
)
ARCH_CORES = {
    "Generic": "#4c72b0",
    "Generic v2": "#dd8452",
    "Generic v3": "#55a868",
    "Generic v4": "#c44e52",
    "Native": "#8172b3",
}
ARCH_MARCADORES = {
    "Generic": "o",
    "Generic v2": "s",
    "Generic v3": "D",
    "Generic v4": "^",
    "Native": "P",
}
COR_BARRA = {"gcc": "#4c72b0", "clang": "#c44e52"}


def rotulo_serie(arch: str, pgo: bool, cc: str | None, prefixar: bool) -> str:
    nome = f"{arch} PGO" if pgo else arch
    if prefixar and cc:
        return f"{COMPILADORES[cc]} {nome}"
    return nome


def ordem_series(prefixar: bool) -> list[str]:
    ccs: list[str | None] = ["gcc", "clang"] if prefixar else [None]
    ordem: list[str] = []
    for pgo in (False, True):
        for _, arch in SERIES_ARCH:
            for cc in ccs:
                ordem.append(rotulo_serie(arch, pgo, cc, prefixar))
    return ordem


def estilo_serie(nome: str) -> dict:
    """Mesma cor/marcador por ISA; Clang = linha pontilhada e marcador oco."""
    pgo = nome.endswith(" PGO")
    base = nome[: -len(" PGO")] if pgo else nome
    cc = None
    if base.startswith("GCC "):
        cc = "gcc"
        base = base[len("GCC ") :]
    elif base.startswith("Clang "):
        cc = "clang"
        base = base[len("Clang ") :]
    color = ARCH_CORES.get(base, "#4c72b0")
    marker = ARCH_MARCADORES.get(base, "o")
    if cc == "clang":
        ls = "-." if pgo else ":"
        return {
            "color": color,
            "marker": marker,
            "ls": ls,
            "mfc": "white",
            "mec": color,
            "lw": 2.2,
        }
    return {
        "color": color,
        "marker": marker,
        "ls": "--" if pgo else "-",
        "mfc": color,
        "mec": color,
        "lw": 2.2,
    }


def coletar_referencias(df: pd.DataFrame) -> list[dict]:
    """Default por compilador (se houver os dois) e Conda, só se o log existir."""
    prefixar = dois_compiladores(df)
    specs: list[tuple[str, str, str, str]] = []
    if prefixar:
        specs.append((r"^openmc_gcc_default\.log$", "Default GCC", "red", "darkred"))
        specs.append((r"^openmc_clang_default\.log$", "Default Clang", "#e67e22", "#a04000"))
    else:
        specs.append((r"(?:^|_)default\.log$", "Default", "red", "darkred"))
    specs.append((r"(?:^|_)conda\.log$", "Conda", "hotpink", "mediumvioletred"))

    refs = []
    for padrao, label, color, edge in specs:
        t_ref = tempo_referencia(df, padrao)
        if t_ref is not None:
            refs.append({"label": label, "color": color, "edge": edge, "t_sim": t_ref})
    return refs


def tempo_referencia(df: pd.DataFrame, padrao_arquivo: str) -> float | None:
    mask = df["arquivo"].str.contains(padrao_arquivo, regex=True)
    if not mask.any():
        return None
    val = df.loc[mask, "t_sim"].iloc[0]
    return float(val) if pd.notna(val) else None


def eixos_com_referencias(
    pontos_eixo: list[str], presentes: list[str]
) -> list[str]:
    """Insere Default/Conda imediatamente depois de Ofast, nessa ordem."""
    eixos = list(pontos_eixo)
    inserir = [lab for lab in presentes if lab not in eixos]
    if not inserir:
        return eixos
    if "Ofast" in eixos:
        i = eixos.index("Ofast") + 1
        for offset, lab in enumerate(inserir):
            eixos.insert(i + offset, lab)
    else:
        eixos.extend(inserir)
    return eixos


def classificar_curva(arquivo: str, prefixar: bool) -> tuple[str, str] | None:
    """openmc_gcc_native_O3_oti_pgo.log -> ('GCC Native PGO', 'O3 oti') se prefixar."""
    cc = compilador_do_arquivo(arquivo)
    resto = "_".join(partes_config(arquivo))
    for prefixo, serie in SERIES_ARCH:
        if resto == prefixo or resto.startswith(prefixo + "_"):
            sufixo = resto[len(prefixo) :].lstrip("_")
            pgo = sufixo.endswith("_pgo")
            if pgo:
                sufixo = sufixo[: -len("_pgo")]
            ponto = SUFIXO_PONTO.get(sufixo)
            if ponto is None:
                return None
            return rotulo_serie(serie, pgo, cc, prefixar), ponto
    return None


def grafico_curvas_opt(df: pd.DataFrame, saida: Path, pontos_eixo: list[str]) -> None:
    """Uma curva por ISA (± PGO) vs. nível de otimização; GCC e Clang se ambos existirem."""
    prefixar = dois_compiladores(df)
    refs = coletar_referencias(df)
    pontos_eixo = eixos_com_referencias(pontos_eixo, [r["label"] for r in refs])
    ordem = ordem_series(prefixar)
    pontos: dict[str, dict[str, float]] = {s: {} for s in ordem}
    for _, row in df.dropna(subset=["t_sim"]).iterrows():
        classif = classificar_curva(row["arquivo"], prefixar)
        if classif is None:
            continue
        serie, ponto = classif
        if ponto not in pontos_eixo:
            continue
        if serie not in pontos:
            pontos[serie] = {}
        pontos[serie][ponto] = float(row["t_sim"])

    series_com_dados = [s for s in ordem if pontos.get(s)]
    if not series_com_dados and not refs:
        print(f"Gráfico de curvas: nenhum ponto em {saida.name}.")
        return

    x_pos = {nome: i for i, nome in enumerate(pontos_eixo)}
    plt.figure(figsize=(14, 8) if prefixar else (12, 7))
    sns.set_style("whitegrid")
    for serie in series_com_dados:
        xs, ys = [], []
        for ponto in pontos_eixo:
            if ponto in pontos[serie]:
                xs.append(x_pos[ponto])
                ys.append(pontos[serie][ponto])
        estilo = estilo_serie(serie)
        plt.plot(
            xs,
            ys,
            label=serie,
            color=estilo["color"],
            marker=estilo["marker"],
            linestyle=estilo["ls"],
            markersize=9,
            linewidth=estilo["lw"],
            markerfacecolor=estilo["mfc"],
            markeredgecolor=estilo["mec"],
            markeredgewidth=1.1,
        )
        for x, y in zip(xs, ys):
            plt.annotate(
                f"{y:.0f}s",
                (x, y),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=7 if prefixar else 8,
            )

    for ref in refs:
        if ref["label"] not in x_pos:
            continue
        x_ref = x_pos[ref["label"]]
        y_ref = ref["t_sim"]
        plt.axhline(
            y=y_ref,
            color=ref["color"],
            linestyle=":",
            linewidth=1.8,
            zorder=1,
        )
        plt.plot(
            x_ref,
            y_ref,
            marker="*",
            color=ref["color"],
            markersize=18,
            linestyle="None",
            label=ref["label"],
            zorder=5,
            markeredgecolor=ref["edge"],
            markeredgewidth=0.6,
        )
        plt.annotate(
            f"{y_ref:.0f}s",
            (x_ref, y_ref),
            textcoords="offset points",
            xytext=(0, 10),
            ha="center",
            fontsize=8,
            color=ref["color"],
            fontweight="bold",
        )

    plt.xticks(range(len(pontos_eixo)), pontos_eixo, rotation=25, ha="right")
    plt.ylabel("Tempo de simulação (s)")
    plt.xlabel("Otimização")
    com_o0 = "O0" in pontos_eixo
    plt.title(
        "Tempo vs. otimização por arquitetura"
        + (" (com O0)" if com_o0 else " (sem O0)")
    )
    plt.legend(
        title="Arquitetura / compilador" if prefixar else "Arquitetura",
        fontsize=7 if prefixar else 8,
        ncol=2 if prefixar else 1,
    )
    plt.tight_layout()
    plt.savefig(saida, dpi=300)
    plt.close()
    print(f"Gráfico de curvas: {saida}")


def grafico_tempos(df: pd.DataFrame, saida: Path) -> None:
    plot_df = df.dropna(subset=["t_sim"]).sort_values("t_sim", ascending=False)
    prefixar = dois_compiladores(df)
    n = len(plot_df)
    plt.figure(figsize=(max(12, n * 0.28), 7))
    cores = [
        COR_BARRA.get(cc if isinstance(cc, str) else "", "#8c8c8c") if prefixar else "#4c72b0"
        for cc in plot_df["compilador"]
    ]
    barras = plt.bar(plot_df["config"], plot_df["t_sim"], color=cores, edgecolor="black")
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
            fontsize=7 if n > 35 else 9,
            fontweight="bold",
        )
    if prefixar:
        plt.legend(
            handles=[
                Patch(facecolor=COR_BARRA["gcc"], edgecolor="black", label="GCC"),
                Patch(facecolor=COR_BARRA["clang"], edgecolor="black", label="Clang"),
            ],
            title="Compilador",
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

    n = len(plot_df)
    plt.figure(figsize=(14, max(8, n * 0.28)))
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
    grafico_curvas_opt(df, saida / "curvas_otimizacao_openmc_com_O0.png", PONTOS_CURVA)
    grafico_curvas_opt(
        df,
        saida / "curvas_otimizacao_openmc.png",
        [p for p in PONTOS_CURVA if p != "O0"],
    )
    baseline = escolher_baseline(df)
    if baseline is None or pd.isna(baseline["t_sim"]):
        print("Sem tempo de simulação para calcular speedup.")
        return
    print(f"Baseline: {baseline['config']} ({baseline['t_sim']:.4f} s)")
    grafico_speedup(df, baseline, saida / "analise_speedup_openmc.png")


if __name__ == "__main__":
    main()
