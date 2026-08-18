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

> **Não precisa baixar nada.** O repositório já inclui uma amostra em
> `data/sample/`, então o projeto roda logo após o clone.

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

---

## Arquitetura

Modelo **medallion**, em camadas:

```
CSV  ->  RAW (bronze)  ->  STAGING (prata)  ->  MART (ouro)  ->  Power BI
         tudo VARCHAR      tipado e limpo       modelado
         sem constraint    deduplicado          fatos e dimensões
```

**Estado atual: camada RAW concluída.**

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
  01_create_raw_tables.sql
src/
  download_data.py   obtém o dataset completo
  load_raw.py        carrega os CSVs no DuckDB
  make_sample.py     regenera a amostra e o manifesto (só para manutenção)
powerbi/
```

## Stack

**DuckDB** como banco analítico: roda embarcado, sem servidor nem Docker, lê CSV
nativamente e processa o milhão de linhas de `geolocation` em segundos. O dialeto
SQL é próximo do PostgreSQL, então migrar para um servidor depois é barato.

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
