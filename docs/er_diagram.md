# Diagrama ER — Olist Brazilian E-Commerce Dataset

Gerado a partir da inspeção direta dos cabeçalhos dos CSVs em `data/raw/`.

```mermaid
erDiagram
    CUSTOMERS {
        string customer_id PK
        string customer_unique_id
        string customer_zip_code_prefix
        string customer_city
        string customer_state
    }

    ORDERS {
        string order_id PK
        string customer_id FK
        string order_status
        timestamp order_purchase_timestamp
        timestamp order_approved_at
        timestamp order_delivered_carrier_date
        timestamp order_delivered_customer_date
        timestamp order_estimated_delivery_date
    }

    ORDER_ITEMS {
        string order_id PK, FK
        int order_item_id PK
        string product_id FK
        string seller_id FK
        timestamp shipping_limit_date
        decimal price
        decimal freight_value
    }

    ORDER_PAYMENTS {
        string order_id PK, FK
        int payment_sequential PK
        string payment_type
        int payment_installments
        decimal payment_value
    }

    ORDER_REVIEWS {
        string review_id PK
        string order_id FK
        int review_score
        string review_comment_title
        string review_comment_message
        timestamp review_creation_date
        timestamp review_answer_timestamp
    }

    PRODUCTS {
        string product_id PK
        string product_category_name FK
        int product_name_lenght
        int product_description_lenght
        int product_photos_qty
        decimal product_weight_g
        decimal product_length_cm
        decimal product_height_cm
        decimal product_width_cm
    }

    SELLERS {
        string seller_id PK
        string seller_zip_code_prefix
        string seller_city
        string seller_state
    }

    PRODUCT_CATEGORY_TRANSLATION {
        string product_category_name PK
        string product_category_name_english
    }

    GEOLOCATION {
        string geolocation_zip_code_prefix
        decimal geolocation_lat
        decimal geolocation_lng
        string geolocation_city
        string geolocation_state
    }

    CUSTOMERS ||--o{ ORDERS : places
    ORDERS ||--|{ ORDER_ITEMS : contains
    ORDERS ||--o{ ORDER_PAYMENTS : "paga via"
    ORDERS ||--o{ ORDER_REVIEWS : recebe
    PRODUCTS ||--o{ ORDER_ITEMS : "vendido como"
    SELLERS ||--o{ ORDER_ITEMS : vende
    PRODUCT_CATEGORY_TRANSLATION ||--o{ PRODUCTS : categoriza
    CUSTOMERS }o--o{ GEOLOCATION : "zip code (referência fraca)"
    SELLERS }o--o{ GEOLOCATION : "zip code (referência fraca)"
```

## Legenda de cardinalidade

| Símbolo | Significado |
|---|---|
| `\|\|--o{` | um-para-muitos (obrigatório do lado "um") |
| `\|\|--\|{` | um-para-muitos (obrigatório em ambos os lados) |
| `}o--o{` | muitos-para-muitos opcional |
| `PK` | chave primária |
| `FK` | chave estrangeira |
| `PK, FK` | chave primária composta que também é estrangeira |

## Observações importantes

- **`customer_id` vs `customer_unique_id`**: cada pedido gera um `customer_id` novo em `orders`/`customers`. Quem identifica a pessoa real ao longo do tempo é `customer_unique_id`. Use `customer_unique_id` para análises de cliente único (ex: recorrência de compra); use `customer_id` para o join técnico com `orders`.
- **`order_items` e `order_payments`** têm chave primária composta (`order_id` + `order_item_id` / `payment_sequential`), porque um pedido pode ter múltiplos itens e múltiplas parcelas/formas de pagamento.
- **`geolocation`** não tem chave primária única (o mesmo `zip_code_prefix` se repete em várias linhas com lat/lng ligeiramente diferentes). O join com `customers`/`sellers` é feito por `zip_code_prefix`, mas é uma relação fraca — vale agregar (ex: média de lat/lng por prefixo) antes de usar.
- **`order_reviews`** é modelado aqui como 1:N em relação a `orders`, mas na prática é quase sempre 1:1 (raríssimos pedidos com mais de uma review).
