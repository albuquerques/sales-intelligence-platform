# Camada MART — o modelo estrela

Como a `staging` vira um modelo pronto para análise, o que prova que ele está
certo e as primeiras perguntas de negócio respondidas sobre ele. A camada
anterior está em [pipeline.md](pipeline.md); o painel construído em cima, em
[dashboard.md](dashboard.md).

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

---

## O grão

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

## Aditivo e não aditivo

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

## Três chaves de data, não seis

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

## O que prova que a fato está certa

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

## Por que não há uma segunda fact table

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

## As perguntas de negócio em SQL

```bash
psql -U postgres -d sales_intelligence -f sql/07_perguntas_negocio.sql
```

Oito perguntas em [`sql/07_perguntas_negocio.sql`](../sql/07_perguntas_negocio.sql),
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

As respostas abaixo são sobre o **dataset inteiro**. O painel aplica um recorte
de jan/2017 a ago/2018, e por isso alguns números dele diferem um pouco destes
(ticket médio R$ 160,19 no painel; 18 categorias para chegar a 80%).

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

### Por que nenhuma consulta virou `VIEW`

View é para consulta que se repete, e quando estas foram escritas quem ia
repetir era o Power BI — que ainda não existia. Criar view naquele momento
seria adivinhar o que ele ia pedir, e cada view é mais um lugar onde a regra de
negócio passa a morar.

O teste valeu depois: a única view do projeto, a
[`vw_calendario`](../sql/08_create_mart_views.sql), nasceu quando o painel
precisou dela, e é consulta que ele repete a cada atualização.
