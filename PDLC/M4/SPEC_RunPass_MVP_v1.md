# SPEC — RunPass MVP — referência única

Atualização: 28/10/2026. Estado: **direções prioritárias aprovadas pelo usuário; detalhamento e desenvolvimento incremental autorizados no escopo abaixo**.

Arquivo canônico: **SPEC_RunPass_MVP_v1.md**. Por decisão do usuário, existe uma única SPEC ativa. O conteúdo consolidado foi incorporado neste arquivo; a tentativa de v2 foi incorporada sem manter um segundo arquivo ativo. O registro anterior foi preservado em historico/REGISTRO-TECNICO-ANTERIOR-2026-10-27.md, sem vigência concorrente.

## Decisão de aprovação e primeira entrega

O usuário aprovou as três direções apresentadas e a manutenção de uma única SPEC:

1. **Dados:** DynamoDB sob demanda, agrupando participação, avaliação e medalha; separar os demais domínios conforme padrões de acesso e necessidades operacionais. Engenharia detalha tabelas, chaves, índices e transações sem exigir aprovação de cada atributo. A aprovação não fixa automaticamente as seis tabelas candidatas da seção 6.
2. **Eventos:** outbox persistida na mesma transação da alteração, entrega via SQS e consumidores protegidos por versões/idempotência; replay de sete dias e reconstrução de projeções antigas pelo estado atual, conforme política já aprovada.
3. **Identidade:** Cognito com separação entre corredores e operadores; MFA por aplicativo autenticador para administração, autorização na API e permissões por função.

Primeira entrega autorizada para detalhamento e desenvolvimento técnico: **autenticação → catálogo → rascunho → imagem → conclusão → avaliação e medalha**. Não autoriza provisionamento pago ou release. Detalhes locais e reversíveis de implementação podem prosseguir; orçamento autorizado é condição antes de criar recursos pagos.

Painel completo, feed, pós-beta e detalhes operacionais devem ser resolvidos antes das respectivas entregas. Segurança, restauração, desempenho e privacidade precisam de evidências antes do beta. Requisitos não implementados não voltam automaticamente à condição de não aprovados. Não criar nova SPEC para mera reorganização.

## 1. Problema e resultado esperado

Corredores precisam descobrir provas, registrar experiências concluídas, organizar medalhas e compartilhar avaliações e conquistas. O MVP deve validar adesão, repetição e interação com até mil corredores, sem exigir arquitetura de produção futura completa no primeiro lançamento.

Aplicativo Flutter/Dart para Android e iPhone, backend Python/FastAPI em Lambda, armazenamento operacional DynamoDB e operação inicial na AWS São Paulo (`sa-east-1`). Não há site público para corredores no MVP. A equipe RunPass mantém catálogo e moderação por interface administrativa.

## 2. Estado das decisões e execução incremental

- **A — aprovado:** decisões anteriores e as três direções registradas acima.
- **P — proposta de detalhamento:** candidato técnico que Engenharia pode refinar no escopo aprovado. Alternativas com impacto real de produto, custo ou privacidade voltam à decisão do usuário.
- **B — dependência técnica:** resolver antes de implementar ou liberar a parte afetada; não bloqueia indiscriminadamente todo o projeto.
- **L — condição de liberação:** configuração, teste ou evidência necessária antes de PROD/beta.

As propostas P01–P09 e dependências B01–B06 abaixo foram preservadas para rastreabilidade. Não constituem uma nova rodada obrigatória de nove aprovações. As direções de DynamoDB on-demand, outbox/SQS e Cognito/MFA já estão aprovadas; quantidades físicas, parâmetros novos e escolhas além dessas direções não foram aprovados por inferência. A autorização de desenvolvimento não comprova testes nem libera produção.

## 3. Fontes e precedência

Base: PRD_RunPass_MVP_v2.md, decisões de Grill-me e confirmações posteriores, preservadas no registro histórico, MATRIZ-APROVACOES-M4-RunPass.md e documentos de retenção/eventos. Decisão explícita posterior prevalece sobre uma pendência histórica anterior.

O contrato API-RunPass-v1.openapi.json está em 0.8.0-draft, com 55 caminhos e 72 operações. Sua validação estrutural não comprova implementação. MODELO-DYNAMODB-RunPass-v1.md detalha o desenho físico do fluxo inicial na S01, em revisão. Não é modelo de todo o MVP nem infraestrutura homologada.

Referências complementares: EVENTOS-E-REPLAY-RunPass-MVP.md; DATA-LAKE-AVALIACOES-RunPass-v1.md; RETENCAO-E-EXCLUSAO-RunPass-MVP.md; RETENCAO-DENUNCIAS-E-AUDITORIA-RunPass.md; RETENCAO-TECNICA-RunPass-MVP.md; UPLOAD-ADMINISTRATIVO-MEDALHAS-RunPass.md; FECHAMENTO-TECNICO-RunPass-MVP.md; ORCAMENTO-RunPass-preliminar.md e respectiva simulação.

