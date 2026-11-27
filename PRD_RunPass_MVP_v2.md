# PRD — RunPass MVP — Versão 2

**Data:** 20/10/2026  
**Estado do conteúdo de produto:** APROVADO pelo usuário nesta conversa, após revisão final.  
**Estado dos gates do PDLC:** sem evidência de conclusão formal de M0–M3; esta aprovação de conteúdo não equivale à liberação desses gates.  
**Fontes:** PRD_RunPass_MVP.md e decisões da entrevista grill-me, incluindo a rodada final de 20 perguntas.  
**Governança:** decisões confirmadas na entrevista não equivalem à aprovação formal dos gates da SKILL-PDLC. Não há evidência registrada de aprovação de M0–M3. Este documento não autoriza avançar esses gates.

**Registro da aprovação:** o usuário respondeu “Aprovado” à solicitação de aprovação do conteúdo consolidado do PRD v2, após confirmação das regras de perfil, foto obrigatória da medalha quando ausente no catálogo e arquivamento das edições com participações. Escopo: conteúdo de produto desta revisão; não inclui aprovação técnica ou liberação de produção.

## 1. Visão do produto

RunPass é uma rede social para corredores de rua registrarem provas concluídas, colecionarem medalhas, avaliarem experiências e descobrirem onde correr, trocando informações com outros corredores.

- Categoria: SportTech / rede social / corrida de rua.
- Plataformas do MVP: Android e iOS (iPhone).
- Mercado inicial: Brasil, com catálogo inicial concentrado em São Paulo capital.
- Site para usuários fora do MVP; implantação futura após comprovar o valor do produto.
- Primeiras interações principalmente entre corredores que já se conhecem.

**Proposta de valor:** um histórico social das provas e medalhas do corredor, conectado às experiências dos amigos e de participantes das mesmas edições.

O foco é a experiência em provas de rua. Tracking GPS, treinamento e venda de inscrições ficam fora desta entrega.

## 2. Problema e hipóteses

O PRD inicial descreve uma jornada fragmentada entre descoberta de eventos, inscrições, aplicativos esportivos, redes sociais e medalhas físicas. A relevância desse problema para o público deverá ser validada pelo beta; a ausência de alternativas no mercado não é uma conclusão comprovada por este documento.

Hipóteses a testar:

1. Corredores mantêm e ampliam um histórico digital de provas concluídas.
2. O medalheiro incentiva o registro das experiências.
3. Oito critérios obrigatórios de avaliação são aceitáveis durante o registro.
4. Avaliações ajudam a descobrir e escolher provas.
5. Conquistas compartilhadas geram interação entre corredores e interesse no produto.

A obrigatoriedade da avaliação significa que a quantidade de reviews, isoladamente, não comprova disposição espontânea para avaliar. É necessário observar abandono e feedback sobre esse passo.

## 3. Objetivo e público do MVP

Validar o interesse em manter um histórico social de experiências em provas e interagir com outros corredores.

O usuário deverá conseguir criar conta e perfil, encontrar uma edição, declarar sua conclusão, registrar resultado opcional, avaliar a experiência, receber a medalha digital, consultar seu histórico, salvar provas futuras e compartilhar conquistas. Também poderá seguir corredores, curtir e comentar publicações.

Persona de referência do PRD inicial: corredor recreativo de 25 a 45 anos, com 4 a 12 provas por ano, principalmente de 5 km, 10 km e 21 km, que valoriza conquistas e pesquisa eventos. Essas características orientam recrutamento e descoberta; não são restrições de elegibilidade.

O beta será gratuito e destinado a maiores de 13 anos (revisão explícita de 07/11/2026, alinhada à prática do Instagram), com instalação pelas lojas oficiais e admissão dos primeiros 1.000 usuários elegíveis. Após atingir o teto, oferecer lista de espera dentro do aplicativo, sem acesso automático ao beta. Essa revisão substitui o acesso por convite. A forma de verificar a elegibilidade será especificada antes da abertura.

## 4. Conceitos e regras centrais

| Conceito | Definição |
| --- | --- |
| Prova/corrida | Evento esportivo identificado no catálogo. |
| Edição | Ocorrência específica de uma prova, com data e local; pode haver várias no mesmo ano. Não usar apenas o ano como identidade. |
| Participação | Declaração de conclusão do corredor, limitada a uma por usuário e edição. |
| Rascunho | Participação ainda não concluída, inclusive enquanto a prova aguarda revisão. Independe do estado da publicação no feed. |
| Medalha do usuário | Item do medalheiro vinculado à participação; imagem oficial ou foto enviada pelo corredor. |
| Avaliação | Oito notas obrigatórias e um comentário opcional, vinculados à participação. |
| RunScore | Média das avaliações de uma edição. |
| Conquista/publicação | Conteúdo social associado a uma participação concluída, publicado por escolha do usuário. |
| Quero correr | Edição futura salva na wishlist; não equivale à inscrição oficial. |

