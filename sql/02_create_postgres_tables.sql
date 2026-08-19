-- =============================================================================
-- CAMADA STAGING (prata) — PostgreSQL
-- =============================================================================
--
-- Contraste proposital com sql/01_create_raw_tables.sql:
--
--                        RAW (DuckDB)            STAGING (PostgreSQL)
--   Tipos                tudo VARCHAR            tipos reais
--   Constraints          nenhuma                 PK, FK, NOT NULL, CHECK
--   Objetivo             receber o dado          garantir que ele é válido
--
-- A RAW não podia ter constraint: ela existe para aterrissar o arquivo como
-- ele é, defeitos inclusive. Aqui o pipeline já validou tudo em Python antes
-- de enviar, então o banco pode ser rigoroso.
--
-- Por que ter as duas coisas, se o Python já validou?
--   O Python valida ESTA carga. A constraint vale para SEMPRE, para qualquer
--   escrita — um INSERT manual, outro script, um colega. Validação em Python
--   dá boa mensagem de erro; constraint dá garantia. São complementares.
--
-- Notas de tipo:
--
--   VARCHAR(32) nos IDs — no PostgreSQL, VARCHAR(n) e TEXT têm exatamente o
--   mesmo desempenho; o limite é uma restrição de integridade, não uma
--   otimização (diferente do que acontece em alguns outros bancos). Está aqui
--   para documentar que o ID é um hash de 32 caracteres, e barrar o que não é.
--
--   NUMERIC(10,2) em dinheiro — nunca FLOAT/DOUBLE. Ponto flutuante binário não
--   representa 0,10 exatamente; somar centavos milhares de vezes acumula erro e
--   o faturamento fecha com diferença de centavos. NUMERIC é decimal exato.
--
--   CHAR(5) no CEP — é prefixo de CEP, não número. Como inteiro, o CEP 01037
--   viraria 1037 e o zero à esquerda sumiria. Largura fixa confirmada no
--   profiling: 100% dos valores têm exatamente 5 dígitos nos dois datasets.
--
--   TIMESTAMP sem fuso — a origem não informa fuso horário nenhum. Usar
--   TIMESTAMPTZ obrigaria a inventar um, e dado inventado é pior que ausente.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS staging;

-- -----------------------------------------------------------------------------
-- CUSTOMERS — sem dependências, carrega primeiro.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.customers (
    customer_id                 VARCHAR(32)  PRIMARY KEY,
    customer_unique_id          VARCHAR(32)  NOT NULL,
    customer_zip_code_prefix    CHAR(5)      NOT NULL,
    customer_city               VARCHAR(64)  NOT NULL,
    customer_state              CHAR(2)      NOT NULL
);

-- customer_unique_id é a pessoa real; customer_id muda a cada pedido.
-- Métricas de cliente (recorrência, LTV) usam este campo, então ele merece
-- índice — sem PK, porque ele repete de propósito.
CREATE INDEX IF NOT EXISTS ix_customers_unique_id
    ON staging.customers (customer_unique_id);

-- -----------------------------------------------------------------------------
-- SELLERS — sem dependências.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.sellers (
    seller_id               VARCHAR(32)  PRIMARY KEY,
    seller_zip_code_prefix  CHAR(5)      NOT NULL,
    seller_city             VARCHAR(64)  NOT NULL,
    seller_state            CHAR(2)      NOT NULL
);

-- -----------------------------------------------------------------------------
-- PRODUCTS — sem dependências.
--
-- Os campos de anúncio são NULL-áveis de propósito: 610 produtos (1,85%) têm
-- anúncio incompleto e vêm sem categoria nem medidas de texto. São dados reais
-- e válidos; um NOT NULL aqui rejeitaria 610 produtos legítimos.
--
-- Não há FK de product_category_name para a tabela de tradução porque ela não
-- faz parte deste pipeline. Quando entrar, a FK vem junto.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.products (
    product_id                  VARCHAR(32)  PRIMARY KEY,
    product_category_name       VARCHAR(64),
    product_name_lenght         INTEGER,
    product_description_lenght  INTEGER,
    product_photos_qty          INTEGER,
    product_weight_g            INTEGER,
    product_length_cm           INTEGER,
    product_height_cm           INTEGER,
    product_width_cm            INTEGER,

    -- Medida negativa é impossível. Em NULL o CHECK não dispara (NULL não é
    -- FALSE), que é exatamente o comportamento desejado aqui.
    CONSTRAINT ck_products_medidas_positivas CHECK (
        COALESCE(product_weight_g,   0) >= 0 AND
        COALESCE(product_length_cm,  0) >= 0 AND
        COALESCE(product_height_cm,  0) >= 0 AND
        COALESCE(product_width_cm,   0) >= 0
    )
);

