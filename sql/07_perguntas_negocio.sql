-- =============================================================================
-- 07 — AS PRIMEIRAS PERGUNTAS DE NEGÓCIO
-- =============================================================================
--
-- Esta é a primeira etapa que CONSOME o modelo estrela em vez de construí-lo, e
-- é ela que revela se o modelo presta: pergunta que exige contorcionismo em SQL
-- é sintoma de modelagem errada, não de SQL fraco.
--
-- O arquivo é SOMENTE LEITURA. Nenhum comando aqui escreve, cria ou altera
-- objeto — dá para rodar inteiro, quantas vezes quiser, sem consequência:
--
--   psql -U postgres -d sales_intelligence -f sql/07_perguntas_negocio.sql
--
-- POR QUE NENHUMA CONSULTA VIROU VIEW (ainda). A tentação é transformar as mais
-- úteis em view da mart. Foi descartado por ora: view é para consulta que se
-- REPETE, e quem vai repetir é o Power BI — que ainda não existe. Criar view
-- agora seria adivinhar o que ele vai pedir, e cada view é mais um lugar onde a
-- regra de negócio passa a morar. Quando o painel estiver montado, o que ele
-- repetir vira view com motivo, não com palpite.
--
--
-- AS DUAS REGRAS QUE VALEM PARA O ARQUIVO INTEIRO
-- -----------------------------------------------------------------------------
--
-- 1. RECEITA = preco + frete.
--
--    É o que o cliente pagou, e é a definição que fecha com a âncora de
--    docs/dashboard.md (R$ 15.843.553,24 com cancelados). A alternativa — receita só de
--    mercadoria, frete tratado como repasse — é defensável, e por isso as duas
--    parcelas aparecem SEPARADAS onde a diferença importa (P2 e P7). O que não
--    pode é oscilar entre as duas sem avisar: dois números do painel
--    discordariam e ninguém saberia qual está certo.
--
-- 2. DINHEIRO EXCLUI CANCELADO; VOLUME MOSTRA OS DOIS.
--
--    Toda pergunta de receita filtra `ds.eh_venda_efetiva` — venda que não
--    aconteceu não é faturamento. Perguntas de volume e de operação NÃO
--    filtram: elas põem o status na quebra, porque "quanto se cancela" é uma
--    pergunta de negócio, e um filtro a esconderia (P8).
--
--    Conferência das duas âncoras, que precisam bater sempre:
--      com cancelados ....... R$ 15.843.553,24   (549 itens não efetivados)
--      sem cancelados ....... R$ 15.735.527,03   <- base de toda receita aqui
--      diferença ............ R$    108.026,21
--
--
-- AS TRÊS ARMADILHAS QUE ESTAS CONSULTAS PRECISAM DESVIAR
-- -----------------------------------------------------------------------------
--
-- A. O GRÃO É DE ITEM, NÃO DE PEDIDO.
--    COUNT(*) conta ITENS. Pedido com 3 itens vira 3 linhas. Por isso:
--      - contagem de pedidos é sempre COUNT(DISTINCT order_id);
--      - ticket médio EXIGE agregar por pedido antes de tirar média (P3) —
--        AVG(preco + frete) direto na fato responde outra pergunta
--        ("valor médio do item"), e responde certo, o que é justamente o
--        perigo: número plausível para a pergunta errada.
--
-- B. A SÉRIE TEMPORAL TEM BURACO E TEM TOCO.
--    O dataset não é um retângulo de 24 meses. Medido:
--      2016-09 ...... 6 itens        \
--      2016-10 .... 363 itens         |  operação em teste
--      2016-11 ...... 0 itens  <- MÊS INTEIRO AUSENTE
--      2016-12 ...... 1 item         /
--      2017-01 .... 955 itens
--      ...
--      2018-09 ...... 1 item   <- corte da extração, não queda de vendas
--    Num gráfico de linha isso vira um despencar no fim que qualquer leitor
--    interpreta como colapso do negócio. P1 marca cada mês como pleno ou
--    parcial em vez de deixar o leitor descobrir sozinho.
--
-- C. STATUS "ENTREGUE" E DATA DE ENTREGA SE CONTRADIZEM EM 8 ITENS.
--    A origem tem 8 itens com status delivered e SEM data de entrega. Eles
--    ficam com eh_entregue = TRUE e sk_data_entrega = -1 ao mesmo tempo.
--    Toda análise de SLA usa as DUAS condições — eh_entregue E
--    dias_entrega IS NOT NULL — nunca só uma.
--
-- =============================================================================


