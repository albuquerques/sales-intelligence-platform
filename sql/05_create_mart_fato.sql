-- =============================================================================
-- CAMADA MART — a fact table
-- =============================================================================
--
-- As cinco dimensões já existiam e não se ligavam a nada: cinco tabelas soltas
-- no schema, sem uma única FK entre elas. Esta tabela é o centro que faltava —
-- é ela que transforma a mart em um modelo estrela de verdade.
--
--
-- O GRÃO
-- ------
-- Uma linha desta tabela é UM ITEM VENDIDO DENTRO DE UM PEDIDO.
--
-- Essa frase é a decisão que define todo o resto: quais medidas podem existir,
-- quais dimensões são alcançáveis, e o que uma contagem significa. Ela vem
-- antes do DDL de propósito, e está gravada na PRIMARY KEY logo abaixo — não
-- só neste comentário.
--
-- Por que item e não pedido (99.441 linhas): não é porque price e
-- freight_value já são por item — isso só torna o grão de item conveniente. O
-- motivo é que no grão de pedido dim_produto e dim_vendedor ficam
-- INALCANÇÁVEIS:
--
--     pedidos com 2+ itens      : 10.578
--     pedidos com 2+ vendedores :  1.278
--
-- Um pedido com 3 produtos de 2 vendedores não tem "o" produto nem "o"
-- vendedor. Ligá-lo às dimensões exigiria uma tabela-ponte ou uma regra
-- inventada de "vendedor principal" — complexidade real para responder pior. E
-- "faturamento por categoria" é a pergunta central do dashboard, não um extra.
--
-- CUSTO ACEITO, e ele aparece no painel: 775 pedidos não têm item nenhum
-- (unavailable 603, canceled 164, created 5, invoiced 2, shipped 1) e portanto
-- NÃO EXISTEM nesta tabela. Contagem de pedidos distintos dará 98.666, não
-- 99.441 — diferença de 0,78%. Aceito porque 77% deles são "unavailable",
-- pedido que nunca virou venda. Fica escrito aqui para ser respondido, não
-- descoberto.
--
--
-- POR QUE A FATO NÃO TEM CHAVE SUBSTITUTA PRÓPRIA
-- -----------------------------------------------
-- Toda dimensão daqui tem uma (sk_*), por três motivos: compressão no VertiPaq,
-- desacoplamento da origem, e pré-requisito de SCD tipo 2. Nenhum dos três vale
-- para uma fato — NADA aponta para ela. Um IDENTITY aqui seriam 4 bytes vezes
-- 112.650 linhas e uma coluna que ninguém usa.
--
-- A chave desta tabela é a chave natural da origem, que entra também como
-- DIMENSÃO DEGENERADA: order_id fica na fato para contar pedidos distintos sem
-- exigir uma dim_pedido que não teria atributo nenhum além do próprio id.
--
-- Os nomes das duas seguem em inglês, como as outras chaves naturais da mart:
-- elas são o fio de volta ao CSV, não atributo de negócio.
-- =============================================================================