## 4. Requisitos de produto consolidados — A

### 4.1 Catálogo e solicitações

Catálogo por prova e edição, com distâncias próprias. Cobertura inicial das principais corridas de São Paulo capital, dois anos de histórico e provas futuras. Meta de cobertura de 90% usa a referência inicial documentada de provas, não mínimo arbitrário de edições.

Equipe RunPass gerencia catálogo; corredor solicita provas ausentes, com nome, data, cidade e distância. Duplicatas são vinculadas à edição existente após revisão humana. Rascunhos são preservados; solicitação aceita não conclui automaticamente a participação. Organizador é referência de catálogo, sem login ou portal B2B.

Arquivar edição impede novas conclusões e transferências para ela, preserva histórico e permite editar/excluir participações já concluídas. Alterações em distâncias não podem invalidar referências existentes silenciosamente.

### 4.2 Participação, avaliação e medalha

Uma participação por usuário/edição, somente de prova concluída por autodeclaração. Antes de concluir, pode manter rascunho. Conclusão exige oito notas de 1 a 5 e imagem de medalha disponível; comentário de avaliação é opcional.

Critérios: organização, percurso, kit, medalha, hidratação, estrutura, segurança e custo-benefício. RunScore é a média com pesos iguais, por edição, apresentado com uma casa decimal; avaliações podem ser filtradas por distância. Avaliação invalidada não contribui ao score; decisão de moderação não exclui automaticamente toda a conquista.

O proprietário pode editar ou excluir seu cadastro, respeitando unicidade e controle de versão. PUT da avaliação substitui as oito notas; omitir comentário remove o comentário atual e gera histórico restrito antes/depois. Alterar edição exige verificar duplicidade e ajustar contribuições/projeções.

Medalha é adicionada automaticamente na conclusão. Usa imagem oficial vigente ou foto própria obrigatória quando ela não existe. Foto própria não é promovida automaticamente ao catálogo. Cada medalha guarda a versão oficial vinculada; trocar a imagem do catálogo só afeta novos vínculos. Correção retroativa é ação separada, explícita e auditada.

### 4.3 Social e privacidade

Feed de conquistas e medalhas; sem feed genérico de fotos livres. Decisão de produto de 08/11/2026 (substitui a de 07/11/2026): **publicações são sempre públicas**, perfil privado ou não — qualquer usuário admitido vê o feed, curte, comenta, e vê fotos de post, avatar e banner de qualquer autor, além da contagem de seguidores/seguindo de qualquer perfil. Perfil privado restringe **só o resumo consolidado de corridas** (contagem de participações e a lista de corridas concluídas) a quem é amigo aceito (ou o próprio dono); seguir sozinho nunca desbloqueia esse resumo. A tela Início oferece quatro recortes do feed, recência dentro de cada um (decisão de 08/11/2026): "Todos" (padrão; qualquer autor com conta ativa, inclui as minhas publicações), "Amigos" (só amizades aceitas, nunca as minhas — sem nenhuma, convida a encontrar pessoas), "Seguindo" (só quem eu sigo, nunca as minhas — mesmo convite quando vazio) e "Minha Cidade" (recorta "Todos" pela cidade/estado cadastrados no meu perfil, com prioridade para a mesma cidade; sem nenhuma publicação da mesma cidade, cai para cidades vizinhas num raio de 50 km, calculado pela distância entre os centroides das cidades — pede o cadastro de estado/cidade uma única vez, na primeira vez que o usuário abre esse filtro, caso ainda não tenha). Nos quatro, as publicações em si nunca ficam restritas por privacidade. Curtidas, comentários, seguir, pedido de amizade, busca de perfis e wishlist integram o MVP.

Estado (UF) e cidade do perfil vêm de uma lista fechada do IBGE (27 UFs, ~5.570 municípios), escolhidos por rolagem, sem digitação livre, no mesmo padrão visual da data de nascimento. Junto, o app grava a latitude/longitude do centroide da cidade escolhida (de um dataset público derivado do IBGE), usada só para o raio de "Minha Cidade" — sem GPS do aparelho. Novo cadastro pede os dois num passo dedicado, entre o perfil e a data de nascimento; quem já tem conta preenche ao usar o filtro "Minha Cidade" pela primeira vez, ou a qualquer momento em "Editar perfil".

Seguir (`follow`) é unidirecional e sempre imediato, mesmo para perfil privado — nunca exige aprovação. Amizade (`friend`) é bidirecional, com pedido e aprovação explícita do dono do perfil; só amizade aceita abre o resumo de corridas de um perfil privado. Pedidos de amizade recebidos aparecem só em Avisos, num resumo com contagem ("Pedidos de amizade (N)"); a tela de Perfil não tem mais atalho de busca de pessoas nem de pedidos (busca já está no Início).

A tela de Perfil concentra as publicações do próprio usuário (corridas com `publishToFeed=true`), mais recente primeiro, como em outras redes sociais — mesmo cartão usado no Feed, uma publicação abaixo da outra — além de continuarem aparecendo em "Todos".

