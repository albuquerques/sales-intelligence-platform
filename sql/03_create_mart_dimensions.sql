-- =============================================================================
-- CAMADA MART (ouro) — dimensões do modelo estrela
-- =============================================================================
--
-- Terceiro e último nível do medallion:
--
--                RAW (DuckDB)      STAGING (PostgreSQL)   MART (PostgreSQL)
--   Objetivo     receber o dado    garantir que é válido  responder perguntas
--   Modelagem    igual à origem    igual à origem         estrela
--   Tipos        tudo VARCHAR      tipos reais            tipos reais
--   Público      ninguém           quem carrega           quem analisa
--
-- STAGING é normalizada: espelha a origem, evita repetição e é ótima para
-- gravar. Só que responder "faturamento por categoria por mês" nela exige
-- percorrer order_items -> products, order_items -> orders -> customers, e
-- extrair o mês de um timestamp em toda linha. O modelo estrela troca essa
-- repetição de TRABALHO por repetição de DADO: a categoria já vem escrita e
-- legível, o mês já vem calculado. Espaço é barato; junção em tempo de
-- consulta, num painel que alguém está esperando carregar, não é.
--
-- Nomes em PORTUGUÊS aqui, e em inglês na STAGING, de propósito: a STAGING
-- herda os nomes da origem e renomear lá quebraria a rastreabilidade até o
-- CSV. A MART é a camada que uma pessoa de negócio lê dentro do Power BI, e o
-- painel é em português. A tradução acontece exatamente uma vez, na fronteira
-- entre as duas camadas.
--
-- As chaves naturais (product_id, seller_id, customer_unique_id) continuam em
-- inglês mesmo aqui — elas NÃO são atributo de negócio, são o fio que liga a
-- linha de volta à origem. Traduzi-las esconderia essa ligação.
--
--
-- CHAVE SUBSTITUTA (surrogate key)
-- --------------------------------
-- Toda dimensão tem uma chave inteira própria (sk_*), e é ela que a fato vai
-- guardar — não o hash de 32 caracteres da origem. Motivos, em ordem de peso
-- real neste projeto:
--
--   1. Power BI. O VertiPaq comprime coluna de inteiro sequencial ordens de
--      grandeza melhor que hash aleatório. Com 112.650 linhas na fato e várias
--      chaves, é a diferença que aparece no tamanho do .pbix e na resposta dos
--      visuais.
--   2. Desacoplamento. Se amanhã entrar outra fonte de produtos com outro
--      formato de ID, a fato não muda: muda o mapeamento aqui.
--   3. Pré-requisito de SCD tipo 2. Mesma chave natural, várias linhas, cada
--      uma com sua sk. Sem chave substituta é impossível.
--
-- O que se perde: não dá mais para ler uma junção a olho nu. Por isso a chave
-- natural CONTINUA na dimensão, com UNIQUE. Ganha-se a chave substituta sem
-- perder a rastreabilidade — e o UNIQUE é o que garante que a chave natural
-- não duplique, defeito que dobraria o faturamento quando a fato chegar.
--
--
-- SCD: TIPO 1, E POR QUÊ
-- ----------------------
-- Dimensão que muda devagar (Slowly Changing Dimension) tem duas respostas
-- clássicas: tipo 1 sobrescreve o valor antigo; tipo 2 guarda uma linha por
-- versão, com vigência, e preserva a história.
--
-- Aqui é tipo 1, e a decisão é do dataset, não de preguiça: o Olist é um
-- retrato congelado, encerrado em outubro de 2018. Nenhuma atualização vai
-- chegar nunca. Um tipo 2 teria colunas dt_inicio/dt_fim/eh_atual que jamais
-- registrariam mais de uma versão — complexidade real na carga da fato (que
-- passaria a ter de escolher a versão vigente na data do pedido) em troca de
-- zero informação.
--
-- Onde isso doeria, se doesse: 250 dos 96.096 clientes (0,26%) mudam de CEP
-- entre pedidos. Com tipo 1 e a regra "endereço do pedido mais recente", uma
-- compra feita de SP em 2017 aparece no estado atual da pessoa. É a única
-- distorção conhecida do modelo, está medida, e está escrita aqui em vez de
-- escondida.
--
-- dt_carga existe em todas as dimensões justamente porque o tipo 1 apaga o
-- passado: é o mínimo de rastreabilidade que sobra — quando esta linha foi
-- escrita pela última vez.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS mart;

