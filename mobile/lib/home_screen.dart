import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'agenda.dart';
import 'catalog_screen.dart';
import 'friends.dart';
import 'identity_gateway.dart';
import 'location_picker.dart';
import 'notifications.dart';
import 'post_card.dart';
import 'runpass_theme.dart';
import 'podium_logo.dart';

export 'post_card.dart' show FeedEntry;

/// Avisa a tela Início quando ela volta a ser a tela visível (por exemplo, ao voltar de um rascunho).
final RouteObserver<ModalRoute<void>> runPassRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// A private draft of the signed-in runner. Drafts are not published, so they never appear
/// in the feed; they are listed on Início so they can be found and continued.
class DraftEntry {
  final Map<String, dynamic> participation;
  final Map<String, dynamic>? edition;
  const DraftEntry(this.participation, this.edition);

  String get title =>
      edition?['name'] as String? ??
      participation['editionId'] as String? ??
      'Corrida';

  /// Corrida que ainda não aconteceu: fica como rascunho até a data da prova.
  bool get upcoming {
    final date = DateTime.tryParse(edition?['date'] as String? ?? '');
    if (date == null) return false;
    final now = DateTime.now();
    return date.isAfter(DateTime(now.year, now.month, now.day));
  }

  String get place =>
      [edition?['city'], edition?['state']].whereType<String>().join('/');
}

