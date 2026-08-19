"""
Pipeline CSV -> pandas -> validacao -> PostgreSQL.

Uso:
    python src/load_postgres.py --sample       # amostra versionada (data/sample/)
    python src/load_postgres.py                # dataset completo (data/raw/)
    python src/load_postgres.py --check-only   # so valida, nao grava nada

Diferenca para o load_raw.py: la o DuckDB le o CSV sozinho, dentro do INSERT, e
o dado nunca passa pela memoria do Python. Aqui ele passa por um DataFrame de
proposito -- e esse DataFrame e o unico lugar onde da para OLHAR o dado antes de
grava-lo. E ali que a validacao acontece.

Requer um servidor PostgreSQL rodando e um arquivo .env com as credenciais
(copie o .env.example). Ver secao "PostgreSQL" no README.
"""

from __future__ import annotations

import argparse
import io
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

# O console do Windows usa cp1252 por padrao e quebra ao imprimir acentos.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

try:
    import pandas as pd
    import psycopg
except ModuleNotFoundError as exc:
    sys.exit(f"Dependencia ausente ({exc.name}). Rode: pip install -r requirements.txt")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DDL_PATH = PROJECT_ROOT / "sql" / "02_create_postgres_tables.sql"
ENV_PATH = PROJECT_ROOT / ".env"
SCHEMA = "staging"

# Os 8 status do dataset completo. A amostra so contem 6 (faltam 'approved' e
# 'created'), entao a lista vem do profiling do dataset inteiro -- validar
# contra o que esta no arquivo carregado nao validaria nada.
STATUS_VALIDOS = frozenset({
    "delivered", "shipped", "canceled", "unavailable",
    "invoiced", "processing", "created", "approved",
})


# =============================================================================
# Configuracao das tabelas
# =============================================================================

@dataclass(frozen=True)
class Tabela:
    """Tudo que o pipeline precisa saber sobre uma tabela, num lugar so."""

    nome: str
    csv: str
    colunas: tuple[str, ...]          # ordem do CSV e do DDL
    pk: tuple[str, ...]               # composta quando tem mais de uma coluna
    nao_nulo: tuple[str, ...]         # espelha os NOT NULL do DDL
    esperado: int                     # linhas no dataset completo
    inteiros: tuple[str, ...] = ()
    decimais: tuple[str, ...] = ()
    timestamps: tuple[str, ...] = ()
    largura_fixa: tuple[tuple[str, int], ...] = ()   # (coluna, tamanho)
    dominios: dict[str, frozenset[str]] = field(default_factory=dict)
    fks: tuple[tuple[str, str, str], ...] = ()       # (coluna, tabela_pai, coluna_pai)


