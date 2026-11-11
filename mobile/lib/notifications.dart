import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'catalog_screen.dart' show timeAgo;
import 'friends.dart';
import 'identity_gateway.dart';
import 'post_card.dart';
import 'runpass_theme.dart';

/// Texto de um aviso, igual na tela e no aviso do celular.
String notificationText(Map<String, dynamic> item) {
  final actor = item['actor'] as Map? ?? const {};
  final name = actor['displayName'] as String? ?? 'Alguém';
  return switch (item['kind']) {
    'friend_request' => '$name quer ser seu amigo.',
    'friend' => 'Você e $name agora são amigos.',
    'follow' => '$name começou a seguir você.',
    'like' => '$name curtiu sua publicação.',
    'comment' => '$name comentou: “${item['text'] ?? ''}”',
    'post' => '$name publicou uma conquista.',
    'comment_like' => '$name curtiu seu comentário.',
    'reply' => '$name respondeu seu comentário: “${item['text'] ?? ''}”',
    _ => '$name interagiu com você.',
  };
}

IconData notificationIcon(String? kind) => switch (kind) {
  'friend_request' => Icons.person_add_alt_1_rounded,
  'friend' => Icons.how_to_reg_rounded,
  'follow' => Icons.person_rounded,
  'like' => Icons.favorite_rounded,
  'comment' => Icons.chat_bubble_rounded,
  'comment_like' => Icons.favorite_rounded,
  'reply' => Icons.reply_rounded,
  _ => Icons.emoji_events_rounded,
};

/// Avisos no centro de notificacoes do iPhone e do Android. Ligados por padrao; a pessoa pode
/// desligar na tela de avisos ou nas configuracoes. Falha de plugin ou de permissao nunca
/// atrapalha o app.
class LocalAlerts {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static const requestCategory = 'friend_request';
  static const acceptAction = 'accept';
  static const declineAction = 'decline';
  static const _enabledKey = 'os-alerts-enabled';
  static const _lastKey = 'os-alerts-last';