## 5. Jornadas principais

### 5.1 Registrar uma edição existente

1. Criar conta e completar o perfil.
2. Buscar e selecionar a edição.
3. Declarar que concluiu a prova e indicar a distância.
4. Informar resultado opcional e ajustar a visibilidade.
5. Preencher os oito critérios obrigatórios, com comentário opcional.
6. Usar a imagem da medalha do catálogo; se ela estiver ausente, enviar obrigatoriamente uma foto para concluir o cadastro da corrida realizada.
7. Concluir o registro: participação, avaliação e medalha ficam vinculadas.
8. Revisar a publicação, visível por padrão, podendo ocultá-la; compartilhar externamente é opcional.

Não publicar no feed não torna a participação privada: prova e medalha continuam no perfil público, respeitadas as opções de ocultação dos resultados.

### 5.2 Registrar uma prova ausente

1. Preencher a solicitação da prova e salvar a participação em rascunho.
2. A equipe revisa e aprova, identifica duplicidade ou recusa com motivo.
3. O usuário recebe aviso dentro do aplicativo.
4. Após aprovação ou vinculação a uma edição existente, revisa e conclui o rascunho, incluindo a avaliação obrigatória.
5. Se recusada, pode corrigir e reenviar sem perder os dados da participação.

### 5.3 Descobrir e interagir

Buscar corridas, consultar avaliações, salvar uma edição em “Quero correr”, encontrar conhecidos, seguir perfis e interagir nas conquistas por curtidas e comentários.

## 6. Conta, perfil e busca de corredores

Requisitos herdados do PRD inicial: cadastro por e-mail e senha, validação e confirmação de e-mail, recuperação de senha e logout. Login Google e Apple permanecem como evolução sujeita à validação dos requisitos de distribuição.

- Perfis públicos com informações voltadas às corridas e conquistas.
- Nome de exibição, username, histórico, medalhas, avaliações e contagens de provas/medalhas compõem a proposta de perfil.
- Nome de exibição e username são obrigatórios. Foto do perfil, cidade e bio são opcionais. E-mail permanece privado. A foto opcional do perfil não se confunde com a imagem obrigatória da medalha na conclusão da participação.
- E-mail e demais dados privados de cadastro não serão exibidos publicamente.
- Busca de corredores por nome ou username e compartilhamento do link do perfil.
- Seguir corredores está no MVP. Fluxo sem aprovação de seguidores é uma premissa de especificação, coerente com perfis públicos, ainda não detalhada na entrevista.
- Importação de contatos do celular fora do MVP.

## 7. Catálogo e descoberta de corridas

### 7.1 Cobertura e manutenção

- Equipe RunPass responsável pelo cadastro e atualização no MVP.
- Prioridade: principais corridas de São Paulo capital.
- Dois anos de histórico inicial, além das edições futuras disponibilizadas para descoberta.
- Provas mais antigas podem ser solicitadas pelos usuários; a janela inicial não impede sua inclusão após revisão.
- Não há exigência de 500 provas para lançar.
- Gate de catálogo para o beta: cobrir ao menos 90% das edições distintas citadas por um grupo inicial de convidados, dentro do recorte da capital e dos dois anos de histórico.
- Montar a lista de referência com os primeiros convidados, no pré-lançamento. Congelar e registrar a lista e o período antes da avaliação. Cobertura = edições da lista disponíveis no catálogo / total de edições distintas da lista. Registrar os participantes consultados; não há tamanho mínimo de amostra aprovado.
- Integrações automáticas com IA ficam para o futuro.

### 7.2 Dados, busca e página da edição

O catálogo mantém nome, organizador, identificação da edição, data, cidade/estado, distâncias, imagem, descrição, links oficial e de inscrição e status. Disponibilidade e obrigatoriedade dos campos administrativos serão detalhadas, especialmente para provas antigas.

Filtros iniciais: nome, cidade, data e distância. Na revisão técnica, o usuário aprovou busca pelo início do título, combinada com cidade, período e distância, com a restrição informada na interface. Busca aproximada e por qualquer trecho ficam para evolução, assim como filtros por preço, avaliação, percurso e organizador.

A página apresenta dados da edição, distâncias, RunScore geral, quantidade de avaliações, avaliações recentes e quantidade de participantes RunPass. Permite filtrar as avaliações por distância.

CTAs: **“Eu participei”** e **“Quero correr”**.