# A ORDEM DESTA LISTA E A ORDEM DE CARGA, e ela nao e arbitraria: com chave
# estrangeira ativa, o pai precisa existir antes do filho. order_items vem por
# ultimo porque depende de orders, products e sellers ao mesmo tempo.
TABELAS: tuple[Tabela, ...] = (
    Tabela(
        nome="customers",
        csv="olist_customers_dataset.csv",
        colunas=("customer_id", "customer_unique_id", "customer_zip_code_prefix",
                 "customer_city", "customer_state"),
        pk=("customer_id",),
        nao_nulo=("customer_id", "customer_unique_id", "customer_zip_code_prefix",
                  "customer_city", "customer_state"),
        largura_fixa=(("customer_id", 32), ("customer_unique_id", 32),
                      ("customer_zip_code_prefix", 5), ("customer_state", 2)),
        esperado=99_441,
    ),
    Tabela(
        nome="sellers",
        csv="olist_sellers_dataset.csv",
        colunas=("seller_id", "seller_zip_code_prefix", "seller_city", "seller_state"),
        pk=("seller_id",),
        nao_nulo=("seller_id", "seller_zip_code_prefix", "seller_city", "seller_state"),
        largura_fixa=(("seller_id", 32), ("seller_zip_code_prefix", 5),
                      ("seller_state", 2)),
        esperado=3_095,
    ),
    Tabela(
        nome="products",
        csv="olist_products_dataset.csv",
        colunas=("product_id", "product_category_name", "product_name_lenght",
                 "product_description_lenght", "product_photos_qty",
                 "product_weight_g", "product_length_cm", "product_height_cm",
                 "product_width_cm"),
        pk=("product_id",),
        # So o ID e obrigatorio: 610 produtos (1,85%) tem anuncio incompleto e
        # vem sem categoria nem medidas. Sao dados reais e validos.
        nao_nulo=("product_id",),
        inteiros=("product_name_lenght", "product_description_lenght",
                  "product_photos_qty", "product_weight_g", "product_length_cm",
                  "product_height_cm", "product_width_cm"),
        largura_fixa=(("product_id", 32),),
        esperado=32_951,
    ),
    Tabela(
        nome="orders",
        csv="olist_orders_dataset.csv",
        colunas=("order_id", "customer_id", "order_status",
                 "order_purchase_timestamp", "order_approved_at",
                 "order_delivered_carrier_date", "order_delivered_customer_date",
                 "order_estimated_delivery_date"),
        pk=("order_id",),
        nao_nulo=("order_id", "customer_id", "order_status",
                  "order_purchase_timestamp", "order_estimated_delivery_date"),
        # As 3 datas ausentes daqui sao NULL-aveis de proposito: nulo em
        # order_delivered_customer_date significa "nao entregue", nao "faltou
        # dado". Sao validadas quanto ao FORMATO, nao quanto a presenca.
        timestamps=("order_purchase_timestamp", "order_approved_at",
                    "order_delivered_carrier_date", "order_delivered_customer_date",
                    "order_estimated_delivery_date"),
        largura_fixa=(("order_id", 32), ("customer_id", 32)),
        dominios={"order_status": STATUS_VALIDOS},
        fks=(("customer_id", "customers", "customer_id"),),
        esperado=99_441,
    ),
    Tabela(
        nome="order_items",
        csv="olist_order_items_dataset.csv",
        colunas=("order_id", "order_item_id", "product_id", "seller_id",
                 "shipping_limit_date", "price", "freight_value"),
        pk=("order_id", "order_item_id"),   # <- chave COMPOSTA
        nao_nulo=("order_id", "order_item_id", "product_id", "seller_id",
                  "shipping_limit_date", "price", "freight_value"),
        inteiros=("order_item_id",),
        decimais=("price", "freight_value"),
        timestamps=("shipping_limit_date",),
        largura_fixa=(("order_id", 32), ("product_id", 32), ("seller_id", 32)),
        fks=(("order_id", "orders", "order_id"),
             ("product_id", "products", "product_id"),
             ("seller_id", "sellers", "seller_id")),
        esperado=112_650,
    ),
)


# =============================================================================
# Conexao
# =============================================================================

def carrega_env(path: Path) -> None:
    """
    Le o .env e joga as variaveis no ambiente do processo.

    Escrito a mao em vez de usar python-dotenv: sao 8 linhas e uma dependencia
    a menos num projeto que promete rodar logo apos o clone.

    setdefault (e nao os environ[k] = v) faz variaveis ja presentes no ambiente
    terem precedencia sobre o arquivo -- assim da para sobrescrever a senha em
    um servidor de CI sem editar nada.
    """
    if not path.exists():
        sys.exit(
            f"Arquivo de credenciais nao encontrado: {path}\n"
            f"Crie a partir do modelo:  Copy-Item .env.example .env"
        )
    for linha in path.read_text(encoding="utf-8").splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#") or "=" not in linha:
            continue
        chave, valor = linha.split("=", 1)
        os.environ.setdefault(chave.strip(), valor.strip())


def conecta() -> psycopg.Connection:
    """
    Abre a conexao usando as variaveis PGHOST/PGPORT/PGDATABASE/PGUSER/
    PGPASSWORD, que o psycopg le do ambiente sozinho -- sao os nomes padrao da
    libpq, a mesma biblioteca que o psql usa por baixo.

    O erro de conexao e traduzido porque a mensagem crua do PostgreSQL nao
    ajuda quem esta comecando.
    """
    try:
        return psycopg.connect()
    except psycopg.OperationalError as exc:
        host = os.environ.get("PGHOST", "?")
        port = os.environ.get("PGPORT", "?")
        db = os.environ.get("PGDATABASE", "?")
        sys.exit(
            f"Nao consegui conectar em {host}:{port}/{db}\n"
            f"\n{str(exc).strip()}\n\n"
            f"Verifique:\n"
            f"  1. o servico do PostgreSQL esta rodando?\n"
            f"       Get-Service *postgres*\n"
            f"  2. o banco existe?\n"
            f"       createdb -U postgres {db}\n"
            f"  3. usuario e senha no .env estao corretos?"
        )


# =============================================================================
# Etapa 1 -- CSV -> DataFrame
# =============================================================================

