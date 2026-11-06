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
- **Bloqueio** (`/profiles/{id}/block`), **editar comentario**, **mudar visibilidade de um post** (PATCH /posts) e **denuncias** nao foram implementados. (curtidas foram implementadas na rodada 2, abaixo.)
- Pedidos pendentes **nao viram seguidores sozinhos** se o perfil passar de privado para publico; o dono precisa aceitar.
- Perfis criados antes da busca entram no indice **no proximo login** (GET /beta/status) ou ao abrir o perfil (GET /me). Confirmado em DEV (06/11/2026): so apareciam na busca os perfis que tinham enviado foto, porque a foto era o primeiro PATCH /me depois do deploy; o indice nao depende de foto.
- Feed e contagens leem as participacoes dos seguidos a cada chamada: serve para o beta (ate 100 seguidos, 500 por pessoa), nao para escala; medir antes de ampliar.
- Comentarios de uma publicacao apagada ficam inacessiveis, mas so saem do armazenamento quando o autor exclui a conta.
- Foto antiga trocada **continua no S3** sem referencia (limpeza de derivadas orfas segue pendente).
- Comentarios das corridas nas **informacoes da corrida** (avaliacoes publicas, S12) nao foram implementados.
- Sem limite de taxa para comentarios e sem moderacao.

## Rodada 2 (teste no iPhone, 06/11/2026)
Ajustes pedidos depois do teste humano e como ficaram.

| Pedido | Resultado |
| --- | --- |
| Foto de perfil: recortar, camera, apagar, obrigatoria no cadastro | Tela de recorte circular (`crop_your_image`), escolha camera ou galeria, "Remover foto" com confirmacao (`PATCH /me photoReference: null`). Cadastro novo tem passo "Sua foto de perfil" obrigatorio depois da admissao; o passo tambem aparece para perfil na versao 1 sem foto (cadastro nao concluido). Quem apagar a foto depois nao e forcado a enviar outra. |
| Foto da medalha no feed so aparecia para o dono | Causa: a Inicio so pedia o link `/participations/{id}/image` quando a publicacao era minha. Agora pede para todas; o servidor ja liberava para seguidores autorizados. |
| Busca so achava quem tem foto | Confirmado e corrigido (ver Limites). |
| Perfil privado nas configuracoes | Engrenagem do Perfil abre Configuracoes: privacidade, avisos no celular, Sair e Excluir conta. |
| Texto quebrado nos comentarios | Causa: o app gravava o corpo da requisicao sem fixar UTF-8. Agora envia bytes UTF-8 com `charset=utf-8` (teste com servidor local). Textos ja gravados quebrados continuam quebrados. |
| Ultimo comentario em destaque na publicacao | `Post.lastComment` na API; cartao dourado na Inicio com "Ver todos os N comentarios". |
| Curtidas | `PUT/DELETE /posts/{id}/like` (`likePost`/`unlikePost`), contagem e `likedByMe` no post. Linha `LIKE#<sub>` em `history`, apontada por `LIKEREF#` com `sharedKeys` (sai na exclusao da conta). |
| Notificacoes (sininho em Inicio, Corridas, Medalhas e Perfil) | `GET /me/notifications` e `POST /me/notifications/read`. Os avisos sao **derivados** do que ja existe (pedidos e novos seguidores, curtidas e comentarios nas minhas publicacoes, publicacoes de quem sigo, ultimos 30 dias, ate 50), entao nao ha fan-out de escrita e nada novo para apagar na exclusao. Lidos = marca `readAt`. Pedido para seguir tem Aceitar/Recusar no proprio aviso; tocar abre perfil ou comentarios. |
| Avisos no celular (iOS e Android) | Ligados por padrao, com chave "Avisos no celular" na tela de avisos e nas configuracoes. **Limite:** sao notificacoes locais disparadas pelo app a cada 45 s enquanto ele esta aberto ou recem-minimizado. Aviso com o app fechado exige push remoto (APNs/FCM + SNS ou similar): precisa de chave Apple/projeto Firebase e custo, **nao contratado** e depende de autorizacao. |
| Medalhas: fundo branco | Tema escuro removido; cartoes claros. |
| Medalhas: numeros | Medalhas, Quilometros corridos, Cidades visitadas, Paises visitados. Km = soma da distancia de cada corrida concluida; cidades = cidades distintas; paises = paises distintos. |
| Paises no cadastro das corridas | Campo opcional `country` na edicao (`ImportEdition`, `AdminEditionInput/Patch`, `Edition`). Ausente = Brasil. **Pendencia:** o catalogo atual so tem UF brasileira (`state` com 2 letras); prova no exterior precisa decisao sobre `state`. |
| Login direto | Quem entra vai direto para o app (botao "Entrar no RunPass"); sem tela com Sair/Excluir. Sair e excluir ficam em Configuracoes. "Sair" so aparece na lista de espera e nas admissoes encerradas. |
| "Beta" vira "periodo de avaliacao" | Textos do app trocados. Rotas e nomes internos (`/beta/...`) continuam, por serem contrato. |

Testes: 161 do backend (3 novos em `test_social.py`) e 59 do app (UTF-8, avisos, configuracoes, foto de perfil, feed com ultimo comentario). Falta teste humano das novidades e o deploy desta rodada (nao executado).
