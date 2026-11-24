// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'runpass_theme.dart';
import 'safety.dart';

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

/// Foto de perfil, sempre no formato de medalha (aro dourado e fita); [radius] e o tamanho total.
class ProfileAvatar extends StatelessWidget {
  final double radius;
  final IdentityGateway? gateway;
  final Map? profile;

  /// Sem o cordão: só o círculo dourado (para a foto que fica sobre o banner do perfil).
  final bool ribbon;
  const ProfileAvatar({
    super.key,
    this.radius = 22,
    this.gateway,
    this.profile,
    this.ribbon = true,
  });

  @override
  Widget build(BuildContext context) {
    final inner = MedalAvatar.innerRadius(radius);
    final id = profile?['id'] as String?;
    final person = Icon(Icons.person, color: runPassOrange, size: inner * 1.1);
    final photo =
        gateway != null && id != null && profile?['photoReference'] != null;
    return MedalAvatar(
      radius: radius,
      ribbon: ribbon,
      child: CircleAvatar(
        radius: inner,
        backgroundColor: context.softFill,
        child: photo
            ? ClipOval(
                child: SizedBox(
                  width: inner * 2,
                  height: inner * 2,
                  child: SignedPhoto(
                    gateway: gateway!,
                    endpoint: '/profiles/${Uri.encodeComponent(id)}/photo',
                    fallback: Center(child: person),
                  ),
                ),
              )
            : person,
      ),
    );
  }
}

/// Foto do perfil no formato de medalha: fita no topo (atrás) e aro dourado em volta do [child]. O cordão
/// tem um lado laranja (a cor da marca) e o outro conforme o tema: branco no escuro, azul-marinho no claro.
class MedalAvatar extends StatelessWidget {
  final double radius;
  final Widget child;

  /// Falso: só o aro dourado, sem o cordão em cima.
  final bool ribbon;
  const MedalAvatar({
    super.key,
    required this.radius,
    required this.child,
    this.ribbon = true,
  });

  /// Raio do circulo de dentro (a foto), descontando o aro dourado.
  static double innerRadius(double radius) => radius * 0.87;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final ribbonHeight = radius * (radius < 24 ? 0.7 : 0.9);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Aro dourado, do claro para o escuro na diagonal.
    const ring = [Color(0xFFFFE08A), Color(0xFFD4A017), Color(0xFF9C7412)];
    const rim = Color(0xFFFFF3C4);
    return SizedBox(
      key: const Key('medal-avatar'),
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (ribbon)
            Positioned(
              key: const Key('medal-avatar-ribbon'),
              top: -ribbonHeight * 0.75,
              child: CustomPaint(
                size: Size(radius * 1.15, ribbonHeight),
                painter: _RibbonPainter(
                  // Paleta do app (decisao de produto de 21/11/2026): fundo claro, cordao
                  // escuro (navy) + laranja; fundo escuro, cordao branco + laranja, para o
                  // cordao nao sumir contra o fundo.
                  left: dark ? Colors.white : runPassNavy,
                  right: runPassOrange,
                ),
              ),
            ),
          Container(
            width: size,
            height: size,
            padding: EdgeInsets.all(radius * 0.09),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: ring,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: rim, width: 1.5),
              ),
              child: Center(child: child),
            ),
          ),
        ],
      ),
    );
  }
}

/// O que a pessoa escolheu na foto ampliada do proprio perfil.
enum ProfilePhotoAction { change, remove }

/// Abre a foto do perfil ampliada, no formato de medalha. No proprio perfil ([editable]) oferece
/// alterar e, se houver foto, remover; devolve a escolha (ou null se so olhou).
Future<ProfilePhotoAction?> openProfilePhoto(
  BuildContext context, {
  required IdentityGateway gateway,
  required Map profile,
  bool editable = false,
}) => Navigator.of(context).push<ProfilePhotoAction>(
  PageRouteBuilder(
    opaque: false,
    barrierDismissible: true,
    barrierColor: Colors.black87,
    pageBuilder: (context, _, _) => ProfilePhotoViewer(
      gateway: gateway,
      profile: profile,
      editable: editable,
    ),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween(begin: 0.85, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
        ),
        child: child,
      ),
    ),
  ),
);

