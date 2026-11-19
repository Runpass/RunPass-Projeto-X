import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'agenda.dart';
import 'duration_field.dart';
import 'edition_cards.dart';
import 'city_photos.dart';
import 'friends.dart';
import 'grid_columns.dart';
import 'home_screen.dart';
import 'edition_requests.dart';
import 'identity_gateway.dart';
import 'my_races.dart';
import 'post_preview.dart';
import 'undo_delete.dart';
import 'notifications.dart';
import 'organizer_post.dart';
import 'pending_requests.dart' show loadProvisionalBanner;
import 'profile_photo.dart';
import 'runpass_theme.dart';
import 'tagged_people.dart';

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
/// Pace "5:30" (min:s por km) -> 330. Vazio = nulo; formato inválido ou fora de 1:00 a 60:00 = -1.
int? parsePace(String value) {
  final text = value.trim().replaceAll(RegExp(r'\s*/\s*km$'), '');
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d{1,2}):([0-5]\d)$').firstMatch(text);
  if (match == null) return -1;
  final seconds = int.parse(match[1]!) * 60 + int.parse(match[2]!);
  return seconds >= 60 && seconds <= 3600 ? seconds : -1;
}

/// Pace (segundos por km) calculado pelo tempo ("h:mm:ss") e pela distância em km. Nulo se faltar o tempo ou
/// o km, ou se der fora do que o servidor aceita (de 1:00 a 60:00 por km).
int? paceFromTime(String timeText, double? km) {
  final seconds = parseDuration(timeText);
  if (seconds == null || seconds < 1 || km == null || km <= 0) return null;
  final perKm = (seconds / km).round();
  return perKm >= 60 && perKm <= 3600 ? perKm : null;
}

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
  'BETA_ADMISSION_REQUIRED' =>
    'Sua conta ainda não foi liberada para consultar as corridas.',
  'INVALID_CURSOR' => 'A busca ficou aberta por muito tempo e expirou. Toque em Buscar para começar de novo.',
  'INVALID_INPUT' || 'INVALID_FILTERS' => 'Algum campo está inválido (data, distância ou texto fora do limite). Confira os filtros e tente de novo.',
  'EDITION_NOT_FOUND' =>
    'Esta corrida não está mais no catálogo. Volte à lista e escolha outra.',
  'EDITION_ARCHIVED' => 'Esta edição está arquivada e não aceita novos registros. Escolha outra corrida.',
  'EDITION_CHANGED' => 'O cadastro desta corrida foi atualizado depois que você abriu a tela. Volte à lista e abra a corrida de novo.',
  'INVALID_DISTANCE' => 'Informe uma distância entre 0,1 e 1000 km.',
  'DISTANCE_NOT_ADDABLE' =>
    'Esta corrida já tem distâncias oficiais. Escolha uma delas.',
  'DISTANCE_LIMIT_REACHED' =>
    'Esta corrida já tem o máximo de distâncias informadas por corredores.',
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

/// Perfil da pessoa logada, já conhecido pelo menu (nome e usuário), para a prévia da publicação.
Map<String, dynamic>? navProfileOf(IdentityGateway gateway) =>
    _navProfiles[gateway];

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
      // Trocar de aba sempre zera a pilha: a seta de voltar só existe em telas abertas a partir
      // de outra (ex.: o "+" das medalhas), nunca nas telas principais.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => screen),
        (r) => false,
      );
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
/// Tipo da prova deduzido do nome (só para a arte padrão; não é um dado curado).
enum RaceKind { rua, trilha, kids, noturna }

