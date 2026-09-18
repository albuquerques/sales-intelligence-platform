# Insights: o que os dados mostram e o que eu faria

Seis conclusões sobre o marketplace, da mais importante para a menos. Cada uma
traz o número que a sustenta, por que ela importa e o que eu recomendaria. As
recomendações são hipóteses a testar, porque estes dados não têm custo, margem
nem conversão.

Todos os números são do mesmo período do painel, **jan/2017 a ago/2018**, e cada
seção diz onde conferir.

## O negócio no período

- **R$ 15,7 milhões** em **97.905 pedidos** de **94.703 clientes**; ticket médio
  de R$ 160,19.
- Em 2017 a receita mensal **dobrou**: de R$ 425,6 mil em março, o primeiro mês
  de operação plena, para R$ 861,5 mil em dezembro, com o pico da Black Friday
  em novembro (+53% sobre outubro).
- Em 2018 ela **parou de crescer**: de janeiro a agosto, entre R$ 979 mil e
  R$ 1,16 milhão por mês.
- SP, RJ e MG concentram **62,5% da receita** e 66,5% dos clientes.

## Resumo

| # | Conclusão | O número |
|---|---|---|
| 1 | Entrega atrasada destrói a avaliação | nota 4,29 no prazo; 1,70 com 8+ dias de atraso |
| 2 | O atraso é previsível: depende da margem da promessa | quanto menor a margem, maior o atraso (−0,87) |
| 3 | Quase toda venda é a primeira venda de alguém | 96,7% dos pedidos |
| 4 | O frete pesa mais onde o produto é barato e o cliente está longe | 23,68% em Móveis; 22,7% no Norte |
| 5 | Não existe carro-chefe | 18 de 74 categorias para passar de 80% |
| 6 | Cancelamento não é problema | 0,47% dos itens |

---

## 1. Entrega atrasada destrói a avaliação

**O que os dados mostram.** A nota que o cliente dá despenca com o atraso:

| Entrega | Avaliações | Nota média | 1 estrela |
|---|---|---|---|
| no prazo | 89.681 | **4,29** | 6,6% |
| 1 a 7 dias de atraso | 3.611 | **2,71** | 41,4% |
| 8 dias ou mais de atraso | 2.795 | **1,70** | 69,7% |

As entregas atrasadas são **6,7% das avaliações**, mas respondem por **36,7% das
avaliações de 1 estrela**.

**Por que importa.** Em marketplace, a avaliação é o que o próximo comprador lê
antes de decidir. Mais de um terço da insatisfação extrema vem de um problema
operacional que atinge 1 em cada 15 entregas, e que pode ser atacado sem mexer
em produto nem em preço.

**O que eu faria.** Tratar o atraso como a prioridade número um de satisfação,
à frente de qualquer ação sobre as próprias avaliações. Como teste: avisar o
cliente assim que um atraso ficar provável, e medir se a nota desses pedidos
fica acima dos 1,70 dos atrasos sem aviso.

**Onde conferir.** [`sql/10_avaliacoes.sql`](../sql/10_avaliacoes.sql),
consultas 1a e 1b. As avaliações não estão no painel: ficam só na camada RAW do
projeto.

---

## 2. O atraso é previsível: depende da margem da promessa

**O que os dados mostram.** O prazo informado ao cliente na compra fica acima
do tempo que a entrega realmente leva, e essa folga é **quase a mesma no país
inteiro, entre 11 e 16 dias**, enquanto o prazo real vai de 10,6 dias no
Sudeste a 22,5 no Norte. Onde a entrega é longa, a mesma folga vira uma margem
pequena:

| Região | Prazo real | 90% chegam em | Prometido | Margem | Atraso |
|---|---|---|---|---|---|
| Norte | 22,5 d | 37 d | 38,2 d | 1,70× | 8,7% |
| **Nordeste** | 19,8 d | **33 d** | **31,2 d** | **1,58×** | **12,6%** |
| Centro-Oeste | 14,9 d | 24 d | 27,3 d | 1,84× | 6,5% |
| Sudeste | 10,6 d | 19 d | 22,2 d | 2,10× | 5,9% |
| Sul | 13,9 d | 24 d | 27,1 d | 1,94× | 5,8% |

