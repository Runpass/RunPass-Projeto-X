import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'home_screen.dart';
import 'identity_gateway.dart';
import 'my_races.dart';
import 'runpass_theme.dart';

export 'home_screen.dart';
export 'my_races.dart';

typedef PhotoSelector = Future<List<int>?> Function();

String displayDate(String value) {
  final parts = value.split('-');
  return parts.length == 3 ? '${parts[2]}/${parts[1]}/${parts[0]}' : value;
}

String catalogError(IdentityIssue issue) => switch (issue.code) {
  'INVALID_TOKEN' || 'ACCOUNT_UNAVAILABLE' =>
    'Sua sessão não está disponível. Volte e entre novamente.',
  'BETA_ADMISSION_REQUIRED' =>
    'É necessário participar do beta para consultar as corridas.',
  'INVALID_CURSOR' =>
    'A busca expirou. Toque em Buscar para começar novamente.',
  'INVALID_INPUT' ||
  'INVALID_FILTERS' => 'Confira os filtros, as datas e a distância informada.',
  'EDITION_NOT_FOUND' => 'Esta edição não está disponível.',
  'EDITION_ARCHIVED' ||
  'EDITION_CHANGED' => 'Esta edição mudou e não aceita um novo rascunho.',
  'DISTANCE_NOT_IN_EDITION' => 'A distância não pertence mais a esta edição.',
  'PARTICIPATION_EXISTS' => 'Você já possui um registro para esta edição.',
  'VERSION_CONFLICT' =>
    'O registro mudou em outro lugar. Reabra-o antes de editar.',
  'REVIEW_NOT_FOUND' => 'A avaliação atual não está disponível.',
  'PARTICIPATION_NOT_FOUND' => 'Esta participação não está mais disponível.',
  'DELETION_OPERATION_NOT_FOUND' =>
    'A operação de exclusão não foi encontrada.',
  'IMAGE_SIZE_INVALID' => 'A foto deve ter no máximo 10 MB.',
  'IMAGE_FORMAT_INVALID' =>
    'Escolha uma foto JPEG ou PNG. Não foi possível converter esta imagem.',
  'INVALID_IMAGE' || 'FORMAT_MISMATCH' || 'PIXEL_LIMIT_EXCEEDED' =>
    'A foto não pôde ser validada. O rascunho foi preservado.',
  'PROCESSING_TIMEOUT' || 'UPLOAD_UNAVAILABLE' =>
    'A foto não foi processada. Tente novamente; o rascunho foi preservado.',
  'IMAGE_NOT_VALID' => 'A imagem não está válida. O rascunho foi preservado.',
  'EDITION_NOT_COMPLETABLE' => 'Esta corrida ainda não pode ser concluída.',
  'PARTICIPATION_NOT_DRAFT' =>
    'Esta participação já foi concluída ou alterada.',
  _ => 'Não foi possível carregar as corridas. Tente novamente.',
};

