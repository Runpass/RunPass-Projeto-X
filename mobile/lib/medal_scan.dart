import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'edition_requests.dart';
import 'identity_gateway.dart';
import 'location_picker.dart';
import 'profile_photo.dart' show PhotoChoice, askPhotoChoice;
import 'runpass_theme.dart';

/// Lê o texto de uma foto. No iPhone usa o Vision da Apple, no próprio aparelho: a foto não sai
/// dele, só as linhas de texto voltam. Onde não há leitor (ex.: Android por enquanto), devolve vazio.
abstract class MedalTextReader {
  /// Linhas de texto achadas na foto. Lança [MedalReadUnavailable] se o aparelho não sabe ler.
  Future<List<String>> read(String path);
}

class MedalReadUnavailable implements Exception {}

class PlatformMedalTextReader implements MedalTextReader {
  static const _channel = MethodChannel('br.com.runpass.runpass/text');
  const PlatformMedalTextReader();

  @override
  Future<List<String>> read(String path) async {
    try {
      final lines = await _channel.invokeListMethod<String>('readText', path);
      return lines ?? const [];
    } on MissingPluginException {
      throw MedalReadUnavailable();
    }
  }
}

/// Palavras que aparecem em quase toda medalha e não distinguem uma corrida da outra.
const _noise = {
  'finisher',
  'finisher.',
  'medalha',
  'participante',
  'participation',
  'corrida',
  'run',
  'race',
  'brasil',
  'brazil',
  'km',
  'edicao',
  'edição',
};

/// Transforma as linhas lidas da medalha em até [max] buscas, das mais para as menos específicas.
/// Cada busca é um trecho que parece nome de prova; números soltos e ruído ficam de fora.
List<String> medalQueries(List<String> lines, {int max = 3}) {
  final cleaned = <String>[];
  for (final raw in lines) {
    final text = raw
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s\-]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length < 4) continue;
    final letters = RegExp(r'\p{L}', unicode: true).allMatches(text).length;
    if (letters < 4) continue; // "10 KM", "2024", etc.
    final words = text.split(' ');
    if (words.every((w) => _noise.contains(w.toLowerCase()))) continue;
    cleaned.add(text);
  }
  final queries = <String>[];
  void add(String value) {
    final q = value.length > 80 ? value.substring(0, 80).trim() : value;
    if (q.length >= 4 &&
        !queries.any((e) => e.toLowerCase() == q.toLowerCase())) {
      queries.add(q);
    }
  }

  // Primeiro as linhas com mais de uma palavra (nome de prova costuma ter), da maior para a menor.
  final multi = cleaned.where((l) => l.contains(' ')).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final line in multi) {
    add(line);
  }
  for (final line in cleaned.where((l) => !l.contains(' '))) {
    add(line);
  }
  return queries.take(max).toList();
}

/// Dados que dá para tirar do texto da medalha para já preencher o pedido de cadastro: o nome (a
/// busca mais específica), a distância ("10 KM", "21K") e a data, se estiver impressa (dd/mm/aaaa).
/// Só entra o que o texto realmente mostra; nada é adivinhado.
Map<String, String> medalDetails(List<String> lines, List<String> queries) {
  final details = <String, String>{
    if (queries.isNotEmpty) 'name': queries.first,
  };
  final text = lines.join('\n');
  final km = RegExp(
    r'(?<![\d.,])(\d{1,3}(?:[.,]\d{1,2})?)\s*(?:km|k)\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (km != null) {
    final value = double.tryParse(km.group(1)!.replaceAll(',', '.'));
    if (value != null && value >= 1 && value <= 100) {
      details['distanceKm'] = km.group(1)!.replaceAll(',', '.');
    }
  }
  final date = RegExp(r'\b(\d{1,2})[/.\-](\d{1,2})[/.\-](20\d{2})\b')
      .firstMatch(text);
  if (date != null) {
    final day = int.parse(date.group(1)!), month = int.parse(date.group(2)!);
    if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
      details['date'] =
          '${date.group(3)}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
    }
  }
  return details;
}

/// Foto da medalha: pergunta câmera ou galeria, lê o texto e procura a corrida no catálogo.
/// Devolve o caminho da foto, ou nulo se a pessoa desistir.
typedef MedalPhotoPicker = Future<String?> Function(BuildContext context);

Future<String?> pickMedalPhotoPath(BuildContext context) async {
  final choice = await askPhotoChoice(context);
  if (choice == null || choice == PhotoChoice.remove) return null;
  final file = await ImagePicker().pickImage(
    source: choice == PhotoChoice.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 2000,
    imageQuality: 90,
  );
  return file?.path;
}

class MedalScanScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String photoPath;
  final MedalTextReader reader;
  const MedalScanScreen({
    super.key,
    required this.gateway,
    required this.photoPath,
    this.reader = const PlatformMedalTextReader(),
  });

  @override
  State<MedalScanScreen> createState() => _MedalScanScreenState();
}

class _MedalScanScreenState extends State<MedalScanScreen> {
  bool working = true;
  String? note;
  List<String> queries = const [];
  Map<String, String> details = const {};
  bool unavailable = false;
  final matches = <Map<String, dynamic>>[];

  // O que a medalha mostra, para a pessoa conferir e corrigir antes de buscar de novo ou concluir.
  final name = TextEditingController();
  final date = TextEditingController(); // dd/mm/aaaa
  final distance = TextEditingController();
  final city = TextEditingController();
  final state = TextEditingController();

  @override
  void initState() {
    super.initState();
    scan();
  }

  @override
  void dispose() {
    for (final c in [name, date, distance, city, state]) {
      c.dispose();
    }
    super.dispose();
  }

  /// O que está nos campos agora (já corrigido pela pessoa); só entra o que foi preenchido e é válido.
  Map<String, String> editedDetails() {
    final iso = requestDateToIso(date.text.trim());
    final km = distance.text.trim().replaceAll(',', '.');
    return {
      if (name.text.trim().isNotEmpty) 'name': name.text.trim(),
      'date': ?iso,
      if (double.tryParse(km) != null) 'distanceKm': km,
      if (city.text.trim().isNotEmpty) 'city': city.text.trim(),
      if (state.text.trim().length == 2)
        'state': state.text.trim().toUpperCase(),
    };
  }

  Future<void> searchMatches(List<String> terms) async {
    for (final query in terms) {
      if (!mounted) return;
      try {
        final page = await widget.gateway.request(
          '/editions',
          query: {'q': query, 'limit': '5'},
        );
        for (final item in (page['items'] as List? ?? const [])) {
          final edition = Map<String, dynamic>.from(item as Map);
          if (!matches.any((m) => m['id'] == edition['id'])) {
            matches.add(edition);
          }
        }
      } on Exception {
        // Uma busca que falha não derruba as outras: a pessoa ainda pode procurar à mão.
      }
      if (matches.length >= 8) break;
    }
  }

  Future<void> scan() async {
    try {
      final lines = await widget.reader.read(widget.photoPath);
      queries = medalQueries(lines);
      details = medalDetails(lines, queries);
      name.text = details['name'] ?? '';
      date.text = requestDateToDisplay(details['date'] ?? '');
      distance.text = details['distanceKm'] ?? '';
      if (queries.isEmpty) {
        note = 'Não consegui ler o nome da corrida nesta foto.';
      }
      await searchMatches(queries);
      if (queries.isNotEmpty && matches.isEmpty) {
        note = 'Li o texto da medalha, mas não achei uma corrida com ele.';
      }
    } on MedalReadUnavailable {
      unavailable = true;
      note = 'Este aparelho ainda não lê o texto da medalha. Preencha abaixo.';
    } on Exception {
      note = 'Não consegui ler esta foto. Tente outra, mais nítida e de frente, ou preencha abaixo.';
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  /// Busca de novo com o nome corrigido pela pessoa.
  Future<void> searchAgain() async {
    final term = name.text.trim();
    if (term.length < 2) return;
    setState(() {
      working = true;
      note = null;
      matches.clear();
    });
    await searchMatches([term]);
    if (!mounted) return;
    setState(() {
      working = false;
      if (matches.isEmpty) note = 'Não achei uma corrida com este nome.';
    });
  }

  Future<void> pickDate() async {
    final current = DateTime.tryParse(requestDateToIso(date.text.trim()) ?? '');
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked != null) {
      date.text = requestDateToDisplay(
        picked.toIso8601String().substring(0, 10),
      );
    }
  }

  Future<void> pickLocation() async {
    final picked = await pickBrLocation(
      context,
      initialUf: state.text.isEmpty ? null : state.text,
      initialCity: city.text.isEmpty ? null : city.text,
    );
    if (picked != null && mounted) {
      setState(() {
        state.text = picked.$1;
        city.text = picked.$2;
      });
    }
  }

  Widget editField(
    String key,
    String label, {
    TextInputType? keyboard,
    int? maxLength,
    Widget? suffix,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: Key('medal-edit-$key'),
      controller: {
        'name': name,
        'date': date,
        'distance': distance,
        'city': city,
        'state': state,
      }[key],
      keyboardType: keyboard,
      maxLength: maxLength,
      textCapitalization: key == 'state'
          ? TextCapitalization.characters
          : TextCapitalization.words,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '',
        suffixIcon: suffix,
      ),
    ),
  );