-- =============================================================================
-- P1. Como a receita evoluiu mês a mês — e o negócio está crescendo?
-- =============================================================================
--
-- A pergunta que abre qualquer painel de vendas. Aqui ela serve também para
-- estabelecer a armadilha B acima: a resposta honesta precisa dizer quais meses
-- podem ser lidos e quais não.
--
-- eh_mes_pleno é calculado, não digitado: o critério é o próprio dado (mês com
-- menos de 2.000 itens não é mês de operação normal — os plenos têm entre 5 mil
-- e 13 mil). Digitar a lista de meses ruins funcionaria hoje e mentiria no dia
-- em que o dataset mudasse.
SELECT
    d.ano_mes                                                    AS mes,
    COUNT(DISTINCT f.order_id)                                   AS pedidos,
    COUNT(*)                                                     AS itens,
    SUM(f.preco + f.frete)                                       AS receita,
    -- Variação contra o mês anterior. LAG é o operador que existe exatamente
    -- para isso; a alternativa (self-join da tabela com ela mesma deslocada)
    -- faz o mesmo com o dobro do SQL e um JOIN a mais para errar.
    ROUND(
        100.0 * (SUM(f.preco + f.frete) - LAG(SUM(f.preco + f.frete)) OVER (ORDER BY d.ano_mes))
              / NULLIF(LAG(SUM(f.preco + f.frete)) OVER (ORDER BY d.ano_mes), 0)
    , 1)                                                         AS var_pct,
    COUNT(*) >= 2000                                             AS eh_mes_pleno
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data   = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status = f.sk_status
WHERE ds.eh_venda_efetiva
GROUP BY d.ano_mes
ORDER BY d.ano_mes;