Perfil público mostra dados de corrida/conquistas; e-mail e nascimento permanecem privados. Publicações e wishlist começam visíveis, podendo ser ocultadas. Tempo e colocação podem ser ocultados; ocultar tempo também oculta pace em todas as superfícies. API não devolve campos ocultos apenas porque o cliente os esconde.

Bloqueio oculta interações existentes e remove follows nos dois sentidos, sem apagar indiscriminadamente o histórico. Novas interações são impedidas enquanto existir bloqueio em qualquer direção. Desbloqueio não recria follows. Visibilidade e exclusões atuais prevalecem sobre índices/projeções atrasados.

### 4.4 Beta e feedback

Instalação nas lojas oficiais, como no produto futuro. Beta no ambiente PROD, até mil admitidos únicos, por 60 dias desde o 50º admitido. Admissão exige e-mail confirmado e idade mínima de 13 anos por autodeclaração/data de nascimento (decisão de produto de 07/11/2026, alinhada à prática do Instagram); não exigir documento por inferência. Exclusão não reabre vaga automaticamente. Excedentes podem entrar voluntariamente em lista de espera, sem acesso automático.

Ativo: pelo menos uma participação concluída com cadastro completo. Metas: ativação de 50% dos admitidos reais; repetição em outra edição de 30% dos ativados; interação social de 30% dos ativados. Cadastros de espera não integram denominadores. Contas técnicas não devem contaminar a coorte de corredores.

Feedback voluntário após primeiro registro, canal contínuo, pesquisa aos 30 dias e fechamento aos 60; revisão semanal. Resultados e privacidade devem respeitar correções/exclusões sem duplicar ativação por recriação.

## 5. Arquitetura e fronteiras

### 5.1 Decisões consolidadas — A

Python apenas no backend; Flutter/Dart mobile; FastAPI em Lambda; DynamoDB como direção de armazenamento; CloudFormation; região sa-east-1; DEV e PROD em contas distintas. Backend modular por domínio, sem exigir um microsserviço por módulo.

GitHub Actions com OIDC e papéis temporários separados por conta; pull request, testes e revisão humana antes de main. Promover os mesmos artefatos validados em DEV, com configuração por ambiente e aprovação manual separada de PROD.

### 5.2 Pacote proposto — P01

API Gateway HTTP como entrada; Cognito User Pools para identidade; Lambda para API, processamento e manutenção; DynamoDB on-demand (aprovado); S3 privado para arquivos; Streams como sinal e SQS com consumidores separados por finalidade; CloudWatch para observabilidade. Sem Aurora, OpenSearch, EventBridge geral, NAT ou CDN por padrão nesta linha de base. Adição posterior exige justificativa e atualização de custo.

Separar buckets/prefixos e papéis para originais temporários, imagens tratadas, histórico de avaliações e evidências. Acesso mobile sempre mediado pela autorização da API; não dar acesso direto às tabelas. Downloads por URLs temporárias autorizadas, com risco de validade residual explicitado.

O histórico de avaliações é uma camada informacional limitada, não plataforma analítica geral. Consulta administrativa mediada por índice de avaliação/período e objetos S3, sem introduzir Athena/Glue/Firehose automaticamente.

## 6. Dados: desenho da primeira entrega — S01

O desenho físico atual está em MODELO-DYNAMODB-RunPass-v1.md, com evidências e decisões em S01-desenho-e-contratos.md. Ele substitui os candidatos físicos parciais anteriores para o fluxo inicial; não modela todo o social.

IdentityAccess, RaceCatalog, RunHistory, Operations e Projections cobrem o fluxo inicial. ErasureControl é segregada para o controle mínimo de exclusões aprovado por até 15 dias; Social fica para entrega posterior. Agrupam-se participação/review/medalha por USER/participationId estável, com reserva condicional USER/editionId e lookup por participationId. As tabelas não foram criadas; custos devem ser recalculados antes de provisionar.

O modelo registra PK/SK, índices esparsos e facets de catálogo, fonte/projeção, matriz rota→consulta/transação, invariantes, eventos e limpeza por titular. Todas as combinações dos filtros de catálogo permanecem disponíveis com paginação limitada por trabalho, sem Scan global. Leitura de índices é revalidada na fonte atual, sem expor resultados ocultos ou rascunhos alheios.

**B01:** desenho do fluxo inicial preparado na S01; comprovar consultas, geração de índice, concorrência e distribuição nos slices de implementação. Feed completo permanece dependência de sua própria entrega. Eficiência/custo não são medidos por documentação.

## 7. Integridade, transações e eventos

### 7.1 Invariantes — A

Não duplicar participação por usuário/edição, like por ator/publicação ou admissão. Versão esperada impede sobrescrita silenciosa. Ator vem da identidade autenticada. Conteúdo pendente, oculto, arquivado ou excluído não se torna publicável por uma projeção antiga.

### 7.2 Outbox/SQS aprovados e detalhamento — P03