### 7.3 Solicitações e revisão

- Obrigatórios para solicitar: nome, data, cidade e distância.
- Opcionais: link oficial e imagem.
- Nenhuma prova cadastrada por usuário entra no catálogo público sem revisão humana da equipe.
- A participação vinculada permanece rascunho até a aprovação e a conclusão pelo usuário.
- Duplicidade: equipe vincula à edição correta, preserva os dados e avisa o usuário; ele revisa antes de concluir.
- Recusa: motivo consultável, correção e reenvio permitidos, com rascunho preservado.
- Estados de acompanhamento: pendente, aprovada/vinculada ou recusada, com motivo quando aplicável. Nomenclatura final será definida no desenho da interface.

## 8. Participação, edição e exclusão

- Somente provas concluídas; participação sem conclusão não integra o MVP.
- Conclusão autodeclarada, sem resultado oficial ou certificado obrigatório.
- Uma participação por corredor em cada edição, mesmo que haja várias distâncias ou dias.
- Distância vinculada à edição; tempo opcional, colocação e número do peito opcionais conforme o PRD inicial.
- Pace aplicável quando houver distância e tempo suficientes; forma de cálculo e precisão serão especificadas.
- Usuário pode editar completamente seus registros, incluindo resultado, avaliação e edição da prova, ou excluí-los.
- Troca de edição deve respeitar a unicidade e atualizar os dados derivados das edições de origem e destino. Se já houver participação na edição de destino, impedir a duplicidade e orientar a editar o cadastro existente ou excluí-lo antes de uma nova adição. Não mesclar nem sobrescrever registros automaticamente.
- Excluir participação remove avaliação e medalha associadas, bem como o post e suas interações, se houver, e recalcula o RunScore.
- A participação tem estado rascunho ou concluída; a publicação vinculada tem estado publicada ou não publicada. Uma participação concluída pode não ter publicação no feed.
- A avaliação dos oito critérios é obrigatória na conclusão inicial. Invalidação posterior pela moderação constitui exceção: participação, medalha e publicação são preservadas conforme a seção 14.

## 9. Avaliação obrigatória e RunScore

Para concluir uma participação, preencher todos os critérios com notas de 1 a 5 estrelas:

1. Organização.
2. Percurso.
3. Kit.
4. Medalha.
5. Hidratação.
6. Estrutura.
7. Segurança.
8. Custo-benefício.

Caixa de texto de comentário opcional. Na substituição completa da avaliação por PUT, omitir o comentário remove o texto anterior da avaliação atual. O usuário condicionou essa regra à preservação do histórico de eventos de alteração em camada informacional no data lake. Retenção, conteúdo histórico, acesso e tratamento de exclusões ainda serão definidos; não expor versões antigas pela API pública. Não há opção “não se aplica” aprovada; qualquer exceção deverá ser tratada explicitamente antes da implementação.

- Uma avaliação por participação, editável após publicação.
- Avaliações vinculadas à edição, sem mistura de anos ou ocorrências distintas.
- RunScore geral da edição, com filtro da lista de avaliações pela distância. Não foi aprovado um score independente por distância.
- Nota individual = soma das oito notas / 8.
- RunScore = soma das notas individuais / quantidade de avaliações válidas da edição.
- Todos os critérios e corredores têm o mesmo peso.
- Exibição com uma casa decimal; arredondar para apresentação, evitando perda acumulada de precisão no cálculo.
- Exibir também quantidade de avaliações. Sem avaliações, apresentar ausência de nota, em vez de executar uma divisão por zero — convenção proposta para especificação.
- Edição substitui as notas anteriores; exclusão e mudanças de edição exigem recálculo consistente. Remoções por moderação devem ser tratadas no cálculo conforme a política de conteúdo.

## 10. Medalheiro

- Administrador pode substituir a imagem oficial da medalha no catálogo da edição/distância, sem modificar fotos próprias carregadas pelos corredores. Manter origens distintas. Atualização automática ou preservação da versão nas medalhas já vinculadas à imagem oficial ainda será definida.
- Definição posterior aprovada: medalhas existentes preservam a versão da imagem oficial vinculada no cadastro. Novos registros usam a referência vigente. Correções retroativas exigem ação administrativa explícita e auditada; troca no catálogo não atualiza automaticamente medalhas antigas.

