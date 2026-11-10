// Lógica pura do portal (sem DOM), testável com `node --test`.

export const MENSAGENS = {
  NotAuthorizedException: 'E-mail ou senha incorretos.',
  UserNotFoundException: 'E-mail ou senha incorretos.',
  CodeMismatchException: 'Código do autenticador incorreto. Digite o código atual.',
  ExpiredCodeException: 'Código expirado. Digite o código atual.',
  TooManyRequestsException: 'Muitas tentativas. Aguarde um pouco.',
  LimitExceededException: 'Muitas tentativas. Aguarde um pouco.',
  PASSWORD_RESET_REQUIRED: 'É preciso redefinir a senha antes de entrar.',
  MFA_SETUP: 'Este usuário ainda não cadastrou o autenticador (MFA).',
  InvalidPasswordException: 'A senha não atende às regras (12+ caracteres com maiúscula, minúscula, número e símbolo).',
  OPERATOR_EXISTS: 'Já existe um operador com este e-mail.',
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
  return MENSAGENS[codigo] || 'Não foi possível concluir. Tente novamente.';
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
