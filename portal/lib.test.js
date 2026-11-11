import test from 'node:test';
import assert from 'node:assert/strict';
import { dataBr, linkSeguro, mensagem, montarDecisao, resumoPedido, segundosAteExpirar } from './lib.js';

test('montarDecisao: recusar exige motivo e vincular exige corrida', () => {
  assert.throws(() => montarDecisao({ versao: 1, decisao: 'reject', motivo: '   ' }), /motivo/i);
  assert.throws(() => montarDecisao({ versao: 1, decisao: 'link' }), /corrida/i);
  assert.throws(() => montarDecisao({ versao: 'x', decisao: 'link', edicaoId: 'e' }), /Versão/);
  assert.throws(() => montarDecisao({ versao: 1, decisao: 'apagar', edicaoId: 'e' }), /desconhecida/);
  assert.throws(() => montarDecisao({ versao: 1, decisao: 'reject', motivo: 'x'.repeat(501) }), /500/);
  assert.deepEqual(montarDecisao({ versao: 2, decisao: 'reject', motivo: ' duplicada ' }), {
    expectedVersion: 2, decision: 'reject', reason: 'duplicada',
  });
  assert.deepEqual(montarDecisao({ versao: '3', decisao: 'link', edicaoId: 'csv-sp-x' }), {
    expectedVersion: 3, decision: 'link', editionId: 'csv-sp-x',
  });
  // aprovar/vincular nunca levam motivo; recusar nunca leva corrida (o servidor recusaria os dois)
  assert.equal('reason' in montarDecisao({ versao: 1, decisao: 'approve', edicaoId: 'e', motivo: 'm' }), false);
  assert.equal('editionId' in montarDecisao({ versao: 1, decisao: 'reject', motivo: 'm', edicaoId: 'e' }), false);
});

test('linkSeguro aceita só https', () => {
  assert.equal(linkSeguro('https://exemplo.com/a'), 'https://exemplo.com/a');
  for (const ruim of ['javascript:alert(1)', 'http://exemplo.com', 'data:text/html,x', '', 'nao e url', null]) {
    assert.equal(linkSeguro(ruim), null, String(ruim));
  }
});

test('dataBr e resumoPedido', () => {
  assert.equal(dataBr('2026-12-20'), '20/12/2026');
  assert.equal(dataBr('lixo'), '');
  const r = resumoPedido({ details: { name: 'Corrida X', date: '2026-12-20', city: 'São Paulo', state: 'SP', distanceKm: 10, officialUrl: 'https://x.com' } });
  assert.deepEqual(r, { titulo: 'Corrida X', linha: '20/12/2026 · São Paulo/SP · 10 km', fonte: 'https://x.com' });
  assert.equal(resumoPedido({}).titulo, '(sem nome)');
});

test('mensagem traduz códigos conhecidos e não vaza código desconhecido', () => {
  assert.match(mensagem('CodeMismatchException'), /incorreto/);
  assert.match(mensagem('INVALID_TOKEN'), /sessão/);
  assert.equal(mensagem('ALGO_ESTRANHO_INTERNO'), 'Não foi possível concluir. Tente novamente.');
  // Erros do Cognito sem tradução mostram o código (ajuda o suporte); outros códigos seguem ocultos.
  assert.match(mensagem('InvalidParameterException'), /\(InvalidParameterException\)/);
  assert.match(mensagem('PasswordResetRequiredException'), /redefinir/);
  assert.match(mensagem('NetworkError'), /Cognito/);
  assert.match(mensagem('UnsupportedChallenge:SELECT_MFA_TYPE'), /SELECT_MFA_TYPE/);
  assert.equal(mensagem('x<script>Exception'), 'Não foi possível concluir. Tente novamente.');
  assert.equal(mensagem(undefined), 'Não foi possível concluir. Tente novamente.');
});

test('segundosAteExpirar lê o exp do JWT e devolve 0 para token inválido', () => {
  const corpo = Buffer.from(JSON.stringify({ exp: 2000 })).toString('base64url');
  assert.equal(segundosAteExpirar(`a.${corpo}.c`, 1_000_000), 1000);
  assert.equal(segundosAteExpirar(`a.${corpo}.c`, 5_000_000), 0);
  assert.equal(segundosAteExpirar('lixo'), 0);
});

test('cadastros e operadores: resumo, status e e-mail', async () => {
  const { resumoCadastros, statusCadastro, emailValido } = await import('./lib.js');
  assert.equal(resumoCadastros({ total: 3, partial: false, byStatus: { CONFIRMED: 2, UNCONFIRMED: 1 } }), '3 cadastros: 2 confirmado, 1 e-mail não confirmado');
  assert.equal(resumoCadastros({ total: 1, partial: true, byStatus: {} }), '1 cadastro (lista parcial)');
  assert.equal(statusCadastro('XYZ'), 'XYZ');
  assert.ok(emailValido(' a@b.com '));
  assert.ok(!emailValido('sem-arroba'));
  assert.match(mensagem('RUN_TOO_SOON'), /10 minutos/);
});