Future<List<DraftEntry>> loadDrafts(IdentityGateway gateway) async {
  try {
    final page = await gateway.request(
      '/me/participations',
      query: {'state': 'draft', 'limit': '100'},
    );
    final drafts = (page['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((item) => item['state'] == 'draft')
        .toList();
    final editions = await loadEditions(gateway, [
      for (final d in drafts) d['editionId'] as String,
    ]);
    return [for (final d in drafts) DraftEntry(d, editions[d['editionId']])];
  } on Exception {
    return const [];
  }
}

enum FeedFilter {
  all('Todos', Icons.public_rounded),
  friends('Amigos', Icons.people_outline),
  network('Seguindo', Icons.hub_outlined),
  city('Minha Cidade', Icons.location_city);

  final String label;
  final IconData icon;
  const FeedFilter(this.label, this.icon);
}

/// Escopo enviado ao servidor para cada filtro: "Todos" traz qualquer publicação visível;
/// "Amigos" só de amigos aceitos (sem as minhas); "Seguindo" só de quem eu sigo (sem as
/// minhas). "Minha Cidade" recorta dentro de "Todos" (feedFilterMatches).
String feedScopeFor(FeedFilter filter) => switch (filter) {
  FeedFilter.friends => 'friends',
  FeedFilter.network => 'network',
  _ => 'all',
};

/// "Minha Cidade": mesma cidade do perfil do usuário (e mesmo estado, quando os dois lados
/// informam um). Comparação sem diferenciar maiúsculas/minúsculas; sem cidade cadastrada no
/// perfil, nunca bate (a tela pede o cadastro antes de aplicar o filtro).
bool _sameCity(Map<String, dynamic>? myProfile, FeedEntry entry) {
  final myCity = (myProfile?['city'] as String?)?.trim().toLowerCase();
  if (myCity == null || myCity.isEmpty) return false;
  final raceCity = (entry.race.edition?['city'] as String? ?? '')
      .trim()
      .toLowerCase();
  if (raceCity.isEmpty || raceCity != myCity) return false;
  final myState = (myProfile?['state'] as String?)?.trim().toLowerCase();
  final raceState = (entry.race.edition?['state'] as String? ?? '')
      .trim()
      .toLowerCase();
  if (myState != null &&
      myState.isNotEmpty &&
      raceState.isNotEmpty &&
      myState != raceState) {
    return false;
  }
  return true;
}

bool feedFilterMatches(
  FeedFilter filter,
  FeedEntry entry,
  Map<String, dynamic>? myProfile,
) => switch (filter) {
  FeedFilter.city => _sameCity(myProfile, entry),
  // Todos, Amigos e Seguindo já chegam filtrados pelo servidor (feedScopeFor).
  FeedFilter.all || FeedFilter.friends || FeedFilter.network => true,
};

/// Raio de cidades vizinhas de "Minha Cidade", em km — valor comum de "perto de você" em
/// redes sociais. Só entra em jogo quando não há nenhuma publicação da mesma cidade.
const nearbyCityRadiusKm = 50.0;

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Dentro do raio de "Minha Cidade": exige coordenada salva nos dois lados (perfil do usuário
/// e edição da corrida); sem uma delas, nunca bate — só a mesma cidade por nome continua
/// funcionando nesse caso.
bool _withinNearbyRadius(Map<String, dynamic>? myProfile, FeedEntry entry) {
  final myLat = (myProfile?['latitude'] as num?)?.toDouble();
  final myLon = (myProfile?['longitude'] as num?)?.toDouble();
  if (myLat == null || myLon == null) return false;
  final raceLat = (entry.race.edition?['latitude'] as num?)?.toDouble();
  final raceLon = (entry.race.edition?['longitude'] as num?)?.toDouble();
  if (raceLat == null || raceLon == null) return false;
  return _haversineKm(myLat, myLon, raceLat, raceLon) <= nearbyCityRadiusKm;
}

/// "Minha Cidade": publicações da mesma cidade têm prioridade; só quando não há nenhuma é que
/// entram as de cidades vizinhas dentro do raio.
List<FeedEntry> cityScopedEntries(
  List<FeedEntry> all,
  Map<String, dynamic>? myProfile,
) {
  final sameCity = [
    for (final entry in all)
      if (_sameCity(myProfile, entry)) entry,
  ];
  if (sameCity.isNotEmpty) return sameCity;
  return [
    for (final entry in all)
      if (_withinNearbyRadius(myProfile, entry)) entry,
  ];
}

/// Resultado de [loadFeed]: as publicações a mostrar e o perfil do usuário (para o filtro
/// "Minha Cidade" e para saber se falta cadastrar estado/cidade).
typedef FeedLoad = ({List<FeedEntry> items, Map<String, dynamic>? profile});

/// Published posts first come from the API; the runner's own completed races that are not in
/// the feed are added on top in "Todos" (só ali) so a new registration is always visible on
/// Início. A feed that is unavailable leaves only the own races.
Future<FeedLoad> loadFeed(
  IdentityGateway gateway, {
  FeedFilter filter = FeedFilter.all,
}) async {
  Map<String, dynamic>? profile;
  try {
    profile = await gateway.request('/me');
    rememberNavProfile(gateway, profile);
  } on Exception {
    profile = null;
  }
  final myId = profile?['id'] as String?;
  final myName = profile?['displayName'] as String? ?? 'Você';
  final myUser = profile?['username'] as String? ?? '';
  // "Amigos"/"Seguindo" precisam saber se a lista em si está vazia (para a mensagem de
  // convite), não só se não há publicações recentes — por isso buscam friendsCount/
  // followingCount à parte (/me não traz esses números, só /profiles/{id}).
  if (profile != null &&
      myId != null &&
      (filter == FeedFilter.friends || filter == FeedFilter.network)) {
    try {
      final stats = await gateway.request(
        '/profiles/${Uri.encodeComponent(myId)}',
      );
      profile = {...profile, ...stats};
    } on Exception {
      // Sem os números, a mensagem de convite simplesmente não aparece.
    }
  }

  var posts = <Map<String, dynamic>>[];
  try {
    final page = await gateway.request(
      '/feed',
      query: {'limit': '20', 'scope': feedScopeFor(filter)},
    );
    posts = (page['items'] as List? ?? const []).cast<Map<String, dynamic>>();
  } on Exception {
    posts = const [];
  }
  final mine = await loadMyRaces(gateway).catchError((_) => <RaceRecord>[]);
  final editions = await loadEditions(
    gateway,
    [
      for (final post in posts)
        (post['participation'] as Map?)?['editionId'] as String? ?? '',
    ].where((id) => id.isNotEmpty),
  );

  final entries = <FeedEntry>[];
  final posted = <String>{};
  for (final post in posts) {
    final participation = post['participation'] as Map? ?? const {};
    posted.add(participation['id'] as String? ?? '');
    entries.add(
      entryFromPost(post, editions[participation['editionId']], myId),
    );
  }
  // Só em "Todos": garante que uma corrida recém-registrada apareça no Início. Nos outros
  // filtros (Amigos, Seguindo, Minha Cidade) as minhas publicações não entram por aqui.
  final own = filter == FeedFilter.all
      ? [
          for (final race in mine)
            if (!posted.contains(race.participation['id']))
              FeedEntry(
                postId: null,
                author: myName,
                username: myUser,
                title: race.name,
                place: race.place.isEmpty ? null : race.place,
                race: race,
                mine: true,
                authorProfile: profile,
              ),
        ]
      : const <FeedEntry>[];
  return (items: [...own, ...entries], profile: profile);
}

class RunPassHomeScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const RunPassHomeScreen({super.key, required this.gateway});

  @override
  State<RunPassHomeScreen> createState() => _RunPassHomeScreenState();
}

class _RunPassHomeScreenState extends State<RunPassHomeScreen>
    with RouteAware, WidgetsBindingObserver {
  late Future<FeedLoad> feed = loadFeed(widget.gateway);
  late Future<List<DraftEntry>> drafts = loadDrafts(widget.gateway);
  FeedFilter filter = FeedFilter.all;

  Future<void> selectFilter(FeedFilter item) async {
    if (item == FeedFilter.city && !await ensureLocation()) return;
    if (!mounted) return;
    setState(() {
      filter = item;
      feed = loadFeed(widget.gateway, filter: item);
    });
  }

  /// "Minha Cidade" exige estado/cidade no perfil; se faltar, pede uma vez (fica salvo depois,
  /// não pergunta de novo).
  Future<bool> ensureLocation() async {
    Map<String, dynamic>? profile;
    try {
      profile = await widget.gateway.request('/me');
      rememberNavProfile(widget.gateway, profile);
    } on Exception {
      return false;
    }
    if (profile['city'] != null && profile['state'] != null) return true;
    if (!mounted) return false;
    final picked = await pickBrLocation(context);
    if (picked == null || !mounted) return false;
    try {
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': profile['version'],
          ...brLocationPatch(picked.$1, picked.$2, picked.$3, picked.$4),
        },
      );
      return true;
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível salvar sua cidade. Tente de novo.'),
          ),
        );
      }
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ModalRoute<void>) runPassRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    runPassRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void reload() {
    if (!mounted) return;
    setState(() {
      feed = loadFeed(widget.gateway, filter: filter);
      drafts = loadDrafts(widget.gateway);
    });
  }

  @override
  void didPopNext() => reload();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) reload();
  }

  void go(Widget screen) =>
      Navigator.of(context)
          .pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));

  void soon(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> openDraft(DraftEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: entry.participation,
        ),
      ),
    );
    reload();
  }

  Future<void> deleteDraft(DraftEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir rascunho?'),
        content: Text(
          '${entry.title}: o rascunho privado será excluído. Você poderá criar outro nesta edição.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir rascunho'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.gateway.request(
        '/participations/${Uri.encodeComponent(entry.participation['id'] as String)}',
        method: 'DELETE',
        query: {'expectedVersion': '${entry.participation['version']}'},
      );
    } on Exception {
      soon('Não foi possível excluir o rascunho. Tente novamente.');
    }
    reload();
  }

  Widget draftTile(DraftEntry entry) => ListTile(
    key: Key('draft-${entry.participation['id']}'),
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      entry.upcoming ? Icons.event_rounded : Icons.edit_note_rounded,
    ),
    title: Text(entry.title),
    subtitle: Text(
      [
        if (entry.upcoming && entry.edition?['date'] is String)
          displayDate(entry.edition!['date'] as String),
        if (entry.place.isNotEmpty) entry.place,
        entry.participation['distanceId'] as String? ?? '',
      ].where((part) => part.isNotEmpty).join(' · '),
    ),
    trailing: IconButton(
      key: Key('delete-draft-${entry.participation['id']}'),
      tooltip: 'Excluir rascunho',
      icon: const Icon(Icons.delete_outline_rounded),
      onPressed: () => deleteDraft(entry),
    ),
    onTap: () => openDraft(entry),
  );

  Widget draftGroup(
    Key key,
    String title,
    String caption,
    List<DraftEntry> items,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Text(caption),
            for (final entry in items) draftTile(entry),
          ],
        ),
      ),
    );
  }

  Widget draftsSection() => FutureBuilder<List<DraftEntry>>(
    future: drafts,
    builder: (context, snapshot) {
      final items = snapshot.data ?? const <DraftEntry>[];
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          draftGroup(
            const Key('upcoming-races'),
            'Minhas corridas futuras',
            'Ainda não aconteceram: ficam salvas como rascunho até a data da prova.',
            [
              for (final entry in items)
                if (entry.upcoming) entry,
            ],
          ),
          draftGroup(
            const Key('drafts-in-progress'),
            'Rascunhos em andamento',
            'Privados: nada foi publicado.',
            [
              for (final entry in items)
                if (!entry.upcoming) entry,
            ],
          ),
        ],
      );
    },
  );

  Widget welcome() => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: runPassNavy,
      borderRadius: BorderRadius.circular(24),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PodiumLogo(size: 46),
        SizedBox(height: 18),
        Text(
          'Sua próxima história começa na linha de largada.',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 24,
          ),
        ),
      ],
    ),
  );

  /// Cinco atalhos (4 filtros + agenda) que sempre cabem na largura, em iPhone e Android: o espaço é
  /// dividido igualmente; o círculo e o rótulo se ajustam, sem rolagem lateral.
  Widget filters() => LayoutBuilder(
    builder: (context, box) {
      final count = FeedFilter.values.length + 1;
      final slot = box.maxWidth / count;
      final circle = (slot - 10).clamp(44.0, 62.0);
      Widget chip({
        Key? key,
        required IconData icon,
        required String label,
        required bool selected,
        required VoidCallback onTap,
      }) => SizedBox(
        width: slot,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: circle,
                height: circle,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Destaque laranja segue o filtro selecionado.
                  color: selected ? runPassOrange : context.softFill,
                ),
                child: Icon(
                  icon,
                  color: selected ? Colors.white : runPassOrange,
                  size: circle * .48,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: slot - 4,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      return SizedBox(
        height: circle + 34,
        child: Row(
          children: [
            for (final item in FeedFilter.values)
              chip(
                icon: item.icon,
                label: item.label,
                selected: filter == item,
                onTap: () => selectFilter(item),
              ),
            // Atalho para a agenda, no mesmo padrão dos filtros; não é um filtro.
            chip(
              key: const Key('home-agenda-chip'),
              icon: Icons.calendar_month_rounded,
              label: 'Agenda',
              selected: false,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AgendaScreen(gateway: widget.gateway),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  /// Quando "Amigos"/"Seguindo" está vazio por falta de vínculo (não só de publicações
  /// recentes), convida a encontrar pessoas em vez do aviso genérico.
  Widget emptyFilterState(FeedFilter filter, Map<String, dynamic>? myProfile) {
    final friendsCount = (myProfile?['friendsCount'] as num?)?.toInt();
    final followingCount = (myProfile?['followingCount'] as num?)?.toInt();
    final invite = switch (filter) {
      FeedFilter.friends when friendsCount == 0 => 'Você ainda não tem amigos confirmados no MeuPódio. Envie pedidos de amizade para as pessoas que você conhece e acompanhe as corridas delas por aqui.',
      FeedFilter.network when followingCount == 0 => 'Você ainda não está seguindo ninguém. Siga pessoas que você conhece para ver as publicações delas por aqui.',
      _ => null,
    };
    if (invite == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Nenhuma publicação nesta seleção ainda.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(invite, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('find-friends-empty-state'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FriendSearchScreen(gateway: widget.gateway),
              ),
            ),
            icon: const Icon(Icons.person_search_rounded),
            label: Text(
              filter == FeedFilter.network
                  ? 'Encontrar pessoas'
                  : 'Encontrar amigos',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      // Em telas estreitas o logo encolhe em vez de estourar a barra.
      title: const FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: RunPassWordmark(compact: true),
      ),
      actions: [
        IconButton(
          key: const Key('find-friends'),
          visualDensity: VisualDensity.compact,
          tooltip: 'Buscar amigos',
          icon: const Icon(Icons.person_search_rounded),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FriendSearchScreen(gateway: widget.gateway),
            ),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Buscar corridas',
          icon: const Icon(Icons.search_rounded),
          onPressed: () => go(CatalogScreen(gateway: widget.gateway)),
        ),
        NotificationBell(gateway: widget.gateway),
      ],
    ),
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 0),
    body: RefreshIndicator(
      onRefresh: () async {
        final next = loadFeed(widget.gateway, filter: filter);
        setState(() {
          feed = next;
          drafts = loadDrafts(widget.gateway);
        });
        await next;
      },
      child: FutureBuilder<FeedLoad>(
        future: feed,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final all = snapshot.data?.items ?? const <FeedEntry>[];
          final myProfile = snapshot.data?.profile;
          final shown = filter == FeedFilter.city
              ? cityScopedEntries(all, myProfile)
              : [
                  for (final entry in all)
                    if (feedFilterMatches(filter, entry, myProfile)) entry,
                ];
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              filters(),
              const SizedBox(height: 8),
              draftsSection(),
              if (loading)
                const Center(child: CircularProgressIndicator())
              // O convite "sem corridas ainda" só faz sentido em "Todos"; nos outros
              // filtros, uma lista vazia já é coberta por emptyFilterState.
              else if (all.isEmpty && filter == FeedFilter.all) ...[
                welcome(),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => go(CatalogScreen(gateway: widget.gateway)),
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Encontrar corridas'),
                ),
              ] else if (shown.isEmpty)
                emptyFilterState(filter, myProfile)
              else
                for (final entry in shown) ...[
                  PostCard(
                    gateway: widget.gateway,
                    entry: entry,
                    onChanged: reload,
                  ),
                  const SizedBox(height: 14),
                ],
            ],
          );
        },
      ),
    ),
  );
}
