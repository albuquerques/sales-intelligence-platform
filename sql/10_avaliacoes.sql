-- =============================================================================
-- AVALIAÇÕES × ENTREGA: as consultas por trás do insight 1 de docs/insights.md
-- =============================================================================
--
-- ESTE ARQUIVO RODA NO DUCKDB, NÃO NO POSTGRESQL.
--
-- As avaliações (order_reviews) nunca entraram na STAGING nem na MART: estão em
-- grão de pedido, e a fato está em grão de item (ver docs/star_schema.md, "Por
-- que não há uma segunda fact table"). Elas só existem na camada RAW, que guarda
-- tudo como chegou. É dela que sai o achado mais forte do projeto.
--
-- Exige a RAW com o DATASET COMPLETO. Com a amostra, os números são outros:
--
--   python run.py raw
--   python -X utf8 -c "import duckdb; con = duckdb.connect('sales_intelligence.duckdb', read_only=True); [print(con.sql(s.query)) for s in con.extract_statements(open('sql/10_avaliacoes.sql', encoding='utf-8').read())]"
--
-- extract_statements é o separador do próprio DuckDB: ele entende comentário, e
-- um split pelo ponto e vírgula quebraria na primeira linha acima. O -X utf8 é
-- o configura_console() da linha de comando: sem ele, o console do Windows
-- (cp1252) não imprime as bordas das tabelas do DuckDB.
--
--
-- AS REGRAS, AS MESMAS DO RESTO DO PROJETO
-- -----------------------------------------------------------------------------
--
-- 1. RECORTE DO PAINEL: compra de 2017-01-01 a 2018-08-31. Sem o recorte as
--    médias são as mesmas (conferido), mas os números do documento são todos
--    deste período.
--
-- 2. SÓ PEDIDOS ENTREGUES, COM DATA DE ENTREGA. As duas condições, como na
--    armadilha C do sql/07: 8 pedidos têm status delivered e nenhuma data.
--
-- 3. ATRASO EM DIAS DE CALENDÁRIO, os dois lados truncados para data. A data
--    prevista vem sempre à meia-noite, e subtrair em timestamp puxaria o atraso
--    para baixo em até um dia. É a mesma regra da fato (sql/06).
--
-- 4. TODAS AS LINHAS DE order_reviews. A origem tem 814 review_id repetidos, e
--    alguns pedidos têm mais de uma avaliação. Conferido: contar uma avaliação
--    por pedido (a mais recente) muda o 69,7% para 69,8% e nada mais.
--
-- Tudo aqui é texto na RAW (VARCHAR), por isso os CAST.
--
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1a. A nota por faixa de atraso
-- -----------------------------------------------------------------------------
--
-- Resultado no recorte:
--   no prazo ............ 89.681 avaliações   nota 4,29    6,6% de 1 estrela
--   1 a 7 dias .......... 3.611                nota 2,71   41,4%
--   8 dias ou mais ...... 2.795                nota 1,70   69,7%
WITH entregues AS (
    SELECT order_id,
           CAST(order_delivered_customer_date AS DATE)
             - CAST(order_estimated_delivery_date AS DATE)          AS atraso
    FROM raw.orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_delivered_customer_date <> ''
      AND CAST(order_purchase_timestamp AS DATE)
          BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
)
SELECT
    CASE WHEN e.atraso <= 0 THEN '1. no prazo'
         WHEN e.atraso <= 7 THEN '2. atraso de 1 a 7 dias'
         ELSE                    '3. atraso de 8 dias ou mais'
    END                                                             AS entrega,
    count(*)                                                        AS avaliacoes,
    round(avg(CAST(r.review_score AS INTEGER)), 2)                  AS nota_media,
    round(100.0 * avg(CASE WHEN r.review_score = '1' THEN 1 ELSE 0 END), 1)
                                                                    AS pct_1_estrela
FROM entregues e
JOIN raw.order_reviews r USING (order_id)
GROUP BY 1
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 1b. De onde vêm as avaliações de 1 estrela
-- -----------------------------------------------------------------------------
--
-- A mesma base da 1a, lida pelo outro lado: das avaliações de 1 estrela, quantas
-- vieram de entrega atrasada. É o número que transforma "atraso irrita o
-- cliente" em tamanho de problema.
--
-- Resultado no recorte: 96.087 avaliações, 6,7% delas de entrega atrasada.
-- Mas as atrasadas são 36,7% das 9.367 avaliações de 1 estrela.
WITH entregues AS (
    SELECT order_id,
           CAST(order_delivered_customer_date AS DATE)
             - CAST(order_estimated_delivery_date AS DATE)          AS atraso
    FROM raw.orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_delivered_customer_date <> ''
      AND CAST(order_purchase_timestamp AS DATE)
          BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
)
SELECT
    count(*)                                                        AS avaliacoes,
    round(100.0 * avg(CASE WHEN e.atraso > 0 THEN 1 ELSE 0 END), 1) AS pct_entregas_atrasadas,
    count(*) FILTER (WHERE r.review_score = '1')                    AS avaliacoes_1_estrela,
    round(100.0 * count(*) FILTER (WHERE r.review_score = '1' AND e.atraso > 0)
                / count(*) FILTER (WHERE r.review_score = '1'), 1)  AS pct_das_1_estrela_com_atraso
FROM entregues e
JOIN raw.order_reviews r USING (order_id);


-- -----------------------------------------------------------------------------
-- 1c. A nota por região do cliente
-- -----------------------------------------------------------------------------
--
-- Liga o insight 1 ao 2: a região onde a promessa de prazo dá menos margem (o
-- Nordeste, sql/09) é também a de pior nota. Mesmo CASE de região do sql/07.
--
-- Resultado no recorte:
--   Nordeste ...... nota 3,97   13,0% de 1 estrela    <- a pior
--   Norte ......... nota 4,03   11,2%
--   Centro-Oeste .. nota 4,13    9,9%
--   Sudeste ....... nota 4,18    9,4%
--   Sul ........... nota 4,19    8,8%
SELECT
    CASE
        WHEN c.customer_state IN ('AC','AP','AM','PA','RO','RR','TO')           THEN '1. Norte'
        WHEN c.customer_state IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN '2. Nordeste'
        WHEN c.customer_state IN ('DF','GO','MT','MS')                          THEN '3. Centro-Oeste'
        WHEN c.customer_state IN ('ES','MG','RJ','SP')                          THEN '4. Sudeste'
        WHEN c.customer_state IN ('PR','RS','SC')                               THEN '5. Sul'
    END                                                             AS regiao,
    count(*)                                                        AS avaliacoes,
    round(avg(CAST(r.review_score AS INTEGER)), 2)                  AS nota_media,
    round(100.0 * avg(CASE WHEN r.review_score = '1' THEN 1 ELSE 0 END), 1)
                                                                    AS pct_1_estrela
FROM raw.orders o
JOIN raw.customers     c USING (customer_id)
JOIN raw.order_reviews r USING (order_id)
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_delivered_customer_date <> ''
  AND CAST(o.order_purchase_timestamp AS DATE)
      BETWEEN DATE '2017-01-01' AND DATE '2018-08-31'
GROUP BY 1
ORDER BY 1;
