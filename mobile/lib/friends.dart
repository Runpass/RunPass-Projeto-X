// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'runpass_theme.dart';

String friendsError(IdentityIssue issue) => switch (issue.code) {
  'QUERY_TOO_SHORT' => 'Digite pelo menos 2 letras do nome ou do usuário.',
  'PROFILE_NOT_FOUND' => 'Esse perfil não existe mais ou está indisponível.',
  'CANNOT_FOLLOW_SELF' => 'Você não pode seguir o próprio perfil.',
  'FOLLOW_LIMIT_REACHED' =>
    'Você chegou ao limite de pessoas que pode seguir nesta versão.',
  'POST_NOT_FOUND' => 'Essa publicação não está disponível. Ela pode ter sido removida ou o perfil é privado.',
  'INVALID_TOKEN' || 'ACCOUNT_UNAVAILABLE' => 'Sua sessão expirou ou a conta está indisponível. Volte à tela inicial e entre novamente.',
  _ => 'Não foi possível concluir agora. Verifique a internet e tente de novo.',
};

String followLabel(String? state) => switch (state) {
  'active' => 'Seguindo',
  'pending' => 'Solicitado',
  _ => 'Seguir',
};

class ProfileAvatar extends StatelessWidget {
  final double radius;
  final IdentityGateway? gateway;
  final Map? profile;
  const ProfileAvatar({
    super.key,
    this.radius = 22,
    this.gateway,
    this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final id = profile?['id'] as String?;
    final person = Icon(Icons.person, color: runPassOrange, size: radius * 1.1);
    final photo =
        gateway != null && id != null && profile?['photoReference'] != null;
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xffffe4dc),
      child: photo
          ? ClipOval(
              child: SizedBox(
                width: radius * 2,
                height: radius * 2,
                child: SignedPhoto(
                  gateway: gateway!,
                  endpoint: '/profiles/${Uri.encodeComponent(id)}/photo',
                  fallback: Center(child: person),
                ),
              ),
            )
          : person,
    );
  }
}

/// Procurar pessoas por nome ou usuário, para seguir.
class FriendSearchScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const FriendSearchScreen({super.key, required this.gateway});

  @override
  State<FriendSearchScreen> createState() => _FriendSearchScreenState();
}

class _FriendSearchScreenState extends State<FriendSearchScreen> {
  final query = TextEditingController();
  List<Map<String, dynamic>>? results;
  String? error;
  bool loading = false;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> search() async {
    final text = query.text.trim();
    if (text.length < 2) {
      setState(
        () => error = friendsError(const IdentityIssue('QUERY_TOO_SHORT')),
      );
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.gateway.request(
        '/profiles',
        query: {'q': text, 'limit': '30'},
      );
      if (!mounted) return;
      setState(
        () => results = (page['items'] as List).cast<Map<String, dynamic>>(),
      );
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> open(Map<String, dynamic> profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PublicProfileScreen(
          gateway: widget.gateway,
          profileId: profile['id'] as String,
          initial: profile,
        ),
      ),
    );
    if (mounted && results != null) search();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Buscar amigos')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const Key('friend-search-field'),
          controller: query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => search(),
          decoration: InputDecoration(
            labelText: 'Nome ou usuário',
            hintText: 'Ex.: Marina ou marina_runs',
            suffixIcon: IconButton(
              key: const Key('friend-search-button'),
              tooltip: 'Buscar',
              icon: const Icon(Icons.search_rounded),
              onPressed: loading ? null : search,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (error != null) Text(error!, key: const Key('friend-error')),
        if (loading) const Center(child: CircularProgressIndicator()),
        if (!loading && results != null && results!.isEmpty)
          const Text(
            'Ninguém encontrado. Confira a escrita ou tente só o primeiro nome.',
          ),
        for (final profile in results ?? const <Map<String, dynamic>>[])
          Card(
            child: ListTile(
              key: Key('friend-${profile['id']}'),
              leading: ProfileAvatar(gateway: widget.gateway, profile: profile),
              title: Text(profile['displayName'] as String? ?? ''),
              subtitle: Text(
                '@${profile['username']}'
                '${profile['isPrivate'] == true ? ' · perfil privado' : ''}',
              ),
              trailing: profile['followState'] == 'none'
                  ? null
                  : Chip(
                      label: Text(
                        followLabel(profile['followState'] as String?),
                      ),
                    ),
              onTap: () => open(profile),
            ),
          ),
      ],
    ),
  );
}

