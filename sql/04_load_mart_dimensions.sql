-- =============================================================================
-- CARGA DAS DIMENSÕES — staging -> mart
-- =============================================================================
--
-- Roda inteiro dentro de UMA transação (quem abre é o src/build_mart.py). Ou
-- todas as dimensões ficam coerentes entre si, ou o schema fica exatamente
-- como estava.
--
--
-- POR QUE UPSERT E NÃO "TRUNCATE + INSERT"
-- ----------------------------------------
-- TRUNCATE + INSERT é o jeito óbvio de deixar um script idempotente, e aqui
-- seria uma armadilha: TRUNCATE reinicia o IDENTITY. Na segunda carga, o
-- produto que tinha sk_produto = 7 pode receber 12 — e se a fato já estiver
-- gravada com a chave antiga, ela passa a apontar para OUTRO produto. Sem
-- erro, sem aviso: só números trocados no painel.
--
-- INSERT ... ON CONFLICT (chave_natural) DO UPDATE resolve: a linha é
-- reconhecida pela chave natural, atualizada no lugar, e a chave substituta
-- nunca muda. Custa uma cláusula a mais e elimina a classe inteira do
-- problema.
--
-- Detalhe honesto, e medido: o IDENTITY é consumido ANTES de o conflito ser
-- detectado, então a SEQUÊNCIA avança a cada recarga mesmo quando nenhuma
-- linha nova entra. Depois de três cargas, dim_produto tinha sk de 1 a 32.951
-- (sem buraco nenhum, as chaves não se mexeram) e a sequência já marcava
-- 98.853 = 3 x 32.951. Ou seja: as linhas existentes ficam intactas, e o
-- próximo produto NOVO ganharia sk 98.854, não 32.952.
--
-- Isso é inofensivo — chave substituta não significa nada, só precisa ser
-- única e estável, e as duas coisas continuam valendo. Vale saber para não
-- estranhar ao ver um salto na numeração depois.
--
-- O que o upsert NÃO faz: apagar linha que sumiu da origem. Se um produto
-- deixasse de existir no CSV, ele continuaria aqui. Num pipeline vivo isso
-- exigiria marcação de exclusão lógica; neste projeto a origem está congelada
-- em outubro de 2018 e nunca vai encolher.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PASSO 1 — um ponto por CEP (tabela de apoio, temporária)
--
-- staging.geolocation tem ~1 milhão de amostras e VÁRIAS por prefixo de CEP:
-- mínimo 1, média 53, máximo 1.146 pontos no mesmo prefixo. Juntar direto
-- multiplicaria as linhas do cliente pelo número de pontos do CEP dele — é a
-- "explosão de junção", e ela infla faturamento sem levantar erro nenhum.
-- Agregar ANTES de juntar é o que impede isso.
--
-- MEDIANA, NÃO MÉDIA. O prefixo de CEP cobre uma área, e a geocodificação da
-- origem tem ruído: um ponto errado a 500 km arrasta a média do CEP inteiro,
-- enquanto a mediana ignora. Com até 1.146 pontos por grupo, isso deixa de ser
-- teórico. Custo: a mediana precisa ordenar dentro de cada grupo, mais caro
-- que somar. São segundos, uma vez por carga.
--
-- O filtro da caixa do Brasil descarta 42 linhas com coordenada em outro
-- continente. Elas foram aceitas na STAGING de propósito (o CHECK de lá só
-- barra o impossível — fora da faixa global) e são descartadas AQUI, que é
-- onde regra de negócio mora. Constraint garante o que não PODE existir;
-- consulta decide o que não se QUER usar.
--
-- Tabela TEMPORÁRIA porque é andaime: resultado intermediário, usado por duas
-- dimensões, que não faz parte do modelo. Deixá-la no schema mart obrigaria
-- quem abrisse o banco a descobrir sozinho que ela não é uma dimensão.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_geo_cep;

