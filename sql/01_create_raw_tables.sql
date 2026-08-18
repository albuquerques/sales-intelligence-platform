-- =============================================================================
-- CAMADA RAW — estrutura das tabelas de aterrissagem
-- =============================================================================
--
-- Princípios desta camada (e o porquê de cada um):
--
-- 1. TODA COLUNA É VARCHAR.
--    A camada RAW é uma cópia fiel da fonte. Se tentássemos converter
--    order_purchase_timestamp para TIMESTAMP já na entrada, uma única linha com
--    data malformada derrubaria a carga inteira dos 99.441 pedidos. Aqui a
--    prioridade é *receber o dado*; a tipagem acontece na camada seguinte, onde
--    dá para tratar o erro sem perder o resto.
--
-- 2. NENHUMA CONSTRAINT (sem PK, FK, NOT NULL, UNIQUE).
--    Sabemos pelo profiling que review_id tem duplicatas. Uma PK em
--    raw.order_reviews rejeitaria essas linhas — e perder dado bruto por causa
--    de um problema conhecido é o contrário do que a RAW existe para fazer.
--    Ela guarda o problema para que ele possa ser tratado, não escondido.
--
-- 3. NOMES DE COLUNA IDÊNTICOS AO CSV, ERROS INCLUÍDOS.
--    "product_name_lenght" está escrito errado na origem (o correto seria
--    "length"). Mantemos o erro aqui de propósito: se o nome mudar na RAW,
--    ninguém consegue comparar a tabela com o arquivo original. A correção é
--    feita no rename da próxima camada.
--
-- 4. COLUNAS DE LINHAGEM (_source_file, _ingested_at).
--    Prefixadas com "_" para separá-las visualmente do que veio do arquivo.
--    Respondem "de onde veio esta linha e quando entrou?" — a primeira pergunta
--    de qualquer investigação de dado errado.
--
-- Este é o padrão medallion: RAW (bronze) preserva, STAGING (prata) limpa,
-- MART (ouro) modela para consumo.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS raw;

-- -----------------------------------------------------------------------------
-- CUSTOMERS — 99.441 linhas
-- customer_id muda a cada pedido; customer_unique_id é a pessoa real.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.customers (
    customer_id                 VARCHAR,
    customer_unique_id          VARCHAR,
    customer_zip_code_prefix    VARCHAR,
    customer_city               VARCHAR,
    customer_state              VARCHAR,
    _source_file                VARCHAR,
    _ingested_at                TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- ORDERS — 99.441 linhas
-- As 4 colunas de data têm nulos legítimos (pedido não entregue/cancelado).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.orders (
    order_id                        VARCHAR,
    customer_id                     VARCHAR,
    order_status                    VARCHAR,
    order_purchase_timestamp        VARCHAR,
    order_approved_at               VARCHAR,
    order_delivered_carrier_date    VARCHAR,
    order_delivered_customer_date   VARCHAR,
    order_estimated_delivery_date   VARCHAR,
    _source_file                    VARCHAR,
    _ingested_at                    TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- ORDER_ITEMS — 112.650 linhas
-- Grão = item dentro do pedido. price e freight_value são POR ITEM.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.order_items (
    order_id                VARCHAR,
    order_item_id           VARCHAR,
    product_id              VARCHAR,
    seller_id               VARCHAR,
    shipping_limit_date     VARCHAR,
    price                   VARCHAR,
    freight_value           VARCHAR,
    _source_file            VARCHAR,
    _ingested_at            TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- ORDER_PAYMENTS — 103.886 linhas
-- Grão = transação de pagamento. Um pedido pode ter várias (voucher + cartão).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.order_payments (
    order_id                VARCHAR,
    payment_sequential      VARCHAR,
    payment_type            VARCHAR,
    payment_installments    VARCHAR,
    payment_value           VARCHAR,
    _source_file            VARCHAR,
    _ingested_at            TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- ORDER_REVIEWS — 99.224 linhas
-- ATENÇÃO: review_id tem duplicatas (98.410 distintos). Deduplicar na staging.
-- Os campos de comentário têm quebra de linha e vírgula dentro de aspas.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.order_reviews (
    review_id                   VARCHAR,
    order_id                    VARCHAR,
    review_score                VARCHAR,
    review_comment_title        VARCHAR,
    review_comment_message      VARCHAR,
    review_creation_date        VARCHAR,
    review_answer_timestamp     VARCHAR,
    _source_file                VARCHAR,
    _ingested_at                TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- PRODUCTS — 32.951 linhas
-- "lenght" é erro de grafia da origem, preservado de propósito (ver nota 3).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.products (
    product_id                  VARCHAR,
    product_category_name       VARCHAR,
    product_name_lenght         VARCHAR,
    product_description_lenght  VARCHAR,
    product_photos_qty          VARCHAR,
    product_weight_g            VARCHAR,
    product_length_cm           VARCHAR,
    product_height_cm           VARCHAR,
    product_width_cm            VARCHAR,
    _source_file                VARCHAR,
    _ingested_at                TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- SELLERS — 3.095 linhas
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.sellers (
    seller_id               VARCHAR,
    seller_zip_code_prefix  VARCHAR,
    seller_city             VARCHAR,
    seller_state            VARCHAR,
    _source_file            VARCHAR,
    _ingested_at            TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- PRODUCT_CATEGORY_TRANSLATION — 71 linhas
-- O CSV tem BOM no cabeçalho; o loader lê como UTF-8 para que a primeira
-- coluna não chegue com nome corrompido.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.product_category_translation (
    product_category_name           VARCHAR,
    product_category_name_english   VARCHAR,
    _source_file                    VARCHAR,
    _ingested_at                    TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- GEOLOCATION — 1.000.163 linhas (maior tabela do dataset)
-- Sem chave: vários pontos lat/lng por prefixo de CEP. Agregue antes de juntar
-- com customers/sellers, senão o join multiplica as linhas.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.geolocation (
    geolocation_zip_code_prefix VARCHAR,
    geolocation_lat             VARCHAR,
    geolocation_lng             VARCHAR,
    geolocation_city            VARCHAR,
    geolocation_state           VARCHAR,
    _source_file                VARCHAR,
    _ingested_at                TIMESTAMP
);
