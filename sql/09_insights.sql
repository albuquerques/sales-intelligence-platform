-- =============================================================================
-- INSIGHTS: as consultas por trás de docs/insights.md que o painel não mostra
-- =============================================================================
--
-- Somente leitura, sobre a MART (PostgreSQL). Não faz parte do build, como o 07.
--
--   psql -U postgres -d sales_intelligence -f sql/09_insights.sql
--
-- A nota de avaliação (insight 1) não está aqui: as avaliações só existem na
-- camada RAW, e as consultas dela rodam no DuckDB (sql/10_avaliacoes.sql).
--
--
-- DIFERENÇA PARA O sql/07
-- -----------------------------------------------------------------------------
--
-- O 07 responde sobre o DATASET INTEIRO. Este arquivo usa o RECORTE DO PAINEL,
-- compra de 2017-01-01 a 2018-08-31, porque docs/insights.md é escrito para
-- ser conferido no painel. Um documento com números de dois períodos obrigaria
-- o leitor a descobrir sozinho por que 17 categorias viraram 18.
--
-- O filtro se repete em toda consulta, de propósito: cada uma roda sozinha,
-- copiada para qualquer cliente SQL.
--
-- As duas regras do 07 continuam valendo: receita = preco + frete, e dinheiro
-- exclui cancelado. As de prazo usam eh_entregue E dias_entrega IS NOT NULL.
--
-- =============================================================================


-- =============================================================================
-- INSIGHT 2. A margem da promessa de prazo explica o atraso
-- =============================================================================
--
-- Prazo prometido = dias_entrega - dias_vs_previsto (dias_vs_previsto é
-- negativo quando a entrega chegou antes). A MARGEM é quantas vezes o prazo
-- prometido cabe no prazo real: 2,0 quer dizer que se prometeu o dobro do que
-- a entrega costuma levar.
--
-- A hipótese antiga do projeto era "o estado que mais precisa de folga é o que
-- menos recebe", tirada de dois estados (AL e PR). A 2c testa essa frase no país
-- inteiro, e ela não se sustenta. O que se sustenta é a margem proporcional.


-- 2a. Por região
--
-- Resultado:
--   região          prazo real   90% chegam em   prometido   margem   atraso
--   Norte ............ 22,5 d        37 d          38,2 d     1,70     8,7%
--   Nordeste ......... 19,8 d        33 d          31,2 d     1,58    12,6%
--   Centro-Oeste ..... 14,9 d        24 d          27,3 d     1,84     6,5%
--   Sudeste .......... 10,6 d        19 d          22,2 d     2,10     5,9%
--   Sul .............. 13,9 d        24 d          27,1 d     1,94     5,8%
--
-- O Nordeste é a única região em que o prazo prometido médio fica ABAIXO do
-- tempo em que 90% das entregas chegam (31,2 contra 33 dias).
SELECT
    CASE
        WHEN dc.estado IN ('AC','AP','AM','PA','RO','RR','TO')           THEN '1. Norte'
        WHEN dc.estado IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN '2. Nordeste'
        WHEN dc.estado IN ('DF','GO','MT','MS')                          THEN '3. Centro-Oeste'
        WHEN dc.estado IN ('ES','MG','RJ','SP')                          THEN '4. Sudeste'
        WHEN dc.estado IN ('PR','RS','SC')                               THEN '5. Sul'
    END                                                               AS regiao,
    COUNT(*)                                                          AS entregues,
    ROUND(AVG(f.dias_entrega), 1)                                     AS prazo_real,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.dias_entrega)::numeric, 0)
                                                                      AS prazo_real_p90,
    ROUND(AVG(f.dias_entrega - f.dias_vs_previsto), 1)                AS prazo_prometido,
    ROUND(AVG(f.dias_entrega - f.dias_vs_previsto) / AVG(f.dias_entrega), 2)
                                                                      AS margem,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.dias_vs_previsto > 0) / COUNT(*), 1)
                                                                      AS pct_atraso
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_entregue
  AND f.dias_entrega IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- 2b. Por estado, da menor margem para a maior
--
-- Só estados com 100+ entregas: RR (45), AP (81) e similares não têm média
-- confiável. Os seis primeiros da lista são todos do Nordeste (AL, MA, SE, CE,
-- BA e PI), e AL é o extremo: promete 1,36 vez o prazo real e atrasa 20,9%.
-- SP está na outra ponta: 2,29 e 4,4%.
--
-- A exceção que merece nota é RJ: margem 1,79, no meio da tabela, e 11,7% de
-- atraso. Ali a margem não explica tudo, e a causa está fora deste dado.
SELECT
    dc.estado,
    COUNT(*)                                                          AS entregues,
    ROUND(AVG(f.dias_entrega), 1)                                     AS prazo_real,
    ROUND(AVG(f.dias_entrega - f.dias_vs_previsto), 1)                AS prazo_prometido,
    ROUND(AVG(f.dias_entrega - f.dias_vs_previsto) / AVG(f.dias_entrega), 2)
                                                                      AS margem,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.dias_vs_previsto > 0) / COUNT(*), 1)
                                                                      AS pct_atraso
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_entregue
  AND f.dias_entrega IS NOT NULL