- Medalha adicionada automaticamente ao concluir o registro da participação.
- Utilizar a imagem do catálogo quando disponível.
- Se a imagem estiver ausente no catálogo, exigir upload da foto da medalha pelo corredor para concluir a participação. Até incluir a foto, manter o cadastro como rascunho.
- A foto fica vinculada somente à medalha desse usuário e não altera o catálogo nem é reutilizada automaticamente por outros corredores.
- Essa vinculação individual não significa sigilo da foto: ela pode aparecer no perfil e no post da conquista, conforme a publicação escolhida.
- Informações: imagem, prova, edição/ano, cidade, distância e resultado quando informado e visível.
- Não concluir o cadastro da corrida sem uma imagem da medalha: utilizar a do catálogo ou a foto obrigatória enviada pelo corredor. Imagem neutra não substitui esse requisito.

## 11. Wishlist

Salvar e remover edições futuras por “Quero correr”, exibindo prova, cidade, data e distância. A wishlist também seleciona as edições relevantes para o feed. Será pública por padrão, com opção de o usuário ocultá-la.

## 12. Feed, seguidores e interações

- Comentários sociais podem ser editados pelo próprio autor, exibindo indicação de “editado” e preservando a data original de publicação. Edição não remove bloqueios/moderação nem restaura conteúdo oculto automaticamente. Não estender o histórico de avaliações no data lake a comentários sociais sem definição explícita.

- Feed no MVP, voltado à conclusão de corridas e imagens de medalhas.
- Publicação visível por padrão, com opção de ocultar durante o registro ou após a publicação. Ocultar o post não exclui a participação. Não gerar posts independentes de medalha ou marcos automaticamente.
- O usuário poderá visualizar publicações de outros usuários, sem depender de seguir alguém ou ter edições em comum, desde que o autor tenha perfil público. O feed inicial pode apresentar conquistas recentes de corridas de São Paulo capital.
- Decisão de produto de 07/11/2026: dois vínculos sociais distintos. Seguir (`follow`) é unidirecional e sempre imediato (mesmo para perfil privado); alimenta o filtro "Seguindo". Amizade (`friend`) é bidirecional, com pedido e aprovação explícita; alimenta o filtro "Amigos".
- Decisão de produto de 08/11/2026: a tela Início oferece quatro recortes do feed, recência dentro de cada um: "Todos" (padrão; qualquer autor com conta ativa, inclui as minhas publicações), "Amigos" (ex-"Amigos", agora corrigido: nunca mostra as minhas; sem nenhum amigo aceito, convida a buscar pessoas em vez do aviso genérico), "Seguindo" (ex-"Minha rede", renomeado; nunca mostra as minhas; mesmo convite quando vazio) e "Minha Cidade" (ex-"São Paulo"; recorta "Todos" pela cidade/estado do perfil do usuário, pedindo esse cadastro uma única vez se faltar). Estado e cidade vêm de lista fechada do IBGE, por rolagem, sem digitação; coletados num passo dedicado no cadastro de novos usuários e editáveis a qualquer momento em "Editar perfil".
- Decisão de produto de 08/11/2026: "Minha Cidade" prioriza publicações da mesma cidade; sem nenhuma, passa a considerar cidades vizinhas num raio de 50 km (centroide a centroide, dataset público derivado do IBGE). Perfil passa a guardar também a latitude/longitude da cidade escolhida, só para esse cálculo.
- Decisão de produto de 08/11/2026 (substitui a de 07/11/2026 sobre o que fica restrito): publicações, curtidas, comentários, fotos de post, avatar, banner e as contagens de seguidores/seguindo são **sempre públicos**, perfil privado ou não, nos três recortes do feed. Perfil privado restringe só o **resumo consolidado de corridas** (contagem de participações e a lista de corridas concluídas) na tela de perfil, liberado apenas para quem é amigo aceito (ou o próprio dono) — seguir sozinho não libera esse resumo.
- Edições concluídas ou salvas podem orientar relevância, mas não limitam todo o conteúdo disponível.
- Curtidas e comentários nas publicações.
- Editar participação atualiza o post existente sem duplicação, preservando curtidas e comentários.
- Excluir participação remove o post e suas interações.
- Ordenação, paginação e regra exata de prioridade pendentes de especificação.
- Publicações livres de fotos, stories, vídeos, reels, mensagens privadas e grupos ficam fora do escopo.

## 13. Visibilidade e compartilhamento

- Cards serão gerados no próprio aplicativo, com marca RunPass e respeito às opções atuais de ocultação. Não haverá serviço adicional de geração/armazenamento de cards no backend no MVP. Compartilhamento nativo conforme suporte do dispositivo; cópias já exportadas não podem ser revogadas retroativamente.