class ProfilePhotoViewer extends StatelessWidget {
  final IdentityGateway gateway;
  final Map profile;
  final bool editable;
  const ProfilePhotoViewer({
    super.key,
    required this.gateway,
    required this.profile,
    this.editable = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = profile['photoReference'] != null;
    final size = MediaQuery.sizeOf(context);
    final radius = (size.shortestSide * 0.36).clamp(90.0, 170.0);
    return Scaffold(
      key: const Key('profile-photo-viewer'),
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(onTap: () => Navigator.pop(context)),
            ),
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                key: const Key('profile-photo-close'),
                tooltip: 'Fechar',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: radius * 0.6),
                  ProfileAvatar(
                    radius: radius,
                    gateway: gateway,
                    profile: profile,
                  ),
                  if (editable) ...[
                    const SizedBox(height: 32),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.icon(
                          key: const Key('profile-photo-change'),
                          style: FilledButton.styleFrom(
                            backgroundColor: runPassOrange,
                            // Sem isto o tema estica o botão na largura toda e empurra "Remover foto".
                            minimumSize: const Size(0, 44),
                          ),
                          onPressed: () =>
                              Navigator.pop(context, ProfilePhotoAction.change),
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: Text(
                            hasPhoto ? 'Alterar foto' : 'Adicionar foto',
                          ),
                        ),
                        if (hasPhoto)
                          OutlinedButton.icon(
                            key: const Key('profile-photo-remove'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                            ),
                            onPressed: () => Navigator.pop(
                              context,
                              ProfilePhotoAction.remove,
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remover foto'),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fita da medalha em V, nas cores do app (laranja e azul-marinho).
class _RibbonPainter extends CustomPainter {
  final Color left, right;
  const _RibbonPainter({required this.left, required this.right});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final left = Path()
      ..moveTo(0, 0)
      ..lineTo(w * 0.42, 0)
      ..lineTo(w * 0.62, h)
      ..lineTo(w * 0.2, h)
      ..close();
    final right = Path()
      ..moveTo(w, 0)
      ..lineTo(w * 0.58, 0)
      ..lineTo(w * 0.38, h)
      ..lineTo(w * 0.8, h)
      ..close();
    canvas.drawPath(left, Paint()..color = this.left);
    canvas.drawPath(right, Paint()..color = this.right);
  }

  @override
  bool shouldRepaint(_RibbonPainter oldDelegate) =>
      oldDelegate.left != left || oldDelegate.right != right;
}

/// Últimas sugestões de pessoas de cada sessão: reabrir a busca mostra na hora e atualiza por trás.
final _suggestionCache = Expando<List<Map<String, dynamic>>>();

/// Saiu da conta: as sugestões de quem saiu não aparecem para a próxima pessoa.
void forgetFriendSuggestions(IdentityGateway gateway) =>
    _suggestionCache[gateway] = null;

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
  List<Map<String, dynamic>> suggestions = const [];
  // Sugestoes: loading -> ok | failed (a busca segue valendo em qualquer caso).
  String suggestionsState = 'loading';
  String? suggestionsIssue;
  // Busca enquanto digita: espera uma pausa curta e descarta respostas de buscas antigas.
  Timer? typing;
  int searchSeq = 0;

  @override
  void initState() {
    super.initState();
    final cached = _suggestionCache[widget.gateway];
    if (cached != null) {
      suggestions = cached;
      suggestionsState = 'ok';
    }
    loadSuggestions(quiet: cached != null);
  }

  /// Sugestões já na tela, antes de qualquer busca.
  Future<void> loadSuggestions({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        suggestionsState = 'loading';
        suggestionsIssue = null;
      });
    }
    try {
      final page = await widget.gateway.request(
        '/profiles/suggestions',
        query: {'limit': '12'},
      );
      if (!mounted) return;
      setState(() {
        suggestions = (page['items'] as List).cast<Map<String, dynamic>>();
        suggestionsState = 'ok';
      });
      _suggestionCache[widget.gateway] = suggestions;
    } on IdentityIssue catch (issue) {
      if (quiet) return; // já há sugestões na tela
      if (mounted) {
        setState(() {
          suggestionsState = 'failed';
          suggestionsIssue = issue.code;
        });
      }
    } on Object catch (error) {
      if (quiet) return;
      if (mounted) {
        setState(() {
          suggestionsState = 'failed';
          suggestionsIssue = error.runtimeType.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    typing?.cancel();
    query.dispose();
    super.dispose();
  }

  /// Digitando: com 2 letras ou mais busca sozinho depois de uma pausa curta; apagou tudo, volta às
  /// sugestões.
  void onTyping(String value) {
    typing?.cancel();
    final text = value.trim();
    if (text.isEmpty) {
      searchSeq++;
      setState(() {
        results = null;
        error = null;
        loading = false;
      });
      return;
    }
    if (text.length < 2) return;
    typing = Timer(const Duration(milliseconds: 300), search);
  }

  Future<void> search() async {
    typing?.cancel();
    final text = query.text.trim();
    if (text.length < 2) {
      setState(
        () => error = friendsError(const IdentityIssue('QUERY_TOO_SHORT')),
      );
      return;
    }
    final seq = ++searchSeq;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.gateway.request(
        '/profiles',
        query: {'q': text, 'limit': '30'},
      );
      if (!mounted || seq != searchSeq) return;
      setState(
        () => results = (page['items'] as List).cast<Map<String, dynamic>>(),
      );
    } on IdentityIssue catch (issue) {
      if (mounted && seq == searchSeq) {
        setState(() => error = friendsError(issue));
      }
    } on Exception {
      if (mounted && seq == searchSeq) {
        setState(() => error = friendsError(const IdentityIssue('')));
      }
    } finally {
      if (mounted && seq == searchSeq) setState(() => loading = false);
    }
  }

  /// Por que a pessoa aparece: amigos em comum e se é de perto.
  static String? closeness(Map<String, dynamic> profile) {
    final mutual = profile['mutualFriends'];
    final parts = [
      if (mutual is num && mutual > 0)
        mutual == 1 ? '1 amigo em comum' : '${mutual.toInt()} amigos em comum',
      if (profile['nearby'] == true) 'Perto de você',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
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
          onChanged: onTyping,
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
        // Discreto: a lista anterior continua na tela enquanto a busca nova chega.
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (!loading && results != null && results!.isEmpty)
          const Text(
            'Ninguém encontrado. Confira a escrita ou tente só o primeiro nome.',
          ),
        if (results == null && !loading) ...[
          if (suggestionsState == 'loading')
            const Padding(
              key: Key('friend-suggestions-loading'),
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Buscando sugestões…'),
                ],
              ),
            )
          else if (suggestionsState == 'failed')
            Column(
              key: const Key('friend-suggestions-failed'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // Sem o código interno do erro: ele não diz nada a quem usa o app.
                  'Não foi possível carregar as sugestões agora.',
                ),
                TextButton(
                  key: const Key('friend-suggestions-retry'),
                  onPressed: loadSuggestions,
                  child: const Text('Tentar de novo'),
                ),
              ],
            )
          else if (suggestions.isEmpty)
            const Padding(
              key: Key('friend-suggestions-empty'),
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Sem sugestões por enquanto. Use a busca acima pelo nome ou usuário.',
              ),
            )
          else
            Padding(
              key: const Key('friend-suggestions-title'),
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Sugestões para você',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
        ],
        for (final profile
            in results ??
                (loading ? const <Map<String, dynamic>>[] : suggestions))
          Card(
            // Espaço entre um perfil e outro.
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              key: Key('friend-${profile['id']}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              leading: ProfileAvatar(gateway: widget.gateway, profile: profile),
              title: Text(profile['displayName'] as String? ?? ''),
              subtitle: Text(
                [
                  '@${profile['username']}'
                      '${profile['isPrivate'] == true ? ' · perfil privado' : ''}',
                  ?closeness(profile),
                ].join('\n'),
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

  /// Depois de denunciar e bloquear, o perfil deixa de abrir: volta para a tela anterior.
  Future<void> leaveIfBlocked() async {
    try {
      await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(widget.profileId)}',
      );
    } on IdentityIssue catch (issue) {
      if (issue.code == 'PROFILE_NOT_FOUND' && mounted) {
        Navigator.of(context).pop();
      }
    } on Exception {
      // Segue no perfil.
    }
  }

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
      appBar: AppBar(
        title: Text(p == null ? 'Perfil' : '@${p['username']}'),
        actions: [
          if (p != null && p['followState'] != 'self')
            PopupMenuButton<String>(
              key: const Key('profile-menu'),
              tooltip: 'Mais opções',
              onSelected: (value) async {
                final name = '${p['displayName'] ?? p['username']}';
                if (value == 'report') {
                  final sent = await reportContent(
                    context,
                    widget.gateway,
                    targetType: 'user',
                    targetId: widget.profileId,
                    blockUserId: widget.profileId,
                    blockUserName: name,
                  );
                  if (sent && context.mounted) await leaveIfBlocked();
                } else {
                  final done = await blockPerson(
                    context,
                    widget.gateway,
                    widget.profileId,
                    name,
                  );
                  if (done && context.mounted) Navigator.of(context).pop();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  key: Key('profile-menu-report'),
                  value: 'report',
                  child: Text('Denunciar'),
                ),
                PopupMenuItem(
                  key: Key('profile-menu-block'),
                  value: 'block',
                  child: Text('Bloquear'),
                ),
              ],
            ),
        ],
      ),
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
                    GestureDetector(
                      key: const Key('public-profile-photo'),
                      onTap: () => openProfilePhoto(
                        context,
                        gateway: widget.gateway,
                        profile: p,
                      ),
                      child: ProfileAvatar(
                        radius: 34,
                        gateway: widget.gateway,
                        profile: p,
                      ),
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
                    _count(
                      '${p['friendsCount'] ?? 0}',
                      'Amigos',
                      onTap: () =>
                          openRelationList(RelationListKind.friends, 'Amigos'),
                    ),
                    _count(
                      '${p['followersCount'] ?? 0}',
                      'Seguidores',
                      onTap: () => openRelationList(
                        RelationListKind.followers,
                        'Seguidores',
                      ),
                    ),
                    _count(
                      '${p['followingCount'] ?? 0}',
                      'Seguindo',
                      onTap: () => openRelationList(
                        RelationListKind.following,
                        'Seguindo',
                      ),
                    ),
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

  Widget _count(String value, String label, {VoidCallback? onTap}) {
    final column = Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        Text(label, style: TextStyle(fontSize: 12, color: context.muted)),
      ],
    );
    return onTap == null
        ? column
        : InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: column,
            ),
          );
  }

  void openRelationList(RelationListKind kind, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RelationListScreen(
          gateway: widget.gateway,
          profileId: widget.profileId,
          kind: kind,
          title: title,
          ownList: profile?['followState'] == 'self',
        ),
      ),
    );
  }
}

