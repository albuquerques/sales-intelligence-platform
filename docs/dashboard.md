# O painel em Power BI

Três páginas — Visão Geral, Produtos e Clientes — sobre a camada MART descrita
em [star_schema.md](star_schema.md). Este documento cobre como abrir o painel,
como o modelo semântico foi construído e provado, e o que cada página mostra.

## Abrindo o painel

São dois arquivos, e eles não pedem a mesma coisa:

| Arquivo | Precisa de | Para quê |
|---|---|---|
| `sales_intelligence.pbix` ([baixar](https://github.com/albuquerques/sales-intelligence-platform/releases/download/dashboard-v1/sales_intelligence.pbix)) | só o Power BI Desktop | ver o painel — os dados vêm dentro |
| `powerbi/sales_intelligence.pbip` | PostgreSQL com a `mart` carregada | editar — é a fonte, em texto |

Ao abrir o `.pbip` numa máquina nova, a conexão pede:

```
Servidor ......... localhost
Banco ............ sales_intelligence
Modo ............. Importar        (não DirectQuery)
Autenticação ..... Banco de Dados  (não Windows), usuário postgres
```

Se o PostgreSQL local não tiver SSL configurado, o Power BI falha com "não
damos suporte à conexão criptografada". Desmarque **Criptografar conexão** na
mesma janela de credenciais — em `localhost`, é seguro.

### Duas configurações por máquina

Em *Opções → Arquivo atual → Configurações regionais*. Elas ficam na instalação,
não no arquivo, e sem elas o painel sai em formato americano:

```
Localidade padrão da cadeia de caracteres
para datas e números .................... Português (Brasil)   (vem "Automático")
Unidades de exibição padrão para "none" .. marcada              (vem desmarcada)
```

A primeira decide se `#,0` vira `97.905` ou `97,905`. A segunda impede que o
visual abrevie `97.905` para "98 mil" por conta própria.

---

## O modelo semântico

`powerbi/sales_intelligence.pbip` — as 6 tabelas da `mart` em modo **Import**,
7 relações, `dim_data` marcada como tabela de datas e 23 medidas DAX.

**A camada semântica não repete regra de negócio; ela herda.** As duas
definições do `sql/07` (receita = `preco + frete`; dinheiro exclui cancelado)
valem idênticas no DAX — se divergissem, o painel discordaria do arquivo que
documenta as respostas e não haveria como saber qual está certo.

### As medidas em texto comentado

O modelo é salvo em TMDL, que já é texto — mas guarda cada medida numa linha só,
sem comentário nenhum. As 23 medidas também vivem em
[`powerbi/medidas.dax`](../powerbi/medidas.dax), formatadas e explicadas: é o
que se lê no GitHub, e o que permite revisar uma mudança de regra. O TMDL é o
que executa; os dois precisam andar juntos.

### Como o modelo foi provado

Nenhuma medida foi aceita por parecer certa. Cada uma foi conferida contra um
número que o `build_mart.py` já tinha verificado. Os valores são sobre o
**dataset inteiro**, sem o recorte de período das páginas — é o que mostra a
página *Conferência* do relatório.

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

### As três decisões que o modelo exigiu

**Import, não DirectQuery.** Dado congelado em out/2018 e 112 mil linhas: o
VertiPaq comprime tudo e o DAX fica completo. DirectQuery serve para dado que
muda e volume que não cabe — nenhum dos dois é o caso.

**`mart.vw_calendario` ([`sql/08`](../sql/08_create_mart_views.sql)).** O Power BI
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

### De `.pbix` para PBIP: o relatório vira texto

O `.pbix` é um ZIP com o modelo compilado dentro. O git guarda, mas não lê — e
cada salvar entra inteiro no histórico. O **PBIP** (Power BI Project) é o mesmo
relatório como pasta de texto: um `visual.json` por visual, o modelo em TMDL.
Dá para revisar num diff, e dá para escrever direto no arquivo.

Custo medido e aceito: **o PBIP não guarda os dados importados**, só a
definição. Abrir o `.pbip` exige o PostgreSQL de pé. Por isso os dois níveis
convivem, como já acontece entre DuckDB e PostgreSQL: o `.pbix` preserva a
propriedade de abrir e ver o painel sem instalar nada. Ele deixou de ser a
fonte e passou a ser artefato de saída.

E, como artefato, saiu do git. Binário versionado entra inteiro a cada versão e
nunca mais sai do histórico; o `.pbix` é publicado como [GitHub
Release](https://github.com/albuquerques/sales-intelligence-platform/releases/tag/dashboard-v1),
o mesmo caminho que os CSVs brutos já seguiam.

### Publicando uma versão nova do `.pbix`

Quando o painel mudar, gere o binário a partir do `.pbip`: *Arquivo → Salvar
como → Procurar*, e troque o campo **Tipo** para `Arquivo do Power BI (*.pbix)`
— ele vem preenchido com `.pbip`, e salvar sem trocar só reescreve o projeto.

Com a mudança do PBIP já commitada e enviada, publique um Release novo e troque
o número da versão no link deste documento e do README:

```bash
gh release create dashboard-v2 powerbi/sales_intelligence.pbix --title "Painel Power BI"
```

Um Release por versão, em vez de substituir o arquivo do `dashboard-v1`: cada
tag aponta para o commit do PBIP que gerou aquele binário.

---

## Página Visão Geral

Cinco KPIs, receita e prazo médio de entrega por mês, o funil de status e o
bloco de SLA. Recorte de **jan/2017 a ago/2018**.

### O recorte de período é uma decisão, e ela está escrita na tela

A série começa em set/2016, mas nov/2016 não tem pedido nenhum e set/2018 tem
um item. Num gráfico de linha isso desenha um colapso do negócio que nunca
aconteceu. O painel filtra **2017-01 a 2018-08** — 349 itens e R$ 51.820,29
fora, ou 0,33% da receita.

O filtro é de **página**, não de visual: filtrar só o gráfico deixaria os
cartões somando o dataset inteiro, e o KPI não fecharia com a linha logo
abaixo. E é por **intervalo de datas**, não por lista de meses marcados —
critério, não lista digitada, pelo mesmo motivo que o `eh_mes_pleno` do
`sql/07` é calculado.

O subtítulo `jan/2017 a ago/2018` existe por causa disso. Um recorte que o
leitor não enxerga é uma afirmação sem contexto: "R$ 15,7 milhões" sem dizer de
quando.

### Ordem do eixo é informação, não estética

O Power BI ordena um gráfico pela medida por padrão. Numa série temporal isso
transforma a linha num ranking: a curva desce sempre, e a queda é artefato da
ordenação, não do negócio — número certo, gráfico mentindo.

Os dois gráficos ordenam pela coluna `ano_mes`, ascendente. Ela é `CHAR(7)` no
formato `'2017-05'` justamente para que ordem alfabética e ordem cronológica
sejam a mesma coisa; a decisão foi tomada na etapa das dimensões e é aqui que
ela paga.

### Formatação também produz número errado

Três defeitos apareceram nesta página, e nenhum deles é estético:

| Sintoma | Causa |
|---|---|
| `$ 15.683.706,74` | o botão de moeda grava o cifrão americano; símbolo é literal na máscara, e literal não se traduz |
| `R$ 15,683,706.74` | a máscara é escrita na convenção invariante e traduzida ao desenhar — a localidade dessa tradução estava em `Automático` e resolvia para `en-US` |
| `98 mil` | o cartão tem unidade de exibição própria, que vence a formatação da medida |

Os três produzem números que *parecem* certos. O primeiro e o terceiro são
corrigidos no arquivo versionado (`formatString` no TMDL, `labelDisplayUnits`
no `visual.json`); o segundo é configuração da instalação e precisa ser
repetido em cada máquina — ver [Duas configurações por
máquina](#duas-configurações-por-máquina).

---

## Página Produtos

Curva ABC das categorias, o peso do frete e a tabela completa das 74
categorias. Mesmo recorte de período da Visão Geral — o filtro é **copiado**
do `page.json` da outra página, não reescrito: duas versões do mesmo recorte
podem divergir, e um painel que discorda de si mesmo não tem conserto de
confiança.

### A concentração é fraca, e essa é a resposta

A curva ABC costuma mostrar poucos itens respondendo por 80% da receita. Aqui
não:

```
top  5 categorias ....  39,3%
top 10 categorias ....  62,4%
top 18 categorias ....  ~80%      de um total de 74
```

São precisas 18 categorias para chegar a 80%. Não existe carro-chefe neste
marketplace, e um gráfico de barras sozinho nunca diria isso — por isso a
tabela completa fica embaixo, com o `% Acumulado` linha a linha.

### A armadilha da direção do filtro

A medida `Categorias` parece trivial e não é:

```dax
-- ERRADA: conta as 74 linhas da dimensão, sempre
Categorias = DISTINCTCOUNT ( dim_produto[categoria] )

-- CERTA
Categorias =
CALCULATE (
    DISTINCTCOUNT ( dim_produto[categoria] ),
    fato_vendas,
    dim_status_pedido[eh_venda_efetiva] = TRUE ()
)
```

Num modelo estrela o filtro corre **da dimensão para a fato, nunca de volta**.
A versão ingênua ignora o filtro de período da página, o de status e qualquer
clique num visual — e hoje daria `74`, que é o número certo, porque no recorte
atual todas as categorias venderam. Bastaria filtrar um mês para ela dizer 74
onde venderam 50. `fato_vendas` como argumento de filtro é o que empurra o
contexto de volta.

### Densidade de valor: o frete pesa onde o item é barato

```
Móveis Decoração ....... frete 23,68% do valor da mercadoria  ·  item médio R$  87,69
Relógios Presentes ..... frete  8,37%                          ·  item médio R$ 200,31
```

Quase três vezes de diferença, e não é ineficiência de logística: um relógio de
R$ 300 pesa 200 gramas, uma estante de R$ 300 pesa 20 quilos. As duas séries
estão no mesmo visual — colunas descendo, linha subindo — porque em dois
gráficos separados a comparação dependeria de o leitor cruzar duas listas
ordenadas de formas diferentes.

Essa análise só existe porque a `fato_vendas` guardou `preco` e `frete` em
colunas distintas. Com um único `valor_total` gravado, ela seria impossível.

---

## Página Clientes

Quem compra, onde está e em quanto tempo recebe.

### 97% compram uma vez e não voltam

```
1 pedido .... 91.829 clientes .... 96,97%
2 pedidos ....  2.639 ............  2,79%
3 ou mais ......  235 ............  0,25%
```

Esse número não vira gráfico: seria uma barra gigante e três invisíveis. Ele é
cartão e coluna de tabela.

O par `Receita por Cliente` (R$ 165,61) e `Ticket Médio` (R$ 160,19) está na
mesma linha de KPIs de propósito: **a diferença entre os dois é a recorrência**.
Se ninguém comprasse duas vezes, seriam o mesmo número. R$ 5,42 é o tamanho
inteiro do efeito.

### Por que a recorrência é medida em DAX, e não lida da dimensão

A `dim_cliente` já traz uma coluna `eh_recorrente`, calculada na carga. Usá-la
seria trivial e estaria **errado**: ela foi calculada sobre o dataset inteiro e
responderia `2.997`, ignorando o filtro de período da página, enquanto todo o
resto mostra `2.874`.

Um KPI que ignora em silêncio o filtro da própria página é o mesmo padrão que
este projeto vem evitando desde a camada RAW. A medida recalcula:

```dax
Clientes Recorrentes =
CALCULATE (
    COUNTROWS (
        FILTER (
            VALUES ( fato_vendas[sk_cliente] ),
            CALCULATE ( DISTINCTCOUNT ( fato_vendas[order_id] ) ) >= 2
        )
    ),
    dim_status_pedido[eh_venda_efetiva] = TRUE ()
)
```

O `CALCULATE` de dentro faz **transição de contexto**: para cada cliente da
iteração, recalcula quantos pedidos distintos ele tem naquele contexto. A
coluna da dimensão continua útil para outra coisa — **segmentar** novos contra
recorrentes num slicer, onde ignorar o período é o comportamento desejado.

### A promessa de prazo é calibrada ao contrário

```
       prazo    atraso    folga do prazo
AL ... 24,4 d    20,9%        -8,7
PA ... 23,7 d    11,4%       -14,1
SP ....8,6 d      4,4%       -11,2
PR ... 11,9 d     3,9%       -13,3
```

Alagoas demora três vezes o que São Paulo demora e atrasa cinco vezes mais. Mas
o achado está na última coluna: a folga de AL é de **8,7 dias**, menor que a do
Paraná (**13,3**). **O estado que mais precisa de prazo folgado é o que menos
recebe** — a promessa é mais apertada justamente onde a operação é pior.

Cumprir prazo inflado não é pontualidade, e o inverso também vale: o atraso de
AL é em parte uma promessa mal calibrada.

> **Ressalva estatística:** as três piores posições do gráfico são estados de
> volume mínimo — RR tem 45 itens entregues, AP tem 81, AM tem 163. A média é
> real, mas apoiada em pouca observação. Alagoas, com 426, é o primeiro em que
> o número tem peso.

### O frete aparece de novo, agora como distância

```
SP ....  8,64 dias  ·  ticket R$ 142,97
RJ .... 15,06 dias  ·  ticket R$ 166,37
BA .... 19,19 dias  ·  ticket R$ 181,44
```

Quanto mais longe, maior o ticket — e não é porque o interior compra produtos
mais caros. `Ticket Médio` inclui frete, e frete cresce com a distância. O
cliente distante paga mais pelo mesmo carrinho e espera mais tempo por ele.

Na página de Produtos o frete explicava a diferença entre categorias
(densidade de valor); aqui explica a diferença entre estados (distância). É o
mesmo eixo visto de dois ângulos.