CREATE TABLE IF NOT EXISTS mart.fato_vendas (

    -- -- Dimensão degenerada / chave natural ---------------------------------
    order_id            VARCHAR(32)   NOT NULL,
    order_item_id       SMALLINT      NOT NULL,

    -- -- Chaves estrangeiras -------------------------------------------------
    --
    -- São FK de verdade, e não só coluna inteira, mesmo com o bloco de
    -- verificação do build_mart.py já provando que não há órfão. Os dois
    -- provam coisas diferentes: a verificação prova que ESTA carga está certa,
    -- a constraint prova que QUALQUER escrita futura estará — inclusive um
    -- INSERT manual no psql às onze da noite. Mesmo argumento que o projeto já
    -- usou em "validar em Python E ter constraint no banco".
    sk_cliente          INTEGER       NOT NULL,
    sk_produto          INTEGER       NOT NULL,
    sk_vendedor         INTEGER       NOT NULL,
    sk_status           SMALLINT      NOT NULL,

    -- DIMENSÃO DE PAPÉIS MÚLTIPLOS: três colunas diferentes apontando para a
    -- MESMA dim_data. São 6 datas disponíveis no dataset e só 3 entraram:
    --
    --   entra  compra    (0 NULL)     — a relação ATIVA no Power BI
    --   entra  entrega   (2,98% NULL) — SLA
    --   entra  prevista  (0 NULL)     — previsto x realizado
    --   fora   aprovação (0,16% NULL) — pergunta de operação, não de venda
    --   fora   postagem  (1,79% NULL) — idem
    --   fora   shipping_limit_date    — prazo do vendedor com a plataforma
    --
    -- A regra: cada data a mais é uma relação INATIVA no Power BI, e relação
    -- inativa cobra USERELATIONSHIP em toda medida que a usar. Três é o mínimo
    -- que responde receita no tempo e SLA; seis seriam três armadilhas de DAX
    -- guardadas para depois.
    --
    -- Consequência honesta: com shipping_limit_date fora, as 4 linhas com
    -- prazo em 2020 (que são o motivo de a dim_data ir até lá) ficam sem
    -- consumidor. O calendário continua como está — ele cobre o que o dado
    -- TEM, não o que está em uso hoje.
    --
    -- sk_data_entrega é NOT NULL e recebe -1 nos 2.454 itens sem entrega. É
    -- para isso que o membro "Não informado" foi criado na etapa passada: com
    -- NULL aqui, qualquer INNER JOIN com dim_data apagaria esses itens da
    -- análise e sumiria faturamento sem erro nenhum.
    sk_data_compra      INTEGER       NOT NULL,
    sk_data_entrega     INTEGER       NOT NULL,
    sk_data_prevista    INTEGER       NOT NULL,

    -- -- Medidas ADITIVAS -----------------------------------------------------
    --
    -- Aditiva = pode somar em qualquer combinação de dimensões. São as únicas
    -- duas, e são exatamente as que a origem entrega por item.
    --
    -- NUMERIC e não FLOAT: dinheiro somado 112.650 vezes em ponto flutuante
    -- acumula erro de arredondamento, e a verificação de soma desta etapa
    -- compara centavo a centavo.
    --
    -- NÃO EXISTE valor_total AQUI, e é decisão. Para medida aditiva,
    -- SUM(preco) + SUM(frete) é EXATAMENTE igual a SUM(preco + frete) — não é
    -- aproximação, é identidade. O DAX faz isso de graça. Guardar a coluna
    -- criaria um segundo lugar onde a mesma verdade pode divergir.
    --
    -- NÃO EXISTE quantidade AQUI, pelo mesmo tipo de motivo: neste grão ela é
    -- constante 1 (comprar 2 unidades gera 2 linhas — order_item_id chega a 21
    -- num pedido). Coluna que só contém 1 não informa nada; COUNT(*) já é a
    -- quantidade.
    preco               NUMERIC(10,2) NOT NULL,
    frete               NUMERIC(10,2) NOT NULL,

    -- -- Medidas NÃO ADITIVAS -------------------------------------------------
    --
    -- Destas duas se tira MÉDIA, nunca soma. "Total de dias de entrega" não
    -- significa nada. Está escrito aqui e em docs/star_schema.md para a coluna
    -- não ser arrastada para um total onde ela mente — no Power BI o padrão
    -- de uma coluna numérica é justamente Soma, então o cuidado é ativo.
    --
    -- POR QUE GRAVADAS E NÃO CALCULADAS NO DAX: são a diferença entre duas
    -- datas que moram em relações DIFERENTES com a mesma dim_data, uma delas
    -- inativa. No DAX isso exige USERELATIONSHIP dentro de cada medida que
    -- tocar prazo. Em SQL é uma subtração, feita uma vez na carga, e
    -- verificável.
    --
    -- NULL aqui é a resposta CERTA, e não contradiz o -1 da chave ao lado:
    --   NULL em CHAVE mata linha  — o INNER JOIN descarta a venda inteira.
    --   NULL em MEDIDA é ignorado pelo AVG — que é o comportamento correto,
    --   porque pedido não entregue não tem prazo de entrega. Gravar 0 puxaria
    --   a média para baixo e mentiria.
    -- Problemas diferentes, respostas diferentes.
    --
    -- Medidos no dataset completo:
    --   dias_entrega     : média 12,5 · máx 210 · mín 0
    --   dias_vs_previsto : 6.535 atrasados · 89.941 no prazo · de -147 a +188
    dias_entrega        SMALLINT,
    dias_vs_previsto    SMALLINT,      -- negativo = entregue ANTES do previsto

    dt_carga            TIMESTAMP     NOT NULL DEFAULT now(),

    -- =========================================================================
    -- A PK É A FRASE DO GRÃO VIRANDO CONSTRAINT.
    --
    -- Sem ela, "uma linha por item de pedido" é um comentário que alguém pode
    -- violar sem perceber; com ela, qualquer carga que duplique linha é
    -- rejeitada pelo PostgreSQL. staging.order_items tem exatamente esta PK —
    -- a fato herda a garantia em vez de confiar nela.
    --
    -- É também o ÚNICO índice da tabela, e isso é decisão. A tentação é criar
    -- um índice por FK (o PostgreSQL não cria sozinho). Não compensa: o Power
    -- BI extrai a tabela inteira, e varredura não usa índice; e nas consultas
    -- SQL o caminho é fato -> dimensão, que usa o índice DA DIMENSÃO. Sete
    -- índices custariam espaço e tempo de carga para acelerar consulta que
    -- ninguém faz.
    -- =========================================================================
    CONSTRAINT pk_fato_vendas PRIMARY KEY (order_id, order_item_id),

    CONSTRAINT fk_fato_vendas_cliente
        FOREIGN KEY (sk_cliente)       REFERENCES mart.dim_cliente (sk_cliente),
    CONSTRAINT fk_fato_vendas_produto
        FOREIGN KEY (sk_produto)       REFERENCES mart.dim_produto (sk_produto),
    CONSTRAINT fk_fato_vendas_vendedor
        FOREIGN KEY (sk_vendedor)      REFERENCES mart.dim_vendedor (sk_vendedor),
    CONSTRAINT fk_fato_vendas_status
        FOREIGN KEY (sk_status)        REFERENCES mart.dim_status_pedido (sk_status),
    CONSTRAINT fk_fato_vendas_data_compra
        FOREIGN KEY (sk_data_compra)   REFERENCES mart.dim_data (sk_data),
    CONSTRAINT fk_fato_vendas_data_entrega
        FOREIGN KEY (sk_data_entrega)  REFERENCES mart.dim_data (sk_data),
    CONSTRAINT fk_fato_vendas_data_prevista
        FOREIGN KEY (sk_data_prevista) REFERENCES mart.dim_data (sk_data),

    -- O CHECK de staging.order_items já barra valor negativo. Repetir aqui não
    -- é redundância inútil: a mart é escrita por SQL de transformação, não pelo
    -- carregador validado — um erro de sinal numa futura reescrita da carga
    -- passaria batido sem isto.
    CONSTRAINT ck_fato_vendas_valores CHECK (preco >= 0 AND frete >= 0),

    -- Entrega não antecede a compra (staging.orders já garante na origem).
    CONSTRAINT ck_fato_vendas_dias CHECK (dias_entrega IS NULL OR dias_entrega >= 0),

    -- AS DUAS FORMAS DE DIZER "NÃO ENTREGUE" TÊM DE CONCORDAR.
    -- A ausência de entrega aparece em dois lugares nesta linha: a chave vira
    -- -1 e as medidas de prazo viram NULL. Nada além deste CHECK impede que
    -- uma carga futura preencha um e esqueça o outro — e o resultado seria uma
    -- linha que some do filtro de data mas continua contando na média de
    -- prazo, ou o contrário. Defeito silencioso, do tipo que este projeto
    -- prefere transformar em erro.
    CONSTRAINT ck_fato_vendas_coerencia_prazo CHECK (
        (sk_data_entrega = -1) = (dias_entrega IS NULL)
        AND (dias_entrega IS NULL) = (dias_vs_previsto IS NULL)
    )
);
