// Lógica pura do portal (sem DOM), testável com `node --test`.

export const MENSAGENS = {
  NotAuthorizedException: 'E-mail ou senha incorretos.',
  UserNotFoundException: 'E-mail ou senha incorretos.',
  CodeMismatchException: 'Código do autenticador incorreto. Digite o código atual.',
  ExpiredCodeException: 'Código expirado. Digite o código atual.',
  TooManyRequestsException: 'Muitas tentativas. Aguarde um pouco.',
  LimitExceededException: 'Muitas tentativas. Aguarde um pouco.',
  PasswordResetRequiredException: 'É preciso redefinir a senha antes de entrar. Peça a um administrador para refazer o acesso (aba Operadores > Refazer senha e autenticador).',
  UserNotConfirmedException: 'Este usuário ainda não foi confirmado. Peça a um administrador para refazer o acesso.',
  NetworkError: 'Não consegui falar com o login (Cognito). Confira a internet, bloqueadores de conteúdo ou VPN e tente de novo.',
  PASSWORD_RESET_REQUIRED: 'É preciso redefinir a senha antes de entrar.',
  MFA_SETUP: 'Este usuário ainda não cadastrou o autenticador (MFA).',
  InvalidPasswordException: 'A senha não atende às regras (12+ caracteres com maiúscula, minúscula, número e símbolo).',
  NO_PORTAL_ACCESS: 'Login correto, mas esta conta não tem acesso ativo ao portal. Peça a um administrador para conceder o acesso (aba Operadores).',
  ACCESS_ALREADY_EXISTS: 'Este operador já tem acesso: altere as permissões ou reative.',
  OPERATOR_EXISTS: 'Já existe um operador com este e-mail.',
  CANNOT_CHANGE_SELF: 'Você não pode alterar o seu próprio acesso. Peça a outro administrador.',
  LAST_ADMIN: 'Esta ação deixaria a conta sem nenhum administrador de usuários ativo.',
  OPERATOR_NOT_FOUND: 'Operador não encontrado.',
  OPERATOR_NOT_ACTIVE: 'O acesso deste operador não está ativo. Reative-o primeiro.',
  INVALID_IMAGE_URL: 'Endereço de imagem inválido: use https, sem usuário e senha.',
  IMAGE_URL_BLOCKED: 'Este endereço aponta para uma rede interna e foi bloqueado.',
  IMAGE_TOO_LARGE: 'A imagem passa de 6 MB.',
  INVALID_IMAGE: 'O arquivo não é uma imagem JPEG, PNG ou WebP válida.',
  IMAGE_FETCH_FAILED: 'Não foi possível baixar a imagem (site fora do ar, bloqueio ou endereço errado).',
  RIGHTS_NOT_CONFIRMED: 'Confirme que a base de autorização informada é verdadeira.',
  EDITION_NOT_FOUND: 'Corrida não encontrada no catálogo.',
  NO_BANNER: 'Esta corrida não tem banner.',
  ACCESS_CONFLICT: 'A conta foi criada, mas a concessão de acesso falhou. Avise o administrador.',
  RUN_TOO_SOON: 'A rotina foi disparada há pouco. Aguarde 10 minutos entre disparos.',
  INVALID_TOKEN: 'Sua sessão expirou ou o acesso foi retirado. Entre de novo.',
  PERMISSION_REQUIRED: 'Você não tem permissão para esta ação.',
  REQUEST_NOT_PENDING: 'Este pedido já foi decidido por outra pessoa.',
  VERSION_CONFLICT: 'O pedido mudou. Atualize a lista e tente de novo.',
  CONCURRENT_RETRY_REQUIRED: 'Outra alteração aconteceu ao mesmo tempo. Tente de novo.',
  EDITION_NOT_LINKABLE: 'Essa corrida não pode receber vínculo (não existe, está arquivada ou não foi aprovada).',
  EDITION_REQUEST_NOT_FOUND: 'Pedido não encontrado.',
  INVALID_INPUT: 'Confira os campos: rejeitar exige um motivo; vincular exige escolher uma corrida.',
  DEPENDENCY_UNAVAILABLE: 'Serviço indisponível agora. Tente de novo em instantes.',
};

export function mensagem(codigo) {
  if (MENSAGENS[codigo]) return MENSAGENS[codigo];
  const c = typeof codigo === 'string' ? codigo : '';
  if (c.startsWith('UnsupportedChallenge:')) {
    return `O login pediu uma etapa que o portal ainda não suporta (${c.slice(21)}). Avise um administrador.`;
  }
  // Códigos do Cognito (terminam em "Exception") ajudam no suporte e não são segredo; os demais ficam ocultos.
  if (/^[A-Za-z]{3,60}Exception$/.test(c)) return `Não foi possível concluir (${c}). Tente novamente ou avise um administrador.`;
  return 'Não foi possível concluir. Tente novamente.';
}

