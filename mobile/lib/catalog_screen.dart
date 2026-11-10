import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'home_screen.dart';
import 'edition_requests.dart';
import 'identity_gateway.dart';
import 'my_races.dart';
import 'notifications.dart';
import 'runpass_theme.dart';

export 'home_screen.dart';
export 'my_races.dart';

typedef PhotoSelector = Future<List<int>?> Function();

String registrationText(String? status) => switch (status) {
  'open' => 'Inscrições abertas.',
  'closed' => 'Inscrições encerradas.',
  'sold_out' => 'Inscrições esgotadas.',
  _ => 'Situação das inscrições não informada.',
};

String displayDate(String value) {
  final parts = value.split('-');
  return parts.length == 3 ? '${parts[2]}/${parts[1]}/${parts[0]}' : value;
}

/// Motivo curto pelo qual uma edição saiu de circulação (campo `archivedReason` da API).
/// Aceita "1:30:00", "45:10" ou segundos puros. Vazio vira null; inválido ou zero vira -1.
int? parseDuration(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.length > 3 || parts.any((p) => int.tryParse(p) == null)) return -1;
  final numbers = parts.map(int.parse).toList();
  if (numbers.any((n) => n < 0)) return -1;
  if (numbers.length > 1 && numbers.skip(1).any((n) => n > 59)) return -1;
  var total = 0;
  for (final n in numbers) {
    total = total * 60 + n;
  }
  return total > 0 ? total : -1;
}

String? archivedReasonLabel(String? reason) => switch (reason) {
  'cancelled' => 'corrida cancelada pela organização',
  'unavailable' => 'corrida indisponível para inscrição ou compra',
  'duplicate' => 'cadastro duplicado, substituído por outro no catálogo',
  'ended' => 'edição encerrada',
  _ => null,
};

/// Texto completo para a tela da corrida arquivada.
String archivedNotice(String? reason) {
  final label = archivedReasonLabel(reason);
  return label == null
      ? 'Edição arquivada: o histórico está preservado e novos registros não estão disponíveis.'
      : 'Edição arquivada: $label. O histórico está preservado e novos registros não estão disponíveis.';
}

/// Toda mensagem diz o motivo e o que fazer em seguida.
String catalogError(IdentityIssue issue) => switch (issue.code) {
  'INVALID_TOKEN' || 'ACCOUNT_UNAVAILABLE' => 'Sua sessão expirou ou a conta está indisponível. Volte à tela inicial e entre novamente.',
  'BETA_ADMISSION_REQUIRED' => 'É necessário participar do período de avaliação para consultar as corridas.',
  'INVALID_CURSOR' => 'A busca ficou aberta por muito tempo e expirou. Toque em Buscar para começar de novo.',
  'INVALID_INPUT' || 'INVALID_FILTERS' => 'Algum campo está inválido (data, distância ou texto fora do limite). Confira os filtros e tente de novo.',
  'EDITION_NOT_FOUND' =>
    'Esta corrida não está mais no catálogo. Volte à lista e escolha outra.',
  'EDITION_ARCHIVED' => 'Esta edição está arquivada e não aceita novos registros. Escolha outra corrida.',
  'EDITION_CHANGED' => 'O cadastro desta corrida foi atualizado depois que você abriu a tela. Volte à lista e abra a corrida de novo.',
  'DISTANCE_NOT_IN_EDITION' => 'Esta distância foi removida da corrida. Volte e escolha uma das distâncias atuais.',
  'PARTICIPATION_EXISTS' => 'Você já tem um registro nesta corrida (só é permitido um por edição). Abra o registro existente para continuar.',
  'VERSION_CONFLICT' => 'Este registro foi alterado em outro lugar (outro aparelho ou outra tela). Feche e abra de novo antes de editar.',
  'REVIEW_NOT_FOUND' => 'A avaliação desta participação não foi encontrada. Ela só existe depois que a participação é concluída.',
  'PARTICIPATION_NOT_FOUND' =>
    'Este registro não existe mais (pode ter sido excluído). Volte à lista.',
  'DELETION_OPERATION_NOT_FOUND' =>
    'Não encontramos o pedido de exclusão. Ele pode já ter terminado.',
  'IMAGE_SIZE_INVALID' => 'A foto é maior que 10 MB. Escolha uma foto menor.',
  'IMAGE_FORMAT_INVALID' => 'O formato desta foto não é aceito (use JPEG ou PNG) e não foi possível converter. Escolha outra foto.',
  'INVALID_IMAGE' || 'FORMAT_MISMATCH' || 'PIXEL_LIMIT_EXCEEDED' => 'A foto não passou na validação (arquivo corrompido, formato diferente do informado ou imagem grande demais). Escolha outra foto; o rascunho foi preservado.',
  'PROCESSING_TIMEOUT' || 'UPLOAD_UNAVAILABLE' => 'Não foi possível enviar ou processar a foto agora (conexão ou serviço). Tente de novo; o rascunho foi preservado.',
  'IMAGE_NOT_VALID' => 'A foto escolhida ainda não foi validada. Envie a foto de novo; o rascunho foi preservado.',
  'EDITION_NOT_COMPLETABLE' => 'Esta corrida ainda não aconteceu. Só dá para concluir a participação depois da data da prova.',
  'TOO_MANY_PENDING_REQUESTS' => 'Você já tem 10 pedidos aguardando análise. Espere a equipe responder para pedir mais.',
  'REQUEST_NOT_EDITABLE' || 'REQUEST_NOT_REJECTED' => 'Este pedido não pode mais ser corrigido (ele já foi analisado ou reenviado). Atualize a lista.',
  'EDITION_REQUEST_NOT_FOUND' =>
    'Não encontramos este pedido. Volte à lista de solicitações.',
  'PARTICIPATION_NOT_DRAFT' => 'Esta participação já foi concluída ou excluída, então não pode mais ser alterada como rascunho.',
  _ => 'Não foi possível concluir agora. Pode ser falta de conexão ou instabilidade do serviço. Tente novamente em instantes.',
};

/// [subScreen]: tela interna (detalhe, rascunho). Tocar na aba já destacada leva à tela principal
/// da aba, em vez de não fazer nada.
Widget runPassNavigation(
  BuildContext context,
  IdentityGateway gateway,
  int selectedIndex, {
  bool subScreen = false,
}) => RunPassBottomNav(
  selectedIndex: selectedIndex,
  onDestinationSelected: (index) {
    if (index == selectedIndex && !subScreen) return;
    final screen = switch (index) {
      0 => RunPassHomeScreen(gateway: gateway),
      1 => CatalogScreen(gateway: gateway),
      2 => MedalCollectionScreen(gateway: gateway),
      _ => RunnerProfileScreen(gateway: gateway),
    };
    final route = MaterialPageRoute<void>(builder: (_) => screen);
    if (subScreen) {
      Navigator.of(context).pushAndRemoveUntil(route, (r) => r.isFirst);
    } else {
      Navigator.of(context).pushReplacement(route);
    }
  },
);

