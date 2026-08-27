-- =============================================================================
-- 08 — VIEWS DA CAMADA SEMÂNTICA
-- =============================================================================
--
-- Views que existem para o Power BI, não para o SQL. É a primeira vez que o
-- projeto cria uma — e ela passa no teste que o `sql/07` escreveu:
--
--   "View é para consulta que se REPETE, e quem vai repetir é o Power BI —
--    que ainda não existe. Quando o painel estiver montado, o que ele repetir
--    vira view com motivo, não com palpite."
--
-- O painel agora existe, e repete esta consulta em toda atualização. Deixou de
-- ser palpite.
--
-- ATENÇÃO À NUMERAÇÃO: o `07` é o arquivo de perguntas de negócio, somente
-- leitura, e NÃO faz parte da construção da mart — por isso o `build_mart.py`
-- pula de 06 para 08. O buraco é intencional; renumerar arquivo já versionado
-- quebraria os links do README e do histórico.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- VW_CALENDARIO — a dim_data sem o membro "Não informado".
--
-- POR QUE ELA EXISTE
--
-- O Power BI exige marcar uma tabela como "tabela de datas" para a inteligência
-- de tempo do DAX funcionar de forma confiável. A validação recusa coluna de
-- data com valor nulo, e a nossa tem exatamente um: a linha -1, cujo `data` é
-- NULL por força do CHECK ck_dim_data_sentinela.
--
-- Erro exato que isso produz na interface:
--   "A coluna de data não pode ter valores nulos"
--
-- AS DUAS CAMADAS QUEREM COISAS DIFERENTES, E AS DUAS ESTÃO CERTAS
--
-- O membro -1 foi criado para um problema de SQL: sem ele, um INNER JOIN
-- descartaria os itens sem data de entrega e sumiria faturamento sem erro
-- nenhum. Ele continua necessário na TABELA — é o destino da FK
-- fk_fato_vendas_data_entrega, e sem ele a carga da fato aborta.
--
-- Mas o Power BI não faz INNER JOIN. Linha de fato que aponta para chave
-- inexistente cai numa linha em branco criada por ele, e CONTINUA SOMANDO no
-- total. A proteção que o -1 dá em SQL, o motor tabular já dá sozinho.
--
-- Então a tabela mantém o membro (integridade referencial) e a view o remove
-- (exigência da camada semântica). Não é contradição: é cada camada resolvendo
-- o problema que ela tem.
--
-- O CUSTO, MEDIDO E ACEITO
--
-- Linhas da fato que usam o membro -1, por papel da data:
--     sk_data_compra   = -1  ....      0    (a relação ATIVA no Power BI)
--     sk_data_prevista = -1  ....      0
--     sk_data_entrega  = -1  ....  2.454    (relação INATIVA)
--
-- Só um dos três papéis alcança o -1, e é o pontilhado. Esses 2.454 itens
-- passam a cair na linha em branco automática do Power BI em vez do rótulo
-- "Não informado" — e continuam somando em qualquer total. Pela relação ativa,
-- a linha -1 nunca casou com nada: ela só aparecia como opção vazia num filtro.
--
-- ALTERNATIVAS DESCARTADAS
--
--   Gravar uma data sentinela (2015-12-31) na linha -1. Exigiria trocar o
--   CHECK, e deixaria a linha incoerente consigo mesma: `data` de verdade,
--   `ano` nulo e rótulo "Não informado". Um seletor de datas passaria a
--   oferecer 31/12/2015 como se fosse dia de operação.
--
--   Filtrar dentro do Power Query. Funciona, e cria a primeira transformação
--   fora do SQL — dentro de um binário que o git não sabe ler. A regra do
--   projeto é que transformação mora em SQL, versionada.
--
-- COLUNAS EXPLÍCITAS, NÃO `SELECT *`
--
-- Duas razões. CREATE OR REPLACE VIEW recusa mudança na lista de colunas, e um
-- `SELECT *` faria a próxima coluna adicionada à dim_data quebrar o replace com
-- mensagem obscura. E a lista explícita documenta o contrato: é isto que a
-- camada semântica enxerga.
--
-- Efeito colateral bem-vindo: sem a linha -1, `ano`, `mes`, `dia_semana` e
-- companhia deixam de ter nulos. Elas só eram anuláveis por causa dela.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_calendario AS
SELECT
    sk_data,
    data,
    ano,
    trimestre,
    mes,
    dia,
    ano_mes,
    nome_mes,
    nome_mes_abrev,
    dia_semana,
    nome_dia_semana,
    eh_fim_semana,
    semana_iso,
    dia_ano,
    primeiro_dia_mes,
    ultimo_dia_mes
FROM mart.dim_data
WHERE sk_data <> -1;

COMMENT ON VIEW mart.vw_calendario IS
    'dim_data sem o membro -1. Existe porque o Power BI recusa marcar como '
    'tabela de datas uma coluna com nulos. A TABELA mantem o membro para a FK '
    'da fato; a VIEW o remove para a camada semantica.';