- Usuário pode ocultar tempo e colocação por participação.
- Ocultar tempo oculta também o pace, pois ele e a distância permitem inferir o tempo.
- Aplicar a mesma escolha ao perfil, medalheiro, feed e cards gerados para compartilhamento.
- Publicações e resultados informados começam visíveis, com opção de ocultação durante ou após a publicação. Tempo e colocação continuam controlados por participação; ocultar tempo também oculta pace. Essa regra não torna públicos e-mail e outros dados privados de cadastro.
- Cards com marca RunPass via compartilhamento nativo, incluindo Instagram e WhatsApp quando suportados pelo dispositivo.
- Compartilhar links de perfis e conquistas: abrir no app; sem instalação, encaminhar à loja correspondente.
- Não criar site de conteúdo público para o MVP. Configuração de links e eventual infraestrutura mínima de redirecionamento devem ser validadas tecnicamente, sem reintroduzir um produto web completo.
- Alterações de visibilidade protegem os dados exibidos pelo RunPass e novos cards; não podem revogar cópias de imagens já exportadas para terceiros.

## 14. Avisos, moderação e bloqueio

### Avisos no aplicativo

Informar aprovação/recusa e vinculação de solicitações, novos seguidores, curtidas e comentários. Push fica fora do MVP.

### Moderação

- Encerrar denúncias com decisão e motivo obrigatórios, mantendo o registro restrito à operação: procedente, improcedente ou sem elementos suficientes. A decisão não publica a identidade do denunciante e não substitui a execução explícita de eventual ação de moderação.

- Bloquear outro corredor remove as relações de seguir nos dois sentidos. Curtidas e comentários anteriores são preservados e ocultos entre os envolvidos. Desbloquear não recria esses vínculos de seguir; cada pessoa pode decidir seguir novamente, desde que não haja outro bloqueio ou restrição vigente.

- Ao desbloquear outro corredor, interações anteriores preservadas poderão voltar a ser exibidas se ainda autorizadas. Não recriar relações de seguir removidas nem restaurar conteúdo excluído, oculto ou moderado. Bloqueios ainda existentes na direção oposta continuam restringindo o acesso.

- Denunciar usuários, avaliações, comentários e conteúdo impróprio.
- Equipe RunPass analisa denúncias com revisão humana.
- Remover conteúdo ou suspender contas, registrando o motivo da ação.
- Ocultar apenas o comentário mantém as oito notas válidas e não altera o RunScore.
- Invalidar as notas retira a avaliação do RunScore e da exibição pública, preservando participação, medalha e publicação existentes. Registrar a justificativa e avisar o corredor.
- O corredor pode enviar uma avaliação corrigida, sujeita à revisão humana antes de retornar ao cálculo e à exibição pública. Essa situação é uma exceção explícita à exigência de avaliação válida em uma participação já concluída; não permite dispensar as oito notas no cadastro inicial.
- Bloquear corredor impede seguir, curtir e comentar e oculta conteúdo entre ambos dentro do aplicativo.
- Bloqueio não equivale a controle sobre capturas ou conteúdo já compartilhado externamente.
- Interações anteriores ao bloqueio são apenas ocultadas entre os envolvidos, sem exclusão dos registros. Recursos de moderação, prazos e retenção permanecem detalhes operacionais a definir.

## 15. Operação administrativa

Organizadores serão apenas cadastros de referência gerenciados pela equipe RunPass, sem conta de acesso ou portal próprio no MVP. Edições podem ser vinculadas a esses cadastros; preservar referências ao corrigir informações. Não introduzir login de organizador, painel B2B ou permissões adicionais a partir desse cadastro.

Histórico informacional das avaliações: preservar versões anteriores e novas das notas e do comentário necessárias à auditoria em data lake, com acesso restrito e política explícita de retenção/exclusão. Não expor versões antigas nas interfaces públicas. Prazo e papéis autorizados ainda a definir; não presumir retenção indefinida.

Prazo aprovado para esse histórico no beta: 60 dias, com revisão antes do encerramento da fase. Essa retenção não substitui a política de exclusão de dados pessoais, não altera os registros ativos e é distinta dos 7 dias de pontos de recuperação. Papéis autorizados e detalhes de descarte ainda a definir.

Consulta do histórico restrita a Administradores especificamente autorizados da equipe RunPass, sem acesso para corredores ou Moderadores por padrão. Exigir MFA e auditar consultas; operações técnicas de gravação/descarte devem ter permissões próprias.

Histórico armazenado em S3 privado e isolado por DEV/PROD, com entrega assíncrona. Preservar evento durável junto à alteração operacional para reenvio após falhas; não perder o histórico por indisponibilidade temporária do lake.

Os 60 dias de retenção do histórico contam desde a ocorrência original de cada evento; reenvios e reprocessamentos não renovam o prazo.

