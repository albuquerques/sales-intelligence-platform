# Dicionário de Dados — Olist Brazilian E-Commerce Dataset

Gerado a partir de um profiling automático dos CSVs em `data/raw/` (contagem de linhas, tipo inferido, % de nulos, valores distintos e amostras reais). Ver diagrama de relacionamento em [`er_diagram.md`](er_diagram.md).

**Legenda de colunas:** Chave = PK (chave primária) / FK (chave estrangeira) / — (nenhuma). Nulos % é sobre o total de linhas do arquivo.

---

## CUSTOMERS — `olist_customers_dataset.csv` (99.441 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| customer_id | string | 0% | 99.441 (100%) | PK | Identificador do cliente **por pedido** — muda a cada compra do mesmo cliente. Usado para o join técnico com `orders`. | `06b8999e2fba1a1fbc88172c00ba8bc7` |
| customer_unique_id | string | 0% | 96.096 | — | Identificador estável da pessoa real. Use este campo para análises de cliente único (recorrência, LTV). | `861eff4711a542e4b93843c6dd7febb0` |
| customer_zip_code_prefix | int | 0% | 14.994 | — | 5 primeiros dígitos do CEP do cliente. Chave de junção fraca com `geolocation`. | `14409` |
| customer_city | string | 0% | 4.119 | — | Cidade do cliente. | `franca` |
| customer_state | string | 0% | 27 | — | UF do cliente (26 estados + DF). | `SP` |

---

## ORDERS — `olist_orders_dataset.csv` (99.441 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| order_id | string | 0% | 99.441 (100%) | PK | Identificador único do pedido. | `e481f51cbdc54678b7cc49136f2d6af7` |
| customer_id | string | 0% | 99.441 (100%) | FK → customers | Cliente que fez o pedido (1 valor único por pedido — ver nota sobre `customer_id`). | `9ef432eb6251297304e76186b10a928d` |
| order_status | string | 0% | 8 | — | Status do pedido: `delivered`, `shipped`, `canceled`, `unavailable`, `invoiced`, `processing`, `created`, `approved`. | `delivered` |
| order_purchase_timestamp | timestamp | 0% | 98.875 | — | Data/hora da compra. | `2017-10-02 10:56:33` |
| order_approved_at | timestamp | 0,16% | 90.734 | — | Data/hora da aprovação do pagamento. Nulo = pagamento nunca aprovado (ex: pedido cancelado antes da aprovação). | `2017-10-02 11:07:15` |
| order_delivered_carrier_date | timestamp | 1,79% | 81.019 | — | Data/hora de postagem para a transportadora. Nulo = ainda não postado. | `2017-10-04 19:55:00` |
| order_delivered_customer_date | timestamp | 2,98% | 95.665 | — | Data/hora de entrega ao cliente. Nulo = ainda não entregue (ou cancelado). | `2017-10-10 21:25:13` |
| order_estimated_delivery_date | timestamp | 0% | 459 | — | Data estimada de entrega dada no momento da compra. Útil para calcular SLA (atraso = entregue - estimado). | `2017-10-18 00:00:00` |

---

## ORDER_ITEMS — `olist_order_items_dataset.csv` (112.650 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| order_id | string | 0% | 98.666 | PK (composta), FK → orders | Pedido ao qual o item pertence. Repete quando o pedido tem mais de um item. | `00010242fe8c5a6d1ba2dd792cb16214` |
| order_item_id | int | 0% | 21 (posição sequencial: 1, 2, 3...) | PK (composta) | Número sequencial do item dentro do pedido (1 = primeiro item). | `1` |
| product_id | string | 0% | 32.951 | FK → products | Produto vendido nesse item. | `4244733e06e7ecb4970a6e2683c13e61` |
| seller_id | string | 0% | 3.095 | FK → sellers | Vendedor responsável por esse item (marketplace multi-seller). | `48436dade18ac8b2bce089ec2a041202` |
| shipping_limit_date | timestamp | 0% | 93.318 | — | Prazo limite para o vendedor postar o item à transportadora. | `2017-09-19 09:45:35` |
| price | decimal | 0% | 5.968 | — | Preço do item (sem frete). | `58.90` |
| freight_value | decimal | 0% | 6.999 | — | Valor do frete desse item. | `13.29` |

> Nota: `price` e `freight_value` são **por item**, não por pedido. Para o total do pedido, agregue (`SUM`) por `order_id`.

---

## ORDER_PAYMENTS — `olist_order_payments_dataset.csv` (103.886 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| order_id | string | 0% | 99.440 | PK (composta), FK → orders | Pedido ao qual o pagamento pertence. Repete quando há múltiplas parcelas/formas de pagamento. | `b81ef226f3fe1789b1e8b2acac839d17` |
| payment_sequential | int | 0% | 29 | PK (composta) | Ordem sequencial da transação de pagamento dentro do pedido (>1 quando o cliente combina formas de pagamento, ex: voucher + cartão). | `1` |
| payment_type | string | 0% | 5 | — | Forma de pagamento: `credit_card`, `boleto`, `voucher`, `debit_card`, `not_defined`. | `credit_card` |
| payment_installments | int | 0% | 24 | — | Número de parcelas. | `8` |
| payment_value | decimal | 0% | 29.077 | — | Valor dessa transação de pagamento. | `99.33` |

---

