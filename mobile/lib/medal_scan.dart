import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'duration_field.dart';
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

/// Medalha costuma vir impressa em CAIXA ALTA: "MARATONA FANTASMA DO VALE" vira "Maratona Fantasma do Vale".
/// Só mexe quando o texto inteiro está em maiúsculas; nome já escrito em minúsculas ou misto fica como está.
/// Palavras com número ("10K", "29ª") e siglas de até 2 letras ("SP", "QA") ficam como estão.
String readableMedalName(String raw) {
  final text = raw.trim();
  if (text.isEmpty ||
      text != text.toUpperCase() ||
      text == text.toLowerCase()) {
    return text;
  }
  const small = {
    'de',
    'da',
    'do',
    'das',
    'dos',
    'e',
    'em',
    'no',
    'na',
    'nos',
    'nas',
    'a',
    'o',
    'para',
    'por',
    'com',
    'ao',
    'ou',
    'um',
    'às',
  };
  final words = text.split(RegExp(r'\s+'));
  final out = <String>[];
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    final lower = word.toLowerCase();
    // Número ("10K", "29ª") e sigla de até 2 letras ("QA", "SP", "RJ") ficam como estão; as palavras
    // pequenas da lista acima ("DE", "DO", "EM"...) viram minúsculas no meio do nome.
    final isSmall = small.contains(lower);
    if (RegExp(r'\d').hasMatch(word) || (word.length <= 2 && !isSmall)) {
      out.add(word);
    } else if (i > 0 && isSmall) {
      out.add(lower);
    } else {
      out.add(lower[0].toUpperCase() + lower.substring(1));
    }
  }
  return out.join(' ');
}

/// Dados que dá para tirar do texto da medalha para já preencher o pedido de cadastro: o nome (a
/// busca mais específica), a distância ("10 KM", "21K") e a data, se estiver impressa (dd/mm/aaaa).
/// Só entra o que o texto realmente mostra; nada é adivinhado.
Map<String, String> medalDetails(List<String> lines, List<String> queries) {
  final details = <String, String>{
    if (queries.isNotEmpty) 'name': readableMedalName(queries.first),
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

/// Distância da participação: a única da corrida, a que bate com os km informados ou, na dúvida, pergunta
/// ali mesmo (lista da corrida). Devolve nulo se a corrida não tem distâncias ou a pessoa desistir.
Future<Map?> chooseDistance(
  BuildContext context,
  List<Map> options, {
  double? km,
}) async {
  if (options.isEmpty) return null;
  if (options.length == 1) return options.first;
  if (km != null) {
    for (final d in options) {
      if (((d['kilometers'] as num) - km).abs() < 0.05) return d;
    }
  }
  return showModalBottomSheet<Map>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Qual distância você correu?',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ),
          for (final d in options)
            ListTile(
              key: Key('distance-option-${d['id']}'),
              leading: const Icon(Icons.directions_run, color: runPassOrange),
              title: Text(distanceLabel((d['kilometers'] as num).toDouble())),
              onTap: () => Navigator.pop(sheet, d),
            ),
        ],
      ),
    ),
  );
}