Manter as capacidades administrativas do PRD inicial: cadastrar, editar e remover provas, manter organizadores, imagens e medalhas, consultar avaliações e moderar conteúdo. Acrescentar fila de solicitações, identificação de duplicidades, vinculação de rascunhos e avisos dos resultados da revisão.

O MVP incluirá um painel administrativo interno mínimo, restrito à equipe RunPass, para executar essas operações. Esse painel não constitui um site para corredores; o site público continua fora do MVP.

Edições com participações deverão ser arquivadas em vez de excluídas em cascata. O arquivamento impede novos registros de participação, conclusão de rascunhos e transferência de participação para a edição arquivada, mantendo consulta ao histórico e edição ou exclusão dos registros existentes. Ao bloquear, preservar os dados do rascunho ou da participação de origem e informar o motivo. Preservar referências, avaliações e medalhas enquanto seus registros não forem excluídos pelo fluxo aplicável. Não arquivar automaticamente uma edição apenas por ser passada.

## 16. Requisitos não funcionais e privacidade

Metas herdadas do PRD inicial, ainda sujeitas à validação técnica:

- Tela inicial em menos de 3 segundos em conexão adequada.
- Média inferior a 500 ms para APIs críticas.
- Disponibilidade inicial de 99,5%.
- Definir dispositivo, rede, carga, endpoints e janela de medição na especificação para tornar as metas verificáveis.

Requisitos do original: autenticação por token, HTTPS, senhas sem armazenamento em texto puro, autorização por usuário, acesso administrativo restrito e logs de operações sensíveis. Aplicar autorização também às operações de edição, exclusão e consulta de dados ocultos.

Termos de Uso e Política de Privacidade, edição de dados pessoais, solicitação de exclusão da conta e exclusão de dados deverão ser contemplados. Localização precisa não é necessária no MVP. A implementação e os textos precisam de revisão especializada; este PRD não certifica conformidade legal. Retenção, descarte, tratamento de conteúdo de terceiros e verificação etária permanecem pendências de especificação.

## 17. Direção técnica inicial

O PRD original propõe Flutter e AWS, com Cognito, API Gateway, Lambda, S3, CloudFront e CloudWatch, além de DynamoDB e PostgreSQL como componentes listados.

Esses itens são referências técnicas preliminares, não escolhas revalidadas pelo grill-me. A especificação deve justificar o armazenamento escolhido; não assumir necessidade de dois bancos. Também deverá validar links para as lojas, uploads, consistência dos registros e cálculo de agregados. Não há implementação ou arquitetura aprovada por este documento.

## 18. Analytics e métricas

### Métrica principal

**Participações completas registradas por mês**, excluindo rascunhos. Participação completa inclui conclusão declarada, avaliação dos oito critérios e medalha vinculada com imagem do catálogo ou foto enviada pelo corredor. Registrar a coorte temporal usada na análise para lidar com edições e exclusões posteriores.

### Eventos

Manter os eventos do original aplicáveis: `user_registered`, `login_completed`, `race_viewed`, `race_searched`, `participation_created`, `review_created`, `medal_added`, `wishlist_added`, `post_liked`, `post_commented`, `share_clicked`.

Acrescentar instrumentação para rascunho e conclusão, atualização/exclusão, solicitação e resultado de revisão, publicação opcional, seguir corredor e visualização das avaliações. Nomes finais serão definidos na especificação. Não implementar `achievement_unlocked`, pois marcos extras estão fora do MVP.

Evitar duplicar ativação ou repetição por edições do mesmo registro. Likes e comentários próprios não contam para a meta social. Não enviar comentários, credenciais ou resultados ocultos como propriedades desnecessárias de analytics.

Métricas secundárias: aquisição, ativação, abandono da avaliação, registros por usuário, uso do medalheiro e wishlist, consulta de reviews, compartilhamento, D7/D30 e usuários ativos mensais. São diagnósticas quando não houver limiar aprovado.

## 19. Beta e critérios de sucesso

- Elegibilidade etária confirmada na revisão técnica: 13 anos completos ou mais durante o beta (redefinido em 07/11/2026, revisão explícita, alinhado à prática do Instagram), por autodeclaração com preenchimento da data de nascimento. Validar idade no cadastro e manter a data privada, sem exposição no perfil público. Não foi definida exigência de documento.

