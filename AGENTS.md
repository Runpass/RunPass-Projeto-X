# RunPass

## Antes de implementar

- Use `PRD_RunPass_MVP_v2.md` para produto e `PDLC/M4/SPEC_RunPass_MVP_v1.md` como única SPEC ativa. Decisões explícitas posteriores prevalecem sobre pendências históricas.
- Consulte `PDLC/M4/implementation-slices.md` para escopo, dependências e aceite de cada entrega. Resolva as dependências da parte afetada antes de implementá-la.
- Para alterar rotas ou persistência, leia também `PDLC/M4/API-RunPass-v1.openapi.json` e `PDLC/M4/MODELO-DYNAMODB-RunPass-v1.md`; mantenha contrato, desenho e SPEC coerentes.

## Execução e verificação

- Setup e comandos locais: `docs/desenvolvimento.md`. Execute `make check` para Python/contrato e `make mobile-check` quando alterar o mobile.
- Use dados sintéticos e adaptadores locais nos testes; serviços AWS reais pertencem à integração DEV autorizada.
- A primeira entrega é autenticação → catálogo → rascunho → imagem → conclusão → avaliação e medalha. Preserve autorização, privacidade, versões e idempotência desde o primeiro fluxo.
- Registre resultados e limitações no slice. Diferencie teste local, integração real e aceite humano.
- Desenvolvimento local está autorizado. Provisionamento pago exige orçamento e autorização; PROD/beta tem aprovação própria. Mantenha credenciais e dados reais fora do Git.

## Padrão único por função (decisão de 19/11/2026, Thiago)

Telas que fazem a mesma coisa têm **a mesma funcionalidade e o mesmo desenho**. Antes de mexer em
uma delas, procure as outras que fazem o mesmo e mude todas, ou extraia um widget comum. Vale para
cadastro de medalha, cadastro/pedido de corrida, publicação de foto, escolha de corrida e avaliação.

- **A jornada começa sempre pela foto.** O `+` do perfil abre direto o cadastro da medalha (foto da
  medalha). O `+` da Início tem **duas opções**: *Cadastrar medalha* e *Postar foto*. Nunca começa
  pela escolha da corrida.
- **Cadastro da medalha, igual em toda tela que o tenha:** foto da medalha → leitura de todo o
  texto da medalha → **um único campo**, o nome da corrida (já preenchido com o que foi lido), e a
  lista de corridas achadas → tocar na corrida segue para **tempo, lugar, km, pace, número de peito
  e avaliação** (tela da participação, tudo opcional) → *depois da avaliação*, a opção de postar uma
  foto da corrida (outra foto, não a da medalha) na linha do tempo → **Concluir** ou **Sair**.
  Não achou a corrida: buscar de novo com outro nome ou **cadastrar a corrida manualmente**.
- Em **Corridas**, o campo de busca por nome fica sempre à vista, sem lupa; sem resultado, aparece
  o cadastro manual da corrida.
- O que foi preenchido (tempo, distância, pace, colocação, peito) aparece na publicação.
- Postar só a foto **não** joga a pessoa na Início com os dados preenchidos; ela segue na jornada.
- Medalhas: a ordem padrão é pela **data da corrida**, não pela data do cadastro.
- **Lista de corridas é uma só**, o mesmo cartão em todas as telas (`EditionCompactCard`), com a
  imagem ocupando a largura inteira do cartão.
- **Ícones e botões discretos:** texto pequeno, sem botão grande colorido onde um ícone resolve.
