// Login direto no Cognito: a senha e o código do autenticador vão para o Cognito, nunca para a nossa API.

async function chamar(cfg, alvo, corpo) {
  const resposta = await fetch(`https://cognito-idp.${cfg.region}.amazonaws.com/`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': `AWSCognitoIdentityProviderService.${alvo}`,
    },
    body: JSON.stringify(corpo),
  });
  const json = await resposta.json().catch(() => ({}));
  if (!resposta.ok) {
    const erro = new Error(json.__type || 'erro');
    erro.codigo = (json.__type || 'erro').split('#').pop();
    throw erro;
  }
  return json;
}

function falha(codigo) {
  const erro = new Error(codigo);
  erro.codigo = codigo;
  return erro;
}

/** Passo 1: e-mail e senha. Devolve {desafio, sessao}: 'mfa' (operador normal), 'nova_senha' ou 'mfa_setup' (primeiro acesso). */
export async function entrar(cfg, email, senha) {
  const r = await chamar(cfg, 'InitiateAuth', {
    AuthFlow: 'USER_PASSWORD_AUTH',
    ClientId: cfg.clientId,
    AuthParameters: { USERNAME: email, PASSWORD: senha },
  });
  const mapa = { SOFTWARE_TOKEN_MFA: 'mfa', NEW_PASSWORD_REQUIRED: 'nova_senha', MFA_SETUP: 'mfa_setup' };
  const desafio = mapa[r.ChallengeName];
  if (!desafio || !r.Session) throw falha('NotAuthorizedException');
  return { desafio, sessao: r.Session };
}

/** Primeiro acesso: troca a senha temporária. Devolve o próximo desafio (normalmente 'mfa_setup'). */
export async function definirSenha(cfg, email, sessao, novaSenha) {
  const r = await chamar(cfg, 'RespondToAuthChallenge', {
    ClientId: cfg.clientId,
    ChallengeName: 'NEW_PASSWORD_REQUIRED',
    Session: sessao,
    ChallengeResponses: { USERNAME: email, NEW_PASSWORD: novaSenha },
  });
  if (r.ChallengeName !== 'MFA_SETUP' || !r.Session) throw falha('NotAuthorizedException');
  return r.Session;
}

/** Pede o segredo do autenticador. Devolve {segredo, sessao}. */
export async function iniciarAutenticador(cfg, sessao) {
  const r = await chamar(cfg, 'AssociateSoftwareToken', { Session: sessao });
  if (!r.SecretCode || !r.Session) throw falha('NotAuthorizedException');
  return { segredo: r.SecretCode, sessao: r.Session };
}

/** Confirma o primeiro código e conclui o login. Devolve o token de acesso. */
export async function concluirAutenticador(cfg, email, sessao, codigo) {
  const v = await chamar(cfg, 'VerifySoftwareToken', { Session: sessao, UserCode: codigo });
  if (v.Status !== 'SUCCESS' || !v.Session) throw falha('CodeMismatchException');
  const r = await chamar(cfg, 'RespondToAuthChallenge', {
    ClientId: cfg.clientId,
    ChallengeName: 'MFA_SETUP',
    Session: v.Session,
    ChallengeResponses: { USERNAME: email },
  });
  const token = r.AuthenticationResult && r.AuthenticationResult.AccessToken;
  if (!token) throw falha('NotAuthorizedException');
  return token;
}

/** Passo 2: código do autenticador. Devolve o token de acesso. */
export async function confirmarMfa(cfg, email, sessao, codigo) {
  const r = await chamar(cfg, 'RespondToAuthChallenge', {
    ClientId: cfg.clientId,
    ChallengeName: 'SOFTWARE_TOKEN_MFA',
    Session: sessao,
    ChallengeResponses: { USERNAME: email, SOFTWARE_TOKEN_MFA_CODE: codigo },
  });
  const token = r.AuthenticationResult && r.AuthenticationResult.AccessToken;
  if (!token || r.ChallengeName) throw falha('NotAuthorizedException');
  return token;
}