Conclusão grava participação, review e medalha, conversão do rascunho quando aplicável, idempotência e outbox em transação com condições de unicidade, conta ativa e versão/estado da edição. Edição concorrente de catálogo deve provocar conflito/revalidação, não conclusão com dados inconsistentes.

Outbox durável em Operations na mesma transação da alteração de negócio. Streams apenas acorda publicador; reconciliador consulta pendências duráveis. Publicador encaminha por destino; falha após envio pode duplicar. Não declarar entrega aplicada apenas porque a fila aceitou.

Envelope: eventId, eventType, schemaVersion, aggregateId, aggregateVersion, occurredAt UTC, correlationId, payload mínimo. Payload de auditoria antes/depois fica separado do evento para score/feed. Nunca incluir nascimento, credenciais ou imagem binária.

Cada consumidor registra versão/contribuição com escrita condicional e, quando possível, na mesma transação do efeito. RunScore guarda contribuição válida por review: calcula diferença para somas/contagem anteriores e registra a versão aplicada. Evento antigo não reaplica contribuição; exclusão ou invalidação retira contribuição. Edição do destino corrige ambos os agregados. Reconstrução é isolada por geração e conciliada com mudanças concorrentes antes de promoção.

Replay de concluídos por até sete dias — A; propõe-se contar desde a última confirmação obrigatória, sem renovar por replay. Pendências permanecem recuperáveis, respeitando exclusões e expiração específica. Reconstruções mais antigas usam fontes atuais. Operação interna registra ator, motivo, seleção e resultado.

**B02:** desenho S01 fixa replay desde allConfirmedAt, transporte de um dia, ledger ligado à outbox viva e contribuição versionada vigente; controle mínimo de exclusão por até 15 dias aprovado como exceção segregada. Implementar e comprovar em S07–S09; TTL não substitui expiração lógica ou limpeza. Reconstrução usa fontes atuais e nunca recria conteúdo excluído.

## 8. Identidade e autorização

### 8.1 Regras — A

Corredor: e-mail/senha; proprietário altera seus dados. Administrador gerencia catálogo/solicitações/acessos; Moderador atua em denúncias/conteúdo. Ambos exigem MFA. Administrador não recebe moderação ou consulta do lake automaticamente. Consulta do lake exige autorização específica e auditoria.

Conta excluída deve perder acesso à API mesmo com token emitido. Bloqueios são bilaterais na autorização de novas interações. Identidade autenticada sem admissão só acessa bootstrap e exclusão previstos no contrato. Operação administrativa não consome vaga de corredor.

### 8.2 Cognito/MFA aprovados e detalhamento — P04

Cognito segregado por ambiente e pools distintos para corredores e operadores; TOTP obrigatório no pool administrativo. Separar clients, audiences e papéis; API verifica issuer/audience/token e fluxo administrativo autenticado, além de papel/estado atual na fonte. Não inferir MFA de um JWT qualquer nem confiar em indicação enviada pelo frontend.

Bootstrap de operador por procedimento restrito de infraestrutura, sem cadastro público. Recuperação de MFA exige verificação e trilha operacional; não oferecer bypass por endpoint público. Propor ao menos dois operadores recuperáveis antes de PROD para evitar dependência de uma pessoa. Matriz de consulta de auditoria e replay usa permissões específicas.

**B03:** S01 descreve attestation de conclusão TOTP para token exato, bootstrap, recuperação e revogação. Implementar/verificar protocolo e nomear responsáveis antes de ativar administração real. Validar o plano Cognito escolhido e o custo, sem tratar a hipótese Lite do orçamento como aprovação. Política IAM e segredos não são criados por este documento.

## 9. Imagens e painel

### 9.1 Imagens — A

JPEG/PNG, original até 10 MB; meta de otimização até 1 MB. Servidor valida formato real, tamanho e decodificação, remove GPS e preserva orientação. Validação com meta de cinco segundos pós-upload; pendente não significa válida. Não servir original não tratado a terceiros.

Sessões administrativas vinculam edição/distância e ambiente. Upload não publica. Após prévia, PATCH versionado confirma referência administrativa validada, sem aceitar upload pessoal de terceiro. Versões anteriores referenciadas são preservadas. URL de upload: 15 minutos.

### 9.2 Propostas — P05

Converter HEIC no dispositivo para formato aceito antes do envio, com teste em iPhone real. Se conversão falhar, informar e preservar rascunho; não declarar suporte HEIC servidor. A S01 fixa proteção inicial de 25 megapixels por imagem e sessão de recebimento de 15 minutos, com UX de redução local; validar fotos típicas nos slices de imagem antes de liberação. Downloads autorizados por URL de cinco minutos e sem cache público de conteúdo ocultável; validade residual deve constar no teste/experiência, sem promessa de revogação instantânea de URL já emitida.

Painel Flutter Web como proposta técnica, hospedagem estática privada na operação de administração ou pública apenas para o shell sem dados, com backend protegido. Escolher hospedagem após prova de login/MFA, formulários, uploads e acessibilidade; não acrescentar um site público de corredores.