-- =============================================================================
-- P2. Quais categorias sustentam o faturamento? (curva ABC)
-- =============================================================================
--
-- A pergunta central da página de produtos, e a que justificou o grão de item:
-- no grão de pedido, dim_produto seria inalcançável e esta consulta não
-- existiria.
--
-- Não basta ordenar por receita — a decisão de negócio ("em quantas categorias
-- eu preciso prestar atenção?") depende do ACUMULADO. As duas funções de janela
-- fazem isso sem uma segunda passada na tabela:
--   SUM(...) OVER ()                 = total geral, repetido em toda linha
--   SUM(...) OVER (ORDER BY ...)     = soma corrida até a linha atual
--
-- preco e frete aparecem separados aqui de propósito (regra 1 do cabeçalho):
-- categoria de móvel carrega frete que categoria de perfumaria não carrega, e
-- somar os dois numa coluna só esconderia isso.
WITH por_categoria AS (
    SELECT
        dp.categoria,
        SUM(f.preco)           AS mercadoria,
        SUM(f.frete)           AS frete,
        SUM(f.preco + f.frete) AS receita,
        COUNT(*)               AS itens
    FROM mart.fato_vendas f
    JOIN mart.dim_produto       dp ON dp.sk_produto = f.sk_produto
    JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
    WHERE ds.eh_venda_efetiva
    GROUP BY dp.categoria
)
SELECT
    ROW_NUMBER() OVER (ORDER BY receita DESC)                          AS pos,
    categoria,
    itens,
    mercadoria,
    frete,
    receita,
    ROUND(100.0 * receita / SUM(receita) OVER (), 2)                   AS pct,
    ROUND(100.0 * SUM(receita) OVER (ORDER BY receita DESC
                                     ROWS UNBOUNDED PRECEDING)
                / SUM(receita) OVER (), 2)                             AS pct_acum,
    -- Classificação ABC clássica: A = as que fazem os primeiros 80%.
    CASE WHEN 100.0 * SUM(receita) OVER (ORDER BY receita DESC
                                         ROWS UNBOUNDED PRECEDING)
                    / SUM(receita) OVER () <= 80 THEN 'A'
         WHEN 100.0 * SUM(receita) OVER (ORDER BY receita DESC
                                         ROWS UNBOUNDED PRECEDING)
                    / SUM(receita) OVER () <= 95 THEN 'B'
         ELSE 'C'
    END                                                                AS classe
FROM por_categoria
ORDER BY receita DESC;


-- =============================================================================
-- P3. Quanto vale um pedido? (ticket médio — e a armadilha do grão)
-- =============================================================================
--
-- ESTA É A CONSULTA QUE MAIS ENSINA DO ARQUIVO.
--
-- A fato está no grão de ITEM. AVG(preco + frete) direto nela dá o valor médio
-- do ITEM, não do PEDIDO — e dá um número plausível, o que é exatamente o
-- perigo: nada quebra, nenhum erro aparece, e o painel passa a mostrar ticket
-- médio errado para baixo (porque pedido com 3 itens é contado 3 vezes, cada
-- uma pelo valor de um item só).
--
-- A resposta certa tem duas etapas: agregar ATÉ o grão de pedido, e só então
-- tirar a média. É para isso que o CTE existe.
--
-- MÉDIA E MEDIANA JUNTAS, sempre. Se a média for muito maior que a mediana, a
-- distribuição tem cauda longa à direita — poucos pedidos caros puxando o
-- número — e reportar só a média descreveria um pedido típico que não existe.
WITH pedido AS (
    SELECT
        f.order_id,
        SUM(f.preco + f.frete)       AS valor,
        COUNT(*)                     AS itens,
        COUNT(DISTINCT f.sk_produto) AS produtos_distintos
    FROM mart.fato_vendas f
    JOIN mart.dim_status_pedido ds ON ds.sk_status = f.sk_status
    WHERE ds.eh_venda_efetiva
    GROUP BY f.order_id
)
SELECT
    COUNT(*)                                                          AS pedidos,
    ROUND(AVG(valor), 2)                                              AS ticket_medio,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY valor)::numeric, 2)
                                                                      AS ticket_mediano,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY valor)::numeric, 2)
                                                                      AS p90,
    MAX(valor)                                                        AS maior_pedido,
    ROUND(AVG(itens), 2)                                              AS itens_por_pedido,
    COUNT(*) FILTER (WHERE itens > 1)                                 AS pedidos_multi_item,
    -- A comparação que prova a armadilha: o mesmo dinheiro dividido pelo
    -- denominador errado. A diferença entre as duas colunas é o tamanho do erro
    -- que um AVG ingênuo cometeria.
    ROUND(SUM(valor) / SUM(itens), 2)                                 AS valor_medio_do_item
FROM pedido;


-- =============================================================================
-- P4. Onde estão os clientes e o dinheiro? (concentração geográfica)
-- =============================================================================
--
-- Página de clientes. COUNT(DISTINCT dc.sk_cliente) conta PESSOAS, e só conta
-- porque a etapa das dimensões escolheu o grão de customer_unique_id: com o
-- grão de customer_id (que muda a cada pedido) esta coluna seria idêntica à de
-- pedidos e não informaria nada.
SELECT
    dc.estado,
    COUNT(DISTINCT dc.sk_cliente)                                     AS clientes,
    COUNT(DISTINCT f.order_id)                                        AS pedidos,
    SUM(f.preco + f.frete)                                            AS receita,
    ROUND(100.0 * SUM(f.preco + f.frete) / SUM(SUM(f.preco + f.frete)) OVER (), 2)
                                                                      AS pct_receita,
    ROUND(100.0 * SUM(SUM(f.preco + f.frete)) OVER (ORDER BY SUM(f.preco + f.frete) DESC
                                                   ROWS UNBOUNDED PRECEDING)
                / SUM(SUM(f.preco + f.frete)) OVER (), 2)             AS pct_acum,
    ROUND(SUM(f.preco + f.frete) / COUNT(DISTINCT f.order_id), 2)     AS ticket_medio