-- -----------------------------------------------------------------------------
-- ORDERS — depende de customers.
--
-- 4 das 5 colunas de data são NULL-áveis, e cada NULL significa algo:
--   order_approved_at             NULL = pagamento nunca aprovado
--   order_delivered_carrier_date  NULL = nunca postado
--   order_delivered_customer_date NULL = nunca entregue
-- Ausência aqui é informação, não defeito.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.orders (
    order_id                        VARCHAR(32)  PRIMARY KEY,
    customer_id                     VARCHAR(32)  NOT NULL,
    order_status                    VARCHAR(16)  NOT NULL,
    order_purchase_timestamp        TIMESTAMP    NOT NULL,
    order_approved_at               TIMESTAMP,
    order_delivered_carrier_date    TIMESTAMP,
    order_delivered_customer_date   TIMESTAMP,
    order_estimated_delivery_date   TIMESTAMP    NOT NULL,

    CONSTRAINT fk_orders_customer
        FOREIGN KEY (customer_id) REFERENCES staging.customers (customer_id),

    -- Os 8 status observados no dataset completo. A amostra só contém 6
    -- (faltam 'approved' e 'created'), por isso a lista vem do profiling do
    -- dataset inteiro e não do arquivo que estiver sendo carregado.
    CONSTRAINT ck_orders_status CHECK (order_status IN (
        'delivered', 'shipped', 'canceled', 'unavailable',
        'invoiced', 'processing', 'created', 'approved'
    )),

    -- Entrega não pode anteceder a compra. Regra de negócio que o banco
    -- passa a garantir sozinho.
    CONSTRAINT ck_orders_entrega_apos_compra CHECK (
        order_delivered_customer_date IS NULL OR
        order_delivered_customer_date >= order_purchase_timestamp
    )
);

CREATE INDEX IF NOT EXISTS ix_orders_customer_id
    ON staging.orders (customer_id);
CREATE INDEX IF NOT EXISTS ix_orders_purchase_ts
    ON staging.orders (order_purchase_timestamp);

-- -----------------------------------------------------------------------------
-- ORDER_ITEMS — depende de orders, products e sellers. Carrega por último.
--
-- A PK é COMPOSTA: um pedido tem vários itens, numerados 1, 2, 3... Nem
-- order_id nem order_item_id são únicos sozinhos; o par é.
--
-- price e freight_value são POR ITEM. O total do pedido é SUM() por order_id.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.order_items (
    order_id                VARCHAR(32)   NOT NULL,
    order_item_id           SMALLINT      NOT NULL,
    product_id              VARCHAR(32)   NOT NULL,
    seller_id               VARCHAR(32)   NOT NULL,
    shipping_limit_date     TIMESTAMP     NOT NULL,
    price                   NUMERIC(10,2) NOT NULL,
    freight_value           NUMERIC(10,2) NOT NULL,

    CONSTRAINT pk_order_items PRIMARY KEY (order_id, order_item_id),

    CONSTRAINT fk_order_items_order
        FOREIGN KEY (order_id)   REFERENCES staging.orders (order_id),
    CONSTRAINT fk_order_items_product
        FOREIGN KEY (product_id) REFERENCES staging.products (product_id),
    CONSTRAINT fk_order_items_seller
        FOREIGN KEY (seller_id)  REFERENCES staging.sellers (seller_id),

    CONSTRAINT ck_order_items_valores CHECK (price >= 0 AND freight_value >= 0),
    CONSTRAINT ck_order_items_sequencial CHECK (order_item_id >= 1)
);

-- O índice da PK já cobre buscas por order_id (é a primeira coluna dela).
-- Estes dois cobrem o sentido inverso: "o que este produto vendeu?", "o que
-- este vendedor vendeu?".
CREATE INDEX IF NOT EXISTS ix_order_items_product_id
    ON staging.order_items (product_id);
CREATE INDEX IF NOT EXISTS ix_order_items_seller_id
    ON staging.order_items (seller_id);