**B04:** fechar hospedagem/painel, tratamento de filtros/limites e operação retroativa da imagem antes das respectivas entregas. Teste de HEIC, metadados, concorrência e preservação de versões é condição L, sem reaprovar formatos já aceitos.

## 10. Retenção e exclusão: referência consolidada

| Categoria | Estado/regra |
| --- | --- |
| Histórico ativo | A: sem TTL; exclusão pelos fluxos previstos |
| Conta excluída | A: bloqueio/ocultação imediatos; remover dados pessoais ativos em até sete dias, inclusive lake |
| Controle mínimo de exclusão | A em 28/10: segregado/pseudonimizado, apenas recuperação, por até 15 dias desde aceitação; exceção específica, sem estender demais dados |
| Lake de avaliações | A: 60 dias desde ocorrência original, sem renovação por replay; exclusão de conta prevalece |
| Recuperação | A: sete dias no beta, independente dos dados ativos; reaplicar exclusões na restauração |
| Denúncia aberta | A: enquanto necessária, revisão semanal; não deixar sem acompanhamento indefinidamente |
| Denúncia encerrada/evidência necessária | A: até 60 dias do encerramento |
| Auditoria administrativa | A: até 90 dias da ação |
| Logs DEV/PROD | A: sete/30 dias; minimização e exclusão pessoal continuam obrigatórias |
| Idempotência de comando | A: sete dias desde primeira aceitação durável |
| Payload entregue | A: sete dias desde última confirmação obrigatória, não define ledger |
| Temporário abandonado | A: limpar até 24 horas após expiração da sessão, sem apagar trabalho ativo |
| Validada nunca vinculada | A: sete dias desde validação, limpar até 24 horas depois; checar referências |

**P06:** bloquear consulta de lake/denúncia/auditoria no vencimento e remover cópias operacionais elegíveis em até 24 horas depois. Auditoria de avaliação ainda pendente ao vencer deve ter payload pessoal descartado com registro mínimo de expiração/falha, sem falsa confirmação de entrega. Evento operacional de score continua independente.

**B05:** controle mínimo de exclusões aprovado por até 15 dias e desenhado na S01, com comprovação de recuperação/descarte pendente. Definir retenções restantes de rascunhos, espera, solicitações e feedbacks; política de nascimento; comprovar que logs e filas permitem cumprir exclusão pessoal. Não armazenar dados indefinidamente sob pretexto de pendência, backup ou auditoria. Backups não são prometidos como removidos em 24 horas; versões e cópias são inventariadas.

## 11. Contratos e testes

### 11.1 Contrato HTTP

OpenAPI 0.8.0-draft cobre conta/beta, perfis, catálogo, participação/review, uploads comuns e administrativos, social, wishlist, notices, solicitações, moderação e administração. PUT de review é substituição; PATCH é alteração parcial; DELETE aceita remoção e não afirma limpeza de todas as cópias. Cognito tem fluxo de login próprio, não endpoints fictícios no backend.

Erros, idempotência, versão, parâmetros e schemas existentes são a base de revisão. **P07:** aprovar a linha de base contratual condicionada a revisão por jornada; ajustes incompatíveis exigem versão/migração. Limites de texto e paginação devem ser fixados no contrato antes de gerar cliente definitivo. Não interpretar extensões x-required-role/x-requires-mfa como segurança executável.

### 11.2 Critérios mensuráveis propostos — P08

| Área | Proposta de aceite e evidência L |
| --- | --- |
| Integridade | Testes concorrentes sem participação/like/admissão duplicados; sem perda de outbox confirmada |
| Segurança | Testes negativos de proprietário, papéis, MFA, bloqueios e token anterior à exclusão; dados ocultos ausentes das respostas |
| Latência | p95 da validação de imagem até 5 s pós-upload; p95 RunScore até 10 s pós-commit, no cenário de carga acordado |
| API | Separar endpoint crítico de processamento assíncrono; medir média abaixo de 500 ms e p95 abaixo de 1 s para operações leves, sem contar transferência de arquivo |
| Carga | Patamar de 20 req/s por 30 min, mistura versionada de jornadas; estresse de 100 req/s por 10 min, com limitação controlada e sem corrupção/perda |
| Falhas | Menos de 1% de erros 5xx no ensaio esperado; respostas de validação deliberadamente inválidas fora dessa conta; identificar toda limitação 429 |
| Disponibilidade | Meta anterior de 99,5%; propor janela mensal por jornada sintética, contando indisponibilidade percebida inclusive manutenção planejada; RTO não é franquia de queda |
| Recuperação | Ensaio de RPO até 5 min e RTO até 4 h nos cenários cobertos, com exclusões reaplicadas, dados e imagens coerentes |
| Mobile | Jornadas essenciais em Android/iPhone reais, formatos de foto, privacidade e instalação pelas lojas; fixar modelos/versões testados |

