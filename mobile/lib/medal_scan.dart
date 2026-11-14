import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
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
  final matches = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    scan();
  }

  Future<void> scan() async {
    try {
      final lines = await widget.reader.read(widget.photoPath);
      queries = medalQueries(lines);
      if (queries.isEmpty) {
        note = 'Não consegui ler o nome da corrida nesta foto.';
      }
      for (final query in queries) {
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
      if (queries.isNotEmpty && matches.isEmpty) {
        note = 'Li o texto da medalha, mas não achei uma corrida com ele.';
      }
    } on MedalReadUnavailable {
      note = 'Este aparelho ainda não lê o texto da medalha.';
    } on Exception {
      note =
          'Não consegui ler esta foto. Tente outra, mais nítida e de frente.';
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void openCatalog() => Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => CatalogScreen(gateway: widget.gateway),
    ),
  );

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
          const SizedBox(height: 8),
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
        ],
      ],
    ),
  );
}