  static Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_enabledKey) ??
          true;
    } on Object {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_enabledKey, value);
    } on Object {
      // Sem armazenamento: vale so ate fechar o app.
    }
    if (value) await requestPermission();
  }

  static Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
            // Pedido para seguir: botoes Aceitar e Recusar no proprio aviso do iPhone.
            notificationCategories: [
              DarwinNotificationCategory(
                requestCategory,
                actions: [
                  DarwinNotificationAction.plain(
                    acceptAction,
                    'Aceitar',
                    options: {DarwinNotificationActionOption.foreground},
                  ),
                  DarwinNotificationAction.plain(
                    declineAction,
                    'Recusar',
                    options: {
                      DarwinNotificationActionOption.foreground,
                      DarwinNotificationActionOption.destructive,
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        onDidReceiveNotificationResponse: (response) =>
            NotificationCenter.instance.handleResponse(response),
      );
      _ready = true;
    } on Object {
      _ready = false;
    }
  }

  static Future<void> requestPermission() async {
    await init();
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } on Object {
      // A pessoa pode negar; os avisos continuam na tela do sininho.
    }
  }

  /// Ultimo erro e ultima checagem, para o diagnostico em Configuracoes.
  static String? lastError;
  static DateTime? lastCheck;

  /// Permissao do sistema: verdadeiro/falso, ou nulo se nao deu para ler.
  static Future<bool?> permissionGranted() async {
    await init();
    try {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) return (await ios.checkPermissions())?.isEnabled;
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.areNotificationsEnabled();
    } on Object catch (error) {
      lastError = '$error';
      return null;
    }
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'runpass-social',
      'Amigos e interações',
      channelDescription:
          'Pedidos para seguir, curtidas, comentários e publicações de amigos.',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentSound: true,
    ),
  );

  /// Teste: aviso agora (app aberto) ou agendado no sistema (vale com o app fechado).
  static Future<void> test({Duration after = Duration.zero}) async {
    await init();
    if (!_ready) {
      lastError ??= 'plugin nao iniciou';
      return;
    }
    try {
      if (after == Duration.zero) {
        await _plugin.show(
          id: 7001,
          title: 'MeuPódio',
          body: 'Teste: os avisos estão funcionando neste celular.',
          notificationDetails: _details,
        );
      } else {
        await _plugin.zonedSchedule(
          id: 7002,
          title: 'MeuPódio',
          body: 'Teste agendado: o aviso chegou com o app fechado.',
          scheduledDate: tz.TZDateTime.now(tz.UTC).add(after),
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
      lastError = null;
    } on Object catch (error) {
      lastError = '$error';
    }
  }

  /// Aviso de pedido de amizade: com os botoes Aceitar e Recusar.
  static const _requestDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'runpass-social',
      'Amigos e interações',
      channelDescription:
          'Pedidos de amizade, curtidas, comentários e publicações de amigos.',
      importance: Importance.high,
      priority: Priority.high,
      actions: [
        AndroidNotificationAction(
          acceptAction,
          'Aceitar',
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          declineAction,
          'Recusar',
          showsUserInterface: true,
        ),
      ],
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentSound: true,
      categoryIdentifier: requestCategory,
    ),
  );

  static Future<void> show(
    int id,
    String body, {
    String? payload,
    bool request = false,
  }) async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: 'MeuPódio',
        body: body,
        payload: payload,
        notificationDetails: request ? _requestDetails : _details,
      );
    } on Object catch (error) {
      lastError = '$error'; // sem permissao ou plugin indisponivel
    }
  }

  /// Mostra no celular so o que chegou depois do ultimo aviso mostrado. Na primeira vez apenas
  /// marca o ponto de partida, para nao despejar o historico inteiro.
  static Future<void> announce(
    List<Map<String, dynamic>> items, {
    Future<void> Function(int id, String body, {String? payload, bool request})?
    present,
  }) async {
    if (!await enabled()) return;
    present ??= show;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_lastKey);
      final newest = items.isEmpty
          ? null
          : items
                .map((i) => i['createdAt'] as String? ?? '')
                .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
      if (last == null) {
        // Primeira checagem: marca o ponto de partida sem despejar o historico. Historico vazio
        // grava "" (qualquer aviso futuro e novo); antes ficava nulo e o primeiro aviso real era
        // engolido como se fosse o ponto de partida.
        await prefs.setString(_lastKey, newest ?? '');
        await requestPermission();
        return;
      }
      final fresh = [
        for (final i in items)
          if (i['unread'] == true &&
              (i['createdAt'] as String? ?? '').compareTo(last) > 0)
            i,
      ];
      if (fresh.isEmpty) return;
      if (newest != null) await prefs.setString(_lastKey, newest);
      for (final i in fresh.take(3)) {
        final request = i['kind'] == 'friend_request';
        await present(
          i['id'].hashCode & 0x7fffffff,
          notificationText(i),
          request: request,
          payload: request
              ? jsonEncode({
                  'kind': 'friend_request',
                  'actorId': (i['actor'] as Map?)?['id'],
                })
              : null,
        );
      }
    } on Object {
      // Avisos do celular sao um extra.
    }
  }
}

/// Contador do sininho e verificacao periodica enquanto o app esta aberto.
class NotificationCenter with WidgetsBindingObserver {
  NotificationCenter._();
  static final instance = NotificationCenter._();

  /// Ligado so no app real: nos testes, a tela nao faz chamadas nem cria timers.
  static bool active = false;

  final unread = ValueNotifier<int>(0);
  Timer? _timer;
  IdentityGateway? _gateway;
  bool _asked = false;