CREATE TEMP TABLE tmp_geo_cep AS
SELECT
    geolocation_zip_code_prefix AS cep_prefixo,
    (PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY geolocation_lat::DOUBLE PRECISION))::NUMERIC(9,6) AS latitude,
    (PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY geolocation_lng::DOUBLE PRECISION))::NUMERIC(9,6) AS longitude
FROM staging.geolocation
WHERE geolocation_lat BETWEEN -34 AND 6      -- caixa aproximada do Brasil
  AND geolocation_lng BETWEEN -74 AND -34
GROUP BY geolocation_zip_code_prefix;

-- Sem índice, cada uma das duas junções seguintes varreria as ~19 mil linhas
-- inteiras para cada cliente. UNIQUE também documenta (e garante) que a
-- agregação de fato produziu um único ponto por CEP.
CREATE UNIQUE INDEX ON tmp_geo_cep (cep_prefixo);

ANALYZE tmp_geo_cep;


-- -----------------------------------------------------------------------------
-- PASSO 2 — DIM_DATA (gerada, não extraída)
--
-- Os nomes de mês e de dia vêm de ARRAY escrito à mão, e NÃO de
-- TO_CHAR(d, 'TMMonth'). O TM usa o lc_time do SERVIDOR — que nesta máquina é
-- 'English_United States.1252', ou seja, produziria "January" numa MART em
-- português. Pior: o mesmo script daria resultado diferente na outra máquina,
-- que é justamente o tipo de coisa que faz um pipeline "funcionar aqui". A
-- aparência do dado é decisão do modelo, não configuração do servidor.
--
-- EXTRACT devolve NUMERIC no PostgreSQL moderno, e índice de array precisa ser
-- INTEGER — daí o ::INT em cada subscrito. Sem ele o erro é em tempo de
-- execução, não de escrita.
--
-- OS LITERAIS SÃO 'TIMESTAMP', E NÃO 'DATE'. Isto aqui foi um bug de verdade,
-- pego pela verificação de contagem:
--
--   generate_series(DATE '2016-01-01', DATE '2018-12-31', INTERVAL '1 day')
--       -> 1095 dias
--   generate_series(TIMESTAMP '2016-01-01', TIMESTAMP '2018-12-31', ...)
--       -> 1096 dias
--
-- Com literais DATE o PostgreSQL escolhe a versão TIMESTAMPTZ da função, que
-- respeita fuso. O TimeZone deste servidor é America/Sao_Paulo, e o Brasil
-- TINHA horário de verão em 2016-2018: o deslocamento acumulado empurrou o
-- último passo para além do limite e 2018-12-31 sumiu do calendário.
--
-- O detalhe que faz esse defeito ser perigoso: 2018-12-31 não tem pedido
-- nenhum (o último é de 2018-10-17), então NADA quebraria hoje. Ele ficaria
-- esperando o primeiro dado novo cair na ponta do calendário.
--
-- TIMESTAMP sem fuso é o tipo certo aqui porque calendário não tem fuso —
-- 31 de dezembro é 31 de dezembro em qualquer lugar. Mesmo motivo que levou a
-- STAGING a usar TIMESTAMP e não TIMESTAMPTZ nas datas dos pedidos.
-- -----------------------------------------------------------------------------
INSERT INTO mart.dim_data (
    sk_data, data, ano, trimestre, mes, dia, ano_mes,
    nome_mes, nome_mes_abrev, dia_semana, nome_dia_semana, eh_fim_semana,
    semana_iso, dia_ano, primeiro_dia_mes, ultimo_dia_mes
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER,
    d::DATE,
    EXTRACT(YEAR    FROM d)::SMALLINT,
    EXTRACT(QUARTER FROM d)::SMALLINT,
    EXTRACT(MONTH   FROM d)::SMALLINT,
    EXTRACT(DAY     FROM d)::SMALLINT,
    TO_CHAR(d, 'YYYY-MM'),
    (ARRAY['Janeiro','Fevereiro','Março','Abril','Maio','Junho',
           'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro']
    )[EXTRACT(MONTH FROM d)::INT],
    (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun',
           'Jul','Ago','Set','Out','Nov','Dez']
    )[EXTRACT(MONTH FROM d)::INT],
    EXTRACT(ISODOW FROM d)::SMALLINT,
    (ARRAY['Segunda-feira','Terça-feira','Quarta-feira','Quinta-feira',
           'Sexta-feira','Sábado','Domingo']
    )[EXTRACT(ISODOW FROM d)::INT],
    EXTRACT(ISODOW FROM d) >= 6,
    EXTRACT(WEEK FROM d)::SMALLINT,
    EXTRACT(DOY  FROM d)::SMALLINT,
    DATE_TRUNC('month', d)::DATE,
    (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::DATE
FROM generate_series(TIMESTAMP '2016-01-01', TIMESTAMP '2020-12-31', INTERVAL '1 day') AS g(d)
ON CONFLICT (sk_data) DO UPDATE SET
    data             = EXCLUDED.data,
    ano              = EXCLUDED.ano,
    trimestre        = EXCLUDED.trimestre,
    mes              = EXCLUDED.mes,
    dia              = EXCLUDED.dia,
    ano_mes          = EXCLUDED.ano_mes,
    nome_mes         = EXCLUDED.nome_mes,
    nome_mes_abrev   = EXCLUDED.nome_mes_abrev,
    dia_semana       = EXCLUDED.dia_semana,
    nome_dia_semana  = EXCLUDED.nome_dia_semana,
    eh_fim_semana    = EXCLUDED.eh_fim_semana,
    semana_iso       = EXCLUDED.semana_iso,
    dia_ano          = EXCLUDED.dia_ano,
    primeiro_dia_mes = EXCLUDED.primeiro_dia_mes,
    ultimo_dia_mes   = EXCLUDED.ultimo_dia_mes;

-- O membro desconhecido. Só os rótulos de texto são preenchidos; ano, mês e
-- eh_fim_semana ficam NULL porque data desconhecida não tem ano, nem é fim de
-- semana, nem deixa de ser.
INSERT INTO mart.dim_data (sk_data, data, nome_mes, nome_mes_abrev, nome_dia_semana)
VALUES (-1, NULL, 'Não informado', 'n/d', 'Não informado')
ON CONFLICT (sk_data) DO NOTHING;


-- -----------------------------------------------------------------------------
-- PASSO 3 — DIM_CLIENTE (grão = pessoa)
--
-- DISTINCT ON é específico do PostgreSQL e é exatamente a ferramenta certa
-- aqui: devolve a primeira linha de cada grupo segundo o ORDER BY. Um
-- ROW_NUMBER() em subconsulta faria o mesmo com o dobro de texto.
--
-- O ORDER BY tem TRÊS níveis, e o terceiro não é decoração:
--   1. customer_unique_id  — obrigatório, tem de casar com o DISTINCT ON
--   2. purchase_timestamp DESC — a regra de negócio: endereço do pedido mais
--      recente
--   3. customer_id — DESEMPATE. Sem ele, duas compras da mesma pessoa no mesmo
--      instante fariam o PostgreSQL escolher qualquer uma, e o script deixaria
--      de ser idempotente: mesma entrada, saída diferente entre execuções. É a
--      diferença entre "quase sempre igual" e "sempre igual".
--
-- INITCAP na cidade porque a origem grava tudo minúsculo ('sao paulo') e esta
-- é a camada de apresentação. Limitação conhecida: 'rio de janeiro' vira 'Rio
-- De Janeiro', com o 'De' maiúsculo. Corrigir exigiria lista de preposições —
-- não compensa para o uso atual, e fica registrado como escolha, não descuido.
-- -----------------------------------------------------------------------------
WITH pedidos_por_pessoa AS (
    SELECT c.customer_unique_id,
           COUNT(*)::SMALLINT AS qtd_pedidos
    FROM staging.customers c
    JOIN staging.orders o ON o.customer_id = c.customer_id
    GROUP BY c.customer_unique_id
),
endereco_atual AS (
    SELECT DISTINCT ON (c.customer_unique_id)
           c.customer_unique_id,
           c.customer_zip_code_prefix   AS cep_prefixo,
           INITCAP(c.customer_city)     AS cidade,
           c.customer_state             AS estado
    FROM staging.customers c
    JOIN staging.orders o ON o.customer_id = c.customer_id
    ORDER BY c.customer_unique_id,
             o.order_purchase_timestamp DESC,
             c.customer_id
)
INSERT INTO mart.dim_cliente (
    customer_unique_id, cep_prefixo, cidade, estado,
    latitude, longitude, qtd_pedidos, eh_recorrente
)
SELECT
    e.customer_unique_id,
    e.cep_prefixo,
    e.cidade,
    e.estado,
    g.latitude,
    g.longitude,
    p.qtd_pedidos,
    p.qtd_pedidos > 1
FROM endereco_atual e
JOIN pedidos_por_pessoa p ON p.customer_unique_id = e.customer_unique_id
-- LEFT, não INNER: 157 prefixos de CEP de clientes não existem em geolocation
-- (278 linhas de staging.customers, que viram 269 pessoas aqui — 0,28%). Com
-- INNER JOIN essas pessoas SUMIRIAM da dimensão, e a fato ficaria sem para
-- onde apontar. Ficam sem coordenada, não sem linha: ausência de atributo não
-- pode virar ausência de cliente.
LEFT JOIN tmp_geo_cep g ON g.cep_prefixo = e.cep_prefixo
ON CONFLICT (customer_unique_id) DO UPDATE SET
    cep_prefixo   = EXCLUDED.cep_prefixo,
    cidade        = EXCLUDED.cidade,
    estado        = EXCLUDED.estado,
    latitude      = EXCLUDED.latitude,
    longitude     = EXCLUDED.longitude,
    qtd_pedidos   = EXCLUDED.qtd_pedidos,
    eh_recorrente = EXCLUDED.eh_recorrente,
    dt_carga      = now();


-- -----------------------------------------------------------------------------
-- PASSO 4 — DIM_VENDEDOR
--
-- Mesmo padrão da dim_cliente, sem a parte difícil: seller_id não se repete na
-- origem, então não há decisão de grão nem regra de desempate. 7 vendedores
-- (0,23%) ficam sem coordenada, pelo mesmo motivo e com o mesmo LEFT JOIN.
-- -----------------------------------------------------------------------------
INSERT INTO mart.dim_vendedor (
    seller_id, cep_prefixo, cidade, estado, latitude, longitude
)
SELECT
    s.seller_id,
    s.seller_zip_code_prefix,
    INITCAP(s.seller_city),
    s.seller_state,
    g.latitude,
    g.longitude
FROM staging.sellers s
LEFT JOIN tmp_geo_cep g ON g.cep_prefixo = s.seller_zip_code_prefix
ON CONFLICT (seller_id) DO UPDATE SET
    cep_prefixo = EXCLUDED.cep_prefixo,
    cidade      = EXCLUDED.cidade,
    estado      = EXCLUDED.estado,
    latitude    = EXCLUDED.latitude,
    longitude   = EXCLUDED.longitude,
    dt_carga    = now();


-- -----------------------------------------------------------------------------
-- PASSO 5 — DIM_PRODUTO
--
-- COALESCE(..., 'Não informado') é a decisão de tratamento dos 610 anúncios
-- incompletos, e ela é feita AQUI e não na STAGING de propósito: a STAGING
-- guarda o que a origem disse (NULL, ausência real); a MART decide como a
-- ausência aparece no painel.
--
-- volume_cm3 é a primeira coluna verdadeiramente derivada do modelo — não
-- existe em lugar nenhum da origem. Vira NULL sozinha quando qualquer medida
-- falta, porque em SQL qualquer operação com NULL dá NULL. Aqui isso é o
-- comportamento desejado: volume parcial não é volume.
-- -----------------------------------------------------------------------------
INSERT INTO mart.dim_produto (
    product_id, categoria, categoria_origem, anuncio_completo,
    peso_g, comprimento_cm, altura_cm, largura_cm, volume_cm3,
    qtd_fotos, tam_nome, tam_descricao
)
SELECT
    p.product_id,
    COALESCE(INITCAP(REPLACE(p.product_category_name, '_', ' ')), 'Não informado'),
    p.product_category_name,
    p.product_category_name IS NOT NULL,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm,
    p.product_length_cm * p.product_height_cm * p.product_width_cm,
    p.product_photos_qty::SMALLINT,
    p.product_name_lenght::SMALLINT,     -- typo da origem corrigido no destino
    p.product_description_lenght
FROM staging.products p
ON CONFLICT (product_id) DO UPDATE SET
    categoria        = EXCLUDED.categoria,
    categoria_origem = EXCLUDED.categoria_origem,
    anuncio_completo = EXCLUDED.anuncio_completo,
    peso_g           = EXCLUDED.peso_g,
    comprimento_cm   = EXCLUDED.comprimento_cm,
    altura_cm        = EXCLUDED.altura_cm,
    largura_cm       = EXCLUDED.largura_cm,
    volume_cm3       = EXCLUDED.volume_cm3,
    qtd_fotos        = EXCLUDED.qtd_fotos,
    tam_nome         = EXCLUDED.tam_nome,
    tam_descricao    = EXCLUDED.tam_descricao,
    dt_carga         = now();


-- -----------------------------------------------------------------------------
-- PASSO 6 — DIM_STATUS_PEDIDO
--
-- A única dimensão escrita à mão, porque é a única cujo conteúdo NÃO está no
-- dado: 'delivered' é o que a origem diz; que 'delivered' venha depois de
-- 'shipped' no funil, e que 'unavailable' não seja venda, é conhecimento de
-- negócio. Dado nenhum informa isso — alguém precisa declarar.
--
-- Por isso ele fica versionado aqui, em SQL, e não digitado dentro do Power BI:
-- no arquivo ele é revisável, comentável e igual nas duas máquinas.
-- -----------------------------------------------------------------------------
INSERT INTO mart.dim_status_pedido (
    sk_status, status_origem, status, ordem_funil, eh_venda_efetiva, eh_entregue
) VALUES
    (1, 'created',     'Criado',           1, TRUE,  FALSE),
    (2, 'approved',    'Aprovado',         2, TRUE,  FALSE),
    (3, 'invoiced',    'Faturado',         3, TRUE,  FALSE),
    (4, 'processing',  'Em processamento', 4, TRUE,  FALSE),
    (5, 'shipped',     'Enviado',          5, TRUE,  FALSE),
    (6, 'delivered',   'Entregue',         6, TRUE,  TRUE),
    -- Cancelado e indisponível são os dois desfechos que NÃO viraram receita.
    (7, 'canceled',    'Cancelado',        7, FALSE, FALSE),
    (8, 'unavailable', 'Indisponível',     8, FALSE, FALSE)
ON CONFLICT (sk_status) DO UPDATE SET
    status_origem    = EXCLUDED.status_origem,
    status           = EXCLUDED.status,
    ordem_funil      = EXCLUDED.ordem_funil,
    eh_venda_efetiva = EXCLUDED.eh_venda_efetiva,
    eh_entregue      = EXCLUDED.eh_entregue;


DROP TABLE IF EXISTS tmp_geo_cep;