/** Corpo do POST de decisão. Lança Error com texto para a pessoa quando faltar algo. */
export function montarDecisao({ versao, decisao, edicaoId, motivo }) {
  const v = Number(versao);
  if (!Number.isInteger(v) || v < 1) throw new Error('Versão do pedido inválida. Atualize a lista.');
  if (decisao === 'reject') {
    const texto = (motivo || '').trim();
    if (!texto) throw new Error('Informe o motivo da recusa.');
    if (texto.length > 500) throw new Error('O motivo pode ter até 500 caracteres.');
    return { expectedVersion: v, decision: 'reject', reason: texto };
  }
  if (decisao !== 'approve' && decisao !== 'link') throw new Error('Decisão desconhecida.');
  if (!edicaoId) throw new Error('Escolha a corrida do catálogo.');
  return { expectedVersion: v, decision: decisao, editionId: edicaoId };
}

/** "20/12/2026" a partir de "2026-12-20" (sem fuso: data civil). */
export function dataBr(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || '');
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '';
}

export function resumoPedido(p) {
  const d = p.details || {};
  const lugar = [d.city, d.state].filter(Boolean).join('/');
  return {
    titulo: d.name || '(sem nome)',
    linha: [dataBr(d.date), lugar, d.distanceKm ? `${d.distanceKm} km` : ''].filter(Boolean).join(' · '),
    fonte: d.officialUrl || '',
  };
}

/** Só endereços https viram link clicável (nunca javascript: nem data:). */
export function linkSeguro(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' ? u.href : null;
  } catch {
    return null;
  }
}

/** Segundos até o token expirar, lendo o `exp` do JWT (sem validar: quem valida é a API). */
export function segundosAteExpirar(token, agoraMs = Date.now()) {
  try {
    const corpo = JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    return Math.max(0, Math.floor(corpo.exp - agoraMs / 1000));
  } catch {
    return 0;
  }
}

export const PERMISSOES = {
  catalog_admin: 'Catálogo (pedidos de corrida e atualização)',
  moderation: 'Moderação',
  lake_read: 'Leitura de dados analíticos',
  user_admin: 'Usuários (cadastros e operadores)',
  cost_read: 'Custos (AWS e OpenAI)',
};

export const MODOS_CATALOGO = {
  semanal: 'Rotina semanal (séries conhecidas)',
  simulacao: 'Simulação (não grava nada)',
  enriquecer: 'Enriquecer provas do último calendário',
  imagens: 'Coletar imagens candidatas',
};

export const STATUS_CADASTRO = {
  CONFIRMED: 'Confirmado',
  UNCONFIRMED: 'E-mail não confirmado',
  FORCE_CHANGE_PASSWORD: 'Troca de senha pendente',
  RESET_REQUIRED: 'Redefinição pendente',
};

export function statusCadastro(s) {
  return STATUS_CADASTRO[s] || s || '—';
}

export function emailValido(texto) {
  return /^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$/.test((texto || '').trim());
}

/** Resumo "12 cadastros: 10 confirmados, 2 e-mail não confirmado". */
export function resumoCadastros(r) {
  const partes = Object.entries(r.byStatus || {}).map(([s, n]) => `${n} ${statusCadastro(s).toLowerCase()}`);
  return `${r.total} cadastro${r.total === 1 ? '' : 's'}${partes.length ? ': ' + partes.join(', ') : ''}${r.partial ? ' (lista parcial)' : ''}`;
}

export const SITUACAO_EXECUCAO = {
  waiting: 'Aguardando início',
  running: 'Em execução',
  done: 'Concluída',
  failed: 'Terminou com erro',
  timeout: 'Tempo esgotado (15 min)',
  dispatch_failed: 'Não foi possível disparar',
  no_record: 'Sem registro da execução',
  unknown: 'Situação indisponível',
};

export function situacaoExecucao(status) {
  return SITUACAO_EXECUCAO[status] || status || '—';
}

