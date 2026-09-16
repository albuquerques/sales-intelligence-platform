"""
Ponto de entrada do pipeline: uma camada, ou todas, na ordem certa.

Uso:
    python run.py raw --sample   # amostra no DuckDB, sem servidor (roda logo após o clone)
    python run.py raw            # dataset completo no DuckDB
    python run.py staging        # CSV -> validação -> PostgreSQL
    python run.py mart           # staging -> modelo estrela, com verificação
    python run.py tudo           # todas as camadas acima, parando no primeiro erro

Este arquivo não reimplementa nada. Cada etapa é um script de src/ que já roda
sozinho; o que o run.py acrescenta é a ORDEM e a regra de PARAR no primeiro
erro — conhecimento que antes só existia escrito no README.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parent

# Cada camada é uma lista de passos: (script em src/, argumentos...).
#
# O download entra antes de toda camada que lê data/raw/. Repeti-lo é seguro:
# com os CSVs já presentes, ele só confere os checksums e sai. Custa segundos e
# troca um "arquivo não encontrado" no meio do caminho por nada.
#
# Em "tudo", RAW e STAGING leem os MESMOS CSVs — uma não alimenta a outra, são
# os dois níveis independentes do projeto. "tudo" quer dizer toda camada
# construída, não uma corrente em que cada uma lê a anterior. Só a MART depende
# de verdade de quem vem antes: ela lê a STAGING.
DOWNLOAD = ("download_data.py",)
CAMADAS: dict[str, list[tuple[str, ...]]] = {
    "raw":     [DOWNLOAD, ("load_raw.py",)],
    "staging": [DOWNLOAD, ("load_postgres.py",)],
    "mart":    [("build_mart.py",)],
    "tudo":    [DOWNLOAD, ("load_raw.py",), ("load_postgres.py",), ("build_mart.py",)],
}


def roda(passo: tuple[str, ...]) -> int:
    """
    Roda um script de src/ num processo separado e devolve o código de saída.

    Processo separado, e não import, por três motivos concretos:
      - cada script lê os PRÓPRIOS argumentos com argparse; importado, o main()
        dele tentaria ler os argumentos do run.py;
      - os scripts encerram com sys.exit() quando algo falha; importado, esse
        sys.exit derrubaria o run.py no meio, sem dizer onde parou;
      - o código de saída (0 = deu certo) já é o contrato que todos cumprem.
        O run.py só precisa lê-lo.
    """
    script, *args = passo
    # sys.executable, e não "python": garante o mesmo interpretador — e o mesmo
    # ambiente virtual, se houver — que está rodando este arquivo.
    comando = [sys.executable, str(RAIZ / "src" / script), *args]
    return subprocess.run(comando, cwd=RAIZ).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Roda o pipeline: uma camada ou todas.")
    parser.add_argument("camada", choices=CAMADAS, help="qual camada construir")
    parser.add_argument("--sample", action="store_true",
                        help="usa a amostra versionada (so com 'raw')")
    args = parser.parse_args()

    # --sample só vale para a RAW, de propósito. As verificações do
    # build_mart.py esperam os números do dataset completo (96.096 clientes,
    # 112.650 itens): uma STAGING com a amostra faria a MART reprovar — e a
    # carga da amostra já teria apagado a STAGING completa antes disso.
    if args.sample and args.camada != "raw":
        parser.error("--sample so vale para 'raw': a MART verifica contra os numeros "
                     "do dataset completo. Para a amostra no PostgreSQL, rode direto: "
                     "python src/load_postgres.py --sample")

    passos = [("load_raw.py", "--sample")] if args.sample else CAMADAS[args.camada]

    feitos: list[tuple[str, float]] = []
    for i, passo in enumerate(passos, start=1):
        nome = " ".join(passo)
        # flush: o script filho escreve direto no console, sem passar pelo
        # buffer deste processo. Sem descarregar antes, o cabeçalho da etapa
        # pode aparecer DEPOIS da saída dela.
        print(f"\n==> [{i}/{len(passos)}] {nome}\n", flush=True)

        inicio = time.perf_counter()
        codigo = roda(passo)
        feitos.append((nome, time.perf_counter() - inicio))

        if codigo != 0:
            print(f"\nFALHOU em {nome} (codigo {codigo}).")
            restantes = [" ".join(p) for p in passos[i:]]
            if restantes:
                print("NAO rodaram: " + ", ".join(restantes))
            return codigo

    print("\nResumo")
    for nome, segundos in feitos:
        print(f"  OK  {nome:<24} {segundos:6.1f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
