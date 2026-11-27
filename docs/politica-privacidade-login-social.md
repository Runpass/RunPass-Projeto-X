# Política de privacidade — login social (RunPass / +1Pódio)

Esta página descreve, para fins do cadastro OAuth do Google e do Facebook, quais dados o
aplicativo RunPass (ambiente de desenvolvimento, marca final +1Pódio) solicita ao login social
e como são usados.

## Dados solicitados ao provedor (Google/Facebook)

- E-mail e confirmação de verificação do e-mail.
- Nome associado à conta do provedor.
- Identificador único da conta no provedor (usado apenas para vincular o login, nunca exibido).

O aplicativo não solicita acesso a contatos, calendário, arquivos ou qualquer outro dado do
provedor além do necessário para autenticação (OpenID Connect, escopos `openid`, `email`,
`profile`).

## Como os dados são usados

- Criar ou vincular a conta RunPass à mesma pessoa, caso já exista uma conta com o mesmo
  e-mail verificado.
- Preencher o nome de exibição inicial do perfil (editável pela pessoa depois).
- Autenticar sessões futuras no aplicativo.

Os dados não são vendidos nem compartilhados com terceiros para fins de publicidade.

## Retenção e exclusão

A pessoa pode solicitar a exclusão da conta dentro do aplicativo. A exclusão bloqueia o acesso
imediatamente; dados pessoais identificáveis são removidos das partições ativas, com um período
de controle pseudonimizado de até 15 dias para prevenção de fraude antes do descarte completo.

## Contato

Dúvidas sobre esta política: runpasslife@gmail.com
