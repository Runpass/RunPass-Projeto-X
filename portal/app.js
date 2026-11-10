import cfg from './config.js';
import { concluirAutenticador, confirmarMfa, definirSenha, entrar, iniciarAutenticador } from './cognito.js';
import {
  MODOS_CATALOGO, PERMISSOES, ativa, dataHoraBr, duracao, situacaoExecucao, emailValido, linkSeguro, mensagem, montarDecisao, resumoCadastros,
  resumoPedido, segundosAteExpirar, statusCadastro,
} from './lib.js';

// O token fica só em memória: recarregar a página ou fechar a aba encerra a sessão.
let token = null;
let temporizador = null;
let sessaoMfa = null;
let emailTentativa = '';

const $ = (id) => document.getElementById(id);

/** Cria elementos sem innerHTML: todo texto vindo da API entra como texto, nunca como HTML. */
function el(tag, atributos = {}, ...filhos) {
  const nó = document.createElement(tag);
  for (const [chave, valor] of Object.entries(atributos)) {
    if (chave === 'class') nó.className = valor;
    else if (chave.startsWith('on')) nó.addEventListener(chave.slice(2), valor);
    else if (valor !== false && valor != null) nó.setAttribute(chave, valor === true ? '' : valor);
  }
  for (const filho of filhos.flat()) nó.append(filho instanceof Node ? filho : String(filho ?? ''));
  return nó;
}

function aviso(texto, tipo = '') {
  const caixa = $('aviso');
  caixa.hidden = !texto;
  caixa.textContent = texto || '';
  caixa.className = `aviso ${tipo}`;
}

async function api(caminho, opcoes = {}) {
  const resposta = await fetch(cfg.apiUrl + caminho, {
    ...opcoes,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(opcoes.body ? { 'Content-Type': 'application/json' } : {}),
    },
  });
  const json = await resposta.json().catch(() => ({}));
  if (resposta.status === 401) {
    sair('INVALID_TOKEN');
    throw new Error('sessão');
  }
  if (!resposta.ok) {
    const erro = new Error(json.code || 'erro');
    erro.codigo = json.code;
    throw erro;
  }
  return json;
}

function sair(motivo) {
  token = null;
  sessaoMfa = null;
  clearInterval(temporizador);
  clearTimeout(acompanhar);
  $('painel').hidden = true;
  $('sessao').hidden = true;
  $('entrar').hidden = false;
  etapa('senha');
  $('segredo').textContent = '';
  $('cadastros').replaceChildren();
  $('senha').value = '';
  $('codigo').value = '';
  $('pedidos').replaceChildren();
  aviso(motivo ? mensagem(motivo) : '', motivo ? 'erro' : '');
}

function iniciarSessao(t, assunto) {
  token = t;
  $('entrar').hidden = true;
  $('painel').hidden = false;
  $('sessao').hidden = false;
  $('quem').textContent = assunto;
  clearInterval(temporizador);
  const tick = () => {
    const restante = segundosAteExpirar(token);
    if (restante <= 30) return sair('INVALID_TOKEN');
    $('expira').textContent = `Sessão expira em ${Math.ceil(restante / 60)} min`;
  };
  tick();
  temporizador = setInterval(tick, 15000);
}

// ---- pedidos de corrida -----------------------------------------------------------------------

