# Sales Intelligence Platform

Pipeline de dados sobre o **Olist Brazilian E-Commerce Dataset** (~100 mil pedidos
reais de marketplace), da ingestão dos arquivos brutos até a camada pronta para
análise em Power BI.

## Problema

Uma empresa de e-commerce possui dados de vendas distribuídos em diferentes
fontes e precisa de uma estrutura centralizada para análise de desempenho.

## Objetivo

Construir um pipeline capaz de coletar, armazenar, transformar e disponibilizar
informações comerciais para análise.

---

## Começando

O projeto roda em **dois níveis**, e eles são independentes:

| Nível | Banco | O que precisa | Para quê |
|---|---|---|---|
| **RAW** (bronze) | DuckDB, embarcado | só `pip install` | roda logo após o clone |
| **STAGING** (prata) | PostgreSQL, servidor | servidor + `.env` | chaves estrangeiras, tipos exatos, transação |

O nível RAW existe para que o repositório não dependa de nada externo: DuckDB é
uma biblioteca lendo um arquivo, e a amostra em `data/sample/` já vem
versionada. O nível STAGING usa PostgreSQL porque `FOREIGN KEY`, `CHECK` e
`NUMERIC` exato só valem de verdade num servidor — e servidor não tem como ser
embarcado no clone. Um não substitui o outro.

### Nível RAW — sem instalar nada

```bash
git clone https://github.com/albuquerques/sales-intelligence-platform.git
cd sales-intelligence-platform

pip install -r requirements.txt
python src/load_raw.py --sample
```

Isso cria `sales_intelligence.duckdb` com o schema `raw` populado. Para conferir:

```bash
python -c "import duckdb; print(duckdb.connect('sales_intelligence.duckdb').sql('FROM raw.orders LIMIT 5'))"
```

