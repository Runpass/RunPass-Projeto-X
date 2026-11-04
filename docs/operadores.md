# Operadores: bootstrap, sessão e recuperação

Procedimento preparado na S02; não executado na AWS. Bloquear habilitação administrativa real até responsáveis e papéis estarem configurados e testes S09 realizados.

1. Nomear responsável principal, substituto e responsável distinto para revisão/recuperação. Manter identificadores e contatos fora do Git.
2. Usar papel temporário restrito de infraestrutura na conta/ambiente corretos para criar o operador no pool exclusivo. Sem autocadastro, federação ou inscrição no beta. Inscrever/verificar TOTP pelo fluxo Cognito; senha inicial e segredo TOTP não entram em arquivo, log, histórico shell ou chat.
3. Após conferir a inscrição e identidade, outro responsável ativa `OPERATOR#sub / ACCESS` com `state=active`, `_rev` e apenas permissões necessárias. catalog_admin, moderation e lake_read são independentes. Não atribuir permissão de escrita das sessões ao próprio app/papel comum do operador.
4. Componente interno confiável de infraestrutura chama `establish_session` com cliente e store restritos. Ele exige SOFTWARE_TOKEN_MFA como desafio e resposta final do Cognito, valida access token e grava sessão pelo digest exato. Expira em até uma hora e nunca além do token. Retorno é usado em memória pelo cliente operacional; não imprimir tokens. Resposta inicial com tokens, MFA_SETUP ou refresh não cria sessão.
5. API verifica sessão, ACCESS atual e permissão. Ao implementar escritas administrativas, incluir a versão de ACCESS na própria transação de negócio; uma verificação anterior isolada não protege toda a operação contra revogação concorrente.
6. Recuperação: confirmar identidade por responsável distinto, suspender ACCESS/incrementar versão antes de redefinir fatores; revogar sessões Cognito, invalidar sessões locais e exigir novo enrollment/TOTP. Reativar após revisão; não há endpoint público de bypass. Registrar motivo/ator com a política de auditoria aprovada, sem copiar segredo ou token.

Antes de DEV: criar políticas IAM por recurso para identidade/sessões, definir armazenamento do segredo HMAC e provar que cliente público não pode gravar atestações. Antes de PROD: ensaiar primeira autenticação, enrollment incompleto, refresh, token alheio, revogação, recuperação e ausência do principal. A função Python/testes locais demonstram o protocolo, não uma execução real de MFA.

## Alertas críticos (escalonamento)

Definido em 04/11/2026: **Thiago é o primeiro responsável e Rafael o segundo.** Os alertas do tópico SNS `CriticalAlerts` (mensagens nas DLQs de eventos e auditoria, erros 5xx da API e falhas da manutenção agendada) chegam por e-mail aos quatro endereços cadastrados, que ficam fora do Git e entram como parâmetros `AlertEmail1` a `AlertEmail4` no deploy. O primeiro responsável confirma o recebimento e investiga; o segundo assume se o primeiro não puder. O prazo de resposta ainda não foi definido e deve ser acordado antes de DEV receber tráfego de teste de carga. O recebimento só é provado no deploy: cada destinatário confirma o e-mail de assinatura e um alarme de teste (`aws cloudwatch set-alarm-state`) deve chegar a todos.