/// Participações (rascunho ou concluída) da pessoa por edição, para marcar "já está na sua lista".
/// Falhas deixam o mapa vazio: a marca é só uma ajuda e nunca bloqueia a tela.
Future<Map<String, Map<String, dynamic>>> loadMyEditions(
  IdentityGateway gateway,
) async {
  final mine = <String, Map<String, dynamic>>{};
  try {
    String? cursor;
    var pages = 0;
    do {
      final page = await gateway.request(
        '/me/participations',
        query: {'limit': '100', 'cursor': ?cursor},
      );
      for (final item in (page['items'] as List? ?? const [])) {
        final map = Map<String, dynamic>.from(item as Map);
        final id = map['editionId'];
        if (id is String &&
            (map['state'] == 'draft' || map['state'] == 'completed')) {
          mine[id] = map;
        }
      }
      cursor = page['nextCursor'] as String?;
    } while (cursor != null && ++pages < 5);
  } on Exception {
    return mine;
  }
  return mine;
}

class CatalogScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const CatalogScreen({super.key, required this.gateway});
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final fields = {
    for (final key in [
      'namePrefix',
      'city',
      'state',
      'distanceKm',
      'dateFrom',
      'dateTo',
    ])
      key: TextEditingController(),
  };
  final form = GlobalKey<FormState>();
  // Busca por frase livre (rota /editions/search). Com frase, os campos abaixo sao ignorados.
  final phrase = TextEditingController();
  Map<String, dynamic>? searchInfo;
  final items = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> mine = {};
  Map<String, String> activeFilters = {};
  String? nextCursor, error;
  // Situacao das inscricoes (filtro): nulo = qualquer.
  String? registration;
  int registrationEpoch =
      0; // recria o seletor ao limpar (reset() devolveria o valor antigo)
  bool loading = false;
  bool showFilters = false;

  @override
  void initState() {
    super.initState();
    load();
    loadMine();
  }

  Future<void> loadMine() async {
    final result = await loadMyEditions(widget.gateway);
    if (mounted) setState(() => mine = result);
  }

  @override
  void dispose() {
    phrase.dispose();
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    if (!more && !(form.currentState?.validate() ?? true)) return;
    final sentence = phrase.text.trim();
    if (!more) {
      activeFilters = sentence.isNotEmpty
          ? {}
          : {
              for (final entry in fields.entries)
                if (entry.value.text.trim().isNotEmpty)
                  entry.key: entry.value.text.trim(),
              'registrationStatus': ?registration,
            };
      searchInfo = null;
      items.clear();
      nextCursor = null;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final bySentence = !more && sentence.isNotEmpty;
      final page = await widget.gateway.request(
        bySentence ? '/editions/search' : '/editions',
        query: bySentence
            ? {'phrase': sentence, 'limit': '20'}
            : {
                ...activeFilters,
                'limit': '20',
                if (more && nextCursor != null) 'cursor': nextCursor!,
              },
      );
      if (!mounted) return;
      if (bySentence) {
        // As proximas paginas usam GET /editions com os filtros que o servidor resolveu.
        searchInfo = Map<String, dynamic>.from(page['search'] as Map);
        activeFilters = {
          for (final e in (searchInfo!['filters'] as Map).entries)
            e.key as String: '${e.value}',
        };
      }
      final known = items.map((e) => e['id']).toSet();
      for (final entry
          in (page['items'] as List).cast<Map<String, dynamic>>()) {
        if (known.add(entry['id'])) items.add(entry);
      }
      nextCursor = page['nextCursor'] as String?;
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Aviso honesto sobre a busca por frase: o que o catalogo nao filtra e quando a IA nao respondeu.
  String? get searchNotice {
    final info = searchInfo;
    if (info == null) return null;
    const labels = {
      'preco_max_brl': 'preço',
      'altimetria': 'altimetria',
      'distancia_max_km': 'distância máxima',
      'consulta_semantica': 'o tema da frase',
      'raio_km': 'proximidade ("perto de mim")',
    };
    final skipped = (info['notApplied'] as List? ?? const [])
        .map((k) => labels[k] ?? '$k')
        .toList();
    final parts = [
      if (info['source'] == 'text') 'Não foi possível interpretar a frase agora. Mostrando a busca pelo nome.',
      if (skipped.isNotEmpty)
        'Não filtrei por: ${skipped.join(', ')}. Os resultados não consideram isso.',
    ];
    return parts.isEmpty ? null : parts.join('\n');
  }

  void openMyRequests() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MyEditionRequestsScreen(gateway: widget.gateway),
    ),
  );

  Future<void> requestRace() async {
    final sent = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => EditionRequestFormScreen(
          gateway: widget.gateway,
          prefill: {
            if (phrase.text.trim().isNotEmpty) 'name': phrase.text.trim(),
            if ((fields['city']?.text.trim() ?? '').isNotEmpty)
              'city': fields['city']!.text.trim(),
          },
        ),
      ),
    );
    if (sent != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pedido enviado. Acompanhe em "Minhas solicitações".'),
        ),
      );
    }
  }

  void clearSearch() {
    if (loading) return;
    phrase.clear();
    for (final controller in fields.values) {
      controller.clear();
    }
    form.currentState?.reset();
    setState(() {
      registration = null;
      registrationEpoch++;
    });
    load();
  }

  Widget filter(
    String key,
    String label, {
    String? Function(String)? validate,
    int? maxLength,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      controller: fields[key],
      maxLength: maxLength,
      decoration: InputDecoration(labelText: label),
      keyboardType: key == 'distanceKm'
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      validator: (value) => value == null || value.trim().isEmpty
          ? null
          : validate?.call(value.trim()),
    ),
  );

  String? dateValidator(String value) {
    final parsed = DateTime.tryParse(value);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        parsed == null ||
        parsed.toIso8601String().substring(0, 10) != value) {
      return 'Use uma data válida no formato AAAA-MM-DD.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const RunPassWordmark(compact: true),
      actions: [
        IconButton(
          key: const Key('catalog-search-toggle'),
          tooltip: showFilters ? 'Fechar filtros' : 'Filtrar corridas',
          icon: Icon(showFilters ? Icons.close_rounded : Icons.search_rounded),
          onPressed: () {
            if (showFilters && activeFilters.isNotEmpty) {
              // Ao fechar os filtros, volta a lista completa (a frase digitada fica).
              for (final controller in fields.values) {
                controller.clear();
              }
              registration = null;
              registrationEpoch++;
              load();
            }
            setState(() => showFilters = !showFilters);
          },
        ),
        NotificationBell(gateway: widget.gateway),
        const SizedBox(width: 8),
      ],
    ),
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 1),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              key: const Key('catalog-phrase'),
              controller: phrase,
              maxLength: 200,
              buildCounter: (
                _, {
                required currentLength,
                required isFocused,
                maxLength,
              }) => null,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => load(),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Descreva a corrida',
                hintText: 'Ex.: meia maratona em abril',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: phrase.text.isEmpty
                    ? null
                    : IconButton(
                        key: const Key('catalog-phrase-clear'),
                        tooltip: 'Limpar a frase',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: loading
                            ? null
                            : () {
                                phrase.clear();
                                load();
                              },
                      ),
              ),
            ),
          ),
          if (showFilters)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: form,
                  child: Column(
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Encontre sua próxima conquista',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Se houver uma frase acima, estes filtros são ignorados.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      filter(
                        'namePrefix',
                        'Início do nome da corrida',
                        maxLength: 160,
                      ),
                      filter('city', 'Cidade', maxLength: 100),
                      filter(
                        'state',
                        'Estado (UF)',
                        maxLength: 2,
                        validate: (value) =>
                            RegExp(r'^[A-Za-z]{2}$').hasMatch(value)
                            ? null
                            : 'Informe a UF.',
                      ),
                      filter(
                        'distanceKm',
                        'Distância em km',
                        validate: (value) {
                          final km = double.tryParse(value);
                          return km != null && km.isFinite && km > 0
                              ? null
                              : 'Informe uma distância positiva, usando ponto para decimais.';
                        },
                      ),
                      filter(
                        'dateFrom',
                        'Data inicial (AAAA-MM-DD)',
                        validate: dateValidator,
                      ),
                      filter(
                        'dateTo',
                        'Data final (AAAA-MM-DD)',
                        validate: dateValidator,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: DropdownButtonFormField<String?>(
                          key: ValueKey(
                            'filter-registration-$registrationEpoch',
                          ),
                          initialValue: registration,
                          decoration: const InputDecoration(
                            labelText: 'Inscrições',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: null,
                              child: Text('Qualquer situação'),
                            ),
                            DropdownMenuItem(
                              value: 'open',
                              child: Text('Abertas'),
                            ),
                            DropdownMenuItem(
                              value: 'closed',
                              child: Text('Encerradas'),
                            ),
                            DropdownMenuItem(
                              value: 'sold_out',
                              child: Text('Esgotadas'),
                            ),
                            DropdownMenuItem(
                              value: 'unknown',
                              child: Text('Não informada'),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => registration = value),
                        ),
                      ),
                      FilledButton(
                        onPressed: loading ? null : () => load(),
                        child: const Text('Buscar'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: loading ? null : clearSearch,
                        child: const Text('Limpar busca'),
                      ),
                      const Divider(height: 32),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Não encontrou a corrida?',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Peça o cadastro. A equipe pesquisa os pedidos periodicamente, confere a fonte e o resultado aparece em "Minhas solicitações".',
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        key: const Key('catalog-request-new'),
                        onPressed: loading ? null : requestRace,
                        child: const Text('Pedir cadastro da corrida'),
                      ),
                      TextButton(
                        key: const Key('catalog-request-mine'),
                        onPressed: openMyRequests,
                        child: const Text('Minhas solicitações'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (searchNotice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                searchNotice!,
                key: const Key('catalog-search-notice'),
              ),
            ),
          if (error != null) ...[
            Text(error!, key: const Key('catalog-error')),
            TextButton(
              onPressed: loading ? null : () => load(more: nextCursor != null),
              child: const Text('Tentar novamente'),
            ),
          ],
          if (loading) const Center(child: CircularProgressIndicator()),
          if (!loading && error == null && items.isEmpty)
            Text(
              nextCursor == null
                  ? 'Nenhuma corrida encontrada com esses filtros.'
                  : 'Nenhuma corrida nesta página. Continue a busca.',
            ),
          if (!loading && error == null && items.isEmpty && nextCursor == null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('catalog-request-empty'),
                onPressed: requestRace,
                child: const Text('Não encontrou? Pedir cadastro da corrida'),
              ),
            ),
          for (final edition in items)
            Card(
              color: edition['status'] == 'archived' ? context.panelCard : null,
              child: ListTile(
                textColor: edition['status'] == 'archived'
                    ? context.archivedText
                    : null,
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: edition['status'] == 'archived'
                        ? context.panelStrong
                        : runPassOrange.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    edition['status'] == 'archived'
                        ? Icons.inventory_2_outlined
                        : Icons.directions_run,
                    color: edition['status'] == 'archived'
                        ? context.archivedText
                        : runPassOrange,
                  ),
                ),
                title: Text(edition['name'] as String),
                subtitle: Text(
                  '${displayDate(edition['date'] as String)} · ${edition['city']}/${edition['state']}\n'
                  '${(edition['distances'] as List).map((d) => '${d['kilometers']} km').join(' · ')}'
                  '${edition['status'] == 'archived' ? '\nArquivada: ${archivedReasonLabel(edition['archivedReason'] as String?) ?? 'motivo não informado'}' : ''}'
                  '${mine.containsKey(edition['id']) ? '\nJá está na sua lista' : ''}',
                ),
                isThreeLine: true,
                trailing: mine.containsKey(edition['id'])
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: runPassOrange,
                        semanticLabel: 'Já está na sua lista',
                      )
                    : null,
                onTap: loading
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EditionScreen(
                              gateway: widget.gateway,
                              editionId: edition['id'] as String,
                            ),
                          ),
                        );
                        loadMine();
                      },
              ),
            ),
          if (nextCursor != null)
            TextButton(
              onPressed: loading ? null : () => load(more: true),
              child: const Text('Carregar mais'),
            ),
        ],
      ),
    ),
  );
}

class EditionScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String editionId;
  const EditionScreen({
    super.key,
    required this.gateway,
    required this.editionId,
  });
  @override
  State<EditionScreen> createState() => _EditionScreenState();
}

class _EditionScreenState extends State<EditionScreen> {
  Map<String, dynamic>? edition;
  String? selectedDistance, error;
  bool loading = true, saving = false, loadingReviews = false;
  List<Map<String, dynamic>>? reviews;
  Map<String, dynamic>? reviewSummary;
  bool showAllReviews = false;
  Map<String, dynamic>? mine;
  Map<String, dynamic>? myReview;

  static const criteria = [
    ('organization', 'Organização', Icons.groups_outlined),
    ('course', 'Percurso', Icons.alt_route),
    ('kit', 'Kit', Icons.card_giftcard),
    ('medal', 'Medalha', Icons.workspace_premium_outlined),
    ('hydration', 'Hidratação', Icons.water_drop_outlined),
    ('facilities', 'Estrutura', Icons.wc_outlined),
    ('safety', 'Segurança', Icons.health_and_safety_outlined),
    ('valueForMoney', 'Custo-benefício', Icons.savings_outlined),
  ];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}',
      );
      if (mounted) edition = result;
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (mounted && edition != null) {
      loadReviews();
      loadMyParticipation();
    }
  }

  /// Participação desta pessoa nesta edição, se já existir (rascunho ou concluída).
  Future<void> loadMyParticipation() async {
    final all = await loadMyEditions(widget.gateway);
    final found = all[widget.editionId];
    if (!mounted || found == null) return;
    setState(() {
      mine = found;
      selectedDistance ??= found['distanceId'] as String?;
    });
    if (found['state'] == 'completed') loadMyReview(found['id'] as String);
  }

  /// Avaliação que a própria pessoa já cadastrou para esta corrida.
  Future<void> loadMyReview(String participationId) async {
    try {
      final review = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(participationId)}/review',
      );
      if (mounted) setState(() => myReview = review);
    } on Exception {
      if (mounted) setState(() => myReview = null);
    }
  }

  Widget myReviewCard() {
    final participation = mine;
    if (participation == null) return const SizedBox.shrink();
    final review = myReview;
    if (participation['state'] != 'completed' || review == null) {
      return participation['state'] == 'draft'
          ? const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text(
                'Sua avaliação aparece aqui depois que você concluir a participação.',
              ),
            )
          : const SizedBox.shrink();
    }
    return MyReviewView(
      review: review,
      onEdit: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ReviewEditScreen(
              gateway: widget.gateway,
              participationId: participation['id'] as String,
            ),
          ),
        );
        if (mounted) loadMyReview(participation['id'] as String);
      },
    );
  }

  Future<void> openMine() async {
    final existing = mine;
    if (existing == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: existing,
        ),
      ),
    );
    if (mounted) loadMyParticipation();
  }

  /// Public reviews for the selected distance. Unavailable reviews leave the
  /// tab with the score only; they never block the rest of the screen.
  Future<void> loadReviews() async {
    setState(() => loadingReviews = true);
    try {
      final page = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/reviews',
        query: {'limit': '50', 'distanceId': ?selectedDistance},
      );
      if (mounted) {
        reviews = (page['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        reviewSummary = (page['summary'] as Map?)?.cast<String, dynamic>();
      }
    } on Exception {
      if (mounted) {
        reviews = null;
        reviewSummary = null;
      }
    } finally {
      if (mounted) setState(() => loadingReviews = false);
    }
  }

  void soon(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  double? average(String key) {
    final values = [
      for (final review in reviews ?? const <Map<String, dynamic>>[])
        (review['ratings'] as Map?)?[key] as num?,
    ].whereType<num>().toList();
    return values.isEmpty
        ? null
        : values.reduce((a, b) => a + b) / values.length;
  }

  double reviewAverage(Map<String, dynamic> review) {
    final ratings = ((review['ratings'] as Map?) ?? const {}).values
        .whereType<num>();
    return ratings.isEmpty
        ? 0
        : ratings.reduce((a, b) => a + b) / ratings.length;
  }

  String thousands(int value) => value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => '.',
  );

  Widget hero(Map<String, dynamic> body) => Container(
    height: 200,
    width: double.infinity,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [runPassNavy, Color(0xff5a2a1c), runPassOrange],
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: Stack(
        children: [
          Positioned(
            left: 8,
            top: 4,
            child: IconButton(
              tooltip: 'Voltar',
              color: Colors.white,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Positioned(
            right: 8,
            top: 4,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Quero correr',
                  color: Colors.white,
                  icon: const Icon(Icons.favorite_border),
                  onPressed: () => soon('Lista Quero correr em breve.'),
                ),
                IconButton(
                  tooltip: 'Compartilhar',
                  color: Colors.white,
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => soon('Compartilhamento em breve.'),
                ),
              ],
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 20,
            child: Text(
              (body['name'] as String).toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 24,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget distanceSelector(Map<String, dynamic> body) {
    final archived = body['status'] == 'archived';
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: archived ? context.panelStrong : context.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final distance in body['distances'] as List)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(11),
                onTap: archived
                    ? null
                    : () {
                        setState(
                          () => selectedDistance = distance['id'] as String,
                        );
                        loadReviews();
                      },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selectedDistance == distance['id']
                        ? runPassOrange
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    distanceLabel((distance['kilometers'] as num).toDouble()),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: archived
                          ? context.archivedText
                          : selectedDistance == distance['id']
                          ? Colors.white
                          : context.onSurfaceText,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget header(Map<String, dynamic> body) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.calendar_today_outlined, size: 16),
          const SizedBox(width: 6),
          Text(displayDate(body['date'] as String)),
          const SizedBox(width: 16),
          const Icon(Icons.place_outlined, size: 16),
          const SizedBox(width: 4),
          Expanded(child: Text('${body['city']}/${body['state']}')),
        ],
      ),
      const SizedBox(height: 14),
      if (mine != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: const [
              Icon(Icons.check_circle_rounded, color: runPassOrange, size: 18),
              SizedBox(width: 6),
              Text(
                'Esta corrida está na sua lista',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      distanceSelector(body),
      if (body['status'] == 'archived')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(archivedNotice(body['archivedReason'] as String?)),
        ),
      const SizedBox(height: 16),
    ],
  );

  Widget aboutTab(Map<String, dynamic> body) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      header(body),
      if (body['description'] != null) Text(body['description'] as String),
      if (body['organizerName'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('Organização: ${body['organizerName']}'),
        ),
      if ((body['distances'] as List).any(
        (d) =>
            d['medalImageReference'] != null ||
            body['medalImageReference'] != null,
      ))
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Imagem oficial da medalha disponível'),
        ),
      if (selectedDistance != null)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Distância selecionada.'),
        ),
      if (mine != null) ...[
        const SizedBox(height: 16),
        Row(
          key: const Key('already-mine'),
          children: const [
            Icon(Icons.check_circle_rounded, color: runPassOrange),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Esta corrida já está na sua lista.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: openMine,
          child: Text(
            mine!['state'] == 'completed'
                ? 'Editar minha participação'
                : 'Editar meu rascunho',
          ),
        ),
      ] else if (selectedDistance != null) ...[
        const SizedBox(height: 16),
        FilledButton(
          onPressed: saving ? null : createDraft,
          child: Text(saving ? 'Salvando...' : 'Criar rascunho'),
        ),
      ],
      // Informacoes da fonte ao fim da aba, sem empurrar as acoes da pessoa.
      const SizedBox(height: 16),
      if (body['venue'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Local: ${body['venue']}'),
        ),
      // Nunca afirma que as inscricoes estao abertas quando a fonte nao informou.
      Padding(
        key: const Key('registration-info'),
        padding: const EdgeInsets.only(top: 8),
        child: Text(registrationText(body['registrationStatus'] as String?)),
      ),
      if (body['lastVerifiedAt'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Informação conferida em ${displayDate((body['lastVerifiedAt'] as String).substring(0, 10))}.',
            key: const Key('verified-info'),
            style: TextStyle(fontSize: 12, color: context.muted),
          ),
        ),
    ],
  );

  Future<void> createDraft() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final draft = await widget.gateway.request(
        '/participations',
        method: 'POST',
        body: {'editionId': widget.editionId, 'distanceId': selectedDistance},
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ParticipationDraftScreen(gateway: widget.gateway, initial: draft),
        ),
      );
    } on IdentityIssue catch (issue) {
      if (issue.code == 'PARTICIPATION_EXISTS') {
        await openExistingDraft();
      } else if (mounted) {
        error = catalogError(issue);
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Já existe um registro desta edição: se for um rascunho, abre-o para continuar.
  Future<void> openExistingDraft() async {
    Map<String, dynamic>? existing;
    try {
      final page = await widget.gateway.request(
        '/me/participations',
        query: {'state': 'draft', 'limit': '100'},
      );
      for (final item in (page['items'] as List? ?? const [])) {
        if ((item as Map)['editionId'] == widget.editionId) {
          existing = Map<String, dynamic>.from(item);
          break;
        }
      }
    } on IdentityIssue {
      existing = null;
    }
    if (!mounted) return;
    if (existing == null) {
      setState(
        () => error = catalogError(const IdentityIssue('PARTICIPATION_EXISTS')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: existing!,
        ),
      ),
    );
  }

  /// Item avaliado: estrelas douradas; sem avaliações ficam vazias (só o contorno).
  Widget bar(String label, IconData icon, double? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        SizedBox(width: 118, child: Text(label)),
        Expanded(child: Stars(value ?? 0, size: 20)),
        SizedBox(
          width: 42,
          child: Text(
            value == null ? '-' : decimalPt(value),
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );

  Widget scoreCard(Map<String, dynamic> body) {
    final score = body['runScore'] as Map<String, dynamic>?;
    final loaded = reviews ?? const <Map<String, dynamic>>[];
    final summary = reviewSummary;
    final value =
        (summary?['average'] as num?) ??
        (score?['value'] is num
            ? score!['value'] as num
            : num.tryParse('${score?['value'] ?? ''}')) ??
        (loaded.isEmpty
            ? null
            : loaded.map(reviewAverage).reduce((a, b) => a + b) /
                  loaded.length);
    if (value == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Esta prova ainda não tem avaliações.',
            key: const Key('reviews-none'),
            style: TextStyle(color: context.muted),
          ),
        ),
      );
    }
    final count =
        (summary?['reviewCount'] as num?)?.toInt() ??
        (score?['reviewCount'] as num?)?.toInt() ??
        loaded.length;
    final recommend =
        (summary?['recommendPercent'] as num?)?.toInt() ??
        (loaded.isEmpty
            ? null
            : (100 *
                      loaded.where((r) => reviewAverage(r) >= 4).length /
                      loaded.length)
                  .round());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Text(
                    decimalPt(value),
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stars(value, size: 17),
                        Text(
                          '${thousands(count)} avaliações',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (recommend != null) ...[
          const SizedBox(width: 10),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.greenFill,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Color(0xff2f9e5e),
                        size: 20,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$recommend%',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    'recomendariam\nesta prova',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget reviewTile(Map<String, dynamic> review) {
    final created = DateTime.tryParse(review['createdAt'] as String? ?? '');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: context.softFill,
                  child: Icon(Icons.person, color: runPassOrange),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        review['authorName'] as String? ?? 'Corredor RunPass',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Row(
                        children: [
                          Stars(reviewAverage(review), size: 14),
                          if (created != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              timeAgo(created),
                              style: TextStyle(
                                fontSize: 12,
                                color: context.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.more_horiz),
              ],
            ),
            if (review['comment'] != null) ...[
              const SizedBox(height: 10),
              Text(review['comment'] as String),
            ],
          ],
        ),
      ),
    );
  }

  Widget reviewsTab(Map<String, dynamic> body) {
    final loaded = reviews;
    final byCriterion = (reviewSummary?['byCriterion'] as Map?) ?? const {};
    double? criterion(String key) =>
        (byCriterion[key] as num?)?.toDouble() ?? average(key);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        header(body),
        myReviewCard(),
        scoreCard(body),
        const SizedBox(height: 14),
        for (final (key, label, icon) in criteria)
          bar(label, icon, criterion(key)),
        const SizedBox(height: 18),
        if (loadingReviews)
          const Center(child: CircularProgressIndicator())
        else if (loaded == null)
          const Text(
            'A lista pública de avaliações não pôde ser carregada agora. As suas aparecem acima.',
          )
        else if (loaded.isNotEmpty) ...[
          Row(
            children: [
              const Expanded(
                child: Text(
                  'O que os corredores estão dizendo',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
              if (loaded.length > 3)
                TextButton(
                  key: const Key('reviews-show-all'),
                  onPressed: () =>
                      setState(() => showAllReviews = !showAllReviews),
                  child: Text(showAllReviews ? 'Ver menos' : 'Ver todas'),
                ),
            ],
          ),
          for (final review in showAllReviews ? loaded : loaded.take(3)) ...[
            reviewTile(review),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }

  Widget emptyTab(IconData icon, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: context.muted),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );

  Widget participantsTab(Map<String, dynamic> body) {
    final count = (body['participantCount'] as num?)?.toInt();
    return emptyTab(
      Icons.groups_outlined,
      count == null
          ? 'A lista de participantes estará disponível em breve.'
          : '${thousands(count)} corredores já concluíram esta prova.\nA lista de participantes estará disponível em breve.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = edition;
    return Scaffold(
      appBar: loading || error != null || body == null
          ? AppBar(title: const Text('Detalhes da corrida'))
          : null,
      bottomNavigationBar: runPassNavigation(
        context,
        widget.gateway,
        1,
        subScreen: true,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  TextButton(
                    onPressed: load,
                    child: const Text('Tentar novamente'),
                  ),
                ],
              ),
            )
          : body == null
          ? const SizedBox.shrink()
          : DefaultTabController(
              length: 4,
              child: Column(
                children: [
                  hero(body),
                  Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: TabBar(
                      labelColor: runPassOrange,
                      indicatorColor: runPassOrange,
                      labelStyle: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                      unselectedLabelColor: context.onSurfaceText,
                      tabs: [
                        Tab(text: 'Sobre'),
                        Tab(text: 'Avaliações'),
                        Tab(text: 'Fotos'),
                        Tab(text: 'Participantes'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        aboutTab(body),
                        reviewsTab(body),
                        emptyTab(
                          Icons.photo_library_outlined,
                          'As fotos desta prova aparecerão aqui.',
                        ),
                        participantsTab(body),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Avaliação da própria pessoa, só leitura: oito critérios com estrelas e o comentário.
class MyReviewView extends StatelessWidget {
  final Map<String, dynamic> review;
  final VoidCallback? onEdit;
  const MyReviewView({super.key, required this.review, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final ratings = (review['ratings'] as Map?) ?? const {};
    final comment = review['comment'] as String?;
    return Card(
      key: const Key('my-review'),
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Minha avaliação',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 6),
            for (final (key, label, icon) in _EditionScreenState.criteria)
              if (ratings[key] is num)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(label)),
                      Stars(ratings[key] as num, size: 18),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${ratings[key]}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
            if (comment != null && comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('“$comment”'),
            ],
            if (onEdit != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onEdit,
                  child: const Text('Editar avaliação'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Nota de 1 a 5 estrelas para um critério, com o ícone do critério (como no mockup).
class RatingInput extends StatelessWidget {
  final String label;
  final IconData icon;
  final int value;
  final ValueChanged<int>? onChanged;
  const RatingInput({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        for (var star = 1; star <= 5; star++)
          IconButton(
            key: Key('rating-$label-$star'),
            tooltip: '$label: $star de 5',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 40),
            icon: Icon(
              star <= value ? Icons.star_rounded : Icons.star_border_rounded,
              color: runPassGold,
              size: 28,
            ),
            onPressed: onChanged == null ? null : () => onChanged!(star),
          ),
      ],
    ),
  );
}

class ParticipationDraftScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> initial;
  final PhotoSelector? photoSelector;
  const ParticipationDraftScreen({
    super.key,
    required this.gateway,
    required this.initial,
    this.photoSelector,
  });

  @override
  State<ParticipationDraftScreen> createState() =>
      _ParticipationDraftScreenState();
}

class _ParticipationDraftScreenState extends State<ParticipationDraftScreen> {
  late Map<String, dynamic> draft;
  late final TextEditingController time, placement, bib;
  late final TextEditingController comment;
  String? message;
  bool saving = false, uploading = false;
  String? imageReference, pendingUploadId;
  bool declaredCompleted = false, publishToFeed = false;
  DateTime? editionDate;
  Map<String, dynamic>? review;
  List<Map<String, dynamic>> distances = const [];
  String? distanceId;
  // Mantem a foto validada e a avaliacao quando a pessoa volta para esta tela.
  static final Map<String, Map<String, dynamic>> formCache = {};
  int photoRevision = 0;
  // Comeca vazio (0): a pessoa precisa dar uma nota de 1 a 5 em cada criterio.
  final ratings = {
    'organization': 0,
    'course': 0,
    'kit': 0,
    'medal': 0,
    'hydration': 0,
    'facilities': 0,
    'safety': 0,
    'valueForMoney': 0,
  };
  bool get ratingsComplete => ratings.values.every((v) => v >= 1);

  @override
  void initState() {
    super.initState();
    draft = Map<String, dynamic>.from(widget.initial);
    distanceId = draft['distanceId'] as String?;
    final seconds = draft['timeSeconds'];
    time = TextEditingController(
      text: seconds is num ? formatDuration(seconds.toInt()) : '',
    );
    placement = TextEditingController(
      text: draft['placement']?.toString() ?? '',
    );
    bib = TextEditingController(text: draft['bibNumber'] as String? ?? '');
    comment = TextEditingController();
    final saved = formCache[draft['id']];
    if (saved != null && draft['state'] == 'draft') {
      imageReference = saved['imageReference'] as String?;
      declaredCompleted = saved['declaredCompleted'] == true;
      publishToFeed = saved['publishToFeed'] == true;
      comment.text = saved['comment'] as String? ?? '';
      ratings.addAll(Map<String, int>.from(saved['ratings'] as Map));
    }
    loadEditionDate();
    if (draft['state'] == 'completed') loadReview();
  }

  Future<void> loadReview() async {
    final id = draft['id'];
    if (id is! String) return;
    try {
      final result = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}/review',
      );
      if (mounted) setState(() => review = result);
    } on Exception {
      if (mounted) setState(() => review = null);
    }
  }

  Future<void> loadEditionDate() async {
    final id = draft['editionId'];
    if (id is! String) return;
    try {
      final edition = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(id)}',
      );
      final parsed = DateTime.tryParse(edition['date'] as String? ?? '');
      final list = (edition['distances'] as List? ?? const [])
          .whereType<Map>()
          .map((d) => Map<String, dynamic>.from(d))
          .toList();
      if (mounted) {
        setState(() {
          if (parsed != null && draft['state'] == 'draft') editionDate = parsed;
          distances = list;
        });
      }
    } on Exception {
      // Sem a data, o servidor continua validando a conclusao.
    }
  }

  bool get upcoming {
    final date = editionDate;
    if (date == null) return false;
    final now = DateTime.now();
    return date.isAfter(DateTime(now.year, now.month, now.day));
  }

  @override
  void dispose() {
    if (draft['state'] == 'draft') {
      formCache[draft['id'] as String] = {
        'imageReference': imageReference,
        'declaredCompleted': declaredCompleted,
        'publishToFeed': publishToFeed,
        'comment': comment.text,
        'ratings': Map<String, int>.from(ratings),
      };
    } else {
      formCache.remove(draft['id']);
    }
    time.dispose();
    placement.dispose();
    bib.dispose();
    comment.dispose();
    super.dispose();
  }

  int? positive(String value) {
    if (value.trim().isEmpty) return null;
    final parsed = int.tryParse(value);
    return parsed != null && parsed > 0 ? parsed : -1;
  }

  /// Meus dados desta corrida: distância, tempo, colocação e número de peito.
  List<Widget> raceDataFields({required String saveLabel}) => [
    if (distances.length > 1)
      DropdownButtonFormField<String>(
        key: const Key('distance-field'),
        initialValue: distanceId,
        decoration: const InputDecoration(labelText: 'Distância'),
        items: [
          for (final d in distances)
            DropdownMenuItem(
              value: d['id'] as String,
              child: Text(distanceLabel((d['kilometers'] as num).toDouble())),
            ),
        ],
        onChanged: saving
            ? null
            : (value) => setState(() => distanceId = value),
      ),
    TextField(
      controller: time,
      keyboardType: TextInputType.datetime,
      decoration: const InputDecoration(
        labelText: 'Tempo (h:mm:ss ou segundos, opcional)',
      ),
    ),
    TextField(
      controller: placement,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Colocação (opcional)'),
    ),
    TextField(
      controller: bib,
      maxLength: 40,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: 'Número de peito (opcional)',
      ),
    ),
    FilledButton(
      onPressed: saving ? null : save,
      child: Text(saving ? 'Salvando...' : saveLabel),
    ),
  ];

  Future<void> save() async {
    final seconds = parseDuration(time.text), place = positive(placement.text);
    if (seconds == -1 || place == -1 || bib.text.length > 40) {
      setState(
        () => message = 'O tempo deve ser como 1:30:00 (ou só segundos), a colocação um número inteiro maior que zero e o número de peito ter no máximo 40 caracteres.',
      );
      return;
    }
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'PATCH',
        body: {
          'expectedVersion': draft['version'],
          'timeSeconds': seconds,
          'placement': place,
          'bibNumber': bib.text.trim().isEmpty ? null : bib.text.trim(),
          if (distanceId != null && distanceId != draft['distanceId'])
            'distanceId': distanceId,
        },
      );
      if (mounted) {
        message = draft['state'] == 'completed'
            ? 'Dados da corrida salvos.'
            : 'Rascunho salvo. Nada foi publicado.';
      }
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> selectPhoto() async {
    setState(() {
      uploading = true;
      message = null;
    });
    try {
      List<int>? bytes;
      if (widget.photoSelector != null) {
        bytes = await widget.photoSelector!();
      } else {
        final file = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 5000,
          maxHeight: 5000,
          imageQuality: 85,
          requestFullMetadata: false,
        );
        bytes = await file?.readAsBytes();
      }
      if (bytes == null) return;
      final contentType =
          bytes.length >= 3 &&
              bytes[0] == 0xff &&
              bytes[1] == 0xd8 &&
              bytes[2] == 0xff
          ? 'image/jpeg'
          : bytes.length >= 8 &&
                bytes[0] == 0x89 &&
                bytes[1] == 0x50 &&
                bytes[2] == 0x4e &&
                bytes[3] == 0x47
          ? 'image/png'
          : null;
      if (contentType == null) {
        throw const IdentityIssue('IMAGE_FORMAT_INVALID');
      }
      final result = await widget.gateway.uploadImage(bytes, contentType);
      if (result['state'] == 'valid') {
        imageReference = result['imageReference'] as String;
        pendingUploadId = null;
        message = 'Foto validada e privada. Ainda não foi publicada.';
      } else if (result['state'] == 'failed') {
        throw IdentityIssue(result['reasonCode'] as String? ?? 'INVALID_IMAGE');
      } else {
        pendingUploadId = result['uploadId'] as String;
        message = 'Foto recebida e ainda em processamento.';
      }
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'O app não conseguiu abrir ou ler a foto escolhida. Tente de novo ou escolha outra; o rascunho foi preservado.';
      }
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  /// Corrida concluída: escolhe outra foto e troca a da medalha.
  Future<void> changeMedalPhoto() async {
    imageReference = null;
    await selectPhoto();
    if (!mounted) return;
    final reference = imageReference;
    if (reference == null) {
      setState(() {
        message ??= 'A foto ainda não foi trocada. Tente de novo.';
        if (pendingUploadId != null) {
          message = 'A foto está em processamento. Tente trocar de novo em instantes.';
        }
      });
      return;
    }
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'PATCH',
        body: {
          'expectedVersion': draft['version'],
          'medalImageReference': reference,
        },
      );
      forgetMedalPhoto(draft['id'] as String);
      photoRevision++;
      message = 'Foto da medalha atualizada.';
    } on IdentityIssue catch (issue) {
      message = catalogError(issue);
    } on Exception {
      message =
          'Não foi possível trocar a foto agora. A foto anterior foi mantida.';
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> refreshPhoto() async {
    final uploadId = pendingUploadId;
    if (uploadId == null) return;
    setState(() {
      uploading = true;
      message = null;
    });
    try {
      final result = await widget.gateway.uploadStatus(uploadId);
      if (result['state'] == 'valid') {
        imageReference = result['imageReference'] as String;
        pendingUploadId = null;
        message = 'Foto validada e privada. Ainda não foi publicada.';
      } else if (result['state'] == 'failed') {
        pendingUploadId = null;
        throw IdentityIssue(result['reasonCode'] as String? ?? 'INVALID_IMAGE');
      } else {
        message =
            'A foto continua em processamento. Tente consultar novamente.';
      }
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> complete() async {
    if (imageReference == null || !declaredCompleted) {
      setState(
        () => message = 'Para concluir, anexe uma foto validada e marque "Declaro que concluí esta corrida".',
      );
      return;
    }
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}/complete',
        method: 'POST',
        body: {
          'expectedVersion': draft['version'],
          'declaredCompleted': true,
          'ratings': ratings,
          'medalImageReference': imageReference,
          'publishToFeed': publishToFeed,
          if (comment.text.isNotEmpty) 'comment': comment.text,
        },
      );
      if (mounted) {
        message = 'Participação concluída. Avaliação e medalha foram salvas.';
        // Ao concluir, leva a pessoa para a coleção de medalhas, onde a conquista aparece.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Participação concluída. Avaliação e medalha foram salvas.',
            ),
          ),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => MedalCollectionScreen(gateway: widget.gateway),
          ),
          (route) => route.isFirst,
        );
      }
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> saveVisibility() async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'PATCH',
        body: {
          'expectedVersion': draft['version'],
          'showTime': draft['showTime'] != false,
          'showPlacement': draft['showPlacement'] != false,
        },
      );
      if (mounted) message = 'Preferências da participação atualizadas.';
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> deleteParticipation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          draft['state'] == 'draft'
              ? 'Excluir rascunho?'
              : 'Excluir participação?',
        ),
        content: Text(
          draft['state'] == 'draft'
              ? 'O rascunho privado será excluído. Você poderá criar outro nesta edição.'
              : 'A participação será ocultada imediatamente e o RunScore será recomposto.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              draft['state'] == 'draft'
                  ? 'Excluir rascunho'
                  : 'Excluir participação',
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      saving = true;
      message = null;
    });
    final wasDraft = draft['state'] == 'draft';
    try {
      await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'DELETE',
        query: {'expectedVersion': '${draft['version']}'},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasDraft ? 'Rascunho excluído.' : 'Participação excluída. Ela já não aparece nas suas medalhas; a limpeza dos dados continua em segundo plano.',
          ),
        ),
      );
      // Volta para a lista de onde a pessoa veio, em vez de ficar numa tela sem saída.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => wasDraft
              ? CatalogScreen(gateway: widget.gateway)
              : MedalCollectionScreen(gateway: widget.gateway),
        ),
        (route) => route.isFirst,
      );
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'Não foi possível excluir agora. Verifique a internet e tente de novo; nada foi alterado.';
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (draft['state'] == 'completed') {
      return Scaffold(
        appBar: AppBar(title: const RunPassWordmark(compact: true)),
        bottomNavigationBar: runPassNavigation(
          context,
          widget.gateway,
          2,
          subScreen: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            SizedBox(
              height: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ColoredBox(
                  color: context.softFill,
                  child: MedalPhoto(
                    key: ValueKey('medal-photo-$photoRevision'),
                    gateway: widget.gateway,
                    participationId: draft['id'] as String?,
                    size: 72,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('change-medal-photo'),
              onPressed: saving || uploading ? null : changeMedalPhoto,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(
                uploading ? 'Enviando foto...' : 'Trocar foto da medalha',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Participação concluída · medalha e avaliação registradas.',
            ),
            const SizedBox(height: 8),
            Text(
              draft['publishToFeed'] == true
                  ? 'Conquista publicada: quem pode ver seu perfil vê esta corrida.'
                  : 'Conquista não publicada: só você vê esta corrida.',
            ),
            const SizedBox(height: 12),
            if (review != null) MyReviewView(review: review!),
            SwitchListTile(
              value: draft['showTime'] != false,
              onChanged: saving
                  ? null
                  : (value) => setState(() => draft['showTime'] = value),
              title: const Text('Exibir meu tempo'),
            ),
            SwitchListTile(
              value: draft['showPlacement'] != false,
              onChanged: saving
                  ? null
                  : (value) => setState(() => draft['showPlacement'] = value),
              title: const Text('Exibir minha colocação'),
            ),
            FilledButton(
              onPressed: saving ? null : saveVisibility,
              child: const Text('Salvar visibilidade'),
            ),
            const Divider(height: 32),
            const Text(
              'Meus dados desta corrida',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            ...raceDataFields(saveLabel: 'Salvar dados da corrida'),
            OutlinedButton(
              onPressed: saving
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ReviewEditScreen(
                            gateway: widget.gateway,
                            participationId: draft['id'] as String,
                          ),
                        ),
                      );
                      if (mounted) loadReview();
                    },
              child: const Text('Editar avaliação'),
            ),
            TextButton(
              onPressed: saving ? null : deleteParticipation,
              child: const Text('Excluir participação'),
            ),
            if (message != null)
              Text(message!, key: const Key('completed-message')),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const RunPassWordmark(compact: true)),
      bottomNavigationBar: runPassNavigation(
        context,
        widget.gateway,
        1,
        subScreen: true,
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Rascunho da participação',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
          ),
          const SizedBox(height: 8),
          const Text('Privado · não gera medalha, avaliação ou publicação.'),
          const SizedBox(height: 4),
          const Text(
            'Rascunho criado. Preencha o que quiser e toque em Salvar rascunho.',
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                message!,
                key: const Key('draft-message'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ...raceDataFields(saveLabel: 'Salvar rascunho'),
          const SizedBox(height: 12),
          if (upcoming && draft['state'] == 'draft')
            Container(
              key: const Key('upcoming-notice'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.warnFill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Corrida futura: acontece em ${displayDate(editionDate!.toIso8601String().substring(0, 10))}. '
                'Ela fica salva como rascunho em "Minhas corridas futuras". Depois da data da prova você poderá anexar a foto, avaliar e concluir.',
              ),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: saving || uploading ? null : selectPhoto,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(uploading ? 'Enviando foto...' : 'Selecionar foto'),
            ),
            if (imageReference != null)
              const Text('Imagem validada para uso na conclusão.'),
            if (pendingUploadId != null)
              TextButton(
                onPressed: uploading ? null : refreshPhoto,
                child: const Text('Consultar processamento da foto'),
              ),
          ],
          if (imageReference != null &&
              draft['state'] == 'draft' &&
              !upcoming) ...[
            const Divider(height: 32),
            const Text(
              'Avaliação obrigatória',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final (key, label, icon) in _EditionScreenState.criteria)
              RatingInput(
                label: label,
                icon: icon,
                value: ratings[key] ?? 0,
                onChanged: saving
                    ? null
                    : (value) => setState(() => ratings[key] = value),
              ),
            TextField(
              controller: comment,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Comentário (opcional)',
              ),
            ),
            CheckboxListTile(
              value: declaredCompleted,
              onChanged: (value) =>
                  setState(() => declaredCompleted = value ?? false),
              title: const Text('Declaro que concluí esta corrida'),
            ),
            CheckboxListTile(
              value: publishToFeed,
              onChanged: (value) =>
                  setState(() => publishToFeed = value ?? false),
              title: const Text(
                'Publicar conquista quando o feed estiver disponível',
              ),
            ),
            if (!ratingsComplete)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Dê uma nota de 1 a 5 estrelas em todos os critérios para concluir.',
                ),
              ),
            FilledButton(
              onPressed: saving || !ratingsComplete ? null : complete,
              child: Text(saving ? 'Concluindo...' : 'Concluir participação'),
            ),
          ],
          if (draft['state'] == 'draft')
            TextButton(
              onPressed: saving ? null : deleteParticipation,
              child: const Text('Excluir rascunho'),
            ),
        ],
      ),
    );
  }
}

class ReviewEditScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String participationId;
  const ReviewEditScreen({
    super.key,
    required this.gateway,
    required this.participationId,
  });

  @override
  State<ReviewEditScreen> createState() => _ReviewEditScreenState();
}

class _ReviewEditScreenState extends State<ReviewEditScreen> {
  Map<String, dynamic>? review;
  final comment = TextEditingController();
  String? message;
  bool loading = true, saving = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    comment.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final result = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(widget.participationId)}/review',
      );
      if (!mounted) return;
      review = result;
      comment.text = result['comment'] as String? ?? '';
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    final current = review;
    if (current == null) return;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      review = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(widget.participationId)}/review',
        method: 'PUT',
        body: {
          'expectedVersion': current['version'],
          'ratings': current['ratings'],
          if (comment.text.isNotEmpty) 'comment': comment.text,
        },
      );
      if (mounted) message = 'Avaliação atualizada.';
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Editar avaliação')),
    bottomNavigationBar: runPassNavigation(
      context,
      widget.gateway,
      1,
      subScreen: true,
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : review == null
        ? Center(child: Text(message ?? 'Avaliação indisponível.'))
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final (key, label, icon) in _EditionScreenState.criteria)
                RatingInput(
                  label: label,
                  icon: icon,
                  value: (review!['ratings'] as Map)[key] as int,
                  onChanged: saving
                      ? null
                      : (value) => setState(
                          () => (review!['ratings'] as Map)[key] = value,
                        ),
                ),
              TextField(
                controller: comment,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Comentário (deixe vazio para remover)',
                ),
              ),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? 'Salvando...' : 'Salvar avaliação'),
              ),
              if (message != null)
                Text(message!, key: const Key('review-message')),
            ],
          ),
  );
}