GROUP BY dc.estado
HAVING COUNT(*) >= 100
ORDER BY margem;


-- 2c. O teste: qual medida da promessa anda junto com o atraso?
--
-- Correlação entre os 24 estados com 100+ entregas (de -1 a 1):
--   prazo real × folga em dias ........ -0,19   a frase antiga não se sustenta:
--                                               prazo longo NÃO recebe menos folga
--   folga em dias × atraso ............  0,69
--   margem proporcional × atraso ...... -0,87   a mais forte das três
--
-- A folga em dias quase não varia com o prazo real (de 11 a 16 dias entre as
-- regiões, enquanto o prazo real vai de 10,6 a 22,5). Somada a um prazo longo,
-- vira uma margem pequena, e é aí que a entrega atrasa.
WITH estado AS (
    SELECT
        dc.estado,
        AVG(f.dias_entrega)                                           AS prazo_real,
        AVG(f.dias_vs_previsto)                                       AS folga,
        AVG(f.dias_entrega - f.dias_vs_previsto) / AVG(f.dias_entrega) AS margem,
        AVG(CASE WHEN f.dias_vs_previsto > 0 THEN 1.0 ELSE 0 END)     AS atraso
    FROM mart.fato_vendas f
    JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
    JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
    JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
    WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
      AND ds.eh_entregue
      AND f.dias_entrega IS NOT NULL
    GROUP BY dc.estado
    HAVING COUNT(*) >= 100
)
SELECT
    COUNT(*)                                                          AS estados,
    ROUND(CORR(prazo_real, folga)::numeric, 2)                        AS prazo_real_x_folga,
    ROUND(CORR(folga, atraso)::numeric, 2)                            AS folga_x_atraso,
    ROUND(CORR(margem, atraso)::numeric, 2)                           AS margem_x_atraso
FROM estado;


-- =============================================================================
-- INSIGHT 3. Quase toda venda é a primeira venda de alguém
-- =============================================================================
--
-- Pedidos de recompra = pedidos - clientes: cada cliente tem exatamente uma
-- primeira compra, e o que passa disso é volta.
--
-- Resultado: 97.905 pedidos, 94.703 clientes, 3.202 recompras (3,27%).
-- Ou seja, 96,7% dos pedidos do período são a primeira compra de alguém.
SELECT
    COUNT(DISTINCT f.order_id)                                        AS pedidos,
    COUNT(DISTINCT f.sk_cliente)                                      AS clientes,
    COUNT(DISTINCT f.order_id) - COUNT(DISTINCT f.sk_cliente)         AS recompras,
    ROUND(100.0 * (COUNT(DISTINCT f.order_id) - COUNT(DISTINCT f.sk_cliente))
                / COUNT(DISTINCT f.order_id), 2)                      AS pct_recompra
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data    = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status = f.sk_status
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_venda_efetiva;


-- 3b. Receita por mês: o crescimento parou em 2018
--
-- Em 2017 a receita mensal dobrou (R$ 425,6 mil em março, o primeiro mês com
-- 2.000+ itens, para R$ 861,5 mil em dezembro), com o pico da Black Friday em
-- novembro: +53,3% sobre outubro. De janeiro a agosto de 2018 ela ficou entre
-- R$ 979 mil e R$ 1,16 milhão, sem tendência de alta.
SELECT
    d.ano_mes,
    COUNT(*)                                                          AS itens,
    SUM(f.preco + f.frete)                                            AS receita,
    ROUND(100.0 * (SUM(f.preco + f.frete) - LAG(SUM(f.preco + f.frete)) OVER (ORDER BY d.ano_mes))
                / LAG(SUM(f.preco + f.frete)) OVER (ORDER BY d.ano_mes), 1)
                                                                      AS var_pct
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data    = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status = f.sk_status
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_venda_efetiva
GROUP BY d.ano_mes
ORDER BY d.ano_mes;


-- =============================================================================
-- INSIGHT 4. O frete pesa mais longe do Sudeste
-- =============================================================================
--
-- Frete sobre o valor da mercadoria, calculado sobre os TOTAIS (como no 07, P7):
-- a média de percentuais daria o mesmo peso a um item de R$ 10 e a um de
-- R$ 5.000.
--
-- Resultado: Norte 22,7%, Nordeste 21,7%, Centro-Oeste 17,6%, Sul 17,6%,
-- Sudeste 15,2%.
SELECT
    CASE
        WHEN dc.estado IN ('AC','AP','AM','PA','RO','RR','TO')           THEN '1. Norte'
        WHEN dc.estado IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN '2. Nordeste'
        WHEN dc.estado IN ('DF','GO','MT','MS')                          THEN '3. Centro-Oeste'
        WHEN dc.estado IN ('ES','MG','RJ','SP')                          THEN '4. Sudeste'
        WHEN dc.estado IN ('PR','RS','SC')                               THEN '5. Sul'
    END                                                               AS regiao,
    COUNT(*)                                                          AS itens,
    ROUND(100.0 * SUM(f.frete) / SUM(f.preco), 1)                     AS frete_pct_mercadoria
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_venda_efetiva
GROUP BY 1
ORDER BY 1;


