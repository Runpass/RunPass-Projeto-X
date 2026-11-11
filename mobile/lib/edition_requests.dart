import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';

/// Pedido de prova ausente: o corredor informa nome, data, cidade e distância; a equipe confere a
/// fonte e adiciona ao catálogo. O pedido é privado e nunca vira corrida pública sozinho.

String requestStatusLabel(String? status) => switch (status) {
  'pending' => 'Em análise pela equipe',
  'approved' => 'Aprovada: já está no catálogo',
  'linked' => 'Esta corrida já existia: vinculamos o seu pedido a ela',
  'awaiting_load' => 'Aprovada pela equipe: assim que a corrida entrar no catálogo ela é vinculada ao seu pedido',
  'rejected' => 'Não aprovada',
  _ => 'Situação desconhecida',
};

String? requestDateError(String value) {
  final parsed = DateTime.tryParse(value);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
      parsed == null ||
      parsed.toIso8601String().substring(0, 10) != value) {
    return 'Use uma data válida no formato AAAA-MM-DD.';
  }
  return null;
}

String? requestDistanceError(String value) {
  final km = double.tryParse(value.replaceAll(',', '.'));
  return km != null && km.isFinite && km > 0 && km <= 1000
      ? null
      : 'Informe a distância em km (até 1000), por exemplo 10 ou 21,1.';
}

class EditionRequestFormScreen extends StatefulWidget {
  final IdentityGateway gateway;

  /// Pedido rejeitado que a pessoa vai corrigir e reenviar.
  final Map<String, dynamic>? existing;

  /// Sugestões de preenchimento (nome, data, cidade, estado, distância, endereço).
  final Map<String, String> prefill;
  const EditionRequestFormScreen({
    super.key,
    required this.gateway,
    this.existing,
    this.prefill = const {},
  });
  @override
  State<EditionRequestFormScreen> createState() =>
      _EditionRequestFormScreenState();
}

class _EditionRequestFormScreenState extends State<EditionRequestFormScreen> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  bool saving = false;
  String? error;

  bool get correcting => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final details = Map<String, dynamic>.from(
      (widget.existing?['details'] as Map?) ?? const {},
    );
    String start(String key, [String fallback = '']) =>
        '${details[key] ?? widget.prefill[key] ?? fallback}';
    fields = {
      'name': TextEditingController(text: start('name')),
      'date': TextEditingController(text: start('date')),
      'city': TextEditingController(text: start('city', 'São Paulo')),
      'state': TextEditingController(text: start('state', 'SP')),
      'distanceKm': TextEditingController(text: start('distanceKm')),
      'officialUrl': TextEditingController(
        text: correcting ? '' : start('officialUrl'),
      ),
    };
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String text(String key) => fields[key]!.text.trim();

  Future<void> submit() async {
    if (saving || !(form.currentState?.validate() ?? false)) return;
    final body = <String, dynamic>{
      'name': text('name'),
      'date': text('date'),
      'city': text('city'),
      if (text('state').isNotEmpty) 'state': text('state').toUpperCase(),
      'distanceKm': double.parse(text('distanceKm').replaceAll(',', '.')),
      if (text('officialUrl').isNotEmpty) 'officialUrl': text('officialUrl'),
    };
    setState(() {
      saving = true;
      error = null;
    });
    try {
      Map<String, dynamic> result;
      if (correcting) {
        final id = Uri.encodeComponent(widget.existing!['id'] as String);
        final patched = await widget.gateway.request(
          '/edition-requests/$id',
          method: 'PATCH',
          body: {'expectedVersion': widget.existing!['version'], ...body},
        );
        result = await widget.gateway.request(
          '/edition-requests/$id/resubmit',
          method: 'POST',
          body: {'expectedVersion': patched['version']},
        );
      } else {
        result = await widget.gateway.request(
          '/edition-requests',
          method: 'POST',
          body: body,
        );
      }
      if (mounted) Navigator.of(context).pop(result);
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = catalogError(issue));
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(
    String key,
    String label, {
    required bool required,
    String? Function(String)? validate,
    int? maxLength,
    String? helper,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      key: Key('request-$key'),
      controller: fields[key],
      maxLength: maxLength,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, helperText: helper),
      validator: (value) {
        final v = (value ?? '').trim();
        if (v.isEmpty) return required ? 'Preencha este campo.' : null;
        return validate?.call(v);
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(correcting ? 'Corrigir pedido' : 'Pedir cadastro da corrida'),
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            correcting
                ? 'Corrija o que a equipe apontou e reenvie para análise.'
                : 'Informe o que você sabe. A equipe pesquisa a corrida, confere a fonte e só então coloca no catálogo. Isso não é imediato: acompanhe em "Minhas solicitações".',
          ),
          if (correcting && widget.existing!['reason'] != null) ...[
            const SizedBox(height: 8),
            Text(
              'Motivo informado: ${widget.existing!['reason']}',
              key: const Key('request-reason'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
          const SizedBox(height: 16),
          Form(
            key: form,
            child: Column(
              children: [
                field(
                  'name',
                  'Nome da corrida',
                  required: true,
                  maxLength: 160,
                ),
                field(
                  'date',
                  'Data (AAAA-MM-DD)',
                  required: true,
                  validate: requestDateError,
                ),
                field('city', 'Cidade', required: true, maxLength: 100),
                field(
                  'state',
                  'Estado (UF)',
                  required: false,
                  maxLength: 2,
                  validate: (v) => RegExp(r'^[A-Za-z]{2}$').hasMatch(v)
                      ? null
                      : 'Informe a UF com 2 letras.',
                ),
                field(
                  'distanceKm',
                  'Distância em km',
                  required: true,
                  validate: requestDistanceError,
                  keyboard: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  helper: 'Uma distância por pedido. Para outra, faça outro pedido.',
                ),
                field(
                  'officialUrl',
                  'Endereço da página da corrida (opcional)',
                  required: false,
                  maxLength: 500,
                  validate: (v) => RegExp(r'^https://\S+$').hasMatch(v)
                      ? null
                      : 'Use um endereço que comece com https://',
                  helper: correcting
                      ? 'Em branco mantém o endereço atual.'
                      : null,
                  keyboard: TextInputType.url,
                ),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, key: const Key('request-error')),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('request-submit'),
            onPressed: saving ? null : submit,
            child: Text(correcting ? 'Corrigir e reenviar' : 'Enviar pedido'),
          ),
          if (saving) const Center(child: CircularProgressIndicator()),
        ],
      ),
    ),
  );
}

class MyEditionRequestsScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const MyEditionRequestsScreen({super.key, required this.gateway});
  @override
  State<MyEditionRequestsScreen> createState() =>
      _MyEditionRequestsScreenState();
}