export function duracao(ms) {
  if (!Number.isFinite(ms)) return '';
  const s = Math.round(ms / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}min ${s % 60}s`;
}

/** "10/11/2026 12:30" no fuso de São Paulo, a partir de "2026-11-10T15:30:00Z". */
export function dataHoraBr(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' });
}

export function ativa(execucoes) {
  return execucoes.some((e) => e.status === 'waiting' || e.status === 'running');
}

/** Linha da tabela de agendamentos: quando, o que faz e a situação. */
export function descreverAgendamento(a) {
  let quando = 'Desativado';
  if (a.enabled) quando = a.nextRun ? dataHoraBr(a.nextRun) : `Ver expressão: ${a.expression}`;
  return {
    quando,
    oque: a.description || a.name,
    situacao: a.enabled ? 'Ativo' : 'Desativado',
  };
}

export function usd(v) {
  return Number.isFinite(v) ? `US$ ${v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}` : '—';
}

export function compacto(n) {
  if (!Number.isFinite(n)) return '—';
  if (n >= 1e6) return `${(n / 1e6).toLocaleString('pt-BR', { maximumFractionDigits: 2 })} mi`;
  if (n >= 1e3) return `${(n / 1e3).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} mil`;
  return String(n);
}

/** Percentual inteiro de `valor` sobre `limite` (sem limite = null). */
export function percentual(valor, limite) {
  return Number.isFinite(valor) && Number.isFinite(limite) && limite > 0 ? Math.round((valor / limite) * 100) : null;
}

/** Retângulos de um gráfico de barras: valores -> {x, y, w, h} dentro de largura x altura. */
export function barras(valores, largura, altura) {
  const maximo = Math.max(...valores, 0);
  const n = valores.length || 1;
  const passo = largura / n;
  return valores.map((v, i) => {
    const h = maximo > 0 ? Math.max(v > 0 ? 1 : 0, (v / maximo) * altura) : 0;
    return { x: i * passo + passo * 0.1, y: altura - h, w: passo * 0.8, h };
  });
}

/** "2026-11" -> "11/2026". */
export function mesBr(m) {
  const [a, b] = (m || '').split('-');
  return a && b ? `${b}/${a}` : '';
}

export function situacaoOperador(o) {
  if (!o.enabled) return 'Desativado';
  const estado = o.access && o.access.state;
  if (!estado) return 'Sem acesso ao portal (conta existe)';
  if (estado === 'revoked') return 'Acesso retirado';
  if (o.status === 'FORCE_CHANGE_PASSWORD') return 'Convite enviado (ainda não entrou)';
  return 'Ativo';
}

export function permissoesDe(o) {
  return (o.access && o.access.permissions) || [];
}

/** Texto inicial da base de autorização: a pessoa lê, ajusta e só então confirma que é verdadeiro. */
export function notaDireitosPadrao(paginaOficial, hojeIso) {
  const [a, m, d] = (hojeIso || '').split('-');
  const data = a && m && d ? `${d}/${m}/${a}` : '';
  const origem = paginaOficial ? ` (${paginaOficial})` : '';
  return `Imagem de divulgação publicada pelo organizador na página oficial${origem}. Sem autorização formal; risco assumido pelo responsável do produto em ${data}. Remover a pedido do organizador.`;
}

export function dataHojeIso(agora = new Date()) {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(agora);
  return p;
}

/** Motivo (código curto vindo da API) -> frase para a pessoa. Nunca mostra detalhes da chave. */
export function motivoOpenAi(codigo) {
  const c = codigo || '';
  const [base, detalhe] = c.split(':');
  if (base === 'http_429' && detalhe === 'insufficient_quota') {
    return 'A OpenAI recusou por cota: a conta está sem crédito ou estourou o limite de gasto. Confira Billing e Limits no console.';
  }
  if (base === 'http_429' && detalhe) {
    return `A OpenAI limitou as consultas (${detalhe}). Tente de novo em instantes.`;
  }
  if (c.startsWith('key_read_failed')) {
    const tipo = c.split(':')[1] || '';
    return `Não consegui ler a chave no SSM (${tipo || 'erro'}): confira o nome do parâmetro, se ele é SecureString e se a região é sa-east-1.`;
  }
  const mapa = {
    empty_key: 'O parâmetro do SSM está vazio.',
    http_401: 'A OpenAI recusou a chave: ela é inválida, foi revogada ou não é uma chave de administrador (sk-admin-...).',
    http_403: 'A OpenAI recusou a chave: ela não tem permissão para ler custos e uso.',
    http_400: 'A OpenAI recusou a consulta (confira o ID do projeto, proj_...).',
    http_404: 'A OpenAI não encontrou o recurso (confira o ID do projeto, proj_...).',
    http_429: 'A OpenAI limitou as consultas agora. Tente de novo em instantes.',
    network: 'Sem resposta da OpenAI agora.',
    not_configured: 'A chave de administrador não está configurada neste deploy.',
  };
  if (mapa[c]) return mapa[c];
  return c.startsWith('http_') ? `A OpenAI respondeu com erro (${c.slice(5)}).` : 'Motivo não identificado.';
}

/** "42 de 44 (95%)": parte, total e porcentagem inteira; sem total válido, só o número. */
export function taxa(parte, total) {
  if (!Number.isFinite(parte)) return '—';
  if (!Number.isFinite(total) || total <= 0) return String(parte);
  return `${parte} de ${total} (${Math.round((parte / total) * 100)}%)`;
}

export const RESULTADO_CONFERENCIA = {
  confere: 'Confere',
  parcial: 'Confere em parte',
  nao_verificado: 'Não verificado',
  errada: 'Errada',
};