-- -----------------------------------------------------------------------------
-- DIM_DATA — a única dimensão que não vem de tabela nenhuma: é gerada.
--
-- Por que gerar em vez de SELECT DISTINCT das datas dos pedidos:
--
--   1. Buracos. Dia sem venda simplesmente não existiria. Um gráfico de série
--      temporal pularia o dia sem avisar, e "média diária" passaria a dividir
--      pelo número de dias COM venda — resposta errada, sem erro.
--   2. Datas futuras. A entrega estimada vai até 2018-11-12, quase um mês além
--      da última compra (2018-10-17). Derivar da coluna de compras deixaria
--      essas datas órfãs.
--   3. Atributos que o dado não carrega. Trimestre, nome do mês, dia da semana
--      e fim de semana não estão em lugar nenhum do CSV — são conhecimento de
--      calendário, não de vendas.
--
-- Faixa: 2016-01-01 a 2020-12-31 = 1.827 dias. Anos fechados nas pontas para
-- que trimestre e comparação ano-a-ano não apareçam cortados no painel.
--
-- POR QUE ATÉ 2020, se o último pedido é de outubro de 2018: order_items tem
-- 4 linhas com shipping_limit_date em 2020 (pedidos de março e maio de 2017
-- com prazo de postagem quase três anos depois, e com o mesmo horário do
-- pedido — defeito de digitação da origem, não pedido de verdade).
--
-- São 4 linhas em 112.650, e a escolha entre encurtar o calendário ou cobri-lo
-- não é de estética:
--   cobrir  = 731 linhas a mais e dois anos quase vazios no filtro do painel.
--             Problema cosmético, resolvido no Power BI.
--   encurtar= o dia não existe no calendário, e no momento em que alguém ligar
--             shipping_limit_date à dim_data, essas 4 linhas somem da fato sem
--             erro. Problema de correção, e ele não avisa.
-- Calendário é infraestrutura: ele cobre o que o dado tem, não o que seria
-- bonito. As duas pontas vazias ficam documentadas aqui.
--
-- A CHAVE É A EXCEÇÃO DA REGRA. Aqui ela é AAAAMMDD (20170214), não IDENTITY:
-- é uma chave "inteligente", que carrega significado — normalmente um erro,
-- porque significado dentro de chave envelhece. Aceita-se neste caso porque
-- data não muda de valor, e a legibilidade ao depurar a fato compensa.
--
-- A LINHA -1 ("Não informado") é obrigatória, e o motivo é concreto: 2,98% dos
-- pedidos não têm data de entrega. Se a fato guardasse NULL nessa chave,
-- qualquer INNER JOIN com esta tabela APAGARIA essas linhas da fato — e
-- sumiria faturamento do relatório sem erro nenhum. Com a linha -1, a fato
-- sempre aponta para algum lugar e a ausência vira um rótulo visível.
--
-- Nela os atributos numéricos ficam NULL de propósito, e não zerados: em
-- lógica de três valores, `WHERE eh_fim_semana` e `WHERE NOT eh_fim_semana`
-- excluem os dois a linha -1 — que é exatamente o certo, porque data
-- desconhecida não é fim de semana nem deixa de ser. Já os rótulos de texto
-- são NOT NULL e dizem "Não informado", porque num filtro do Power BI um NULL
-- é descartado em silêncio e um texto participa como qualquer outro valor.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.dim_data (
    sk_data             INTEGER      PRIMARY KEY,   -- AAAAMMDD, ou -1
    data                DATE         UNIQUE,        -- NULL só na linha -1
    ano                 SMALLINT,
    trimestre           SMALLINT,
    mes                 SMALLINT,
    dia                 SMALLINT,
    ano_mes             CHAR(7),                    -- '2017-05', ordena como texto
    nome_mes            VARCHAR(16)  NOT NULL,
    nome_mes_abrev      VARCHAR(4)   NOT NULL,
    dia_semana          SMALLINT,                   -- ISO: 1=segunda ... 7=domingo
    nome_dia_semana     VARCHAR(16)  NOT NULL,
    eh_fim_semana       BOOLEAN,
    semana_iso          SMALLINT,
    dia_ano             SMALLINT,
    primeiro_dia_mes    DATE,
    ultimo_dia_mes      DATE,

    -- A chave só pode ser o sentinela ou uma data plausível. Barra o acidente
    -- clássico de gravar um EXTRACT(EPOCH) ou um ano de 2 dígitos aqui.
    CONSTRAINT ck_dim_data_sk CHECK (
        sk_data = -1 OR sk_data BETWEEN 19000101 AND 29991231
    ),

    -- Ou é o sentinela sem data, ou é uma data de verdade. Impede o estado
    -- incoerente de uma linha comum com data NULL.
    CONSTRAINT ck_dim_data_sentinela CHECK (
        (sk_data = -1) = (data IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS ix_dim_data_ano_mes ON mart.dim_data (ano_mes);

-- -----------------------------------------------------------------------------
-- DIM_CLIENTE — a decisão de grão mais perigosa do modelo.
--
-- O grão é a PESSOA (customer_unique_id), não o cadastro de pedido
-- (customer_id). Os números que decidiram:
--
--     customer_id distintos        : 99.441   (muda a cada pedido!)
--     customer_unique_id distintos : 96.096   (a pessoa)
--     pessoas com mais de 1 pedido :  2.997
--
-- No grão de customer_id, "clientes distintos" daria 99.441 — inflado em 3,5%
-- — e a taxa de recorrência daria ZERO: todo cliente pareceria comprador de
-- primeira viagem, para sempre. Isso nunca levanta erro; levanta um número
-- errado dentro de um painel que alguém vai apresentar.
--
-- Consequência para a próxima etapa: a fato NÃO chega aqui direto.
-- staging.orders só tem customer_id, então o caminho é
-- order_items -> orders -> customers -> dim_cliente.
--
-- ENDEREÇO: o do pedido mais recente da pessoa. 250 pessoas (0,26%) mudam de
-- CEP entre pedidos, 122 mudam de cidade, 39 mudam de estado — nelas, a compra
-- antiga aparece no endereço novo. É o preço do tipo 1, e está medido.
--
-- qtd_pedidos e eh_recorrente são atributos DERIVADOS de staging.orders. Fica
-- registrado que é uma concessão consciente: atributo contado dentro de
-- dimensão precisa ser recalculado sempre que a base muda, e num pipeline vivo
-- o certo seria calculá-lo como medida no DAX. Aqui a base está congelada, e
-- em troca "cliente recorrente x cliente de uma compra só" vira um filtro de
-- um clique no Power BI em vez de uma medida que precisa ser escrita certa.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.dim_cliente (
    sk_cliente          INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_unique_id  VARCHAR(32)  NOT NULL UNIQUE,   -- chave natural
    cep_prefixo         CHAR(5)      NOT NULL,
    cidade              VARCHAR(64)  NOT NULL,
    estado              CHAR(2)      NOT NULL,
    latitude            NUMERIC(9,6),
    longitude           NUMERIC(9,6),
    qtd_pedidos         SMALLINT     NOT NULL,
    eh_recorrente       BOOLEAN      NOT NULL,
    dt_carga            TIMESTAMP    NOT NULL DEFAULT now(),

    -- A pessoa só existe nesta tabela porque fez pedido; zero é impossível.
    CONSTRAINT ck_dim_cliente_qtd CHECK (qtd_pedidos >= 1),

    -- Coordenada é par: ou vêm as duas, ou nenhuma. Meia coordenada põe um
    -- ponto no meio do Atlântico e ninguém percebe até o mapa ficar errado.
    CONSTRAINT ck_dim_cliente_coord CHECK ((latitude IS NULL) = (longitude IS NULL))
);

CREATE INDEX IF NOT EXISTS ix_dim_cliente_estado ON mart.dim_cliente (estado);

-- -----------------------------------------------------------------------------
-- DIM_VENDEDOR — 3.095 linhas, sem decisão difícil: seller_id já é a empresa e
-- não se repete. É a dimensão que mostra como o modelo fica quando a origem
-- colabora.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.dim_vendedor (
    sk_vendedor     INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id       VARCHAR(32)  NOT NULL UNIQUE,       -- chave natural
    cep_prefixo     CHAR(5)      NOT NULL,
    cidade          VARCHAR(64)  NOT NULL,
    estado          CHAR(2)      NOT NULL,
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6),
    dt_carga        TIMESTAMP    NOT NULL DEFAULT now(),

    CONSTRAINT ck_dim_vendedor_coord CHECK ((latitude IS NULL) = (longitude IS NULL))
);

CREATE INDEX IF NOT EXISTS ix_dim_vendedor_estado ON mart.dim_vendedor (estado);

-- -----------------------------------------------------------------------------
-- DIM_PRODUTO — o caso de "atributo faltante", que NÃO é o mesmo que "linha
-- faltante".
--
--   Linha faltante    = a fato aponta para uma dimensão que não tem a linha.
--                       Resolve-se com membro desconhecido (a linha -1 da
--                       dim_data). Aqui não acontece: as FKs de order_items
--                       são NOT NULL e garantidas por constraint na STAGING.
--   Atributo faltante = a linha existe, o campo está vazio. É o caso dos 610
--                       produtos (1,85%) com anúncio incompleto.
--
-- Para o atributo faltante a resposta é texto sentinela, não NULL. Motivo
-- concreto: no Power BI, um filtro `categoria <> 'cama_mesa_banho'` DESCARTA
-- os NULL em silêncio (NULL não é diferente de nada — NULL não se compara), e
-- os 610 produtos somem do relatório sem aviso. 'Não informado' participa dos
-- filtros como qualquer outro valor.
--
-- categoria_origem preserva o slug cru, com o NULL original. É o que permite
-- provar depois que 'Não informado' foi decisão desta camada, e não dado da
-- origem.
--
-- POR QUE A TABELA DE TRADUÇÃO OFICIAL NÃO FOI USADA: ela está incompleta.
-- products tem 73 categorias distintas; product_category_name_translation tem
-- 71. Faltam 'pc_gamer' e 'portateis_cozinha_e_preparadores_de_alimentos'. Um
-- INNER JOIN com ela perderia produtos silenciosamente. E como a MART é em
-- português e a origem JÁ é em português, ela só serviria para virar inglês:
-- dependência a mais, cobertura incompleta, e no idioma errado. O slug é
-- formatado aqui mesmo (INITCAP sobre o underscore trocado por espaço).
--
-- product_name_lenght, escrito errado na origem, é corrigido AQUI (tam_nome).
-- A RAW e a STAGING preservam o erro de propósito, para que o caminho de volta
-- até o CSV continue literal; a MART é a primeira camada que pode limpar.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.dim_produto (
    sk_produto          INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id          VARCHAR(32)  NOT NULL UNIQUE,   -- chave natural
    categoria           VARCHAR(80)  NOT NULL,          -- 'Não informado' nos 610
    categoria_origem    VARCHAR(64),                    -- slug cru, NULL preservado
    anuncio_completo    BOOLEAN      NOT NULL,
    peso_g              INTEGER,
    comprimento_cm      INTEGER,
    altura_cm           INTEGER,
    largura_cm          INTEGER,
    volume_cm3          INTEGER,                        -- derivado; máx. real 296.208
    qtd_fotos           SMALLINT,
    tam_nome            SMALLINT,                       -- ex-product_name_lenght
    tam_descricao       INTEGER,
    dt_carga            TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_dim_produto_categoria ON mart.dim_produto (categoria);

-- -----------------------------------------------------------------------------
-- DIM_STATUS_PEDIDO — 8 linhas. A dimensão que quase não existiu.
--
-- O reflexo é deixar o status como texto solto na fato: são 8 valores, o
-- VertiPaq comprime, ninguém morre. O que muda a resposta é ORDENAÇÃO: no
-- painel você quer os status na ordem do funil (criado -> aprovado -> faturado
-- -> em processamento -> enviado -> entregue), não em ordem alfabética, e o
-- Power BI só ordena uma coluna por outra se essa outra coluna existir.
-- ordem_funil tem que morar em algum lugar — e repeti-la 112.650 vezes na fato
-- para armazenar 8 valores distintos é literalmente o problema que dimensão
-- resolve.
--
-- De brinde, os dois booleanos: sem eles, toda medida de receita carregaria
-- uma lista de status escrita à mão dentro do DAX, e essa lista estaria
-- escrita de novo, um pouco diferente, em cada medida.
--
--   eh_venda_efetiva = o pedido não foi cancelado nem ficou indisponível.
--                      Base de "receita" — inclui o que ainda está em trânsito,
--                      porque a venda aconteceu.
--   eh_entregue      = chegou ao cliente. Base de SLA e de análise de prazo.
--
-- Dois booleanos em vez de um porque "venda efetiva" sozinho é ambíguo: uma
-- pessoa lê como "concluída", outra como "não cancelada". Nomear os dois casos
-- separadamente resolve a ambiguidade no schema, não na cabeça de quem lê.
--
-- A CHAVE AQUI NÃO É IDENTITY, é atribuída à mão. IDENTITY serve para conjunto
-- ABERTO, que cresce e cujos membros ninguém enumera. Este é FECHADO e
-- conhecido: 8 status, garantidos pelo CHECK de staging.orders. Chave à mão em
-- lista fechada é estável para sempre, sem depender de upsert nem da ordem em
-- que as linhas foram inseridas.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart.dim_status_pedido (
    sk_status           SMALLINT     PRIMARY KEY,       -- atribuída à mão
    status_origem       VARCHAR(16)  NOT NULL UNIQUE,   -- chave natural
    status              VARCHAR(24)  NOT NULL,
    ordem_funil         SMALLINT     NOT NULL UNIQUE,
    eh_venda_efetiva    BOOLEAN      NOT NULL,
    eh_entregue         BOOLEAN      NOT NULL,

    -- Entregue implica venda efetiva. O contrário não vale (pedido enviado é
    -- venda e ainda não foi entregue). Sem isso, nada impede alguém de marcar
    -- 'canceled' como entregue numa edição futura.
    CONSTRAINT ck_dim_status_coerencia CHECK (NOT eh_entregue OR eh_venda_efetiva)
);