def le_csv(caminho: Path) -> pd.DataFrame:
    """
    Le o CSV com TUDO como texto (dtype=str).

    Sem isso o pandas infere o tipo de cada coluna olhando so uma amostra das
    linhas, e infere errado em casos que importam:

      - customer_zip_code_prefix viraria inteiro e o CEP 01037 viraria 1037,
        perdendo o zero a esquerda. Nada da erro; o join com geolocation e que
        para de casar. Silenciosamente e a parte grave.
      - a mesma coluna pode virar 'object' num arquivo e 'int64' em outro,
        fazendo o comportamento do programa mudar sem o codigo mudar.

    Lendo como texto o pandas nao decide nada. Quem decide o tipo e o DDL, e a
    conversao acontece dentro do PostgreSQL, na hora do COPY.
    """
    return pd.read_csv(caminho, dtype=str, encoding="utf-8")


# =============================================================================
# Etapa 2 -- Validacao
#
# Cada funcao devolve uma lista de problemas (vazia = tudo certo). Ninguem
# levanta excecao: os problemas sao acumulados para que a saida mostre TUDO de
# uma vez, em vez de obrigar a rodar cinco vezes corrigindo um erro por vez.
# =============================================================================

def _amostra(valores) -> str:
    """Ate 3 exemplos reais -- um erro sem exemplo e quase impossivel de achar."""
    exemplos = [repr(v) for v in list(valores)[:3]]
    return ", ".join(exemplos)


def valida_colunas(df: pd.DataFrame, t: Tabela) -> list[str]:
    """Pega o caso mais comum de quebra: a origem mudou o layout do arquivo."""
    faltando = [c for c in t.colunas if c not in df.columns]
    if faltando:
        return [f"colunas ausentes no CSV: {', '.join(faltando)}"]
    return []


def valida_nao_nulo(df: pd.DataFrame, t: Tabela) -> list[str]:
    problemas = []
    for col in t.nao_nulo:
        n = int(df[col].isna().sum())
        if n:
            problemas.append(f"{col}: {n:,} valores nulos (a coluna e NOT NULL)")
    return problemas


def valida_pk(df: pd.DataFrame, t: Tabela) -> list[str]:
    """
    Chave primaria precisa ser unica. Em order_items ela e COMPOSTA
    (order_id + order_item_id): nenhuma das duas e unica sozinha, o par e.
    """
    dup = df.duplicated(subset=list(t.pk), keep=False)
    if not dup.any():
        return []
    chave = " + ".join(t.pk)
    exemplos = df.loc[dup, list(t.pk)].head(3).astype(str).agg(" | ".join, axis=1)
    return [f"PK ({chave}): {int(dup.sum()):,} linhas duplicadas. Ex: {_amostra(exemplos)}"]


def valida_largura(df: pd.DataFrame, t: Tabela) -> list[str]:
    """
    Confere o tamanho exato dos campos de largura fixa (IDs de 32 caracteres,
    CEP de 5, UF de 2). Barra truncamento e lixo antes do banco reclamar.
    """
    problemas = []
    for col, tamanho in t.largura_fixa:
        errado = df[col].dropna().str.len() != tamanho
        if errado.any():
            valores = df[col].dropna()[errado]
            problemas.append(
                f"{col}: {int(errado.sum()):,} valores fora do tamanho {tamanho}. "
                f"Ex: {_amostra(valores)}"
            )
    return problemas


def valida_inteiros(df: pd.DataFrame, t: Tabela) -> list[str]:
    """
    O valor precisa virar inteiro sem perda. errors='coerce' transforma o que
    nao converte em NaN; comparando com quem NAO era nulo antes, sobra
    exatamente o que quebraria o COPY.
    """
    problemas = []
    for col in t.inteiros:
        original = df[col]
        convertido = pd.to_numeric(original, errors="coerce")
        ruins = original.notna() & convertido.isna()
        if ruins.any():
            problemas.append(
                f"{col}: {int(ruins.sum()):,} valores nao sao inteiros. "
                f"Ex: {_amostra(original[ruins])}"
            )
            continue
        # "40.0" converte para numero, mas o COPY numa coluna INTEGER falha.
        com_ponto = original.dropna().str.contains(r"\.", regex=True)
        if com_ponto.any():
            problemas.append(
                f"{col}: {int(com_ponto.sum()):,} valores com casa decimal em coluna "
                f"inteira. Ex: {_amostra(original.dropna()[com_ponto])}"
            )
    return problemas


def valida_decimais(df: pd.DataFrame, t: Tabela) -> list[str]:
    """Alem de converter, valor monetario negativo nao existe aqui."""
    problemas = []
    for col in t.decimais:
        original = df[col]
        convertido = pd.to_numeric(original, errors="coerce")
        ruins = original.notna() & convertido.isna()
        if ruins.any():
            problemas.append(
                f"{col}: {int(ruins.sum()):,} valores nao sao numericos. "
                f"Ex: {_amostra(original[ruins])}"
            )
            continue
        negativos = convertido < 0
        if negativos.any():
            problemas.append(
                f"{col}: {int(negativos.sum()):,} valores negativos. "
                f"Ex: {_amostra(original[negativos])}"
            )
    return problemas