-- 4b. O ticket mais alto longe do Sudeste NÃO é só frete
--
-- A documentação dizia que o cliente distante "paga mais pelo mesmo carrinho".
-- Separando o ticket em mercadoria e frete, não é o mesmo carrinho:
--
--   estado   mercadoria/pedido   frete/pedido   ticket
--   SP ......... R$ 125,60        R$ 17,37      R$ 142,97
--   RJ ......... R$ 142,42        R$ 23,95      R$ 166,37
--   BA ......... R$ 151,58        R$ 29,85      R$ 181,44
--
-- Dos R$ 38,47 entre BA e SP, R$ 12,48 são frete (um terço) e R$ 25,98 são
-- mercadoria mais cara. Uma leitura possível, que este dado não prova: o frete
-- filtra as compras baratas longe do Sudeste, e sobram as que o compensam.
SELECT
    dc.estado,
    COUNT(DISTINCT f.order_id)                                        AS pedidos,
    ROUND(SUM(f.preco) / COUNT(DISTINCT f.order_id), 2)               AS mercadoria_por_pedido,
    ROUND(SUM(f.frete) / COUNT(DISTINCT f.order_id), 2)               AS frete_por_pedido,
    ROUND(SUM(f.preco + f.frete) / COUNT(DISTINCT f.order_id), 2)     AS ticket
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_venda_efetiva
  AND dc.estado IN ('SP', 'RJ', 'BA')
GROUP BY dc.estado
ORDER BY ticket;


-- 4c. Densidade de valor: peso e preço do item nas duas pontas
--
-- O peso é o do anúncio (product_weight_g da origem, peso_g na MART).
--
-- Resultado:
--   categoria            frete    peso médio   preço médio
--   Moveis Decoracao ... 23,68%     2,65 kg     R$  87,69
--   Relogios Presentes .  8,37%     0,58 kg     R$ 200,31
SELECT
    dp.categoria,
    COUNT(*)                                                          AS itens,
    ROUND(100.0 * SUM(f.frete) / SUM(f.preco), 2)                     AS frete_pct_mercadoria,
    ROUND(AVG(dp.peso_g) / 1000.0, 2)                                 AS peso_medio_kg,
    ROUND(AVG(f.preco), 2)                                            AS preco_medio
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
JOIN mart.dim_produto       dp ON dp.sk_produto = f.sk_produto
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_venda_efetiva
  AND dp.categoria IN ('Moveis Decoracao', 'Relogios Presentes')
GROUP BY dp.categoria
ORDER BY frete_pct_mercadoria DESC;


-- =============================================================================
-- INSIGHT 6. O que não vira venda
-- =============================================================================
--
-- Sem o filtro eh_venda_efetiva, porque a perda é a própria pergunta (P8).
-- No recorte, todo item perdido é cancelamento: os pedidos 'unavailable' quase
-- nunca têm item, e pedido sem item não existe na fato (ver star_schema.md,
-- "O grão").
--
-- Resultado: 527 de 112.279 itens (0,47%), R$ 102.496,83.
SELECT
    COUNT(*)                                                          AS itens,
    COUNT(*) FILTER (WHERE NOT ds.eh_venda_efetiva)                   AS nao_efetivados,
    COUNT(*) FILTER (WHERE ds.status_origem = 'canceled')             AS cancelados,
    ROUND(100.0 * COUNT(*) FILTER (WHERE NOT ds.eh_venda_efetiva) / COUNT(*), 2)
                                                                      AS pct_perdido,
    SUM(f.preco + f.frete) FILTER (WHERE NOT ds.eh_venda_efetiva)     AS receita_perdida
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data    = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status = f.sk_status
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31';


-- =============================================================================
-- CONTEXTO. Onde está o negócio
-- =============================================================================
--
-- Resultado: SP, RJ e MG somam 62,5% da receita e 66,5% dos clientes.
SELECT
    ROUND(100.0 * SUM(f.preco + f.frete) FILTER (WHERE dc.estado IN ('SP','RJ','MG'))
                / SUM(f.preco + f.frete), 1)                          AS pct_receita_sp_rj_mg,
    ROUND(100.0 * COUNT(DISTINCT f.sk_cliente) FILTER (WHERE dc.estado IN ('SP','RJ','MG'))
                / COUNT(DISTINCT f.sk_cliente), 1)                    AS pct_clientes_sp_rj_mg
FROM mart.fato_vendas f
JOIN mart.dim_data          d  ON d.sk_data     = f.sk_data_compra
JOIN mart.dim_status_pedido ds ON ds.sk_status  = f.sk_status
JOIN mart.dim_cliente       dc ON dc.sk_cliente = f.sk_cliente
WHERE d.data BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
  AND ds.eh_venda_efetiva;
