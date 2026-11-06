# S10 - Amigos: busca, seguir, feed e comentarios (06/11/2026)

Estado: implementado e testado localmente (backend 157 testes, app 50 testes). **Nao implantado no DEV**: exige change set da stack `runpass-dev-app` com aprovacao. Sem aceite humano.

## Decisoes do produto (usuario, 06/11/2026)
- Perfil **publico por padrao**. Seguir perfil publico e **imediato**; perfil **privado** exige **aprovacao** do dono.
- Perfil privado: so o dono e seguidores aceitos veem corridas, fotos, comentarios e contagens.

## O que existe
| Rota | Funcao |
| --- | --- |
| GET /profiles?q= | busca por nome ou usuario (sem acento, prefixo; minimo 2 letras) |
| GET /profiles/{id} | perfil, `followState`, `canView`, contagens |
| GET /profiles/{id}/participations | corridas concluidas visiveis (tempo/colocacao conforme `showTime`/`showPlacement`) |
| PUT/DELETE /profiles/{id}/follow | seguir, pedir, cancelar, deixar de seguir |
| GET /me/follow-requests; PUT/DELETE /me/follow-requests/{id} | aprovar, recusar ou remover seguidor |
| GET /feed, GET /posts/{id} | minhas publicacoes e as de quem sigo, mais recentes primeiro |
| GET/POST /posts/{id}/comments, DELETE /comments/{id} | comentar; apaga o autor ou o dono da publicacao |
| PATCH /me `isPrivate` | liga/desliga perfil privado |
| GET /participations/{id}/image | foto da medalha (link assinado de 5 min) respeitando a visibilidade |
| PATCH /participations/{id} `medalImageReference` | trocar a foto da medalha de corrida concluida |

Post = participacao concluida com `publishToFeed`. Dados: busca em `identity` (`PIDX#xx`), seguir em `identity` (`FOLLOWING#`/`FOLLOWER#`), comentarios em `history` (`POST#id`). Linhas de uma conta fora da particao dela ficam listadas em `sharedKeys` e saem na exclusao da conta (testado).

## Limites conhecidos (nao escondidos)
- **Bloqueio** (`/profiles/{id}/block`), **curtidas**, **editar comentario**, **mudar visibilidade de um post** (PATCH /posts) e **denuncias** nao foram implementados. O botao de curtir da Inicio ainda falha com aviso.
- Pedidos pendentes **nao viram seguidores sozinhos** se o perfil passar de privado para publico; o dono precisa aceitar.
- Perfis criados antes da busca entram no indice **na proxima vez que o dono abre o app** (GET /me).
- Feed e contagens leem as participacoes dos seguidos a cada chamada: serve para o beta (ate 100 seguidos, 500 por pessoa), nao para escala; medir antes de ampliar.
- Comentarios de uma publicacao apagada ficam inacessiveis, mas so saem do armazenamento quando o autor exclui a conta.
- Foto antiga trocada **continua no S3** sem referencia (limpeza de derivadas orfas segue pendente).
- Comentarios das corridas nas **informacoes da corrida** (avaliacoes publicas, S12) nao foram implementados.
- Sem limite de taxa para comentarios e sem moderacao.