def valida_timestamps(df: pd.DataFrame, t: Tabela) -> list[str]:
    """
    Valida o FORMATO, nunca a presenca -- quem exige presenca e o NOT NULL.
    Uma data nula em order_delivered_customer_date significa "nao entregue",
    que e informacao legitima, nao defeito.
    """
    problemas = []
    for col in t.timestamps:
        original = df[col]
        convertido = pd.to_datetime(original, errors="coerce", format="%Y-%m-%d %H:%M:%S")
        ruins = original.notna() & convertido.isna()
        if ruins.any():
            problemas.append(
                f"{col}: {int(ruins.sum()):,} datas em formato invalido. "
                f"Ex: {_amostra(original[ruins])}"
            )
    return problemas


def valida_dominios(df: pd.DataFrame, t: Tabela) -> list[str]:
    """Colunas com conjunto fechado de valores (ex: order_status)."""
    problemas = []
    for col, permitidos in t.dominios.items():
        fora = ~df[col].isin(permitidos) & df[col].notna()
        if fora.any():
            problemas.append(
                f"{col}: {int(fora.sum()):,} valores fora do dominio conhecido. "
                f"Ex: {_amostra(df[col][fora].unique())}"
            )
    return problemas


def valida_fks(df: pd.DataFrame, t: Tabela, carregados: dict[str, pd.DataFrame]) -> list[str]:
    """
    Integridade referencial ANTES do banco.

    O PostgreSQL pegaria isso sozinho -- mas diria apenas
    'violates foreign key constraint "fk_order_items_order"', sem dizer quantas
    linhas nem quais. Aqui sai "847 order_id inexistentes em orders. Ex: ...",
    que e a diferenca entre 10 segundos e uma tarde de investigacao.
    """
    problemas = []
    for col, tabela_pai, col_pai in t.fks:
        pai = carregados.get(tabela_pai)
        if pai is None:
            problemas.append(f"{col}: tabela pai '{tabela_pai}' nao foi carregada")
            continue
        orfas = ~df[col].isin(set(pai[col_pai]))
        if orfas.any():
            problemas.append(
                f"{col}: {int(orfas.sum()):,} valores sem correspondencia em "
                f"{tabela_pai}.{col_pai}. Ex: {_amostra(df[col][orfas].unique())}"
            )
    return problemas


def valida(df: pd.DataFrame, t: Tabela, carregados: dict[str, pd.DataFrame]) -> list[str]:
    """Roda todas as checagens de uma tabela e junta os problemas."""
    problemas = valida_colunas(df, t)
    if problemas:
        # Sem as colunas certas, o resto das checagens so geraria KeyError.
        return problemas

    for checagem in (valida_nao_nulo, valida_pk, valida_largura,
                     valida_inteiros, valida_decimais, valida_timestamps,
                     valida_dominios):
        problemas += checagem(df, t)
    problemas += valida_fks(df, t, carregados)
    return problemas


# =============================================================================
# Etapa 3 -- DataFrame -> PostgreSQL
# =============================================================================

def copia(cur: psycopg.Cursor, df: pd.DataFrame, t: Tabela) -> int:
    """
    Envia o DataFrame com COPY, o comando de carga em massa do PostgreSQL.

    Por que nao df.to_sql(): ele gera INSERTs em lote e exige o SQLAlchemy
    inteiro como dependencia. Para as 112 mil linhas de order_items sao
    minutos; com COPY sao segundos. Diferenca de ordem de grandeza, nao de
    ajuste fino.

    O dado vai como TEXTO e quem converte para INTEGER/NUMERIC/TIMESTAMP e o
    proprio PostgreSQL, seguindo o DDL. Por isso a validacao precisa vir antes:
    aqui ja nao ha mais como tratar erro linha a linha.

    Campo vazio vira NULL: o pandas escreve NaN como vazio sem aspas, e no
    formato CSV do COPY vazio-sem-aspas e exatamente a representacao de NULL.
    """
    buffer = io.StringIO()
    df.to_csv(buffer, index=False, header=False, na_rep="", lineterminator="\n")
    buffer.seek(0)

    colunas = ", ".join(t.colunas)
    sql = f"COPY {SCHEMA}.{t.nome} ({colunas}) FROM STDIN WITH (FORMAT CSV)"
    with cur.copy(sql) as copy:
        copy.write(buffer.getvalue())

    cur.execute(f"SELECT count(*) FROM {SCHEMA}.{t.nome}")
    return cur.fetchone()[0]