*Margem* é quantas vezes o prazo prometido cabe no real: 2× quer dizer que se
prometeu o dobro do que a entrega costuma levar.

- Nos 24 estados com volume, **quanto menor a margem, maior o atraso**:
  correlação de **−0,87**.
- Os **seis estados de menor margem são todos do Nordeste**. Alagoas é o
  extremo: promete 1,36 vez o prazo real e atrasa 20,9%. São Paulo está na
  outra ponta: 2,29 vezes e 4,4%.
- O Nordeste é a **única região** em que o prazo prometido médio (31,2 dias)
  fica abaixo do tempo em que 90% das entregas chegam (33 dias).
- E é a região de **pior avaliação**: nota 3,97 e 13,0% de 1 estrela, contra
  4,19 e 8,8% no Sul.

**Por que importa.** É a causa por trás do insight 1. Boa parte do atraso não é
a entrega demorar: é a promessa ser curta demais para o destino. E o Nordeste
não é marginal: são 9,1% de todas as entregas.

**O que eu faria.** Calcular o prazo prometido **por estado**, a partir do
histórico de entregas daquele estado (por exemplo, o tempo em que 90% delas
chegam), em vez de somar a mesma folga em todo lugar. O custo possível é
conversão: um prazo mais longo no checkout pode afastar compradores. Por isso,
testar primeiro no Nordeste, medindo atraso, nota e volume de vendas juntos.

A exceção que merece investigação à parte é o **Rio de Janeiro**: margem 1,79,
no meio da tabela, e 11,7% de atraso. Lá a margem não explica o atraso, e a
causa está fora destes dados.

**Como esta conclusão foi testada.** A versão anterior deste projeto dizia que
"o estado que mais precisa de folga é o que menos recebe", com base em dois
estados (AL e PR). No país inteiro isso não se sustenta: prazo longo e folga em
dias praticamente não andam juntos (correlação de −0,19). O que se sustenta é a
margem proporcional.

**Onde conferir.** Painel, página **Clientes** (prazo, atraso e folga por
estado). A margem e as correlações:
[`sql/09_insights.sql`](../sql/09_insights.sql), insight 2. A nota por região:
[`sql/10_avaliacoes.sql`](../sql/10_avaliacoes.sql), consulta 1c.

---

## 3. Quase toda venda é a primeira venda de alguém

**O que os dados mostram.** Dos 94.703 clientes, **91.829 (96,97%) compraram
uma única vez**. Só 2.874 voltaram (3,03%). Dos 97.905 pedidos, apenas 3.202
são recompra: **96,7% dos pedidos são a primeira compra de alguém**.

A receita por cliente (R$ 165,61) quase não passa do ticket médio (R$ 160,19).
A diferença, R$ 5,42, é o tamanho inteiro do valor que a recompra traz.

**Por que importa.** Sem recompra, a receita de cada mês é praticamente o
número de clientes novos daquele mês vezes o ticket. É por isso que a
estagnação de 2018 é, na prática, uma estagnação de aquisição: com 96,7% dos
pedidos vindos de quem compra pela primeira vez, receita parada quer dizer que
a entrada de clientes novos parou de crescer.

**O que eu faria.** Antes de investir em retenção, descobrir **por que ninguém
volta**: se é o tipo de produto (compra única por natureza), a experiência (o
insight 1 é um suspeito) ou a falta de contato depois da venda. Estes dados não
respondem a essa pergunta (veja a última seção).

**Onde conferir.** Painel, página **Clientes** (cartões e tabela por estado).
A contagem de recompras: [`sql/09_insights.sql`](../sql/09_insights.sql),
insight 3.

---

## 4. O frete pesa mais onde o produto é barato e o cliente está longe

**O que os dados mostram.** O peso do frete sobre o valor da mercadoria muda
com o produto e com o destino:

- **Por produto:** em Móveis Decoração o frete é **23,68%** da mercadoria; em
  Relógios Presentes, **8,37%**. O item médio de Móveis pesa 2,65 kg e custa
  R$ 87,69; o de Relógios pesa 0,58 kg e custa R$ 200,31. Frete cobra peso, e
  pesa mais onde há muito peso para pouco valor.