/// Perfil de outra pessoa: seguir, ver corridas e, se permitido, as medalhas.
class PublicProfileScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String profileId;
  final Map<String, dynamic>? initial;
  const PublicProfileScreen({
    super.key,
    required this.gateway,
    required this.profileId,
    this.initial,
  });

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  Map<String, dynamic>? profile;
  List<RaceRecord> races = const [];
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    profile = widget.initial;
    load();
  }

  Future<void> load() async {
    try {
      final loaded = await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(widget.profileId)}',
      );
      var list = const <RaceRecord>[];
      if (loaded['canView'] == true) {
        final page = await widget.gateway.request(
          '/profiles/${Uri.encodeComponent(widget.profileId)}/participations',
          query: {'limit': '50'},
        );
        final items = (page['items'] as List).cast<Map<String, dynamic>>();
        final editions = await loadEditions(
          widget.gateway,
          [for (final p in items) p['editionId'] as String? ?? '']
              .where((id) => id.isNotEmpty),
        );
        list = [for (final p in items) RaceRecord(p, editions[p['editionId']])];
      }
      if (!mounted) return;
      setState(() {
        profile = loaded;
        races = list;
        error = null;
      });
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    }
  }

  Future<void> toggleFollow() async {
    final state = profile?['followState'] as String? ?? 'none';
    setState(() => busy = true);
    try {
      await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(widget.profileId)}/follow',
        method: state == 'none' ? 'PUT' : 'DELETE',
      );
      await load();
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final state = p?['followState'] as String? ?? 'none';
    final canView = p?['canView'] == true;
    return Scaffold(
      appBar: AppBar(title: Text(p == null ? 'Perfil' : '@${p['username']}')),
      body: p == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(error!, key: const Key('profile-error')),
                    ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    ProfileAvatar(
                      radius: 34,
                      gateway: widget.gateway,
                      profile: p,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p['displayName'] as String? ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                            ),
                          ),
                          Text('@${p['username']}'),
                          if (p['city'] != null) Text(p['city'] as String),
                        ],
                      ),
                    ),
                  ],
                ),
                if (p['bio'] != null) ...[
                  const SizedBox(height: 10),
                  Text(p['bio'] as String),
                ],
                const SizedBox(height: 14),
                if (state != 'self')
                  FilledButton.icon(
                    key: const Key('follow-button'),
                    onPressed: busy ? null : toggleFollow,
                    icon: Icon(
                      state == 'active'
                          ? Icons.check_rounded
                          : state == 'pending'
                          ? Icons.hourglass_empty_rounded
                          : Icons.person_add_alt_1_rounded,
                    ),
                    label: Text(
                      state == 'pending'
                          ? 'Solicitado (toque para cancelar)'
                          : followLabel(state),
                    ),
                  ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, key: const Key('profile-error')),
                ],
                const SizedBox(height: 14),
                if (!canView)
                  const Card(
                    child: ListTile(
                      key: Key('private-profile'),
                      leading: Icon(Icons.lock_outline),
                      title: Text('Este perfil é privado'),
                      subtitle: Text(
                        'Peça para seguir. Quando a pessoa aprovar, você vê as corridas e medalhas dela.',
                      ),
                    ),
                  )
                else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _count('${p['participationCount'] ?? 0}', 'Corridas'),
                      _count('${p['followersCount'] ?? 0}', 'Seguidores'),
                      _count('${p['followingCount'] ?? 0}', 'Seguindo'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (races.isEmpty)
                    const Text(
                      'Ainda não há corridas concluídas para mostrar.',
                    ),
                  for (final race in races)
                    Card(
                      child: ListTile(
                        leading: SizedBox(
                          width: 52,
                          height: 52,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: MedalPhoto(
                              gateway: widget.gateway,
                              participationId:
                                  race.participation['id'] as String?,
                              size: 34,
                            ),
                          ),
                        ),
                        title: Text(race.name),
                        subtitle: Text(
                          [
                            if (race.place.isNotEmpty) race.place,
                            if (race.date != null) displayDate(race.date!),
                            if (race.timeSeconds != null)
                              formatDuration(race.timeSeconds!),
                          ].join(' · '),
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _count(String value, String label) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
      ),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
    ],
  );
}

/// Pedidos pendentes para seguir o meu perfil privado.
class FollowRequestsScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const FollowRequestsScreen({super.key, required this.gateway});

  @override
  State<FollowRequestsScreen> createState() => _FollowRequestsScreenState();
}

