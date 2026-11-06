import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    'follow_request' => '$name quer seguir você.',
    'follow' => '$name começou a seguir você.',
    'like' => '$name curtiu sua publicação.',
    'comment' => '$name comentou: “${item['text'] ?? ''}”',
    'post' => '$name publicou uma conquista.',
    _ => '$name interagiu com você.',
  };
}

IconData notificationIcon(String? kind) => switch (kind) {
  'follow_request' => Icons.person_add_alt_1_rounded,
  'follow' => Icons.person_rounded,
  'like' => Icons.favorite_rounded,
  'comment' => Icons.chat_bubble_rounded,
  _ => Icons.emoji_events_rounded,
};

/// Avisos no centro de notificacoes do iPhone e do Android. Ligados por padrao; a pessoa pode
/// desligar na tela de avisos ou nas configuracoes. Falha de plugin ou de permissao nunca
/// atrapalha o app.
class LocalAlerts {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
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
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
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

  static Future<void> show(int id, String body) async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: 'RunPass',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'runpass-social',
            'Amigos e interações',
            channelDescription: 'Pedidos para seguir, curtidas, comentários e publicações de amigos.',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
          ),
        ),
      );
    } on Object {
      // Sem permissao ou plugin indisponivel.
    }
  }

  /// Mostra no celular so o que chegou depois do ultimo aviso mostrado. Na primeira vez apenas
  /// marca o ponto de partida, para nao despejar o historico inteiro.
  static Future<void> announce(List<Map<String, dynamic>> items) async {
    if (!await enabled()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_lastKey);
      final newest = items.isEmpty
          ? null
          : items
                .map((i) => i['createdAt'] as String? ?? '')
                .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
      if (last == null) {
        if (newest != null) await prefs.setString(_lastKey, newest);
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
        await show(i['id'].hashCode & 0x7fffffff, notificationText(i));
      }
    } on Object {
      // Avisos do celular sao um extra.
    }
  }
}

/// Contador do sininho e verificacao periodica enquanto o app esta aberto.
class NotificationCenter {
  NotificationCenter._();
  static final instance = NotificationCenter._();

  /// Ligado so no app real: nos testes, a tela nao faz chamadas nem cria timers.
  static bool active = false;

  final unread = ValueNotifier<int>(0);
  Timer? _timer;
  IdentityGateway? _gateway;

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
      if (announce) await LocalAlerts.announce(items);
      return items;
    } on Exception {
      return const [];
    }
  }

  void start(IdentityGateway gateway) {
    if (!active) return;
    _gateway = gateway;
    _timer ??= Timer.periodic(const Duration(seconds: 45), (_) {
      final current = _gateway;
      if (current != null && current.signedIn) refresh(current);
    });
    refresh(gateway);
  }

  void stop() {
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

/// Alternador "Avisos no celular", usado na tela de avisos e nas configuracoes.
class OsAlertsSwitch extends StatefulWidget {
  const OsAlertsSwitch({super.key});

  @override
  State<OsAlertsSwitch> createState() => _OsAlertsSwitchState();
}

class _OsAlertsSwitchState extends State<OsAlertsSwitch> {
  bool value = true;

  @override
  void initState() {
    super.initState();
    LocalAlerts.enabled().then((v) {
      if (mounted) setState(() => value = v);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const Key('os-alerts-switch'),
    secondary: const Icon(Icons.notifications_active_outlined),
    title: const Text('Avisos no celular'),
    subtitle: const Text(
      'Receba no iPhone ou no Android os avisos de seguidores, curtidas, comentários e publicações de amigos.',
    ),
    value: value,
    onChanged: (next) {
      setState(() => value = next);
      LocalAlerts.setEnabled(next);
    },
  );
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

  Future<void> decide(Map<String, dynamic> item, bool approve) async {
    final actor = item['actor'] as Map;
    try {
      await widget.gateway.request(
        '/me/follow-requests/${Uri.encodeComponent(actor['id'] as String)}',
        method: approve ? 'PUT' : 'DELETE',
      );
    } on Exception {
      if (mounted) {
        setState(() => error = friendsError(const IdentityIssue('')));
      }
      return;
    }
    await load();
  }

  /// Deslizar para a esquerda apaga o aviso (pedidos para seguir nao: aceite ou recuse).
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

  Future<void> open(Map<String, dynamic> item) async {
    final actor = item['actor'] as Map;
    final kind = item['kind'] as String?;
    final postId = item['postId'] as String?;
    if (postId != null && kind != 'follow' && kind != 'follow_request') {
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
    final request = item['kind'] == 'follow_request';
    return Card(
      key: Key('notification-${item['id']}'),
      color: request
          ? (Theme.of(context).brightness == Brightness.dark
                ? const Color(0xff3a2216)
                : const Color(0xffffe4d6))
          : unread
          ? (Theme.of(context).brightness == Brightness.dark
                ? const Color(0xff2a2018)
                : const Color(0xffffeee6))
          : null,
      shape: request
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: runPassOrange, width: 1.5),
            )
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
              if (request)
                Padding(
                  padding: const EdgeInsets.only(top: 10, left: 58),
                  child: Row(
                    children: [
                      FilledButton(
                        key: Key('notification-approve-${actor['id']}'),
                        onPressed: () => decide(item, true),
                        child: const Text('Aceitar'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        key: Key('notification-decline-${actor['id']}'),
                        onPressed: () => decide(item, false),
                        child: const Text('Recusar'),
                      ),
                    ],
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
                'Nada por aqui ainda. Pedidos para seguir, curtidas, comentários e publicações de amigos aparecem neste lugar.',
                key: Key('no-notifications'),
                textAlign: TextAlign.center,
              ),
            ),
          if ((items ?? const []).any((i) => i['kind'] == 'follow_request'))
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Pedidos para seguir',
                key: Key('requests-title'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ),
          for (final item in items ?? const <Map<String, dynamic>>[]) ...[
            if (item['kind'] == 'follow_request')
              row(item)
            else
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