O nível STAGING está descrito em [Camada STAGING — PostgreSQL](#camada-staging--postgresql).

### Rodando com o dataset completo

A amostra tem ~3 mil pedidos; o dataset real tem 99.441 pedidos e 1 milhão de
linhas de geolocalização. Para trabalhar com ele:

```bash
python src/download_data.py     # baixa ~121 MB e valida os checksums
python src/load_raw.py
```

---

## Sobre a amostra

Os CSVs brutos **não são versionados** (~121 MB): dados de entrada não pertencem
ao histórico do git, que guarda toda versão para sempre. Mas um repositório que
não roda depois do clone também não serve. A solução tem três camadas:

| Camada | Onde | Para quê |
|---|---|---|
| Amostra versionada | `data/sample/` (~5 MB) | O projeto roda sem download |
| Dataset completo | GitHub Release, via `src/download_data.py` | Escala real |
| Manifesto | `data/manifest.json` | SHA256 + contagens; valida o download |

A amostra é **referencialmente íntegra**. Não são "as primeiras N linhas de cada
arquivo" — isso quebraria todos os JOINs. São 3.000 pedidos sorteados, dos quais
todo o resto é derivado em cascata:

```
orders (sorteio)
 ├── customers      : só os clientes desses pedidos
 ├── order_items    : só os itens desses pedidos
 │    ├── products  : só os produtos que aparecem nesses itens
 │    └── sellers   : só os vendedores que aparecem nesses itens
 ├── order_payments : só os pagamentos desses pedidos
 └── order_reviews  : só as avaliações desses pedidos
```

O `src/make_sample.py` verifica que não sobrou nenhuma referência órfã antes de
gravar. Os defeitos de qualidade do dataset original (`review_id` duplicado, BOM
no cabeçalho, nulos correlacionados em `products`) foram preservados de propósito
— eles são parte do que o pipeline precisa tratar.

Essa integridade não é preciosismo: sem ela, a carga no PostgreSQL
(`load_postgres.py --sample`) falharia nas chaves estrangeiras. A amostra
alimenta os dois níveis.

---

## Arquitetura

Modelo **medallion**, em camadas:

```
CSV  ->  RAW (bronze)  ->  STAGING (prata)  ->  MART (ouro)  ->  Power BI
         tudo VARCHAR      tipado e limpo       modelado
         sem constraint    deduplicado          fatos e dimensões
```

**Estado atual: RAW (DuckDB) + STAGING (PostgreSQL) + MART completa (modelo
estrela com 5 dimensões e a fato) + perguntas de negócio em SQL + o modelo
carregado e conferido dentro do Power BI.** Falta montar as páginas do
dashboard.

A camada RAW é uma cópia fiel da origem, e isso é uma decisão deliberada:

- **Toda coluna é `VARCHAR`.** Converter datas na entrada faria uma única linha
  malformada derrubar a carga inteira. A tipagem fica para a staging, onde o erro
  pode ser tratado sem perder o resto.
- **Nenhuma constraint.** Uma PK em `raw.order_reviews` rejeitaria os `review_id`
  duplicados que sabemos existir. A RAW guarda o problema para que ele seja
  tratado, não escondido.
- **Nomes idênticos ao CSV, erros de grafia incluídos** (`product_name_lenght`).
  Renomear aqui impediria comparar a tabela com o arquivo original.
- **Colunas de linhagem** `_source_file` e `_ingested_at` respondem "de onde veio
  esta linha e quando entrou?".

---

## Camada STAGING — PostgreSQL

> **Exige um servidor PostgreSQL rodando.** Não é opcional no sentido de
> acessório — é aqui que as garantias de integridade existem. É opcional apenas
> no sentido de que o nível RAW continua funcionando sem isso.

Pipeline `CSV → pandas → validação → PostgreSQL`:

```bash
# 1. crie o banco vazio
createdb -U postgres sales_intelligence

# 2. configure as credenciais
cp .env.example .env                       # e preencha PGPASSWORD

# 3. rode o pipeline
pip install -r requirements.txt
python src/load_postgres.py --check-only   # valida sem gravar
python src/load_postgres.py --sample       # carrega a amostra
python src/load_postgres.py                # carrega o dataset completo
```

No Windows, o instalador do PostgreSQL não adiciona os utilitários ao `PATH`;
use o caminho completo e `Copy-Item` no lugar do `cp`:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\createdb.exe" -U postgres sales_intelligence
Copy-Item .env.example .env
```

Saída da carga completa (347.578 linhas, ~43 s):

```
[2/3] Validando
  OK       customers      sem problemas
  OK       sellers        sem problemas
  OK       products       sem problemas
  OK       orders         sem problemas
  OK       order_items    sem problemas

[3/3] Gravando no PostgreSQL
  OK       staging.customers         99,441 linhas
  OK       staging.sellers            3,095 linhas
  OK       staging.products          32,951 linhas
  OK       staging.orders            99,441 linhas
  OK       staging.order_items      112,650 linhas
```

### Por que o pandas está no meio

No `load_raw.py` o DuckDB lê o CSV sozinho, dentro do `INSERT` — o dado nunca
passa pela memória do Python. É rápido, mas não existe ponto onde inspecionar o
dado entre ler e gravar. O DataFrame é esse ponto.

### O que é validado, e por quê

| Checagem | Exemplo de saída |
|---|---|
| Colunas esperadas presentes | `colunas ausentes no CSV: product_weight_g` |
| PK única e não-nula (composta em `order_items`) | `PK (customer_id): 2 linhas duplicadas` |
| `NOT NULL` do DDL | `customer_id: 3 valores nulos` |
| Largura fixa (ID 32, CEP 5, UF 2) | `customer_id: 1 valores fora do tamanho 32` |
| Conversão de inteiros e decimais | `product_weight_g: 1 valores com casa decimal` |
| Formato de data | `order_purchase_timestamp: 1 datas em formato inválido` |
| Domínio fechado (`order_status`) | `order_status: 1 valores fora do domínio` |
| Integridade referencial | `order_id: 1 valores sem correspondência em orders.order_id` |

O PostgreSQL pegaria quase tudo isso sozinho — mas diria apenas
`violates foreign key constraint "fk_order_items_order"`, sem dizer quantas
linhas nem quais. **A constraint garante; o Python explica.** Por isso o projeto
tem os dois: validação em Python para diagnosticar, constraint no banco para
valer também fora deste script.

### Decisões de carga

- **Validar tudo antes de gravar qualquer coisa.** As 5 tabelas são conferidas
  com a conexão ainda fechada. Se algo falha, nada é gravado e a saída lista
  todos os problemas de uma vez, em vez de um por execução.
- **`COPY`, não `df.to_sql()`.** O `to_sql` gera `INSERT`s e exige o SQLAlchemy;
  para as 112 mil linhas de `order_items` são minutos. O `COPY` é o carregador
  em massa nativo — segundos.
- **Uma única transação.** Ou as 5 tabelas entram, ou o banco fica exatamente
  como estava. Nunca meio carregado.
- **Idempotente.** `TRUNCATE` antes da carga; rodar duas vezes dá o mesmo
  resultado.
- **Ordem de carga ditada pelas FKs:** `customers`, `sellers`, `products` →
  `orders` → `order_items`.

### Contraste entre as camadas

| | RAW (DuckDB) | STAGING (PostgreSQL) | MART (PostgreSQL) |
|---|---|---|---|
| Tipos | tudo `VARCHAR` | `NUMERIC(10,2)`, `TIMESTAMP`, `SMALLINT` | idem |
| Constraints | nenhuma | 5 PK, 4 FK, 6 CHECK | 6 PK, 7 FK, 6 UNIQUE, 9 CHECK |
| Modelagem | igual à origem | igual à origem | estrela |
| Nomes | do CSV, erros inclusive | do CSV | português |
| Objetivo | receber o dado como ele é | garantir que ele é válido | responder perguntas |

Detalhes de tipo em [`sql/02_create_postgres_tables.sql`](sql/02_create_postgres_tables.sql):
`NUMERIC` em dinheiro (nunca `FLOAT` — ponto flutuante binário não representa
R$ 0,10 exatamente e o faturamento fecha com diferença de centavos), `CHAR(5)`
no CEP (como inteiro, `01037` viraria `1037`), `TIMESTAMP` sem fuso (a origem
não informa fuso, e inventar um é pior que não ter).

### Credenciais

Ficam em `.env`, que **não é versionado**. O modelo está em `.env.example`. As
variáveis usam os nomes padrão da libpq (`PGHOST`, `PGUSER`, `PGPASSWORD`…), que
tanto o `psql` quanto o `psycopg` leem sem configuração extra.

---

## Camada MART — o modelo estrela

```bash
python src/build_mart.py                 # cria/atualiza dimensões + fato e verifica
python src/build_mart.py --so-verificar  # só roda as verificações, não escreve
```

```
              dim_data (1.828)          dim_produto (32.951)
                       \                   /
                        \                 /
   dim_cliente (96.096) ── fato_vendas ── dim_vendedor (3.095)
                             112.650      /
                                \        /
                          dim_status_pedido (8)
```

Os quatro arquivos SQL rodam **numa transação só**. Ou o modelo inteiro fica
coerente, ou o schema fica exatamente como estava — uma fato gravada apontando
para uma dimensão que não foi é o pior estado possível deste banco, porque ele
*parece* inteiro.

### O grão

> Uma linha de `fato_vendas` é **um item vendido dentro de um pedido**.

Essa frase decide todo o resto, e está gravada na `PRIMARY KEY (order_id,
order_item_id)` — não só em comentário. Sem a PK, o grão é uma promessa; com
ela, o banco rejeita qualquer carga que o viole.

O grão de pedido foi descartado por um motivo estrutural: 10.578 pedidos têm
2+ itens e 1.278 têm 2+ vendedores, então nesse grão `dim_produto` e
`dim_vendedor` ficam **inalcançáveis** — e "faturamento por categoria" é a
pergunta central do painel. **Custo aceito e documentado:** 775 pedidos não têm
item nenhum (77% deles `unavailable`) e por isso não existem na fato. Contagem
de pedidos dá 98.666, não 99.441.

### Aditivo e não aditivo

| Coluna | Tipo de medida | Como usar |
|---|---|---|
| `preco`, `frete` | aditiva | soma em qualquer combinação de dimensões |
| `dias_entrega`, `dias_vs_previsto` | **não aditiva** | média — "total de dias de entrega" não significa nada |

O Power BI põe Soma como padrão em toda coluna numérica, então marcar as duas
últimas é cuidado ativo, não formalidade.

Não existe `valor_total`: para medida aditiva, `SUM(preco) + SUM(frete)` é
*identidade* com `SUM(preco + frete)`, e guardar a coluna criaria um segundo
lugar onde a mesma verdade pode divergir. Não existe `quantidade`: neste grão
ela é constante 1, e `COUNT(*)` já responde.

### Três chaves de data, não seis

`dim_data` aparece três vezes na fato — compra, entrega e previsão — porque é
uma **dimensão de papéis múltiplos**. Das seis datas do dataset, três ficaram de
fora: cada uma a mais é uma relação inativa no Power BI, que cobra
`USERELATIONSHIP` em toda medida que a usar.

Ausência de entrega (2,18% dos itens) aparece de duas formas coerentes entre si,
e um `CHECK` obriga as duas a concordarem:

- **na chave**, vira `-1` — o membro "Não informado". Com `NULL` ali, um
  `INNER JOIN` apagaria esses itens e sumiria faturamento sem erro nenhum;
- **na medida**, vira `NULL` — que o `AVG` ignora, e é o certo: pedido não
  entregue não tem prazo. Gravar `0` puxaria a média para baixo e mentiria.

### O que prova que a fato está certa

`build_mart.py` roda **21 verificações capazes de reprovar** (mais 12
informativas) e desfaz a transação inteira se qualquer uma falhar — modelo que
não passou não fica gravado. As três que carregam o peso:

| Verificação | Pega o quê |
|---|---|
| `SUM(preco)` e `SUM(frete)` **em centavos inteiros** contra a `staging` | explosão de junção — o defeito que duplica receita sem mudar nada visível |
| viagem de volta `sk → dimensão → chave natural` vs. `staging` | apelido de `JOIN` trocado, que produz chave válida apontando para o produto errado |
| `-1` e prazo `NULL` concordando | linha que some do filtro de data e continua contando na média |

Contagem sozinha não basta: uma fato pode ter o número de linhas certo e o
dinheiro errado. É por isso que a soma é a verificação central, e é comparada em
centavos — em ponto flutuante, uma diferença de 0,0000001 reprovaria sem haver
erro nenhum.

---

## As primeiras perguntas de negócio

```bash
psql -U postgres -d sales_intelligence -f sql/07_perguntas_negocio.sql
```

Oito perguntas em [`sql/07_perguntas_negocio.sql`](sql/07_perguntas_negocio.sql),
somente leitura. É a primeira etapa que *consome* o modelo em vez de construí-lo
— e o teste real dele: pergunta que exige contorcionismo em SQL é sintoma de
modelagem errada, não de SQL fraco. Nenhuma exigiu.

**Duas regras valem para o arquivo inteiro**, escritas no cabeçalho porque dois
números do painel que discordam custam mais que qualquer consulta:

- **Receita = `preco + frete`** (o que o cliente pagou). As parcelas aparecem
  separadas onde a diferença importa.
- **Dinheiro exclui cancelado, volume mostra os dois.** Receita filtra
  `eh_venda_efetiva` — R$ 15.735.527,03 de base. P8 não filtra, porque "quanto
  se cancela" é a própria pergunta.

| | Pergunta | Resposta curta |
|---|---|---|
| P1 | A receita cresce? | ~2,3× de mar/17 a ago/18; pico em nov/17 (Black Friday, +53%) |
| P2 | Quais categorias sustentam? | **17 de 74** fazem 80% da receita |
| P3 | Quanto vale um pedido? | Ticket médio R$ 160,24 · **mediana R$ 105,28** |
| P4 | Onde está o dinheiro? | SP+RJ+MG = 62,5%; ticket é *inverso* à concentração |
| P5 | O cliente volta? | **97% compram uma vez só** |
| P6 | A entrega cumpre o prazo? | AL atrasa 20,8%, SP 4,4% — mas o prazo é inflado |
| P7 | Quanto o frete pesa? | 22,7% do preço no Norte, 15,2% no Sudeste |
| P8 | O que não vira venda? | 0,49% dos itens — cancelamento é irrelevante aqui |

### As três armadilhas que essas consultas desviam

O cabeçalho do arquivo documenta as três, porque cada uma produz um número
*plausível e errado* — o tipo que ninguém confere:

- **O grão é de item.** `AVG(preco + frete)` na fato dá R$ 140,37 e parece ticket
  médio. Não é: subestima em 12,4%, porque pedido com 3 itens é contado 3 vezes
  pelo valor de um item. Ticket médio exige agregar por pedido *antes* da média.
- **A série temporal tem buraco e toco.** 2016-11 não tem nenhum item e 2018-09
  tem 1 — corte da extração, não queda de vendas. Num gráfico de linha isso vira
  um colapso do negócio. A coluna `eh_mes_pleno` é calculada do próprio dado.
- **8 itens são `delivered` sem data de entrega.** Toda análise de SLA usa
  `eh_entregue` **e** `dias_entrega IS NOT NULL`, nunca só uma das duas.

### Nenhuma consulta virou `VIEW`

View é para consulta que se repete, e quem vai repetir é o Power BI — que ainda
não existe. Criar view agora seria adivinhar o que ele vai pedir, e cada view é
mais um lugar onde a regra de negócio passa a morar.

### Por que não há uma segunda fact table

`order_payments` e `order_reviews` seguem fora do modelo, e é decisão, não
esquecimento: as duas estão em **grão de pedido**, e `fato_vendas` está em grão
de item. Como coluna da fato existente seriam defeito — pagamento explodiria a
junção (2.961 pedidos têm 2+ formas de pagamento), e nota repetida por item
faria a média pesar cada pedido pelo número de itens que ele tem. Mereceriam
fatos próprias, ligadas às mesmas dimensões — o padrão se chama *fact
constellation*, e é escopo que este projeto não assumiu.

O custo está medido: atraso na entrega derruba a nota de **4,29** (no prazo)
para **1,70** (8+ dias de atraso, com 69,7% de avaliações de 1 estrela). É a
análise mais forte que o dataset permite, e ela está fora do modelo.

---

## O modelo dentro do Power BI

`powerbi/sales_intelligence.pbix` — as 6 tabelas da `mart` em modo **Import**,
7 relações, `dim_data` marcada como tabela de datas e 14 medidas DAX.

**A camada semântica não repete regra de negócio; ela herda.** As duas
definições do `sql/07` (receita = `preco + frete`; dinheiro exclui cancelado)
valem idênticas no DAX — se divergissem, o painel discordaria do arquivo que
documenta as respostas e não haveria como saber qual está certo.

### As medidas ficam em texto, não só no binário

O `.pbix` é binário: o git guarda, mas não lê. Um `git diff` nele não diz nada,
e uma medida errada entraria no histórico sem rastro. Por isso as 14 medidas
também vivem em [`powerbi/medidas.dax`](powerbi/medidas.dax), comentadas — é o
que se lê no GitHub, e o que permite revisar uma mudança de regra.

### Como o modelo foi provado

Nenhuma medida foi aceita por parecer certa. Cada uma foi conferida contra um
número que o `build_mart.py` já tinha verificado:

| Medida | Valor | Medida | Valor |
|---|---|---|---|
| Receita | R$ 15.735.527,03 | Itens Entregues | 110.189 |
| Receita Mercadoria | R$ 13.494.400,74 | Prazo Médio | 12,41 dias |
| Receita Frete | R$ 2.241.126,29 | Itens com Atraso | 7.264 |
| Receita c/ cancelados | R$ 15.843.553,24 | % com Atraso | 6,59% |
| Pedidos | 98.199 | Folga Média do Prazo | −12,03 dias |
| Itens Vendidos | 112.101 | Ticket Médio | R$ 160,24 |
| Clientes | 94.983 | Itens por Pedido | 1,14 |

A primeira delas sozinha prova cinco coisas: a conexão, que as 112.650 linhas
vieram inteiras, que a relação com `dim_status_pedido` propaga filtro, que o
`eh_venda_efetiva` foi aplicado (senão daria 15.843.553,24) e que o
`NUMERIC(10,2)` atravessou PostgreSQL → Npgsql → VertiPaq → DAX sem perder
centavo.

### As três decisões que a etapa exigiu

**Import, não DirectQuery.** Dado congelado em out/2018 e 112 mil linhas: o
VertiPaq comprime tudo e o DAX fica completo. DirectQuery serve para dado que
muda e volume que não cabe — nenhum dos dois é o caso.

**`mart.vw_calendario` ([`sql/08`](sql/08_create_mart_views.sql)).** O Power BI
recusa marcar como tabela de datas uma coluna com nulos, e a `dim_data` tem um:
o membro `-1`, criado na etapa da fato para que os itens sem entrega não sumam
num `INNER JOIN`. A tabela mantém o membro — é destino da FK; a view o remove —
é exigência da camada semântica. **As duas camadas querem coisas diferentes e as
duas estão certas.** Medido antes de decidir: só `sk_data_entrega` chega ao
`-1`, e essa é justamente a relação inativa.

**Nenhuma transformação no Power Query.** Ele foi aberto uma vez, para trocar a
*origem* de uma consulta — o que não é transformar dado. A regra continua:
transformação mora em SQL, versionada. Dentro do `.pbix` ela ficaria trancada
num binário.

### O filtro duplo do SLA

As medidas de prazo filtram `eh_entregue` **e** dependem de `dias_entrega` não
vazio. `AVERAGE` e `COUNT` já ignoram vazio — o que resolve os 8 itens marcados
`delivered` sem data —, mas engoliriam os **7 itens de pedidos cancelados que
têm data de entrega**. Sem o filtro duplo, a base dá 110.196 em vez de 110.189 e
o atraso dá 7.265 em vez de 7.264: diferença pequena o bastante para ninguém
conferir, que é o que a torna perigosa.

---

## Estrutura

```
data/
  sample/            amostra versionada (roda sem download)
  raw/               dataset completo (gitignored)
  manifest.json      checksums e contagens
docs/
  data_dictionary.md dicionário com profiling de todas as colunas
  er_diagram.md      diagrama ER (Mermaid)
sql/
  01_create_raw_tables.sql        camada RAW  (DuckDB)
  02_create_postgres_tables.sql   camada STAGING (PostgreSQL)
  03_create_mart_dimensions.sql   dimensões da MART
  04_load_mart_dimensions.sql     carga staging -> mart
  05_create_mart_fato.sql         fato_vendas: grão, 7 FKs, medidas
  06_load_mart_fato.sql           carga da fato (chave natural -> substituta)
  07_perguntas_negocio.sql        8 perguntas de negócio (somente leitura)
  08_create_mart_views.sql        vw_calendario para o Power BI
src/
  download_data.py   obtém o dataset completo
  load_raw.py        carrega os CSVs no DuckDB
  load_postgres.py   CSV -> pandas -> validação -> PostgreSQL
  build_mart.py      staging -> mart, com verificação
  make_sample.py     regenera a amostra e o manifesto (só para manutenção)
powerbi/
  sales_intelligence.pbix         o modelo e o painel
  medidas.dax                     as 14 medidas em texto legível
.env.example         modelo das credenciais do PostgreSQL
```

## Stack

**DuckDB** na camada RAW: roda embarcado, sem servidor nem Docker, lê CSV
nativamente e processa o milhão de linhas de `geolocation` em segundos. É o que
permite o projeto rodar logo após o clone.

**PostgreSQL** na camada STAGING: é onde chaves estrangeiras, `CHECK` e tipos
decimais exatos passam a valer de verdade. Também é o banco que se encontra em
produção — o DuckDB é excelente para análise local, mas não é um servidor
multiusuário.

**pandas** entre os dois, como o ponto onde o dado pode ser inspecionado antes
de ser gravado.

---

## Manutenção

Para regenerar a amostra e publicar o dataset completo (precisa dos CSVs em
`data/raw/`):

```bash
python src/make_sample.py          # regenera data/sample/ + data/manifest.json
```

Publicar o Release que o `download_data.py` consome:

```bash
cd data/raw && zip -r ../../olist-dataset.zip *.csv && cd ../..
gh release create data-v1 olist-dataset.zip --title "Dataset bruto (Olist)"
```

Sem o `gh` instalado, dá para criar o release pela interface do GitHub em
*Releases > Draft a new release*, usando a tag `data-v1` e anexando o zip.

---

## Fonte dos dados

[Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce),
publicado pela Olist no Kaggle. Licença **CC BY-NC-SA 4.0** — uso não comercial,
com atribuição e compartilhamento sob a mesma licença.
