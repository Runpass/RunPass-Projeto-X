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

/** Passo 1: e-mail e senha. Devolve a sessão do desafio de MFA. */
export async function entrar(cfg, email, senha) {
  const r = await chamar(cfg, 'InitiateAuth', {
    AuthFlow: 'USER_PASSWORD_AUTH',
    ClientId: cfg.clientId,
    AuthParameters: { USERNAME: email, PASSWORD: senha },
  });
  if (r.ChallengeName !== 'SOFTWARE_TOKEN_MFA' || !r.Session) {
    const erro = new Error(r.ChallengeName || 'sem desafio');
    erro.codigo = r.ChallengeName === 'MFA_SETUP' ? 'MFA_SETUP' : 'NotAuthorizedException';
    throw erro;
  }
  return r.Session;
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
  if (!token || r.ChallengeName) {
    const erro = new Error('sem token');
    erro.codigo = 'NotAuthorizedException';
    throw erro;
  }
  return token;
}
