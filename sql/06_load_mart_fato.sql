-- =============================================================================
-- CARGA DA FATO — staging + dimensões da mart -> mart.fato_vendas
-- =============================================================================
--
-- Roda dentro da MESMA transação das dimensões (quem abre é o
-- src/build_mart.py). Fato e dimensão gravadas juntas ou nenhuma das duas: uma
-- fato apontando para dimensão que não foi gravada é o pior estado possível
-- deste banco.
--
--
-- POR QUE AQUI É "TRUNCATE + INSERT", E NAS DIMENSÕES ERA UPSERT
-- --------------------------------------------------------------
-- O 04_load_mart_dimensions.sql rejeitou TRUNCATE, e o motivo era ESPECÍFICO:
-- TRUNCATE reinicia o IDENTITY, as chaves substitutas mudariam entre cargas, e
-- a fato passaria a apontar para outro produto sem erro nenhum.
--
-- Esse motivo NÃO EXISTE aqui. A fato não tem IDENTITY (é a decisão registrada
-- no 05: nada aponta para ela, então chave substituta própria não serve para
-- nada) e nenhuma FK a referencia — o TRUNCATE nem precisa de CASCADE. Usar
-- UPSERT aqui seria escolha por herança, não por raciocínio.
--
-- E traria de volta um custo já medido neste projeto: ON CONFLICT DO UPDATE
-- reescreve TODA linha, e no MVCC a versão antiga vira lixo. Foi o que inchou
-- dim_cliente para 50 MB com 96 mil linhas depois de quatro cargas. TRUNCATE
-- não deixa rastro: a tabela recomeça vazia e as 112.650 linhas entram uma vez.
--
-- Idempotência continua valendo, e por um motivo que só é verdade porque as
-- DIMENSÕES usam upsert: como as sk_* são estáveis entre cargas, recarregar a
-- fato do zero reproduz linhas idênticas. As duas decisões, opostas entre si,
-- dependem uma da outra.
--
--
-- POR QUE NENHUMA JUNÇÃO AQUI PODE MULTIPLICAR LINHA
-- ---------------------------------------------------
-- Explosão de junção é o defeito clássico de carga de fato: um join casa com
-- duas linhas, a venda é contada duas vezes, e o faturamento dobra sem erro
-- nenhum. Foi o motivo de a geolocation ser agregada antes de entrar nas
-- dimensões.
--
-- Aqui isso é ESTRUTURALMENTE impossível, não só verificado depois: toda
-- coluna do lado direito de todo JOIN abaixo é PK ou UNIQUE.
--
--     staging.orders.order_id                  PK
--     staging.customers.customer_id            PK
--     mart.dim_cliente.customer_unique_id      UNIQUE
--     mart.dim_produto.product_id              UNIQUE
--     mart.dim_vendedor.seller_id              UNIQUE
--     mart.dim_status_pedido.status_origem     UNIQUE
--     mart.dim_data.data                       UNIQUE
--
-- É para isso que a chave natural continuou nas dimensões junto com a
-- substituta. A verificação de soma no build_mart.py continua existindo mesmo
-- assim — garantia estrutural que ninguém confere vira suposição.
-- =============================================================================


-- Sem CASCADE de propósito: se um dia alguma tabela passar a referenciar a
-- fato, este comando FALHA em vez de apagar a outra tabela junto.
TRUNCATE TABLE mart.fato_vendas;


