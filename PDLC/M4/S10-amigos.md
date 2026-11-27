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
| Compartilhar publicacao | Botao Compartilhar do feed abre a folha de compartilhamento do sistema (`share_plus`): WhatsApp, e-mail, Instagram, Facebook e o que a pessoa tiver instalado. Envia texto com corrida, distancia e comentario e, quando ha foto da medalha, a imagem (baixada pelo link assinado de 5 min; sem foto ou sem rede, so o texto). Nao ha link publico da publicacao: quem recebe ve a mensagem e a foto, nao abre o post. Validar no iPhone/Android. |
| Medalhas: numeros | Medalhas, Quilometrocimetro (ex.: 10 KM's), Cidades visitadas, Paises visitados. Km = soma da distancia de cada corrida concluida; cidades = cidades distintas; paises = paises distintos. |
| Paises no cadastro das corridas | Campo opcional `country` na edicao (`ImportEdition`, `AdminEditionInput/Patch`, `Edition`). Ausente = Brasil. **Pendencia:** o catalogo atual so tem UF brasileira (`state` com 2 letras); prova no exterior precisa decisao sobre `state`. |
| Login direto | Quem entra vai direto para o app (botao "Entrar no RunPass"); sem tela com Sair/Excluir. Sair e excluir ficam em Configuracoes. "Sair" so aparece na lista de espera e nas admissoes encerradas. |
| "Beta" vira "periodo de avaliacao" | Textos do app trocados. Rotas e nomes internos (`/beta/...`) continuam, por serem contrato. |

Testes: 161 do backend (3 novos em `test_social.py`) e 59 do app (UTF-8, avisos, configuracoes, foto de perfil, feed com ultimo comentario). Falta teste humano das novidades e o deploy desta rodada (nao executado).

## Rodada 3 (teste no iPhone, 06/11/2026)

| Pedido | Resultado |
| --- | --- |
| Compartilhar nao funcionava como pedido | Cartao do feed foi para `post_card.dart`. O compartilhamento agora **sempre leva uma imagem**: a foto da medalha (link assinado) ou, sem foto/sem rede/demora de 6 s, um cartao PNG desenhado no app (trofeu, corrida, distancia/tempo, RunPass). Instagram e Facebook so aparecem na folha do sistema quando ha imagem; antes, sem foto, ia so texto. Mostra "Preparando..." e, se o anexo falhar, tenta so com texto; se tudo falhar, mostra o tipo do erro. Teste automatizado com a folha do sistema substituida (texto, imagem PNG, fallback). **Causa do relato nao confirmada em aparelho**: provavel ausencia de imagem; precisa de teste no iPhone. |
| Avisos: entrar na postagem | Toque abre a tela **Publicacao** (`GET /posts/{id}`) com cartao completo, curtir, comentar, compartilhar e perfil do autor. |
| Pedidos de amizade em destaque, primeiro, com Aceitar | Pedidos pendentes vem **sempre primeiro**, em cartao destacado com borda e titulo "Pedidos para seguir", **sem expirar** pelos 30 dias e fora do limite de 50. Aceitar/Recusar no proprio aviso. Pedido so existe para perfil **privado**; perfil publico gera aviso "comecou a seguir voce". |
| Tirar "Avisos no celular" da tela de avisos | Fica so em Configuracoes. |
| Apagar aviso arrastando para a esquerda | `Dismissible` + `DELETE /me/notifications/{id}`; ids apagados ficam em `NOTIFSTATE.dismissed` (ultimos 300). Pedido nao desliza (aceite ou recuse). |
| Manter conectado | Caixa "Manter conectado" (marcada) na entrada. Guarda **so o token de renovacao do Cognito** (30 dias) no Keychain/Keystore (`flutter_secure_storage`); nunca a senha. Ao abrir, renova o acesso e entra no Inicio; o acesso de 60 min e renovado sozinho no 401. Sair (GlobalSignOut), excluir conta ou token recusado limpam. Sem mudanca de infraestrutura (`ALLOW_REFRESH_TOKEN_AUTH` ja existia). |
| Foto da postagem abre o perfil | Avatar e nome do autor abrem o perfil publico (com Seguir/solicitar); nos meus posts, o meu perfil. |
| Tirar "Mais uma medalha para o medalheiro!" | Removido dos cartoes. |
| Banner do perfil com imagem da galeria | Botao "Banner" no Perfil: camera/galeria, recorte 16:7, remover. `bannerReference` no perfil (mesmo envio de imagens; troca ajusta referencias) e `GET /profiles/{id}/banner` com a mesma regra de visibilidade da foto. Aparece tambem no perfil publico de quem pode ver. |
| Seguidores e seguindo no formato do Instagram | Linha "corridas / seguidores / seguindo" (numero em cima) no Perfil. **Nao** abre lista de seguidores/seguindo ainda. |
| Medalhas: quilometros | Numero em destaque e "km's corridos" embaixo, como os demais. |
| **Modo escuro** | Chave em Configuracoes, lembrada entre aberturas. Tema escuro vale para todo o app: textos, icones, cartoes, campos, chips, destaques (comentario, pedido, avisos) e logotipo trocam de cor via paleta do tema. Formato escolhido: **chave liga/desliga** com texto explicando o efeito (padrao dos apps); fica de fora "seguir o celular" (automatico). Sem revisao visual em aparelho: telas de detalhe de corrida e rascunho foram ajustadas por busca de cores fixas e precisam de olhar humano. |

Testes: 164 no backend e 72 no app. Falta deploy (nao executado) e teste humano.

## Rodada 4 (06/11/2026)
- **Avisos no iPhone:** `AppDelegate` agora define o delegate de notificacoes (sem isso o iOS nao mostra aviso local com o app aberto); permissao pedida logo apos o login. Aviso com o app fechado continua exigindo push remoto (nao contratado).
- **Comentarios:** curtir (`PUT/DELETE /comments/{id}/like`) e responder (`parentId`, um nivel, ate 20 respostas); respostas embutidas no comentario principal; apagar o principal leva as respostas; avisos `comment_like` e `reply`. Toque na foto ou no nome abre o perfil. Limite: curtidas de um comentario apagado ficam orfas ate o autor da curtida excluir a conta.
- **Perfil:** seguidores e seguindo ao lado da foto (corridas saiu); botao Banner abaixo da area dos icones; aviso de novo seguidor com "Seguir de volta".
- **Biometria:** Face ID, Touch ID e digital como trava de abertura sobre o "manter conectado" (oferta unica apos o primeiro login; chave em Configuracoes). Falha ou cancelamento caem na senha. So a logica e testada automaticamente; o hardware precisa de teste no aparelho.
- **Catalogo:** ver S03 e `docs/catalogo-corridas.md`.

### Avisos no celular: correcao e botoes (06/11/2026, apos teste no iPhone)
- O aviso local **chegou no iPhone** apos a correcao do `AppDelegate` (confirmado pelo usuario).
- Defeito achado por leitura do codigo: conta com historico de avisos vazio na primeira checagem engolia o primeiro aviso real como "ponto de partida". Agora o ponto de partida vazio vale `""` e qualquer aviso futuro aparece. Teste automatizado.
- **Pedido para seguir no proprio aviso do celular:** categoria iOS `follow_request` com **Aceitar** e **Recusar** (acoes que abrem o app) e acoes equivalentes no Android; payload carrega o id de quem pediu. Se o app ainda nao entrou na conta, a decisao espera na fila e e aplicada ao entrar. O aviso so e gerado enquanto o app esta aberto ou recem-minimizado (push remoto continua fora).
- Conferencia no DEV (somente leitura): a conta `theco` (privada) tinha 2 pedidos pendentes, entao a tela de avisos do app deve listar Aceitar/Recusar no topo.
- Configuracoes ganhou o estado da permissao do sistema e dois testes: "Testar agora" (app aberto) e "Testar em 10 s" (agendado no sistema, vale com o app fechado). O app tambem confere avisos ao voltar para o primeiro plano.

### Seguir e amizade separados; feed publico "Todos" (07/11/2026)

Decisao de produto: **Seguir** (`follow`) deixa de pedir aprovacao mesmo para perfil privado — vira unidirecional e sempre imediato, como no Skoob, e nunca mais concede acesso a conteudo privado. Abre-se um segundo vinculo, **Amizade** (`friend`), bidirecional com pedido/aprovacao (padrao Instagram): so amizade aceita abre um perfil privado. As duas relacoes sao independentes (ex.: posso seguir sem ser amigo, ou ser amigo sem seguir).

- **Backend (`social.py`)**: `follow()`/`unfollow()` simplificados (sempre `active`). Novo bloco `add_friend`/`remove_friend`/`friend_requests`/`decide_friend`, espelhando o padrao de `FOLLOWING#`/`FOLLOWER#` numa particao `FRIEND#` por par (pedido mutuo e aceito na hora). `can_view` passa a checar amizade ativa, nao mais seguir. Rotas: `PUT/DELETE /profiles/{id}/friend`, `GET /me/friend-requests`, `PUT/DELETE /me/friend-requests/{id}` (substituem as antigas `/me/follow-requests*`).
- **Feed publico "Todos"**: novo ponteiro global `("history", "FEED#PUBLIC", "T#<completedAt>#<postId>")`, gravado por `ParticipationService.complete()` quando `publishToFeed` e verdadeiro (continua Query por PK fixa, sem Scan, como o restante do modelo). `GET /feed` ganha `scope=all|friends|network` (`all` e o padrao): `all` le esse ponteiro e reconfirma `can_view` na leitura (perfil que virou privado depois de publicar some do feed de quem nao e amigo); `friends` e `network` continuam a iteracao por lista pequena (amigos/seguidos), como antes. Ponteiro erasavel via `FEEDREF#` na particao do dono (mesmo padrao de `sharedKeys` de comentarios/curtidas).
- **Mobile**: tela Início ganha os tres filtros com o escopo batendo na API (`feedScopeFor` em `home_screen.dart`); icone de "Todos" virou um globo (`Icons.public_rounded`). Perfil de outra pessoa (`friends.dart`) ganhou um segundo botao "Adicionar amigo" (template Skoob anexado pelo usuario), independente do botao "Seguir". Tela de pedidos renomeada de `FollowRequestsScreen` para `FriendRequestsScreen`; avisos usam os tipos `friend_request`/`friend` em vez de `follow_request`.
- Testes: 29 casos de `test_social.py` cobrindo os dois vinculos, os tres escopos de feed e a erasao do ponteiro publico; suite mobile (104) e `flutter analyze` sem erros. Implantado no DEV em 07/11/2026 junto com o ajuste de idade minima (ver `S09-integracao-dev.md`, "Deploy da rodada 6"); ainda sem teste humano dos dois vinculos nem do feed "Todos".
- Teste humano achou o feed "Todos" vazio: faltava backfill do ponteiro para posts ja existentes antes do deploy (ver `S09-integracao-dev.md`, "Backfill do ponteiro publico do feed 'Todos'"), corrigido com dados, sem mudanca de codigo.

### Perfil privado passa a restringir so o resumo de corridas, nao mais as publicacoes (08/11/2026)

Teste humano com duas contas achou que seguir @thicost (privado) nao bastava para ver as publicacoes dele — exigia amizade aceita, como desenhado. A pedido do usuario, a regra de privacidade mudou (substitui a decisao original de 07/11/2026 sobre o que perfil privado esconde):

- **Sempre publico, perfil privado ou nao**: publicacoes no feed (qualquer escopo), curtir, comentar, ver comentarios, fotos de post (medalha), avatar e banner, contagem de seguidores e de seguindo.
- **Continua restrito a amigo aceito (ou o proprio dono)**: contagem de participacoes e a lista de corridas concluidas na tela de perfil — unico resquicio do que "privado" significa agora.
- **Backend (`social.py`)**: nova funcao `_author_active` (so confere conta ativa) substitui `can_view` em `_authorized_post`, `may_view_photo`, `may_view_profile_photo`, `_authors_feed` e `_public_feed`. `can_view` continua existindo, mas so e usado em `profile_view` (campo `canView`, que agora governa so `participationCount`) e `public_participations`. `followersCount`/`followingCount` em `profile_view` saem de dentro do `if canView` e passam a ser calculados sempre.
- **Mobile (`friends.dart`)**: banner deixa de depender de `canView`; a linha de contagens mostra Seguidores/Seguindo sempre e "Corridas" so quando `canView`; o cartao de bloqueio muda de "Este perfil e privado" para "Resumo de corridas privado". Texto da chave "Perfil privado" em Configuracoes atualizado (nao fala mais em "corridas, medalhas e comentarios" ficarem ocultos).
- Testes: 6 casos de `test_social.py` reescritos para a nova regra (post/comentario/curtida/avatar/banner acessiveis sem amizade; resumo de corridas continua bloqueado) — suite completa segue em 29 casos, sem regressao; mobile 104/104. Implantado no DEV em 08/11/2026 (ver `S09-integracao-dev.md`, "Deploy da rodada 7"); ainda sem `.apk` nem teste humano desta rodada.