  Future<List<Map<String, dynamic>>> refresh(
    IdentityGateway gateway, {
    bool announce = true,
  }) async {
    if (!active) return const [];
    try {
      final page = await gateway.request('/me/notifications');
      final items = (page['items'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      unread.value = (page['unreadCount'] as num?)?.toInt() ?? 0;
      LocalAlerts.lastCheck = DateTime.now();
      if (announce) await LocalAlerts.announce(items);
      return items;
    } on Exception {
      return const [];
    }
  }

  void start(IdentityGateway gateway) {
    if (!active) return;
    _gateway = gateway;
    if (!_asked) {
      _asked = true;
      // Permissao pedida logo apos o login, e nao so no primeiro ciclo de checagem.
      LocalAlerts.enabled().then((on) {
        if (on) LocalAlerts.requestPermission();
      });
    }
    if (_timer == null) WidgetsBinding.instance.addObserver(this);
    _timer ??= Timer.periodic(const Duration(seconds: 45), (_) {
      final current = _gateway;
      if (current != null && current.signedIn) {
        flushDecisions();
        refresh(current);
      }
    });
    refresh(gateway);
    flushDecisions();
    // Abriu pelo aviso antes de entrar na conta: agora a tela de avisos pode abrir.
    if (_openPending) {
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => openNotificationsScreen())
        ..scheduleFrame(); // garante um quadro, mesmo com a tela parada
    }
  }

  final _decisions = <({String actorId, bool approve})>[];
  bool _openPending = false;
  bool _screenOpen = false;

  /// Abre a tela de avisos. Se o app ainda nao entrou na conta (abriu pelo aviso), espera.
  void openNotificationsScreen() {
    final gateway = _gateway;
    final navigator = runPassNavigatorKey.currentState;
    if (gateway == null || !gateway.signedIn || navigator == null) {
      _openPending = true;
      return;
    }
    _openPending = false;
    if (_screenOpen) return;
    _screenOpen = true;
    navigator
        .push(
          MaterialPageRoute<void>(
            builder: (_) => NotificationsScreen(gateway: gateway),
          ),
        )
        .whenComplete(() => _screenOpen = false);
  }

  /// Toque num botao do aviso do celular (Aceitar/Recusar). Se o app ainda nao entrou na conta,
  /// a decisao espera na fila e e aplicada assim que houver sessao.
  Future<void> handleResponse(NotificationResponse response) async {
    final action = response.actionId;
    if (action != LocalAlerts.acceptAction &&
        action != LocalAlerts.declineAction) {
      // Toque no corpo do aviso: leva para a tela de avisos.
      openNotificationsScreen();
      return;
    }
    try {
      final data = jsonDecode(response.payload ?? '{}') as Map;
      final actor = data['actorId'];
      if (actor is String && actor.isNotEmpty) {
        _decisions.add((
          actorId: actor,
          approve: action == LocalAlerts.acceptAction,
        ));
      }
    } on Object {
      return;
    }
    await flushDecisions();
  }

  Future<void> flushDecisions() async {
    final gateway = _gateway;
    if (gateway == null || !gateway.signedIn) return;
    while (_decisions.isNotEmpty) {
      final next = _decisions.first;
      try {
        await gateway.request(
          '/me/friend-requests/${Uri.encodeComponent(next.actorId)}',
          method: next.approve ? 'PUT' : 'DELETE',
        );
      } on Exception {
        break; // sem rede: tenta de novo na proxima checagem
      }
      _decisions.removeAt(0);
    }
    await refresh(gateway, announce: false);
  }

  /// Voltar ao app (iOS suspende o timer em segundo plano): confere na hora.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final current = _gateway;
    if (state == AppLifecycleState.resumed &&
        current != null &&
        current.signedIn) {
      refresh(current);
    }
  }

  void stop() {
    // Sair da conta: nada de tela de avisos aberta nem abertura pendente de outra sessao.
    _screenOpen = false;
    _openPending = false;
    _decisions.clear();
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _gateway = null;
    unread.value = 0;
  }
}