test('execuções: situação, duração e acompanhamento', async () => {
  const { situacaoExecucao, duracao, ativa } = await import('./lib.js');
  assert.equal(situacaoExecucao('running'), 'Em execução');
  assert.equal(situacaoExecucao('timeout'), 'Tempo esgotado (15 min)');
  assert.equal(duracao(9000), '9s');
  assert.equal(duracao(150000), '2min 30s');
  assert.equal(duracao(undefined), '');
  assert.ok(ativa([{ status: 'done' }, { status: 'waiting' }]));
  assert.ok(!ativa([{ status: 'done' }, { status: 'failed' }]));
});

test('agendamentos: descrição', async () => {
  const { descreverAgendamento } = await import('./lib.js');
  assert.equal(descreverAgendamento({ enabled: false, name: 'x', description: '' }).situacao, 'Desativado');
  assert.equal(descreverAgendamento({ enabled: true, name: 'x', description: 'Calendário', expression: 'rate(1 day)', nextRun: null }).quando, 'Ver expressão: rate(1 day)');
  assert.equal(descreverAgendamento({ enabled: true, name: 'n', description: '', nextRun: '2026-11-16T10:00:00Z' }).oque, 'n');
});

test('custos: formatação, percentual e barras', async () => {
  const { usd, compacto, percentual, barras, mesBr } = await import('./lib.js');
  assert.match(usd(5.5), /^US\$\s5,50$/);
  assert.equal(usd(undefined), '—');
  assert.equal(compacto(1_502_000), '1,5 mi');
  assert.equal(compacto(2500), '2,5 mil');
  assert.equal(compacto(12), '12');
  assert.equal(percentual(5, 10), 50);
  assert.equal(percentual(5, null), null);
  assert.equal(percentual(5, 0), null);
  assert.equal(mesBr('2026-11'), '11/2026');
  const b = barras([0, 5, 10], 300, 100);
  assert.equal(b[2].h, 100);
  assert.equal(b[1].h, 50);
  assert.equal(b[0].h, 0);
  assert.ok(barras([0, 0], 100, 50).every((x) => x.h === 0));
  assert.ok(barras([0.0001, 100], 100, 50)[0].h >= 1); // valor pequeno continua visível
  assert.deepEqual(barras([], 100, 50), []);
});

test('operadores: situação e permissões', async () => {
  const { situacaoOperador, permissoesDe } = await import('./lib.js');
  const ativo = { enabled: true, status: 'CONFIRMED', access: { state: 'active', permissions: ['cost_read'] } };
  assert.equal(situacaoOperador(ativo), 'Ativo');
  assert.deepEqual(permissoesDe(ativo), ['cost_read']);
  assert.equal(situacaoOperador({ ...ativo, enabled: false }), 'Desativado');
  assert.match(situacaoOperador({ enabled: true, access: null }), /Sem acesso/);
  assert.equal(situacaoOperador({ enabled: true, access: { state: 'revoked', permissions: [] } }), 'Acesso retirado');
  assert.equal(situacaoOperador({ ...ativo, status: 'FORCE_CHANGE_PASSWORD' }), 'Convite enviado (ainda não entrou)');
  assert.deepEqual(permissoesDe({ access: null }), []);
  assert.match(mensagem('LAST_ADMIN'), /administrador/);
});

test('banners: nota de direitos padrão e data de hoje', async () => {
  const { notaDireitosPadrao, dataHojeIso } = await import('./lib.js');
  const nota = notaDireitosPadrao('https://o.exemplo/p', '2026-11-10');
  assert.match(nota, /página oficial \(https:\/\/o\.exemplo\/p\)/);
  assert.match(nota, /10\/11\/2026/);
  assert.match(nota, /Sem autorização formal/);
  assert.ok(notaDireitosPadrao('', '2026-11-10').length > 20);
  assert.match(dataHojeIso(new Date('2026-11-10T15:00:00Z')), /^2026-11-10$/);
  assert.match(mensagem('IMAGE_URL_BLOCKED'), /rede interna/);
});

test('motivo da falha da OpenAI vira frase útil sem vazar detalhes', async () => {
  const { motivoOpenAi } = await import('./lib.js');
  assert.match(motivoOpenAi('key_read_failed:ParameterNotFound'), /ParameterNotFound.*SecureString/);
  assert.match(motivoOpenAi('http_401'), /administrador/);
  assert.match(motivoOpenAi('http_403'), /permissão/);
  assert.match(motivoOpenAi('http_400'), /projeto/);
  assert.match(motivoOpenAi('http_500'), /\(500\)/);
  assert.match(motivoOpenAi('network'), /Sem resposta/);
  assert.match(motivoOpenAi('http_429:insufficient_quota'), /sem crédito/);
  assert.match(motivoOpenAi('http_429:rate_limit_exceeded'), /rate_limit_exceeded/);
  assert.match(motivoOpenAi('key_read_failed:ParameterNotFound'), /ParameterNotFound/);
  assert.equal(motivoOpenAi(undefined), 'Motivo não identificado.');
});

test('acesso ao portal: mensagens de conta sem acesso', async () => {
  const { situacaoOperador } = await import('./lib.js');
  assert.match(mensagem('NO_PORTAL_ACCESS'), /não tem acesso ativo/);
  assert.match(mensagem('ACCESS_ALREADY_EXISTS'), /reative/);
  assert.match(situacaoOperador({ enabled: true, access: null }), /Sem acesso ao portal/);
});
