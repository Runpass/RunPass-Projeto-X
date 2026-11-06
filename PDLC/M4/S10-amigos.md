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