P95, duração, mistura e limiares adicionais são propostas novas, não metas históricas aprovadas por inferência. Carga de mil inscritos não significa mil simultâneos. RTO depende de cenário e pode consumir mais que o orçamento mensal de disponibilidade; avaliar ambos separadamente.

## 12. Orçamento, operação e liberação

Premissas A: 20 medalhas/usuário, 300 usuários/dia, duas sessões/dia e 30 imagens/sessão. Estimativa existente é sensibilidade parcial baseada nas tarifas coletadas em 26/10/2026; não atualizada por esta consolidação.

Subtotal registrado: DEV US$ 3,07/mês e PROD esperado US$ 26,91/mês; soma modelada US$ 29,98/mês, antes das exclusões. Não é proposta de teto. Não usar US$ 29,98 como custo completo nem aplicar os valores automaticamente às seis tabelas candidatas ou à nova solução de identidade.

**B06:** recalcular por operações/tamanhos/índices, incluir outbox/ledger, jobs, S3 versões/limpeza, consulta/auditoria, logs completos, alarmes, identidade/painel, pipeline, tráfego API, lojas e demais exclusões; apresentar limite autorizado antes de provisionar. Não há orçamento aprovado.

Alertas críticos por e-mail à equipe RunPass — A. **L:** nomear principal/substituto e cobertura, testar recebimento/escalonamento, documentar falhas, replay, restore, rollback e exclusão. Endereço operacional fora do repositório. Antes de PROD: acessos, lojas, política de dados, testes essenciais, custo autorizado e aceite de release.

## 13. Encerramento do beta — proposta P09

Ao fim dos 60 dias, não apagar contas automaticamente nem ampliar vagas. Propor manter acesso dos admitidos e congelar novas admissões até revisão de resultados pela equipe RunPass; preservar lista de espera conforme política de retenção a fechar. Aprovar explicitamente a continuidade operacional e seu orçamento: a duração da avaliação não encerra custos nem obrigações por si só.

O aplicativo continua distribuído pelas lojas oficiais. Alteração de faixa etária, monetização, site público ou expansão de capacidade exige evolução específica; não faz parte desta proposta.

## 14. Plano de execução da primeira entrega

1. Detalhar apenas os acessos, chaves e transações de identidade, catálogo e histórico necessários ao fluxo inicial; adaptar o modelo DynamoDB existente. Fechar a deduplicação/versão e o controle de exclusões dos consumidores envolvidos. Feed completo não bloqueia essa modelagem inicial.
2. Atualizar os contratos existentes para esse fluxo, especificar autenticação/autorizações e preparar testes locais de unicidade, versão, imagem, transação/outbox e replay.
3. Preparar implementation-slices.md para a primeira entrega, com dependências e critérios de aceite. Organizar contexto/regras/harness antes da execução; não marcar uma dependência não resolvida como concluída.
4. Desenvolver e revisar por entrega. Antes de provisionar DEV, concluir orçamento aplicável e obter autorização de custo. Antes do beta, cumprir condições de liberação, fechar políticas necessárias e revisar resultados de testes.

**Aprovação registrada:** direções prioritárias e desenvolvimento incremental do fluxo inicial. **Pendente:** detalhamento dos pontos técnicos da entrega e aceite posterior dos resultados. Não é necessário reaprovar as mesmas direções; aprovação de todo o MVP e autorização de PROD não são presumidas.

## 15. Fora do MVP e pontos de extensão

Fora: rastreamento GPS/treinos, chat/stories, ranking competitivo, clubes, monetização, integrações esportivas, portal de organizadores, analytics avançado e site público para corredores. Notificações do produto inicialmente internas; push futuro. Compartilhamento usa cards gerados localmente com dados autorizados.

Evolução por contratos versionados, fronteiras de módulos e projeções reconstruíveis. Separar serviço, banco ou consumidor quando carga, isolamento ou operação justificarem; não prometer escalabilidade sem medir hot keys, fan-out, custo e limites.

## 16. Referências técnicas consultadas nesta revisão