/// Distâncias de uma corrida; se a lista não trouxe (só um resumo), busca o detalhe.
Future<List<Map>> editionDistances(
  IdentityGateway gateway,
  String editionId,
  Map<String, dynamic>? known,
) async {
  List<Map> pick(Map? source) => [
    for (final d in (source?['distances'] as List? ?? const []))
      if (d is Map && d['kilometers'] is num) d,
  ];
  final fromList = pick(known);
  if (fromList.isNotEmpty) return fromList;
  try {
    return pick(
      await gateway.request('/editions/${Uri.encodeComponent(editionId)}'),
    );
  } on Exception {
    return const [];
  }
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

  /// Seleção de foto do rascunho da participação (só os testes trocam; o app usa a galeria).
  final PhotoSelector? draftPhotoSelector;
  const MedalScanScreen({
    super.key,
    required this.gateway,
    required this.photoPath,
    this.reader = const PlatformMedalTextReader(),
    this.draftPhotoSelector,
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
  String? chosenId; // corrida do catálogo que preencheu o cadastro

  /// Todo o texto lido da medalha, linha por linha, para a pessoa conferir e para a busca.
  List<String> allLines = const [];
  bool showAllLines = false;

  /// Meus dados desta prova, todos opcionais; seguem para a participação e aparecem na publicação.
  final time = TextEditingController();
  final pace = TextEditingController();
  final placement = TextEditingController();
  final bib = TextEditingController();

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
    for (final c in [
      name,
      date,
      distance,
      city,
      state,
      time,
      pace,
      placement,
      bib,
    ]) {
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
      allLines = lines;
      // Todo o texto da medalha vira busca, do trecho mais específico ao menos específico.
      queries = medalQueries(lines, max: 6);
      details = medalDetails(lines, queries);
      name.text = details['name'] ?? '';
      date.text = requestDateToDisplay(details['date'] ?? '');
      distance.text = details['distanceKm'] ?? '';
      if (queries.isEmpty) {
        note = 'Não consegui ler o nome da corrida nesta foto.';
      }
      await searchMatches(queries);
      if (matches.isNotEmpty) await markRegistered();
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

  /// Toque numa corrida achada: preenche o cadastro com os dados dela (nome, data, local, distância),
  /// sem digitar de novo. Os campos continuam editáveis.
  /// Corridas desta lista em que a pessoa já tem a medalha cadastrada.
  Set<String> registered = {};

  Future<void> markRegistered() async {
    final mine = await loadMyEditions(widget.gateway);
    if (!mounted) return;
    setState(() {
      registered = {
        for (final e in mine.entries)
          if (e.value['state'] == 'completed') e.key,
      };
    });
  }

  void fillFrom(Map<String, dynamic> edition) {
    final distances = [
      for (final d in (edition['distances'] as List? ?? const []))
        if (d is Map && d['kilometers'] is num) (d['kilometers'] as num),
    ];
    setState(() {
      chosenId = edition['id'] as String?;
      name.text = edition['name'] as String? ?? name.text;
      if (edition['date'] is String) {
        date.text = requestDateToDisplay(edition['date'] as String);
      }
      city.text = edition['city'] as String? ?? city.text;
      state.text = edition['state'] as String? ?? state.text;
      if (distances.length == 1) {
        final km = distances.first;
        distance.text = km == km.roundToDouble() ? '${km.toInt()}' : '$km';
      }
    });
  }

  /// "Concluir" com uma corrida do catálogo escolhida: abre o rascunho da participação nessa corrida, já com a
  /// foto da medalha, para completar tempo, avaliação e concluir. Sem a distância certa, abre a corrida para escolher.
  Future<void> concludeChosen() async {
    final edition = matches.firstWhere(
      (m) => m['id'] == chosenId,
      orElse: () => const {},
    );
    final id = chosenId;
    if (id == null || edition.isEmpty) return;
    final km = double.tryParse(distance.text.trim().replaceAll(',', '.'));
    final navigator = Navigator.of(context);
    setState(() => working = true);
    // Medalha já cadastrada nesta corrida: avisa e não deixa cadastrar de novo (editar é uma escolha explícita).
    final mine = (await loadMyEditions(widget.gateway))[id];
    if (!mounted) return;
    if (mine != null && mine['state'] == 'completed') {
      setState(() => working = false);
      await alreadyRegistered(
        mine,
        edition['name'] as String? ?? 'esta corrida',
      );
      return;
    }
    final options = await editionDistances(widget.gateway, id, edition);
    if (!mounted) return;
    setState(() => working = false);
    final picked = await chooseDistance(context, options, km: km);
    if (!mounted) return;
    if (picked == null) {
      if (options.isEmpty) {
        // Corrida sem distâncias no cadastro: a tela da corrida é o caminho.
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                EditionScreen(gateway: widget.gateway, editionId: id),
          ),
        );
      }
      return; // desistiu de escolher a distância
    }
    setState(() => working = true);
    List<int>? photo;
    try {
      final file = File(widget.photoPath);
      photo = file.existsSync() ? await file.readAsBytes() : null;
    } on Exception {
      photo = null;
    }
    try {
      final draft = await widget.gateway.request(
        '/participations',
        method: 'POST',
        body: {'editionId': id, 'distanceId': picked['id']},
      );
      if (!mounted) return;
      setState(() => working = false);
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ParticipationDraftScreen(
            gateway: widget.gateway,
            initial: draft,
            initialPhoto: photo,
            photoSelector: widget.draftPhotoSelector,
            initialTime: time.text,
            initialPace: pace.text,
            initialPlacement: placement.text,
            initialBib: bib.text,
          ),
        ),
      );
      // Se a participação foi concluída, a pilha já foi zerada e a prateleira nova está no topo: não há o que
      // fechar (fechar aqui deixava a tela preta). Se voltou sem concluir, fecha e a prateleira recarrega.
      if (mounted && navigator.canPop()) navigator.pop(true);
    } on IdentityIssue catch (issue) {
      if (!mounted) return;
      setState(() => working = false);
      if (issue.code == 'PARTICIPATION_EXISTS') {
        // Já existe participação nesta corrida: abre a participação (rascunho ou concluída) para completar/editar.
        final existing = (await loadMyEditions(widget.gateway))[id];
        if (!mounted) return;
        if (existing != null && existing['state'] == 'completed') {
          await alreadyRegistered(
            existing,
            edition['name'] as String? ?? 'esta corrida',
          );
          return;
        }
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => existing == null
                ? EditionScreen(gateway: widget.gateway, editionId: id)
                : ParticipationDraftScreen(
                    gateway: widget.gateway,
                    initial: existing,
                  ),
          ),
        );
        if (mounted && navigator.canPop()) navigator.pop(true);
      } else {
        setState(() => note = catalogError(issue));
      }
    } on Exception {
      if (mounted) {
        setState(() {
          working = false;
          note = 'Sem conexão com o servidor. Verifique a internet e tente de novo.';
        });
      }
    }
  }

  /// A medalha desta corrida já está cadastrada: não cadastra de novo e não abre a edição sozinho.
  /// Quem quiser corrigir escolhe "Editar meu cadastro".
  Future<void> alreadyRegistered(
    Map<String, dynamic> existing,
    String raceName,
  ) async {
    final navigator = Navigator.of(context);
    final edit = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('medal-already'),
        title: const Text('Essa medalha já está cadastrada'),
        content: Text(
          'Você já registrou "$raceName". Não dá para cadastrar a mesma medalha duas vezes. '
          'Se alguma informação estiver errada, edite o cadastro que já existe.',
        ),
        actions: [
          TextButton(
            key: const Key('medal-already-close'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Fechar'),
          ),
          FilledButton(
            key: const Key('medal-already-edit'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Editar meu cadastro'),
          ),
        ],
      ),
    );
    if (edit != true || !mounted) return;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: existing,
        ),
      ),
    );
    if (mounted && navigator.canPop()) navigator.pop(true);
  }

  /// Não achou a corrida no catálogo: pesquisa o nome (como está nos campos) na internet, no navegador.
  Future<void> searchWeb() async {
    final term = name.text.trim();
    if (term.isEmpty) return;
    var opened = false;
    try {
      opened = await linkOpener(
        Uri.https('www.google.com', '/search', {'q': '$term corrida'}),
      );
    } on Exception {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível abrir o navegador. Tente de novo.'),
        ),
      );
    }
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
    List<TextInputFormatter>? formatters,
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
      inputFormatters: formatters,
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

  /// Meus dados desta corrida, na mesma tela da escolha: todos opcionais. O que for preenchido vai para a
  /// participação e aparece na publicação.
  Widget raceDataCard() => Card(
    key: const Key('medal-race-data'),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Seus dados nesta corrida',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            'Tudo opcional. O que você preencher aparece na sua publicação.',
            style: TextStyle(fontSize: 12, color: context.muted),
          ),
          const SizedBox(height: 6),
          DurationField(key: const Key('medal-data-time'), controller: time),
          TextField(
            key: const Key('medal-data-pace'),
            controller: pace,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(
              labelText: 'Pace (opcional)',
              hintText: 'Ex.: 5:30',
              suffixText: 'min/km',
            ),
          ),
          TextField(
            key: const Key('medal-data-placement'),
            controller: placement,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Colocação (opcional)',
            ),
          ),
          TextField(
            key: const Key('medal-data-bib'),
            controller: bib,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Número de peito (opcional)',
              counterText: '',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton.icon(
                key: const Key('medal-scan-other-race'),
                onPressed: () => setState(() => chosenId = null),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12.5),
                ),
                icon: const Icon(Icons.search_rounded, size: 16),
                label: const Text('Outra corrida'),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                key: const Key('medal-scan-conclude'),
                onPressed: concludeChosen,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 13),
                ),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: const Text('Continuar'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  /// Todo o texto que o aparelho leu na medalha, para conferir sem sair da tela.
  Widget readLinesTile() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          key: const Key('medal-scan-lines-toggle'),
          onPressed: () => setState(() => showAllLines = !showAllLines),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 12.5),
          ),
          icon: Icon(
            showAllLines ? Icons.expand_less : Icons.expand_more,
            size: 16,
          ),
          label: Text('Texto lido da medalha (${allLines.length})'),
        ),
        if (showAllLines)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Text(
              allLines.join(' · '),
              key: const Key('medal-scan-lines'),
              style: TextStyle(fontSize: 12.5, color: context.muted),
            ),
          ),
      ],
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
            keyboard: TextInputType.number,
            maxLength: 10,
            // Só os números: as barras entram sozinhas (dd/mm/aaaa).
            formatters: const [DateMaskFormatter()],
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
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: const Key('medal-scan-search-again'),
                onPressed: searchAgain,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12.5),
                ),
                icon: const Icon(Icons.search_rounded, size: 16),
                label: const Text('Buscar de novo'),
              ),
              // Sempre à mão, já na primeira tela: pesquisa o nome digitado na internet.
              ListenableBuilder(
                listenable: name,
                builder: (context, _) => TextButton.icon(
                  key: const Key('medal-scan-web-search'),
                  onPressed: name.text.trim().isEmpty ? null : searchWeb,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                  icon: const Icon(Icons.public_rounded, size: 16),
                  label: const Text('Procurar na internet'),
                ),
              ),
            ],
          ),
        ],
      ),
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
      Navigator.of(context).pop('request');
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
                color: chosenId == edition['id']
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: ListTile(
                  key: Key('medal-match-${edition['id']}'),
                  leading: Icon(
                    chosenId == edition['id']
                        ? Icons.check_circle
                        : Icons.directions_run,
                    color: runPassOrange,
                  ),
                  title: Text(edition['name'] as String? ?? ''),
                  subtitle: Text(
                    [
                      if (edition['date'] is String)
                        displayDate(edition['date'] as String),
                      if (edition['city'] != null)
                        '${edition['city']}/${edition['state']}',
                      if (registered.contains(edition['id']))
                        'Já cadastrada por você',
                    ].join(' · '),
                  ),
                  // Toque escolhe a corrida e abre, logo abaixo, os dados da prova (todos opcionais).
                  onTap: () => fillFrom(edition),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Edição diferente da que quero cadastrar: copia os dados para os campos, eu ajusto o que
                      // for diferente (data, distância, local) e sigo com o cadastro manual.
                      IconButton(
                        key: Key('medal-base-${edition['id']}'),
                        tooltip: 'Não é esta edição: usar como base',
                        icon: const Icon(Icons.edit_note_rounded),
                        onPressed: () {
                          fillFrom(edition);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Dados copiados para os campos. Ajuste o que for diferente e toque em Fazer o cadastro manual.',
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        key: Key('medal-open-${edition['id']}'),
                        tooltip: 'Abrir a corrida',
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EditionScreen(
                              gateway: widget.gateway,
                              editionId: edition['id'] as String,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (chosenId != null) ...[
              const SizedBox(height: 4),
              raceDataCard(),
            ],
          ],
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note!, key: const Key('medal-scan-note')),
            ),
          if (allLines.isNotEmpty) readLinesTile(),
          readCard(),
          const SizedBox(height: 8),
          if (matches.isEmpty)
            // Não achou: sugere cadastrar a corrida, já com o que foi lido na medalha.
            Card(
              key: const Key('medal-scan-suggest'),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Esta corrida ainda não está no catálogo.',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Confira os dados acima e faça o cadastro manual: ele leva o que estiver nos campos, junto com a foto da medalha.',
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          // Sempre disponível, depois da busca pela foto: cadastro manual com os campos (editáveis) acima.
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('medal-scan-request'),
              onPressed: requestRace,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 13),
              ),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('Cadastrar esta corrida'),
            ),
          ),
        ],
      ],
    ),
  );
}