async function carregarPedidos() {
  const lista = $('pedidos');
  lista.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const { items } = await api('/admin/edition-requests');
    lista.replaceChildren(
      ...(items.length
        ? items.map(cartaoPedido)
        : [el('p', { class: 'vazio' }, 'Nenhum pedido pendente.')]),
    );
  } catch (erro) {
    if (token) {
      lista.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

function cartaoPedido(pedido) {
  const resumo = resumoPedido(pedido);
  const link = linkSeguro(resumo.fonte);
  const area = el('div');
  const cartao = el(
    'article',
    { class: 'cartao' },
    el('h2', {}, resumo.titulo),
    el('div', { class: 'linha' }, resumo.linha),
    link
      ? el('div', { class: 'meta' }, 'Fonte informada: ', el('a', { href: link, target: '_blank', rel: 'noopener noreferrer' }, link))
      : '',
    el('div', { class: 'meta' }, `Pedido ${pedido.id} · versão ${pedido.version}`),
    el(
      'div',
      { class: 'acoes' },
      el('button', { type: 'button', onclick: () => painelVinculo(area, pedido, 'link') }, 'Vincular a corrida existente'),
      el('button', { type: 'button', class: 'ok', onclick: () => painelVinculo(area, pedido, 'approve') }, 'Aprovar (corrida já importada)'),
      el('button', { type: 'button', class: 'perigo', onclick: () => painelRecusa(area, pedido) }, 'Recusar'),
    ),
    area,
  );
  return cartao;
}

async function decidir(pedido, corpo, botao) {
  botao.disabled = true;
  try {
    const decisao = montarDecisao({ versao: pedido.version, ...corpo });
    await api(`/admin/edition-requests/${encodeURIComponent(pedido.id)}/decision`, {
      method: 'POST',
      body: JSON.stringify(decisao),
    });
    aviso('Pedido decidido.', 'ok');
    await carregarPedidos();
  } catch (erro) {
    botao.disabled = false;
    if (token) aviso(erro.codigo ? mensagem(erro.codigo) : erro.message, 'erro');
  }
}

function painelVinculo(area, pedido, decisao) {
  let escolhida = null;
  const resultados = el('ul', { class: 'escolhas', role: 'listbox' });
  const confirmar = el('button', { type: 'button', class: 'ok', disabled: true }, decisao === 'link' ? 'Vincular' : 'Aprovar');
  const busca = el('input', { type: 'search', placeholder: 'Nome da corrida no catálogo', maxlength: '160', value: (pedido.details || {}).name || '' });
  let aguardando = null;

  const pesquisar = async () => {
    escolhida = null;
    confirmar.disabled = true;
    try {
      const { items } = await api(`/admin/editions?q=${encodeURIComponent(busca.value.trim())}&limit=20`);
      resultados.replaceChildren(
        ...(items.length
          ? items.map((e) => {
              const li = el('li', { role: 'option', 'aria-selected': 'false', tabindex: '0' }, `${e.name} · ${e.date} · ${e.city}/${e.state}`);
              const marcar = () => {
                for (const outro of resultados.children) outro.setAttribute('aria-selected', 'false');
                li.setAttribute('aria-selected', 'true');
                escolhida = e.id;
                confirmar.disabled = false;
              };
              li.addEventListener('click', marcar);
              li.addEventListener('keydown', (ev) => ev.key === 'Enter' && marcar());
              return li;
            })
          : [el('li', {}, 'Nenhuma corrida encontrada. Importe a corrida antes de aprovar o pedido.')]),
      );
    } catch (erro) {
      if (token) aviso(mensagem(erro.codigo), 'erro');
    }
  };
  busca.addEventListener('input', () => {
    clearTimeout(aguardando);
    aguardando = setTimeout(pesquisar, 350);
  });
  confirmar.addEventListener('click', () => decidir(pedido, { decisao: decisao, edicaoId: escolhida }, confirmar));
  area.replaceChildren(
    el('label', {}, decisao === 'link' ? 'Corrida do catálogo que este pedido repete:' : 'Corrida do catálogo criada a partir do pedido:', busca),
    resultados,
    confirmar,
  );
  pesquisar();
}

function painelRecusa(area, pedido) {
  const motivo = el('textarea', { rows: '3', maxlength: '500', placeholder: 'Motivo (a pessoa que pediu vai ler)' });
  const confirmar = el('button', { type: 'button', class: 'perigo' }, 'Confirmar recusa');
  confirmar.addEventListener('click', () => decidir(pedido, { decisao: 'reject', motivo: motivo.value }, confirmar));
  area.replaceChildren(el('label', {}, 'Motivo da recusa', motivo), confirmar);
}

// ---- cadastros, operadores e atualização do catálogo ------------------------------------------

let permissoes = [];

function mostrarAba(nome) {
  for (const b of document.querySelectorAll('[data-aba]')) b.setAttribute('aria-selected', String(b.dataset.aba === nome));
  for (const s of document.querySelectorAll('[data-sec]')) s.hidden = s.dataset.sec !== nome;
  aviso('');
  if (nome === 'pedidos') carregarPedidos();
  if (nome === 'catalogo') carregarUltimoDisparo();
  if (nome === 'cadastros') carregarCadastros();
}

async function carregarCadastros() {
  const alvo = $('cadastros');
  alvo.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const r = await api('/admin/users/runners');
    $('resumo-cadastros').textContent = resumoCadastros(r);
    alvo.replaceChildren(
      r.items.length
        ? el(
            'table',
            { class: 'tabela' },
            el('thead', {}, el('tr', {}, el('th', {}, 'Cadastro'), el('th', {}, 'E-mail'), el('th', {}, 'Situação'), el('th', {}, 'Criado em'))),
            el('tbody', {}, r.items.map((u) => el('tr', {}, el('td', {}, u.id), el('td', {}, u.email), el('td', {}, statusCadastro(u.status) + (u.enabled ? '' : ' (desativado)')), el('td', {}, (u.createdAt || '').slice(0, 10).split('-').reverse().join('/'))))),
          )
        : el('p', { class: 'vazio' }, 'Nenhum cadastro ainda.'),
    );
  } catch (erro) {
    if (token) {
      alvo.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

let acompanhar = null;

async function carregarExecucoes() {
  clearTimeout(acompanhar);
  try {
    const r = await api('/admin/catalog/runs');
    const linhas = r.items.map((e) =>
      el(
        'tr',
        {},
        el('td', {}, dataHoraBr(e.at)),
        el('td', {}, e.origin === 'portal' ? `Portal · ${MODOS_CATALOGO[e.mode] || e.mode}` : 'Agendada'),
        el('td', {}, e.by ? e.by.slice(0, 8) : '—'),
        el('td', {}, situacaoExecucao(e.status)),
        el('td', {}, duracao(e.durationMs)),
      ),
    );
    $('execucoes').replaceChildren(
      linhas.length
        ? el('table', { class: 'tabela' }, el('thead', {}, el('tr', {}, ['Início', 'Origem', 'Por', 'Situação', 'Duração'].map((t) => el('th', {}, t)))), el('tbody', {}, linhas))
        : el('p', { class: 'vazio' }, 'Nenhuma execução nos últimos 7 dias.'),
      r.logsAvailable ? '' : el('p', { class: 'meta' }, 'Os registros da rotina não puderam ser lidos agora; a lista mostra só os disparos.'),
    );
    if (token && ativa(r.items) && !$('sec-catalogo').hidden) acompanhar = setTimeout(carregarExecucoes, 20000);
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

async function carregarUltimoDisparo() {
  carregarExecucoes();
  try {
    const { last } = await api('/admin/catalog/run');
    $('ultimo-disparo').textContent = last
      ? `Último disparo: ${MODOS_CATALOGO[last.mode] || last.mode} em ${last.startedAt.replace('T', ' ').replace('Z', ' UTC')}`
      : 'Nenhum disparo registrado.';
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

$('rodar').addEventListener('click', async () => {
  const modo = $('modo-catalogo').value;
  if (!window.confirm(`Disparar agora: ${MODOS_CATALOGO[modo]}? Usa a cota da OpenAI.`)) return;
  $('rodar').disabled = true;
  try {
    await api('/admin/catalog/run', { method: 'POST', body: JSON.stringify({ mode: modo }) });
    aviso('Rotina disparada. Ela roda em segundo plano; os resultados chegam em revisão.', 'ok');
    await carregarUltimoDisparo();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  } finally {
    $('rodar').disabled = false;
  }
});

$('form-operador').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const email = $('op-email').value.trim();
  const escolhidas = [...document.querySelectorAll('#op-permissoes input:checked')].map((i) => i.value);
  if (!emailValido(email) || !escolhidas.length) return aviso('Informe um e-mail válido e ao menos uma permissão.', 'erro');
  if (!window.confirm(`Criar o operador ${email} com: ${escolhidas.join(', ')}?`)) return;
  try {
    const r = await api('/admin/operators', { method: 'POST', body: JSON.stringify({ email, permissions: escolhidas }) });
    aviso(`Operador criado (${r.email}). Ele recebeu um e-mail com a senha temporária.`, 'ok');
    $('form-operador').reset();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
});

function prepararAbas() {
  const abas = { pedidos: 'catalog_admin', catalogo: 'catalog_admin', cadastros: 'user_admin', operadores: 'user_admin' };
  for (const [nome, perm] of Object.entries(abas)) $(`aba-${nome}`).hidden = !permissoes.includes(perm);
  $('modo-catalogo').replaceChildren(...Object.entries(MODOS_CATALOGO).map(([v, t]) => el('option', { value: v }, t)));
  $('op-permissoes').replaceChildren(
    el('legend', {}, 'Permissões'),
    ...Object.entries(PERMISSOES).map(([v, t]) => el('label', {}, el('input', { type: 'checkbox', value: v }), t)),
  );
  mostrarAba(permissoes.includes('catalog_admin') ? 'pedidos' : permissoes.includes('user_admin') ? 'cadastros' : '');
}

for (const b of document.querySelectorAll('[data-aba]')) b.addEventListener('click', () => mostrarAba(b.dataset.aba));

// ---- login --------------------------------------------------------------------------------------

function etapa(nome) {
  for (const id of ['form-senha', 'form-nova', 'form-setup', 'form-mfa']) $(id).hidden = id !== `form-${nome}`;
}

async function abrirPainel(t) {
  iniciarSessao(t, emailTentativa);
  const info = await api('/admin/session');
  permissoes = info.permissions || [];
  if (!permissoes.some((p) => p === 'catalog_admin' || p === 'user_admin')) {
    aviso('Seu acesso não inclui permissão para este portal. Peça a ativação.', 'erro');
    return;
  }
  prepararAbas();
}

$('form-senha').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  aviso('');
  emailTentativa = $('email').value.trim();
  try {
    const r = await entrar(cfg, emailTentativa, $('senha').value);
    sessaoMfa = r.sessao;
    if (r.desafio === 'mfa_setup') {
      const s = await iniciarAutenticador(cfg, sessaoMfa);
      sessaoMfa = s.sessao;
      $('segredo').textContent = s.segredo;
    }
    $('senha').value = '';
    etapa({ mfa: 'mfa', nova_senha: 'nova', mfa_setup: 'setup' }[r.desafio]);
    $({ mfa: 'codigo', nova_senha: 'nova-senha', mfa_setup: 'codigo-setup' }[r.desafio]).focus();
  } catch (erro) {
    aviso(mensagem(erro.codigo), 'erro');
  }
});

$('form-nova').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  aviso('');
  try {
    sessaoMfa = await definirSenha(cfg, emailTentativa, sessaoMfa, $('nova-senha').value);
    $('nova-senha').value = '';
    const s = await iniciarAutenticador(cfg, sessaoMfa);
    sessaoMfa = s.sessao;
    $('segredo').textContent = s.segredo;
    etapa('setup');
    $('codigo-setup').focus();
  } catch (erro) {
    aviso(mensagem(erro.codigo), 'erro');
    if (erro.codigo !== 'InvalidPasswordException') voltarAoInicio();
  }
});

$('form-setup').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  aviso('');
  try {
    const t = await concluirAutenticador(cfg, emailTentativa, sessaoMfa, $('codigo-setup').value.trim());
    $('segredo').textContent = '';
    $('codigo-setup').value = '';
    await abrirPainel(t);
  } catch (erro) {
    if (token) return;
    aviso(mensagem(erro.codigo), 'erro');
    if (erro.codigo !== 'CodeMismatchException' && erro.codigo !== 'ExpiredCodeException') voltarAoInicio();
  }
});

function voltarAoInicio() {
  sessaoMfa = null;
  $('segredo').textContent = '';
  etapa('senha');
}

$('form-mfa').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  aviso('');
  try {
    const t = await confirmarMfa(cfg, emailTentativa, sessaoMfa, $('codigo').value.trim());
    await abrirPainel(t);
  } catch (erro) {
    if (token) return;
    aviso(mensagem(erro.codigo), 'erro');
    if (erro.codigo === 'CodeMismatchException' || erro.codigo === 'ExpiredCodeException') return;
    voltarAoInicio();
  }
});

$('voltar').addEventListener('click', () => sair());
$('sair').addEventListener('click', () => sair());
$('atualizar').addEventListener('click', carregarPedidos);
$('atualizar-cadastros').addEventListener('click', carregarCadastros);
$('atualizar-execucoes').addEventListener('click', carregarExecucoes);