class _FollowRequestsScreenState extends State<FollowRequestsScreen> {
  List<Map<String, dynamic>>? items;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final page = await widget.gateway.request('/me/follow-requests');
      if (mounted) {
        setState(() {
          items = (page['items'] as List).cast<Map<String, dynamic>>();
          error = null;
        });
      }
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    }
  }

  Future<void> decide(String id, bool approve) async {
    try {
      await widget.gateway.request(
        '/me/follow-requests/${Uri.encodeComponent(id)}',
        method: approve ? 'PUT' : 'DELETE',
      );
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    }
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pedidos para seguir')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null) Text(error!, key: const Key('requests-error')),
        if (items == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (items != null && items!.isEmpty)
          const Text('Nenhum pedido pendente.', key: Key('no-requests')),
        for (final row in items ?? const <Map<String, dynamic>>[])
          Card(
            child: ListTile(
              leading: ProfileAvatar(
                gateway: widget.gateway,
                profile: row['profile'] as Map,
              ),
              title: Text((row['profile'] as Map)['displayName'] as String),
              subtitle: Text('@${(row['profile'] as Map)['username']}'),
              trailing: Wrap(
                children: [
                  IconButton(
                    key: Key('decline-${(row['profile'] as Map)['id']}'),
                    tooltip: 'Recusar',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () =>
                        decide((row['profile'] as Map)['id'] as String, false),
                  ),
                  IconButton(
                    key: Key('approve-${(row['profile'] as Map)['id']}'),
                    tooltip: 'Aceitar',
                    icon: const Icon(Icons.check_rounded, color: Colors.green),
                    onPressed: () =>
                        decide((row['profile'] as Map)['id'] as String, true),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// Comentários de uma publicação: ler, escrever e apagar o que é meu (ou da minha publicação).
class CommentsScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String postId;
  final String title;
  final String? myId;
  final bool postIsMine;
  const CommentsScreen({
    super.key,
    required this.gateway,
    required this.postId,
    required this.title,
    this.myId,
    this.postIsMine = false,
  });

  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  final text = TextEditingController();
  List<Map<String, dynamic>>? comments;
  String? error;
  bool sending = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  String get path => '/posts/${Uri.encodeComponent(widget.postId)}/comments';

  Future<void> load() async {
    try {
      final page = await widget.gateway.request(path, query: {'limit': '50'});
      if (mounted) {
        setState(() {
          comments = (page['items'] as List).cast<Map<String, dynamic>>();
          error = null;
        });
      }
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    }
  }

  Future<void> send() async {
    final value = text.text.trim();
    if (value.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      await widget.gateway.request(path, method: 'POST', body: {'text': value});
      text.clear();
      await load();
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> remove(String id) async {
    try {
      await widget.gateway.request(
        '/comments/${Uri.encodeComponent(id)}',
        method: 'DELETE',
      );
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    }
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Comentários · ${widget.title}')),
    body: Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (error != null) Text(error!, key: const Key('comments-error')),
              if (comments == null && error == null)
                const Center(child: CircularProgressIndicator()),
              if (comments != null && comments!.isEmpty)
                const Text(
                  'Ainda não há comentários. Seja o primeiro!',
                  key: Key('no-comments'),
                ),
              for (final c in comments ?? const <Map<String, dynamic>>[])
                ListTile(
                  key: Key('comment-${c['id']}'),
                  contentPadding: EdgeInsets.zero,
                  leading: ProfileAvatar(
                    radius: 18,
                    gateway: widget.gateway,
                    profile: c['author'] as Map,
                  ),
                  title: Text(
                    '${(c['author'] as Map)['displayName'] ?? 'Corredor'}'
                    ' · ${timeAgo(DateTime.tryParse(c['createdAt'] as String? ?? '') ?? DateTime.now())}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(c['text'] as String? ?? ''),
                  trailing:
                      (c['author'] as Map)['id'] == widget.myId ||
                          widget.postIsMine
                      ? IconButton(
                          key: Key('delete-comment-${c['id']}'),
                          tooltip: 'Apagar comentário',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => remove(c['id'] as String),
                        )
                      : null,
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('comment-field'),
                    controller: text,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      hintText: 'Escreva um comentário',
                      counterText: '',
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('comment-send'),
                  tooltip: 'Enviar',
                  icon: const Icon(Icons.send_rounded),
                  onPressed: sending ? null : send,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Chave "Perfil privado" do próprio perfil. Público é o padrão.
class PrivacyTile extends StatefulWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> profile;
  const PrivacyTile({super.key, required this.gateway, required this.profile});

  @override
  State<PrivacyTile> createState() => _PrivacyTileState();
}

class _PrivacyTileState extends State<PrivacyTile> {
  late bool isPrivate = widget.profile['isPrivate'] == true;
  late int version = (widget.profile['version'] as num).toInt();
  bool saving = false;
  String? error;

  Future<void> change(bool value) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final saved = await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {'expectedVersion': version, 'isPrivate': value},
      );
      if (mounted) {
        setState(() {
          isPrivate = saved['isPrivate'] == true;
          version = (saved['version'] as num).toInt();
        });
      }
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Não foi possível mudar a privacidade. Tente de novo.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        key: const Key('private-switch'),
        secondary: const Icon(Icons.lock_outline),
        title: const Text('Perfil privado'),
        subtitle: Text(
          isPrivate
              ? 'Só quem você aceitar vê suas corridas, medalhas e comentários.'
              : 'Público: qualquer pessoa pode seguir você e ver suas publicações.',
        ),
        value: isPrivate,
        onChanged: saving ? null : change,
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(error!, key: const Key('privacy-error')),
        ),
    ],
  );
}