class NotificationBell extends StatefulWidget {
  final IdentityGateway gateway;
  const NotificationBell({super.key, required this.gateway});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  @override
  void initState() {
    super.initState();
    NotificationCenter.instance.start(widget.gateway);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: NotificationCenter.instance.unread,
    builder: (context, count, _) => IconButton(
      visualDensity: VisualDensity.compact,
      key: const Key('notifications-bell'),
      tooltip: count > 0 ? 'Avisos ($count novos)' : 'Avisos',
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 9 ? '9+' : '$count'),
        child: const Icon(Icons.notifications_none_rounded),
      ),
      onPressed: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NotificationsScreen(gateway: widget.gateway),
          ),
        );
        NotificationCenter.instance.refresh(widget.gateway, announce: false);
      },
    ),
  );
}

/// "Avisos no celular": chave, estado da permissao do sistema e testes de aviso.
class OsAlertsSwitch extends StatefulWidget {
  const OsAlertsSwitch({super.key});

  @override
  State<OsAlertsSwitch> createState() => _OsAlertsSwitchState();
}

class _OsAlertsSwitchState extends State<OsAlertsSwitch> {
  bool value = true;
  bool? granted;

  @override
  void initState() {
    super.initState();
    LocalAlerts.enabled().then((v) {
      if (mounted) setState(() => value = v);
    });
    refreshStatus();
  }

  Future<void> refreshStatus() async {
    final result = await LocalAlerts.permissionGranted();
    if (mounted) setState(() => granted = result);
  }

