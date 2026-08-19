"""
Gera a amostra versionada (data/sample/) e o manifesto de integridade.

Este script roda em cima do dataset completo, então só quem mantém o projeto
precisa executá-lo — quem clona o repo já recebe a amostra pronta.

Uso:
    python src/make_sample.py                # 3000 pedidos, semente fixa
    python src/make_sample.py --orders 5000
    python src/make_sample.py --manifest-only

O PONTO CENTRAL: INTEGRIDADE REFERENCIAL
-----------------------------------------
Pegar "as primeiras 1000 linhas de cada CSV" produz uma amostra inútil: os
order_id de order_items não existiriam em orders e todo JOIN voltaria vazio.

Aqui a amostragem é em cascata. Sorteamos um conjunto de PEDIDOS e derivamos
todo o resto a partir dele:

    orders (sorteio)
      +-- customers    : só os clientes desses pedidos
      +-- order_items  : só os itens desses pedidos
      |     +-- products : só os produtos que aparecem nesses itens
      |     +-- sellers  : só os vendedores que aparecem nesses itens
      +-- order_payments : só os pagamentos desses pedidos
      +-- order_reviews  : só as avaliações desses pedidos

O resultado é um "mini-Olist" coerente: os mesmos JOINs do dataset completo
funcionam, com os mesmos problemas de qualidade preservados.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from datetime import datetime, timezone
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
RAW_DIR = PROJECT_ROOT / "data" / "raw"
SAMPLE_DIR = PROJECT_ROOT / "data" / "sample"
MANIFEST_PATH = PROJECT_ROOT / "data" / "manifest.json"

CSV = {
    "customers":    "olist_customers_dataset.csv",
    "geolocation":  "olist_geolocation_dataset.csv",
    "order_items":  "olist_order_items_dataset.csv",
    "payments":     "olist_order_payments_dataset.csv",
    "reviews":      "olist_order_reviews_dataset.csv",
    "orders":       "olist_orders_dataset.csv",
    "products":     "olist_products_dataset.csv",
    "sellers":      "olist_sellers_dataset.csv",
    "translation":  "product_category_name_translation.csv",
}

# Quantos pontos de geolocalização manter por prefixo de CEP. O arquivo cheio
# tem ~1M de linhas para 19 mil prefixos; sem esse corte a amostra passaria de
# 100 MB e perderia o propósito.
GEO_POINTS_PER_ZIP = 3


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def check_raw() -> None:
    faltando = [name for name in CSV.values() if not (RAW_DIR / name).exists()]
    if faltando:
        print(f"Dataset completo ausente em {RAW_DIR}:")
        for name in faltando:
            print(f"  - {name}")
        sys.exit("\nRode antes: python src/download_data.py")


def register_views(con: duckdb.DuckDBPyConnection) -> None:
    """Expõe cada CSV bruto como uma view, sem copiar nada para o disco."""
    for alias, filename in CSV.items():
        path = (RAW_DIR / filename).as_posix()
        con.execute(
            f"CREATE OR REPLACE VIEW src_{alias} AS "
            f"SELECT * FROM read_csv('{path}', all_varchar = true, header = true)"
        )


def build_sample(con: duckdb.DuckDBPyConnection, n_orders: int, seed: float) -> None:
    SAMPLE_DIR.mkdir(parents=True, exist_ok=True)

    # setseed torna o sorteio reprodutível: mesma semente, mesma amostra.
    # Sem isso, cada execução geraria um diff enorme no git.
    con.execute(f"SELECT setseed({seed})")
    con.execute(
        f"""
        CREATE OR REPLACE TABLE picked_orders AS
        SELECT * FROM src_orders USING SAMPLE {n_orders} ROWS (reservoir)
        """
    )

    # Cada consulta abaixo é derivada de picked_orders — nunca de um LIMIT solto.
    queries = {
        "olist_orders_dataset.csv": "SELECT * FROM picked_orders",
        "olist_customers_dataset.csv": """
            SELECT c.* FROM src_customers c
            WHERE c.customer_id IN (SELECT customer_id FROM picked_orders)
        """,
        "olist_order_items_dataset.csv": """
            SELECT i.* FROM src_order_items i
            WHERE i.order_id IN (SELECT order_id FROM picked_orders)
        """,
        "olist_order_payments_dataset.csv": """
            SELECT p.* FROM src_payments p
            WHERE p.order_id IN (SELECT order_id FROM picked_orders)
        """,
        "olist_order_reviews_dataset.csv": """
            SELECT r.* FROM src_reviews r
            WHERE r.order_id IN (SELECT order_id FROM picked_orders)
        """,
        "olist_products_dataset.csv": """
            SELECT pr.* FROM src_products pr
            WHERE pr.product_id IN (
                SELECT i.product_id FROM src_order_items i
                WHERE i.order_id IN (SELECT order_id FROM picked_orders)
            )
        """,
        "olist_sellers_dataset.csv": """
            SELECT s.* FROM src_sellers s
            WHERE s.seller_id IN (
                SELECT i.seller_id FROM src_order_items i
                WHERE i.order_id IN (SELECT order_id FROM picked_orders)
            )
        """,
        # Tabela de domínio com 71 linhas: vai inteira, cortar não economiza nada.
        "product_category_name_translation.csv": "SELECT * FROM src_translation",
        # Só os CEPs que aparecem na amostra, e no máximo N pontos por CEP.
        "olist_geolocation_dataset.csv": f"""
            SELECT g.* FROM src_geolocation g
            WHERE g.geolocation_zip_code_prefix IN (
                SELECT c.customer_zip_code_prefix FROM src_customers c
                WHERE c.customer_id IN (SELECT customer_id FROM picked_orders)
                UNION
                SELECT s.seller_zip_code_prefix FROM src_sellers s
                WHERE s.seller_id IN (
                    SELECT i.seller_id FROM src_order_items i
                    WHERE i.order_id IN (SELECT order_id FROM picked_orders)
                )
            )
            QUALIFY row_number() OVER (
                PARTITION BY g.geolocation_zip_code_prefix ORDER BY g.geolocation_lat
            ) <= {GEO_POINTS_PER_ZIP}
        """,
    }

    print(f"Gerando amostra de {n_orders:,} pedidos em {SAMPLE_DIR}\n")
    total_bytes = 0
    for filename, query in queries.items():
        out = SAMPLE_DIR / filename
        con.execute(f"COPY ({query}) TO '{out.as_posix()}' (HEADER, DELIMITER ',')")
        linhas = con.execute(f"SELECT count(*) FROM ({query})").fetchone()[0]
        tamanho = out.stat().st_size
        total_bytes += tamanho
        print(f"  {filename:<45} {linhas:>8,} linhas  {tamanho / 1024:>8.1f} KB")

    print(f"\nAmostra total: {total_bytes / 1024 / 1024:.1f} MB")


def verify_sample(con: duckdb.DuckDBPyConnection) -> bool:
    """
    Confere que a amostra não tem referência órfã.

    É o teste que prova que a cascata funcionou: se algum JOIN essencial
    apontar para uma linha inexistente, a amostra está quebrada e não adianta
    commitar.
    """
    checks = {
        "order_items -> orders": """
            SELECT count(*) FROM read_csv('{d}/olist_order_items_dataset.csv', all_varchar=true) i
            LEFT JOIN read_csv('{d}/olist_orders_dataset.csv', all_varchar=true) o USING (order_id)
            WHERE o.order_id IS NULL
        """,
        "orders -> customers": """
            SELECT count(*) FROM read_csv('{d}/olist_orders_dataset.csv', all_varchar=true) o
            LEFT JOIN read_csv('{d}/olist_customers_dataset.csv', all_varchar=true) c USING (customer_id)
            WHERE c.customer_id IS NULL
        """,
        "order_items -> products": """
            SELECT count(*) FROM read_csv('{d}/olist_order_items_dataset.csv', all_varchar=true) i
            LEFT JOIN read_csv('{d}/olist_products_dataset.csv', all_varchar=true) p USING (product_id)
            WHERE p.product_id IS NULL
        """,
        "order_items -> sellers": """
            SELECT count(*) FROM read_csv('{d}/olist_order_items_dataset.csv', all_varchar=true) i
            LEFT JOIN read_csv('{d}/olist_sellers_dataset.csv', all_varchar=true) s USING (seller_id)
            WHERE s.seller_id IS NULL
        """,
    }

    print("\nVerificando integridade referencial da amostra:")
    ok = True
    d = SAMPLE_DIR.as_posix()
    for nome, sql in checks.items():
        orfas = con.execute(sql.format(d=d)).fetchone()[0]
        status = "OK " if orfas == 0 else "FALHA"
        if orfas:
            ok = False
        print(f"  {status} {nome:<28} {orfas} referencias orfas")
    return ok


def count_rows(path: Path) -> int:
    """
    Conta REGISTROS do CSV, não linhas do arquivo.

    A distinção importa em olist_order_reviews_dataset.csv: os comentários dos
    clientes contêm quebras de linha dentro de campos entre aspas, então um
    registro pode ocupar várias linhas físicas. Contar linhas dava 104.719
    quando o arquivo tem 99.224 registros — 5.495 a mais, e o manifesto
    contradizia o dicionário de dados e o load_raw.py, que estavam certos.

    O módulo csv respeita as aspas e junta as linhas do mesmo registro.
    """
    with path.open("r", encoding="utf-8", errors="replace", newline="") as f:
        return sum(1 for _ in csv.reader(f)) - 1  # menos o cabeçalho


def write_manifest(n_orders: int) -> None:
    """Registra tamanho, sha256 e registros de cada CSV bruto, para download_data.py validar."""
    files = {}
    for filename in sorted(CSV.values()):
        path = RAW_DIR / filename
        linhas = count_rows(path)
        files[filename] = {
            "bytes": path.stat().st_size,
            "rows": linhas,
            "sha256": sha256(path),
        }
        print(f"  {filename:<45} {linhas:>9,} linhas  sha256 {files[filename]['sha256'][:12]}...")

    manifest = {
        "dataset": "Olist Brazilian E-Commerce Public Dataset",
        "source": "https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce",
        "license": "CC BY-NC-SA 4.0",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sample_orders": n_orders,
        "files": files,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"\nManifesto escrito em {MANIFEST_PATH}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Gera a amostra versionada e o manifesto.")
    parser.add_argument("--orders", type=int, default=3000, help="quantos pedidos sortear (padrao 3000)")
    parser.add_argument("--seed", type=float, default=0.42, help="semente do sorteio, entre -1 e 1")
    parser.add_argument("--manifest-only", action="store_true", help="so regenera o manifesto")
    args = parser.parse_args()

    check_raw()
    con = duckdb.connect()
    try:
        if not args.manifest_only:
            register_views(con)
            build_sample(con, args.orders, args.seed)
            if not verify_sample(con):
                print("\nAmostra com referencias orfas - nao commite. Investigue a cascata.")
                return 1

        print("\nGerando manifesto do dataset completo:")
        write_manifest(args.orders)
    finally:
        con.close()

    print("\nPronto. Commite data/sample/ e data/manifest.json.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