- Beta gratuito para os primeiros usuários elegíveis maiores de 13 anos que se cadastrarem pelo aplicativo instalado nas lojas oficiais, sem convite. Meta de recrutamento e limite máximo: 1.000 usuários durante todo o período. Ao atingir o teto, oferecer lista de espera dentro do app; seus integrantes não contam como admitidos nem recebem acesso automático. Exclusões não liberam novas vagas automaticamente.
- Avaliação por 60 dias a partir da entrada dos primeiros 50 usuários; registrar esse marco como início da janela. A data final não será adiada até completar 1.000.
- O foco do beta será medir adesão ao aplicativo, interações, disponibilidade durante o uso e feedbacks dos usuários.
- Registrar data de entrada e tempo de exposição de cada participante, separando recrutamento de uso. O denominador da ativação será o total de usuários únicos efetivamente admitidos no beta até o encerramento dos 60 dias, incluindo os primeiros 50 que iniciam a janela, e não a meta fixa de 1.000. Convites sem adesão não contam como usuários admitidos. Apresentar recrutamento separadamente.
- Para a visão de adesão do beta, usuário ativo significa ter cadastrado completamente pelo menos uma competição concluída; corresponde ao usuário ativado. Inativo nessa visão significa não ter realizado esse cadastro. Essa classificação não exige acessos frequentes e não deve ser confundida com atividade diária/mensal ou retenção recorrente.
- Acompanhar disponibilidade ao longo da janela, falhas e incidentes que interrompam as jornadas. A meta técnica herdada de 99,5% permanece referência sujeita à especificação da medição.
- Plano de feedback aprovado: após o primeiro registro completo, perguntar “Foi fácil registrar sua corrida?”, de 1 a 5, com comentário opcional; manter botão “Enviar feedback” durante todo o beta, com categorias problema, sugestão e elogio; aos 30 dias, aplicar pesquisa curta sobre utilidade e dificuldades; ao final dos 60 dias, perguntar intenção de continuar usando, funcionalidade mais valiosa e principal melhoria; para quem não tiver registro completo após 7 dias da entrada, perguntar opcionalmente o que impediu concluir.
- Consolidar feedbacks semanalmente, priorizando falhas que impedem o uso. Questionários são opcionais. Usar avisos no aplicativo, sem introduzir push no MVP. Não há limiar de satisfação aprovado.
- Antes da liberação, catálogo com cobertura mínima de 90% da lista coletada com o grupo inicial, no recorte aprovado.

| Indicador | Definição | Meta |
| --- | --- | --- |
| Ativação | Usuários com pelo menos uma participação completa / usuários únicos efetivamente admitidos até o encerramento do beta | Pelo menos 50% (500 se houver 1.000 admitidos; 300 se houver 600) |
| Repetição | Ativados que registram uma segunda prova, em outra edição / total de ativados | Pelo menos 30% |
| Interação social | Ativados com pelo menos uma curtida ou comentário em conquista de outro corredor / total de ativados | Pelo menos 30% |

Contar usuários únicos dentro da janela do beta. Com exatamente 500 ativados, repetição e interação social exigem ao menos 150 usuários cada, podendo ser os mesmos. Se houver mais ativados, o denominador aumenta.

Essas metas substituem os limiares antigos de 100 usuários, 300 participações, 200 reviews, 100 medalhas e avaliação por apenas 30% dos participantes. Perfil completo, compartilhamento e interesse de organizadores podem ser acompanhados, mas não são gates adicionais aprovados nesta rodada.

O cumprimento das metas apoia a avaliação humana do valor do MVP; não representa aprovação automática de publicação, expansão ou gates do PDLC. Como registros históricos são aceitos, registrar uma segunda prova não implica necessariamente concluir uma nova corrida durante o beta.

## 20. Escopo e prioridades

### P0 — MVP

- Conta, autenticação, admissão dos primeiros 1.000 usuários elegíveis maiores de 13 anos e lista de espera no aplicativo após atingir o teto.
- Perfil público, busca de corredores e seguir perfis.
- Catálogo, busca, detalhes por edição e wishlist.
- Solicitação de prova, revisão humana, rascunhos e comunicação do resultado.
- Participação concluída autodeclarada, avaliação obrigatória, RunScore e medalheiro.
- Edição/exclusão dos próprios registros e visibilidade de resultados.
- Feed de conclusões e medalhas, publicação opcional, curtidas e comentários.
- Cards, links compartilháveis e avisos dentro do aplicativo.
- Denúncias, bloqueio e operação administrativa necessária.
- Privacidade, exclusão de conta e dados, segurança e analytics do beta.

### Fora do MVP

Site para usuários, notificações push, importação de contatos, conquistas extras por marcos, rankings, clubes, grupos, assessorias, monetização, premium, afiliados, anúncios, analytics B2B, marketplace, pagamentos e venda de inscrições.

Também ficam fora: tracking GPS, treino, streaming, chat privado, stories, reels, vídeos, feed de fotos livres, integrações Garmin/Strava/Apple Health/Health Connect, automação de catálogo por IA e turismo esportivo.