- **Por região:** **22,7%** no Norte e 21,7% no Nordeste, contra **15,2%** no
  Sudeste. No Norte e no Nordeste, é mais de R$ 1 de frete para cada R$ 5 de
  mercadoria.

O cliente distante também gasta mais por pedido, e **não só por causa do
frete**: na Bahia o ticket é R$ 181,44, contra R$ 142,97 em São Paulo, mas só
um terço dessa diferença é frete (R$ 29,85 contra R$ 17,37 por pedido). O resto
é mercadoria mais cara.

**Por que importa.** Uma leitura possível, que estes dados não provam: longe do
Sudeste, o frete **filtra as compras baratas**, e sobram as que o compensam. Se
for isso, existe uma demanda de itens baratos no Norte e no Nordeste que hoje
não vira venda.

**O que eu faria.** Testar uma política de frete por região e categoria (por
exemplo, frete subsidiado para itens de menor valor no Norte e no Nordeste) e
medir se aparecem as compras que hoje não acontecem. O teste exige dado de
conversão, que este dataset não tem.

**Onde conferir.** Painel, página **Produtos** (frete e preço médio por
categoria) e **Clientes** (ticket por estado). Frete por região, a separação
do ticket e o peso dos itens: [`sql/09_insights.sql`](../sql/09_insights.sql),
insight 4.

---

## 5. Não existe carro-chefe

**O que os dados mostram.** As 5 maiores categorias fazem **39,3%** da receita;
as 10 maiores, **62,4%**. São precisas **18 das 74** categorias para passar de
80% (81,3%).

**Por que importa.** O lado bom: nenhuma categoria sozinha é um risco, e uma
queda isolada não derruba o negócio. O lado difícil: não há poucas categorias
onde concentrar esforço de catálogo e de compra para mover o total.

**O que eu faria.** Priorizar categorias por um critério que não seja só o
tamanho, porque pela receita a lista de prioridades tem 18 itens. O peso do frete
(insight 4) é um candidato; a margem de cada categoria seria melhor, mas não
está nestes dados.

**Onde conferir.** Painel, página **Produtos**: a curva ABC e a tabela com o
percentual acumulado de cada categoria.

---

## 6. Cancelamento não é problema

**O que os dados mostram.** No período, **527 de 112.279 itens (0,47%)** foram
cancelados. Somam R$ 102,5 mil, o equivalente a 0,65% da receita.

**Por que importa.** Saber onde **não** gastar esforço também é conclusão. Entre
o cancelamento (0,47% dos itens) e o atraso (6,61% dos itens entregues, 36,7%
das avaliações de 1 estrela), a prioridade é clara.

**O que eu faria.** Nenhuma ação dedicada. Manter o indicador no painel como
alarme.

**Onde conferir.** Painel, página **Visão Geral** (funil de status).
[`sql/09_insights.sql`](../sql/09_insights.sql), insight 6.

---

## O que estes dados não respondem

- **Conversão.** Só existem vendas concluídas, sem nenhum dado de visita, busca
  ou carrinho abandonado. O efeito do frete e do prazo prometido na decisão de
  compra (insights 2 e 4) não é mensurável aqui.
- **Custo e margem.** Não há custo de produto, custo real do frete nem margem.
  Toda prioridade deste documento é por receita e por satisfação, não por
  lucro.
- **Por que o cliente não volta.** Pergunta em aberto que vale a próxima
  análise: *clientes cuja primeira entrega atrasou voltam menos?* O teste pede
  cuidado, porque quem comprou pela primeira vez em agosto de 2018 teve poucos dias
  para voltar antes de o dado acabar.
- **Pedidos sem item.** No dataset inteiro, 775 pedidos não têm nenhum item e
  ficam fora de todas as contas. A maioria deles (603) está marcada como
  indisponível.
- **O depois.** O dataset é um retrato que termina em 2018. A estagnação daquele
  ano não diz nada sobre o que veio em seguida.