- [DynamoDB: limites e transações](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Constraints.html): transações têm limites e não atravessam contas/regiões.
- [DynamoDB: TTL](https://docs.aws.amazon.com/us_en/amazondynamodb/latest/developerguide/TTL.html): expiração não representa descarte físico imediato; trabalhos com prazo precisam de desenho próprio.
- [Cognito: TOTP MFA](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-settings-mfa-totp.html): base para a proposta de segundo fator; integração e recuperação precisam de validação.

Registro de aprovação: usuário respondeu **“Aprovado! vamos utilizar uma única SPEC”**, aprovando as três direções e a primeira entrega descritas no início. Não há aprovação de terceiros presumida. Identificação de responsáveis técnicos, aceite de implementação e liberação de PROD serão registrados separadamente. Esta decisão não cria evidência de reuniões ou gates corporativos não realizados.

## Plano da primeira entrega preparado

implementation-slices.md detalha S00–S09 para o fluxo aprovado: preparação local/contexto/harness, desenho de dados e contratos, identidade/admissão, catálogo, rascunho, imagem, conclusão/avaliação/medalha, consumidores/RunScore/histórico restrito, edição/exclusão e integração real em DEV. Cada slice tem dependências e critérios de aceite. S00 pode iniciar; os seguintes dependem das saídas anteriores. Provisionamento DEV depende de orçamento e autorização; release PROD/beta não é autorizado por esse plano. Não há implementação/testes de execução concluídos nem nova SPEC criada.
## S01 — desenho e contrato preparados

Em 28/10/2026, por solicitação do usuário, detalhados modelo físico e contratos do fluxo inicial. PUT /me fecha o bootstrap pré-admissão; limites de username/comentário/página/imagem e estados de upload foram explicitados. S01-desenho-e-contratos.md registra decisões, fontes primárias, matriz de falhas e verificações. Desenho em revisão, sem API/AWS executada; não constitui aprovação integral da SPEC ou liberação. S02 pode avançar localmente conforme as dependências registradas. A aprovação específica do controle de exclusão por até 15 dias não aprova automaticamente outras propostas de retenção.


## Aceite da revisão S01 — 28/10/2026

Usuário concordou com os três blocos revisados sequencialmente: perfil/cadastro, catálogo/avaliações e fotos/falhas. Último bloco confirma conversão HEIC e redução de resolução no mobile, sessão de 15 minutos, imagem validada antes da conclusão e preservação do rascunho em falha/timeout de processamento (15 minutos após finalize). Meta pós-upload de cinco segundos mantida, sujeita a testes. S01 aceita no escopo do desenho revisado; próximo slice S02 local. Detalhes e evidências em S01-desenho-e-contratos.md. Não comprova implementação ou testes reais, não dispensa dependências dos slices seguintes e não autoriza recursos pagos, deploy ou beta.


## S02 — implementação local em revisão, 28/10/2026

Usuário autorizou seguir para S02. Implementadas nove operações HTTP de perfil/admissão/espera, validação JWT/Cognito, idade/teto/marco do beta, idempotência, bloqueio imediato da conta e job durável de exclusão. Mobile tem cadastro/confirmação/login/recuperação/perfil/admissão/espera com token em memória. Adaptador local e DynamoDB explícito, sessão de operadores ligada ao desafio TOTP e template CloudFormation de identidade preparado sem aplicar. Evidências/limites: S02-identidade-admissao.md. Testes locais não comprovam AWS, MFA real ou aparelhos; worker de limpeza e integração permanecem S08/S09. S02 em revisão, sem aceite humano, provisionamento, deploy, commit ou push. Próximo slice técnico: S03 catálogo.


## S03 — catálogo local em revisão, 28/10/2026

Após liberar espaço do Mac e solicitar retomada, implementadas GET /editions e GET /editions/{id}, filtros combináveis/cursor cifrado, carga interna em gerações com MFA/papel atual, auditoria e referências de imagem validadas. Seed sintético idempotente em memória e telas Flutter de catálogo/detalhe/seleção. S03-catalogo.md registra resultados e limites; OpenAPI 0.8.0-draft preservado. Demonstração debug separada sem rede preparada para teste visual no simulador, sem afirmar autenticação real ou integração de backend. Usuário autorizou reinstalar runtime iOS 27.1 após falha de inicialização; resultado nativo depende de evidência no relatório. Sem aceite humano, AWS, deploy, commit ou push. Próximo slice: S04 rascunho.

## S04 — rascunho local em revisão, 28/10/2026

Após o usuário solicitar continuidade das slices, foram implementadas criação, leitura, listagem e alteração de rascunho privado, com reserva única por usuário/edição, idempotência, versão esperada, validação de edição/distância e integração Flutter a partir do catálogo. A entrega não gera review, medalha, RunScore, outbox ou publicação. Evidências e limitações: S04-rascunho-participacao.md. Sem AWS, deploy, commit ou push. Próximo slice técnico: S05 imagem.

## S05 — imagem local em execução, 29/10/2026

Implementados localmente sessão/finalização/estado de upload privado, fixação da versão do objeto, autorização do titular, validação JPEG/PNG, limite de 25 megapixels, orientação, remoção de metadados, otimização e falha fechada. O Flutter seleciona e reduz fotos, valida assinatura/tamanho, envia pela URL autorizada e só então finaliza; falhas preservam o rascunho. Evidências: 63 testes backend, 14 testes Flutter, análise estática e compilação no simulador. Conversão HEIC exige iPhone real; S3/IAM e latência pertencem à integração DEV autorizada no S09. Detalhes em S05-upload-imagem.md. Sem AWS, deploy, commit ou push.

## S06 — conclusão local em revisão, 29/10/2026

Implementada conclusão transacional local do rascunho com autodeclaração, oito notas, imagem válida, review, medalha com referência/versionamento fixos, claim, outbox e idempotência. Concorrência produz um único vencedor e falhas de imagem/edição preservam o rascunho. O teste Flutter vertical percorre upload sintético, validação, oito notas e conclusão. Evidências: 66 testes backend, 15 Flutter e análise limpa; limites em S06-conclusao-avaliacao-medalha.md. Consumidores/RunScore são S07; integração real é S09. Sem AWS, deploy, commit ou push.

## S07 — consumidores locais em revisão, 01/11/2026

Implementados consumidores locais idempotentes de score/auditoria, contribuição vigente, RunScore por soma inteira, DELIVERY por destino, epoch, prazo de replay sem renovação e marcador/reconciliador em 16 shards. Lease renovável de 60 segundos usa fencing monotônico; falhas permanecem reencontráveis com backoff. Eventos atrasados reconciliam a fonte atual; comentário fica fora do evento operacional. Limpeza ativa remove payload entregue após sete dias e lake no marco original de 60 dias; auditoria pendente vencida é descartada sem confirmação falsa. Evidências: nove testes focados e 75 testes backend em `make check`. SQS/S3/IAM e metas de latência permanecem integração S09. Sem AWS, deploy ou push.

## S08 — edição e exclusão locais em execução, 01/11/2026

Implementados PUT completo de review, remoção de comentário omitido, histórico restrito antes/depois, edição versionada de participação concluída, transferência de edição com recomposição do RunScore e exclusão lógica da participação. Exclusão de conta ganhou marcador e executor retomável por etapas, compensando score e enumerando registros pessoais locais antes da conclusão; bloqueio imediato e controle pseudonimizado aprovado permanecem. Evidências e limitações em S08-edicao-exclusao-privacidade.md. Bytes de objetos, serviços AWS, restore e UI mobile continuam pendentes. Sem AWS, deploy ou push.

## S09 — preparação local, 01/11/2026

Preparado template CloudFormation candidato para seis tabelas, buckets privados de medalhas/auditoria, filas/DLQs e alarmes, somado ao template Cognito existente. `make infra-check` valida os dois arquivos localmente. Gate, evidências e lacunas estão em S09-integracao-dev.md. Em 01/11/2026, o usuário autorizou teto de R$ 1.000/mês para DEV; orçamento continua parcial e deve ser atualizado antes do change set. Conta DEV, OIDC, responsáveis e autorização de provisionamento não estão registrados. Nenhum recurso AWS foi criado e integração/aceite não foram declarados.

## Região AWS — decisão de 02/11/2026

O usuário decidiu migrar a região inicial de `sa-east-1` (São Paulo) para `us-east-2` (Ohio). Esta decisão posterior prevalece sobre as menções a São Paulo e `sa-east-1` na linha de base 5.1 e nos registros anteriores, que ficam preservados como histórico.

Motivo: o projeto AWS disponível usa a nova experiência, que só cria recursos na região do projeto, e uma política de organização gerenciada pela AWS nega `sa-east-1`. Tentar contornar essa política não é opção. Os onze serviços da arquitetura (DynamoDB, S3, SQS, Lambda, API Gateway, Cognito, SSM, CloudWatch Logs, SNS, EventBridge e CloudFormation) responderam em `us-east-2` em chamadas somente de leitura.

Consequências em aberto, nenhuma aprovada por inferência:

- **Dados pessoais fora do Brasil.** Cadastro, nascimento, fotos e avaliações passam a ser armazenados nos Estados Unidos. A revisão de privacidade e de transferência internacional de dados pessoais (LGPD) é necessária antes de qualquer dado real, beta ou PROD. Esta decisão cobre a preparação e o DEV com dados sintéticos.
- **Latência.** O público é brasileiro e o desempenho de imagem (cinco segundos) e de RunScore (dez segundos) deve ser medido no DEV, não presumido.
- **Orçamento.** As tarifas coletadas em 26/10/2026 são de São Paulo e não valem para Ohio; o orçamento precisa ser recalculado antes do change set. O teto DEV de R$ 1.000/mês continua o limite financeiro.
- **PROD.** Aprovação própria continua exigida, inclusive para decidir se a região de PROD será a mesma.

O fuso `America/Sao_Paulo` usado na regra de data de edições futuras não muda: ele descreve a data local das provas, não a região de hospedagem. Nenhum recurso foi provisionado, e esta decisão não autoriza provisionamento.

## Região AWS — retorno a São Paulo em 02/11/2026

O usuário criou uma conta AWS padrão (`<ID da conta DEV>`) e decidiu manter a região `sa-east-1`. Esta decisão posterior substitui a migração para `us-east-2` registrada acima, que fica preservada como histórico. A conta de projeto `<ID da conta de projeto>` não é usada para o RunPass: ela só opera em `us-east-2`, por política gerenciada pela AWS.

Efeitos: dados pessoais voltam a ficar no Brasil, e a revisão de transferência internacional deixa de ser necessária. As tarifas de São Paulo coletadas em 26/10/2026 voltam a valer como base, ainda sujeitas a atualização antes do change set. O teto DEV de R$ 1.000/mês é o mesmo. Provisionamento continua não autorizado, e PROD exige aprovação própria.
