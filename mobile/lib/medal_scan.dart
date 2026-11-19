import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'edition_cards.dart' show EditionCompactCard;
import 'edition_requests.dart';
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

  // O único campo da tela: o nome da corrida, já preenchido com o que foi lido da medalha.
  final name = TextEditingController();
  // O resto do que a medalha mostrou (sem campo na tela): vai junto se for preciso cadastrar a corrida.
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
    appBar: AppBar(title: const Text('Cadastrar medalha')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 160,
            child: Image.file(
              File(widget.photoPath),
              key: const Key('medal-scan-photo'),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Um campo só: o nome da corrida. Vem do que foi lido da medalha; dá para corrigir e buscar de novo.
        TextField(
          key: const Key('medal-edit-name'),
          controller: name,
          maxLength: 160,
          textInputAction: TextInputAction.search,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => searchAgain(),
          decoration: InputDecoration(
            labelText: 'Nome da corrida',
            hintText: 'Procure a corrida da sua medalha',
            counterText: '',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              key: const Key('medal-scan-search-again'),
              tooltip: 'Buscar',
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: working ? null : searchAgain,
            ),
          ),
        ),
        const SizedBox(height: 12),
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
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note!, key: const Key('medal-scan-note')),
            ),
          if (matches.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Toque na sua corrida:',
                key: Key('medal-scan-found'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
            // O mesmo cartão das outras listas de corridas. Tocar segue para tempo, lugar, km, pace, peito e avaliação.
            for (final edition in matches)
              KeyedSubtree(
                key: Key('medal-match-${edition['id']}'),
                child: EditionCompactCard(
                  gateway: widget.gateway,
                  edition: edition,
                  actions: registered.contains(edition['id'])
                      ? Text(
                          'Já cadastrada por você',
                          style: TextStyle(
                            color: context.muted,
                            fontSize: 12.5,
                          ),
                        )
                      : null,
                  onTap: () {
                    fillFrom(edition);
                    concludeChosen();
                  },
                ),
              ),
          ] else
            // Não achou: sugere cadastrar a corrida, já com o que foi lido na medalha.
            Padding(
              key: const Key('medal-scan-suggest'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Esta corrida ainda não está no catálogo. Corrija o nome e busque de novo, ou cadastre a corrida.',
                style: TextStyle(color: context.muted),
              ),
            ),
          const SizedBox(height: 4),
          // Sempre à mão e discretos: cadastrar a corrida (leva a foto da medalha) e procurar o nome na internet.
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: const Key('medal-scan-request'),
                onPressed: requestRace,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12.5),
                ),
                icon: const Icon(Icons.add_location_alt_outlined, size: 16),
                label: const Text('Cadastrar esta corrida'),
              ),
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
      ],
    ),
  );
}
