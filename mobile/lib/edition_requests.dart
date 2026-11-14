import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'location_picker.dart';
import 'profile_photo.dart';

/// Pedido de prova ausente: o corredor informa nome, data, cidade e distância; a equipe confere a
/// fonte e adiciona ao catálogo. O pedido é privado e nunca vira corrida pública sozinho.

/// Situação do banner que a pessoa sugeriu junto com o pedido; nulo quando não há o que dizer.
String? bannerStatusLabel(String? bannerState, String? status) {
  if (bannerState == 'published') return 'Seu banner foi publicado na corrida';
  if (bannerState == 'dismissed') {
    return 'Seu banner não foi aprovado pela equipe (a imagem não é publicada)';
  }
  return switch (status) {
    'approved' || 'linked' => 'Banner enviado: aguardando a decisão da equipe',
    'pending' || 'awaiting_load' =>
      'Banner enviado: será analisado depois que a corrida for aprovada',
    _ => null,
  };
}

String requestStatusLabel(String? status) => switch (status) {
  'pending' => 'Em análise pela equipe',
  'approved' => 'Aprovada: já está no catálogo',
  'linked' => 'Esta corrida já existia: vinculamos o seu pedido a ela',
  'awaiting_load' => 'Aprovada pela equipe: assim que a corrida entrar no catálogo ela é vinculada ao seu pedido',
  'rejected' => 'Não aprovada',
  _ => 'Situação desconhecida',
};

/// "2027-03-14" -> "14/03/2027" (o que a pessoa vê e digita). Texto fora desse formato passa como veio.
String requestDateToDisplay(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  return m == null ? iso : '${m[3]}/${m[2]}/${m[1]}';
}

/// "14/03/2027" -> "2027-03-14" (o que o servidor recebe); nulo se não for uma data de calendário válida.
String? requestDateToIso(String display) {
  final m = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(display);
  if (m == null) return null;
  final iso = '${m[3]}-${m[2]}-${m[1]}';
  final parsed = DateTime.tryParse(iso);
  return parsed != null && parsed.toIso8601String().substring(0, 10) == iso
      ? iso
      : null;
}

String? requestDateError(String value) => requestDateToIso(value) == null
    ? 'Use uma data válida no formato DD/MM/AAAA.'
    : null;

/// Máscara DD/MM/AAAA: só dígitos, com as barras inseridas enquanto a pessoa digita.
class DateMaskFormatter extends TextInputFormatter {
  const DateMaskFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final cut = digits.length > 8 ? digits.substring(0, 8) : digits;
    final out = StringBuffer();
    for (var i = 0; i < cut.length; i++) {
      if (i == 2 || i == 4) out.write('/');
      out.write(cut[i]);
    }
    final text = out.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
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

  /// Escolhe e recorta a imagem do banner; nulo se a pessoa desistir. Troque nos testes.
  final Future<List<int>?> Function(BuildContext context)? bannerSelector;

