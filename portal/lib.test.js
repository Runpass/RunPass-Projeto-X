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