FROM mart.fato_vendas f
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
WHERE ds.eh_venda_efetiva
GROUP BY dc.estado
ORDER BY receita DESC;


-- =============================================================================
-- P5. O cliente volta? (recorrência)
-- =============================================================================
--
-- A pergunta que o grão errado teria zerado. Com customer_id como grão da
-- dimensão, TODO cliente teria exatamente 1 pedido e a taxa de recorrência daria
-- 0% — sem erro, sem sintoma, sem ninguém desconfiar.
--
-- CUIDADO COM dc.qtd_pedidos: ela foi calculada na carga da dimensão a partir
-- de staging.orders, e conta TODOS os pedidos da pessoa, inclusive os 775 que
-- não têm item e por isso não existem na fato. Para a quebra ser coerente com a
-- receita que está ao lado, a contagem é refeita AQUI, sobre a fato.
WITH cliente AS (
    SELECT
        f.sk_cliente,
        COUNT(DISTINCT f.order_id) AS pedidos,
        SUM(f.preco + f.frete)     AS receita
    FROM mart.fato_vendas f
    JOIN mart.dim_status_pedido ds ON ds.sk_status = f.sk_status
    WHERE ds.eh_venda_efetiva
    GROUP BY f.sk_cliente
)
SELECT
    CASE WHEN pedidos = 1 THEN '1 pedido'
         WHEN pedidos = 2 THEN '2 pedidos'
         WHEN pedidos BETWEEN 3 AND 5 THEN '3 a 5 pedidos'
         ELSE '6+ pedidos'
    END                                                               AS faixa,
    COUNT(*)                                                          AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                AS pct_clientes,
    SUM(receita)                                                      AS receita,
    ROUND(100.0 * SUM(receita) / SUM(SUM(receita)) OVER (), 2)        AS pct_receita,
    ROUND(AVG(receita), 2)                                            AS receita_por_cliente
FROM cliente
GROUP BY faixa
ORDER BY MIN(pedidos);


-- =============================================================================
-- P6. A entrega cumpre o prazo? (SLA por estado)
-- =============================================================================
--
-- Aqui a armadilha C do cabeçalho cobra: o filtro usa eh_entregue E
-- dias_entrega IS NOT NULL. Com só o primeiro, 8 itens entrariam na conta sem
-- ter prazo; com só o segundo, a leitura fica correta por acidente e para de
-- ficar no dia em que outro status ganhar data.
--
-- dias_vs_previsto é NEGATIVO quando a entrega foi ANTES do previsto — por isso
-- atraso é > 0. Guardar o sinal em vez de um booleano "atrasou" foi o que
-- permitiu medir também a folga média, que é a outra metade da pergunta: prazo
-- cumprido com 12 dias de sobra não é pontualidade, é previsão inflada.
SELECT
    dc.estado,
    COUNT(*)                                                          AS itens_entregues,
    ROUND(AVG(f.dias_entrega), 1)                                     AS dias_medio,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.dias_entrega)::numeric, 0)
                                                                      AS dias_p90,
    COUNT(*) FILTER (WHERE f.dias_vs_previsto > 0)                    AS atrasados,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.dias_vs_previsto > 0) / COUNT(*), 2)
                                                                      AS pct_atraso,
    -- Folga média: quanto o prazo prometido sobrou. Negativo = entregue antes.
    ROUND(AVG(f.dias_vs_previsto), 1)                                 AS folga_media
FROM mart.fato_vendas f
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
WHERE ds.eh_entregue
  AND f.dias_entrega IS NOT NULL      -- as duas condições, nunca só uma
