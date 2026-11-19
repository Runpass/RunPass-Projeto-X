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

- **A jornada começa sempre pela foto.** O `+` (perfil, início e tela da corrida) abre o cadastro da
  medalha pela foto da medalha; publicar uma experiência começa pela foto da corrida. Nunca começa
  pela escolha da corrida.
- **Ordem do cadastro da medalha, igual em toda tela que o tenha:** foto da medalha → leitura de
  *todo* o texto da medalha → busca da corrida no catálogo → escolher a corrida (ou buscar de novo,
  ou cadastrar uma corrida nova) → tempo, colocação, número do peito e pace, todos **opcionais** →
  oferecer publicar uma foto da corrida (outra foto, não a da medalha) → avaliação da corrida →
  **Concluir** ou **Sair**.
- O que foi preenchido (tempo, distância, pace, colocação, peito) aparece na publicação.
- Ao publicar a foto, só envia a foto e segue na jornada: **não** joga a pessoa na Início.
- **Lista de corridas é uma só**, o mesmo cartão em todas as telas (`EditionCompactCard`), com a
  imagem ocupando a largura inteira do cartão.
- **Ícones e botões discretos:** texto pequeno, sem botão grande colorido onde um ícone resolve.
