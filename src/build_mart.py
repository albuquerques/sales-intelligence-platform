"""
Constroi a camada MART (dimensoes) a partir da STAGING, e prova que ficou certa.

Uso:
    python src/build_mart.py                 # cria/atualiza as dimensoes e verifica
    python src/build_mart.py --so-verificar  # so roda as verificacoes, nao escreve

Por que este script e fino e o trabalho esta no SQL: o dado ja esta dentro do
PostgreSQL. Puxar 1 milhao de linhas de geolocation para a memoria do Python,
calcular a mediana e devolver seria ida e volta sem proposito -- e a
transformacao (juncao, agregacao, deduplicacao) e feita de CONJUNTOS, que e
exatamente o que SQL faz melhor. Diferente do load_postgres.py, onde o
DataFrame existia porque era o unico lugar onde dava para OLHAR o dado antes de
grava-lo pela primeira vez.

O que sobra para o Python e o que SQL nao faz bem: abrir a transacao, traduzir
o erro e transformar as verificacoes num relatorio legivel. Um script que so
diz "COMMIT" nao prova nada; o valor desta etapa esta na secao [3/4].
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

# O console do Windows usa cp1252 por padrao e quebra ao imprimir acentos.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

try:
    import psycopg
except ModuleNotFoundError as exc:
    sys.exit(f"Dependencia ausente ({exc.name}). Rode: pip install -r requirements.txt")

# Reaproveita a leitura do .env e a conexao traduzida do pipeline da STAGING --
# sao o mesmo banco e as mesmas credenciais. Duplicar isso aqui criaria dois
# lugares para corrigir quando a conexao mudar.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from load_postgres import carrega_env, conecta, ENV_PATH  # noqa: E402

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DDL_PATH = PROJECT_ROOT / "sql" / "03_create_mart_dimensions.sql"
CARGA_PATH = PROJECT_ROOT / "sql" / "04_load_mart_dimensions.sql"


# =============================================================================
# Verificacoes
#
# "Dimensao funcionando" nao e "a tabela existe". E: tem o numero certo de
# linhas, nenhuma chave natural ficou de fora, e a fato da proxima etapa vai
# achar destino para toda linha que tentar apontar para ca.
#
# Cada verificacao devolve UM numero. Quando 'esperado' e None ela e apenas
# informativa e nunca reprova -- serve para dar visibilidade a um numero que
# vale conhecer, nao para julgar.
# =============================================================================

@dataclass(frozen=True)
class Verificacao:
    nome: str
    sql: str
    esperado: int | None
    porque: str          # o que estaria quebrado se este numero viesse errado


# -- 1. Contagem ---------------------------------------------------------------
#
# Numero de linhas conferido contra o profiling do dataset completo. E a
# checagem mais boba e a que pega mais coisa: junção que multiplicou linha,
# filtro que comeu linha, carga que rodou pela metade.
CONTAGENS = (
    Verificacao(
        "dim_data           linhas", "SELECT COUNT(*) FROM mart.dim_data", 1_828,
        "1.827 dias de 2016-01-01 a 2020-12-31, mais a linha -1 (nao informado). "
        "Esta contagem e a unica checagem que pega ponta faltando -- e ela ja "
        "pegou: com literal DATE em vez de TIMESTAMP, o horario de verao "
        "brasileiro apagava 2018-12-31 do calendario",
    ),
    Verificacao(
        "dim_cliente        linhas", "SELECT COUNT(*) FROM mart.dim_cliente", 96_096,
        "customer_unique_id distintos. Se der 99.441, o grao virou customer_id "
        "por engano e a recorrencia vai dar zero",
    ),
    Verificacao(
        "dim_vendedor       linhas", "SELECT COUNT(*) FROM mart.dim_vendedor", 3_095,
        "seller_id distintos em staging.sellers",
    ),
    Verificacao(
        "dim_produto        linhas", "SELECT COUNT(*) FROM mart.dim_produto", 32_951,
        "product_id distintos em staging.products",
    ),
    Verificacao(
        "dim_status_pedido  linhas", "SELECT COUNT(*) FROM mart.dim_status_pedido", 8,
        "os 8 status do CHECK de staging.orders",
    ),
)

# -- 2. Integridade que constraint nenhuma pega --------------------------------
#
# O UNIQUE da chave natural garante que nao ha DUPLICATA. Nada garante que nao
# ha FALTA -- e falta e o defeito grave: a fato nao acha a linha, e a venda
# some do painel.
#
# Este bloco e o coracao da etapa. Se ele passa, a fact table da proxima etapa
# nao vai perder nenhuma das 112.650 linhas.
INTEGRIDADE = (
    Verificacao(
        "clientes sem linha na dimensao",
        """
        SELECT COUNT(*) FROM (
            SELECT DISTINCT customer_unique_id FROM staging.customers
        ) s
        WHERE NOT EXISTS (
            SELECT 1 FROM mart.dim_cliente d
            WHERE d.customer_unique_id = s.customer_unique_id
        )
        """,
        0,
        "toda pessoa da staging precisa existir na dimensao, senao a fato "
        "perde as vendas dela",
    ),
    Verificacao(
        "produtos sem linha na dimensao",
        """
        SELECT COUNT(*) FROM staging.products s
        WHERE NOT EXISTS (
            SELECT 1 FROM mart.dim_produto d WHERE d.product_id = s.product_id
        )
        """,
        0,
        "todo produto vendido precisa ter linha, inclusive os 610 sem categoria",
    ),
    Verificacao(
        "vendedores sem linha na dimensao",
        """
        SELECT COUNT(*) FROM staging.sellers s
        WHERE NOT EXISTS (
            SELECT 1 FROM mart.dim_vendedor d WHERE d.seller_id = s.seller_id
        )
        """,
        0,
        "todo vendedor precisa ter linha",
    ),
    Verificacao(
        "status sem linha na dimensao",
        """
        SELECT COUNT(*) FROM (
            SELECT DISTINCT order_status FROM staging.orders
        ) s
        WHERE NOT EXISTS (
            SELECT 1 FROM mart.dim_status_pedido d WHERE d.status_origem = s.order_status
        )
        """,
        0,
        "a lista de status e escrita a mao no SQL de carga -- esta e a unica "
        "coisa que impede ela de sair de sincronia com o dado",
    ),
    Verificacao(
        "pedidos perdidos ao mudar de grao",
        "SELECT (SELECT COALESCE(SUM(qtd_pedidos),0) FROM mart.dim_cliente) "
        "     - (SELECT COUNT(*) FROM staging.orders)",
        0,
        "a soma de qtd_pedidos por pessoa TEM de fechar com os 99.441 pedidos. "
        "Diferente de zero significa que a mudanca de customer_id para "
        "customer_unique_id perdeu ou duplicou pedido",
    ),
)

# -- 3. Cobertura da dim_data --------------------------------------------------
#
# A dimensao de data e a unica gerada, entao ela e a unica que pode estar
# certa por dentro e mesmo assim nao cobrir o dado real. As duas checagens
# aqui sao "nao tem buraco" e "nao falta ponta".
DATAS = (
    Verificacao(
        "dim_data dias faltando na sequencia",
        "SELECT (MAX(data) - MIN(data) + 1) - COUNT(*) FROM mart.dim_data WHERE sk_data <> -1",
        0,
        "buraco no calendario faz o grafico de serie temporal pular o dia sem "
        "avisar e a media diaria dividir pelo numero errado. Repare que esta "
        "checagem NAO enxerga ponta faltando: se o ultimo dia sumir, MAX() so "
        "diminui junto e a conta continua fechando. Quem pega isso e a contagem",
    ),
    Verificacao(
        "datas do negocio fora da dim_data",
        """
        WITH usadas AS (
            SELECT order_purchase_timestamp::date      AS d FROM staging.orders
            UNION SELECT order_approved_at::date             FROM staging.orders
            UNION SELECT order_delivered_carrier_date::date  FROM staging.orders
            UNION SELECT order_delivered_customer_date::date FROM staging.orders
            UNION SELECT order_estimated_delivery_date::date FROM staging.orders
            UNION SELECT shipping_limit_date::date           FROM staging.order_items
        )
        SELECT COUNT(*) FROM usadas u
        WHERE u.d IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM mart.dim_data dd WHERE dd.data = u.d)
        """,
        0,
        "qualquer data usada pelo negocio precisa existir no calendario, "
        "inclusive a entrega estimada que vai ate 2018-11-12",
    ),
)

# -- 4. Informativo ------------------------------------------------------------
#
# Nao reprova nada. Sao os numeros que a etapa PRODUZIU e que vale ver escritos
# -- inclusive as lacunas conhecidas, que ficam a vista em vez de descobertas
# no meio do painel.
INFORMATIVO = (
    Verificacao(
        "clientes sem coordenada",
        "SELECT COUNT(*) FROM mart.dim_cliente WHERE latitude IS NULL", None,
        "CEP sem correspondencia em geolocation",
    ),
    Verificacao(
        "vendedores sem coordenada",
        "SELECT COUNT(*) FROM mart.dim_vendedor WHERE latitude IS NULL", None,
        "CEP sem correspondencia em geolocation",
    ),
    Verificacao(
        "produtos com anuncio incompleto",
        "SELECT COUNT(*) FROM mart.dim_produto WHERE NOT anuncio_completo", None,
        "recebem categoria 'Nao informado'",
    ),
    Verificacao(
        "categorias distintas",
        "SELECT COUNT(DISTINCT categoria) FROM mart.dim_produto", None,
        "73 reais + 'Nao informado'",
    ),
    Verificacao(
        "clientes recorrentes",
        "SELECT COUNT(*) FROM mart.dim_cliente WHERE eh_recorrente", None,
        "pessoas com mais de um pedido -- o numero que o grao errado zeraria",
    ),
)


def executa(cur: psycopg.Cursor, v: Verificacao) -> tuple[bool, int]:
    cur.execute(v.sql)
    valor = cur.fetchone()[0]
    passou = v.esperado is None or valor == v.esperado
    return passou, valor


def roda_bloco(cur: psycopg.Cursor, titulo: str, bloco: tuple[Verificacao, ...]) -> list[str]:
    """Roda um grupo de verificacoes e devolve a lista de falhas."""
    print(f"\n  {titulo}")
    falhas = []
    for v in bloco:
        passou, valor = executa(cur, v)
        if v.esperado is None:
            print(f"    --       {v.nome:<38} {valor:>9,}   ({v.porque})")
        elif passou:
            print(f"    OK       {v.nome:<38} {valor:>9,}")
        else:
            print(f"    FALHOU   {v.nome:<38} {valor:>9,}   <-- esperado {v.esperado:,}")
            print(f"             {v.porque}")
            falhas.append(v.nome)
    return falhas


def mostra_amostra(cur: psycopg.Cursor) -> None:
    """
    Tres linhas de duas dimensoes. Contagem prova que o numero fechou; olhar o
    dado e o que pega o defeito que fecha a conta e mesmo assim esta errado --
    mes em ingles, cidade em caixa baixa, coordenada trocada de sinal.
    """
    print("\n  Amostra (o que o Power BI vai enxergar)")

    cur.execute("""
        SELECT sk_data, data, ano_mes, nome_mes, nome_dia_semana, eh_fim_semana
        FROM mart.dim_data
        WHERE sk_data IN (-1, 20161225, 20170902, 20180501)
        ORDER BY sk_data
    """)
    print("    dim_data")
    for sk, data, ano_mes, mes, dia_sem, fds in cur.fetchall():
        print(f"      {sk:>9}  {str(data):<12} {ano_mes or '-':<8} "
              f"{mes:<14} {dia_sem:<14} fim de semana={fds}")

    cur.execute("""
        SELECT sk_cliente, cidade, estado, latitude, longitude, qtd_pedidos, eh_recorrente
        FROM mart.dim_cliente
        ORDER BY qtd_pedidos DESC, sk_cliente
        LIMIT 3
    """)
    print("    dim_cliente (os que mais compraram)")
    for sk, cid, uf, lat, lng, qtd, rec in cur.fetchall():
        coord = f"{lat}, {lng}" if lat is not None else "sem coordenada"
        print(f"      {sk:>9}  {cid:<22} {uf}  {coord:<24} "
              f"pedidos={qtd} recorrente={rec}")


# =============================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Constroi as dimensoes da camada MART a partir da STAGING."
    )
    parser.add_argument("--so-verificar", action="store_true",
                        help="nao escreve nada; so roda as verificacoes")
    args = parser.parse_args()

    for caminho in (DDL_PATH, CARGA_PATH):
        if not caminho.exists():
            sys.exit(f"Arquivo SQL nao encontrado: {caminho}")

    carrega_env(ENV_PATH)

    # Uma transacao para tudo. Ou as cinco dimensoes ficam coerentes entre si,
    # ou o schema fica exatamente como estava -- nunca meio caminho, que e o
    # estado em que ninguem sabe se pode confiar no banco.
    with conecta() as con:
        with con.cursor() as cur:

            if args.so_verificar:
                print("--so-verificar: nada sera escrito.\n")
            else:
                print("[1/3] Criando o schema mart")
                cur.execute(DDL_PATH.read_text(encoding="utf-8"))
                print(f"  DDL aplicado ({DDL_PATH.name})")

                print("\n[2/4] Carregando as dimensoes")
                cur.execute(CARGA_PATH.read_text(encoding="utf-8"))
                print(f"  Carga executada ({CARGA_PATH.name})")

            print("\n[3/4] Verificando")
            falhas = []
            falhas += roda_bloco(cur, "Contagem", CONTAGENS)
            falhas += roda_bloco(cur, "Integridade (o que constraint nao pega)", INTEGRIDADE)
            falhas += roda_bloco(cur, "Cobertura do calendario", DATAS)
            falhas += roda_bloco(cur, "Informativo", INFORMATIVO)
            mostra_amostra(cur)

            if falhas:
                # Levantar a excecao desfaz a transacao inteira: dimensao que
                # nao passou na verificacao nao fica gravada. A alternativa --
                # gravar e avisar -- deixaria a proxima etapa construir a fato
                # em cima de dimensao que ja se sabe errada.
                raise SystemExit(
                    f"\n{len(falhas)} verificacao(oes) falharam: {', '.join(falhas)}\n"
                    f"NADA foi gravado (a transacao foi desfeita)."
                )

    # -- Fora da transacao, de proposito -------------------------------------
    #
    # VACUUM nao roda dentro de transacao, entao so pode acontecer aqui, depois
    # do COMMIT. Duas razoes, e as duas importam:
    #
    #   ANALYZE atualiza a estatistica que o planejador usa. A proxima etapa
    #   junta a fato (112.650 linhas) com estas dimensoes; com estatistica
    #   velha o PostgreSQL escolhe o plano errado e a consulta fica lenta sem
    #   motivo aparente.
    #
    #   VACUUM limpa o rastro do upsert. ON CONFLICT DO UPDATE reescreve TODA
    #   linha a cada carga -- e no MVCC a versao antiga nao e apagada, vira
    #   lixo. Depois de quatro cargas, dim_cliente ocupava 50 MB para 96 mil
    #   linhas: ~545 bytes por linha, uma ordem de grandeza acima do que o dado
    #   pesa. Esse e o custo real do upsert, e o preco de manter a chave
    #   substituta estavel -- TRUNCATE + INSERT nao incharia, mas embaralharia
    #   as chaves. O VACUUM devolve o espaco para reuso; ele nao encolhe o
    #   arquivo (isso exigiria VACUUM FULL, que trava a tabela).
    if not args.so_verificar:
        print("\n[4/4] VACUUM ANALYZE")
        with conecta() as con:
            con.autocommit = True
            with con.cursor() as cur:
                for tabela in ("dim_data", "dim_cliente", "dim_vendedor",
                               "dim_produto", "dim_status_pedido"):
                    cur.execute(f"VACUUM (ANALYZE) mart.{tabela}")
        print("  Estatisticas atualizadas e espaco liberado para reuso")

    print("\nDimensoes prontas em mart. Proxima etapa: a fact table.")
    print("\nInspecione com:")
    print('  psql -U postgres -d sales_intelligence -c "\\dt mart.*"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