GROUP BY dc.estado
HAVING COUNT(*) >= 100                -- estado com 20 entregas não tem média confiável
ORDER BY pct_atraso DESC;


-- =============================================================================
-- P7. Quanto o frete pesa, e para quem?
-- =============================================================================
--
-- Pergunta que só existe porque preco e frete ficaram em colunas separadas na
-- fato. Se a etapa anterior tivesse gravado valor_total, esta análise estaria
-- perdida — e é a que liga a página de clientes à de produtos: frete alto sobre
-- item barato é o que mata conversão em estado distante.
--
-- A quebra é por REGIÃO e não por estado para a tabela caber na resposta; o CASE
-- está aqui e não numa dimensão de propósito — se a região virar recorrente, ela
-- vira coluna de dim_cliente, que é onde atributo de cliente mora. Enquanto é
-- uma consulta só, CASE local é honesto; repetido em cinco consultas, seria
-- regra de negócio espalhada.
SELECT
    CASE
        WHEN dc.estado IN ('AC','AP','AM','PA','RO','RR','TO')           THEN '1 Norte'
        WHEN dc.estado IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN '2 Nordeste'
        WHEN dc.estado IN ('DF','GO','MT','MS')                          THEN '3 Centro-Oeste'
        WHEN dc.estado IN ('ES','MG','RJ','SP')                          THEN '4 Sudeste'
        WHEN dc.estado IN ('PR','RS','SC')                               THEN '5 Sul'
    END                                                               AS regiao,
    COUNT(*)                                                          AS itens,
    ROUND(AVG(f.preco), 2)                                            AS preco_medio,
    ROUND(AVG(f.frete), 2)                                            AS frete_medio,
    -- O percentual é calculado sobre os TOTAIS, não como média de percentuais.
    -- AVG(frete/preco) daria peso igual a um item de R$ 10 e a um de R$ 5.000,
    -- e a cauda de itens baratíssimos dominaria o resultado.
    ROUND(100.0 * SUM(f.frete) / SUM(f.preco), 1)                     AS frete_pct_preco,
    ROUND(AVG(f.dias_entrega), 1)                                     AS dias_medio
FROM mart.fato_vendas f
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
WHERE ds.eh_venda_efetiva
GROUP BY regiao
ORDER BY regiao;


-- =============================================================================
-- P8. O que não vira venda? (taxa de perda por categoria)
-- =============================================================================
--
-- ÚNICA CONSULTA DO ARQUIVO SEM O FILTRO eh_venda_efetiva — e é a razão de a
-- regra ser "dinheiro exclui, volume mostra os dois". Filtrar aqui esconderia
-- justamente o que se quer medir.
--
-- FILTER (WHERE ...) em vez de SUM(CASE WHEN ... THEN 1 ELSE 0 END): mesmo
-- resultado, e diz o que faz. É SQL padrão desde 2003 e o PostgreSQL implementa.
--
-- O HAVING corta categoria pequena: 1 cancelamento em 3 itens dá 33% e não
-- significa nada. Sem ele, o topo da lista seria só ruído estatístico — o erro
-- clássico de ranking por percentual sobre base pequena.
SELECT
    dp.categoria,
    COUNT(*)                                                          AS itens,
    COUNT(*) FILTER (WHERE ds.status_origem = 'canceled')             AS cancelados,
    COUNT(*) FILTER (WHERE ds.status_origem = 'unavailable')          AS indisponiveis,
    ROUND(100.0 * COUNT(*) FILTER (WHERE NOT ds.eh_venda_efetiva) / COUNT(*), 2)
                                                                      AS pct_perdido,
    -- Quanto de receita a categoria deixou na mesa.
    SUM(f.preco + f.frete) FILTER (WHERE NOT ds.eh_venda_efetiva)     AS receita_perdida
FROM mart.fato_vendas f
JOIN mart.dim_produto       dp ON dp.sk_produto = f.sk_produto
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
GROUP BY dp.categoria
HAVING COUNT(*) >= 500
ORDER BY pct_perdido DESC
LIMIT 15;