INSERT INTO mart.fato_vendas (
    order_id, order_item_id,
    sk_cliente, sk_produto, sk_vendedor, sk_status,
    sk_data_compra, sk_data_entrega, sk_data_prevista,
    preco, frete, dias_entrega, dias_vs_previsto
)
SELECT
    -- Dimensão degenerada: a chave natural da origem fica na própria fato.
    i.order_id,
    i.order_item_id,

    -- Tradução de chave natural para chave substituta. É o único trabalho
    -- real desta consulta, e é o que faz o modelo ser estrela.
    dc.sk_cliente,
    dp.sk_produto,
    dv.sk_vendedor,
    ds.sk_status,

    dd_compra.sk_data,

    -- Onde o membro "Não informado" da dim_data finalmente é usado. Sem este
    -- COALESCE a coluna viria NULL nos 2.454 itens de pedido não entregue, e o
    -- NOT NULL do 05 abortaria a carga — que é exatamente o desenho: a
    -- ausência precisa ser tratada explicitamente, não escorregar para dentro
    -- da tabela.
    COALESCE(dd_entrega.sk_data, -1),

    dd_prevista.sk_data,

    i.price,
    i.freight_value,

    -- OS DOIS LADOS SÃO TRUNCADOS PARA DATA (::date), E ISSO FOI MEDIDO.
    --
    -- order_estimated_delivery_date está em 00:00:00 nas 99.441 linhas: é uma
    -- DATA vestida de TIMESTAMP. Já order_delivered_customer_date nunca está
    -- em 00:00:00 — é hora real de entrega.
    --
    -- Subtrair um do outro em timestamp embutiria um viés sistemático de até
    -- um dia para baixo, e o atraso apareceria MENOR do que é — erro que nunca
    -- levanta exceção e vai direto para o slide. Truncar os dois lados para
    -- data elimina isso e responde a pergunta certa: "em quantos DIAS de
    -- calendário isso chegou?".
    --
    -- Quando a entrega é NULL, a subtração inteira vira NULL sozinha. Aqui
    -- isso é o comportamento desejado: pedido não entregue não tem prazo.
    (o.order_delivered_customer_date::date - o.order_purchase_timestamp::date)::SMALLINT,

    -- Negativo = chegou ANTES do previsto. A ordem (realizado - previsto) é
    -- escolhida para que "atraso" seja positivo, que é como a pessoa que lê o
    -- painel pensa.
    (o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date)::SMALLINT

FROM staging.order_items i

-- ---------------------------------------------------------------------------
-- JOIN (interno) do lado da STAGING: aqui INNER é seguro, e por prova, não por
-- fé — order_items.order_id e orders.customer_id são FK declaradas no
-- 02_create_postgres_tables.sql. O banco não permite que essas linhas existam
-- sem par.
--
-- O desvio por customers é obrigatório e é consequência direta da decisão de
-- grão da dim_cliente: ela está no grão da PESSOA (customer_unique_id), e
-- staging.orders só conhece customer_id (que muda a cada pedido). O caminho
-- tem de ser order_items -> orders -> customers -> dim_cliente.
-- ---------------------------------------------------------------------------
JOIN staging.orders    o ON o.order_id    = i.order_id
JOIN staging.customers c ON c.customer_id = o.customer_id

-- ---------------------------------------------------------------------------
-- LEFT JOIN (externo) do lado da MART, e esta é a decisão menos óbvia da etapa.
--
-- O jeito natural seria INNER JOIN com cada dimensão. O problema: se uma linha
-- de dimensão faltasse, o INNER JOIN DESCARTARIA A VENDA EM SILÊNCIO. A
-- contagem final pegaria — mas dizendo só "faltam linhas", sem dizer quais nem
-- por quê.
--
-- Com LEFT JOIN a chave vem NULL; com NOT NULL na coluna (ver 05), o
-- PostgreSQL aborta a transação nomeando a coluna exata. O defeito passa de
-- silencioso a impossível, ao custo de quatro letras por linha.
--
-- É o mesmo princípio que decidiu a camada RAW sem constraint e o LEFT JOIN da
-- geolocation: entre um defeito que avisa e um que não avisa, escolher o que
-- avisa.
--
-- (dd_entrega é a exceção prevista: ali o NULL é esperado e vira -1 acima.)
-- ---------------------------------------------------------------------------
LEFT JOIN mart.dim_cliente       dc ON dc.customer_unique_id = c.customer_unique_id
LEFT JOIN mart.dim_produto       dp ON dp.product_id         = i.product_id
LEFT JOIN mart.dim_vendedor      dv ON dv.seller_id          = i.seller_id
LEFT JOIN mart.dim_status_pedido ds ON ds.status_origem      = o.order_status

-- A MESMA dim_data, três vezes, com apelidos diferentes: é assim que uma
-- dimensão de papéis múltiplos é carregada. Cada apelido é um papel.
--
-- Note que o join é por dd.data (a coluna DATE, UNIQUE), e não por
-- TO_CHAR(...)::INT sobre a chave AAAAMMDD. Os dois funcionariam; este usa o
-- índice da dimensão e não depende do formato da chave continuar o que é.
--
-- A linha -1 tem data NULL e por isso NUNCA casa aqui por acidente: em SQL
-- NULL = NULL não é verdadeiro. Ela só entra pelo COALESCE explícito.
LEFT JOIN mart.dim_data dd_compra   ON dd_compra.data   = o.order_purchase_timestamp::date
LEFT JOIN mart.dim_data dd_entrega  ON dd_entrega.data  = o.order_delivered_customer_date::date
LEFT JOIN mart.dim_data dd_prevista ON dd_prevista.data = o.order_estimated_delivery_date::date;