class _MyEditionRequestsScreenState extends State<MyEditionRequestsScreen> {
  final items = <Map<String, dynamic>>[];
  String? nextCursor, error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    if (!more) {
      items.clear();
      nextCursor = null;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.gateway.request(
        '/me/edition-requests',
        query: {
          'limit': '20',
          if (more && nextCursor != null) 'cursor': nextCursor!,
        },
      );
      if (!mounted) return;
      items.addAll((page['items'] as List).cast<Map<String, dynamic>>());
      nextCursor = page['nextCursor'] as String?;
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) {
        error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> correct(Map<String, dynamic> request) async {
    final sent = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => EditionRequestFormScreen(
          gateway: widget.gateway,
          existing: request,
        ),
      ),
    );
    if (sent != null) load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Minhas solicitações')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (error != null) ...[
            Text(error!, key: const Key('requests-error')),
            TextButton(
              onPressed: loading ? null : () => load(more: nextCursor != null),
              child: const Text('Tentar novamente'),
            ),
          ],
          if (loading) const Center(child: CircularProgressIndicator()),
          if (!loading && error == null && items.isEmpty)
            const Text('Você ainda não pediu o cadastro de nenhuma corrida.'),
          for (final request in items) _card(request),
          if (nextCursor != null)
            TextButton(
              onPressed: loading ? null : () => load(more: true),
              child: const Text('Carregar mais'),
            ),
        ],
      ),
    ),
  );

  Widget _card(Map<String, dynamic> request) {
    final details = Map<String, dynamic>.from(request['details'] as Map);
    final status = request['status'] as String?;
    final linked = request['linkedEditionId'] as String?;
    return Card(
      key: Key('request-${request['id']}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${details['name']}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              '${displayDate(details['date'] as String)} · ${details['city']}'
              '${details['state'] != null ? '/${details['state']}' : ''} · ${details['distanceKm']} km',
            ),
            const SizedBox(height: 8),
            Text(
              requestStatusLabel(status),
              key: Key('status-${request['id']}'),
            ),
            if (status == 'rejected' && request['reason'] != null)
              Text('Motivo: ${request['reason']}'),
            if (status == 'rejected')
              TextButton(
                onPressed: () => correct(request),
                child: const Text('Corrigir e reenviar'),
              ),
            if ((status == 'approved' || status == 'linked') && linked != null)
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EditionScreen(
                      gateway: widget.gateway,
                      editionId: linked,
                    ),
                  ),
                ),
                child: const Text('Ver a corrida no catálogo'),
              ),
          ],
        ),
      ),
    );
  }
}
