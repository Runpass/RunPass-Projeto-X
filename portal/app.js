import cfg from './config.js';
import { concluirAutenticador, confirmarMfa, definirSenha, entrar, iniciarAutenticador } from './cognito.js';
import {
  dataBr, motivoOpenAi, RESULTADO_CONFERENCIA, taxa, DIAS_SEMANA, TIPOS_AGENDAMENTO, TIPO_DIVERGENCIA, textoRevocacao, ABAS, TEMAS, lerPrefs, abaInicial, listaKm, validarDecisao, MAX_PROVAS_POR_EXECUCAO, TIPOS_FONTE, NIVEIS_FONTE, VERIFICACAO_FONTE, idFonte, validarFonte, quandoTexto, validarAgendamento, montarAprovacao, textoAprovacao, montarPublicacaoBanner, MODOS_CATALOGO, PERMISSOES, dataHojeIso, notaDireitosPadrao, permissoesDe, situacaoOperador, barras, compacto, mesBr, percentual, usd, ativa, dataHoraBr, descreverAgendamento, duracao, situacaoExecucao, emailValido, linkSeguro, mensagem, montarDecisao, resumoCadastros,
  resumoPedido, segundosAteExpirar, statusCadastro, montarBannerArquivo, dimensoesEnvio, resumoImporte,
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
    const sessao = new Error('sessão');
    sessao.tratado = true; // a mensagem ja foi mostrada: os formulários de login não a sobrescrevem
    throw sessao;
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
  $('custos').replaceChildren();
  $('divergencias').replaceChildren();
  $('fontes').replaceChildren();
  $('fonte-nova').replaceChildren();
  $('operadores').replaceChildren();
  $('banners-candidatas').replaceChildren();
  $('banner-manual').replaceChildren();
  $('banners-publicados').replaceChildren();
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
    const { items, awaiting, images, linkedNow } = await api('/admin/edition-requests');
    const espera = awaiting || [];
    const banners = images || [];
    if (linkedNow) aviso(`${linkedNow} pedido(s) que aguardavam foram vinculados automaticamente.`, 'ok');
    lista.replaceChildren(
      el('h2', {}, 'Pendentes de decisão'),
      ...(items.length ? items.map((p) => cartaoPedido(p)) : [el('p', { class: 'vazio' }, 'Nenhum pedido pendente.')]),
      ...(banners.length
        ? [
            el('h2', {}, 'Banners sugeridos por usuários'),
            el('p', { class: 'ajuda' }, 'Nada é publicado sem a sua decisão: confira a imagem, informe o crédito e a base de autorização, e só então publique. Publicar substitui o banner atual da corrida, se houver.'),
            ...banners.map(cartaoBanner),
          ]
        : []),
      ...(espera.length
        ? [
            el('h2', {}, 'Aprovados, aguardando a carga da corrida'),
            el('p', { class: 'ajuda' }, 'Faltava o estado para criar a corrida. Quando ela entrar no catálogo, o vínculo é feito sozinho; ou complete aqui e crie agora.'),
            ...espera.map((p) => cartaoPedido(p, true)),
          ]
        : []),
    );
  } catch (erro) {
    if (token) {
      lista.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

async function verificarVinculos() {
  try {
    const r = await api('/admin/edition-requests/sweep', { method: 'POST' });
    aviso(r.linked ? `${r.linked} pedido(s) vinculado(s). Ainda aguardando: ${r.waiting}.` : `Nenhum vínculo novo. Aguardando a carga: ${r.waiting}.`, 'ok');
    await carregarPedidos();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

/** Carrega a imagem enviada no pedido (rota protegida) e a mostra em `alvo`. */
async function carregarImagemPedido(id, alvo) {
  try {
    const r = await fetch(`${cfg.apiUrl}/admin/edition-requests/${encodeURIComponent(id)}/image`, { headers: { Authorization: `Bearer ${token}` } });
    if (r.status === 401) return sair('INVALID_TOKEN');
    if (!r.ok) throw new Error('erro');
    alvo.replaceChildren(el('img', { class: 'previa', src: URL.createObjectURL(await r.blob()), alt: 'Banner enviado pelo usuário' }));
  } catch (falha) {
    if (token) alvo.replaceChildren(el('p', { class: 'aviso erro' }, 'Não foi possível carregar a imagem enviada.'));
  }
}

function cartaoBanner(pedido) {
  const d = pedido.details || {};
  const e = pedido.edition || {};
  const previa = el('div', {}, el('p', { class: 'meta' }, 'Carregando a imagem...'));
  carregarImagemPedido(pedido.id, previa);
  const credito = el('input', { type: 'text', maxlength: '200', placeholder: 'ex.: Divulgação: Organizador', autocomplete: 'off' });
  const nota = el('textarea', { rows: '3', maxlength: '1000', placeholder: 'Como o direito de uso foi obtido (fica só no registro interno)' });
  const confirmar = el('input', { type: 'checkbox' });
  const erro = el('p', { class: 'aviso erro', hidden: true });
  const publicar = el('button', { type: 'button', class: 'ok' }, 'Publicar banner');
  const descartar = el('button', { type: 'button', class: 'perigo' }, 'Descartar');
  publicar.addEventListener('click', async () => {
    let corpo;
    try {
      corpo = montarPublicacaoBanner({ credito: credito.value, nota: nota.value, confirmou: confirmar.checked });
      erro.hidden = true;
    } catch (falha) {
      erro.hidden = false;
      erro.textContent = falha.message;
      return;
    }
    if (!window.confirm('Publicar PUBLICA esta imagem como banner da corrida, com o crédito informado. Confirmar?')) return;
    publicar.disabled = descartar.disabled = true;
    try {
      await api(`/admin/edition-requests/${encodeURIComponent(pedido.id)}/banner`, { method: 'POST', body: JSON.stringify(corpo) });
      aviso('Banner publicado.', 'ok');
      await carregarPedidos();
    } catch (falha) {
      publicar.disabled = descartar.disabled = false;
      if (token) {
        erro.hidden = false;
        erro.textContent = falha.codigo ? mensagem(falha.codigo) : falha.message;
      }
    }
  });
  descartar.addEventListener('click', async () => {
    const motivo = window.prompt('Descartar este banner (nada é publicado). Motivo, opcional:', '');
    if (motivo === null) return;
    publicar.disabled = descartar.disabled = true;
    try {
      await api(`/admin/edition-requests/${encodeURIComponent(pedido.id)}/banner/dismiss`, { method: 'POST', body: JSON.stringify({ reason: motivo.trim() }) });
      aviso('Banner descartado.', 'ok');
      await carregarPedidos();
    } catch (falha) {
      publicar.disabled = descartar.disabled = false;
      if (token) aviso(falha.codigo ? mensagem(falha.codigo) : falha.message, 'erro');
    }
  });
  return el(
    'article',
    { class: 'cartao' },
    el('h2', {}, e.name || d.name || '(corrida)'),
    el('div', { class: 'linha' }, [e.date ? dataBr(e.date) : '', [e.city, e.state].filter(Boolean).join('/')].filter(Boolean).join(' · ')),
    pedido.kind === 'banner' ? el('div', { class: 'meta' }, 'Sugestão de banner enviada por um usuário para esta corrida já cadastrada.') : '',
    pedido.editionHasBanner ? el('div', { class: 'aviso' }, 'Esta corrida já tem banner: publicar substitui.') : '',
    previa,
    el('label', {}, 'Crédito (aparece no app)', credito),
    el('label', {}, 'Base de autorização (como você obteve o direito de usar; fica só no registro interno)', nota),
    el('label', { class: 'confirma' }, confirmar, ' Confirmo que a base de autorização acima é verdadeira.'),
    erro,
    el('div', { class: 'acoes' }, publicar, descartar),
  );
}

function cartaoPedido(pedido, aguardando = false) {
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
    ...(((pedido.details || {}).imageReference)
      ? (() => {
          const medalha = !!(pedido.details || {}).medalPhoto;
          const caixa = el('div', {}, el('p', { class: 'meta' }, medalha ? 'Carregando a foto da medalha...' : 'Carregando o banner enviado...'));
          carregarImagemPedido(pedido.id, caixa);
          return [
            el(
              'div',
              { class: 'meta' },
              medalha
                ? 'Foto da MEDALHA do usuário (medalha provisória: é privada, não é banner e não será publicada; serve para conferir a corrida):'
                : 'Banner enviado pelo usuário (só entra na fila de publicação depois que o pedido for aprovado e vinculado):',
            ),
            caixa,
          ];
        })()
      : []),
    el(
      'div',
      { class: 'acoes' },
      el('button', { type: 'button', class: 'ok', onclick: () => painelAprovacao(area, pedido, aguardando) }, aguardando ? 'Completar e criar a corrida' : 'Aprovar e criar a corrida'),
      el('button', { type: 'button', class: 'sec', onclick: () => painelVinculo(area, pedido, 'link') }, 'Vincular a corrida existente'),
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

/** Aprova: cria a corrida com os dados do pedido (a equipe confere estado e distâncias) e vincula o usuário. */
function painelAprovacao(area, pedido, aguardando) {
  const d = pedido.details || {};
  const estado = el('input', { type: 'text', maxlength: '2', placeholder: 'UF, ex.: SP', autocomplete: 'off', value: d.state || '' });
  const distancias = el('input', { type: 'text', maxlength: '80', placeholder: 'ex.: 5, 10', autocomplete: 'off', value: d.distanceKm ? String(d.distanceKm) : '' });
  const erro = el('p', { class: 'aviso erro', hidden: true });
  // Banner opcional, enviado como arquivo junto com a aprovação (credito e autorizacao obrigatorios).
  const arquivo = el('input', { type: 'file', accept: 'image/png,image/jpeg,image/webp' });
  const credito = el('input', { type: 'text', maxlength: '200', placeholder: 'ex.: Divulgação: Organizador', autocomplete: 'off' });
  const nota = el('textarea', { rows: '3', maxlength: '1000', placeholder: 'Como o direito de uso foi obtido (fica só no registro interno)' });
  const confirmaDireito = el('input', { type: 'checkbox' });
  const previaBanner = el('div');
  let pronto = null;
  arquivo.addEventListener('change', async () => {
    pronto = null;
    previaBanner.replaceChildren(el('p', { class: 'meta' }, 'Preparando a imagem...'));
    try {
      pronto = await prepararArquivo(arquivo.files[0]);
      previaBanner.replaceChildren(pronto ? el('img', { class: 'previa', src: pronto.previa, alt: 'Prévia do banner' }) : '');
    } catch (falha) {
      previaBanner.replaceChildren(el('p', { class: 'aviso erro' }, falha.message));
    }
  });
  const confirmar = el('button', { type: 'button', class: 'ok' }, aguardando ? 'Criar a corrida e vincular' : 'Aprovar');
  confirmar.addEventListener('click', async () => {
    let corpo;
    let corpoBanner = null;
    try {
      corpo = montarAprovacao({ versao: pedido.version, estado: estado.value, distancias: distancias.value });
      // Valida o banner ANTES de criar a corrida, para não criar e depois falhar.
      if (pronto) corpoBanner = montarBannerArquivo({ editionId: 'a-definir', base64: pronto.base64, tipo: pronto.tipo, credito: credito.value, nota: nota.value, confirmou: confirmaDireito.checked });
      erro.hidden = true;
    } catch (falha) {
      erro.hidden = false;
      erro.textContent = falha.message;
      return;
    }
    confirmar.disabled = true;
    try {
      const r = await api(`/admin/edition-requests/${encodeURIComponent(pedido.id)}/approve`, { method: 'POST', body: JSON.stringify(corpo) });
      aviso(textoAprovacao(r.outcome), 'ok');
      const editionId = r.request && r.request.linkedEditionId;
      if (corpoBanner && editionId) {
        try {
          await api('/admin/banners/approve', { method: 'POST', body: JSON.stringify({ ...corpoBanner, editionId }) });
          aviso('Corrida aprovada e banner publicado.', 'ok');
        } catch (falha) {
          aviso(`A corrida foi aprovada, mas o banner NÃO foi publicado (${falha.codigo ? mensagem(falha.codigo) : falha.message}). Envie na aba Banners.`, 'erro');
        }
      } else if (corpoBanner) {
        aviso('O banner não foi enviado porque a corrida ainda não existe no catálogo. Envie na aba Banners depois.', 'erro');
      }
      await carregarPedidos();
    } catch (falha) {
      confirmar.disabled = false;
      if (!token) return;
      erro.hidden = false;
      erro.textContent = falha.codigo ? mensagem(falha.codigo) : falha.message;
    }
  });
  area.replaceChildren(
    el('p', { class: 'meta' }, `A corrida será criada como "${d.name || ''}", ${dataBr(d.date)}, ${d.city || ''}. A distância veio do usuário, sem fonte: confira antes de aprovar.`),
    el('label', {}, 'Estado (UF)', estado),
    el('label', {}, 'Distâncias em km (separe por vírgula)', distancias),
    el('p', { class: 'meta' }, 'Se a mesma corrida já estiver no catálogo (mesma data e nome parecido), o usuário é só vinculado a ela. Sem o estado, o pedido fica aguardando a carga.'),
    el('fieldset', {}, el('legend', {}, 'Banner da corrida (opcional)'),
      el('label', {}, 'Arquivo da imagem (JPEG, PNG ou WebP)', arquivo),
      previaBanner,
      el('label', {}, 'Crédito (aparece no app)', credito),
      el('label', {}, 'Base de autorização (como você obteve o direito de usar; fica só no registro interno)', nota),
      el('label', { class: 'confirma' }, confirmaDireito, ' Confirmo que a base de autorização acima é verdadeira.'),
    ),
    erro,
    confirmar,
  );
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

// ---- divergências ---------------------------------------------------------------------------------

async function baixarAceitas() {
  try {
    const resposta = await fetch(cfg.apiUrl + '/admin/divergences/accepted.csv', { headers: { Authorization: `Bearer ${token}` } });
    if (resposta.status === 401) return sair('INVALID_TOKEN');
    if (!resposta.ok) throw new Error('erro');
    const nome = /filename="([^"]+)"/.exec(resposta.headers.get('content-disposition') || '');
    const url = URL.createObjectURL(await resposta.blob());
    const link = el('a', { href: url, download: nome ? nome[1] : 'divergencias-aceitas.csv' });
    document.body.append(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  } catch (erro) {
    if (token) aviso('Não foi possível baixar o CSV agora.', 'erro');
  }
}

function cartaoDivergencia(d) {
  const distancias = el('input', { type: 'text', placeholder: 'ex.: 5, 10', maxlength: '60', autocomplete: 'off', value: d.suggestedKm.join(', ') });
  const fonte = el('input', { type: 'url', placeholder: 'https://... (página que comprova)', maxlength: '500', autocomplete: 'off' });
  const trecho = el('input', { type: 'text', placeholder: 'Trecho da fonte (até 160 caracteres)', maxlength: '160', autocomplete: 'off' });
  const erro = el('p', { class: 'aviso erro', hidden: true });
  const nada = d.kind === 'nada';
  const aceitar = el('button', { type: 'button', class: 'ok' }, nada ? 'Existe informação (aceitar)' : 'Aceitar');
  const reprovar = el('button', { type: 'button', class: 'perigo' }, nada ? 'Descartar (sem informação útil)' : 'Reprovar');
  const decidir = async (decisao, extra) => {
    const dados = { decisao, distancias: listaKm(distancias.value), fonte: fonte.value.trim(), trecho: trecho.value.trim(), ...extra };
    const problema = validarDecisao(dados);
    erro.hidden = !problema;
    erro.textContent = problema;
    if (problema) return;
    aceitar.disabled = reprovar.disabled = true;
    const corpo = decisao === 'accepted' ? { decision: 'accepted', distances: dados.distancias, sourceUrl: dados.fonte, snippet: dados.trecho } : { decision: 'rejected', reason: extra.motivo || '' };
    try {
      await api(`/admin/divergences/${d.id}/decision`, { method: 'POST', body: JSON.stringify(corpo) });
      aviso(decisao === 'accepted' ? 'Aceita. Ela entra no CSV das aceitas.' : 'Reprovada.', 'ok');
      await carregarDivergencias();
    } catch (falha) {
      aceitar.disabled = reprovar.disabled = false;
      if (!token) return;
      erro.hidden = false;
      erro.textContent = falha.codigo === 'INVALID_INPUT' ? 'O servidor recusou os dados. Confira a distância, o link https e o trecho.' : mensagem(falha.codigo);
    }
  };
  aceitar.addEventListener('click', () => decidir('accepted', {}));
  reprovar.addEventListener('click', () => {
    if (nada) return decidir('rejected', { motivo: 'sem informação útil' });
    const motivo = window.prompt(`Reprovar "${d.name}". Motivo (opcional, até 200 caracteres):`, '');
    if (motivo === null) return;
    decidir('rejected', { motivo: motivo.trim() });
  });
  return el(
    'article',
    { class: 'cartao' },
    el('h2', {}, d.name),
    el('div', { class: 'linha' }, `${dataBr(d.date)}${d.venue ? ' · ' + d.venue : ''}`),
    el('div', { class: 'aviso' }, TIPO_DIVERGENCIA[d.kind] || d.kind, d.note ? ` — ${d.note}` : ''),
    linkSeguro(d.source) ? el('div', { class: 'meta' }, 'Fonte da rotina: ', el('a', { href: linkSeguro(d.source), target: '_blank', rel: 'noopener noreferrer' }, d.source)) : '',
    linkSeguro(d.listSource) ? el('div', { class: 'meta' }, 'Lista oficial: ', el('a', { href: linkSeguro(d.listSource), target: '_blank', rel: 'noopener noreferrer' }, d.listSource)) : '',
    d.suggestedKm.length ? el('div', { class: 'meta' }, `Distâncias sugeridas (de outra edição, não confirmadas): ${d.suggestedKm.join(', ')} km`) : '',
    el('label', {}, 'Distâncias em km (para aceitar)', distancias),
    el('label', {}, 'Link da fonte que comprova', fonte),
    el('label', {}, 'Trecho da fonte', trecho),
    erro,
    el('div', { class: 'acoes' }, aceitar, reprovar),
  );
}

function cartaoFonte(f) {
  const nota = el('input', { type: 'text', placeholder: 'O que foi conferido (site oficial, robots.txt, termos, API ou feed)', maxlength: '300', autocomplete: 'off', value: f.verificationNote || '' });
  const erro = el('p', { class: 'aviso erro', hidden: true });
  const botoes = [];
  const enviar = async (caminho, corpo, ok) => {
    for (const b of botoes) b.disabled = true;
    try {
      await api(`/admin/sources/${f.id}/${caminho}`, { method: 'POST', body: JSON.stringify({ version: f.version, ...corpo }) });
      aviso(ok, 'ok');
      await carregarFontes();
    } catch (falha) {
      for (const b of botoes) b.disabled = false;
      if (!token) return;
      erro.hidden = false;
      erro.textContent = falha.codigo === 'INVALID_INPUT' ? 'Descreva o que foi conferido (até 300 caracteres).' : mensagem(falha.codigo);
    }
  };
  const verificar = (status, ok) => () => {
    if (status !== 'pending' && !nota.value.trim()) {
      erro.hidden = false;
      erro.textContent = 'Descreva o que foi conferido antes de verificar ou rejeitar.';
      return;
    }
    enviar('verification', { status, note: nota.value.trim() }, ok);
  };
  const acao = (rotulo, classe, fn) => {
    const b = el('button', { type: 'button', class: classe }, rotulo);
    b.addEventListener('click', fn);
    botoes.push(b);
    return b;
  };
  const acoes = [acao('Marcar como verificada', 'ok', verificar('verified', 'Fonte verificada.')), acao('Rejeitar', 'perigo', verificar('rejected', 'Fonte rejeitada.'))];
  if (f.verification !== 'pending') acoes.push(acao('Voltar a pendente', 'sec', verificar('pending', 'Fonte voltou a pendente.')));
  if (f.verification === 'verified') acoes.push(acao(f.active ? 'Desativar' : 'Ativar', f.active ? 'sec' : 'ok', () => enviar('active', { active: !f.active }, f.active ? 'Fonte desativada.' : 'Fonte ativada.')));
  const site = linkSeguro(f.websiteUrl);
  return el(
    'article',
    { class: 'cartao' },
    el('h2', {}, f.name),
    el('div', { class: 'linha' }, `${TIPOS_FONTE[f.type] || f.type} · ${NIVEIS_FONTE[f.trustLevel] || ''} · ${f.region} · a cada ${f.frequencyHours} h`),
    site ? el('div', { class: 'meta' }, el('a', { href: site, target: '_blank', rel: 'noopener noreferrer' }, f.websiteUrl)) : '',
    el('div', { class: 'aviso' }, `${VERIFICACAO_FONTE[f.verification] || f.verification} · ${f.active ? 'ativa' : 'desativada'} · ${f.collectable ? 'pode coletar' : 'não coleta'}`),
    f.verifiedAt ? el('div', { class: 'meta' }, `Verificada em ${dataHoraBr(f.verifiedAt)}`) : '',
    f.lastSuccessAt ? el('div', { class: 'meta' }, `Última coleta com sucesso: ${dataHoraBr(f.lastSuccessAt)}`) : '',
    f.lastError ? el('div', { class: 'aviso erro' }, `Último erro: ${f.lastError}`) : '',
    el('label', {}, 'Nota da verificação', nota),
    erro,
    el('div', { class: 'acoes' }, acoes),
  );
}

function formularioFonte() {
  const nome = el('input', { type: 'text', maxlength: '80', autocomplete: 'off', placeholder: 'ex.: Nome da organizadora' });
  const site = el('input', { type: 'url', maxlength: '300', autocomplete: 'off', placeholder: 'https://...' });
  const tipo = el('select', {}, Object.entries(TIPOS_FONTE).map(([v, t]) => el('option', { value: v }, t)));
  const nivel = el('select', {}, Object.entries(NIVEIS_FONTE).map(([v, t]) => el('option', { value: v }, t)));
  const freq = el('input', { type: 'number', min: '1', max: '2160', value: '24' });
  const erro = el('p', { class: 'aviso erro', hidden: true });
  const salvar = el('button', { type: 'button', class: 'ok' }, 'Cadastrar (fica pendente e desativada)');
  tipo.addEventListener('change', () => {
    nivel.value = tipo.value === 'organizer' ? '1' : tipo.value === 'platform' ? '2' : '3';
  });
  salvar.addEventListener('click', async () => {
    const dados = { nome: nome.value, site: site.value.trim(), tipo: tipo.value, nivel: Number(nivel.value), frequencia: Number(freq.value) };
    const problema = validarFonte(dados);
    erro.hidden = !problema;
    erro.textContent = problema;
    if (problema) return;
    salvar.disabled = true;
    try {
      await api('/admin/sources', { method: 'POST', body: JSON.stringify({ id: idFonte(dados.nome), name: dados.nome.trim(), type: dados.tipo, trustLevel: dados.nivel, websiteUrl: dados.site, region: 'SP', method: 'website', frequencyHours: dados.frequencia }) });
      aviso('Fonte cadastrada como pendente.', 'ok');
      await carregarFontes();
    } catch (falha) {
      salvar.disabled = false;
      if (!token) return;
      erro.hidden = false;
      erro.textContent = mensagem(falha.codigo);
    }
  });
  return el('article', { class: 'cartao' }, el('h2', {}, 'Nova fonte'), el('label', {}, 'Nome', nome), el('label', {}, 'Site oficial', site), el('label', {}, 'Tipo', tipo), el('label', {}, 'Nível de confiança', nivel), el('label', {}, 'Frequência da coleta (horas)', freq), erro, el('div', { class: 'acoes' }, salvar));
}

async function carregarFontes() {
  const alvo = $('fontes');
  alvo.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const r = await api('/admin/sources');
    const m = r.summary;
    alvo.replaceChildren(
      el(
        'div',
        { class: 'grade' },
        cartaoNumero('Fontes', String(m.total)),
        cartaoNumero('Verificadas', String(m.verified)),
        cartaoNumero('Pendentes', String(m.pending)),
        cartaoNumero('Podem coletar', String(m.collectable), 'ativas e verificadas'),
        cartaoNumero('Com erro', String(m.withError)),
      ),
      ...(r.items.length ? r.items.map(cartaoFonte) : [el('p', { class: 'vazio' }, 'Nenhuma fonte cadastrada. Use "Carregar fontes candidatas" ou cadastre uma abaixo.')]),
    );
    $('fonte-nova').replaceChildren(formularioFonte());
  } catch (erro) {
    if (token) {
      alvo.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

async function carregarCandidatas() {
  try {
    const r = await api('/admin/sources/candidates', { method: 'POST', body: '{}' });
    aviso(r.created.length ? `${r.created.length} fontes candidatas carregadas (todas pendentes e desativadas).` : 'As candidatas já estavam carregadas.', 'ok');
    await carregarFontes();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

async function carregarDivergencias() {
  const alvo = $('divergencias');
  alvo.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const r = await api('/admin/divergences');
    const pendentes = r.items.filter((i) => !i.decision);
    const decididas = r.items.filter((i) => i.decision);
    alvo.replaceChildren(
      el('p', { class: 'meta' }, r.run ? `Coleta de ${dataBr(r.run)}.` : 'Nenhuma coleta de enriquecimento encontrada.'),
      el(
        'div',
        { class: 'grade' },
        cartaoNumero('Pendentes', String(r.summary.pending)),
        cartaoNumero('Aceitas', String(r.summary.accepted)),
        cartaoNumero('Reprovadas', String(r.summary.rejected)),
        cartaoNumero('Rotina deixou de achar', textoRevocacao(r.summary.nothingFound).valor, textoRevocacao(r.summary.nothingFound).detalhe),
      ),
      ...(pendentes.length ? pendentes.map(cartaoDivergencia) : [el('p', { class: 'vazio' }, r.summary.total ? 'Nenhuma divergência pendente.' : 'Nenhuma divergência nesta coleta.')]),
      decididas.length
        ? el(
            'div',
            { class: 'cartao' },
            el('div', { class: 'rot' }, 'Já decididas'),
            tabela(['Prova', 'Data', 'Decisão', 'Detalhe'], decididas.map((i) => [i.name, dataBr(i.date), i.decision.result === 'accepted' ? 'Aceita' : 'Reprovada', i.decision.result === 'accepted' ? `${i.decision.distances.join(', ')} km` : i.decision.reason || '—'])),
          )
        : '',
    );
  } catch (erro) {
    if (token) {
      alvo.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

// ---- qualidade da busca ---------------------------------------------------------------------------

/** "Última execução": números lidos dos relatórios da rotina (atualiza sozinho). Não mede acerto. */
function painelUltimaExecucao(vivo) {
  const partes = [
    el('h2', {}, 'Última execução da rotina'),
    el('p', { class: 'meta' }, 'Lido dos relatórios que a própria rotina grava a cada execução, então se atualiza sozinho. Mostra o que ela fez (quantas corridas achou, quantas vieram com fonte, quantas esperam decisão). Não mede acerto: isso só vem de conferência humana (a medição manual abaixo e as decisões da aba Divergências). Execuções de teste (dry-run) ficam de fora.'),
  ];
  if (!vivo) {
    partes.push(el('p', { class: 'aviso erro' }, 'Não foi possível ler os relatórios da rotina agora. Tente atualizar.'));
    return el('div', {}, ...partes);
  }
  if (!vivo.runs.length) partes.push(el('p', { class: 'vazio' }, 'Nenhuma execução encontrada nos relatórios ainda.'));
  for (const run of vivo.runs) {
    partes.push(
      el('h3', {}, run.label),
      el('p', { class: 'meta' }, `Execução de ${dataBr(run.date)}${run.generatedAt ? ` · gerada em ${dataHoraBr(run.generatedAt)}` : ''}${run.interrupted ? ' · INTERROMPIDA antes do fim' : ''}`),
      el('div', { class: 'grade' }, ...run.metrics.map((m) => cartaoNumero(m.label, m.of != null ? taxa(m.value, m.of) : String(m.value), m.note))),
    );
  }
  const d = vivo.decisions;
  if (d) {
    const n = d.nothingFound;
    partes.push(
      el('h3', {}, 'Decisões humanas (aba Divergências)'),
      el(
        'div',
        { class: 'grade' },
        cartaoNumero('Esperam decisão', String(d.pending), d.pending ? 'Abra a aba Divergências' : 'Nada pendente'),
        cartaoNumero('Aceitas', taxa(d.accepted, d.total)),
        cartaoNumero('Reprovadas', taxa(d.rejected, d.total)),
        cartaoNumero('"Nada encontrado" conferidas', taxa(n.checked, n.total), 'Das que a rotina não achou, quantas uma pessoa já conferiu'),
        cartaoNumero('Tinham informação útil', taxa(n.hadInfo, n.checked), 'O que a rotina deixou de achar (mede a revocação)'),
      ),
    );
  }
  return el('div', {}, ...partes);
}

async function carregarQualidade() {
  const alvos = ['qualidade-ultima', 'qualidade-extracao', 'qualidade-enriquecimento'].map($);
  for (const a of alvos) a.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const [r, vivo] = await Promise.all([api('/admin/quality'), api('/admin/quality/live').catch(() => null)]);
    const x = r.extraction;
    const e = r.enrichment;
    const f = e.filled;
    const contagem = r.spotCheck.reduce((a, c) => ({ ...a, [c.result]: (a[c.result] || 0) + 1 }), {});
    const decidir = x.notExtracted.filter((i) => i.decision === 'decidir').length;
    alvos[0].replaceChildren(painelUltimaExecucao(vivo));
    alvos[1].replaceChildren(
      el('h2', {}, `Medição manual de ${dataBr(r.date)} (conferida por uma pessoa)`),
      el('p', { class: 'meta' }, r.scope),
      el('h2', {}, 'Extração do calendário da prefeitura'),
      el(
        'div',
        { class: 'grade' },
        cartaoNumero('Extraídas que existem na página', taxa(x.matched, x.extracted), 'Mesmo nome e mesma data. Nenhuma inventada quando 100%.'),
        cartaoNumero('Cobertura das corridas', taxa(x.extracted, x.extracted + decidir), decidir ? `${decidir} item(ns) esperam decisão humana` : 'Sem itens em dúvida'),
        cartaoNumero('Itens na página oficial', String(x.inPage), `${x.notExtracted.length} não extraídos`),
      ),
      el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Não extraídos'), tabela(['Item', 'Data', 'Motivo', 'Situação'], x.notExtracted.map((i) => [i.name, dataBr(i.date), i.reason, i.decision === 'decidir' ? 'Decidir' : 'Correto excluir']))),
    );
    alvos[2].replaceChildren(
      el('h2', {}, 'Enriquecimento (distância, local e inscrição)'),
      el(
        'div',
        { class: 'grade' },
        cartaoNumero('Prontas para importar', taxa(e.ready, e.total), undefined, percentual(e.ready, e.total)),
        cartaoNumero('Nada encontrado', taxa(e.notFound, e.total)),
        cartaoNumero('Pista parcial', taxa(e.partial, e.total)),
      ),
      el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Campos preenchidos'), tabela(['Campo', 'Provas'], [['Distâncias', taxa(f.distances, e.total)], ['Local de largada', taxa(f.venue, e.total)], ['Organizador', taxa(f.organizer, e.total)], ['Link de inscrição', taxa(f.registrationUrl, e.total)], ['Horário de largada', taxa(f.startTime, e.total)]], [1])),
      el('h2', {}, 'Conferência por amostra das provas prontas'),
      el('p', { class: 'meta' }, `${contagem.confere || 0} conferem por inteiro, ${contagem.parcial || 0} em parte, ${contagem.nao_verificado || 0} não verificadas, ${contagem.errada || 0} erradas (de ${r.spotCheck.length}). É amostra pequena: não prova uma taxa.`),
      el('div', { class: 'cartao' }, tabela(['Prova', 'Resultado', 'Observação'], r.spotCheck.map((c) => [c.name, RESULTADO_CONFERENCIA[c.result] || c.result, c.note]))),
      el('h2', {}, 'O que esta medição não cobre'),
      el('ul', {}, r.notCovered.map((t) => el('li', {}, t))),
      el('h2', {}, 'Próximos passos'),
      el('ul', {}, r.nextSteps.map((t) => el('li', {}, t))),
    );
  } catch (erro) {
    if (token) {
      for (const a of alvos) a.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

// ---- custos -------------------------------------------------------------------------------------

const NS = 'http://www.w3.org/2000/svg';

function grafico(valores, rotulos, descricao) {
  const L = 600;
  const A = 120;
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${L} ${A + 16}`);
  svg.setAttribute('class', 'grafico');
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', descricao);
  barras(valores, L, A).forEach((b, i) => {
    const r = document.createElementNS(NS, 'rect');
    for (const [k, v] of Object.entries({ x: b.x, y: b.y, width: b.w, height: b.h })) r.setAttribute(k, v.toFixed(1));
    const t = document.createElementNS(NS, 'title');
    t.textContent = `${rotulos[i]}: ${usd(valores[i])}`;
    r.append(t);
    svg.append(r);
  });
  if (rotulos.length) {
    for (const i of [0, rotulos.length - 1]) {
      const tx = document.createElementNS(NS, 'text');
      tx.setAttribute('x', i === 0 ? '0' : String(L));
      tx.setAttribute('y', String(A + 12));
      tx.setAttribute('text-anchor', i === 0 ? 'start' : 'end');
      tx.textContent = rotulos[i];
      svg.append(tx);
    }
  }
  return svg;
}

function cartaoNumero(rotulo, valor, detalhe, pct) {
  const caixa = el('article', { class: 'cartao' }, el('div', { class: 'rot' }, rotulo), el('div', { class: 'num' }, valor), detalhe ? el('div', { class: 'meta' }, detalhe) : '');
  if (pct != null) {
    const barra = el('div', { class: `barra-uso${pct >= 100 ? ' estouro' : pct >= 80 ? ' alerta' : ''}` }, el('span'));
    barra.firstChild.style.width = `${Math.min(pct, 100)}%`;
    caixa.append(barra);
  }
  return caixa;
}

function tabela(cabecalho, linhas, direita = []) {
  return el(
    'table',
    { class: 'tabela' },
    el('thead', {}, el('tr', {}, cabecalho.map((t, i) => el('th', { class: direita.includes(i) ? 'direita' : '' }, t)))),
    el('tbody', {}, linhas.map((l) => el('tr', {}, l.map((c, i) => el('td', { class: direita.includes(i) ? 'direita' : '' }, c))))),
  );
}

async function carregarCustos() {
  const alvoAws = $('custos-aws');
  const alvoIa = $('custos-ia');
  for (const a of [alvoAws, alvoIa]) a.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const r = await api('/admin/costs');
    const partes = [];
    const partesIa = [];
    const a = r.aws;
    partes.push(el('h2', {}, 'AWS (conta inteira)'));
    if (!a) {
      partes.push(el('p', { class: 'meta' }, 'Não foi possível ler os custos da AWS agora (o Cost Explorer precisa estar habilitado na conta).'));
    } else {
      partes.push(
        el(
          'div',
          { class: 'grade' },
          cartaoNumero(`Gasto em ${mesBr(a.month)}`, usd(a.totalUsd), a.budgetUsd ? `Teto mensal ${usd(a.budgetUsd)}` : '', percentual(a.totalUsd, a.budgetUsd)),
          cartaoNumero('Previsão do mês', usd(a.forecastUsd), a.forecastUsd == null ? 'Sem histórico suficiente' : 'Gasto até agora + previsão do restante', percentual(a.forecastUsd, a.budgetUsd)),
        ),
        a.daily.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Por dia no mês'), grafico(a.daily.map((d) => d.usd), a.daily.map((d) => d.date.slice(8) + '/' + d.date.slice(5, 7)), 'Custo diário da AWS no mês')) : '',
        el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Por serviço (mês)'), tabela(['Serviço', 'Custo'], a.byService.map((s) => [s.service, usd(s.usd)]), [1])),
        el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Últimos meses'), tabela(['Mês', 'Custo'], a.months.map((m) => [mesBr(m.month) + (m.estimated ? ' (parcial)' : ''), usd(m.usd)]), [1])),
        el('p', { class: 'meta' }, 'Valores em dólar, sem converter. Dados do Cost Explorer podem atrasar até 1 dia; a consulta é cobrada pela AWS e fica em cache por 15 minutos.'),
      );
    }
    if (r.openaiOrg) {
      partesIa.push(...secaoOpenAiReal(r.openaiOrg));
    } else {
      if (r.openaiOrgStatus === 'error') {
        partesIa.push(el('p', { class: 'aviso erro' }, `Não foi possível ler os dados reais da OpenAI. ${motivoOpenAi(r.openaiOrgReason)} Mostrando a estimativa.`));
      }
      partesIa.push(...secaoOpenAiEstimativa(r.openai, r.openaiOrgStatus === 'not_configured'));
    }
    alvoAws.replaceChildren(...partes);
    alvoIa.replaceChildren(...partesIa);
  } catch (erro) {
    if (token) {
      alvoAws.replaceChildren();
      alvoIa.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

/** Réplica da página Usage do console da OpenAI (dados reais pela API de administração). */
function secaoOpenAiReal(o) {
  const n = (v) => Number(v).toLocaleString('pt-BR');
  const rotulos = o.daily.map((d) => `${d.date.slice(8)}/${d.date.slice(5, 7)}`);
  return [
    el('h2', {}, 'OpenAI'),
    el(
      'div',
      { class: 'grade' },
      cartaoNumero(`Gasto total em ${mesBr(o.month)}`, usd(o.totalUsd), o.limitUsd ? `Limite mensal ${usd(o.limitUsd)}` : '', percentual(o.totalUsd, o.limitUsd)),
      cartaoNumero('Total de tokens', n(o.totalTokens), `${n(o.inputTokens)} de entrada · ${n(o.outputTokens)} de saída`),
      cartaoNumero('Total de requisições', n(o.totalRequests)),
    ),
    o.daily.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Gasto por dia'), grafico(o.daily.map((d) => d.usd), rotulos, 'Gasto diário da OpenAI')) : '',
    o.daily.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Requisições por dia'), grafico(o.daily.map((d) => d.requests), rotulos, 'Requisições diárias da OpenAI')) : '',
    o.daily.length
      ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Por dia'), tabela(['Dia', 'Gasto', 'Requisições', 'Entrada', 'Saída'], o.daily.slice().reverse().map((d) => [d.date.split('-').reverse().join('/'), usd(d.usd), n(d.requests), n(d.inputTokens), n(d.outputTokens)]), [1, 2, 3, 4]))
      : el('p', { class: 'vazio' }, 'Nenhum uso neste mês ainda.'),
    o.byApiKey.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Por chave de API'), tabela(['Chave', 'Requisições', 'Tokens'], o.byApiKey.map((k) => [k.name, n(k.requests), n(k.tokens)]), [1, 2])) : '',
    o.byModel.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Por modelo'), tabela(['Modelo', 'Requisições', 'Tokens'], o.byModel.map((k) => [k.name, n(k.requests), n(k.tokens)]), [1, 2])) : '',
    o.byLineItem.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, 'Categorias de gasto'), tabela(['Categoria', 'Gasto'], o.byLineItem.map((k) => [k.name, usd(k.usd)]), [1])) : '',
    el('p', { class: 'meta' }, 'Dados da API de administração da OpenAI (a mesma fonte da página Usage do console), em dólar, dias em UTC. Mostra o uso de completions/respostas; outros recursos (imagens, embeddings...) não entram aqui. Atualiza a cada 15 minutos.'),
  ];
}

function secaoOpenAiEstimativa(o, semChave) {
  const partes = [el('h2', {}, 'OpenAI (estimativa)')];
  if (!o) {
    partes.push(el('p', { class: 'meta' }, 'Não foi possível ler o consumo da OpenAI agora.'));
    return partes;
  }
  const mes = o.thisMonth;
  const rotulos = o.daily.map((d) => d.date.slice(8) + '/' + d.date.slice(5, 7));
  partes.push(
    el(
      'div',
      { class: 'grade' },
      cartaoNumero(`Custo estimado em ${mesBr(o.month)}`, o.priced ? usd(mes.estimatedUsd) : 'Preços não informados', o.limitUsd ? `Limite no console ${usd(o.limitUsd)}` : '', o.priced ? percentual(mes.estimatedUsd, o.limitUsd) : null),
      cartaoNumero('Chamadas no mês', String(mes.chamadas), `${compacto(mes.entrada)} tokens de entrada · ${compacto(mes.saida)} de saída`),
      cartaoNumero('Buscas na web no mês', String(mes.buscas), `Mês anterior: ${o.previousMonth.chamadas} chamadas`),
    ),
    o.daily.length ? el('div', { class: 'cartao' }, el('div', { class: 'rot' }, o.priced ? 'Custo estimado por dia' : 'Chamadas por dia'), grafico(o.daily.map((d) => (o.priced ? d.estimatedUsd : d.chamadas)), rotulos, 'Consumo diário da OpenAI')) : '',
    o.daily.length
      ? el('div', { class: 'cartao' }, tabela(['Dia', 'Chamadas', 'Entrada', 'Saída', 'Buscas', 'Custo est.'], o.daily.slice().reverse().map((d) => [d.date.split('-').reverse().join('/'), d.chamadas, compacto(d.entrada), compacto(d.saida), d.buscas, d.estimatedUsd == null ? '—' : usd(d.estimatedUsd)]), [1, 2, 3, 4, 5]))
      : el('p', { class: 'vazio' }, 'Nenhum consumo registrado neste mês ainda.'),
    el(
      'p',
      { class: 'meta' },
      (o.priced
        ? 'Estimativa a partir das chamadas registradas pelas rotinas do catálogo e da busca por linguagem natural, com os preços configurados no portal. Não inclui testes feitos fora delas nem o consumo anterior a esta medição. '
        : 'Só o consumo medido aparece. Para estimar o custo, informe os preços da página oficial da OpenAI na implantação do portal. ') +
        (semChave ? 'Para ver o gasto real por dia (como no console da OpenAI), configure a chave de administrador da OpenAI no portal. ' : '') +
        'A fatura da OpenAI é a referência.',
    ),
  );
  return partes;
}

// ---- banners --------------------------------------------------------------------------------------

/** Busca de corrida do catálogo (a mesma busca do vínculo de pedidos). `aoEscolher(edicao)` recebe a escolhida. */
function seletorEdicao(textoInicial, aoEscolher, idInicial = null) {
  const lista = el('ul', { class: 'escolhas', role: 'listbox' });
  const busca = el('input', { type: 'search', placeholder: 'Nome da corrida no catálogo', maxlength: '160', value: textoInicial || '' });
  let espera = null;
  let inicial = idInicial;
  const pesquisar = async () => {
    aoEscolher(null);
    try {
      const { items } = await api(`/admin/editions?q=${encodeURIComponent(busca.value.trim())}&limit=20`);
      lista.replaceChildren(
        ...(items.length
          ? items.map((e) => {
              const li = el('li', { role: 'option', 'aria-selected': 'false', tabindex: '0', 'data-id': e.id }, `${e.name} · ${e.date} · ${e.city}/${e.state}`);
              const marcar = () => {
                for (const outro of lista.children) outro.setAttribute('aria-selected', 'false');
                li.setAttribute('aria-selected', 'true');
                aoEscolher(e);
              };
              li.addEventListener('click', marcar);
              li.addEventListener('keydown', (ev) => ev.key === 'Enter' && marcar());
              return li;
            })
          : [el('li', {}, 'Nenhuma corrida encontrada.')]),
      );
      const sugerida = inicial && [...lista.children].find((li) => li.dataset.id === inicial);
      inicial = null;
      if (sugerida) sugerida.click();
    } catch (erro) {
      if (token) aviso(mensagem(erro.codigo), 'erro');
    }
  };
  busca.addEventListener('input', () => {
    clearTimeout(espera);
    espera = setTimeout(pesquisar, 350);
  });
  return { caixa: el('div', {}, el('label', {}, 'Corrida do catálogo', busca), lista), pesquisar };
}

/** Formulário de aprovação: imagem (com prévia), crédito, base de autorização e confirmação. */
const candidatasPublicadas = new Set();

const LIMITE_ARQUIVO_BYTES = 3_000_000;

/**
 * Lê o arquivo escolhido, reduz (maior lado 1920 px) e converte em JPEG de até ~3 MB, pronto para ir no JSON
 * (a Lambda aceita até 6 MB). Devolve { base64, tipo, previa (endereço local), bytes }.
 */
async function prepararArquivo(arquivo) {
  if (!arquivo) return null;
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(arquivo.type)) throw new Error('Use uma imagem JPEG, PNG ou WebP.');
  const origem = URL.createObjectURL(arquivo);
  try {
    const img = await new Promise((ok, falha) => {
      const i = new Image();
      i.onload = () => ok(i);
      i.onerror = () => falha(new Error('Não foi possível ler a imagem.'));
      i.src = origem;
    });
    const { largura, altura } = dimensoesEnvio(img.naturalWidth, img.naturalHeight);
    const tela = document.createElement('canvas');
    tela.width = largura;
    tela.height = altura;
    const ctx = tela.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, largura, altura);
    ctx.drawImage(img, 0, 0, largura, altura);
    let qualidade = 0.92;
    let blob;
    do {
      blob = await new Promise((ok) => tela.toBlob(ok, 'image/jpeg', qualidade));
      qualidade -= 0.1;
    } while (blob && blob.size > LIMITE_ARQUIVO_BYTES && qualidade > 0.4);
    if (!blob || blob.size > LIMITE_ARQUIVO_BYTES) throw new Error('A imagem continua grande demais. Escolha uma menor.');
    const base64 = await new Promise((ok, falha) => {
      const leitor = new FileReader();
      leitor.onload = () => ok(String(leitor.result).split(',')[1]);
      leitor.onerror = () => falha(new Error('Não foi possível ler a imagem.'));
      leitor.readAsDataURL(blob);
    });
    return { base64, tipo: 'image/jpeg', previa: URL.createObjectURL(blob), bytes: blob.size };
  } finally {
    URL.revokeObjectURL(origem);
  }
}

function formularioBanner({ imagem, credito, pagina, edicao, nomeBusca }) {
  let escolhida = null;
  let urlPrevia = null;
  const campoUrl = imagem ? null : el('input', { type: 'url', placeholder: 'https://...', maxlength: '2000' });
  // Arquivo do computador (alternativa ao endereço); só no formulário manual, não nas candidatas da coleta.
  const campoArquivo = imagem ? null : el('input', { type: 'file', accept: 'image/png,image/jpeg,image/webp' });
  let arquivoPronto = null;
  const previa = el('div');
  const campoCredito = el('input', { type: 'text', maxlength: '200', value: credito || '', placeholder: 'Ex.: Divulgação: Organizador' });
  const campoNota = el('textarea', { rows: '4', maxlength: '1000' });
  campoNota.value = notaDireitosPadrao(pagina, dataHojeIso());
  const confirmar = el('input', { type: 'checkbox' });
  const aprovar = el('button', { type: 'button', class: 'ok', disabled: true }, 'Aprovar e publicar');
  const seletor = seletorEdicao(
    edicao ? edicao.name : nomeBusca,
    (e) => {
      escolhida = e ? e.id : null;
      habilitar();
    },
    edicao ? edicao.id : null,
  );
  const endereco = () => (imagem || campoUrl.value.trim());
  const temFonte = () => Boolean(arquivoPronto || endereco());
  const habilitar = () => {
    aprovar.disabled = !(escolhida && temFonte() && campoCredito.value.trim() && campoNota.value.trim().length >= 10 && confirmar.checked);
  };
  for (const c of [campoCredito, campoNota, confirmar]) c.addEventListener('input', habilitar);
  if (campoUrl) campoUrl.addEventListener('input', habilitar);
  if (campoArquivo) {
    campoArquivo.addEventListener('change', async () => {
      arquivoPronto = null;
      previa.replaceChildren(el('p', { class: 'meta' }, 'Preparando a imagem...'));
      try {
        arquivoPronto = await prepararArquivo(campoArquivo.files[0]);
        previa.replaceChildren(
          arquivoPronto
            ? el('div', {}, el('img', { class: 'previa', src: arquivoPronto.previa, alt: 'Prévia do banner' }), el('p', { class: 'meta' }, `Arquivo pronto (${Math.round(arquivoPronto.bytes / 1024)} KB). O servidor ainda remove os metadados antes de publicar.`))
            : '',
        );
      } catch (falha) {
        previa.replaceChildren(el('p', { class: 'aviso erro' }, falha.message));
      }
      habilitar();
    });
  }

  const verPrevia = el('button', { type: 'button', class: 'sec' }, 'Ver a imagem como ficará no app');
  verPrevia.addEventListener('click', async () => {
    if (arquivoPronto) {
      return previa.replaceChildren(el('img', { class: 'previa', src: arquivoPronto.previa, alt: 'Prévia do banner' }));
    }
    if (!endereco()) return aviso('Informe o endereço da imagem ou escolha um arquivo.', 'erro');
    verPrevia.disabled = true;
    // O resultado e os erros aparecem AQUI, junto do botão (o aviso global fica no topo da página, fora da vista).
    previa.replaceChildren(el('p', { class: 'meta' }, 'Gerando a prévia... pode levar até 30 segundos.'));
    try {
      const r = await fetch(cfg.apiUrl + '/admin/banners/preview', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ imageUrl: endereco() }),
      });
      if (r.status === 401) return sair('INVALID_TOKEN');
      if (!r.ok) {
        const j = await r.json().catch(() => ({}));
        const texto = j.code ? mensagem(j.code) : 'O servidor demorou demais ou falhou ao tratar a imagem. Tente de novo; se repetir, a imagem pode ser grande demais.';
        return previa.replaceChildren(el('p', { class: 'aviso erro' }, texto));
      }
      if (urlPrevia) URL.revokeObjectURL(urlPrevia);
      urlPrevia = URL.createObjectURL(await r.blob());
      previa.replaceChildren(el('img', { class: 'previa', src: urlPrevia, alt: 'Prévia do banner' }));
    } catch (falha) {
      previa.replaceChildren(el('p', { class: 'aviso erro' }, 'Sem resposta do servidor. Confira a conexão e tente de novo.'));
    } finally {
      verPrevia.disabled = false;
    }
  });

  aprovar.addEventListener('click', async () => {
    let corpo;
    try {
      corpo = arquivoPronto
        ? montarBannerArquivo({ editionId: escolhida, base64: arquivoPronto.base64, tipo: arquivoPronto.tipo, credito: campoCredito.value, nota: campoNota.value, confirmou: confirmar.checked })
        : { editionId: escolhida, imageUrl: endereco(), credit: campoCredito.value.trim(), rightsNote: campoNota.value.trim(), confirmRights: confirmar.checked };
    } catch (falha) {
      return aviso(falha.message, 'erro');
    }
    if (!window.confirm('Aprovar PUBLICA esta imagem no app, com o crédito informado. Confirmar?')) return;
    aprovar.disabled = true;
    try {
      await api('/admin/banners/approve', { method: 'POST', body: JSON.stringify(corpo) });
      if (!arquivoPronto && endereco()) candidatasPublicadas.add(endereco());
      aviso('Banner publicado.', 'ok');
      await carregarBanners();
    } catch (erro) {
      habilitar();
      if (token) aviso(mensagem(erro.codigo), 'erro');
    }
  });

  seletor.pesquisar();
  return el(
    'div',
    {},
    campoUrl ? el('label', {}, 'Endereço da imagem (https)', campoUrl) : '',
    campoArquivo ? el('label', {}, 'Ou envie o arquivo da imagem (JPEG, PNG ou WebP; o portal reduz antes de enviar)', campoArquivo) : '',
    el('div', { class: 'acoes' }, verPrevia),
    previa,
    seletor.caixa,
    el('label', {}, 'Crédito (aparece no app)', campoCredito),
    el('label', {}, 'Base de autorização (como você obteve o direito de usar; fica só no registro interno)', campoNota),
    el('label', { class: 'confirma' }, confirmar, ' Confirmo que a base de autorização acima é verdadeira.'),
    aprovar,
  );
}

/** Redes do organizador de uma corrida: perfis (Instagram/Facebook) e UM post a exibir pelo embed da Meta. */
function formularioRedes(sugestao = null) {
  let escolhida = null;
  const instagram = el('input', { type: 'url', maxlength: '500', placeholder: 'https://www.instagram.com/usuario/' });
  const facebook = el('input', { type: 'url', maxlength: '500', placeholder: 'https://www.facebook.com/pagina' });
  const post = el('input', { type: 'url', maxlength: '500', placeholder: 'https://www.instagram.com/p/... (post, reel ou vídeo público)' });
  const salvar = el('button', { type: 'button', class: 'ok', disabled: true }, 'Salvar redes');
  const erro = el('p', { class: 'aviso erro', hidden: true });
  const seletor = seletorEdicao(
    sugestao ? sugestao.nome : '',
    (e) => {
      escolhida = e ? e.id : null;
      salvar.disabled = !escolhida;
      instagram.value = (e && e.instagramUrl) || (sugestao && sugestao.instagram) || '';
      facebook.value = (e && e.facebookUrl) || (sugestao && sugestao.facebook) || '';
      post.value = (e && e.organizerPostUrl) || '';
    },
    sugestao ? sugestao.edicaoId : null,
  );
  salvar.addEventListener('click', async () => {
    if (!escolhida) return;
    salvar.disabled = true;
    erro.hidden = true;
    try {
      // Vazio apaga; so mandamos o que a pessoa deixou no formulario.
      await api(`/admin/editions/${encodeURIComponent(escolhida)}/social`, {
        method: 'PUT',
        body: JSON.stringify({ instagramUrl: instagram.value.trim(), facebookUrl: facebook.value.trim(), organizerPostUrl: post.value.trim() }),
      });
      aviso('Redes da corrida salvas.', 'ok');
    } catch (falha) {
      if (token) {
        erro.hidden = false;
        erro.textContent = falha.codigo ? mensagem(falha.codigo) : falha.message;
      }
    } finally {
      salvar.disabled = !escolhida;
    }
  });
  seletor.pesquisar();
  return el(
    'div',
    {},
    seletor.caixa,
    el('label', {}, 'Instagram do organizador (perfil)', instagram),
    el('label', {}, 'Facebook do organizador (página)', facebook),
    el('label', {}, 'Post para mostrar na corrida (opcional, só post público)', post),
    el('p', { class: 'meta' }, 'Deixar um campo vazio e salvar apaga aquele link.'),
    erro,
    salvar,
  );
}

async function carregarBanners() {
  $('banners-candidatas').replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const [cand, pub] = await Promise.all([api('/admin/banners/candidates'), api('/admin/banners/published')]);
    $('banners-candidatas').replaceChildren(
      el('h2', {}, cand.source ? `Candidatas da coleta de ${dataBr(cand.source)}` : 'Candidatas'),
      ...(cand.items.filter((c) => !candidatasPublicadas.has(c.imageUrl)).length
        ? cand.items.filter((c) => !candidatasPublicadas.has(c.imageUrl)).map((c) =>
            el(
              'article',
              { class: 'cartao' },
              el('h2', {}, c.name),
              el('div', { class: 'linha' }, `${dataBr(c.date)} · direitos: ${c.rights || 'não verificado'}`),
              linkSeguro(c.officialPage) ? el('div', { class: 'meta' }, 'Página oficial: ', el('a', { href: linkSeguro(c.officialPage), target: '_blank', rel: 'noopener noreferrer' }, c.officialPage)) : '',
              formularioBanner({ imagem: c.imageUrl, credito: c.credit, pagina: c.officialPage, edicao: c.edition, nomeBusca: c.name }),
              c.instagramUrl || c.facebookUrl
                ? el(
                    'details',
                    {},
                    el('summary', {}, 'Instagram/Facebook que o organizador divulga na página oficial'),
                    c.instagramUrl ? el('div', { class: 'meta' }, 'Instagram: ', el('a', { href: c.instagramUrl, target: '_blank', rel: 'noopener noreferrer' }, c.instagramUrl)) : '',
                    c.facebookUrl ? el('div', { class: 'meta' }, 'Facebook: ', el('a', { href: c.facebookUrl, target: '_blank', rel: 'noopener noreferrer' }, c.facebookUrl)) : '',
                    formularioRedes({ nome: c.name, edicaoId: c.edition ? c.edition.id : null, instagram: c.instagramUrl, facebook: c.facebookUrl }),
                  )
                : '',
              el('div', { class: 'acoes' }, el('button', { type: 'button', class: 'perigo', onclick: () => excluirCandidata(c) }, 'Excluir candidata')),
            ),
          )
        : [el('p', { class: 'vazio' }, 'Nenhuma imagem candidata pendente. Para trocar o banner de uma corrida, retire o atual ou use o formulário manual.')]),
    );
    $('banner-manual').replaceChildren(formularioBanner({ imagem: '', credito: '', pagina: '', edicao: null, nomeBusca: '' }));
    $('redes-organizador').replaceChildren(formularioRedes());
    $('banners-publicados').replaceChildren(
      ...(pub.items.length
        ? pub.items.map((e) =>
            el(
              'article',
              { class: 'cartao' },
              el('h2', {}, e.name),
              el('div', { class: 'linha' }, `${dataBr(e.date)} · ${e.city}/${e.state} · crédito: ${e.credit || '—'}`),
              el('button', { type: 'button', class: 'perigo', onclick: () => retirarBanner(e) }, 'Excluir banner'),
            ),
          )
        : [el('p', { class: 'vazio' }, 'Nenhum banner publicado.')]),
    );
  } catch (erro) {
    if (token) {
      $('banners-candidatas').replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

async function excluirCandidata(c) {
  if (!window.confirm(`Excluir a candidata "${c.name}"? Ela sai da lista e não volta nas próximas coletas. A imagem publicada, se houver, não é afetada.`)) return;
  try {
    await api('/admin/banners/dismiss', { method: 'POST', body: JSON.stringify({ imageUrl: c.imageUrl }) });
    candidatasPublicadas.add(c.imageUrl);
    aviso('Candidata excluída.', 'ok');
    await carregarBanners();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

async function retirarBanner(e) {
  const motivo = window.prompt(`Excluir o banner de "${e.name}". Motivo (fica registrado):`, '');
  if (!motivo || motivo.trim().length < 5) return;
  try {
    await api('/admin/banners/remove', { method: 'POST', body: JSON.stringify({ editionId: e.id, reason: motivo.trim() }) });
    aviso('Banner retirado.', 'ok');
    await carregarBanners();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

// ---- gestão de operadores -----------------------------------------------------------------------

let meuId = '';

async function acaoOperador(caminho, metodo, corpo, sucesso) {
  try {
    await api(`/admin/operators/${encodeURIComponent(caminho)}`, { method: metodo, body: corpo ? JSON.stringify(corpo) : undefined });
    aviso(sucesso, 'ok');
    await carregarOperadores();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

function editorPermissoes(op, area, conceder = false) {
  const atuais = new Set(permissoesDe(op));
  const caixas = Object.entries(PERMISSOES).map(([v, t]) => el('label', {}, el('input', { type: 'checkbox', value: v, checked: atuais.has(v) }), t));
  const salvar = el('button', { type: 'button', class: 'ok' }, conceder ? 'Conceder acesso' : 'Salvar permissões');
  salvar.addEventListener('click', () => {
    const escolhidas = [...area.querySelectorAll('input:checked')].map((i) => i.value);
    if (!escolhidas.length) return aviso('Escolha ao menos uma permissão (ou retire o acesso).', 'erro');
    if (conceder) acaoOperador(`${op.subject}/grant`, 'POST', { permissions: escolhidas }, 'Acesso concedido. Peça para a pessoa entrar de novo.');
    else acaoOperador(`${op.subject}/permissions`, 'PUT', { permissions: escolhidas }, 'Permissões atualizadas.');
  });
  area.replaceChildren(el('fieldset', {}, el('legend', {}, 'Permissões'), caixas), salvar);
}

function cartaoOperador(op) {
  const area = el('div');
  const eu = op.subject === meuId;
  const ativo = op.enabled && op.access && op.access.state === 'active';
  const botoes = [];
  if (!eu) {
    if (ativo) {
      botoes.push(el('button', { type: 'button', class: 'sec', onclick: () => editorPermissoes(op, area) }, 'Alterar permissões'));
      botoes.push(el('button', { type: 'button', class: 'perigo', onclick: () => window.confirm(`Retirar o acesso de ${op.email}? A sessão dele cai agora.`) && acaoOperador(`${op.subject}/revoke`, 'POST', null, 'Acesso retirado.') }, 'Retirar acesso'));
      botoes.push(el('button', { type: 'button', class: 'sec', onclick: () => window.confirm(`Esqueceu senha ou autenticador? Vamos apagar o login de ${op.email} e enviar um convite novo, com as mesmas permissões. Continuar?`) && acaoOperador(`${op.subject}/reset`, 'POST', null, 'Login recriado: o operador recebeu um convite novo por e-mail.') }, 'Refazer senha e autenticador'));
    } else if (!op.access && op.enabled) {
      botoes.push(el('button', { type: 'button', class: 'ok', onclick: () => editorPermissoes(op, area, true) }, 'Conceder acesso ao portal'));
    } else if (op.access) {
      botoes.push(el('button', { type: 'button', class: 'ok', onclick: () => acaoOperador(`${op.subject}/reactivate`, 'POST', null, 'Acesso reativado.') }, 'Reativar acesso'));
    }
  }
  const concedido = op.access && op.access.grantedAt ? ` · concedido em ${dataHoraBr(op.access.grantedAt)}` : '';
  return el(
    'article',
    { class: 'cartao' },
    el('h2', {}, op.email + (eu ? ' (você)' : '')),
    el('div', { class: 'linha' }, `${situacaoOperador(op)}${concedido}`),
    el('div', { class: 'meta' }, permissoesDe(op).map((p) => PERMISSOES[p] || p).join(' · ') || 'Sem permissões'),
    el('div', { class: 'acoes' }, botoes),
    area,
  );
}

async function carregarOperadores() {
  const alvo = $('operadores');
  alvo.replaceChildren(el('p', { class: 'vazio' }, 'Carregando...'));
  try {
    const { items } = await api('/admin/operators');
    alvo.replaceChildren(...(items.length ? items.map(cartaoOperador) : [el('p', { class: 'vazio' }, 'Nenhum operador.')]));
  } catch (erro) {
    if (token) {
      alvo.replaceChildren();
      aviso(mensagem(erro.codigo), 'erro');
    }
  }
}

// ---- cadastros, operadores e atualização do catálogo ------------------------------------------

let permissoes = [];

function mostrarAba(nome) {
  for (const b of document.querySelectorAll('[data-aba]')) b.setAttribute('aria-selected', String(b.dataset.aba === nome));
  for (const s of document.querySelectorAll('[data-sec]')) s.hidden = s.dataset.sec !== nome;
  aviso('');
  if (nome === 'pedidos') carregarPedidos();
  if (nome === 'catalogo') carregarUltimoDisparo();
  if (nome === 'fontes') carregarFontes();
  if (nome === 'cadastros') carregarCadastros();
  if (nome === 'divergencias') carregarDivergencias();
  if (nome === 'qualidade') carregarQualidade();
  if (nome === 'custos') carregarCustos();
  if (nome === 'banners') carregarBanners();
  if (nome === 'operadores') carregarOperadores();
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
            el('thead', {}, el('tr', {}, el('th', {}, 'Cadastro'), el('th', {}, 'Usuário (ID)'), el('th', {}, 'E-mail'), el('th', {}, 'Situação'), el('th', {}, 'Criado em'))),
            el('tbody', {}, r.items.map((u) => el('tr', {}, el('td', {}, u.id), el('td', {}, u.username ? '@' + u.username : '—'), el('td', {}, u.email), el('td', {}, statusCadastro(u.status) + (u.enabled ? '' : ' (desativado)')), el('td', {}, (u.createdAt || '').slice(0, 10).split('-').reverse().join('/'))))),
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

/** Formulário de agendamento: `item` null = novo; com `item` = editar (tipo e nome não mudam). */
function formularioAgendamento(item, aoFechar) {
  const novo = !item;
  const hoje = dataHojeIso();
  const nome = el('input', { type: 'text', maxlength: '40', placeholder: 'ex.: enriquecimento-quinta', autocomplete: 'off' });
  const tipo = el('select', {}, ...Object.entries(TIPOS_AGENDAMENTO).map(([v, t]) => el('option', { value: v }, t)));
  const caixas = DIAS_SEMANA.map(([codigo, rotulo]) => {
    const c = el('input', { type: 'checkbox', value: codigo });
    c.checked = !!(item && item.days && item.days.includes(codigo));
    return [c, el('label', { class: 'dia' }, c, ' ', rotulo)];
  });
  const horario = el('input', { type: 'time', value: (item && item.time) || '06:00' });
  const data = el('input', { type: 'date', min: hoje, value: (item && item.date) || '' });
  const modoSemana = el('input', { type: 'radio', name: 'quando', value: 'semanal' });
  const modoUmaVez = el('input', { type: 'radio', name: 'quando', value: 'uma-vez' });
  (item && item.date ? modoUmaVez : modoSemana).checked = true;
  const modo = () => (modoUmaVez.checked ? 'uma-vez' : 'semanal');
  const rodada = el('input', { type: 'number', min: '1', max: '3', value: String((item && item.params && item.params.rodada) || 1) });
  const maximo = el('input', { type: 'number', min: '1', max: String(MAX_PROVAS_POR_EXECUCAO), value: String((item && item.params && item.params.max) || MAX_PROVAS_POR_EXECUCAO) });
  const meses = el('input', { type: 'number', min: '1', max: '6', value: String((item && item.params && item.params.meses) || 3) });
  const ativo = el('input', { type: 'checkbox' });
  ativo.checked = item ? item.enabled : true;
  const grupoRodada = el('label', {}, 'Rodada (1 a 3)', rodada);
  const grupoMax = el('label', {}, `Máximo de provas por execução (1 a ${MAX_PROVAS_POR_EXECUCAO})`, maximo);
  const grupoMeses = el('label', {}, 'Meses do calendário (1 a 6)', meses);
  const tipoAtual = () => (novo ? tipo.value : item.kind);
  const grupoDias = el('fieldset', { class: 'dias' }, el('legend', {}, 'Dias da semana (horário de São Paulo, no máximo 1 vez por dia)'), ...caixas.map(([, rotulo]) => rotulo));
  const grupoData = el('label', {}, 'Data da execução (horário de São Paulo; roda uma vez e o agendamento some sozinho)', data);
  const mostrar = () => {
    grupoDias.hidden = modo() !== 'semanal';
    grupoData.hidden = modo() !== 'uma-vez';
    grupoRodada.hidden = grupoMax.hidden = tipoAtual() !== 'enriquecer';
    grupoMeses.hidden = tipoAtual() !== 'calendario';
  };
  tipo.addEventListener('change', mostrar);
  modoSemana.addEventListener('change', mostrar);
  modoUmaVez.addEventListener('change', mostrar);
  mostrar();
  const erro = el('p', { class: 'aviso erro', hidden: true });
  const salvar = el('button', { type: 'button' }, novo ? 'Criar agendamento' : 'Salvar alterações');
  const cancelar = el('button', { type: 'button', class: 'sec', onclick: aoFechar }, 'Cancelar');

  salvar.addEventListener('click', async () => {
    const dias = caixas.filter(([c]) => c.checked).map(([c]) => c.value);
    const umaVez = modo() === 'uma-vez';
    const dados = { novo, nome: nome.value.trim(), tipo: tipoAtual(), modo: modo(), data: data.value, dias: umaVez ? [] : dias, horario: umaVez || dias.length ? horario.value : '', rodada: Number(rodada.value), max: Number(maximo.value), meses: Number(meses.value) };
    const problema = validarAgendamento(novo || umaVez ? dados : { ...dados, horario: dias.length || horario.value !== ((item && item.time) || '06:00') ? horario.value : '' });
    erro.hidden = !problema;
    erro.textContent = problema;
    if (problema) return;
    const corpo = { enabled: ativo.checked };
    if (umaVez) Object.assign(corpo, { date: data.value, time: horario.value });
    else if (dias.length) Object.assign(corpo, { days: dias, time: horario.value });
    if (dados.tipo === 'enriquecer') Object.assign(corpo, { rodada: dados.rodada, max: dados.max });
    if (dados.tipo === 'calendario') corpo.meses = dados.meses;
    if (novo) Object.assign(corpo, { name: dados.nome, kind: dados.tipo });
    salvar.disabled = true;
    try {
      if (novo) await api('/admin/catalog/schedules', { method: 'POST', body: JSON.stringify(corpo) });
      else await api(`/admin/catalog/schedules/${encodeURIComponent(item.name)}`, { method: 'PUT', body: JSON.stringify(corpo) });
      aviso(novo ? 'Agendamento criado.' : 'Agendamento atualizado.', 'ok');
      aoFechar();
      await carregarAgendamentos();
    } catch (falha) {
      salvar.disabled = false;
      if (!token) return;
      erro.hidden = false;
      erro.textContent = falha.codigo === 'INVALID_INPUT' ? 'A AWS ou o servidor recusou os dados. Confira o nome, o tipo, os dias, o horário e os limites.' : mensagem(falha.codigo);
    }
  });

  const dicaExpressao = !novo && !item.days ? el('p', { class: 'meta' }, `Horário atual fora do padrão (${item.expression}). Escolha dias e horário para substituí-lo, ou deixe em branco para manter.`) : '';
  return el(
    'article',
    { class: 'cartao' },
    el('h2', {}, novo ? 'Novo agendamento' : `Editar: ${item.description || item.name}`),
    novo ? el('label', {}, 'Nome (ficará como "portal-nome")', nome) : '',
    novo ? el('label', {}, 'O que faz', tipo) : el('p', { class: 'meta' }, `Tipo: ${TIPOS_AGENDAMENTO[item.kind] || 'não editável pelo portal (só pausar, ativar ou apagar)'}`),
    ...(novo || item.kind
      ? [
          el('div', { class: 'dias' }, el('label', { class: 'dia' }, modoSemana, ' Repetir toda semana'), el('label', { class: 'dia' }, modoUmaVez, ' Uma vez, em uma data')),
          grupoDias,
          grupoData,
          dicaExpressao,
          el('label', {}, 'Horário', horario),
          grupoRodada,
          grupoMax,
          grupoMeses,
        ]
      : []),
    el('label', { class: 'confirma' }, ativo, ' Ativo (roda sozinho e gasta a cota da OpenAI)'),
    erro,
    el('div', { class: 'acoes' }, salvar, cancelar),
  );
}

async function alternarAgendamento(a) {
  try {
    await api(`/admin/catalog/schedules/${encodeURIComponent(a.name)}`, { method: 'PUT', body: JSON.stringify({ enabled: !a.enabled }) });
    aviso(a.enabled ? 'Agendamento pausado.' : 'Agendamento ativado.', 'ok');
    await carregarAgendamentos();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

async function apagarAgendamento(a) {
  const doStack = !a.createdByPortal;
  const texto = `Apagar o agendamento "${a.description || a.name}"?` + (doStack ? '\n\nEle foi criado pela stack do catálogo (CloudFormation). Apagar aqui o deixa diferente do template: um deploy futuro pode recriá-lo ou falhar.' : '') + '\n\nNão dá para desfazer.';
  if (!window.confirm(texto)) return;
  try {
    await api(`/admin/catalog/schedules/${encodeURIComponent(a.name)}`, { method: 'DELETE' });
    aviso('Agendamento apagado.', 'ok');
    await carregarAgendamentos();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
}

async function carregarAgendamentos() {
  try {
    const { items } = await api('/admin/catalog/schedules');
    const editor = el('div', {});
    const fechar = () => editor.replaceChildren();
    const abrir = (item) => editor.replaceChildren(formularioAgendamento(item, fechar));
    $('agendamentos').replaceChildren(
      el('div', { class: 'acoes' }, el('button', { type: 'button', onclick: () => abrir(null) }, 'Novo agendamento')),
      editor,
      items.length
        ? el(
            'table',
            { class: 'tabela' },
            el('thead', {}, el('tr', {}, ['Próxima execução', 'O que faz', 'Quando', 'Situação', 'Ações'].map((t) => el('th', {}, t)))),
            el('tbody', {}, items.map((a) => {
              const d = descreverAgendamento(a);
              return el(
                'tr',
                {},
                el('td', {}, d.quando),
                el('td', {}, d.oque, a.createdByPortal ? el('div', { class: 'meta' }, 'Criado pelo portal') : ''),
                el('td', {}, quandoTexto(a.days, a.time, a.date) || a.expression),
                el('td', {}, d.situacao),
                el(
                  'td',
                  {},
                  el(
                    'div',
                    { class: 'acoes' },
                    el('button', { type: 'button', class: 'sec', onclick: () => abrir(a) }, 'Editar'),
                    el('button', { type: 'button', class: 'sec', onclick: () => alternarAgendamento(a) }, a.enabled ? 'Pausar' : 'Ativar'),
                    el('button', { type: 'button', class: 'perigo', onclick: () => apagarAgendamento(a) }, 'Apagar'),
                  ),
                ),
              );
            })),
          )
        : el('p', { class: 'vazio' }, 'Nenhum agendamento encontrado.'),
    );
  } catch (erro) {
    if (token) $('agendamentos').replaceChildren(el('p', { class: 'meta' }, 'Não foi possível ler os agendamentos agora.'));
  }
}

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

/** Importe automático: interruptor, resumo da última rodada e lista do que entrou, com Desfazer. */
async function carregarImporteAutomatico() {
  const alvo = $('importe-automatico-corpo');
  try {
    const e = await api('/admin/catalog/auto-import');
    const caixa = el('input', { type: 'checkbox' });
    caixa.checked = e.enabled;
    caixa.addEventListener('change', async () => {
      const ligar = caixa.checked;
      if (ligar && !window.confirm('Ligar o importe automático? As corridas que passarem nas travas serão PUBLICADAS no app sem a sua revisão. Você poderá desfazer cada uma.')) {
        caixa.checked = false;
        return;
      }
      caixa.disabled = true;
      try {
        await api('/admin/catalog/auto-import', { method: 'PUT', body: JSON.stringify({ enabled: ligar }) });
        aviso(ligar ? 'Importe automático ligado.' : 'Importe automático desligado.', 'ok');
      } catch (falha) {
        caixa.checked = !ligar;
        if (token) aviso(mensagem(falha.codigo), 'erro');
      } finally {
        caixa.disabled = false;
        carregarImporteAutomatico();
      }
    });
    const agora = el('button', { type: 'button', class: 'sec' }, 'Importar agora');
    agora.addEventListener('click', async () => {
      agora.disabled = true;
      try {
        const r = await api('/admin/catalog/auto-import/run', { method: 'POST' });
        aviso(r.skipped ? 'O importe automático está desligado.' : `Importe feito: ${r.created} corrida(s) nova(s).`, r.skipped ? 'erro' : 'ok');
      } catch (falha) {
        if (token) aviso(mensagem(falha.codigo), 'erro');
      } finally {
        agora.disabled = false;
        carregarImporteAutomatico();
      }
    });
    const ultimo = e.lastRun ? resumoImporte(e.lastRun.detalhe) : null;
    alvo.replaceChildren(
      el('label', { class: 'confirma' }, caixa, ' Importe automático ligado'),
      el('p', { class: 'meta' }, 'Travas (todas precisam passar): ' + e.gates.join('; ') + '. Roda de hora em hora.'),
      e.lastRun
        ? el('p', { class: 'meta' }, `Última rodada: ${dataHoraBr(e.lastRun.at)} (${e.lastRun.trigger === 'manual' ? 'manual' : 'agendada'}) · ${ultimo.texto}${ultimo.detalhes.length ? ` (para revisão: ${ultimo.detalhes.join('; ')})` : ''}`)
        : el('p', { class: 'meta' }, 'Nenhuma rodada ainda.'),
      el('div', { class: 'acoes' }, agora),
      el('h3', {}, 'Importadas automaticamente'),
      ...(e.recent.length
        ? e.recent.map((c) =>
            el(
              'div',
              { class: 'linha' },
              `${c.name} · ${dataBr(c.date)} · ${dataHoraBr(c.at)} `,
              c.undone || c.archived
                ? el('span', { class: 'meta' }, '(desfeita)')
                : el('button', { type: 'button', class: 'perigo', onclick: () => desfazerImporte(c) }, 'Desfazer'),
            ),
          )
        : [el('p', { class: 'vazio' }, 'Nada importado automaticamente ainda.')]),
    );
  } catch (erro) {
    if (token) alvo.replaceChildren(el('p', { class: 'aviso erro' }, mensagem(erro.codigo)));
  }
}

async function desfazerImporte(c) {
  const motivo = window.prompt(`Desfazer a corrida "${c.name}" (ela é arquivada e some do app). Motivo:`, '');
  if (motivo === null) return;
  try {
    await api('/admin/catalog/auto-import/undo', { method: 'POST', body: JSON.stringify({ editionId: c.id, reason: motivo.trim() }) });
    aviso('Corrida desfeita (arquivada).', 'ok');
    carregarImporteAutomatico();
  } catch (falha) {
    if (token) aviso(mensagem(falha.codigo), 'erro');
  }
}

async function carregarUltimoDisparo() {
  carregarImporteAutomatico();
  carregarAgendamentos();
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
    carregarOperadores();
  } catch (erro) {
    if (token) aviso(mensagem(erro.codigo), 'erro');
  }
});

// ---- preferências (só neste navegador) ------------------------------------------------------------

const PREFS_CHAVE = 'runpass-admin-prefs';

function lerPrefsSalvas() {
  try { return lerPrefs(window.localStorage.getItem(PREFS_CHAVE)); } catch { return lerPrefs(''); }
}

function salvarPrefs(prefs) {
  try { window.localStorage.setItem(PREFS_CHAVE, JSON.stringify(prefs)); return true; } catch { return false; }
}

function aplicarTema(tema) {
  if (tema === 'claro' || tema === 'escuro') document.documentElement.dataset.tema = tema;
  else delete document.documentElement.dataset.tema;
}

function montarPreferencias() {
  const prefs = lerPrefsSalvas();
  $('pref-tema').replaceChildren(...Object.entries(TEMAS).map(([v, t]) => el('option', { value: v }, t)));
  const visiveis = Object.entries(ABAS).filter(([, [, perm]]) => permissoes.includes(perm));
  $('pref-aba').replaceChildren(el('option', { value: '' }, 'Padrão (a primeira disponível)'), ...visiveis.map(([v, [t]]) => el('option', { value: v }, t)));
  $('pref-tema').value = prefs.tema;
  $('pref-aba').value = visiveis.some(([v]) => v === prefs.abaInicial) ? prefs.abaInicial : '';
}

function guardarPreferencias() {
  const prefs = { tema: $('pref-tema').value, abaInicial: $('pref-aba').value };
  aplicarTema(prefs.tema);
  $('pref-aviso').textContent = salvarPrefs(prefs) ? 'Preferências salvas neste navegador.' : 'Este navegador não permite salvar preferências (modo privado?). Valem só até fechar a página.';
}

aplicarTema(lerPrefsSalvas().tema);

function prepararAbas() {
  for (const [nome, [, perm]] of Object.entries(ABAS)) $(`aba-${nome}`).hidden = !permissoes.includes(perm);
  montarPreferencias();
  $('modo-catalogo').replaceChildren(...Object.entries(MODOS_CATALOGO).map(([v, t]) => el('option', { value: v }, t)));
  $('op-permissoes').replaceChildren(
    el('legend', {}, 'Permissões'),
    ...Object.entries(PERMISSOES).map(([v, t]) => el('label', {}, el('input', { type: 'checkbox', value: v }), t)),
  );
  mostrarAba(abaInicial(lerPrefsSalvas().abaInicial, permissoes));
}

for (const b of document.querySelectorAll('[data-aba]')) b.addEventListener('click', () => mostrarAba(b.dataset.aba));

// ---- login --------------------------------------------------------------------------------------

function etapa(nome) {
  for (const id of ['form-senha', 'form-nova', 'form-setup', 'form-mfa']) $(id).hidden = id !== `form-${nome}`;
}

async function abrirPainel(t) {
  iniciarSessao(t, emailTentativa);
  let info;
  try {
    info = await api('/admin/session');
  } catch (erro) {
    if (erro.tratado) {
      aviso(mensagem('NO_PORTAL_ACCESS'), 'erro'); // o login do Cognito passou, mas não há acesso ativo
      return;
    }
    aviso(mensagem(erro.codigo), 'erro'); // por ex. serviço indisponível: o painel não abre, mas a razão aparece
    throw erro;
  }
  permissoes = info.permissions || [];
  meuId = info.subject;
  if (!permissoes.some((p) => ['catalog_admin', 'user_admin', 'cost_read'].includes(p))) {
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
    if (token || erro.tratado) return;
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
    if (token || erro.tratado) return;
    aviso(mensagem(erro.codigo), 'erro');
    if (erro.codigo === 'CodeMismatchException' || erro.codigo === 'ExpiredCodeException') return;
    voltarAoInicio();
  }
});

$('voltar').addEventListener('click', () => sair());
$('sair').addEventListener('click', () => sair());
$('pref-tema').addEventListener('change', guardarPreferencias);
$('pref-aba').addEventListener('change', guardarPreferencias);
$('pref-padrao').addEventListener('click', () => {
  $('pref-tema').value = 'auto';
  $('pref-aba').value = '';
  guardarPreferencias();
});
$('atualizar').addEventListener('click', carregarPedidos);
$('atualizar-cadastros').addEventListener('click', carregarCadastros);
$('atualizar-banners').addEventListener('click', carregarBanners);
$('atualizar-operadores').addEventListener('click', carregarOperadores);
$('atualizar-custos').addEventListener('click', carregarCustos);
$('atualizar-qualidade').addEventListener('click', carregarQualidade);
$('verificar-vinculos').addEventListener('click', verificarVinculos);
$('atualizar-divergencias').addEventListener('click', carregarDivergencias);
$('atualizar-fontes').addEventListener('click', carregarFontes);
$('carregar-candidatas').addEventListener('click', carregarCandidatas);
$('baixar-aceitas').addEventListener('click', baixarAceitas);
$('atualizar-execucoes').addEventListener('click', carregarExecucoes);

// Abas horizontais dentro de uma aba (telas com mais de um assunto).
for (const barra of document.querySelectorAll('[data-subabas]')) {
  const secao = barra.closest('[data-sec]');
  barra.addEventListener('click', (evento) => {
    const botao = evento.target.closest('[data-sub-alvo]');
    if (!botao) return;
    for (const b of barra.querySelectorAll('[data-sub-alvo]')) b.setAttribute('aria-selected', String(b === botao));
    for (const bloco of secao.querySelectorAll('[data-sub]')) bloco.hidden = bloco.dataset.sub !== botao.dataset.subAlvo;
  });
}