# =============================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Carrega os CSVs no PostgreSQL, validando antes de gravar."
    )
    parser.add_argument("--sample", action="store_true",
                        help="usa data/sample/ em vez de data/raw/")
    parser.add_argument("--check-only", action="store_true",
                        help="so valida; nao conecta nem grava nada")
    args = parser.parse_args()

    origem = PROJECT_ROOT / "data" / ("sample" if args.sample else "raw")
    if not origem.exists():
        print(f"Diretorio nao encontrado: {origem}")
        print("Rode antes: python src/download_data.py")
        return 1

    print(f"Origem: {origem}")

    # -- Etapa 1: ler tudo ---------------------------------------------------
    print("\n[1/3] Lendo CSVs")
    quadros: dict[str, pd.DataFrame] = {}
    for t in TABELAS:
        caminho = origem / t.csv
        if not caminho.exists():
            print(f"  FALTA    {t.csv}")
            print(f"\nArquivo obrigatorio ausente. Rode: python src/download_data.py")
            return 1
        df = le_csv(caminho)
        quadros[t.nome] = df
        print(f"  {t.nome:<14} {len(df):>9,} linhas")

    # -- Etapa 2: validar tudo antes de gravar qualquer coisa ----------------
    #
    # Validamos as 5 tabelas ANTES de abrir a conexao. E a diferenca entre
    # descobrir o problema agora e descobri-lo com o banco meio carregado.
    print("\n[2/3] Validando")
    achados: dict[str, list[str]] = {}
    for t in TABELAS:
        problemas = valida(quadros[t.nome], t, quadros)
        achados[t.nome] = problemas

        # A contagem so e comparavel no dataset completo -- a amostra e menor
        # de proposito.
        aviso = ""
        if not args.sample and len(quadros[t.nome]) != t.esperado:
            aviso = f"  <-- esperado {t.esperado:,}"

        if problemas:
            print(f"  FALHOU   {t.nome:<14} {len(problemas)} problema(s){aviso}")
            for p in problemas:
                print(f"           - {p}")
        else:
            print(f"  OK       {t.nome:<14} sem problemas{aviso}")

    if any(achados.values()):
        total = sum(len(p) for p in achados.values())
        print(f"\n{total} problema(s) encontrados. NADA foi gravado.")
        print("A carga so acontece com as 5 tabelas integras -- carregar pela")
        print("metade deixaria o banco num estado que ninguem sabe se pode usar.")
        return 1

    if args.check_only:
        print("\n--check-only: validacao passou, nada foi gravado.")
        return 0

    # -- Etapa 3: gravar, tudo dentro de UMA transacao -----------------------
    print("\n[3/3] Gravando no PostgreSQL")
    carrega_env(ENV_PATH)

    if not DDL_PATH.exists():
        sys.exit(f"DDL nao encontrado: {DDL_PATH}")

    # O 'with' do psycopg confirma (COMMIT) ao sair sem erro e desfaz
    # (ROLLBACK) se qualquer excecao escapar. E o que garante que o resultado
    # seja binario: ou as 5 tabelas entraram, ou o banco ficou exatamente como
    # estava. Nunca meio caminho -- que e justamente o defeito do load_raw.py,
    # onde cada comando e confirmado sozinho.
    with conecta() as con:
        with con.cursor() as cur:
            cur.execute(DDL_PATH.read_text(encoding="utf-8"))
            print(f"  Schema '{SCHEMA}' aplicado ({DDL_PATH.name})")

            # Idempotencia: rodar duas vezes nao pode duplicar. Um unico
            # TRUNCATE com todas as tabelas resolve a ordem das FKs sozinho.
            alvos = ", ".join(f"{SCHEMA}.{t.nome}" for t in TABELAS)
            cur.execute(f"TRUNCATE {alvos}")
            print(f"  Tabelas esvaziadas")

            total = 0
            for t in TABELAS:
                df = quadros[t.nome][list(t.colunas)]   # ordem fixa, nao a do arquivo
                linhas = copia(cur, df, t)
                total += linhas
                print(f"  OK       {SCHEMA}.{t.nome:<14} {linhas:>9,} linhas")

    print(f"\n{total:,} linhas gravadas em {os.environ.get('PGDATABASE')}.")
    print("\nInspecione com:")
    print('  psql -U postgres -d sales_intelligence -c "\\dt staging.*"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
