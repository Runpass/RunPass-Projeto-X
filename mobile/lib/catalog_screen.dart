import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'agenda.dart';
import 'catalog_views.dart';
import 'duration_field.dart';
import 'edition_cards.dart';
import 'friends.dart';
import 'grid_columns.dart';
import 'home_screen.dart';
import 'edition_requests.dart';
import 'identity_gateway.dart';
import 'location_picker.dart';
import 'my_races.dart';
import 'notifications.dart';
import 'organizer_post.dart';
import 'profile_photo.dart';
import 'runpass_theme.dart';

export 'home_screen.dart';
export 'my_races.dart';

typedef PhotoSelector = Future<List<int>?> Function();

/// Abre um link fora do app. Troque nos testes para nao abrir o navegador de verdade.
typedef LinkOpener = Future<bool> Function(Uri uri);
LinkOpener linkOpener = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// So devolve links https com dominio e sem usuario/senha embutidos; qualquer outra coisa vira null
/// (a fonte do catalogo nunca decide abrir esquemas como javascript: ou intent:).
Uri? safeHttpsUri(Object? value) {
  if (value is! String || value.length > 500) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty) return null;
  return uri;
}

/// Perfil do organizador numa rede social: só https e só dos domínios da própria rede (o servidor
/// já valida; aqui é a segunda barreira antes de abrir o navegador).
Uri? socialProfileUri(Object? value, String network) {
  final uri = safeHttpsUri(value);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  final domains = network == 'instagram'
      ? const ['instagram.com', 'www.instagram.com']
      : const ['facebook.com', 'www.facebook.com', 'fb.com', 'www.fb.com'];
  return domains.contains(host) ? uri : null;
}

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