Não há ordem pós-MVP aprovada. Site, integrações, recursos sociais adicionais e monetização serão reavaliados após evidências de valor.

## 21. Critérios funcionais para revisão e aceite

1. Uma participação não pode ser concluída sem declarar conclusão e preencher as oito notas; comentário e tempo permanecem opcionais.
2. A mesma conta não consegue criar uma segunda participação na mesma edição.
3. Rascunho de prova pendente não aparece como conquista publicada nem entra no RunScore.
4. Prova de usuário só entra no catálogo após revisão; aprovação, duplicidade e recusa preservam o rascunho e produzem aviso apropriado.
5. Medalha é vinculada ao concluir; sem imagem no catálogo, exigir foto enviada pelo corredor. Sem ambas, o registro permanece rascunho. Foto alternativa não altera o catálogo de terceiros.
6. Avaliação editada substitui as notas anteriores; edições distintas não compartilham o RunScore.
7. Omitir publicação mantém participação e medalha no perfil, mas não cria post no feed.
8. Atualizar participação não duplica post e preserva interações; excluí-la remove vínculos e atualiza agregados.
9. Ocultar tempo também oculta pace em todas as superfícies controladas pelo produto; colocação segue a escolha por participação.
10. Feed permite publicações de qualquer corredor, perfil privado ou não (filtro "Todos", sem restringir às edições em comum) e oferece "Amigos"/"Minha rede" como recortes por amizade/seguir; perfil privado só restringe o resumo de corridas na tela de perfil; respeita ocultações, bloqueios e moderação.
11. Links abrem no app ou direcionam à loja, conforme validação técnica do mecanismo.
12. Analytics permite calcular as três metas do beta sem contar rascunhos ou duplicar usuários.
13. Avaliação invalidada pela moderação sai da exibição pública e do RunScore sem excluir participação, medalha ou publicação; só retorna após revisão da correção.
14. O beta não admite mais de 1.000 usuários no período, e o encerramento ocorre 60 dias após o marco dos primeiros 50.

Esses critérios traduzem decisões de produto; não substituem cenários detalhados e revisão técnica.

## 22. Pendências explícitas e próxima etapa

Sem nova rodada automática de entrevistas: o limite de 20 perguntas foi concluído. As pendências devem ser trabalhadas na revisão/especificação e as escolhas não confirmadas identificadas como propostas:

- Evidência dos gates formais do PDLC; a aprovação humana do conteúdo deste PRD já foi registrada.
- Executar a coleta da lista de referência com os primeiros convidados e registrar período exato do histórico e tratamento de edições futuras.
- Detalhamento do painel administrativo interno mínimo, já incluído no MVP; site público permanece fora.
- Detalhar os campos públicos aprovados: nome de exibição e username obrigatórios; foto do perfil, cidade e bio opcionais; e-mail privado.
- Especificar upload obrigatório de foto da medalha quando não houver imagem no catálogo, respeitando a vinculação apenas ao usuário.
- Ordenação do feed, limites de conteúdo e critérios de busca.
- Detalhar os fluxos de unicidade, moderação e exclusão conforme as regras aprovadas, sem alterar seus efeitos.
- Prazos de revisão, políticas de retenção e detalhamento da ocultação das interações antigas após bloqueio, sem excluí-las.
- Método de elegibilidade etária, publicação nas lojas oficiais, detalhes da lista de espera e configuração dos links nas duas plataformas.
- Validação das metas técnicas, arquitetura e critérios de medição.

## 23. Principais mudanças da versão 1

- Feed, seguir corredores, curtidas, comentários e avisos internos promovidos ao MVP.
- Site, push, marcos extras e rankings explicitamente fora da entrega.
- Uma participação por edição, autodeclaração de conclusão e resultado opcional.
- Oito critérios obrigatórios, comentário opcional e RunScore calculado por edição.
- Medalha automática e foto alternativa restrita ao registro do usuário.
- Revisão de provas cadastradas por usuários, rascunhos, reenvio e tratamento de duplicidade.
- Perfis públicos com controles de resultado por participação e bloqueio de corredores.
- Cobertura do catálogo orientada pelas provas dos convidados, substituindo o mínimo de 500.
- Beta gratuito com admissão dos primeiros 1.000 usuários elegíveis adultos pelas lojas oficiais e lista de espera no aplicativo, durante 60 dias, com metas de ativação, repetição e interação social.

## 24. Visão de longo prazo

Ser uma plataforma de identidade e experiência de corredores de rua no Brasil, respondendo onde o usuário correu, quais medalhas conquistou, como foi a experiência e qual pode ser sua próxima prova, com descobertas apoiadas nas experiências de outros corredores.
