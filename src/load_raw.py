"""
Carga dos CSVs para a camada RAW do DuckDB.

Uso:
    python src/load_raw.py              # carrega data/raw/ (dataset completo)
    python src/load_raw.py --sample     # carrega data/sample/ (amostra do repo)
    python src/load_raw.py --db meu.duckdb

O banco gerado é um artefato: está no .gitignore e pode ser reconstruído a
qualquer momento rodando este script de novo.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# O console do Windows usa cp1252 por padrão e quebra ao imprimir acentos.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

try:
    import duckdb
except ModuleNotFoundError:
    sys.exit("duckdb nao instalado. Rode: pip install -r requirements.txt")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DDL_PATH = PROJECT_ROOT / "sql" / "01_create_raw_tables.sql"
DEFAULT_DB = PROJECT_ROOT / "sales_intelligence.duckdb"

# tabela RAW  ->  (arquivo CSV, linhas esperadas no dataset completo)
# A contagem esperada vem do profiling em docs/data_dictionary.md e serve de
# alarme: se a carga trouxer um número diferente, algo mudou na origem ou o
# parser quebrou em alguma linha.
TABLES: dict[str, tuple[str, int]] = {
    "customers":                    ("olist_customers_dataset.csv",          99_441),
    "orders":                       ("olist_orders_dataset.csv",             99_441),
    "order_items":                  ("olist_order_items_dataset.csv",       112_650),
    "order_payments":               ("olist_order_payments_dataset.csv",    103_886),
    "order_reviews":                ("olist_order_reviews_dataset.csv",      99_224),
    "products":                     ("olist_products_dataset.csv",           32_951),
    "sellers":                      ("olist_sellers_dataset.csv",             3_095),
    "product_category_translation": ("product_category_name_translation.csv",    71),
    "geolocation":                  ("olist_geolocation_dataset.csv",     1_000_163),
}


def create_schema(con: duckdb.DuckDBPyConnection) -> None:
    if not DDL_PATH.exists():
        sys.exit(f"DDL nao encontrado: {DDL_PATH}")
    con.execute(DDL_PATH.read_text(encoding="utf-8"))
    print(f"Schema aplicado a partir de {DDL_PATH.name}")


def load_table(con: duckdb.DuckDBPyConnection, table: str, csv_path: Path) -> int:
    """
    Carrega um CSV na tabela raw.<table> e devolve a contagem de linhas.

    Detalhes que importam:

    - all_varchar=true faz o DuckDB parar de inferir tipos e trazer tudo como
      texto, casando com o DDL. Sem isso ele adivinharia (às vezes errado, ex:
      um CEP virando inteiro e perdendo o zero à esquerda).

    - O INSERT é POSICIONAL: as colunas entram na ordem do arquivo, não pelo
      nome. É por isso que o BOM no cabeçalho de
      product_category_name_translation.csv não causa problema aqui — mesmo que
      o nome da primeira coluna chegue sujo, a posição está certa.

    - DELETE antes do INSERT torna o script idempotente: rodar duas vezes não
      duplica dados.
    """
    con.execute(f"DELETE FROM raw.{table}")
    con.execute(
        f"""
        INSERT INTO raw.{table}
        SELECT *, ?, now()
        FROM read_csv(?, all_varchar = true, header = true)
        """,
        [csv_path.name, str(csv_path)],
    )
    return con.execute(f"SELECT count(*) FROM raw.{table}").fetchone()[0]


def main() -> int:
    parser = argparse.ArgumentParser(description="Carrega os CSVs na camada RAW.")
    parser.add_argument("--sample", action="store_true", help="usa data/sample/ em vez de data/raw/")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="caminho do arquivo .duckdb")
    args = parser.parse_args()

    src_dir = PROJECT_ROOT / "data" / ("sample" if args.sample else "raw")
    if not src_dir.exists():
        print(f"Diretorio nao encontrado: {src_dir}")
        print("Rode antes: python src/download_data.py")
        return 1

    print(f"Origem : {src_dir}")
    print(f"Destino: {args.db}\n")

    con = duckdb.connect(str(args.db))
    try:
        create_schema(con)
        print()

        total = 0
        divergencias = []

        for table, (csv_name, esperado) in TABLES.items():
            csv_path = src_dir / csv_name
            if not csv_path.exists():
                print(f"  PULADO   raw.{table:<30} ({csv_name} ausente)")
                continue

            try:
                linhas = load_table(con, table, csv_path)
            except duckdb.Error as exc:
                # Erro de parsing aqui quase sempre significa arquivo truncado,
                # corrompido no download ou com separador diferente. A mensagem
                # crua do DuckDB é longa demais, então mostramos só a 1a linha
                # junto do arquivo culpado.
                primeira_linha = str(exc).strip().splitlines()[0]
                print(f"  FALHOU   raw.{table:<30} {csv_name}")
                print(f"           {primeira_linha}")
                print(f"           Verifique o arquivo com: python src/download_data.py --force")
                return 1

            total += linhas

            # Na amostra a contagem é menor de propósito, então só comparamos
            # com o esperado quando estamos carregando o dataset completo.
            if not args.sample and linhas != esperado:
                marca = "  <-- divergente"
                divergencias.append(f"raw.{table}: esperado {esperado:,}, obtido {linhas:,}")
            else:
                marca = ""
            print(f"  OK       raw.{table:<30} {linhas:>9,} linhas{marca}")

        print(f"\n{total:,} linhas carregadas em {args.db.name}")

        if divergencias:
            print("\nAtencao - contagens diferentes do profiling documentado:")
            for d in divergencias:
                print(f"  - {d}")

        print("\nInspecione com:")
        print(f"  python -c \"import duckdb;print(duckdb.connect('{args.db.name}').sql('FROM raw.orders LIMIT 5'))\"")
    finally:
        con.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