RaceKind raceKind(String? name) {
  final n = (name ?? '')
      .toLowerCase()
      .replaceAll(RegExp('[áàâã]'), 'a')
      .replaceAll(RegExp('[éê]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll(RegExp('[óôõ]'), 'o')
      .replaceAll('ú', 'u');
  bool has(String pattern) => RegExp(pattern).hasMatch(n);
  if (has(r'\b(kids?|infantil|mirim|crianca)')) return RaceKind.kids;
  if (has(r'\b(trail|trilha|montanha|mountain|cross|serra|ultra)')) {
    return RaceKind.trilha;
  }
  if (has(r'\b(noturna|night|noite|neon|lua)')) return RaceKind.noturna;
  return RaceKind.rua;
}

/// Arte padrão da corrida sem imagem aprovada: não é foto nem logo da prova, só uma identidade visual honesta.
/// Cor e ícone pelo tipo (rua, trilha, kids, noturna) e, em destaque, a maior distância ou a sigla da cidade.
/// A mesma corrida tem sempre a mesma variação de cor.
class RaceArt extends StatelessWidget {
  final Map<String, dynamic> edition;

  /// A distância fica no canto superior esquerdo, na lista e no banner da corrida; o corredor, à direita.
  final bool labelAtLeft;

  /// Foto de cartão postal da cidade: entra no lugar do degradê quando a corrida não tem banner autorizado.
  final CityPhoto? photo;
  const RaceArt({
    super.key,
    required this.edition,
    this.labelAtLeft = false,
    this.photo,
  });

  static const kindPalettes = {
    RaceKind.rua: [
      [runPassNavy, Color(0xff5a2a1c), runPassOrange],
      [Color(0xff3a0f1e), Color(0xff9a2e4d), Color(0xffff9d5c)],
    ],
    RaceKind.trilha: [
      [Color(0xff10321f), Color(0xff2f7d4f), Color(0xffd9b44a)],
      [Color(0xff2b1d0e), Color(0xff6b4a22), Color(0xff8fb35a)],
    ],
    RaceKind.kids: [
      [Color(0xff0f2a43), Color(0xff1d8a8a), Color(0xffffd23f)],
      [Color(0xff3b1d5a), Color(0xffd94f8a), Color(0xffffc857)],
    ],
    RaceKind.noturna: [
      [Color(0xff070b1f), Color(0xff24103f), Color(0xff6a3d9a)],
      [Color(0xff050816), Color(0xff0f2a43), Color(0xff3f6fd8)],
    ],
  };

  static const kindIcons = {
    RaceKind.rua: Icons.directions_run,
    RaceKind.trilha: Icons.terrain,
    RaceKind.kids: Icons.child_care,
    RaceKind.noturna: Icons.nights_stay,
  };

  RaceKind get kind => raceKind(edition['name'] as String?);

  List<Color> get colors {
    final id = '${edition['id'] ?? edition['name'] ?? ''}';
    final seed = id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
    final options = kindPalettes[kind]!;
    return options[seed % options.length];
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

  /// Sem distância: a sigla da cidade (3 letras), para cada corrida não ficar igual às outras.
  String? get label {
    final distance = longest;
    if (distance != null) return distance;
    final city = '${edition['city'] ?? ''}'.trim();
    if (city.isEmpty) return null;
    final letters = city.replaceAll(RegExp(r'[^A-Za-zÀ-ÿ]'), '');
    return letters.isEmpty
        ? null
        : letters
              .substring(0, letters.length < 3 ? letters.length : 3)
              .toUpperCase();
  }

  /// Cidade e estado em caixa alta, para a capa generica ter cara de cartao postal.
  String? get postcardCity {
    final city = '${edition['city'] ?? ''}'.trim();
    if (city.isEmpty) return null;
    final state = '${edition['state'] ?? ''}'.trim();
    return state.isEmpty
        ? city.toUpperCase()
        : '${city.toUpperCase()} · $state';
  }

  /// Local da prova (quando o catalogo tem), embaixo da cidade.
  String? get postcardVenue {
    final venue = '${edition['venue'] ?? ''}'.trim();
    return venue.isEmpty ? null : venue;
  }

  @override
  Widget build(BuildContext context) {
    final text = label;
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
      child: LayoutBuilder(
        builder: (context, box) {
          // Miniatura (lista compacta): a distância é a informação, legível e no centro.
          final small = box.maxWidth < 140;
          return ClipRect(
            child: Stack(
              children: [
                if (photo != null) ...[
                  Positioned.fill(
                    child: Image.asset(
                      photo!.asset,
                      key: const Key('race-art-photo'),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                  // Escurece o pé da foto para o nome da cidade e o local ficarem legíveis.
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black54],
                          stops: [0.45, 1],
                        ),
                      ),
                    ),
                  ),
                ] else
                  Positioned(
                    right: small ? -6 : -14,
                    bottom: small ? -10 : -26,
                    child: Icon(
                      kindIcons[kind],
                      key: Key('race-art-${kind.name}'),
                      size: small ? 56 : 170,
                      color: Colors.white.withValues(alpha: small ? .18 : .13),
                    ),
                  ),
                if (text != null && small && photo == null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          text,
                          key: const Key('race-art-label'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 24,
                            shadows: [
                              Shadow(blurRadius: 6, color: Colors.black38),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                else if (text != null && photo == null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ArtLabelPainter(text, left: labelAtLeft),
                    ),
                  ),
                // Capa generica (nao ha imagem autorizada da prova): no formato de cartao postal, com a
                // cidade e o local, e rotulada como arte do app.
                if (!small) ...[
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (postcardCity != null)
                          Text(
                            postcardCity!,
                            key: const Key('race-art-city'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 20,
                              letterSpacing: 1.5,
                              shadows: [
                                Shadow(blurRadius: 8, color: Colors.black54),
                              ],
                            ),
                          ),
                        if (postcardVenue != null)
                          Text(
                            postcardVenue!,
                            key: const Key('race-art-venue'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .85),
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                              shadows: const [
                                Shadow(blurRadius: 6, color: Colors.black54),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // No canto de baixo: no alto, na tela da corrida, ficava por cima do ícone de compartilhar.
                  Positioned(
                    right: 10,
                    bottom: 8,
                    child: Text(
                      photo != null ? 'foto da cidade' : 'arte do app',
                      key: const Key('race-art-tag'),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .6),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
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
        RaceArt(
          edition: widget.edition,
          labelAtLeft: true,
          photo: widget.edition['imageReference'] == null
              ? cityPhotoFor(widget.edition)
              : null,
        ),
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

/// Valor do filtro de ano que mostra só as corridas dos próximos [upcomingDays] dias (o padrão da lista).
const upcomingFilter = 'next';
const upcomingDays = 20;

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Janela de hoje até daqui a [upcomingDays] dias.
({String from, String to}) upcomingRange([DateTime? now]) {
  final today = now ?? DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  return (
    from: _isoDay(day),
    to: _isoDay(day.add(const Duration(days: upcomingDays))),
  );
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

  const CatalogScreen({super.key, required this.gateway});
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final fields = {
    for (final key in ['q', 'city', 'state']) key: TextEditingController(),
  };
  // Sugestões enquanto digita: corridas cujo nome contém o texto, para escolher uma.
  // Busca por frase livre (rota /editions/search). Com frase, os campos abaixo sao ignorados.
  final items = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> mine = {};
  // Situação da pessoa em cada corrida (desejada ou inscrita): edição -> `wanted` | `registered`.
  Map<String, String> plans = {};
  Map<String, String> activeFilters = {};
  String? nextCursor, error;
  bool loading = false;

  /// A lista mostra só as corridas dos próximos 20 dias; as outras aparecem pela busca por nome.
  bool get upcomingWindow => fields['q']!.text.trim().isEmpty;

  @override
  void initState() {
    super.initState();
    start();
    loadMine();
  }

  /// Primeira carga: se o perfil tem cidade, a lista abre nela (dá para trocar ou limpar em "Estado e cidade").
  Future<void> start() async {
    try {
      final me = await widget.gateway.request('/me');
      final city = (me['city'] as String?)?.trim() ?? '';
      final state = (me['state'] as String?)?.trim() ?? '';
      if (city.isNotEmpty && state.isNotEmpty && mounted) {
        fields['city']!.text = city;
        fields['state']!.text = state;
      }
    } on Exception {
      // Sem perfil ou sem conexão: abre com todas as cidades.
    }
    if (mounted) await load();
  }

  /// Corpo da lista (só lista, com seções por período).
  List<Widget> editionViews() {
    final shown = items;
    // Seções por período (a lista já vem na ordem certa): Hoje, Amanhã, Este fim de semana...
    final out = <Widget>[];
    String? section;
    for (final edition in shown) {
      final period = periodOf('${edition['date']}');
      if (period != section) {
        section = period;
        out.add(
          Padding(
            key: Key('catalog-section-$period'),
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(
              period,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
        );
      }
      out.add(editionCard(edition));
    }
    return out;
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

  /// Cartão compacto: miniatura, quando e onde, nome, distâncias e as ações com rótulo.
  Widget editionCard(Map<String, dynamic> edition) {
    final score = scoreOf(edition);
    return EditionCompactCard(
      gateway: widget.gateway,
      edition: edition,
      rating: score == null
          ? null
          : '★ ${decimalPt(score)} · ${reviewsOf(edition)} avaliações',
      onTap: loading ? null : () => openEdition(edition['id'] as String),
      actions: quickActions(edition),
      trailing: raceLinkButton(edition),
    );
  }

  /// Ações da corrida com rótulo (não só ícone): Quero correr, Inscrito e Já corri. Marcada fica laranja.
  /// Link da prova no cartão: o site oficial; sem ele, a página de inscrição. Sem link, nada aparece.
  Widget? raceLinkButton(Map<String, dynamic> edition) {
    final official = safeHttpsUri(edition['officialUrl']);
    final link = official ?? safeHttpsUri(edition['registrationUrl']);
    if (link == null) return null;
    return IconButton(
      key: Key('card-link-${edition['id']}'),
      tooltip: official != null ? 'Site da corrida' : 'Página de inscrição',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.public_rounded, size: 20),
      onPressed: () async {
        if (!await linkOpener(link) && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Não foi possível abrir o link.')),
          );
        }
      },
    );
  }

  Widget quickActions(Map<String, dynamic> edition) {
    final id = edition['id'] as String;
    final status = edition['status'];
    if (status == 'archived') return const SizedBox.shrink();
    final upcoming = status != 'past';
    Widget action(
      String key,
      IconData icon,
      String label,
      String tooltip,
      bool on,
      VoidCallback onTap,
    ) => Tooltip(
      message: tooltip,
      child: Material(
        color: on ? runPassOrange : context.panel,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          key: Key('$key-$id'),
          borderRadius: BorderRadius.circular(999),
          onTap: loading ? null : onTap,
          child: ConstrainedBox(
            // Área de toque confortável mesmo com o texto curto.
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: on ? Colors.white : null),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (upcoming) ...[
          action(
            'quick-wanted',
            plans[id] == 'wanted' ? Icons.favorite : Icons.favorite_border,
            'Quero correr',
            plans[id] == 'wanted' ? 'Tirar de Quero correr' : 'Quero correr',
            plans[id] == 'wanted',
            () => togglePlan(edition, 'wanted'),
          ),
          action(
            'quick-registered',
            Icons.how_to_reg_outlined,
            'Inscrito',
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
          mine.containsKey(id) ? 'Meu registro' : 'Já corri',
          mine.containsKey(id) ? 'Ver meu registro' : 'Já corri',
          mine.containsKey(id),
          () => markRan(edition),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Corridas por página: o servidor já devolve na ordem da mais antiga para a mais nova e o "Carregar mais"
  /// pede a próxima página (o cursor é amarrado aos filtros, inclusive o limite).
  static const pageLimit = '20';

  static num? scoreOf(Map<String, dynamic> edition) {
    final raw = (edition['runScore'] as Map?)?['value'];
    return raw is num ? raw : num.tryParse('${raw ?? ''}');
  }

  static int reviewsOf(Map<String, dynamic> edition) =>
      ((edition['runScore'] as Map?)?['reviewCount'] as num?)?.toInt() ?? 0;

  /// Limpa a busca por nome e volta à lista padrão (próximos 20 dias).
  void clearSearch() {
    final hadName = fields['q']!.text.trim().isNotEmpty;
    fields['q']!.clear();
    setState(() {});
    if (hadName) load();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    if (!more) {
      final name = fields['q']!.text.trim();
      // Busca por nome vale para o catálogo todo; sem nome, a lista é da cidade do perfil e dos próximos 20 dias
      // (ou do ano escolhido no calendário).
      activeFilters = name.isNotEmpty
          ? {'q': name}
          : {
              for (final key in ['city', 'state'])
                if (fields[key]!.text.trim().isNotEmpty)
                  key: fields[key]!.text.trim(),
              if (upcomingWindow) ...{
                'dateFrom': upcomingRange().from,
                'dateTo': upcomingRange().to,
              },
            };
      items.clear();
      nextCursor = null;
    }
    setState(() {
      loading = true;
      error = null;
    });
    transient = false;
    try {
      final page = await widget.gateway.request(
        '/editions',
        query: {
          ...activeFilters,
          'limit': pageLimit,
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
      autoRetried = false;
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
      transient = const {
        'SERVICE_UNAVAILABLE',
        'CONCURRENT_RETRY_REQUIRED',
      }.contains(issue.code);
    } on Exception {
      if (mounted) error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
      transient = true;
    } finally {
      if (mounted) setState(() => loading = false);
    }
    // Falha passageira (serviço sobrecarregado ou rede): a tela tenta de novo sozinha uma vez, em vez de deixar o
    // erro parado até a pessoa tocar em "Tentar novamente".
    if (error != null && transient && !autoRetried && mounted) {
      autoRetried = true;
      setState(() => retryPending = true);
      final retryMore = more;
      Future<void>.delayed(autoRetryDelay, () {
        if (!mounted) return;
        retryPending = false;
        if (error != null && !loading) load(more: retryMore);
      });
    }
  }

  /// Uma nova tentativa automática por falha passageira (zera quando uma carga dá certo).
  bool autoRetried = false;
  bool retryPending = false;
  bool transient = false;
  static const autoRetryDelay = Duration(seconds: 3);

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
            if (fields['q']!.text.trim().isNotEmpty)
              'name': fields['q']!.text.trim(),
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const RunPassWordmark(compact: true),
      actions: [
        // Um só "+": incluir uma corrida que não está no catálogo ou acompanhar os pedidos já feitos.
        PopupMenuButton<String>(
          key: const Key('catalog-request-new'),
          tooltip: 'Incluir corrida',
          icon: const Icon(Icons.add_circle_outline),
          enabled: !loading,
          onSelected: (value) =>
              value == 'mine' ? openMyRequests() : requestRace(),
          itemBuilder: (_) => const [
            PopupMenuItem(
              key: Key('catalog-request-new-item'),
              value: 'new',
              child: ListTile(
                leading: Icon(Icons.add_location_alt_outlined),
                title: Text('Incluir uma corrida'),
              ),
            ),
            PopupMenuItem(
              key: Key('catalog-request-mine'),
              value: 'mine',
              child: ListTile(
                leading: Icon(Icons.assignment_outlined),
                title: Text('Minhas solicitações'),
              ),
            ),
          ],
        ),
        IconButton(
          key: const Key('catalog-agenda'),
          visualDensity: VisualDensity.compact,
          // Marcador (não calendário): o calendário da lista é o filtro de data.
          tooltip: 'Minha agenda (Quero correr e Inscrito)',
          icon: const Icon(Icons.bookmarks_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AgendaScreen(gateway: widget.gateway),
            ),
          ),
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
          // Busca por nome sempre à vista, sem lupa. Se não achar a corrida, aparece o cadastro manual.
          TextField(
            key: const Key('catalog-name-search'),
            controller: fields['q'],
            maxLength: 160,
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
              hintText: 'Nome da corrida',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (fields['q']!.text.isNotEmpty)
                    IconButton(
                      key: const Key('catalog-search-clear'),
                      tooltip: 'Limpar a busca',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: clearSearch,
                    ),
                  IconButton(
                    key: const Key('catalog-name-search-go'),
                    tooltip: 'Buscar',
                    icon: const Icon(Icons.arrow_forward_rounded),
                    onPressed: loading ? null : load,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Mesmo espaço (12) entre "Minhas solicitações", o público e o ano.
          // Falha passageira com nova tentativa automática em curso: espera em silêncio, sem mensagem.
          if (error != null && retryPending)
            const Center(child: CircularProgressIndicator())
          else if (error != null) ...[
            Text(error!, key: const Key('catalog-error')),
            TextButton(
              onPressed: loading ? null : () => load(more: nextCursor != null),
              child: const Text('Tentar novamente'),
            ),
          ],
          const SizedBox(height: 8),
          if (loading) const Center(child: CircularProgressIndicator()),
          // Ao abrir (lista dos próximos 20 dias) sem nenhuma corrida: uma orientação discreta, para a tela
          // não ficar em branco. Não é erro nem "nada encontrado": só aponta a busca pelo nome.
          if (!loading &&
              error == null &&
              items.isEmpty &&
              nextCursor == null &&
              upcomingWindow)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                'Sem corridas nos próximos dias por aqui.\nBusque pelo nome no campo acima.',
                key: const Key('catalog-opening-hint'),
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted),
              ),
            ),
          if (!loading && error == null && items.isEmpty && !upcomingWindow)
            Text(
              nextCursor == null
                  ? 'Nenhuma corrida encontrada com esses filtros.'
                  : 'Nenhuma corrida nesta página. Continue a busca.',
            ),
          if (!loading &&
              error == null &&
              items.isEmpty &&
              nextCursor == null &&
              !upcomingWindow)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('catalog-request-empty'),
                onPressed: requestRace,
                child: const Text(
                  'Não encontrou? Cadastrar a corrida manualmente',
                ),
              ),
            ),
          ...editionViews(),
          if (nextCursor != null)
            TextButton(
              key: const Key('catalog-show-more'),
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

  /// Carrega o meu banner sugerido ainda sem decisão. Trocável nos testes (o link assinado não roda lá).
  final Future<List<int>?> Function(IdentityGateway gateway, String editionId)
  provisionalBannerLoader;
  const EditionScreen({
    super.key,
    required this.gateway,
    required this.editionId,
    this.bannerSelector,
    this.oembedFetcher,
    this.embedBuilder,
    this.provisionalBannerLoader = loadProvisionalBanner,
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
  final peopleReviewsKey = GlobalKey();
  bool sendingBanner = false;
  // Detalhes (itens avaliados) da avaliação geral e da minha: recolher e expandir.
  bool showSummaryDetails = true, showMyDetails = true;
  Map<String, dynamic>? mine;
  Map<String, dynamic>? plan;
  bool savingPlan = false;
  String? bannerUrl, bannerCredit;
  List<int>? provisionalBanner;
  // Comentários da corrida (qualquer pessoa da beta comenta; independe de participação).
  final comments = <Map<String, dynamic>>[];
  String? commentsCursor, commentsError;
  bool loadingComments = false, sendingComment = false;
  final commentField = TextEditingController();
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
  void dispose() {
    commentField.dispose();
    super.dispose();
  }

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
      if (mounted) {
        edition = result;
        // Corrida com uma distância só (é o caso das cadastradas à mão): já vem escolhida, e dá para
        // marcar "Já corri" e cadastrar a participação sem passos extras.
        final distances = result['distances'] as List? ?? const [];
        if (selectedDistance == null &&
            distances.length == 1 &&
            (distances.first as Map)['id'] is String) {
          selectedDistance = (distances.first as Map)['id'] as String;
        }
      }
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (mounted && edition != null) {
      loadReviews();
      loadComments();
      loadBanner();
      loadProvisional();
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
  /// Meu banner sugerido, ainda sem decisão: provisório e só meu.
  Future<void> loadProvisional() async {
    final bytes = await widget.provisionalBannerLoader(
      widget.gateway,
      widget.editionId,
    );
    if (mounted && bytes != null) setState(() => provisionalBanner = bytes);
  }

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

  /// Fotos de postagem publicadas por quem concluiu a corrida (só as fotos próprias das
  /// publicações públicas; nunca a foto da medalha nem a arte padrão do catálogo).
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
        // Vale também para a corrida que já aconteceu: é nela que se chega por "Já corri" na lista.
        if (mine == null && !archived && selectedDistance == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Escolha uma distância para registrar que você já correu.',
              key: const Key('pick-distance-hint'),
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
      final path = '/editions/${Uri.encodeComponent(widget.editionId)}/reviews';
      var page = await widget.gateway.request(
        path,
        query: {'limit': '50', 'distanceId': ?selectedDistance},
      );
      // A nota da prova soma todas as distâncias: se a distância escolhida ainda não tem
      // avaliações, mostra as da prova toda em vez de itens vazios.
      final first = page['summary'];
      if (selectedDistance != null &&
          first is Map &&
          (first['reviewCount'] as num? ?? 0) == 0) {
        page = await widget.gateway.request(path, query: {'limit': '50'});
      }
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
          Positioned.fill(
            child: RaceArt(
              edition: body,
              labelAtLeft: true,
              photo: body['imageReference'] == null ? cityPhotoFor(body) : null,
            ),
          ),
          if (bannerUrl != null)
            Positioned.fill(
              child: Image.network(
                bannerUrl!,
                key: const Key('hero-image'),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (bannerUrl == null && provisionalBanner != null)
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0x66000000),
                  BlendMode.darken,
                ),
                child: Image.memory(
                  Uint8List.fromList(provisionalBanner!),
                  key: const Key('hero-provisional'),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (bannerUrl != null || provisionalBanner != null)
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
                      // Corrida que já aconteceu não entra em "Quero correr" (só sai, se já estava).
                      if (body['status'] != 'past' || wanted)
                        IconButton(
                          key: const Key('hero-wanted'),
                          tooltip: wanted
                              ? 'Tirar de Quero correr'
                              : 'Quero correr',
                          color: Colors.white,
                          icon: Icon(
                            wanted ? Icons.favorite : Icons.favorite_border,
                          ),
                          onPressed: savingPlan
                              ? null
                              : () => setPlan('wanted'),
                        ),
                      // Site da corrida em todas as corridas: o oficial, quando cadastrado; senão uma busca na internet.
                      IconButton(
                        key: const Key('hero-site'),
                        tooltip: safeHttpsUri(body['officialUrl']) != null
                            ? 'Site da corrida'
                            : 'Buscar o site da corrida',
                        color: Colors.white,
                        icon: const Icon(Icons.public_rounded),
                        onPressed: () => openLink(
                          safeHttpsUri(body['officialUrl']) ??
                              Uri.https('www.google.com', '/search', {
                                'q':
                                    '${body['name']} ${body['city'] ?? ''} site oficial',
                              }),
                        ),
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
                if (bannerUrl == null && provisionalBanner != null)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: Colors.white70,
                        ),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Seu banner · em análise pela equipe (só você vê)',
                            key: Key('hero-provisional-note'),
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
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

  /// Corrida que veio sem distância: a pessoa informa o km ao se inscrever e ele passa a valer para a corrida.
  Future<void> addDistance() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Qual a distância?'),
        content: TextField(
          key: const Key('add-distance-field'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Distância em km',
            hintText: 'Ex.: 10',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('add-distance-confirm'),
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('Informar'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    try {
      final result = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/distances',
        method: 'POST',
        body: {'kilometers': text.replaceAll(',', '.')},
      );
      if (!mounted) return;
      setState(() {
        edition = result;
        error = null;
        final list = (result['distances'] as List? ?? const []).cast<Map>();
        final km = double.tryParse(text.replaceAll(',', '.'));
        for (final d in list) {
          if (km != null && ((d['kilometers'] as num) - km).abs() < 0.0001) {
            selectedDistance = d['id'] as String;
          }
        }
      });
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

  Widget distanceSelector(Map<String, dynamic> body) {
    final archived = body['status'] == 'archived';
    final distances = body['distances'] as List;
    if (distances.isEmpty && !archived) {
      return OutlinedButton.icon(
        key: const Key('add-distance'),
        onPressed: addDistance,
        icon: const Icon(Icons.straighten),
        label: const Text('Informar a distância desta corrida'),
      );
    }
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: archived ? context.panelStrong : context.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final distance in distances)
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
      // Minha avaliação e meu comentário logo abaixo da média geral (resumo), para quem já concluiu a corrida.
      if (mine?['state'] == 'completed' && myReview != null) ...[
        const SizedBox(height: 12),
        MyReviewView(
          key: const Key('about-my-review'),
          review: myReview!,
          showItems: false,
        ),
      ],
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

  /// Toque na nota geral: abre a lista completa das avaliações e comentários das pessoas.
  void showPeopleReviews() {
    setState(() => showAllReviews = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = peopleReviewsKey.currentContext;
      if (target != null && mounted) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

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

  Widget scoreCard(Map<String, dynamic> body, {VoidCallback? onTap}) {
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
    return InkWell(
      key: const Key('score-card-tap'),
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: IntrinsicHeight(
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
                            style: TextStyle(
                              fontSize: 13,
                              color: context.muted,
                            ),
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
                const ProfileAvatar(radius: 20),
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

  /// Comentários da corrida, mais recentes primeiro (qualquer pessoa da beta lê e comenta).
  Future<void> loadComments({bool more = false}) async {
    if (loadingComments) return;
    setState(() {
      loadingComments = true;
      commentsError = null;
      if (!more) {
        comments.clear();
        commentsCursor = null;
      }
    });
    try {
      final page = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/comments',
        query: {
          'limit': '20',
          if (more && commentsCursor != null) 'cursor': commentsCursor!,
        },
      );
      if (!mounted) return;
      comments.addAll(
        (page['items'] as List? ?? const []).cast<Map<String, dynamic>>(),
      );
      commentsCursor = page['nextCursor'] as String?;
    } on IdentityIssue catch (issue) {
      if (mounted) commentsError = catalogError(issue);
    } on Exception {
      if (mounted) {
        commentsError = 'Não foi possível carregar os comentários agora.';
      }
    } finally {
      if (mounted) setState(() => loadingComments = false);
    }
  }

  Future<void> sendComment() async {
    final text = commentField.text.trim();
    if (text.isEmpty || sendingComment) return;
    setState(() {
      sendingComment = true;
      commentsError = null;
    });
    try {
      final made = await widget.gateway.request(
        '/editions/${Uri.encodeComponent(widget.editionId)}/comments',
        method: 'POST',
        body: {'text': text},
      );
      if (!mounted) return;
      commentField.clear();
      setState(() => comments.insert(0, made));
    } on IdentityIssue catch (issue) {
      if (mounted) {
        commentsError = issue.code == 'COMMENT_LIMIT_REACHED'
            ? 'Você já fez o máximo de comentários nesta corrida. Apague um para escrever outro.'
            : issue.code == 'EDITION_ARCHIVED'
            ? 'Esta corrida está arquivada e não recebe novos comentários.'
            : catalogError(issue);
      }
    } on Exception {
      if (mounted) {
        commentsError = 'Não foi possível enviar agora. Verifique a internet e tente de novo.';
      }
    } finally {
      if (mounted) setState(() => sendingComment = false);
    }
  }

  Future<void> deleteComment(Map<String, dynamic> comment) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Apagar comentário?'),
        content: const Text('O comentário deixa de aparecer para todos.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('edition-comment-delete-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final index = comments.indexWhere((c) => c['id'] == comment['id']);
    try {
      // Some na hora, com "Desfazer"; o DELETE só vai ao servidor depois da janela.
      await deleteWithUndo(
        context,
        id: comment['id'] as String,
        message: 'Comentário apagado.',
        hide: () => setState(
          () => comments.removeWhere((c) => c['id'] == comment['id']),
        ),
        restore: () {
          if (mounted) {
            setState(
              () => comments.insert(
                index < 0 ? 0 : index.clamp(0, comments.length),
                comment,
              ),
            );
          }
        },
        perform: () => widget.gateway.request(
          '/edition-comments/${Uri.encodeComponent(comment['id'] as String)}',
          method: 'DELETE',
        ),
      );
    } on Exception {
      if (mounted) {
        setState(() {
          commentsError = 'Não foi possível apagar agora. Tente de novo.';
          if (!comments.any((c) => c['id'] == comment['id'])) {
            comments.insert(
              index < 0 ? 0 : index.clamp(0, comments.length),
              comment,
            );
          }
        });
      }
    }
  }

  /// Comentários da corrida: caixa para escrever e a lista (qualquer pessoa da beta comenta, com ou sem participação).
  List<Widget> commentsSection() => [
    const SizedBox(height: 18),
    Text(
      'Comentários da corrida',
      key: const Key('edition-comments-title'),
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
    ),
    const SizedBox(height: 8),
    TextField(
      key: const Key('edition-comment-field'),
      controller: commentField,
      maxLength: 1000,
      minLines: 1,
      maxLines: 4,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: 'Comente sobre esta corrida',
        hintText: 'Percurso, organização, dicas para quem vai correr…',
        suffixIcon: IconButton(
          key: const Key('edition-comment-send'),
          tooltip: 'Enviar comentário',
          icon: sendingComment
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_rounded),
          onPressed: sendingComment ? null : sendComment,
        ),
      ),
    ),
    if (commentsError != null)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(commentsError!, key: const Key('edition-comments-error')),
      ),
    const SizedBox(height: 8),
    if (loadingComments && comments.isEmpty)
      const Center(child: CircularProgressIndicator())
    else if (comments.isEmpty && commentsError == null)
      Text(
        'Ainda não há comentários nesta corrida. Seja a primeira pessoa!',
        key: const Key('edition-comments-empty'),
        style: TextStyle(color: context.muted),
      ),
    for (final comment in comments)
      Card(
        key: Key('edition-comment-${comment['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ProfileAvatar(radius: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            (comment['author'] as Map?)?['displayName']
                                    as String? ??
                                'Corredor RunPass',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (DateTime.tryParse('${comment['createdAt']}') !=
                            null) ...[
                          const SizedBox(width: 8),
                          Text(
                            timeAgo(DateTime.parse('${comment['createdAt']}')),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${comment['text']}'),
                  ],
                ),
              ),
              if (comment['mine'] == true)
                IconButton(
                  key: Key('edition-comment-delete-${comment['id']}'),
                  tooltip: 'Apagar meu comentário',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => deleteComment(comment),
                ),
            ],
          ),
        ),
      ),
    if (commentsCursor != null)
      TextButton(
        key: const Key('edition-comments-more'),
        onPressed: loadingComments ? null : () => loadComments(more: true),
        child: const Text('Ver mais comentários'),
      ),
  ];

  Widget reviewsTab(Map<String, dynamic> body) {
    final loaded = reviews;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        scoreCard(body, onTap: showPeopleReviews),
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
            key: peopleReviewsKey,
            children: [
              Expanded(
                child: Text(
                  'O que os corredores estão dizendo (${loaded.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
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
        ...commentsSection(),
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
  /// Minha foto de POSTAGEM desta corrida (publicada, com foto própria), para aparecer antes da lista
  /// pública carregar. A foto da medalha nunca entra aqui: a aba mostra o que os corredores postaram.
  Map<String, dynamic>? get _ownPhoto {
    final m = mine;
    if (m == null ||
        m['state'] != 'completed' ||
        m['publishToFeed'] != true ||
        (m['postImageReference'] == null && m['hasPostImage'] != true)) {
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
      endpoint: '/participations/${Uri.encodeComponent(id)}/post-image',
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
                        fontSize: 14,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                      unselectedLabelColor: context.onSurfaceText,
                      // Quatro abas em telas estreitas: sem a folga lateral padrão os nomes cabem inteiros.
                      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
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

  /// Sem os itens: só a nota média e o comentário (resumo, como na aba Sobre).
  final bool showItems;
  const MyReviewView({
    super.key,
    required this.review,
    this.onEdit,
    this.expanded = true,
    this.onToggle,
    this.showItems = true,
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
            if (!showItems && ratings.values.whereType<num>().isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Stars(
                      ratings.values.whereType<num>().reduce((a, b) => a + b) /
                          ratings.values.whereType<num>().length,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      decimalPt(
                        ratings.values.whereType<num>().reduce(
                              (a, b) => a + b,
                            ) /
                            ratings.values.whereType<num>().length,
                      ),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            if (expanded && showItems)
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
            // O comentário fica sempre à vista (mesmo com os itens recolhidos).
            if (comment != null && comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('“$comment”', key: const Key('my-comment')),
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
/// Atalho para a avaliação: a pessoa escolhe UMA nota (1 a 5) e ela vale para os 8 critérios; depois ajusta o que
/// quiser. A nota é sempre escolhida por ela (nunca um padrão), para a avaliação continuar sendo dela.
class SameRatingPicker extends StatelessWidget {
  final ValueChanged<int> onPick;
  const SameRatingPicker({super.key, required this.onPick});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Dar a mesma nota para todos os critérios:',
        style: TextStyle(color: context.muted),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        children: [
          for (var n = 1; n <= 5; n++)
            ActionChip(
              key: Key('same-rating-$n'),
              avatar: const Icon(
                Icons.star_rounded,
                size: 18,
                color: runPassGold,
              ),
              label: Text('$n'),
              onPressed: () => onPick(n),
            ),
        ],
      ),
      const SizedBox(height: 8),
    ],
  );
}

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

/// Foto atual da publicação (link curto e assinado), para ajustar o tamanho. Nulo se não der para baixar.
Future<List<int>?> loadPostPhotoBytes(
  IdentityGateway gateway,
  String participationId,
) async {
  try {
    final link = await gateway.request(
      '/participations/${Uri.encodeComponent(participationId)}/post-image',
    );
    return await fetchImageBytes(link['url'] as String);
  } on Exception {
    return null;
  }
}

/// Abre o recorte da foto da corrida/medalha e devolve os bytes ajustados (nulo se cancelar).
Future<List<int>?> cropRacePhoto(BuildContext context, List<int> photo) =>
    Navigator.of(context).push<List<int>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RacePhotoCropScreen(image: Uint8List.fromList(photo)),
      ),
    );

/// Foto da PUBLICAÇÃO: abre inteira; recortar (com os tamanhos) é opcional.
Future<List<int>?> cropPostPhoto(BuildContext context, List<int> photo) =>
    Navigator.of(context).push<List<int>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PhotoZoomScreen(image: Uint8List.fromList(photo)),
      ),
    );

/// Formulário do rascunho guardado ao sair da tela (por id do rascunho), para voltar de onde parou.
/// Os testes limpam entre um e outro.
final Map<String, Map<String, dynamic>> draftFormCache = {};

/// O formulário do rascunho (notas, comentário, publicar, texto, pessoas marcadas) também é guardado NO APARELHO,
/// para não se perder se o app for fechado. O servidor só guarda tempo, colocação, peito e a foto da medalha.
const _draftFormPrefix = 'draft-form-';

Future<void> persistDraftForm(String id, Map<String, dynamic> form) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_draftFormPrefix$id', jsonEncode(form));
  } on Object {
    // Sem onde guardar: o rascunho segue valendo só enquanto o app estiver aberto.
  }
}

Future<Map<String, dynamic>?> readDraftForm(String id) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_draftFormPrefix$id');
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on Object {
    return null;
  }
}

Future<void> forgetDraftForm(String id) async {
  draftFormCache.remove(id);
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_draftFormPrefix$id');
  } on Object {
    // Nada a apagar.
  }
}

class ParticipationDraftScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> initial;
  final PhotoSelector? photoSelector;

  /// Seleção da foto da publicação no feed (outra foto, separada da medalha). Nos testes troca-se; sem ela, usa a galeria.
  final PhotoSelector? postPhotoSelector;

  /// Aberta a partir da minha publicação no feed: a edição ajusta a foto da PUBLICAÇÃO (não a da medalha).
  final bool fromPost;

  /// Aberta pelo toque na medalha em Medalhas: mostra as opções para ajustar a MEDALHA (foto, modelo, legenda, dados),
  /// no mesmo formato da edição da publicação, sem mexer no post.
  final bool medalMode;

  /// Baixa uma imagem pelo link assinado (foto da medalha para usar no post). Trocável nos testes.
  final ImageBytesFetcher medalPhotoFetcher;

  /// Baixa a foto atual da publicação para ajustar o tamanho, e abre o recorte. Trocáveis nos testes.
  final Future<List<int>?> Function(
    IdentityGateway gateway,
    String participationId,
  )
  postPhotoLoader;
  final Future<List<int>?> Function(BuildContext context, List<int> photo)
  postPhotoCropper;

  /// Foto já escolhida (ex.: a da medalha, vinda de "Adicionar medalha"): é enviada ao abrir o rascunho.
  final List<int>? initialPhoto;

  /// Ajuste (recorte) da foto inicial antes do envio; nulo se a pessoa desistir. Trocável nos testes.
  final Future<List<int>?> Function(BuildContext context, List<int> photo)
  initialPhotoCropper;
  const ParticipationDraftScreen({
    super.key,
    required this.gateway,
    required this.initial,
    this.photoSelector,
    this.postPhotoSelector,
    this.fromPost = false,
    this.medalMode = false,
    this.medalPhotoFetcher = fetchImageBytes,
    this.postPhotoLoader = loadPostPhotoBytes,
    this.postPhotoCropper = cropPostPhoto,
    this.initialPhoto,
    this.initialPhotoCropper = cropRacePhoto,
  });

  @override
  State<ParticipationDraftScreen> createState() =>
      _ParticipationDraftScreenState();
}

class _ParticipationDraftScreenState extends State<ParticipationDraftScreen> {
  late Map<String, dynamic> draft;
  late final TextEditingController time, pace, placement, bib;
  late final TextEditingController comment;
  String? message;
  bool saving = false, uploading = false;
  String? imageReference, pendingUploadId;
  // Foto da publicação no feed: outra foto, separada da medalha.
  String? postImageReference;
  List<Map<String, dynamic>> tagged = [];
  bool uploadingPost = false;
  final postText = TextEditingController();
  late final legend = TextEditingController(
    text: draft['medalDescription'] as String? ?? '',
  );
  bool declaredCompleted = false, publishToFeed = false;
  DateTime? editionDate;
  String? editionName; // nome da corrida, mostrado embaixo da foto
  Map<String, dynamic>? review;

  /// Concluída sem avaliação (REVIEW_NOT_FOUND): dá para avaliar agora na própria tela.
  bool noReview = false;
  List<Map<String, dynamic>> distances = const [];
  String? distanceId;
  // Mantem a foto validada e a avaliacao quando a pessoa volta para esta tela.
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

  /// Nenhuma nota dada: a avaliação é opcional, e a participação pode concluir para avaliar depois.
  bool get ratingsEmpty => ratings.values.every((v) => v == 0);

  /// A avaliação vale tudo ou nada: as 8 notas ou nenhuma.
  bool get ratingsValid => ratingsComplete || ratingsEmpty;

  /// Tem foto de publicação: o rascunho traz a referência; a publicação do Feed só diz que existe.
  bool get hasPostPhoto =>
      draft['postImageReference'] != null || draft['hasPostImage'] == true;

  @override
  void initState() {
    super.initState();
    draft = Map<String, dynamic>.from(widget.initial);
    postText.text = draft['postText'] as String? ?? '';
    tagged = [
      for (final person in (draft['taggedProfiles'] as List? ?? const []))
        Map<String, dynamic>.from(person as Map),
    ];
    distanceId = draft['distanceId'] as String?;
    final seconds = draft['timeSeconds'];
    time = TextEditingController(
      text: seconds is num ? formatDuration(seconds.toInt()) : '',
    );
    final paceSeconds = draft['paceSecondsPerKm'];
    pace = TextEditingController(
      text: paceSeconds is num
          ? formatPace(paceSeconds).replaceAll('/km', '')
          : '',
    );
    placement = TextEditingController(
      text: draft['placement']?.toString() ?? '',
    );
    bib = TextEditingController(text: draft['bibNumber'] as String? ?? '');
    time.addListener(() {
      recomputePace();
      if (mounted) setState(() {});
    });
    comment = TextEditingController();
    final saved = draftFormCache[draft['id']];
    if (saved != null && draft['state'] == 'draft') {
      applySavedForm(saved);
    } else if (draft['state'] == 'draft' && draft['id'] is String) {
      // App reaberto: o que foi guardado no aparelho volta.
      readDraftForm(draft['id'] as String).then((form) {
        if (form != null && mounted) setState(() => applySavedForm(form));
      });
    }
    // Rascunho que já guardou a foto da medalha no servidor: ela volta sem pedir de novo.
    if (draft['state'] == 'draft' &&
        imageReference == null &&
        draft['medalImageReference'] is String) {
      imageReference = draft['medalImageReference'] as String;
    }
    loadEditionDate();
    if (draft['state'] == 'completed') loadReview();
    if (widget.initialPhoto != null &&
        draft['state'] == 'draft' &&
        imageReference == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => sendInitialPhoto());
    }
  }

  /// Nome da corrida: tocar abre as informações da corrida (a mesma tela do catálogo).
  Widget raceNameLink() => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: InkWell(
      key: const Key('race-name-open'),
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        final id = draft['editionId'] as String?;
        if (id == null) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                EditionScreen(gateway: widget.gateway, editionId: id),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                editionName!,
                key: const Key('race-name-under-photo'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.open_in_new, size: 16, color: context.muted),
          ],
        ),
      ),
    ),
  );

  /// Devolve ao formulário o que foi guardado (na memória ou no aparelho).
  void applySavedForm(Map<String, dynamic> saved) {
    imageReference =
        saved['imageReference'] as String? ??
        draft['medalImageReference'] as String?;
    declaredCompleted = saved['declaredCompleted'] == true;
    publishToFeed = saved['publishToFeed'] == true;
    postImageReference = saved['postImageReference'] as String?;
    postText.text = saved['postText'] as String? ?? '';
    comment.text = saved['comment'] as String? ?? '';
    final savedRatings = saved['ratings'];
    if (savedRatings is Map) {
      for (final e in savedRatings.entries) {
        if (ratings.containsKey(e.key) && e.value is num) {
          ratings[e.key as String] = (e.value as num).toInt();
        }
      }
    }
    final people = saved['tagged'];
    if (people is List) {
      tagged = [
        for (final p in people)
          if (p is Map) Map<String, dynamic>.from(p),
      ];
    }
  }

  /// O formulário atual, como é guardado (memória e aparelho).
  Map<String, dynamic> formSnapshot() => {
    'imageReference': imageReference,
    'declaredCompleted': declaredCompleted,
    'publishToFeed': publishToFeed,
    'postImageReference': postImageReference,
    'postText': postText.text,
    'comment': comment.text,
    'ratings': Map<String, int>.from(ratings),
    'tagged': tagged,
  };

  Future<void> loadReview() async {
    final id = draft['id'];
    if (id is! String) return;
    try {
      final result = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}/review',
      );
      if (mounted) {
        setState(() {
          review = result;
          // Preenche o formulário de avaliação desta tela com o que já foi enviado.
          final saved = (result['ratings'] as Map?) ?? const {};
          for (final key in ratings.keys.toList()) {
            final value = saved[key];
            if (value is num) ratings[key] = value.toInt();
          }
          comment.text = result['comment'] as String? ?? '';
          noReview = false;
        });
      }
    } on IdentityIssue catch (issue) {
      // Concluída sem avaliação: a pessoa pode avaliar agora (PUT com expectedVersion 0).
      if (mounted) {
        setState(() {
          review = null;
          noReview = issue.code == 'REVIEW_NOT_FOUND';
        });
      }
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
          editionName = edition['name'] as String?;
          recomputePace();
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
    if (draft['state'] == 'draft' && !discarded) {
      final snapshot = formSnapshot();
      draftFormCache[draft['id'] as String] = snapshot;
      persistDraftForm(draft['id'] as String, snapshot);
    } else if (draft['id'] is String) {
      forgetDraftForm(draft['id'] as String);
    }
    time.dispose();
    pace.dispose();
    placement.dispose();
    bib.dispose();
    comment.dispose();
    postText.dispose();
    legend.dispose();
    super.dispose();
  }

  /// Km da distância escolhida (ou da única da corrida); nulo enquanto não se sabe.
  double? get paceKm {
    if (distances.isEmpty) return null;
    final picked = distances.firstWhere(
      (d) => d['id'] == distanceId,
      orElse: () => distances.length == 1 ? distances.first : const {},
    );
    final km = picked['kilometers'];
    return km is num && km > 0 ? km.toDouble() : null;
  }

  /// O pace vem do tempo e da distância: assim que os dois existem, ele é calculado e não se digita.
  bool get paceIsComputed => paceFromTime(time.text, paceKm) != null;
  bool _paceAuto = false;

  void recomputePace() {
    final value = paceFromTime(time.text, paceKm);
    if (value == null) {
      // Tempo ou distância saiu: o pace que era calculado some junto (o digitado à mão fica).
      if (_paceAuto) {
        pace.clear();
        _paceAuto = false;
      }
      return;
    }
    final text = formatPace(value).replaceAll('/km', '');
    if (pace.text != text) pace.text = text;
    _paceAuto = true;
  }

  int? positive(String value) {
    if (value.trim().isEmpty) return null;
    final parsed = int.tryParse(value);
    return parsed != null && parsed > 0 ? parsed : -1;
  }

  /// Meus dados desta corrida: distância, tempo, colocação e número de peito.
  List<Widget> raceDataFields({String? saveLabel}) => [
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
            : (value) => setState(() {
                distanceId = value;
                recomputePace();
              }),
      ),
    DurationField(controller: time, enabled: !saving),
    TextField(
      key: const Key('pace-field'),
      controller: pace,
      enabled: !saving,
      // Calculado pelo tempo e pela distância: sem digitar. Só se digita se faltar um dos dois.
      readOnly: paceIsComputed,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(
        labelText: paceIsComputed ? 'Pace (calculado)' : 'Pace (opcional)',
        hintText: 'Ex.: 5:30',
        suffixText: 'min/km',
        helperText: paceIsComputed
            ? 'Calculado pelo tempo e pela distância.'
            : 'Com o tempo e a distância, o pace é calculado sozinho.',
      ),
    ),
    // Respiro: a ajuda do pace não encosta no rótulo do campo seguinte.
    const SizedBox(height: 10),
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
    if (saveLabel != null)
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? 'Salvando...' : saveLabel),
      ),
  ];

  /// Grava tempo, colocação, número de peito e distância (PATCH). Ao concluir, vai junto e só se mudou algo.
  /// Devolve se pode seguir (falha de validação ou de rede mostra o motivo e devolve falso).
  Future<bool> saveData({
    bool announce = true,
    bool onlyIfChanged = false,
  }) async {
    final seconds = parseDuration(time.text), place = positive(placement.text);
    final paceSeconds = parsePace(pace.text);
    if (seconds == -1 || place == -1 || bib.text.length > 40) {
      setState(
        () => message = 'O tempo deve ser como 1:30:00 (ou só segundos), a colocação um número inteiro maior que zero e o número de peito ter no máximo 40 caracteres.',
      );
      return false;
    }
    if (paceSeconds == -1) {
      setState(
        () => message =
            'O pace deve ser em minutos e segundos por km, como 5:30.',
      );
      return false;
    }
    final newBib = bib.text.trim().isEmpty ? null : bib.text.trim();
    if (onlyIfChanged &&
        seconds == draft['timeSeconds'] &&
        paceSeconds == draft['paceSecondsPerKm'] &&
        place == draft['placement'] &&
        newBib == draft['bibNumber'] &&
        (distanceId == null || distanceId == draft['distanceId'])) {
      return true;
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
          'paceSecondsPerKm': paceSeconds,
          'placement': place,
          'bibNumber': bib.text.trim().isEmpty ? null : bib.text.trim(),
          if (distanceId != null && distanceId != draft['distanceId'])
            'distanceId': distanceId,
        },
      );
      if (mounted && announce) {
        message = draft['state'] == 'completed'
            ? 'Dados da corrida salvos.'
            : 'Rascunho salvo. Nada foi publicado.';
      }
      return true;
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Fecha a tela depois de salvar, com o aviso na tela de trás (o aviso some junto com esta tela).
  void backWith(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop<Map<String, dynamic>>(draft);
  }

  /// Salvou: vai para a tela de Medalhas, que abre nova e já com o dado atualizado. Aberta a partir de um
  /// post do Feed, volta para a tela anterior (o Feed), e não para Medalhas.
  void toMedals(String text) {
    if (widget.fromPost) return backWith(text);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => MedalCollectionScreen(gateway: widget.gateway),
      ),
      (route) => false,
    );
  }

  /// "Salvar como rascunho": grava no servidor o tempo, a colocação, o peito e a foto da medalha já validada,
  /// e leva para Medalhas. Nada é publicado e a participação não é concluída; o resto (notas, comentário)
  /// fica guardado no aparelho e volta quando o rascunho é aberto de novo.
  Future<void> saveAsDraft() async {
    final saved = await saveData(announce: false);
    if (!saved || !mounted) return;
    final reference = imageReference;
    if (reference != null && reference != draft['medalImageReference']) {
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
      } on IdentityIssue catch (issue) {
        if (mounted) setState(() => message = catalogError(issue));
        return;
      } on Exception {
        if (mounted) {
          setState(
            () => message =
                'Não foi possível salvar o rascunho agora. Tente de novo.',
          );
        }
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    if (!mounted) return;
    // Notas, comentário e o resto do formulário ficam guardados neste aparelho.
    final snapshot = formSnapshot();
    draftFormCache[draft['id'] as String] = snapshot;
    await persistDraftForm(draft['id'] as String, snapshot);
    if (mounted) {
      toMedals(
        'Rascunho salvo. As notas e o comentário ficam neste aparelho. Nada foi publicado.',
      );
    }
  }

  /// A avaliação mudou em relação ao que já foi enviado (notas ou comentário).
  bool get reviewDirty {
    if (noReview) return !ratingsEmpty;
    final current = review;
    final saved = current?['ratings'];
    // Sem uma avaliação enviada para comparar, não há o que regravar.
    if (current == null || saved is! Map || saved.isEmpty) return false;
    final changedRatings = ratings.entries.any((e) => saved[e.key] != e.value);
    final savedComment = (current['comment'] as String?) ?? '';
    return changedRatings || savedComment != comment.text.trim();
  }

  /// "Editar informações da medalha": abre o mesmo editor do lápis em Medalhas e atualiza esta tela.
  Future<void> editMedalInfoNow() async {
    final race = RaceRecord(
      Map<String, dynamic>.from(draft),
      editionName == null ? null : {'name': editionName},
    );
    final updated = await editMedalInfo(context, widget.gateway, race);
    if (updated == null || !mounted) return;
    setState(() {
      draft = {...draft, ...updated};
      photoRevision++;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Informações da medalha salvas.')),
    );
  }

  Future<void> save() async {
    final completed = draft['state'] == 'completed';
    final saved = await saveData(
      announce: !completed,
      onlyIfChanged: completed,
    );
    if (!saved || !mounted || !completed) return;
    // "Salvar dados da corrida" grava também a avaliação, se foi mexida, e leva para Medalhas.
    if (reviewDirty && !await saveReviewInline()) return;
    if (mounted) toMedals('Dados da corrida salvos.');
  }

  /// Avaliação editada aqui mesmo, na tela da medalha (sem abrir outra): grava as 8 notas e o comentário.
  Future<bool> saveReviewInline() async {
    final current = review;
    if ((current == null && !noReview) || !ratingsComplete) {
      setState(
        () => message = 'Dê uma nota de 1 a 5 estrelas em todos os critérios.',
      );
      return false;
    }
    setState(() {
      saving = true;
      message = null;
    });
    try {
      review = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}/review',
        method: 'PUT',
        body: {
          // 0 cria a avaliação de quem concluiu sem avaliar; depois, a versão atual.
          'expectedVersion': current == null ? 0 : current['version'],
          'ratings': Map<String, int>.from(ratings),
          if (comment.text.trim().isNotEmpty) 'comment': comment.text.trim(),
        },
      );
      noReview = false;
      message = 'Avaliação atualizada.';
      return true;
    } on IdentityIssue catch (issue) {
      message = catalogError(issue);
      return false;
    } on Exception {
      message = 'Não foi possível salvar a avaliação agora. Tente de novo.';
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Valida o tipo e envia a foto; a referência só vale depois da validação do servidor.
  Future<void> sendPhoto(List<int> bytes) async {
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
      medalPhotoBytes = bytes;
      pendingUploadId = null;
      message = 'Foto validada e privada. Ainda não foi publicada.';
    } else if (result['state'] == 'failed') {
      throw IdentityIssue(result['reasonCode'] as String? ?? 'INVALID_IMAGE');
    } else {
      pendingUploadId = result['uploadId'] as String;
      message = 'Foto recebida e ainda em processamento.';
    }
  }

  /// Foto que já veio escolhida (medalha): envia ao abrir, mostrando o mesmo andamento de sempre.
  Future<void> sendInitialPhoto() async {
    final bytes = widget.initialPhoto;
    if (bytes == null) return;
    setState(() {
      uploading = true;
      message = null;
    });
    try {
      // Antes de enviar, a pessoa ajusta a foto (recorta, amplia, escolhe a proporção), como na escolha normal.
      final cropped = await widget.initialPhotoCropper(context, bytes);
      if (cropped == null) {
        if (mounted) {
          message = 'Foto não enviada. Toque em Selecionar foto quando quiser anexá-la.';
        }
        return;
      }
      await sendPhoto(cropped);
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'Não foi possível enviar a foto da medalha. Toque em Selecionar foto para tentar de novo.';
      }
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  /// Envia a foto da publicação e devolve a referência validada; nulo (com a mensagem na tela) se não servir,
  /// inclusive quando for a mesma foto da medalha.
  Future<String?> uploadPostBytes(List<int> bytes) async {
    final isJpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    final isPng =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
    if (!isJpeg && !isPng) throw const IdentityIssue('IMAGE_FORMAT_INVALID');
    final result = await widget.gateway.uploadImage(
      bytes,
      isJpeg ? 'image/jpeg' : 'image/png',
    );
    if (result['state'] != 'valid') {
      throw IdentityIssue(result['reasonCode'] as String? ?? 'INVALID_IMAGE');
    }
    final reference = result['imageReference'] as String;
    if (reference == imageReference ||
        reference == draft['medalImageReference']) {
      message = 'Escolha uma foto diferente da medalha para a publicação.';
      return null;
    }
    postPhotoBytes = bytes; // para a prévia antes de publicar
    return reference;
  }

  /// Última foto de publicação enviada nesta tela, usada só na prévia.
  List<int>? postPhotoBytes;

  /// Foto da medalha desta tela (a enviada agora ou a baixada), para poder usá-la também como foto do post.
  List<int>? medalPhotoBytes;

  /// A foto da medalha pode ser a foto do post: é enviada de novo como uma imagem própria da publicação (o servidor
  /// pede que a foto do post seja outra imagem, e depois ela pode ser trocada sem mexer na da medalha).
  Future<void> useMedalPhotoForPost() async {
    var bytes = medalPhotoBytes;
    if (bytes == null) {
      bytes = await loadMedalBytes();
      if (bytes == null) {
        if (mounted) {
          setState(
            () => message = 'Não consegui carregar a foto da medalha. Escolha outra foto para a publicação.',
          );
        }
        return;
      }
      medalPhotoBytes = bytes;
    }
    setState(() {
      uploadingPost = true;
      message = null;
    });
    try {
      final reference = await uploadPostBytes(bytes);
      if (reference != null) {
        postImageReference = reference;
        message = 'A foto da medalha será a foto da publicação. Você pode trocá-la quando quiser.';
      }
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message =
            'Não foi possível usar a foto da medalha agora. Tente de novo.';
      }
    } finally {
      if (mounted) setState(() => uploadingPost = false);
    }
  }

  /// Painel "Publicar no feed" da tela da medalha (medalha concluída que ainda não foi publicada).
  bool publishPanelOpen = false;

  bool get isPublished => draft['publishToFeed'] == true;

  Future<void> openPublishPanel() async {
    setState(() => publishPanelOpen = !publishPanelOpen);
    // A foto da medalha já vem como a do post; a pessoa pode escolher outra.
    if (publishPanelOpen && postImageReference == null && !uploadingPost) {
      await useMedalPhotoForPost();
    }
  }

  /// Publica agora uma medalha concluída que ficou sem publicação: mostra a prévia e envia foto, texto e marcados.
  Future<void> publishNow() async {
    if (postImageReference == null) {
      setState(
        () => message = 'Escolha a foto da publicação ou use a da medalha.',
      );
      return;
    }
    final profile = navProfileOf(widget.gateway);
    final confirmed = await confirmPostPreview(
      context,
      PostPreviewData(
        authorName: (profile?['displayName'] as String?) ?? 'Você',
        username: (profile?['username'] as String?) ?? '',
        raceName: editionName ?? 'Sua corrida',
        text: postText.text,
        tagged: [
          for (final person in tagged)
            if ('${person['username'] ?? ''}'.isNotEmpty)
              '${person['username']}',
        ],
        photo: postPhotoBytes,
      ),
    );
    if (!confirmed || !mounted) return;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}/publish',
        method: 'POST',
        body: {
          'expectedVersion': draft['version'],
          'postImageReference': postImageReference,
          if (postText.text.trim().isNotEmpty) 'postText': postText.text.trim(),
          if (tagged.isNotEmpty)
            'taggedUserIds': [for (final p in tagged) p['id']],
        },
      );
      publishPanelOpen = false;
      photoRevision++;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Publicado no feed.')));
      }
    } on IdentityIssue catch (issue) {
      message = catalogError(issue);
    } on Exception {
      message = 'Não foi possível publicar agora. Tente de novo.';
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Já publicada: abre a mesma tela de edição da publicação (trocar a foto, o texto e as marcações).
  Future<void> editPublication() async {
    final id = draft['id'];
    if (id is! String) return;
    var initial = Map<String, dynamic>.from(draft);
    try {
      final post = await widget.gateway.request(
        '/posts/${Uri.encodeComponent(id)}',
      );
      initial['taggedProfiles'] = (post['tagged'] as List? ?? const []);
    } on Exception {
      if (mounted) {
        setState(
          () =>
              message = 'Não consegui abrir a publicação agora. Tente de novo.',
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: initial,
          fromPost: true,
        ),
      ),
    );
  }

  /// Baixa a foto da medalha já enviada (participação concluída), para usá-la como foto do post.
  Future<List<int>?> loadMedalBytes() async {
    final id = draft['id'];
    if (id is! String) return null;
    try {
      final link = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}/image',
      );
      return await widget.medalPhotoFetcher(link['url'] as String);
    } on Exception {
      return null;
    }
  }

  /// Rascunho excluído: o que estava guardado não deve voltar.
  bool discarded = false;

  /// O que vai aparecer no Feed: quem postou, a corrida, a distância e o tempo, o texto e as pessoas marcadas.
  PostPreviewData postPreview() {
    final profile = navProfileOf(widget.gateway);
    final km = [
      for (final d in distances)
        if (d['id'] == distanceId) (d['kilometers'] as num?),
    ].firstOrNull;
    final seconds = parseDuration(time.text);
    return PostPreviewData(
      authorName: (profile?['displayName'] as String?) ?? 'Você',
      username: (profile?['username'] as String?) ?? '',
      raceName: editionName ?? 'Sua corrida',
      distance: km == null ? null : formatKilometers(km.toDouble()),
      time: seconds is int && seconds > 0 ? formatDuration(seconds) : null,
      pace: paceFromTime(time.text, km?.toDouble()) == null
          ? null
          : formatPace(paceFromTime(time.text, km?.toDouble())!),
      text: postText.text,
      tagged: [
        for (final person in tagged)
          if ('${person['username'] ?? ''}'.isNotEmpty) '${person['username']}',
      ],
      photo: postPhotoBytes,
    );
  }

  /// Grava (PATCH) a foto e/ou o texto da publicação já publicada.
  Future<void> pickTags() async {
    final picked = await pickTaggedPeople(context, widget.gateway, tagged);
    if (picked != null && mounted) setState(() => tagged = picked);
  }

  Widget tagButton({required bool saveNow}) => OutlinedButton.icon(
    key: const Key('tag-people'),
    onPressed: saving || uploadingPost
        ? null
        : () async {
            await pickTags();
            if (saveNow && mounted) {
              await patchPost({
                'taggedUserIds': [for (final p in tagged) p['id']],
              }, 'Marcações salvas.');
            }
          },
    icon: const Icon(Icons.local_offer_outlined),
    label: Text(
      tagged.isEmpty
          ? 'Marcar pessoas'
          : 'Marcados: ${tagged.map((p) => '@${p['username']}').join(', ')}',
    ),
  );

  Future<bool> patchPost(Map<String, dynamic> changes, String done) async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'PATCH',
        body: {'expectedVersion': draft['version'], ...changes},
      );
      forgetPostPhoto(draft['id'] as String);
      photoRevision++;
      message = done;
      return true;
    } on IdentityIssue catch (issue) {
      message = catalogError(issue);
      return false;
    } on Exception {
      message =
          'Não foi possível salvar agora. A publicação anterior foi mantida.';
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Ajusta o TAMANHO (recorte/proporção) da foto já publicada: baixa a atual, abre o recorte e envia a nova.
  Future<void> adjustPostPhoto() async {
    final id = draft['id'] as String;
    setState(() {
      uploadingPost = true;
      message = null;
    });
    try {
      final current = await widget.postPhotoLoader(widget.gateway, id);
      if (current == null) {
        message =
            'Não foi possível abrir a foto da publicação agora. Tente de novo.';
        return;
      }
      if (!mounted) return;
      final cropped = await widget.postPhotoCropper(context, current);
      if (cropped == null) return; // desistiu do ajuste
      final reference = await uploadPostBytes(cropped);
      if (reference == null) return;
      await patchPost({
        'postImageReference': reference,
      }, 'Tamanho da foto da publicação ajustado.');
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'Não foi possível ajustar a foto agora. Tente de novo.';
      }
    } finally {
      if (mounted) setState(() => uploadingPost = false);
    }
  }

  /// Troca a foto da publicação por outra (a da medalha não muda).
  Future<void> replacePostPhoto() async {
    final before = postImageReference;
    postImageReference = null;
    await selectPostPhoto();
    if (!mounted) return;
    final reference = postImageReference;
    postImageReference = before;
    if (reference == null) {
      return; // desistiu ou a foto não serviu: a mensagem já explica
    }
    await patchPost({
      'postImageReference': reference,
    }, 'Foto da publicação trocada.');
  }

  /// Escolhe e envia a foto da PUBLICAÇÃO (outra foto qualquer; não pode ser a da medalha).
  Future<void> selectPostPhoto() async {
    setState(() {
      uploadingPost = true;
      message = null;
    });
    try {
      List<int>? bytes;
      final selector = widget.postPhotoSelector;
      if (selector != null) {
        bytes = await selector();
      } else {
        final file = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 2800,
          maxHeight: 2800,
          imageQuality: 88,
          requestFullMetadata: false,
        );
        final original = await file?.readAsBytes();
        if (original == null || !mounted) return;
        bytes = await Navigator.of(context).push<List<int>>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => PhotoZoomScreen(image: original),
          ),
        );
      }
      if (bytes == null) return;
      final reference = await uploadPostBytes(bytes);
      if (reference == null) return;
      postImageReference = reference;
      message =
          'Foto da publicação validada. Ela é separada da foto da medalha.';
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'O app não conseguiu abrir ou ler a foto escolhida. Tente de novo ou escolha outra.';
      }
    } finally {
      if (mounted) setState(() => uploadingPost = false);
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
      await sendPhoto(bytes);
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
      // A prateleira usa o recorte (display-image): esquece também o link dele.
      forgetMedalDisplayImage(draft['id'] as String);
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
    if (publishToFeed && postImageReference == null) {
      setState(
        () => message = 'Para publicar no feed, escolha a foto da publicação (outra foto, separada da medalha).',
      );
      return;
    }
    if (imageReference == null || !declaredCompleted) {
      setState(
        () => message = 'Para concluir, anexe uma foto validada e marque "Declaro que concluí esta corrida".',
      );
      return;
    }
    if (!ratingsValid) {
      setState(
        () => message = 'Dê nota aos 8 critérios ou deixe todos em branco para avaliar depois.',
      );
      return;
    }
    // Vai publicar no feed: mostra a prévia e só segue se a pessoa confirmar.
    if (publishToFeed &&
        (!await confirmPostPreview(context, postPreview()) || !mounted)) {
      return;
    }
    // Sem "Salvar rascunho": o tempo, a colocação e o peito preenchidos são gravados ao concluir.
    if (!await saveData(announce: false, onlyIfChanged: true) || !mounted) {
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
          // Avaliação opcional: sem notas, conclui sem avaliação (a pessoa avalia depois).
          if (ratingsComplete) 'ratings': ratings,
          'medalImageReference': imageReference,
          'publishToFeed': publishToFeed,
          if (publishToFeed) 'postImageReference': postImageReference,
          if (publishToFeed && postText.text.trim().isNotEmpty)
            'postText': postText.text.trim(),
          if (publishToFeed && tagged.isNotEmpty)
            'taggedUserIds': [for (final p in tagged) p['id']],
          if (ratingsComplete && comment.text.isNotEmpty)
            'comment': comment.text,
        },
      );
      if (mounted) {
        message = 'Participação concluída. Avaliação e medalha foram salvas.';
        // Ao concluir, leva a pessoa para a coleção de medalhas, onde a conquista aparece.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ratingsComplete
                  ? 'Participação concluída. Avaliação e medalha foram salvas.'
                  : 'Participação concluída. Você pode avaliar depois, na tela da medalha.',
            ),
          ),
        );
        // Pilha zerada: a prateleira abre nova e já com a medalha concluída, sem uma tela velha por baixo
        // (ao voltar, ela mostrava a lista de antes) e sem seta de voltar.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => MedalCollectionScreen(
              gateway: widget.gateway,
              justEarned: editionName ?? 'Sua corrida',
            ),
          ),
          (route) => false,
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
    final wasDraft = draft['state'] == 'draft';
    final id = draft['id'] as String;
    final version = draft['version'];
    final gateway = widget.gateway;
    final navigator = Navigator.of(context);
    // Vai embora da tela na hora (ela deixa de existir) e a exclusão só é enviada depois da janela do "Desfazer".
    final messenger = ScaffoldMessenger.of(context);
    final target = MaterialPageRoute<void>(
      builder: (_) => wasDraft
          ? CatalogScreen(gateway: gateway)
          : MedalCollectionScreen(gateway: gateway),
    );
    final deletion = deleteWithUndo(
      context,
      id: id,
      message: wasDraft
          ? 'Rascunho excluído.'
          : 'Participação excluída. Ela já não aparece nas suas medalhas.',
      hide: () {},
      restore: () {
        // Desfeito: nada foi enviado. O rascunho guardado volta e a lista recarrega.
        navigator.pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => wasDraft
                ? CatalogScreen(gateway: gateway)
                : MedalCollectionScreen(gateway: gateway),
          ),
          (route) => route.isFirst,
        );
      },
      perform: () async {
        await gateway.request(
          '/participations/${Uri.encodeComponent(id)}',
          method: 'DELETE',
          query: {'expectedVersion': '$version'},
        );
        forgetDraftForm(id);
      },
    );
    // Volta para a lista de onde a pessoa veio, em vez de ficar numa tela sem saída.
    navigator.pushAndRemoveUntil(target, (route) => route.isFirst);
    try {
      await deletion;
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Não foi possível excluir agora. Verifique a internet e tente de novo; nada foi alterado.',
          ),
        ),
      );
    }
  }

  /// Salva a legenda escrita aqui (vazia ou igual ao nome da corrida volta ao padrão).
  Future<void> saveLegend() async {
    final typed = legend.text.trim();
    final custom = typed.isEmpty || typed == editionName ? null : typed;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      draft = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(draft['id'] as String)}',
        method: 'PATCH',
        body: {'expectedVersion': draft['version'], 'medalDescription': custom},
      );
      forgetMedalDisplayImage(draft['id'] as String);
      photoRevision++;
      message = 'Legenda da medalha salva.';
    } on IdentityIssue catch (issue) {
      message = catalogError(issue);
    } on Exception {
      message = 'Não foi possível salvar a legenda agora. Tente de novo.';
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Opções para ajustar a medalha: o mesmo formato da edição da publicação (foto, texto, "alterar"), só que da medalha.
  Widget medalOptionsView() => Scaffold(
    appBar: AppBar(title: const RunPassWordmark(compact: true)),
    bottomNavigationBar: runPassNavigation(
      context,
      widget.gateway,
      1,
      subScreen: true,
    ),
    body: ListView(
      key: const Key('medal-options'),
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(
          height: 220,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
              color: context.softFill,
              child: MedalPhoto(
                key: ValueKey('medal-photo-$photoRevision-options'),
                gateway: widget.gateway,
                participationId: draft['id'] as String?,
                size: 72,
                useDisplayImage: true,
              ),
            ),
          ),
        ),
        if (editionName != null) raceNameLink(),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('change-medal-photo'),
          onPressed: saving || uploading ? null : changeMedalPhoto,
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(
            uploading ? 'Enviando foto...' : 'Trocar a foto da medalha',
          ),
        ),
        const SizedBox(height: 8),
        // Posição da foto, modelo (forma e cor) e legenda: o mesmo editor do lápis em Medalhas.
        OutlinedButton.icon(
          key: const Key('edit-medal-info'),
          onPressed: saving || uploading ? null : editMedalInfoNow,
          icon: const Icon(Icons.tune_rounded),
          label: const Text('Ajustar foto, modelo e legenda'),
        ),
        const SizedBox(height: 8),
        // Os três botões das opções da medalha seguem o mesmo padrão (contornado, com ícone, largura total).
        OutlinedButton.icon(
          key: const Key('open-race-data'),
          onPressed: saving || uploading
              ? null
              : () async {
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => ParticipationDraftScreen(
                        gateway: widget.gateway,
                        initial: Map<String, dynamic>.from(draft),
                      ),
                    ),
                  );
                },
          icon: const Icon(Icons.edit_note_rounded),
          label: const Text('Alterar dados da corrida e avaliação'),
        ),
        const SizedBox(height: 8),
        // Publicação: quem não publicou ao cadastrar pode publicar agora (com a foto da medalha ou outra);
        // quem já publicou edita a publicação (foto, texto, marcados).
        if (isPublished)
          OutlinedButton.icon(
            key: const Key('edit-publication'),
            onPressed: saving || uploading ? null : editPublication,
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('Editar publicação no feed'),
          )
        else
          OutlinedButton.icon(
            key: const Key('publish-from-medal'),
            onPressed: saving || uploading || uploadingPost
                ? null
                : openPublishPanel,
            icon: const Icon(Icons.campaign_outlined),
            label: Text(
              publishPanelOpen ? 'Fechar publicação' : 'Publicar no feed',
            ),
          ),
        if (!isPublished && publishPanelOpen) ...[
          const SizedBox(height: 8),
          Text(
            postImageReference == null
                ? (uploadingPost
                      ? 'Preparando a foto da publicação...'
                      : 'Escolha a foto da publicação ou use a da medalha.')
                : 'A foto da medalha será a foto da publicação. Você pode trocar por outra.',
            key: const Key('publish-panel-hint'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('select-post-photo'),
            onPressed: saving || uploadingPost ? null : selectPostPhoto,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Escolher outra foto'),
          ),
          const SizedBox(height: 8),
          tagButton(saveNow: false),
          TextField(
            key: const Key('post-text-field'),
            controller: postText,
            maxLength: 500,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Texto da publicação (opcional)',
            ),
          ),
          FilledButton(
            key: const Key('publish-now'),
            onPressed: saving || uploadingPost ? null : publishNow,
            child: Text(saving ? 'Publicando...' : 'Publicar'),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const Key('medal-legend-edit'),
          controller: legend,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: 'Legenda da medalha',
            hintText: editionName,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const Key('save-medal-legend'),
            onPressed: saving ? null : saveLegend,
            child: const Text('Salvar legenda da medalha'),
          ),
        ),
        if (message != null)
          Text(message!, key: const Key('medal-options-message')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (draft['state'] == 'completed' && widget.medalMode) {
      return medalOptionsView();
    }
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
                    key: ValueKey(
                      'medal-photo-$photoRevision-${widget.fromPost}',
                    ),
                    gateway: widget.gateway,
                    participationId: draft['id'] as String?,
                    size: 72,
                    // No topo está a foto da MEDALHA. A da publicação só aparece aqui quando a tela foi aberta a
                    // partir de um post do Feed; a foto do post tem a seção própria mais abaixo.
                    usePostImage: hasPostPhoto && widget.fromPost,
                    fit: hasPostPhoto && widget.fromPost
                        ? BoxFit.contain
                        : BoxFit.cover,
                  ),
                ),
              ),
            ),
            // Nome da corrida logo abaixo da foto.
            if (editionName != null) raceNameLink(),
            const SizedBox(height: 8),
            if (widget.fromPost) ...[
              // Editar a publicação: o tamanho da foto publicada (a medalha se edita em Medalhas).
              if (hasPostPhoto) ...[
                OutlinedButton.icon(
                  key: const Key('adjust-post-photo'),
                  onPressed: saving || uploadingPost ? null : adjustPostPhoto,
                  icon: const Icon(Icons.crop_rounded),
                  label: Text(
                    uploadingPost
                        ? 'Enviando foto...'
                        : 'Ajustar o tamanho da foto da publicação',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                key: const Key('replace-post-photo'),
                onPressed: saving || uploadingPost ? null : replacePostPhoto,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Incluir foto da publicação'),
              ),
              const SizedBox(height: 8),
              tagButton(saveNow: true),
              const SizedBox(height: 8),
              // A medalha (foto, tempo, avaliação) se edita na mesma tela de Medalhas.
              TextButton.icon(
                key: const Key('change-medal'),
                onPressed: saving || uploadingPost
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => ParticipationDraftScreen(
                            gateway: widget.gateway,
                            initial: Map<String, dynamic>.from(draft),
                          ),
                        ),
                      ),
                icon: const Icon(Icons.workspace_premium_outlined),
                label: const Text('Alterar medalha'),
              ),
              TextField(
                key: const Key('post-text-edit'),
                controller: postText,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Texto da publicação',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('save-post-text'),
                  onPressed: saving
                      ? null
                      : () async {
                          final saved = await patchPost({
                            'postText': postText.text.trim().isEmpty
                                ? null
                                : postText.text.trim(),
                          }, 'Texto da publicação salvo.');
                          if (saved && mounted) {
                            backWith('Texto da publicação salvo.');
                          }
                        },
                  child: const Text('Salvar texto da publicação'),
                ),
              ),
            ] else
              OutlinedButton.icon(
                key: const Key('change-medal-photo'),
                onPressed: saving || uploading ? null : changeMedalPhoto,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(
                  uploading ? 'Enviando foto...' : 'Trocar foto da medalha',
                ),
              ),
            if (!widget.fromPost) ...[
              const SizedBox(height: 8),
              // Modelo, posição da foto e legenda da medalha (a mesma tela do lápis em Medalhas).
              OutlinedButton.icon(
                key: const Key('edit-medal-info'),
                onPressed: saving || uploading ? null : editMedalInfoNow,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Editar informações da medalha'),
              ),
            ],
            const SizedBox(height: 12),
            // Sem botão "Salvar visibilidade": cada chave grava ao ser alterada.
            SwitchListTile(
              key: const Key('show-time-switch'),
              value: draft['showTime'] != false,
              onChanged: saving
                  ? null
                  : (value) {
                      setState(() => draft['showTime'] = value);
                      saveVisibility();
                    },
              title: const Text('Exibir meu tempo'),
            ),
            SwitchListTile(
              key: const Key('show-placement-switch'),
              value: draft['showPlacement'] != false,
              onChanged: saving
                  ? null
                  : (value) {
                      setState(() => draft['showPlacement'] = value);
                      saveVisibility();
                    },
              title: const Text('Exibir minha colocação'),
            ),
            const Divider(height: 32),
            const Text(
              'Meus dados desta corrida',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            ...raceDataFields(saveLabel: null),
            if (review != null || noReview) ...[
              const Divider(height: 32),
              const Text(
                'Minha avaliação',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              if (noReview)
                Text(
                  'Você ainda não avaliou esta corrida. Dê nota aos 8 critérios e toque em Salvar dados, ou deixe para depois.',
                  key: const Key('no-review-hint'),
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
              SameRatingPicker(
                onPick: (n) => setState(() {
                  for (final key in ratings.keys.toList()) {
                    ratings[key] = n;
                  }
                }),
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
                key: const Key('review-comment-inline'),
                controller: comment,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Comentário (deixe vazio para remover)',
                ),
              ),
              const SizedBox(height: 8),
            ],
            // Embaixo, só dois botões: salvar (dados e avaliação juntos) e excluir.
            FilledButton(
              key: const Key('save-data'),
              onPressed: saving ? null : save,
              child: Text(saving ? 'Salvando...' : 'Salvar dados da corrida'),
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
          Text(
            upcoming
                ? 'Rascunho criado. Preencha o que quiser e toque em Salvar rascunho.'
                : 'Preencha o que quiser. Os dados são gravados ao concluir ou ao sair.',
            key: const Key('draft-hint'),
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
          // Corrida já realizada: sem "Salvar rascunho"; o tempo, a colocação e o peito seguem junto ao concluir.
          // Corrida futura não se conclui ainda, então ali o rascunho precisa do botão para guardar.
          // Respiro: o rótulo flutuante do primeiro campo não fica por cima do texto acima.
          const SizedBox(height: 14),
          ...raceDataFields(saveLabel: upcoming ? 'Salvar rascunho' : null),
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
            // A foto da medalha já foi escolhida no começo (Medalhas > "+"): com ela anexada, ou ainda sendo
            // enviada, o botão não aparece. Ele só volta se não houver foto (corrida aberta sem medalha) ou o envio falhar.
            if (imageReference == null &&
                !(uploading && widget.initialPhoto != null))
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
          // Ordem da jornada: meus dados -> avaliação -> opção de postar uma foto da corrida -> concluir ou sair.
          if (draft['state'] == 'draft' && !upcoming) ...[
            const Divider(height: 32),
            const Text(
              'Avaliação (opcional)',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              'Dê nota aos 8 critérios ou deixe em branco e avalie depois.',
              key: const Key('rating-optional-hint'),
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            SameRatingPicker(
              onPick: (n) => setState(() {
                for (final key in ratings.keys.toList()) {
                  ratings[key] = n;
                }
              }),
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
              key: const Key('publish-to-feed'),
              value: publishToFeed,
              onChanged: (value) {
                setState(() => publishToFeed = value ?? false);
                // Sem outra foto, a da medalha é a do post (já vem escolhida; dá para trocar).
                if (publishToFeed &&
                    postImageReference == null &&
                    medalPhotoBytes != null &&
                    !uploadingPost) {
                  useMedalPhotoForPost();
                }
              },
              title: const Text('Publicar esta conquista no feed'),
            ),
            if (publishToFeed) ...[
              // A publicação leva outra foto (qualquer uma), separada da foto da medalha.
              OutlinedButton.icon(
                key: const Key('select-post-photo'),
                onPressed: saving || uploadingPost ? null : selectPostPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  uploadingPost
                      ? 'Enviando foto da publicação...'
                      : 'Incluir foto da publicação',
                ),
              ),
              if (postImageReference != null)
                const Text(
                  'Foto da publicação validada. Ela é uma cópia: trocar a foto da publicação não muda a da medalha.',
                  key: Key('post-photo-ok'),
                )
              else
                const Text(
                  'Escolha a foto da publicação ou use a da medalha.',
                  key: Key('post-photo-hint'),
                ),
              if (medalPhotoBytes != null)
                OutlinedButton.icon(
                  key: const Key('use-medal-for-post'),
                  onPressed: saving || uploadingPost
                      ? null
                      : useMedalPhotoForPost,
                  icon: const Icon(Icons.workspace_premium_outlined),
                  label: const Text('Usar a foto da medalha na publicação'),
                ),
              tagButton(saveNow: false),
              const SizedBox(height: 8),
              TextField(
                key: const Key('post-text-field'),
                controller: postText,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Texto da publicação (opcional)',
                ),
              ),
            ],
            if (imageReference == null)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Anexe a foto da medalha (Selecionar foto) para poder concluir.',
                  key: Key('needs-photo-hint'),
                ),
              ),
            if (!ratingsValid)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Dê nota aos 8 critérios ou deixe todos em branco para avaliar depois.',
                  key: Key('ratings-partial-hint'),
                ),
              ),
            FilledButton(
              onPressed:
                  saving ||
                      !ratingsValid ||
                      imageReference == null ||
                      (publishToFeed && postImageReference == null)
                  ? null
                  : complete,
              child: Text(saving ? 'Concluindo...' : 'Concluir participação'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('save-draft'),
              onPressed: saving || uploading ? null : saveAsDraft,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 13),
              ),
              // Sai da jornada guardando o que já foi preenchido; concluir fica para depois.
              child: const Text('Sair e continuar depois'),
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
      // Cópia editável: as notas são mexidas na tela (estrelas e "mesma nota para todos").
      review = {
        ...result,
        'ratings': Map<String, dynamic>.from(
          (result['ratings'] as Map?) ?? const {},
        ),
      };
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
      if (mounted) {
        message = 'Avaliação atualizada.';
        // "Salvar" volta para a tela anterior, com o aviso lá.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Avaliação atualizada.')));
        Navigator.of(context).pop();
      }
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
              SameRatingPicker(
                onPick: saving
                    ? (_) {}
                    : (n) => setState(() {
                        for (final key
                            in (review!['ratings'] as Map).keys.toList()) {
                          (review!['ratings'] as Map)[key] = n;
                        }
                      }),
              ),
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