Widget runPassNavigation(
  BuildContext context,
  IdentityGateway gateway,
  int selectedIndex,
) => RunPassBottomNav(
  selectedIndex: selectedIndex,
  onDestinationSelected: (index) {
    if (index == selectedIndex) return;
    final screen = switch (index) {
      0 => RunPassHomeScreen(gateway: gateway),
      1 => CatalogScreen(gateway: gateway),
      2 => MedalCollectionScreen(gateway: gateway),
      _ => RunnerProfileScreen(gateway: gateway),
    };
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));
  },
);

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
  final items = <Map<String, dynamic>>[];
  Map<String, String> activeFilters = {};
  String? nextCursor, error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    if (!more && !(form.currentState?.validate() ?? true)) return;
    if (!more) {
      activeFilters = {
        for (final entry in fields.entries)
          if (entry.value.text.trim().isNotEmpty)
            entry.key: entry.value.text.trim(),
      };
      items.clear();
      nextCursor = null;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.gateway.request(
        '/editions',
        query: {
          ...activeFilters,
          'limit': '20',
          if (more && nextCursor != null) 'cursor': nextCursor!,
        },
      );
      if (!mounted) return;
      final known = items.map((e) => e['id']).toSet();
      for (final entry
          in (page['items'] as List).cast<Map<String, dynamic>>()) {
        if (known.add(entry['id'])) items.add(entry);
      }
      nextCursor = page['nextCursor'] as String?;
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) error = 'Não foi possível conectar. Tente novamente.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void clearSearch() {
    if (loading) return;
    for (final controller in fields.values) {
      controller.clear();
    }
    form.currentState?.reset();
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
      actions: const [
        Icon(Icons.search_rounded),
        SizedBox(width: 16),
        Badge(child: Icon(Icons.notifications_none_rounded)),
        SizedBox(width: 18),
      ],
    ),
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 1),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                    FilledButton(
                      onPressed: loading ? null : () => load(),
                      child: const Text('Buscar'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: loading ? null : clearSearch,
                      child: const Text('Limpar busca'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
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
          for (final edition in items)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: runPassOrange.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.directions_run, color: runPassOrange),
                ),
                title: Text(edition['name'] as String),
                subtitle: Text(
                  '${displayDate(edition['date'] as String)} · ${edition['city']}/${edition['state']}\n'
                  '${(edition['distances'] as List).map((d) => '${d['kilometers']} km').join(' · ')}'
                  '${edition['status'] == 'archived' ? '\nEdição arquivada' : ''}',
                ),
                isThreeLine: true,
                onTap: loading
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => EditionScreen(
                            gateway: widget.gateway,
                            editionId: edition['id'] as String,
                          ),
                        ),
                      ),
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
      if (mounted) error = 'Não foi possível conectar. Tente novamente.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (mounted && edition != null) loadReviews();
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
      }
    } on Exception {
      if (mounted) reviews = null;
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
        color: const Color(0xffe9ecf1),
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
                      color: selectedDistance == distance['id']
                          ? Colors.white
                          : Colors.black87,
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
      Text(
        body['name'] as String,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
      ),
      const SizedBox(height: 8),
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
      distanceSelector(body),
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
      if (body['status'] == 'archived')
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'Edição arquivada: o histórico está preservado e novos registros não estão disponíveis.',
          ),
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
      if (selectedDistance != null) ...[
        const SizedBox(height: 16),
        FilledButton(
          onPressed: saving ? null : createDraft,
          child: Text(saving ? 'Salvando...' : 'Criar rascunho'),
        ),
      ],
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
      if (mounted) error = catalogError(issue);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget bar(String label, IconData icon, double? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        SizedBox(width: 118, child: Text(label)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (value ?? 0) / 5,
              minHeight: 7,
              color: runPassOrange,
              backgroundColor: const Color(0xffeceff3),
            ),
          ),
        ),
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
    final value =
        (score?['value'] as num?) ??
        (loaded.isEmpty
            ? null
            : loaded.map(reviewAverage).reduce((a, b) => a + b) /
                  loaded.length);
    if (value == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Esta prova ainda não tem avaliações.'),
        ),
      );
    }
    final count = (score?['reviewCount'] as num?)?.toInt() ?? loaded.length;
    final recommend = loaded.isEmpty
        ? null
        : (100 *
                  loaded.where((r) => reviewAverage(r) >= 4).length /
                  loaded.length)
              .round();
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
                color: const Color(0xffe6f6ec),
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
                const CircleAvatar(
                  radius: 20,
                  backgroundColor: Color(0xffffe4dc),
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
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
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
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        header(body),
        scoreCard(body),
        const SizedBox(height: 14),
        if (loadingReviews)
          const Center(child: CircularProgressIndicator())
        else if (loaded == null)
          const Text('As avaliações detalhadas ainda não estão disponíveis.')
        else if (loaded.isNotEmpty) ...[
          for (final (key, label, icon) in criteria)
            bar(label, icon, average(key)),
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'O que os corredores estão dizendo',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
              TextButton(
                onPressed: () => soon('Lista completa em breve.'),
                child: const Text('Ver todas'),
              ),
            ],
          ),
          for (final review in loaded.take(3)) ...[
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
          Icon(icon, size: 48, color: Colors.black26),
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
      bottomNavigationBar: runPassNavigation(context, widget.gateway, 1),
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
                  const Material(
                    color: Colors.white,
                    child: TabBar(
                      labelColor: runPassOrange,
                      indicatorColor: runPassOrange,
                      unselectedLabelColor: Colors.black87,
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
  bool deleted = false;
  final ratings = {
    'organization': 5,
    'course': 5,
    'kit': 5,
    'medal': 5,
    'hydration': 5,
    'facilities': 5,
    'safety': 5,
    'valueForMoney': 5,
  };
  static const ratingLabels = {
    'organization': 'Organização',
    'course': 'Percurso',
    'kit': 'Kit',
    'medal': 'Medalha',
    'hydration': 'Hidratação',
    'facilities': 'Estrutura',
    'safety': 'Segurança',
    'valueForMoney': 'Custo-benefício',
  };

  @override
  void initState() {
    super.initState();
    draft = Map<String, dynamic>.from(widget.initial);
    time = TextEditingController(text: draft['timeSeconds']?.toString() ?? '');
    placement = TextEditingController(
      text: draft['placement']?.toString() ?? '',
    );
    bib = TextEditingController(text: draft['bibNumber'] as String? ?? '');
    comment = TextEditingController();
  }

  @override
  void dispose() {
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

  Future<void> save() async {
    final seconds = positive(time.text), place = positive(placement.text);
    if (seconds == -1 || place == -1 || bib.text.length > 40) {
      setState(() => message = 'Confira tempo, colocação e número de peito.');
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
        },
      );
      if (mounted) message = 'Rascunho salvo. Nada foi publicado.';
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
        message =
            'Não foi possível selecionar a foto. O rascunho foi preservado.';
      }
    } finally {
      if (mounted) setState(() => uploading = false);
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
        () => message = 'Confirme a conclusão e use uma imagem validada.',
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
        title: const Text('Excluir participação?'),
        content: const Text(
          'A participação será ocultada imediatamente e o RunScore será recomposto.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir participação'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'DELETE',
        query: {'expectedVersion': '${draft['version']}'},
      );
      if (mounted) deleted = true;
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (deleted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Participação excluída')),
        bottomNavigationBar: runPassNavigation(context, widget.gateway, 3),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'A participação foi ocultada. A limpeza foi agendada e pode continuar em segundo plano.',
          ),
        ),
      );
    }
    if (draft['state'] == 'completed') {
      return Scaffold(
        appBar: AppBar(title: const RunPassWordmark(compact: true)),
        bottomNavigationBar: runPassNavigation(context, widget.gateway, 2),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xffffe4dc),
              ),
              child: const Icon(
                Icons.emoji_events_rounded,
                size: 40,
                color: runPassOrange,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Participação concluída · medalha e avaliação registradas.',
            ),
            const SizedBox(height: 8),
            const Text(
              'A conquista permanece privada enquanto a publicação não estiver disponível.',
            ),
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
            OutlinedButton(
              onPressed: saving
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ReviewEditScreen(
                          gateway: widget.gateway,
                          participationId: draft['id'] as String,
                        ),
                      ),
                    ),
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
      bottomNavigationBar: runPassNavigation(context, widget.gateway, 1),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Rascunho da participação',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
          ),
          const SizedBox(height: 8),
          const Text('Privado · não gera medalha, avaliação ou publicação.'),
          TextField(
            controller: time,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Tempo em segundos (opcional)',
            ),
          ),
          TextField(
            controller: placement,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Colocação (opcional)',
            ),
          ),
          TextField(
            controller: bib,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Número de peito (opcional)',
            ),
          ),
          FilledButton(
            onPressed: saving ? null : save,
            child: Text(saving ? 'Salvando...' : 'Salvar rascunho'),
          ),
          const SizedBox(height: 12),
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
          if (imageReference != null && draft['state'] == 'draft') ...[
            const Divider(height: 32),
            const Text('Avaliação obrigatória'),
            for (final entry in ratingLabels.entries)
              DropdownButtonFormField<int>(
                initialValue: ratings[entry.key],
                decoration: InputDecoration(labelText: entry.value),
                items: [1, 2, 3, 4, 5]
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text('$value')),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) ratings[entry.key] = value;
                },
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
            FilledButton(
              onPressed: saving ? null : complete,
              child: Text(saving ? 'Concluindo...' : 'Concluir participação'),
            ),
          ],
          if (message != null) Text(message!, key: const Key('draft-message')),
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
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 1),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : review == null
        ? Center(child: Text(message ?? 'Avaliação indisponível.'))
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final entry
                  in _ParticipationDraftScreenState.ratingLabels.entries)
                DropdownButtonFormField<int>(
                  initialValue: (review!['ratings'] as Map)[entry.key] as int,
                  decoration: InputDecoration(labelText: entry.value),
                  items: [1, 2, 3, 4, 5]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: saving
                      ? null
                      : (value) {
                          if (value != null) {
                            (review!['ratings'] as Map)[entry.key] = value;
                          }
                        },
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