/// Toque em "amigos"/"seguidores"/"seguindo" (perfil próprio ou de outra pessoa) abre a lista
/// de pessoas, no estilo Instagram: cada linha tem o botão certo para o contexto (amizade na
/// lista de amigos; seguir — com "Seguir de volta" quando é a minha própria lista de
/// seguidores — nas outras duas).
enum RelationListKind { followers, following, friends }

String _compactFriendLabel(String? state) => switch (state) {
  'friends' => 'Amigo',
  'pending_out' => 'Solicitado',
  'pending_in' => 'Responder',
  _ => 'Adicionar',
};

class RelationListScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String profileId;
  final RelationListKind kind;
  final String title;

  /// Se a lista é das próprias relações do usuário logado (não de outra pessoa).
  final bool ownList;
  const RelationListScreen({
    super.key,
    required this.gateway,
    required this.profileId,
    required this.kind,
    required this.title,
    required this.ownList,
  });

  @override
  State<RelationListScreen> createState() => _RelationListScreenState();
}

class _RelationListScreenState extends State<RelationListScreen> {
  List<Map<String, dynamic>>? items;
  String? nextCursor;
  String? error;
  bool loadingMore = false;

  /// A página seguinte falhou: para de pedir sozinho e oferece "Tentar de novo".
  bool moreFailed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Falha numa ação da linha (seguir, adicionar): a lista já está na tela, então o aviso vai embaixo.
  void say(Object issue) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          friendsError(
            issue is IdentityIssue ? issue : const IdentityIssue(''),
          ),
        ),
      ),
    );
  }

  String get _path => switch (widget.kind) {
    RelationListKind.followers => 'followers',
    RelationListKind.following => 'following',
    RelationListKind.friends => 'friends',
  };

  Future<void> load({bool more = false}) async {
    if (more) {
      if (loadingMore || nextCursor == null) return;
      setState(() {
        loadingMore = true;
        moreFailed = false;
      });
    }
    try {
      final page = await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(widget.profileId)}/$_path',
        query: {'limit': '30', if (more) 'cursor': nextCursor!},
      );
      final pageItems = (page['items'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        items = more ? [...(items ?? const []), ...pageItems] : pageItems;
        nextCursor = page['nextCursor'] as String?;
        error = null;
      });
    } on IdentityIssue catch (issue) {
      if (mounted) {
        setState(() {
          error = friendsError(issue);
          moreFailed = more;
        });
      }
    } on Exception {
      if (mounted) {
        setState(() {
          error = friendsError(const IdentityIssue(''));
          moreFailed = more;
        });
      }
    } finally {
      if (more && mounted) setState(() => loadingMore = false);
    }
  }

  Future<void> toggleFollow(Map<String, dynamic> item) async {
    final state = item['followState'] as String? ?? 'none';
    try {
      final result = await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(item['id'] as String)}/follow',
        method: state == 'none' ? 'PUT' : 'DELETE',
      );
      if (mounted) setState(() => item['followState'] = result['state']);
    } on Exception catch (issue) {
      say(issue);
    }
  }

  /// Mesma regra de PublicProfileScreen.toggleFriend: um pedido recebido (pending_in) e aceito
  /// direto aqui.
  Future<void> toggleFriend(Map<String, dynamic> item) async {
    final state = item['friendState'] as String? ?? 'none';
    try {
      final result = state == 'pending_in'
          ? await widget.gateway.request(
              '/me/friend-requests/${Uri.encodeComponent(item['id'] as String)}',
              method: 'PUT',
            )
          : await widget.gateway.request(
              '/profiles/${Uri.encodeComponent(item['id'] as String)}/friend',
              method: state == 'none' ? 'PUT' : 'DELETE',
            );
      if (mounted) setState(() => item['friendState'] = result['state']);
    } on Exception catch (issue) {
      say(issue);
    }
  }

  void open(Map<String, dynamic> profile) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PublicProfileScreen(
          gateway: widget.gateway,
          profileId: profile['id'] as String,
          initial: profile,
        ),
      ),
    );
  }

  Widget? _action(Map<String, dynamic> profile) {
    if (profile['followState'] == 'self') return null;
    if (widget.kind == RelationListKind.friends) {
      return OutlinedButton(
        key: Key('relation-friend-${profile['id']}'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          textStyle: const TextStyle(fontSize: 13),
        ),
        onPressed: () => toggleFriend(profile),
        child: Text(_compactFriendLabel(profile['friendState'] as String?)),
      );
    }
    final state = profile['followState'] as String? ?? 'none';
    final label =
        widget.kind == RelationListKind.followers &&
            widget.ownList &&
            state == 'none'
        ? 'Seguir de volta'
        : followLabel(state);
    return OutlinedButton(
      key: Key('relation-follow-${profile['id']}'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: const TextStyle(fontSize: 13),
      ),
      onPressed: () => toggleFollow(profile),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: items == null
        ? (error != null
              ? Center(child: Text(error!, key: const Key('relation-error')))
              : const Center(child: CircularProgressIndicator()))
        : items!.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nada por aqui ainda.',
              key: Key('relation-empty'),
              textAlign: TextAlign.center,
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items!.length + (nextCursor != null ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == items!.length && moreFailed) {
                return Padding(
                  key: const Key('relation-more-failed'),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text('Não foi possível carregar mais agora.'),
                      TextButton(
                        key: const Key('relation-more-retry'),
                        onPressed: () => load(more: true),
                        child: const Text('Tentar de novo'),
                      ),
                    ],
                  ),
                );
              }
              if (index == items!.length) {
                // Nao chamar load() direto aqui: itemBuilder roda durante o layout, e setState
                // nessa hora quebra o Flutter. Agenda para depois do frame atual.
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => load(more: true),
                );
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final profile = items![index];
              return Card(
                child: ListTile(
                  key: Key('relation-${profile['id']}'),
                  leading: ProfileAvatar(
                    gateway: widget.gateway,
                    profile: profile,
                  ),
                  title: Text(profile['displayName'] as String? ?? ''),
                  subtitle: Text('@${profile['username']}'),
                  trailing: _action(profile),
                  onTap: () => open(profile),
                ),
              );
            },
          ),
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
    } on Exception catch (issue) {
      // O aviso vai embaixo: a recarga da lista limpa o erro da tela.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              friendsError(
                issue is IdentityIssue ? issue : const IdentityIssue(''),
              ),
            ),
          ),
        );
      }
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

  /// Comentario meu que esta sendo editado (o campo de baixo vira "Editando").
  Map<String, dynamic>? editing;

  /// Exclusoes que ainda podem ser desfeitas: somem da tela na hora, mas so vao ao servidor
  /// quando o aviso "Desfazer" acaba (ou ao sair da tela).
  final pendingDeletes = <String>{};

  /// Pessoas sugeridas enquanto digita "@..." no comentario.
  List<Map<String, dynamic>> mentionSuggestions = [];
  Timer? mentionTimer;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    mentionTimer?.cancel();
    // Exclusão em espera ao sair da tela: o aviso com "Desfazer" continua valendo e `remove` termina
    // sozinho quando ele fecha (antes apagava aqui, e o "Desfazer" do aviso já não desfazia nada).
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
      // Todas as páginas (até 500): com só a primeira, o comentário novo de um post com 50 ou mais não
      // aparecia e parecia que o envio tinha falhado.
      final all = <Map<String, dynamic>>[];
      String? cursor;
      var pages = 0;
      do {
        final page = await widget.gateway.request(
          path,
          query: {'limit': '50', 'cursor': ?cursor},
        );
        all.addAll((page['items'] as List).cast<Map<String, dynamic>>());
        cursor = page['nextCursor'] as String?;
      } while (cursor != null && ++pages < 10);
      if (mounted) {
        setState(() {
          comments = all;
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
      final target = editing;
      if (target != null) {
        await widget.gateway.request(
          '/comments/${Uri.encodeComponent(target['id'] as String)}',
          method: 'PATCH',
          body: {'text': value},
        );
        editing = null;
      } else {
        await widget.gateway.request(
          path,
          method: 'POST',
          body: {'text': value, 'parentId': ?replyingTo?['id']},
        );
        replyingTo = null;
      }
      text.clear();
      mentionSuggestions = [];
      await load();
    } on Exception catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void startEdit(Map<String, dynamic> c) {
    setState(() {
      editing = c;
      replyingTo = null;
      text.text = c['text'] as String? ?? '';
      text.selection = TextSelection.collapsed(offset: text.text.length);
    });
    input.requestFocus();
  }

  void cancelEdit() {
    setState(() {
      editing = null;
      text.clear();
      mentionSuggestions = [];
    });
  }

  // ---- @menções: ao digitar "@", sugere pessoas e insere o @usuario escolhido ----
  static final _mentionToken = RegExp(r'(?:^|[\s(])@([A-Za-z0-9_]{0,30})$');

  void onTextChanged(String value) {
    final caret = text.selection.baseOffset;
    final before = caret < 0 || caret > value.length
        ? value
        : value.substring(0, caret);
    final match = _mentionToken.firstMatch(before);
    mentionTimer?.cancel();
    if (match == null) {
      if (mentionSuggestions.isNotEmpty) {
        setState(() => mentionSuggestions = []);
      }
      return;
    }
    final token = match.group(1)!;
    if (token.length == 1) return; // a busca pede 2 letras; espera mais uma
    mentionTimer = Timer(
      const Duration(milliseconds: 250),
      () => loadMentionSuggestions(token),
    );
  }

  Future<void> loadMentionSuggestions(String token) async {
    try {
      final page = token.isEmpty
          ? await widget.gateway.request(
              '/profiles/suggestions',
              query: {'limit': '5'},
            )
          : await widget.gateway.request(
              '/profiles',
              query: {'q': token, 'limit': '5'},
            );
      if (!mounted) return;
      setState(
        () => mentionSuggestions = (page['items'] as List)
            .cast<Map<String, dynamic>>(),
      );
    } on Exception {
      if (mounted) setState(() => mentionSuggestions = []);
    }
  }

  void insertMention(Map<String, dynamic> person) {
    final caret = text.selection.baseOffset;
    final value = text.text;
    final end = caret < 0 || caret > value.length ? value.length : caret;
    final before = value.substring(0, end);
    final match = _mentionToken.firstMatch(before);
    if (match == null) return;
    final at = before.lastIndexOf('@');
    final inserted = '@${person['username']} ';
    text.value = TextEditingValue(
      text: value.replaceRange(at, end, inserted),
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
    setState(() => mentionSuggestions = []);
    input.requestFocus();
  }

  /// Apagar com "Desfazer": o comentário some da tela na hora e só é apagado no servidor se a
  /// pessoa não desfizer no aviso (ou ao sair da tela).
  Future<void> remove(String id) async {
    setState(() => pendingDeletes.add(id));
    final messenger = ScaffoldMessenger.of(context);
    final gateway = widget.gateway; // a tela pode fechar antes de o aviso sumir
    messenger.hideCurrentSnackBar();
    final reason = await messenger
        .showSnackBar(
          SnackBar(
            key: const Key('comment-deleted-snack'),
            content: const Text('Comentário excluído'),
            duration: const Duration(seconds: 6),
            persist: false, // com ação o aviso não some sozinho, a menos que se diga o contrário
            action: SnackBarAction(
              key: const Key('undo-delete-comment'),
              label: 'Desfazer',
              onPressed: () {},
            ),
          ),
        )
        .closed;
    if (!pendingDeletes.contains(id)) return;
    if (reason == SnackBarClosedReason.action) {
      if (mounted) setState(() => pendingDeletes.remove(id));
      return;
    }
    try {
      await gateway.request(
        '/comments/${Uri.encodeComponent(id)}',
        method: 'DELETE',
      );
    } on Exception catch (e) {
      fail(e);
    }
    pendingDeletes.remove(id);
    if (mounted) await load();
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
    if (author['removed'] == true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Esta conta foi removida.')));
      return;
    }
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

  /// Denuncia um comentário de outra pessoa; se a pessoa for bloqueada em seguida, recarrega a lista.
  Future<void> reportComment(Map<String, dynamic> c) async {
    final author = c['author'] as Map;
    final sent = await reportContent(
      context,
      widget.gateway,
      targetType: 'comment',
      targetId: c['id'] as String,
      blockUserId: author['id'] as String?,
      blockUserName: author['displayName'] as String?,
    );
    if (sent && mounted) await load();
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
                    ' · ${timeAgo(DateTime.tryParse(c['createdAt'] as String? ?? '') ?? DateTime.now())}'
                    '${c['edited'] == true ? ' · editado' : ''}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                MentionText(
                  c['text'] as String? ?? '',
                  mentions: (c['mentions'] as List? ?? const [])
                      .cast<Map<String, dynamic>>(),
                  onOpen: (person) => openProfile(person),
                ),
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
                    if (author['id'] == widget.myId)
                      IconButton(
                        key: Key('edit-comment-${c['id']}'),
                        tooltip: 'Editar comentário',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => startEdit(c),
                      ),
                    if (author['id'] != widget.myId)
                      IconButton(
                        key: Key('report-comment-${c['id']}'),
                        tooltip: 'Denunciar comentário',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.flag_outlined, size: 20),
                        onPressed: () => reportComment(c),
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
              for (final c
                  in (comments ?? const <Map<String, dynamic>>[]).where(
                    (c) => !pendingDeletes.contains(c['id']),
                  )) ...[
                commentTile(c),
                if ((c['replies'] as List? ?? const []).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 36),
                    child: Column(
                      children: [
                        for (final r
                            in (c['replies'] as List)
                                .cast<Map<String, dynamic>>()
                                .where(
                                  (r) => !pendingDeletes.contains(r['id']),
                                ))
                          commentTile(r, root: c),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        if (editing != null)
          Container(
            key: const Key('editing-comment'),
            width: double.infinity,
            color: context.softFill,
            padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
            child: Row(
              children: [
                const Expanded(child: Text('Editando comentário')),
                IconButton(
                  key: const Key('cancel-edit'),
                  tooltip: 'Cancelar edição',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: cancelEdit,
                ),
              ],
            ),
          ),
        if (mentionSuggestions.isNotEmpty)
          Material(
            key: const Key('mention-suggestions'),
            color: context.softFill,
            child: Column(
              children: [
                for (final person in mentionSuggestions)
                  ListTile(
                    key: Key('mention-${person['id']}'),
                    dense: true,
                    leading: ProfileAvatar(
                      radius: 14,
                      gateway: widget.gateway,
                      profile: person,
                    ),
                    title: Text('${person['displayName'] ?? ''}'),
                    subtitle: Text('@${person['username']}'),
                    onTap: () => insertMention(person),
                  ),
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
                    onChanged: onTextChanged,
                    decoration: InputDecoration(
                      hintText: editing != null
                          ? 'Edite seu comentário'
                          : replyingTo == null
                          ? 'Escreva um comentário (use @ para marcar alguém)'
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

/// Texto de comentário com as pessoas marcadas (@usuario) em destaque; tocar abre o perfil.
/// Só vira link quem veio em `mentions` (conta existente); o resto do @ fica como texto.
class MentionText extends StatefulWidget {
  final String text;
  final List<Map<String, dynamic>> mentions;
  final void Function(Map<String, dynamic> person) onOpen;
  const MentionText(
    this.text, {
    super.key,
    this.mentions = const [],
    required this.onOpen,
  });

  @override
  State<MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends State<MentionText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    if (widget.mentions.isEmpty) return Text(widget.text);
    final byName = {
      for (final m in widget.mentions)
        (m['username'] as String).toLowerCase(): m,
    };
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in RegExp(
      r'(?<![\w@])@([A-Za-z0-9_]{3,30})',
    ).allMatches(widget.text)) {
      final person = byName[match.group(1)!.toLowerCase()];
      if (person == null) continue;
      if (match.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, match.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onOpen(person);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: match.group(0),
          recognizer: recognizer,
          style: const TextStyle(
            color: runPassOrange,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      last = match.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    return Text.rich(TextSpan(children: spans), key: const Key('mention-text'));
  }
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
