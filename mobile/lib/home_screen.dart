import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'friends.dart';
import 'identity_gateway.dart';
import 'notifications.dart';
import 'post_card.dart';
import 'runpass_theme.dart';

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
  all('Todos', Icons.add),
  friends('Amigos', Icons.people_outline),
  network('Minha rede', Icons.hub_outlined),
  city('São Paulo', Icons.location_city),
  trails('Trilhas', Icons.terrain);

  final String label;
  final IconData icon;
  const FeedFilter(this.label, this.icon);
}

bool feedFilterMatches(FeedFilter filter, FeedEntry entry) => switch (filter) {
  FeedFilter.all => true,
  FeedFilter.network => entry.mine,
  FeedFilter.city =>
    (entry.race.edition?['city'] as String? ?? '').toLowerCase().contains(
      'são paulo',
    ),
  FeedFilter.friends => !entry.mine,
  FeedFilter.trails => false,
};

/// Published posts first come from the API; the runner's own completed races
/// that are not in the feed are added on top so a new registration is always
/// visible on Início. A feed that is unavailable leaves only the own races.
Future<List<FeedEntry>> loadFeed(IdentityGateway gateway) async {
  Map<String, dynamic>? profile;
  try {
    profile = await gateway.request('/me');
  } on Exception {
    profile = null;
  }
  final myId = profile?['id'] as String?;
  final myName = profile?['displayName'] as String? ?? 'Você';
  final myUser = profile?['username'] as String? ?? '';

  var posts = <Map<String, dynamic>>[];
  try {
    final page = await gateway.request('/feed', query: {'limit': '20'});
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
  final own = [
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
  ];
  return [...own, ...entries];
}

class RunPassHomeScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const RunPassHomeScreen({super.key, required this.gateway});

  @override
  State<RunPassHomeScreen> createState() => _RunPassHomeScreenState();
}

class _RunPassHomeScreenState extends State<RunPassHomeScreen>
    with RouteAware, WidgetsBindingObserver {
  late Future<List<FeedEntry>> feed = loadFeed(widget.gateway);
  late Future<List<DraftEntry>> drafts = loadDrafts(widget.gateway);
  FeedFilter filter = FeedFilter.all;

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
      feed = loadFeed(widget.gateway);
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
        Icon(Icons.directions_run_rounded, color: runPassOrange, size: 42),
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

  Widget filters() => SizedBox(
    height: 92,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final item in FeedFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: InkWell(
              onTap: () => setState(() => filter = item),
              borderRadius: BorderRadius.circular(40),
              child: Column(
                children: [
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: item == FeedFilter.all
                          ? runPassOrange
                          : context.softFill,
                      border: Border.all(
                        color: filter == item
                            ? runPassOrange
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: Icon(
                      item.icon,
                      color: item == FeedFilter.all
                          ? Colors.white
                          : runPassOrange,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: filter == item
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const RunPassWordmark(compact: true),
      actions: [
        IconButton(
          key: const Key('find-friends'),
          tooltip: 'Buscar amigos',
          icon: const Icon(Icons.person_search_rounded),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FriendSearchScreen(gateway: widget.gateway),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Buscar corridas',
          icon: const Icon(Icons.search_rounded),
          onPressed: () => go(CatalogScreen(gateway: widget.gateway)),
        ),
        NotificationBell(gateway: widget.gateway),
        const SizedBox(width: 4),
      ],
    ),
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 0),
    body: RefreshIndicator(
      onRefresh: () async {
        final next = loadFeed(widget.gateway);
        setState(() {
          feed = next;
          drafts = loadDrafts(widget.gateway);
        });
        await next;
      },
      child: FutureBuilder<List<FeedEntry>>(
        future: feed,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final all = snapshot.data ?? const <FeedEntry>[];
          final shown = [
            for (final entry in all)
              if (feedFilterMatches(filter, entry)) entry,
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
              else if (all.isEmpty) ...[
                welcome(),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => go(CatalogScreen(gateway: widget.gateway)),
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Encontrar corridas'),
                ),
              ] else if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nenhuma publicação nesta seleção ainda.',
                    textAlign: TextAlign.center,
                  ),
                )
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
