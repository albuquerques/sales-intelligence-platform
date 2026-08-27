"""
Constroi a camada MART (dimensoes + fato) a partir da STAGING, e prova que
ficou certa.

Uso:
    python src/build_mart.py                 # cria/atualiza o modelo e verifica
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

# A ORDEM DESTA TUPLA E A ORDEM DE EXECUCAO, e ela nao e arbitraria: a fato tem
# FK para as cinco dimensoes, entao o DDL dela exige que elas ja existam, e a
# carga dela exige que elas ja estejam preenchidas (e de onde saem as chaves
# substitutas). Tudo dentro da mesma transacao.
ETAPAS_SQL = (
    ("03_create_mart_dimensions.sql", "DDL das dimensoes"),
    ("04_load_mart_dimensions.sql",   "Carga das dimensoes"),
    ("05_create_mart_fato.sql",       "DDL da fato"),
    ("06_load_mart_fato.sql",         "Carga da fato"),
)


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
    Verificacao(
        "fato_vendas        linhas", "SELECT COUNT(*) FROM mart.fato_vendas", 112_650,
        "uma linha por item de pedido -- o grao declarado. Igual a contagem de "
        "staging.order_items: a fato nao inventa nem perde item",
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

# -- 4. A fato bate com a origem? ----------------------------------------------
#
# Uma fato pode estar com a contagem CERTA e o dinheiro ERRADO. Por isso a
# checagem central deste bloco nao e contar linha, e somar dinheiro: uma juncao
# que casa com duas linhas dobra a receita sem mudar nada que salte aos olhos,
# e uma linha perdida some com uma venda em silencio.
#
# As somas sao comparadas em CENTAVOS INTEIROS contra a staging. Nao e detalhe:
# comparar dinheiro em ponto flutuante produz diferenca de 0.0000001 que nao e
# erro nenhum e mesmo assim reprova. Centavo inteiro ou bate ou nao bate.
#
# Varias destas ja sao garantidas por constraint no 05 (a PK garante o grao, as
# sete FKs garantem que nao ha orfao). Estao aqui assim mesmo porque garantia
# estrutural que ninguem confere vira suposicao -- e porque se alguem remover
# uma constraint no futuro, e isto que avisa.
FATO = (
    Verificacao(
        "itens a mais ou a menos que a origem",
        "SELECT (SELECT COUNT(*) FROM mart.fato_vendas) "
        "     - (SELECT COUNT(*) FROM staging.order_items)",
        0,
        "diferente de zero = juncao multiplicou linha ou alguma linha se perdeu "
        "no caminho. Comparado com a origem, nao com numero fixo: vale tambem "
        "quando a staging esta com a amostra",
    ),
    Verificacao(
        "diferenca de PRECO em centavos",
        "SELECT (((SELECT SUM(preco) FROM mart.fato_vendas) "
        "       - (SELECT SUM(price) FROM staging.order_items)) * 100)::BIGINT",
        0,
        "R$ 13.591.643,70 na origem. Esta e A verificacao de uma fact table: "
        "contagem certa com soma errada acontece, e e a explosao de juncao",
    ),
    Verificacao(
        "diferenca de FRETE em centavos",
        "SELECT (((SELECT SUM(frete) FROM mart.fato_vendas) "
        "       - (SELECT SUM(freight_value) FROM staging.order_items)) * 100)::BIGINT",
        0,
        "R$ 2.251.909,54 na origem",
    ),
    Verificacao(
        "linhas fora do grao declarado",
        "SELECT COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)) "
        "FROM mart.fato_vendas",
        0,
        "'uma linha por item de pedido' escrito como numero. A PK ja impede "
        "isso -- esta linha existe para o dia em que alguem achar que a PK "
        "estava atrapalhando a carga",
    ),
    Verificacao(
        "chaves apontando para lugar nenhum",
        """
        SELECT
            (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_cliente d WHERE d.sk_cliente = f.sk_cliente))
          + (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_produto d WHERE d.sk_produto = f.sk_produto))
          + (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_vendedor d WHERE d.sk_vendedor = f.sk_vendedor))
          + (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_status_pedido d WHERE d.sk_status = f.sk_status))
          + (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_data d WHERE d.sk_data = f.sk_data_compra))
          + (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_data d WHERE d.sk_data = f.sk_data_entrega))
          + (SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS
                (SELECT 1 FROM mart.dim_data d WHERE d.sk_data = f.sk_data_prevista))
        """,
        0,
        "as sete FKs conferidas uma a uma. Orfa nao da erro no Power BI: ela "
        "some do visual quando alguem filtra pela dimensao",
    ),
    Verificacao(
        "linhas ligadas a dimensao ERRADA",
        # A verificacao acima prova que toda chave RESOLVE. Esta prova que ela
        # resolve para a linha CERTA -- que e outro defeito, e o mais dificil
        # de enxergar: dois LEFT JOIN com apelidos trocados produzem chaves
        # perfeitamente validas, contagem certa, soma certa, e o produto errado
        # em toda linha. Nenhuma constraint pega isso.
        #
        # O metodo e a viagem de volta: da fato, segue a chave substituta ate a
        # dimensao, pega a chave NATURAL de la, e compara com a que a staging
        # tem para a mesma linha. Se a traducao esta certa, elas sao iguais.
        # E possivel exatamente porque a chave natural continuou dentro da
        # dimensao junto com a substituta.
        #
        # dim_data entra com IS DISTINCT FROM, e nao com <>, por causa do
        # membro -1: nele data e NULL, e a data de entrega da origem tambem e
        # NULL. Com <> a comparacao daria NULL (nem verdadeiro nem falso) e a
        # linha escaparia da checagem; IS DISTINCT FROM trata NULL como valor e
        # confirma que os dois lados concordam em "nao entregue".
        """
        SELECT COUNT(*)
        FROM mart.fato_vendas f
        JOIN staging.order_items i
          ON i.order_id = f.order_id AND i.order_item_id = f.order_item_id
        JOIN staging.orders    o  ON o.order_id    = i.order_id
        JOIN staging.customers c  ON c.customer_id = o.customer_id
        JOIN mart.dim_produto       dp  ON dp.sk_produto  = f.sk_produto
        JOIN mart.dim_vendedor      dv  ON dv.sk_vendedor = f.sk_vendedor
        JOIN mart.dim_cliente       dc  ON dc.sk_cliente  = f.sk_cliente
        JOIN mart.dim_status_pedido ds  ON ds.sk_status    = f.sk_status
        JOIN mart.dim_data          ddc ON ddc.sk_data = f.sk_data_compra
        JOIN mart.dim_data          dde ON dde.sk_data = f.sk_data_entrega
        JOIN mart.dim_data          ddp ON ddp.sk_data = f.sk_data_prevista
        WHERE dp.product_id         <> i.product_id
           OR dv.seller_id          <> i.seller_id
           OR dc.customer_unique_id <> c.customer_unique_id
           OR ds.status_origem      <> o.order_status
           OR ddc.data <> o.order_purchase_timestamp::date
           OR ddp.data <> o.order_estimated_delivery_date::date
           OR dde.data IS DISTINCT FROM o.order_delivered_customer_date::date
           OR f.preco <> i.price
           OR f.frete <> i.freight_value
        """,
        0,
        "a viagem de volta: sk -> dimensao -> chave natural tem de bater com a "
        "staging. Pega apelido de JOIN trocado, que produz chave valida e "
        "aponta para o produto errado sem quebrar nada",
    ),
    Verificacao(
        "incoerencia entre -1 e prazo NULL",
        "SELECT COUNT(*) FROM mart.fato_vendas "
        "WHERE (sk_data_entrega = -1) <> (dias_entrega IS NULL)",
        0,
        "as duas formas de dizer 'nao entregue' tem de concordar. Se divergirem, "
        "a linha some do filtro de data e continua contando na media de prazo",
    ),
    Verificacao(
        "vendas sem pedido correspondente",
        "SELECT COUNT(*) FROM mart.fato_vendas f WHERE NOT EXISTS "
        "(SELECT 1 FROM staging.orders o WHERE o.order_id = f.order_id)",
        0,
        "a dimensao degenerada tem de continuar sendo o fio de volta ate o CSV",
    ),
)

# -- 5. Informativo ------------------------------------------------------------
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
    Verificacao(
        "pedidos distintos na fato",
        "SELECT COUNT(DISTINCT order_id) FROM mart.fato_vendas", None,
        "e este o numero que o painel vai mostrar, nao 99.441",
    ),
    Verificacao(
        "pedidos que ficaram FORA da fato",
        "SELECT (SELECT COUNT(*) FROM staging.orders) "
        "     - (SELECT COUNT(DISTINCT order_id) FROM mart.fato_vendas)", None,
        "pedidos sem item nenhum -- 77% deles 'unavailable'. O custo aceito do "
        "grao de item, medido em vez de descoberto",
    ),
    Verificacao(
        "itens sem data de entrega (sk -1)",
        "SELECT COUNT(*) FROM mart.fato_vendas WHERE sk_data_entrega = -1", None,
        "onde o membro 'Nao informado' da dim_data finalmente e usado",
    ),
    Verificacao(
        "itens de pedido nao efetivado",
        "SELECT COUNT(*) FROM mart.fato_vendas f "
        "JOIN mart.dim_status_pedido s ON s.sk_status = f.sk_status "
        "WHERE NOT s.eh_venda_efetiva", None,
        "cancelado ou indisponivel -- continuam na fato, e o DAX os exclui pelo "
        "eh_venda_efetiva em vez de por lista de status escrita a mao",
    ),
    Verificacao(
        "itens entregues com atraso",
        "SELECT COUNT(*) FROM mart.fato_vendas WHERE dias_vs_previsto > 0", None,
        "chegaram depois da data prevista",
    ),
    Verificacao(
        "prazo medio de entrega (dias)",
        "SELECT ROUND(AVG(dias_entrega), 1) FROM mart.fato_vendas", None,
        "media, nunca soma -- dias_entrega nao e medida aditiva",
    ),
    Verificacao(
        "receita total (preco + frete)",
        "SELECT SUM(preco + frete) FROM mart.fato_vendas", None,
        "inclui cancelados; a medida de receita do painel vai filtrar por "
        "eh_venda_efetiva",
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

    # A estrela inteira em uma consulta: a fato no centro e quatro dimensoes ao
    # redor. Se as chaves substitutas estivessem trocadas, a contagem e a soma
    # continuariam fechando -- so olhar categoria, cidade e status juntos na
    # mesma linha mostra que a traducao chave natural -> chave substituta
    # produziu a linha CERTA, e nao apenas uma linha valida.
    cur.execute("""
        SELECT dd.data, dp.categoria, dc.cidade, dc.estado, ds.status,
               f.preco, f.frete, f.dias_entrega, f.dias_vs_previsto
        FROM mart.fato_vendas f
        JOIN mart.dim_data          dd ON dd.sk_data   = f.sk_data_compra
        JOIN mart.dim_produto       dp ON dp.sk_produto = f.sk_produto
        JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
        JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
        ORDER BY f.preco DESC
        LIMIT 3
    """)
    print("    fato_vendas (as 3 vendas de maior valor, ja pela estrela)")
    for data, cat, cid, uf, st, preco, frete, dias, atraso in cur.fetchall():
        prazo = "nao entregue" if dias is None else f"{dias}d ({atraso:+d} vs previsto)"
        print(f"      {str(data):<12} {cat[:22]:<22} {cid[:16]:<16} {uf}  "
              f"{st:<12} R$ {preco:>8} + {frete:>6} frete  {prazo}")


# =============================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Constroi o modelo estrela da camada MART a partir da STAGING."
    )
    parser.add_argument("--so-verificar", action="store_true",
                        help="nao escreve nada; so roda as verificacoes")
    args = parser.parse_args()

    caminhos = [(PROJECT_ROOT / "sql" / nome, rotulo) for nome, rotulo in ETAPAS_SQL]
    for caminho, _ in caminhos:
        if not caminho.exists():
            sys.exit(f"Arquivo SQL nao encontrado: {caminho}")

    carrega_env(ENV_PATH)

    # UMA transacao para os quatro arquivos. Ou as cinco dimensoes e a fato
    # ficam coerentes entre si, ou o schema fica exatamente como estava -- nunca
    # meio caminho, que e o estado em que ninguem sabe se pode confiar no banco.
    #
    # Com a fato no jogo isso deixou de ser zelo e virou necessidade: uma fato
    # gravada apontando para dimensao que nao foi gravada e o pior estado
    # possivel deste banco, porque ele PARECE inteiro.
    with conecta() as con:
        with con.cursor() as cur:

            if args.so_verificar:
                print("--so-verificar: nada sera escrito.\n")
            else:
                print("[1/3] Construindo o modelo estrela")
                for caminho, rotulo in caminhos:
                    cur.execute(caminho.read_text(encoding="utf-8"))
                    print(f"  {rotulo:<22} ({caminho.name})")

            print("\n[2/3] Verificando")
            falhas = []
            falhas += roda_bloco(cur, "Contagem", CONTAGENS)
            falhas += roda_bloco(cur, "Integridade (o que constraint nao pega)", INTEGRIDADE)
            falhas += roda_bloco(cur, "Cobertura do calendario", DATAS)
            falhas += roda_bloco(cur, "Fato x origem", FATO)
            falhas += roda_bloco(cur, "Informativo", INFORMATIVO)
            mostra_amostra(cur)

            if falhas:
                # Levantar a excecao desfaz a transacao inteira: modelo que nao
                # passou na verificacao nao fica gravado. A alternativa --
                # gravar e avisar -- deixaria alguem construir um painel em
                # cima de numero que ja se sabe errado, e painel errado nao
                # avisa que esta errado.
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
    #
    # A FATO LEVA SO ANALYZE, E AS DIMENSOES LEVAM VACUUM ANALYZE. A diferenca
    # e consequencia direta de as duas usarem estrategias de carga opostas: a
    # fato e recarregada com TRUNCATE + INSERT e comeca vazia, entao nao ha
    # versao antiga de linha para o VACUUM limpar -- so a estatistica a
    # atualizar, e ela e a mais importante das seis, porque e a tabela grande
    # que aparece em toda juncao da proxima etapa.
    if not args.so_verificar:
        print("\n[3/3] Atualizando estatisticas")
        with conecta() as con:
            con.autocommit = True
            with con.cursor() as cur:
                for tabela in ("dim_data", "dim_cliente", "dim_vendedor",
                               "dim_produto", "dim_status_pedido"):
                    cur.execute(f"VACUUM (ANALYZE) mart.{tabela}")
                cur.execute("ANALYZE mart.fato_vendas")
        print("  Estatisticas atualizadas e espaco liberado para reuso")

    print("\nModelo estrela pronto em mart: 5 dimensoes + fato_vendas.")
    print("Proxima etapa: responder as primeiras perguntas de negocio em SQL.")
    print("\nInspecione com:")
    print('  psql -U postgres -d sales_intelligence -c "\\dt mart.*"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