/// "22 de setembro de 2024", como na aba de avaliações.
String longDate(String value) {
  const months = [
    'janeiro',
    'fevereiro',
    'março',
    'abril',
    'maio',
    'junho',
    'julho',
    'agosto',
    'setembro',
    'outubro',
    'novembro',
    'dezembro',
  ];
  final parts = value.split('-');
  final month = parts.length == 3 ? int.tryParse(parts[1]) : null;
  if (month == null || month < 1 || month > 12) return displayDate(value);
  return '${int.parse(parts[2])} de ${months[month - 1]} de ${parts[0]}';
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

/// Perfil para a miniatura da aba "Perfil" do menu inferior. Guardado quando alguma tela já
/// busca o /me por conta própria (Início, Perfil); o menu nunca faz uma requisição só para
/// isso, então, antes do primeiro /me da sessão, a aba mostra o ícone padrão.
final Map<IdentityGateway, Map<String, dynamic>> _navProfiles = {};

/// Avisa a aba "Perfil" (em qualquer tela já aberta) para redesenhar com a foto nova, mesmo
/// quando a tela que buscou o /me não dá outro motivo para o menu inferior ser reconstruído
/// (por exemplo, ao abrir o app: a primeira busca do Início termina depois do primeiro
/// desenho da tela, sem nenhum setState próprio até alguma interação).
final ValueNotifier<int> _navProfileVersion = ValueNotifier(0);

void rememberNavProfile(IdentityGateway gateway, Map<String, dynamic> profile) {
  _navProfiles[gateway] = profile;
  _navProfileVersion.value++;
}

void forgetNavProfile(IdentityGateway gateway) {
  _navProfiles.remove(gateway);
  _navProfileVersion.value++;
}

/// [subScreen]: tela interna (detalhe, rascunho). Tocar na aba já destacada leva à tela principal
/// da aba, em vez de não fazer nada.
Widget runPassNavigation(
  BuildContext context,
  IdentityGateway gateway,
  int selectedIndex, {
  bool subScreen = false,
}) {
  Widget avatar() => ValueListenableBuilder<int>(
    valueListenable: _navProfileVersion,
    builder: (context, _, _) => ProfileAvatar(
      key: const Key('nav-profile-avatar'),
      radius: 15,
      gateway: gateway,
      profile: _navProfiles[gateway],
    ),
  );
  return RunPassBottomNav(
    selectedIndex: selectedIndex,
    // Sem profileIconSelected proprio (sem borda): a selecao da aba Perfil
    // e marcada so pelo mesmo fundo destacado das outras abas, como os
    // demais icones do menu. RunPassBottomNav reaproveita profileIcon.
    profileIcon: avatar(),
    onDestinationSelected: (index) {
      if (index == selectedIndex && !subScreen) return;
      final screen = switch (index) {
        0 => RunPassHomeScreen(gateway: gateway),
        1 => MedalCollectionScreen(gateway: gateway),
        2 => CatalogScreen(gateway: gateway),
        _ => RunnerProfileScreen(gateway: gateway),
      };
      final route = MaterialPageRoute<void>(builder: (_) => screen);
      if (subScreen) {
        Navigator.of(context).pushAndRemoveUntil(route, (r) => false);
      } else {
        Navigator.of(context).pushReplacement(route);
      }
    },
  );
}

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

/// Arte padrão de uma corrida sem imagem aprovada: degradê estável (a mesma corrida sempre tem a mesma
/// cor), silhueta de corredor e a maior distância. Não é foto nem logo da prova: só uma identidade visual.
class RaceArt extends StatelessWidget {
  final Map<String, dynamic> edition;

  /// A distância fica no canto superior esquerdo, na lista e no banner da corrida; o corredor, à direita.
  final bool labelAtLeft;
  const RaceArt({super.key, required this.edition, this.labelAtLeft = false});

  static const palettes = [
    [runPassNavy, Color(0xff5a2a1c), runPassOrange],
    [Color(0xff0f2a43), Color(0xff1d5d7a), Color(0xff4cb5ae)],
    [Color(0xff24103f), Color(0xff6a3d9a), Color(0xffff7a59)],
    [Color(0xff10321f), Color(0xff2f7d4f), Color(0xffd9b44a)],
    [Color(0xff3a0f1e), Color(0xff9a2e4d), Color(0xffff9d5c)],
  ];

  List<Color> get colors {
    final id = '${edition['id'] ?? edition['name'] ?? ''}';
    final seed = id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
    return palettes[seed % palettes.length];
  }

  String? get longest {
    final km = [
      for (final d in (edition['distances'] as List? ?? const []))
        if ((d as Map)['kilometers'] is num)
          (d['kilometers'] as num).toDouble(),
    ];
    if (km.isEmpty) return null;
    km.sort();
    return distanceLabel(km.last);
  }

  @override
  Widget build(BuildContext context) {
    final label = longest;
    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    );
    return DecoratedBox(
      key: const Key('race-art'),
      decoration: decoration,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(
              right: -14,
              bottom: -26,
              child: Icon(
                Icons.directions_run,
                size: 170,
                color: Colors.white.withValues(alpha: .13),
              ),
            ),
            if (label != null)
              Positioned.fill(
                child: CustomPaint(
                  painter: _ArtLabelPainter(label, left: labelAtLeft),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Pinta a distância como desenho (marca d'água), para não virar um texto duplicado na tela.
class _ArtLabelPainter extends CustomPainter {
  final String label;
  final bool left;
  const _ArtLabelPainter(this.label, {this.left = false});

  @override
  void paint(Canvas canvas, Size size) {
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: .22),
          fontSize: 56,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(
      canvas,
      left ? const Offset(16, 10) : Offset(size.width - text.width - 18, 52),
    );
  }

  @override
  bool shouldRepaint(_ArtLabelPainter old) =>
      old.label != label || old.left != left;
}

/// Fundo do cartão da corrida na lista: ocupa o espaço todo. A imagem aprovada (banner ou logo) quando
/// existe; senão a arte padrão da corrida. Só corridas com `imageReference` pedem o link, e ele fica
/// em cache por alguns minutos.
class EditionCover extends StatefulWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> edition;
  const EditionCover({super.key, required this.gateway, required this.edition});

  /// Links temporários já obtidos (corrida -> url, instante), para a rolagem não repetir pedidos.
  static final Map<String, (String, DateTime)> cache = {};

  @override
  State<EditionCover> createState() => _EditionCoverState();
}

class _EditionCoverState extends State<EditionCover> {
  String? url;

  @override
  void initState() {
    super.initState();
    resolve();
  }

  Future<void> resolve() async {
    final id = widget.edition['id'] as String;
    if (widget.edition['imageReference'] == null) return;
    final hit = EditionCover.cache[id];
    if (hit != null && DateTime.now().difference(hit.$2).inMinutes < 4) {
      url = hit.$1;
      return;
    }
    try {
      final link = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(id)}/banner',
      );
      final found = link['url'] as String?;
      if (found == null) return;
      EditionCover.cache[id] = (found, DateTime.now());
      if (mounted) setState(() => url = found);
    } on Exception {
      // Sem imagem, fica a arte padrão: a lista nunca depende dela.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.edition['status'] == 'archived') {
      return ColoredBox(color: context.panelStrong);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        RaceArt(edition: widget.edition, labelAtLeft: true),
        if (url != null)
          Image.network(
            url!,
            key: const Key('edition-cover-image'),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// Intervalo (`from`, `to`) em AAAA-MM-DD do ano escolhido no filtro, ou null se não for um ano.
({String from, String to})? yearRange(String raw) {
  final year = int.tryParse(raw.trim());
  if (year == null || year < 1990 || year > 2100) return null;
  return (from: '$year-01-01', to: '$year-12-31');
}

/// Anos oferecidos no filtro: do próximo ano até 2024, do mais recente para o mais antigo.
List<int> filterYears([DateTime? now, Iterable<int> extra = const []]) {
  // A faixa padrão vai do próximo ano até 2024; corridas cadastradas com data fora dela (mais antigas ou mais
  // adiante) estendem a faixa, para o ano de qualquer corrida do catálogo poder ser escolhido.
  final extras = extra.toList();
  var top = (now ?? DateTime.now()).year + 1;
  var bottom = 2024;
  for (final y in extras) {
    if (y > top) top = y;
    if (y < bottom) bottom = y;
  }
  return [for (var y = top; y >= bottom; y--) y];
}

class CatalogScreen extends StatefulWidget {
  final IdentityGateway gateway;

  /// Só para testes: mantém a paginação do servidor (20 por página, "Carregar mais", sem reordenar).
  /// Em uso normal a lista carrega as páginas e ordena por data no aparelho.
  final bool serverPaging;
  const CatalogScreen({
    super.key,
    required this.gateway,
    this.serverPaging = false,
  });
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
      'year',
      'audience',
    ])
      key: TextEditingController(),
  };
  final form = GlobalKey<FormState>();
  // Sugestões enquanto digita: corridas cujo nome contém o texto, para escolher uma.
  // Busca por frase livre (rota /editions/search). Com frase, os campos abaixo sao ignorados.
  final phrase = TextEditingController();
  Map<String, dynamic>? searchInfo;
  final items = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> mine = {};
  // Situação da pessoa em cada corrida (desejada ou inscrita): edição -> `wanted` | `registered`.
  Map<String, String> plans = {};
  Map<String, String> activeFilters = {};
  String? nextCursor, error;
  // Situacao das inscricoes (filtro): nulo = qualquer.
  String? registration;
  int registrationEpoch =
      0; // recria o seletor ao limpar (reset() devolveria o valor antigo)
  bool loading = false;
  bool showFilters = false;

  int? get selectedYear => int.tryParse(fields['year']!.text);

  /// Anos das corridas já vistas (qualquer busca), para o filtro de ano alcançar todas as datas do catálogo.
  final Set<int> knownYears = {};

  /// Ordem da lista: 'date' (padrão) ou 'rating'. Cada ícone liga a sua ordem; tocar de novo inverte.
  String sortBy = 'date';

  /// Direção: em data, mais recentes primeiro; em avaliação, melhores primeiro.
  bool descending = true;

  /// Visualização escolhida (lista ou grade) e colunas da grade; ficam neste aparelho.
  CatalogViewMode viewMode = CatalogViewMode.list;
  int gridColumns = 2;

  @override
  void initState() {
    super.initState();
    load();
    loadMine();
    loadViewPreferences();
  }

  Future<void> loadViewPreferences() async {
    final mode = await CatalogViewMode.read();
    final columns = await GridColumns.read('catalog-grid-columns', fallback: 2);
    if (mounted) {
      setState(() {
        viewMode = mode;
        gridColumns = columns;
      });
    }
  }

  void chooseViewMode(CatalogViewMode mode) {
    setState(() => viewMode = mode);
    mode.write();
  }

  void chooseGridColumns(int columns) {
    setState(() => gridColumns = columns);
    GridColumns.write('catalog-grid-columns', columns);
  }

  /// Cartão da grade (compartilhado com a agenda e o perfil).
  Widget gridCard(Map<String, dynamic> edition) {
    final score = scoreOf(edition);
    return EditionGridCard(
      key: Key('grid-card-${edition['id']}'),
      gateway: widget.gateway,
      edition: edition,
      columns: gridColumns,
      subtitle:
          '${displayDate(edition['date'] as String)} · ${edition['city']}/${edition['state']}',
      shortDate: displayDate(edition['date'] as String).substring(0, 5),
      rating: score == null
          ? null
          : '★ ${decimalPt(score)} · ${reviewsOf(edition)} avaliações',
      onTap: loading ? null : () => openEdition(edition['id'] as String),
    );
  }

  /// Corpo da lista conforme a visualização escolhida.
  List<Widget> editionViews() {
    final shown = view;
    switch (viewMode) {
      case CatalogViewMode.list:
        return [for (final edition in shown) editionCard(edition)];
      case CatalogViewMode.grid:
        if (shown.isEmpty) return const [];
        return [
          GridView.count(
            key: const Key('catalog-grid'),
            crossAxisCount: gridColumns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: gridCardAspectRatio(gridColumns),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [for (final edition in shown) gridCard(edition)],
          ),
          const SizedBox(height: 12),
        ];
    }
  }

  Future<void> loadMine() async {
    final result = await loadMyEditions(widget.gateway);
    if (mounted) setState(() => mine = result);
    loadPlans();
  }

  /// Atalhos da lista: só ajudam, então uma falha deixa a lista sem marcas, sem erro na tela.
  Future<void> loadPlans() async {
    try {
      final page = await widget.gateway.request('/me/race-plans');
      if (!mounted) return;
      setState(
        () => plans = {
          for (final p in (page['items'] as List? ?? const []))
            if ((p as Map)['editionId'] is String && p['status'] is String)
              p['editionId'] as String: p['status'] as String,
        },
      );
    } on Exception {
      // Sem marcas.
    }
  }

  /// Marca ou desmarca "quero correr" / "inscrito" direto da lista (toque de novo para tirar).
  Future<void> togglePlan(Map<String, dynamic> edition, String status) async {
    final id = edition['id'] as String;
    final path = '/me/race-plans/${Uri.encodeComponent(id)}';
    try {
      if (plans[id] == status) {
        await widget.gateway.request(path, method: 'DELETE');
        if (mounted) setState(() => plans.remove(id));
      } else {
        await widget.gateway.request(
          path,
          method: 'PUT',
          body: {'status': status},
        );
        if (mounted) setState(() => plans[id] = status);
      }
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = catalogError(issue));
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.',
        );
      }
    }
  }

  /// "Já corri" na lista: com uma só distância cria o rascunho e abre o registro; com várias (ou se já
  /// existe registro) abre a corrida, onde a pessoa escolhe a distância.
  Future<void> markRan(Map<String, dynamic> edition) async {
    final id = edition['id'] as String;
    final distances = (edition['distances'] as List).cast<Map>();
    if (!mine.containsKey(id) && distances.length == 1) {
      try {
        final draft = await widget.gateway.request(
          '/participations',
          method: 'POST',
          body: {'editionId': id, 'distanceId': distances.first['id']},
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ParticipationDraftScreen(
              gateway: widget.gateway,
              initial: draft,
            ),
          ),
        );
        loadMine();
        return;
      } on IdentityIssue catch (issue) {
        if (issue.code != 'PARTICIPATION_EXISTS' && mounted) {
          setState(() => error = catalogError(issue));
          return;
        }
      } on Exception {
        if (mounted) {
          setState(
            () => error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.',
          );
        }
        return;
      }
    }
    await openEdition(id);
  }

  Future<void> openEdition(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditionScreen(gateway: widget.gateway, editionId: id),
      ),
    );
    loadMine();
  }

  /// Cartão da corrida: a imagem (ou a arte padrão) cobre o cartão todo; o texto e os atalhos ficam por cima.
  Widget editionCard(Map<String, dynamic> edition) {
    final archived = edition['status'] == 'archived';
    final lines = [
      '${displayDate(edition['date'] as String)} · ${edition['city']}/${edition['state']}',
      (edition['distances'] as List)
          .map((d) => '${d['kilometers']} km')
          .join(' · '),
      if (archived)
        'Arquivada: ${archivedReasonLabel(edition['archivedReason'] as String?) ?? 'motivo não informado'}',
      if (scoreOf(edition) != null)
        '★ ${decimalPt(scoreOf(edition)!)} · ${reviewsOf(edition)} avaliações',
      if (mine.containsKey(edition['id'])) 'Já está na sua lista',
    ];
    return EditionListCard(
      gateway: widget.gateway,
      edition: edition,
      lines: lines,
      onTap: loading ? null : () => openEdition(edition['id'] as String),
      overlay: quickActions(edition),
    );
  }

  Widget quickActions(Map<String, dynamic> edition) {
    final id = edition['id'] as String;
    final status = edition['status'];
    if (status == 'archived') return const SizedBox.shrink();
    final upcoming = status != 'past';
    // Ícones sobre a imagem: círculo escuro translúcido; marcado fica laranja.
    Widget action(
      String key,
      IconData icon,
      String label,
      bool on,
      VoidCallback onTap,
    ) => Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: on ? runPassOrange : Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(
          key: Key('$key-$id'),
          tooltip: label,
          visualDensity: VisualDensity.compact,
          color: Colors.white,
          icon: Icon(icon, size: 22),
          onPressed: loading ? null : onTap,
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (upcoming) ...[
          action(
            'quick-wanted',
            plans[id] == 'wanted' ? Icons.favorite : Icons.favorite_border,
            plans[id] == 'wanted' ? 'Tirar de Quero correr' : 'Quero correr',
            plans[id] == 'wanted',
            () => togglePlan(edition, 'wanted'),
          ),
          action(
            'quick-registered',
            Icons.how_to_reg_outlined,
            plans[id] == 'registered' ? 'Tirar de Inscrito' : 'Inscrito',
            plans[id] == 'registered',
            () => togglePlan(edition, 'registered'),
          ),
        ],
        action(
          'quick-ran',
          mine.containsKey(id)
              ? Icons.check_circle_rounded
              : Icons.directions_run,
          mine.containsKey(id) ? 'Ver meu registro' : 'Já corri',
          mine.containsKey(id),
          () => markRan(edition),
        ),
      ],
    );
  }

  @override
  void dispose() {
    phrase.dispose();
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Itens por página da busca atual. O cursor do servidor é amarrado aos filtros (inclui o limite),
  /// então o limite não pode mudar no meio de uma busca.
  late String pageLimit = widget.serverPaging ? '20' : '100';

  static num? scoreOf(Map<String, dynamic> edition) {
    final raw = (edition['runScore'] as Map?)?['value'];
    return raw is num ? raw : num.tryParse('${raw ?? ''}');
  }

  static int reviewsOf(Map<String, dynamic> edition) =>
      ((edition['runScore'] as Map?)?['reviewCount'] as num?)?.toInt() ?? 0;

  /// Prioridade da corrida para ESTA pessoa: 0 já corri (ou tenho registro), 1 inscrito (pretendo correr),
  /// 2 desejo correr, 3 as demais. Cada perfil vê a sua própria ordem, pois vem das suas marcações.
  int priority(Map<String, dynamic> edition) {
    final id = edition['id'] as String;
    if (mine.containsKey(id)) return 0;
    return switch (plans[id]) {
      'registered' => 1,
      'wanted' => 2,
      _ => 3,
    };
  }

  /// Itens na ordem escolhida pelos ícones: primeiro as minhas (por prioridade), depois as demais. Dentro de
  /// cada grupo, por data ou por avaliação (cada ícone inverte a direção) e, em empate, por nº de avaliações
  /// e pelo nome. Corrida sem avaliação fica sempre por último na ordem por avaliação.
  List<Map<String, dynamic>> get view {
    final list = [...items];
    if (widget.serverPaging) return list;
    list.sort((a, b) {
      final byPriority = priority(a).compareTo(priority(b));
      if (byPriority != 0) return byPriority;
      if (sortBy == 'rating') {
        final sa = scoreOf(a);
        final sb = scoreOf(b);
        if ((sa == null) != (sb == null)) return sa == null ? 1 : -1;
        if (sa != null && sb != null && sa != sb) {
          return descending ? sb.compareTo(sa) : sa.compareTo(sb);
        }
        final byReviews = reviewsOf(b).compareTo(reviewsOf(a));
        if (byReviews != 0) return byReviews;
      }
      final byDate = (a['date'] as String).compareTo(b['date'] as String);
      final byName = '${a['name']}'.compareTo('${b['name']}');
      if (byDate == 0) return byName;
      return sortBy == 'date' && !descending ? byDate : -byDate;
    });
    return list;
  }

  void sortByDate() => setState(() {
    if (sortBy == 'date') {
      descending = !descending;
    } else {
      sortBy = 'date';
      descending = true;
    }
  });

  void sortByRating() => setState(() {
    if (sortBy == 'rating') {
      descending = !descending;
    } else {
      sortBy = 'rating';
      descending = true;
    }
  });

  /// Ícone de ordenação: o símbolo da ordem e, só na ordem ativa, a seta da direção.
  Widget sortGlyph(IconData base, {required bool active}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(base, size: 20),
      if (active)
        Icon(
          descending
              ? Icons.arrow_downward_rounded
              : Icons.arrow_upward_rounded,
          size: 16,
          semanticLabel: descending ? 'Ordem decrescente' : 'Ordem crescente',
        ),
    ],
  );

  /// Ordenar por data precisa do conjunto todo: carrega as próximas páginas (até 500 corridas).
  Future<void> loadRest() async {
    var pages = 0;
    while (mounted &&
        !widget.serverPaging &&
        nextCursor != null &&
        pages++ < 5) {
      await load(more: true);
      if (error != null) return;
    }
  }

  void onPhraseChanged(String text) => setState(() {});

  Future<void> load({bool more = false}) async {
    if (loading) return;
    final sentence = phrase.text.trim();
    if (!more) {
      activeFilters = sentence.isNotEmpty
          ? {}
          : {
              for (final entry in fields.entries)
                if (entry.value.text.trim().isNotEmpty && entry.key != 'year')
                  entry.key: entry.value.text.trim(),
              if (yearRange(fields['year']!.text) case final range?) ...{
                'dateFrom': range.from,
                'dateTo': range.to,
              },
              'registrationStatus': ?registration,
            };
      searchInfo = null;
      items.clear();
      nextCursor = null;
      pageLimit = widget.serverPaging ? '20' : '100';
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
                'limit': pageLimit,
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
        final year = int.tryParse('${entry['date']}'.split('-').first);
        if (year != null && year >= 1990 && year <= 2100) knownYears.add(year);
      }
      nextCursor = page['nextCursor'] as String?;
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (!more && error == null) await loadRest();
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
    // Primeiro o reset do formulário (ele devolve ao seletor o valor antigo e dispara o onChanged);
    // só depois limpo os campos, para o último valor valer.
    form.currentState?.reset();
    for (final controller in fields.values) {
      controller.clear();
    }
    setState(() {
      registration = null;
      registrationEpoch++;
    });
    load();
  }

  /// Há algum filtro além do nome? Se houver, o nome deixa de ser obrigatório.
  bool get hasOtherFilter =>
      fields['distanceKm']!.text.trim().isNotEmpty ||
      fields['year']!.text.trim().isNotEmpty ||
      fields['audience']!.text.trim().isNotEmpty ||
      fields['state']!.text.trim().isNotEmpty ||
      fields['city']!.text.trim().isNotEmpty ||
      registration != null;

  Widget filter(
    String key,
    String label, {
    String? Function(String)? validate,
    int? maxLength,
    String? hint,
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      controller: fields[key],
      maxLength: maxLength,
      decoration: InputDecoration(labelText: label, helperText: hint),
      keyboardType: key == 'distanceKm'
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      validator: (value) => value == null || value.trim().isEmpty
          ? (required && !hasOtherFilter
                ? 'Informe o nome da corrida ou escolha outro filtro.'
                : null)
          : validate?.call(value.trim()),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const RunPassWordmark(compact: true),
      actions: [
        IconButton(
          key: const Key('catalog-agenda'),
          visualDensity: VisualDensity.compact,
          tooltip: 'Minha agenda',
          icon: const Icon(Icons.calendar_month_rounded),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AgendaScreen(gateway: widget.gateway),
            ),
          ),
        ),
        IconButton(
          key: const Key('catalog-search-toggle'),
          visualDensity: VisualDensity.compact,
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
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 2),
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
              onSubmitted: (_) {
                load();
              },
              onChanged: onPhraseChanged,
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
          // Sempre visíveis (não ficam escondidos atrás da lupa): pedir cadastro e acompanhar os pedidos.
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  key: const Key('catalog-request-new'),
                  onPressed: loading ? null : requestRace,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Pedir cadastro da corrida'),
                ),
                OutlinedButton.icon(
                  key: const Key('catalog-request-mine'),
                  onPressed: openMyRequests,
                  icon: const Icon(Icons.assignment_outlined),
                  label: const Text('Minhas solicitações'),
                ),
              ],
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
                        'Nome da corrida',
                        maxLength: 160,
                        hint: 'Obrigatório se você não escolher estado, ano, distância ou inscrições',
                        required: true,
                      ),
                      // Mesmo seletor do editar perfil: lista fechada de estado e cidade, sem digitar.
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: InkWell(
                          key: const Key('filter-location'),
                          onTap: () async {
                            final picked = await pickBrLocation(
                              context,
                              initialUf: fields['state']!.text.isEmpty
                                  ? null
                                  : fields['state']!.text,
                              initialCity: fields['city']!.text.isEmpty
                                  ? null
                                  : fields['city']!.text,
                            );
                            if (picked != null && mounted) {
                              setState(() {
                                fields['state']!.text = picked.$1;
                                fields['city']!.text = picked.$2;
                              });
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Estado e cidade (opcional)',
                              suffixIcon: fields['city']!.text.isEmpty
                                  ? const Icon(Icons.expand_more)
                                  : IconButton(
                                      key: const Key('filter-location-clear'),
                                      tooltip: 'Limpar estado e cidade',
                                      icon: const Icon(Icons.close_rounded),
                                      onPressed: () => setState(() {
                                        fields['state']!.text = '';
                                        fields['city']!.text = '';
                                      }),
                                    ),
                            ),
                            child: Text(
                              fields['city']!.text.isEmpty
                                  ? 'Todos os estados e cidades'
                                  : '${fields['state']!.text} - ${fields['city']!.text}',
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            for (final km in const ['5', '10', '21', '42'])
                              ChoiceChip(
                                key: Key('km-chip-$km'),
                                label: Text('$km km'),
                                selected: fields['distanceKm']!.text == km,
                                onSelected: (picked) => setState(
                                  () => fields['distanceKm']!.text = picked
                                      ? km
                                      : '',
                                ),
                              ),
                          ],
                        ),
                      ),
                      filter(
                        'distanceKm',
                        'Distância em km (opcional)',
                        hint: 'Ex.: 5, 10, 21 ou 42',
                        validate: (value) {
                          final km = double.tryParse(value);
                          return km != null && km.isFinite && km > 0
                              ? null
                              : 'Informe uma distância positiva, usando ponto para decimais.';
                        },
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
                        onPressed: loading
                            ? null
                            : () {
                                // Com uma frase acima, o formulário é ignorado: nada a validar.
                                if (phrase.text.trim().isEmpty &&
                                    !(form.currentState?.validate() ?? true)) {
                                  return;
                                }
                                load();
                              },
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
          // Mesmo espaço (12) entre "Minhas solicitações", o público e o ano.
          if (showFilters) const SizedBox(height: 12),
          if (error != null) ...[
            Text(error!, key: const Key('catalog-error')),
            TextButton(
              onPressed: loading ? null : () => load(more: nextCursor != null),
              child: const Text('Tentar novamente'),
            ),
          ],
          // Público (todas, adultos ou kids) e, no espaço livre ao lado, a ordem da lista.
          Row(
            children: [
              // Público: todas, só adultas ou só kids (kids = nome com Kids/Infantil/Mirim).
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SegmentedButton<String>(
                      key: ValueKey('filter-audience-$registrationEpoch'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: '', label: Text('Todas')),
                        ButtonSegment(value: 'adult', label: Text('Adultos')),
                        ButtonSegment(value: 'kids', label: Text('Kids')),
                      ],
                      selected: {fields['audience']!.text},
                      onSelectionChanged: loading
                          ? null
                          : (value) {
                              setState(
                                () => fields['audience']!.text = value.first,
                              );
                              load();
                            },
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('catalog-sort-rating'),
                tooltip: sortBy != 'rating'
                    ? 'Ordenar por avaliação'
                    : (descending
                          ? 'Melhores avaliações primeiro (toque para inverter)'
                          : 'Piores avaliações primeiro (toque para inverter)'),
                isSelected: sortBy == 'rating',
                icon: sortGlyph(
                  sortBy == 'rating'
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  active: sortBy == 'rating',
                ),
                onPressed: loading ? null : sortByRating,
              ),
              IconButton(
                key: const Key('catalog-sort'),
                tooltip: sortBy != 'date'
                    ? 'Ordenar por data'
                    : (descending
                          ? 'Mais recentes primeiro (toque para inverter)'
                          : 'Mais antigas primeiro (toque para inverter)'),
                isSelected: sortBy == 'date',
                icon: sortGlyph(
                  Icons.calendar_today_rounded,
                  active: sortBy == 'date',
                ),
                onPressed: loading ? null : sortByDate,
              ),
              CatalogViewMenu(
                value: viewMode,
                onChanged: chooseViewMode,
                columns: gridColumns,
                onColumnsChanged: chooseGridColumns,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Ano no mesmo padrão do seletor de público (Todas/Adultos/Kids), mas com a lista
              // de anos, que rola para o lado quando não cabe.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    key: ValueKey('filter-year-$registrationEpoch'),
                    showSelectedIcon: false,
                    segments: [
                      const ButtonSegment(
                        value: '',
                        label: Text('Todos'),
                        icon: Icon(Icons.calendar_today_rounded, size: 16),
                      ),
                      for (final y in filterYears(null, {
                        ...knownYears,
                        ?selectedYear,
                      }))
                        ButtonSegment(value: '$y', label: Text('$y')),
                    ],
                    selected: {fields['year']!.text},
                    // O ano filtra na hora: é a única forma de escolher a data.
                    onSelectionChanged: loading
                        ? null
                        : (value) {
                            setState(() => fields['year']!.text = value.first);
                            load();
                          },
                  ),
                ),
              ),
            ],
          ),
          // Um pouco mais de ar entre a linha do ano e o primeiro cartão.
          const SizedBox(height: 16),
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
          ...editionViews(),
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

  /// Escolhe e recorta a imagem do banner sugerido; nulo se a pessoa desistir. Troque nos testes.
  final Future<List<int>?> Function(BuildContext context)? bannerSelector;

  /// Busca e desenha o embed do post do organizador. Trocáveis nos testes (a WebView não roda lá).
  final OEmbedFetcher? oembedFetcher;
  final OEmbedViewBuilder? embedBuilder;
  const EditionScreen({
    super.key,
    required this.gateway,
    required this.editionId,
    this.bannerSelector,
    this.oembedFetcher,
    this.embedBuilder,
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
  List<Map<String, dynamic>>? participants;
  int participantTotal = 0;
  bool loadingParticipants = false;
  // Quem marcou "inscrito" nesta corrida (`/editions/{id}/registrants`).
  List<Map<String, dynamic>>? registrants;
  int registrantTotal = 0;
  bool loadingRegistrants = false;
  // Fotos que os corredores publicaram para esta corrida (`/editions/{id}/photos`).
  List<Map<String, dynamic>>? photos;
  int photoTotal = 0;
  static const _photoColumnsKey = 'grid-columns-photos';
  int photoColumns = GridColumns.standard;
  bool loadingPhotos = false;
  bool showAllReviews = false;
  bool sendingBanner = false;
  // Detalhes (itens avaliados) da avaliação geral e da minha: recolher e expandir.
  bool showSummaryDetails = true, showMyDetails = true;
  Map<String, dynamic>? mine;
  Map<String, dynamic>? plan;
  bool savingPlan = false;
  String? bannerUrl, bannerCredit;
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
      loadBanner();
      loadParticipants();
      loadRegistrants();
      loadPhotos();
      GridColumns.read(_photoColumnsKey).then((n) {
        if (mounted) {
          setState(() {
            photoColumns = n;
          });
        }
      });
      loadMyParticipation();
      loadPlan();
    }
  }

  /// Banner aprovado pela equipe (cópia guardada pelo +1Pódio, com crédito). Sem banner ou com
  /// falha, o degradê de sempre continua: a imagem nunca bloqueia a tela.
  Future<void> loadBanner() async {
    if (edition?['imageReference'] == null) return;
    try {
      final link = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/banner',
      );
      if (!mounted) return;
      setState(() {
        bannerUrl = link['url'] as String?;
        bannerCredit =
            link['credit'] as String? ?? edition?['imageCredit'] as String?;
      });
    } on Exception {
      if (mounted) setState(() => bannerUrl = null);
    }
  }

  /// Quem concluiu esta corrida. O servidor só lista perfis que a pessoa pode ver; `total` é a
  /// contagem de todas as conclusões, sem identificar ninguém.
  Future<void> loadParticipants() async {
    setState(() => loadingParticipants = true);
    try {
      final page = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/participants',
        query: {'limit': '50'},
      );
      if (mounted) {
        participants = (page['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        participantTotal = (page['total'] as num?)?.toInt() ?? 0;
      }
    } on Exception {
      if (mounted) participants = null;
    } finally {
      if (mounted) setState(() => loadingParticipants = false);
    }
  }

  /// Inscritos (plano `registered`): só perfis que a pessoa pode ver; `total` conta todos.
  Future<void> loadRegistrants() async {
    setState(() => loadingRegistrants = true);
    try {
      final page = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/registrants',
        query: {'limit': '50'},
      );
      if (mounted) {
        registrants = (page['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        registrantTotal = (page['total'] as num?)?.toInt() ?? 0;
      }
    } on Exception {
      if (mounted) registrants = null;
    } finally {
      if (mounted) setState(() => loadingRegistrants = false);
    }
  }

  /// Fotos de medalha publicadas por quem concluiu a corrida (só as fotos próprias das
  /// publicações públicas; nunca a arte padrão do catálogo).
  Future<void> loadPhotos() async {
    setState(() => loadingPhotos = true);
    try {
      final page = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/photos',
        query: {'limit': '60'},
      );
      if (mounted) {
        photos = (page['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        photoTotal = (page['total'] as num?)?.toInt() ?? 0;
      }
    } on Exception {
      if (mounted) photos = null;
    } finally {
      if (mounted) setState(() => loadingPhotos = false);
    }
  }

  /// Situação da pessoa nesta corrida: `wanted` (quero correr) ou `registered` (inscrito).
  Future<void> loadPlan() async {
    try {
      final found = await widget.gateway.request(
        '/me/race-plans/${Uri.encodeComponent(widget.editionId)}',
      );
      if (mounted) setState(() => plan = found);
    } on Exception {
      if (mounted) setState(() => plan = null);
    }
  }

  /// Marca ou, se já estava marcado, desmarca (toque de novo para tirar).
  Future<void> setPlan(String status) async {
    if (savingPlan) return;
    setState(() {
      savingPlan = true;
      error = null;
    });
    final id = Uri.encodeComponent(widget.editionId);
    try {
      if (plan?['status'] == status) {
        await widget.gateway.request('/me/race-plans/$id', method: 'DELETE');
        if (mounted) setState(() => plan = null);
      } else {
        final saved = await widget.gateway.request(
          '/me/race-plans/$id',
          method: 'PUT',
          body: {'status': status, 'distanceId': ?selectedDistance},
        );
        if (mounted) setState(() => plan = saved);
      }
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = catalogError(issue));
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.',
        );
      }
    } finally {
      if (mounted) setState(() => savingPlan = false);
    }
  }

  /// Escolha da situação: quero correr, inscrito (vou correr) e já corri (registro da participação).
  Widget situation(Map<String, dynamic> body) {
    final past = body['status'] == 'past';
    final archived = body['status'] == 'archived';
    final current = plan?['status'] as String?;
    Widget choice(
      String key,
      IconData icon,
      String label,
      bool selected,
      VoidCallback? onTap,
    ) => selected
        ? FilledButton.icon(
            key: Key(key),
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          )
        : OutlinedButton.icon(
            key: Key(key),
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Minha situação nesta corrida',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!past && !archived)
              choice(
                'plan-wanted',
                current == 'wanted' ? Icons.favorite : Icons.favorite_border,
                'Quero correr',
                current == 'wanted',
                savingPlan ? null : () => setPlan('wanted'),
              ),
            if (!past && !archived)
              choice(
                'plan-registered',
                Icons.how_to_reg_outlined,
                'Inscrito',
                current == 'registered',
                savingPlan ? null : () => setPlan('registered'),
              ),
            if (mine == null && selectedDistance != null && !archived)
              choice(
                'plan-ran',
                Icons.directions_run,
                saving ? 'Salvando...' : 'Já corri',
                false,
                saving ? null : createDraft,
              ),
          ],
        ),
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              current == 'wanted'
                  ? 'Esta corrida está na sua agenda, em Desejadas.'
                  : 'Esta corrida está na sua agenda, em Inscritas.',
              key: const Key('plan-note'),
            ),
          ),
        if (!past && !archived && selectedDistance == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Escolha uma distância para registrar que você já correu.',
              style: TextStyle(color: context.muted),
            ),
          ),
      ],
    );
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

  /// Linha "Itens ... ▾" que recolhe/expande os detalhes de uma avaliação.
  Widget _detailsToggle({
    required Key key,
    required String label,
    required bool expanded,
    required VoidCallback onTap,
  }) => InkWell(
    key: key,
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Text(
            expanded ? 'Recolher' : 'Expandir',
            style: const TextStyle(
              color: runPassOrange,
              fontWeight: FontWeight.w700,
            ),
          ),
          Icon(
            expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            color: runPassOrange,
          ),
        ],
      ),
    ),
  );

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
      expanded: showMyDetails,
      onToggle: () => setState(() => showMyDetails = !showMyDetails),
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

  Widget hero(Map<String, dynamic> body) {
    final wanted = plan?['status'] == 'wanted';
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 150),
      child: Stack(
        children: [
          // Base: arte padrão da corrida; a imagem aprovada, quando existe, cobre por cima.
          Positioned.fill(child: RaceArt(edition: body, labelAtLeft: true)),
          if (bannerUrl != null)
            Positioned.fill(
              child: Image.network(
                bannerUrl!,
                key: const Key('hero-image'),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (bannerUrl != null)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Color(0xCC000000)],
                  ),
                ),
              ),
            ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Os ícones ficam numa linha própria: o título longo nunca passa por cima deles.
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Voltar',
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const Key('hero-wanted'),
                        tooltip: wanted
                            ? 'Tirar de Quero correr'
                            : 'Quero correr',
                        color: Colors.white,
                        icon: Icon(
                          wanted ? Icons.favorite : Icons.favorite_border,
                        ),
                        onPressed: savingPlan ? null : () => setPlan('wanted'),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                  child: Text(
                    body['name'] as String,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .92),
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                    ),
                  ),
                ),
                if (bannerUrl != null && bannerCredit != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Text(
                      'Foto: $bannerCredit',
                      key: const Key('hero-credit'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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

  Future<void> openLink(Uri uri) async {
    var opened = false;
    try {
      opened = await linkOpener(uri);
    } on Exception {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o link.')),
      );
    }
  }

  /// Site da corrida e pagina de inscricao, so quando a fonte informou um link https valido.
  Widget linksSection(Map<String, dynamic> body) {
    final site = safeHttpsUri(body['officialUrl']);
    final buy = safeHttpsUri(body['registrationUrl']);
    final instagram = socialProfileUri(body['instagramUrl'], 'instagram');
    final facebook = socialProfileUri(body['facebookUrl'], 'facebook');
    if (site == null && buy == null && instagram == null && facebook == null) {
      return const SizedBox.shrink();
    }
    final closed =
        body['registrationStatus'] == 'closed' ||
        body['registrationStatus'] == 'sold_out';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (buy != null)
            FilledButton.icon(
              key: const Key('link-compra'),
              onPressed: () => openLink(buy),
              icon: const Icon(Icons.confirmation_number_outlined),
              label: Text(closed ? 'Página de inscrição' : 'Comprar inscrição'),
            ),
          if (site != null)
            OutlinedButton.icon(
              key: const Key('link-site'),
              onPressed: () => openLink(site),
              icon: const Icon(Icons.public_rounded),
              label: const Text('Site da corrida'),
            ),
          if (instagram != null)
            OutlinedButton.icon(
              key: const Key('link-instagram'),
              onPressed: () => openLink(instagram),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Ver no Instagram'),
            ),
          if (facebook != null)
            OutlinedButton.icon(
              key: const Key('link-facebook'),
              onPressed: () => openLink(facebook),
              icon: const Icon(Icons.thumb_up_alt_outlined),
              label: const Text('Ver no Facebook'),
            ),
        ],
      ),
    );
  }

  Widget aboutTab(Map<String, dynamic> body) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      header(body),
      // Nota média e quantidade de avaliações; tocar leva à aba Avaliações.
      Builder(
        builder: (tabContext) => InkWell(
          key: const Key('about-rating'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => DefaultTabController.of(tabContext).animateTo(1),
          child: scoreCard(body),
        ),
      ),
      const SizedBox(height: 16),
      if (body['description'] != null) Text(body['description'] as String),
      if (body['organizerName'] != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('Organização: ${body['organizerName']}'),
        ),
      linksSection(body),
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
      ],
      const SizedBox(height: 16),
      situation(body),
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
      const SizedBox(height: 20),
      OutlinedButton.icon(
        key: const Key('suggest-banner'),
        onPressed: sendingBanner ? null : suggestBanner,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(
          sendingBanner ? 'Enviando…' : 'Sugerir banner desta corrida',
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'A equipe confere a autorização da imagem antes de publicar.',
          style: TextStyle(fontSize: 12, color: context.muted),
        ),
      ),
    ],
  );

  /// Sugere o banner desta corrida: a imagem vai para a fila da equipe, que confere a autorização e decide.
  Future<void> suggestBanner() async {
    final messenger = ScaffoldMessenger.of(context);
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
      messenger.showSnackBar(SnackBar(content: Text(photoError(problem))));
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() => sendingBanner = true);
    var message =
        'Banner enviado. A equipe confere a autorização e decide se publica.';
    try {
      final reference = await uploadProfilePhoto(widget.gateway, bytes);
      await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/banner-suggestions',
        method: 'POST',
        body: {'imageReference': reference},
      );
    } on IdentityIssue catch (issue) {
      message = switch (issue.code) {
        'BANNER_SUGGESTION_EXISTS' => 'Você já enviou um banner para esta corrida e ele aguarda a decisão da equipe.',
        'TOO_MANY_PENDING_REQUESTS' => 'Você já tem 5 banners aguardando decisão. Espere a equipe decidir para enviar outro.',
        'EDITION_ARCHIVED' =>
          'Esta corrida saiu de circulação e não aceita banner.',
        _ => photoError(issue),
      };
    } on Exception {
      message =
          'Sem conexão com o servidor. Verifique a internet e tente novamente.';
    } finally {
      if (mounted) setState(() => sendingBanner = false);
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

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

  /// Média de um item da prova: barra laranja proporcional à nota (0 a 5) e a nota à direita.
  Widget bar(String label, IconData icon, double? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        SizedBox(width: 118, child: Text(label)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              key: Key('bar-$label'),
              value: ((value ?? 0) / 5).clamp(0.0, 1.0),
              minHeight: 8,
              color: runPassOrange,
              backgroundColor: context.panel,
            ),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            value == null ? '-' : decimalPt(value),
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );

  /// Média geral da prova: resumo da API, nota da edição ou média das avaliações carregadas.
  num? overallValue(Map<String, dynamic> body) {
    final score = body['runScore'] as Map<String, dynamic>?;
    final loaded = reviews ?? const <Map<String, dynamic>>[];
    return (reviewSummary?['average'] as num?) ??
        (score?['value'] is num
            ? score!['value'] as num
            : num.tryParse('${score?['value'] ?? ''}')) ??
        (loaded.isEmpty
            ? null
            : loaded.map(reviewAverage).reduce((a, b) => a + b) /
                  loaded.length);
  }

  /// Nota por item: resumo da API, média da lista pública ou, se nada disso existir, a minha avaliação.
  double? summaryCriterion(String key) {
    final byCriterion = (reviewSummary?['byCriterion'] as Map?) ?? const {};
    final fromPublic = (byCriterion[key] as num?)?.toDouble() ?? average(key);
    if (fromPublic != null) return fromPublic;
    final mineRatings = myReview?['ratings'] as Map?;
    final own = mineRatings?[key] as num?;
    final noPublicItems = criteria.every(
      (c) => ((byCriterion[c.$1] as num?) ?? average(c.$1)) == null,
    );
    return noPublicItems ? own?.toDouble() : null;
  }

  Widget scoreCard(Map<String, dynamic> body) {
    final score = body['runScore'] as Map<String, dynamic>?;
    final loaded = reviews ?? const <Map<String, dynamic>>[];
    final summary = reviewSummary;
    final value = overallValue(body);
    if (value == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.panel,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            const Text(
              '-',
              style: TextStyle(fontSize: 44, fontWeight: FontWeight.w900),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Stars(0, size: 20),
                  const SizedBox(height: 4),
                  Text(
                    'Esta prova ainda não tem avaliações.',
                    key: const Key('reviews-none'),
                    style: TextStyle(color: context.muted),
                  ),
                ],
              ),
            ),
          ],
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
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 6,
            child: Container(
              key: const Key('score-card'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.panel,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Text(
                    decimalPt(value),
                    style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stars(value, size: 19),
                        const SizedBox(height: 2),
                        Text(
                          '${thousands(count)} avaliações',
                          key: const Key('score-count'),
                          style: TextStyle(fontSize: 13, color: context.muted),
                        ),
                      ],
                    ),
                  ),
                ],
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
      ),
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
                        review['authorName'] as String? ?? 'Corredor +1Pódio',
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

  Widget _overallRow(num? value, int count) => Padding(
    key: const Key('summary-overall'),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        const Icon(Icons.star_rounded, size: 20),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'Média geral',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        Text(
          value == null
              ? '-'
              : '${decimalPt(value)} · ${thousands(count)} ${count == 1 ? 'avaliação' : 'avaliações'}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget reviewsTab(Map<String, dynamic> body) {
    final loaded = reviews;
    final overall = overallValue(body);
    final overallCount =
        (reviewSummary?['reviewCount'] as num?)?.toInt() ??
        ((body['runScore'] as Map?)?['reviewCount'] as num?)?.toInt() ??
        loaded?.length ??
        0;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        scoreCard(body),
        _detailsToggle(
          key: const Key('summary-details-toggle'),
          label: 'Itens da avaliação geral',
          expanded: showSummaryDetails,
          onTap: () => setState(() => showSummaryDetails = !showSummaryDetails),
        ),
        if (showSummaryDetails)
          Column(
            key: const Key('summary-details'),
            children: [
              _overallRow(overall, overallCount),
              for (final (key, label, icon) in criteria)
                bar(label, icon, summaryCriterion(key)),
            ],
          ),
        const SizedBox(height: 14),
        myReviewCard(),
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

  /// Fotos postadas para a corrida, em grade de 3 por linha. Tocar abre a foto maior.
  /// Minha foto desta corrida (participação concluída com foto), para aparecer mesmo antes da
  /// lista pública carregar ou quando eu não a publiquei no feed.
  Map<String, dynamic>? get _ownPhoto {
    final m = mine;
    if (m == null ||
        m['state'] != 'completed' ||
        m['medalImageReference'] == null) {
      return null;
    }
    return {
      'participationId': m['id'],
      'own': true,
      'author': {'displayName': 'Você', 'username': ''},
    };
  }

  Widget photosTab() {
    final list = photos;
    final own = _ownPhoto;
    // Post escolhido pela equipe: so e mostrado (embed oficial da Meta), nunca copiado.
    final postRef = organizerPostRef(edition?['organizerPostUrl']);
    final organizer = postRef == null
        ? null
        : OrganizerPostCard(
            post: postRef,
            fetcher: widget.oembedFetcher ?? fetchOEmbedHtml,
            embedBuilder: widget.embedBuilder ?? webViewEmbed,
          );
    if (loadingPhotos && list == null && own == null && organizer == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final others = list ?? const <Map<String, dynamic>>[];
    final shown = [
      if (own != null &&
          !others.any((p) => p['participationId'] == own['participationId']))
        own,
      ...others,
    ];
    if (shown.isEmpty) {
      final note = list == null
          ? 'Não foi possível carregar as fotos agora.'
          : 'As fotos desta prova aparecerão aqui.';
      if (organizer == null) {
        return emptyTab(Icons.photo_library_outlined, note);
      }
      return ListView(
        key: const Key('photos-list'),
        padding: const EdgeInsets.all(16),
        children: [
          organizer,
          Text(note, style: TextStyle(color: context.muted)),
        ],
      );
    }
    final total = shown.length - others.length + photoTotal;
    return ListView(
      key: const Key('photos-list'),
      padding: const EdgeInsets.all(16),
      children: [
        ?organizer,
        Row(
          children: [
            Expanded(
              child: Text(
                total == 1
                    ? '1 foto desta prova'
                    : '${thousands(total)} fotos desta prova',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            GridColumnsButton(
              key: const Key('grid-columns-photos'),
              value: photoColumns,
              onChanged: (n) {
                setState(() {
                  photoColumns = n;
                });
                GridColumns.write(_photoColumnsKey, n);
              },
            ),
          ],
        ),
        if (list == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Não foi possível carregar as fotos de outros corredores agora.',
              key: const Key('photos-partial'),
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
          ),
        const SizedBox(height: 6),
        GridView.count(
          key: const Key('photos-grid'),
          padding: EdgeInsets.zero,
          crossAxisCount: photoColumns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [for (final item in shown) _photoTile(item)],
        ),
      ],
    );
  }

  Widget _photoTile(Map<String, dynamic> item) {
    final id = item['participationId'] as String;
    final author = Map<String, dynamic>.from(
      item['author'] as Map? ?? const {},
    );
    Widget image({BoxFit fit = BoxFit.cover}) => SignedPhoto(
      gateway: widget.gateway,
      endpoint: '/participations/${Uri.encodeComponent(id)}/image',
      fallback: ColoredBox(
        color: context.panel,
        child: Icon(Icons.image_outlined, color: context.muted),
      ),
      fit: fit,
    );
    return InkWell(
      key: Key('photo-$id'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: InteractiveViewer(child: image(fit: BoxFit.contain)),
              ),
              ListTile(
                title: Text(
                  (author['displayName'] as String?) ?? 'Corredor +1Pódio',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: (author['username'] as String? ?? '').isEmpty
                    ? null
                    : Text('@${author['username']}'),
                trailing: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Fechar'),
                ),
              ),
            ],
          ),
        ),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: image()),
    );
  }

  Widget participantsTab(Map<String, dynamic> body) {
    final done = participants;
    final signed = registrants;
    if ((loadingParticipants && done == null) ||
        (loadingRegistrants && signed == null)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (done == null && signed == null) {
      return emptyTab(
        Icons.groups_outlined,
        'Não foi possível carregar os participantes agora.',
      );
    }
    if (participantTotal == 0 && registrantTotal == 0) {
      return emptyTab(
        Icons.groups_outlined,
        'Ninguém concluiu nem se inscreveu nesta prova no +1Pódio ainda.\n'
        'Seja a primeira pessoa a registrar.',
      );
    }
    final kmById = {
      for (final d in (body['distances'] as List))
        (d as Map)['id'] as String: (d['kilometers'] as num).toDouble(),
    };
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
    );
    Widget hiddenNote(Key key, int hidden, String one, String many) =>
        hidden <= 0
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              hidden == 1 ? one : '$hidden $many',
              key: key,
              style: TextStyle(color: context.muted),
            ),
          );
    return ListView(
      key: const Key('participants-list'),
      padding: const EdgeInsets.all(20),
      children: [
        if (registrantTotal > 0) ...[
          heading(
            registrantTotal == 1
                ? '1 inscrito nesta prova'
                : '${thousands(registrantTotal)} inscritos nesta prova',
          ),
          for (final item in signed ?? const <Map<String, dynamic>>[])
            _registrantTile(item, kmById),
          hiddenNote(
            const Key('registrants-hidden'),
            registrantTotal - (signed?.length ?? 0),
            '1 inscrito não aparece porque o perfil é privado.',
            'inscritos não aparecem porque os perfis são privados.',
          ),
          const SizedBox(height: 14),
        ],
        if (participantTotal > 0) ...[
          heading(
            participantTotal == 1
                ? '1 corredor concluiu esta prova'
                : '${thousands(participantTotal)} corredores concluíram esta prova',
          ),
          for (final item in done ?? const <Map<String, dynamic>>[])
            _participantTile(item, kmById),
          hiddenNote(
            const Key('participants-hidden'),
            participantTotal - (done?.length ?? 0),
            '1 participante não aparece porque o perfil é privado.',
            'participantes não aparecem porque os perfis são privados.',
          ),
        ],
      ],
    );
  }

  Widget _registrantTile(
    Map<String, dynamic> item,
    Map<String, double> kmById,
  ) {
    final author = Map<String, dynamic>.from(item['author'] as Map);
    final name = (author['displayName'] as String?) ?? 'Corredor +1Pódio';
    final km = kmById[item['distanceId']];
    return Card(
      key: Key('registrant-${author['id']}'),
      child: ListTile(
        leading: ProfileAvatar(gateway: widget.gateway, profile: author),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          '@${author['username'] ?? ''}${km == null ? '' : '\n${distanceLabel(km)}'}',
        ),
        isThreeLine: km != null,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PublicProfileScreen(
              gateway: widget.gateway,
              profileId: author['id'] as String,
            ),
          ),
        ),
      ),
    );
  }

  Widget _participantTile(
    Map<String, dynamic> item,
    Map<String, double> kmById,
  ) {
    final author = Map<String, dynamic>.from(item['author'] as Map);
    final name = (author['displayName'] as String?) ?? 'Corredor +1Pódio';
    final km = kmById[item['distanceId']];
    final time = item['timeSeconds'] as num?;
    final place = item['placement'] as num?;
    final details = [
      if (km != null) distanceLabel(km),
      if (time != null) formatDuration(time),
      if (place != null) '${place.toInt()}º lugar',
    ].join(' · ');
    return Card(
      key: Key('participant-${item['participationId']}'),
      child: ListTile(
        leading: ProfileAvatar(gateway: widget.gateway, profile: author),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          '@${author['username'] ?? ''}${details.isEmpty ? '' : '\n$details'}',
        ),
        isThreeLine: details.isNotEmpty,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PublicProfileScreen(
              gateway: widget.gateway,
              profileId: author['id'] as String,
            ),
          ),
        ),
      ),
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
        2,
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
                        photosTab(),
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

  /// Itens e comentário aparecem quando `expanded`; sem `onToggle` fica sempre aberto.
  final bool expanded;
  final VoidCallback? onToggle;
  const MyReviewView({
    super.key,
    required this.review,
    this.onEdit,
    this.expanded = true,
    this.onToggle,
  });

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
            InkWell(
              key: const Key('my-details-toggle'),
              onTap: onToggle,
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Minha avaliação',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (onToggle != null) ...[
                    Text(
                      expanded ? 'Recolher' : 'Expandir',
                      style: const TextStyle(
                        color: runPassOrange,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: runPassOrange,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 6),
            if (expanded)
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
            if (expanded && comment != null && comment.isNotEmpty) ...[
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
    DurationField(controller: time, enabled: !saving),
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
          // Limite menor que o antigo: o recorte devolve a imagem sem reduzir, e o envio aceita até 10 MB.
          maxWidth: 2800,
          maxHeight: 2800,
          imageQuality: 88,
          requestFullMetadata: false,
        );
        final original = await file?.readAsBytes();
        if (original == null || !mounted) return;
        // Ajuste antes de enviar: recortar, ampliar e escolher a proporção. Cancelar não envia nada.
        bytes = await Navigator.of(context).push<List<int>>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => RacePhotoCropScreen(image: original),
          ),
        );
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
          1,
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
        2,
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
      2,
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
