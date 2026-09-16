# Pipeline — do CSV ao PostgreSQL

Como o dado sai dos arquivos da Olist e chega validado ao PostgreSQL. A camada
seguinte, o modelo estrela, está em [star_schema.md](star_schema.md).

## Dois níveis independentes

| Nível | Banco | O que precisa | Para quê |
|---|---|---|---|
| **RAW** (bronze) | DuckDB, embarcado | só `pip install` | roda logo após o clone |
| **STAGING** (prata) | PostgreSQL, servidor | servidor + `.env` | chaves estrangeiras, tipos exatos, transação |

O nível RAW existe para que o repositório não dependa de nada externo: DuckDB é
uma biblioteca lendo um arquivo, e a amostra em `data/sample/` já vem
versionada. O nível STAGING usa PostgreSQL porque `FOREIGN KEY`, `CHECK` e
`NUMERIC` exato só valem de verdade num servidor — e servidor não tem como ser
embarcado no clone. Um não substitui o outro.

---

## A amostra

Os CSVs brutos **não são versionados** (~121 MB): dados de entrada não pertencem
ao histórico do git, que guarda toda versão para sempre. Mas um repositório que
não roda depois do clone também não serve. A solução tem três camadas:

| Camada | Onde | Para quê |
|---|---|---|
| Amostra versionada | `data/sample/` (~2,5 MB) | O projeto roda sem download |
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

## Camada RAW — DuckDB

```bash
python src/load_raw.py --sample     # a amostra versionada
python src/download_data.py         # ou: baixa ~121 MB e valida os checksums
python src/load_raw.py              # e carrega o dataset completo
```

Isso cria `sales_intelligence.duckdb` com o schema `raw` populado. Para conferir:

```bash
python -c "import duckdb; print(duckdb.connect('sales_intelligence.duckdb').sql('FROM raw.orders LIMIT 5'))"
```

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

Saída da validação no dataset completo (`--check-only`):

```
[1/3] Lendo CSVs
  customers         99,441 linhas
  sellers            3,095 linhas
  products          32,951 linhas
  geolocation    1,000,163 linhas
  orders            99,441 linhas
  order_items      112,650 linhas

[2/3] Validando
  OK       customers      sem problemas
  OK       sellers        sem problemas
  OK       products       sem problemas
  OK       geolocation    sem problemas
  OK       orders         sem problemas
  OK       order_items    sem problemas
```

Sem o `--check-only`, a etapa `[3/3]` grava as seis tabelas — 1.347.741 linhas —
numa transação só.

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

- **Validar tudo antes de gravar qualquer coisa.** As 6 tabelas são conferidas
  com a conexão ainda fechada. Se algo falha, nada é gravado e a saída lista
  todos os problemas de uma vez, em vez de um por execução.
- **`COPY`, não `df.to_sql()`.** O `to_sql` gera `INSERT`s e exige o SQLAlchemy;
  para as 112 mil linhas de `order_items` são minutos. O `COPY` é o carregador
  em massa nativo — segundos.
- **Uma única transação.** Ou as 6 tabelas entram, ou o banco fica exatamente
  como estava. Nunca meio carregado.
- **Idempotente.** `TRUNCATE` antes da carga; rodar duas vezes dá o mesmo
  resultado.
- **Ordem de carga ditada pelas FKs:** `customers`, `sellers`, `products`,
  `geolocation` → `orders` → `order_items`.

### Credenciais

Ficam em `.env`, que **não é versionado**. O modelo está em `.env.example`. As
variáveis usam os nomes padrão da libpq (`PGHOST`, `PGUSER`, `PGPASSWORD`…), que
tanto o `psql` quanto o `psycopg` leem sem configuração extra.

---

## Contraste entre as camadas

| | RAW (DuckDB) | STAGING (PostgreSQL) | MART (PostgreSQL) |
|---|---|---|---|
| Tipos | tudo `VARCHAR` | `NUMERIC(10,2)`, `TIMESTAMP`, `SMALLINT` | idem |
| Constraints | nenhuma | 5 PK, 4 FK, 6 CHECK | 6 PK, 7 FK, 6 UNIQUE, 9 CHECK |
| Modelagem | igual à origem | igual à origem | estrela |
| Nomes | do CSV, erros inclusive | do CSV | português |
| Objetivo | receber o dado como ele é | garantir que ele é válido | responder perguntas |

Detalhes de tipo em [`sql/02_create_postgres_tables.sql`](../sql/02_create_postgres_tables.sql):
`NUMERIC` em dinheiro (nunca `FLOAT` — ponto flutuante binário não representa
R$ 0,10 exatamente e o faturamento fecha com diferença de centavos), `CHAR(5)`
no CEP (como inteiro, `01037` viraria `1037`), `TIMESTAMP` sem fuso (a origem
não informa fuso, e inventar um é pior que não ter).

---

## Por que estas ferramentas

**DuckDB** na camada RAW: roda embarcado, sem servidor nem Docker, lê CSV
nativamente e processa o milhão de linhas de `geolocation` em segundos. É o que
permite o projeto rodar logo após o clone.

**PostgreSQL** nas camadas STAGING e MART: é onde chaves estrangeiras, `CHECK` e
tipos decimais exatos passam a valer de verdade. Também é o banco que se
encontra em produção — o DuckDB é excelente para análise local, mas não é um
servidor multiusuário.

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