  /// Foto da medalha (medalha provisória): vai junto com o pedido, privada e fora da fila de banners.
  /// Quando presente, não se escolhe banner.
  final List<int>? medalPhoto;
  const EditionRequestFormScreen({
    super.key,
    required this.gateway,
    this.existing,
    this.prefill = const {},
    this.bannerSelector,
    this.medalPhoto,
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

  /// Banner sugerido (opcional): bytes já recortados e, depois do envio, a referência aceita pelo servidor.
  List<int>? banner;
  String? bannerRef;

  bool get correcting => widget.existing != null;

  @override
  void initState() {
    super.initState();
    banner = widget.medalPhoto;
    final details = Map<String, dynamic>.from(
      (widget.existing?['details'] as Map?) ?? const {},
    );
    String start(String key, [String fallback = '']) =>
        '${details[key] ?? widget.prefill[key] ?? fallback}';
    fields = {
      'name': TextEditingController(text: start('name')),
      'date': TextEditingController(text: requestDateToDisplay(start('date'))),
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

  Future<void> chooseBanner() async {
    List<int>? bytes;
    try {
      if (widget.bannerSelector != null) {
        bytes = await widget.bannerSelector!(context);
      } else {
        final choice = await askPhotoChoice(context);
        if (choice == null || choice == PhotoChoice.remove || !mounted) return;
        bytes = await pickBannerPhoto(context, choice);
      }
    } on Exception catch (problem) {
      if (mounted) setState(() => error = photoError(problem));
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() {
      banner = bytes;
      bannerRef = null; // outra imagem: precisa enviar de novo
      error = null;
    });
  }

  void removeBanner() => setState(() {
    banner = null;
    bannerRef = null;
  });

  Future<void> submit() async {
    if (saving || !(form.currentState?.validate() ?? false)) return;
    final body = <String, dynamic>{
      'name': text('name'),
      'date': requestDateToIso(text('date')) ?? text('date'),
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
      if (!correcting && banner != null) {
        // Envia a imagem primeiro (a referência é só desta pessoa); o pedido leva só a referência.
        bannerRef ??= await uploadProfilePhoto(widget.gateway, banner!);
        body['imageReference'] = bannerRef;
        if (widget.medalPhoto != null) body['medalPhoto'] = true;
      }
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
      const photoCodes = {
        'IMAGE_TYPE_INVALID',
        'IMAGE_NOT_VALID',
        'IMAGE_SIZE_INVALID',
        'UPLOAD_UNAVAILABLE',
        'INVALID_UPLOAD_URL',
      };
      if (mounted) {
        setState(
          () => error = photoCodes.contains(issue.code)
              ? photoError(issue)
              : catalogError(issue),
        );
      }
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

  /// Foto da medalha que segue com o pedido (medalha provisória): só a pessoa a vê até a equipe decidir.
  Widget medalNote() => Card(
    key: const Key('request-medal-photo'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              Uint8List.fromList(widget.medalPhoto!),
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(width: 64, height: 64),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'A foto da sua medalha vai junto e fica só com você. A medalha aparece em Medalhas como "Em análise" até a equipe confirmar a corrida.',
            ),
          ),
        ],
      ),
    ),
  );

  Widget bannerPicker() => Card(
    key: const Key('request-banner'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Banner da corrida (opcional)',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Se você tem a imagem de divulgação da corrida, envie. Ela só é publicada se a equipe aprovar, com o crédito e a autorização do organizador.',
          ),
          const SizedBox(height: 8),
          if (banner != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                Uint8List.fromList(banner!),
                key: const Key('request-banner-preview'),
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            Row(
              children: [
                TextButton(
                  key: const Key('request-banner-change'),
                  onPressed: saving ? null : chooseBanner,
                  child: const Text('Trocar imagem'),
                ),
                TextButton(
                  key: const Key('request-banner-remove'),
                  onPressed: saving ? null : removeBanner,
                  child: const Text('Remover'),
                ),
              ],
            ),
          ] else
            OutlinedButton.icon(
              key: const Key('request-banner-pick'),
              onPressed: saving ? null : chooseBanner,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Escolher imagem do banner'),
            ),
        ],
      ),
    ),
  );

  Widget field(
    String key,
    String label, {
    required bool required,
    String? Function(String)? validate,
    int? maxLength,
    String? helper,
    int helperMaxLines = 1,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      key: Key('request-$key'),
      controller: fields[key],
      maxLength: maxLength,
      keyboardType: keyboard,
      inputFormatters: formatters,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: helperMaxLines,
      ),
      validator: (value) {
        final v = (value ?? '').trim();
        if (v.isEmpty) return required ? 'Preencha este campo.' : null;
        return validate?.call(v);
      },
    ),
  );

  /// Estado e cidade escolhidos na roda de rolagem (lista fechada), sem digitação.
  Future<void> chooseLocation() async {
    final picked = await pickBrLocation(
      context,
      initialUf: text('state').isEmpty ? null : text('state').toUpperCase(),
      initialCity: text('city').isEmpty ? null : text('city'),
    );
    if (picked == null || !mounted) return;
    setState(() {
      fields['state']!.text = picked.$1;
      fields['city']!.text = picked.$2;
    });
  }

  /// Mesmo padrão do filtro de corridas: um campo "Estado e cidade" que abre a roda de rolagem.
  Widget locationField() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: FormField<String>(
      key: const Key('request-location'),
      initialValue: '',
      validator: (_) =>
          text('city').isEmpty ? 'Escolha o estado e a cidade.' : null,
      builder: (state) => InkWell(
        onTap: saving ? null : chooseLocation,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Estado e cidade',
            suffixIcon: const Icon(Icons.expand_more),
            errorText: state.errorText,
          ),
          child: Text(
            text('city').isEmpty
                ? 'Escolha o estado e a cidade'
                : text('state').isEmpty
                ? text('city')
                : '${text('state').toUpperCase()} - ${text('city')}',
          ),
        ),
      ),
    ),
  );

  /// Atalhos de distância (5, 10, 21 e 42 km), como no filtro de corridas.
  Widget distanceChips() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ListenableBuilder(
      listenable: fields['distanceKm']!,
      builder: (context, _) => Wrap(
        spacing: 8,
        children: [
          for (final km in const ['5', '10', '21', '42'])
            ChoiceChip(
              key: Key('km-chip-$km'),
              label: Text('$km km'),
              selected: text('distanceKm') == km,
              onSelected: saving
                  ? null
                  : (picked) => fields['distanceKm']!.text = picked ? km : '',
            ),
        ],
      ),
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
                  'Data (DD/MM/AAAA)',
                  required: true,
                  validate: requestDateError,
                  keyboard: TextInputType.number,
                  formatters: const [DateMaskFormatter()],
                ),
                locationField(),
                distanceChips(),
                field(
                  'distanceKm',
                  'Distância em km',
                  required: true,
                  validate: requestDistanceError,
                  keyboard: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  helper: 'Ex.: 5, 10, 21 ou 42. Uma distância por pedido; para outra, faça outro pedido.',
                  helperMaxLines: 2,
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
          if (!correcting && widget.medalPhoto == null) bannerPicker(),
          if (!correcting && widget.medalPhoto != null) medalNote(),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, key: const Key('request-error')),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('request-submit'),
            onPressed: saving ? null : submit,
            child: Text(
              correcting
                  ? 'Corrigir e reenviar'
                  : (widget.medalPhoto != null
                        ? 'Concluir cadastro da medalha'
                        : 'Enviar pedido'),
            ),
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
              // Sugestão de banner de corrida já cadastrada: não é um pedido de cadastro.
              request['kind'] == 'banner'
                  ? 'Sugestão de banner para uma corrida já cadastrada'
                  : requestStatusLabel(status),
              key: Key('status-${request['id']}'),
            ),
            if (details['imageReference'] != null &&
                bannerStatusLabel(request['bannerState'] as String?, status) !=
                    null)
              Text(
                bannerStatusLabel(request['bannerState'] as String?, status)!,
                key: Key('banner-${request['id']}'),
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