  String get statusText => switch (granted) {
    true => 'Permissão do sistema: liberada.',
    false => 'Permissão do sistema: NEGADA. Abra Ajustes > MeuPódio > Notificações e libere.',
    null => 'Permissão do sistema: não foi possível conferir.',
  };

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        key: const Key('os-alerts-switch'),
        secondary: const Icon(Icons.notifications_active_outlined),
        title: const Text('Avisos no celular'),
        subtitle: const Text(
          'Receba no iPhone ou no Android os avisos de seguidores, curtidas, comentários e publicações de amigos.',
        ),
        value: value,
        onChanged: (next) async {
          setState(() => value = next);
          await LocalAlerts.setEnabled(next);
          await refreshStatus();
        },
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            statusText,
            key: const Key('os-alerts-status'),
            style: TextStyle(fontSize: 12, color: context.muted),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
        child: Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              key: const Key('os-alerts-test-now'),
              onPressed: () async {
                await LocalAlerts.requestPermission();
                await LocalAlerts.test();
                await refreshStatus();
                if (context.mounted) showResult(context);
              },
              child: const Text('Testar agora'),
            ),
            OutlinedButton(
              key: const Key('os-alerts-test-later'),
              onPressed: () async {
                await LocalAlerts.requestPermission();
                await LocalAlerts.test(after: const Duration(seconds: 10));
                await refreshStatus();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Aviso agendado para daqui a 10 segundos. Feche o app agora para testar com ele fechado.',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Testar em 10 s (feche o app)'),
            ),
          ],
        ),
      ),
    ],
  );

  void showResult(BuildContext context) {
    final error = LocalAlerts.lastError;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? 'Aviso enviado. Se não apareceu, confira a permissão acima.'
              : 'Falha ao avisar: $error',
        ),
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const NotificationsScreen({super.key, required this.gateway});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>>? items;
  String? error;

  int get pendingFriendRequests =>
      (items ?? const []).where((i) => i['kind'] == 'friend_request').length;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final page = await widget.gateway.request('/me/notifications');
      final list = (page['items'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      if (mounted) {
        setState(() {
          items = list;
          error = null;
        });
      }
      if ((page['unreadCount'] as num?) != 0) {
        await widget.gateway.request('/me/notifications/read', method: 'POST');
        NotificationCenter.instance.unread.value = 0;
      }
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Não foi possível carregar os avisos. Tente de novo.',
        );
      }
    }
  }

  /// Deslizar para a esquerda apaga o aviso.
  Future<void> dismiss(Map<String, dynamic> item) async {
    setState(() => items?.remove(item));
    try {
      await widget.gateway.request(
        '/me/notifications/${Uri.encodeComponent(item['id'] as String)}',
        method: 'DELETE',
      );
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Não foi possível apagar o aviso. Tente de novo.',
        );
      }
      await load();
    }
  }

  /// Aviso "comecou a seguir voce": seguir de volta sem sair da lista.
  Future<void> followBack(Map<String, dynamic> item) async {
    final actor = item['actor'] as Map;
    try {
      final result = await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(actor['id'] as String)}/follow',
        method: 'PUT',
      );
      if (mounted) {
        setState(() => actor['followState'] = result['state'] ?? 'active');
      }
    } on Exception {
      if (mounted) {
        setState(() => error = friendsError(const IdentityIssue('')));
      }
    }
  }

  Future<void> open(Map<String, dynamic> item) async {
    final actor = item['actor'] as Map;
    final kind = item['kind'] as String?;
    final postId = item['postId'] as String?;
    if (postId != null &&
        kind != 'follow' &&
        kind != 'friend' &&
        kind != 'friend_request') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PostScreen(gateway: widget.gateway, postId: postId),
        ),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PublicProfileScreen(
            gateway: widget.gateway,
            profileId: actor['id'] as String,
            initial: Map<String, dynamic>.from(actor),
          ),
        ),
      );
    }
    if (mounted) load();
  }

  Widget row(Map<String, dynamic> item) {
    final actor = item['actor'] as Map;
    final created = DateTime.tryParse(item['createdAt'] as String? ?? '');
    final unread = item['unread'] == true;
    return Card(
      key: Key('notification-${item['id']}'),
      color: unread
          ? (Theme.of(context).brightness == Brightness.dark
                ? const Color(0xff2a2018)
                : const Color(0xffffeee6))
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => open(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ProfileAvatar(
                        gateway: widget.gateway,
                        profile: actor,
                        radius: 22,
                      ),
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: CircleAvatar(
                          radius: 11,
                          backgroundColor: runPassOrange,
                          child: Icon(
                            notificationIcon(item['kind'] as String?),
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          notificationText(item),
                          style: TextStyle(
                            fontWeight: unread
                                ? FontWeight.w800
                                : FontWeight.w500,
                          ),
                        ),
                        if (created != null)
                          Text(
                            timeAgo(created),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (item['kind'] == 'follow' && actor['followState'] == 'none')
                Padding(
                  padding: const EdgeInsets.only(top: 10, left: 58),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      key: Key('notification-follow-back-${actor['id']}'),
                      onPressed: () => followBack(item),
                      child: const Text('Seguir de volta'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Avisos')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (error != null)
            Text(error!, key: const Key('notifications-error')),
          if (items == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (items != null && items!.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nada por aqui ainda. Pedidos de amizade, curtidas, comentários e publicações de amigos aparecem neste lugar.',
                key: Key('no-notifications'),
                textAlign: TextAlign.center,
              ),
            ),
          // Sempre visível, mesmo com zero pedidos pendentes.
          Card(
            child: ListTile(
              key: const Key('friend-requests-section'),
              leading: const Icon(
                Icons.how_to_reg_rounded,
                color: runPassOrange,
              ),
              title: Text('Pedidos de amizade ($pendingFriendRequests)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        FriendRequestsScreen(gateway: widget.gateway),
                  ),
                );
                if (mounted) load();
              },
            ),
          ),
          const SizedBox(height: 8),
          for (final item in (items ?? const <Map<String, dynamic>>[]).where(
            (i) => i['kind'] != 'friend_request',
          )) ...[
            Dismissible(
              key: Key('dismiss-${item['id']}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.delete_outline, color: Colors.white),
              ),
              onDismissed: (_) => dismiss(item),
              child: row(item),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    ),
  );
}
