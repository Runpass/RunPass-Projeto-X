// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'runpass_theme.dart';

String friendsError(IdentityIssue issue) => switch (issue.code) {
  'QUERY_TOO_SHORT' => 'Digite pelo menos 2 letras do nome ou do usuário.',
  'PROFILE_NOT_FOUND' => 'Esse perfil não existe mais ou está indisponível.',
  'CANNOT_FOLLOW_SELF' => 'Você não pode seguir o próprio perfil.',
  'CANNOT_FRIEND_SELF' =>
    'Você não pode adicionar o próprio perfil como amigo.',
  'FOLLOW_LIMIT_REACHED' =>
    'Você chegou ao limite de pessoas que pode seguir nesta versão.',
  'POST_NOT_FOUND' => 'Essa publicação não está disponível. Ela pode ter sido removida ou o perfil é privado.',
  'INVALID_TOKEN' || 'ACCOUNT_UNAVAILABLE' => 'Sua sessão expirou ou a conta está indisponível. Volte à tela inicial e entre novamente.',
  _ => 'Não foi possível concluir agora. Verifique a internet e tente de novo.',
};

String followLabel(String? state) => switch (state) {
  'active' => 'Seguindo',
  _ => 'Seguir',
};

String friendLabel(String? state) => switch (state) {
  'friends' => 'Remover amigo',
  'pending_out' => 'Solicitado amizade (toque para cancelar)',
  'pending_in' => 'Responder pedido',
  _ => 'Adicionar amigo',
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
      backgroundColor: context.softFill,
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
              trailing: profile['friendState'] == 'friends'
                  ? const Chip(label: Text('Amigo'))
                  : profile['followState'] == 'none'
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
  bool busyFriend = false;

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

  /// Adicionar amigo / cancelar pedido / remover amizade. Um pedido recebido (pending_in) e
  /// resolvido aqui mesmo, aceitando direto (a tela de pedidos cobre o fluxo detalhado).
  Future<void> toggleFriend() async {
    final state = profile?['friendState'] as String? ?? 'none';
    setState(() => busyFriend = true);
    try {
      if (state == 'pending_in') {
        await widget.gateway.request(
          '/me/friend-requests/${Uri.encodeComponent(widget.profileId)}',
          method: 'PUT',
        );
      } else {
        await widget.gateway.request(
          '/profiles/${Uri.encodeComponent(widget.profileId)}/friend',
          method: state == 'none' ? 'PUT' : 'DELETE',
        );
      }
      await load();
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted)
        setState(() => error = friendsError(const IdentityIssue('')));
    } finally {
      if (mounted) setState(() => busyFriend = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final state = p?['followState'] as String? ?? 'none';
    final friendState = p?['friendState'] as String? ?? 'none';
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
                if (p['bannerReference'] != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 7,
                      child: SignedPhoto(
                        key: ValueKey('banner-${p['bannerReference']}'),
                        gateway: widget.gateway,
                        endpoint:
                            '/profiles/${Uri.encodeComponent(widget.profileId)}/banner',
                        fallback: const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
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
                if (state != 'self') ...[
                  OutlinedButton.icon(
                    key: const Key('follow-button'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: busy ? null : toggleFollow,
                    icon: Icon(
                      state == 'active'
                          ? Icons.how_to_reg_rounded
                          : Icons.person_add_alt_1_rounded,
                    ),
                    label: Text(followLabel(state)),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: const Key('friend-button'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: busyFriend ? null : toggleFriend,
                    icon: Icon(
                      friendState == 'friends'
                          ? Icons.how_to_reg_rounded
                          : Icons.group_add_rounded,
                    ),
                    label: Text(friendLabel(friendState)),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, key: const Key('profile-error')),
                ],
                const SizedBox(height: 14),
                // Seguidores/seguindo e as publicações (feed) são sempre públicos; só o resumo
                // de corridas (contagem e lista) fica atrás da amizade quando o perfil é privado.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    if (canView)
                      _count('${p['participationCount'] ?? 0}', 'Corridas'),
                    _count('${p['followersCount'] ?? 0}', 'Seguidores'),
                    _count('${p['followingCount'] ?? 0}', 'Seguindo'),
                  ],
                ),
                const SizedBox(height: 12),
                if (!canView)
                  const Card(
                    child: ListTile(
                      key: Key('private-profile'),
                      leading: Icon(Icons.lock_outline),
                      title: Text('Resumo de corridas privado'),
                      subtitle: Text(
                        'Adicione como amigo. Quando a pessoa aceitar, você vê as corridas e medalhas dela.',
                      ),
                    ),
                  )
                else ...[
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
      Text(label, style: TextStyle(fontSize: 12, color: context.muted)),
    ],
  );
}

/// Pedidos de amizade recebidos, ainda nao respondidos.
class FriendRequestsScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const FriendRequestsScreen({super.key, required this.gateway});

  @override
  State<FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<FriendRequestsScreen> {
  List<Map<String, dynamic>>? items;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final page = await widget.gateway.request('/me/friend-requests');
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
        '/me/friend-requests/${Uri.encodeComponent(id)}',
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
    appBar: AppBar(title: const Text('Pedidos de amizade')),
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
  final input = FocusNode();
  List<Map<String, dynamic>>? comments;
  String? error;
  bool sending = false;

  /// Comentario principal que esta sendo respondido (nulo = comentario novo).
  Map<String, dynamic>? replyingTo;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    text.dispose();
    input.dispose();
    super.dispose();
  }

  String get path => '/posts/${Uri.encodeComponent(widget.postId)}/comments';

  void fail(Object error) {
    if (!mounted) return;
    setState(
      () => this.error = friendsError(
        error is IdentityIssue ? error : const IdentityIssue(''),
      ),
    );
  }

  Future<void> load() async {
    try {
      final page = await widget.gateway.request(path, query: {'limit': '50'});
      if (mounted) {
        setState(() {
          comments = (page['items'] as List).cast<Map<String, dynamic>>();
          error = null;
        });
      }
    } on Exception catch (e) {
      fail(e);
    }
  }

  Future<void> send() async {
    final value = text.text.trim();
    if (value.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      await widget.gateway.request(
        path,
        method: 'POST',
        body: {'text': value, 'parentId': ?replyingTo?['id']},
      );
      text.clear();
      replyingTo = null;
      await load();
    } on Exception catch (e) {
      fail(e);
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
    } on Exception catch (e) {
      fail(e);
    }
    await load();
  }

  /// Curtir e descurtir um comentario (otimista; volta se falhar).
  Future<void> toggleLike(Map<String, dynamic> c) async {
    final was = c['likedByMe'] == true;
    setState(() {
      c['likedByMe'] = !was;
      c['likeCount'] =
          ((c['likeCount'] as num?)?.toInt() ?? 0) + (was ? -1 : 1);
    });
    try {
      await widget.gateway.request(
        '/comments/${Uri.encodeComponent(c['id'] as String)}/like',
        method: was ? 'DELETE' : 'PUT',
      );
    } on Exception {
      if (!mounted) return;
      setState(() {
        c['likedByMe'] = was;
        c['likeCount'] =
            ((c['likeCount'] as num?)?.toInt() ?? 0) + (was ? 1 : -1);
        error = 'Não foi possível atualizar a curtida.';
      });
    }
  }

  void reply(Map<String, dynamic> root) {
    setState(() => replyingTo = root);
    input.requestFocus();
  }

  /// Foto ou nome no comentario: abre o perfil da pessoa (ou o meu).
  Future<void> openProfile(Map author) async {
    final id = author['id'] as String?;
    if (id == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => id == widget.myId
            ? RunnerProfileScreen(gateway: widget.gateway)
            : PublicProfileScreen(
                gateway: widget.gateway,
                profileId: id,
                initial: Map<String, dynamic>.from(author),
              ),
      ),
    );
  }

  Widget commentTile(Map<String, dynamic> c, {Map<String, dynamic>? root}) {
    final author = c['author'] as Map;
    final liked = c['likedByMe'] == true;
    final likes = (c['likeCount'] as num?)?.toInt() ?? 0;
    final canDelete = author['id'] == widget.myId || widget.postIsMine;
    return Padding(
      key: Key('comment-${c['id']}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: Key('comment-author-${c['id']}'),
            onTap: () => openProfile(author),
            borderRadius: BorderRadius.circular(40),
            child: ProfileAvatar(
              radius: root == null ? 18 : 14,
              gateway: widget.gateway,
              profile: author,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => openProfile(author),
                  child: Text(
                    '${author['displayName'] ?? 'Corredor'}'
                    ' · ${timeAgo(DateTime.tryParse(c['createdAt'] as String? ?? '') ?? DateTime.now())}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(c['text'] as String? ?? ''),
                Row(
                  children: [
                    TextButton(
                      key: Key('reply-${c['id']}'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => reply(root ?? c),
                      child: const Text('Responder'),
                    ),
                    if (canDelete)
                      IconButton(
                        key: Key('delete-comment-${c['id']}'),
                        tooltip: 'Apagar comentário',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                        onPressed: () => remove(c['id'] as String),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            children: [
              IconButton(
                key: Key('like-comment-${c['id']}'),
                tooltip: liked ? 'Descurtir' : 'Curtir',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                  size: 20,
                  color: liked ? runPassOrange : null,
                ),
                onPressed: () => toggleLike(c),
              ),
              if (likes > 0)
                Text(
                  '$likes',
                  key: Key('like-count-${c['id']}'),
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ],
      ),
    );
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
              for (final c in comments ?? const <Map<String, dynamic>>[]) ...[
                commentTile(c),
                if ((c['replies'] as List? ?? const []).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 36),
                    child: Column(
                      children: [
                        for (final r
                            in (c['replies'] as List)
                                .cast<Map<String, dynamic>>())
                          commentTile(r, root: c),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        if (replyingTo != null)
          Container(
            key: const Key('replying-to'),
            width: double.infinity,
            color: context.softFill,
            padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Respondendo a ${(replyingTo!['author'] as Map)['displayName'] ?? 'Corredor'}',
                  ),
                ),
                IconButton(
                  key: const Key('cancel-reply'),
                  tooltip: 'Cancelar resposta',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => setState(() => replyingTo = null),
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
                    focusNode: input,
                    maxLength: 1000,
                    decoration: InputDecoration(
                      hintText: replyingTo == null
                          ? 'Escreva um comentário'
                          : 'Escreva sua resposta',
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
              ? 'Suas publicações continuam visíveis para todos. Só quem você aceitar como amigo vê o resumo das suas corridas no seu perfil.'
              : 'Público: qualquer pessoa pode seguir você e ver suas publicações e seu perfil.',
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