## ORDER_REVIEWS — `olist_order_reviews_dataset.csv` (99.224 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| review_id | string | 0% | 98.410 | PK* | Identificador da avaliação. **Não é 100% único** (ver nota abaixo). | `7bc2406110b926393aa56f80a40eba40` |
| order_id | string | 0% | 98.673 | FK → orders | Pedido avaliado. Quase sempre 1:1 com `orders`, raríssimos casos com >1 review. | `73fc7af87114b39712e6da79b0a377eb` |
| review_score | int | 0% | 5 | — | Nota de 1 a 5 dada pelo cliente. | `4` |
| review_comment_title | string | 88,34% | 4.528 | — | Título do comentário (opcional — a maioria dos clientes não preenche). | `recomendo` |
| review_comment_message | string | 58,70% | 36.160 | — | Texto livre do comentário (opcional). Nomes de empresas nesse campo foram anonimizados com nomes de casas de Game of Thrones. | `Recebi bem antes do prazo estipulado.` |
| review_creation_date | timestamp | 0% | 636 | — | Data em que a pesquisa de satisfação foi enviada ao cliente. | `2018-01-18 00:00:00` |
| review_answer_timestamp | timestamp | 0% | 98.248 | — | Data/hora em que o cliente respondeu a avaliação. | `2018-01-18 21:46:59` |

> ⚠️ **Qualidade de dados:** `review_id` tem 98.410 valores distintos em 99.224 linhas — ou seja, existem `review_id` duplicados no arquivo bruto. Não trate como PK garantida sem deduplicar antes de modelar (ex: no `sql/`, valide com `GROUP BY review_id HAVING COUNT(*) > 1`).

---

## PRODUCTS — `olist_products_dataset.csv` (32.951 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| product_id | string | 0% | 32.951 (100%) | PK | Identificador único do produto. | `1e9e8ef04dbcff4541ed26657ea517e5` |
| product_category_name | string | 1,85% | 74 | FK → product_category_name_translation | Categoria do produto, em português. | `perfumaria` |
| product_name_lenght | int | 1,85% | 67 | — | Nº de caracteres do nome do produto no anúncio. | `40` |
| product_description_lenght | int | 1,85% | 2.961 | — | Nº de caracteres da descrição do anúncio. | `287` |
| product_photos_qty | int | 1,85% | 20 | — | Quantidade de fotos no anúncio. | `1` |
| product_weight_g | int | 0,01% | 2.205 | — | Peso do produto em gramas. | `225` |
| product_length_cm | int | 0,01% | 100 | — | Comprimento em cm. | `16` |
| product_height_cm | int | 0,01% | 103 | — | Altura em cm. | `10` |
| product_width_cm | int | 0,01% | 96 | — | Largura em cm. | `14` |

> Nota: os 610 nulos (1,85%) em `product_category_name`, `product_name_lenght`, `product_description_lenght` e `product_photos_qty` são **as mesmas linhas** — produtos com anúncio incompleto ficam sem nenhum desses campos preenchidos. Já os 2 nulos em peso/dimensões são casos isolados, independentes desse grupo.

---

## SELLERS — `olist_sellers_dataset.csv` (3.095 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| seller_id | string | 0% | 3.095 (100%) | PK | Identificador único do vendedor. | `3442f8959a84dea7ee197c632cb2df15` |
| seller_zip_code_prefix | int | 0% | 2.246 | — | 5 primeiros dígitos do CEP do vendedor. Chave de junção fraca com `geolocation`. | `13023` |
| seller_city | string | 0% | 611 | — | Cidade do vendedor. | `campinas` |
| seller_state | string | 0% | 23 | — | UF do vendedor. | `SP` |

---

## PRODUCT_CATEGORY_TRANSLATION — `product_category_name_translation.csv` (71 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| product_category_name | string | 0% | 71 (100%) | PK | Nome da categoria em português (mesmo domínio de `products.product_category_name`). | `beleza_saude` |
| product_category_name_english | string | 0% | 71 (100%) | — | Tradução da categoria para inglês. | `health_beauty` |

> ⚠️ **Qualidade de dados:** o CSV original tem um caractere BOM (`﻿`) grudado no nome da primeira coluna (`﻿product_category_name`). Se a ferramenta de carga não tratar BOM automaticamente, a coluna pode chegar com nome incorreto — vale normalizar o encoding para `UTF-8` sem BOM na etapa de ingestão (`sql/` ou pipeline de load).

---

## GEOLOCATION — `olist_geolocation_dataset.csv` (1.000.163 linhas)

| Coluna | Tipo | Nulos % | Distintos | Chave | Descrição | Exemplo |
|---|---|---|---|---|---|---|
| geolocation_zip_code_prefix | int | 0% | 3.820 | — | 5 primeiros dígitos do CEP. Repete várias vezes (não é chave). | `01037` |
| geolocation_lat | decimal | 0% | 117.932 | — | Latitude. | `-23.54562128115268` |
| geolocation_lng | decimal | 0% | 118.027 | — | Longitude. | `-46.63929204800168` |
| geolocation_city | string | 0% | 48 | — | Cidade associada ao ponto. | `sao paulo` |
| geolocation_state | string | 0% | 3 | — | UF associada ao ponto. | `SP` |

> Nota: essa tabela **não tem chave primária** — é um conjunto de amostras de geocodificação por CEP (múltiplas coordenadas por prefixo). Para juntar com `customers`/`sellers`, agregue antes (ex: `AVG(lat)`, `AVG(lng)` por `zip_code_prefix`) para evitar explosão de linhas no join.

---

## Resumo de qualidade de dados (achados do profiling)

| Achado | Onde | Impacto |
|---|---|---|
| `review_id` duplicado | order_reviews | Não usar como PK sem deduplicar |
| BOM no header | product_category_name_translation.csv | Normalizar encoding na ingestão |
| Nulos correlacionados | products (610 linhas) | Produto com anúncio incompleto — decidir regra de tratamento (excluir vs. imputar) |
| Sem PK própria | geolocation | Agregar por zip antes de fazer join |
| `customer_id` ≠ pessoa | customers / orders | Usar `customer_unique_id` para métricas de cliente |