  /// Campos editáveis com o que foi lido da medalha.
  Widget readCard() => Card(
    key: const Key('medal-scan-edit'),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'O que li na medalha. Confira e corrija:',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          editField('name', 'Nome da corrida', maxLength: 160),
          editField(
            'date',
            'Data (dd/mm/aaaa)',
            keyboard: TextInputType.datetime,
            maxLength: 10,
            suffix: IconButton(
              key: const Key('medal-edit-date-pick'),
              tooltip: 'Escolher no calendário',
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: pickDate,
            ),
          ),
          editField(
            'distance',
            'Distância em km',
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            maxLength: 8,
          ),
          // Estado e cidade por rolagem (a mesma lista fechada do perfil), sem digitar.
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              key: const Key('medal-edit-location'),
              onTap: pickLocation,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Estado e cidade',
                  suffixIcon: Icon(Icons.expand_more),
                ),
                child: Text(
                  city.text.isEmpty
                      ? 'Escolher na lista'
                      : '${state.text} - ${city.text}',
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('medal-scan-search-again'),
              onPressed: searchAgain,
              icon: const Icon(Icons.search_rounded),
              label: const Text('Buscar de novo com este nome'),
            ),
          ),
        ],
      ),
    ),
  );

  void openCatalog() => Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => CatalogScreen(gateway: widget.gateway),
    ),
  );

  /// Não achou: pede o cadastro da corrida, já com o nome lido da medalha no formulário.
  Future<void> requestRace() async {
    // A foto segue junto: a medalha fica provisória em Medalhas até a equipe confirmar a corrida.
    List<int>? photo;
    try {
      final file = File(widget.photoPath);
      photo = file.existsSync() ? await file.readAsBytes() : null;
    } on Exception {
      photo = null; // sem a foto, vira um pedido de cadastro comum
    }
    if (!mounted) return;
    final sent = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => EditionRequestFormScreen(
          gateway: widget.gateway,
          prefill: editedDetails(),
          medalPhoto: photo,
        ),
      ),
    );
    if (sent != null && mounted) {
      // Volta às medalhas, onde a medalha provisória já aparece como "Em análise".
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Adicionar medalha')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 220,
            child: Image.file(
              File(widget.photoPath),
              key: const Key('medal-scan-photo'),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (working)
          const Row(
            key: Key('medal-scan-working'),
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(child: Text('Lendo a medalha e procurando a corrida…')),
            ],
          )
        else ...[
          if (matches.isNotEmpty) ...[
            const Text(
              'Encontrei estas corridas. Toque na sua:',
              key: Key('medal-scan-found'),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            for (final edition in matches)
              Card(
                child: ListTile(
                  key: Key('medal-match-${edition['id']}'),
                  leading: const Icon(
                    Icons.directions_run,
                    color: runPassOrange,
                  ),
                  title: Text(edition['name'] as String? ?? ''),
                  subtitle: Text(
                    [
                      if (edition['date'] is String)
                        displayDate(edition['date'] as String),
                      if (edition['city'] != null)
                        '${edition['city']}/${edition['state']}',
                    ].join(' · '),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EditionScreen(
                        gateway: widget.gateway,
                        editionId: edition['id'] as String,
                      ),
                    ),
                  ),
                ),
              ),
          ],
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note!, key: const Key('medal-scan-note')),
            ),
          readCard(),
          const SizedBox(height: 8),
          if (matches.isEmpty) ...[
            // Não achou: sugere cadastrar a corrida, já com o que foi lido na medalha.
            Card(
              key: const Key('medal-scan-suggest'),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Esta corrida ainda não está no catálogo. Quer cadastrá-la?',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Confira os dados acima: o cadastro leva o que estiver nos campos, junto com a foto da medalha.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('medal-scan-request'),
              onPressed: requestRace,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Concluir cadastro da medalha'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('medal-scan-catalog'),
              onPressed: openCatalog,
              icon: const Icon(Icons.search_rounded),
              label: const Text('Procurar a corrida nas corridas'),
            ),
          ] else ...[
            FilledButton.icon(
              key: const Key('medal-scan-catalog'),
              onPressed: openCatalog,
              icon: const Icon(Icons.search_rounded),
              label: Text(
                matches.isEmpty
                    ? 'Procurar a corrida nas corridas'
                    : 'Não é nenhuma? Procurar nas corridas',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('medal-scan-request'),
              onPressed: requestRace,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Não encontrou? Pedir cadastro da corrida'),
            ),
          ],
        ],
      ],
    ),
  );
}
