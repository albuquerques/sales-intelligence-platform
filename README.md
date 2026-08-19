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

**Estado atual: RAW concluída (DuckDB) + STAGING concluída (PostgreSQL).**

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

| | RAW (DuckDB) | STAGING (PostgreSQL) |
|---|---|---|
| Tipos | tudo `VARCHAR` | `NUMERIC(10,2)`, `TIMESTAMP`, `SMALLINT` |
| Constraints | nenhuma | 5 PK, 4 FK, 5 CHECK, `NOT NULL` |
| Objetivo | receber o dado como ele é | garantir que ele é válido |

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
src/
  download_data.py   obtém o dataset completo
  load_raw.py        carrega os CSVs no DuckDB
  load_postgres.py   CSV -> pandas -> validação -> PostgreSQL
  make_sample.py     regenera a amostra e o manifesto (só para manutenção)
powerbi/
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
