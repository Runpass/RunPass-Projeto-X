import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'runpass_theme.dart';

/// Agenda da pessoa: corridas desejadas (quero correr) e inscritas (vou correr).
/// Os dados são só dela: `/me/race-plans`.
class AgendaScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const AgendaScreen({super.key, required this.gateway});
  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  List<Map<String, dynamic>> plans = [];
  bool loading = true;
  String? error;

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
      final page = await widget.gateway.request('/me/race-plans');
      if (mounted) {
        plans = (page['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
      }
    } on IdentityIssue catch (issue) {
      if (mounted) error = catalogError(issue);
    } on Exception {
      if (mounted) {
        error = 'Sem conexão com o servidor. Verifique a internet e tente novamente.';
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> change(Map<String, dynamic> plan, String? status) async {
    final id = Uri.encodeComponent(plan['editionId'] as String);
    try {
      if (status == null) {
        await widget.gateway.request('/me/race-plans/$id', method: 'DELETE');
      } else {
        await widget.gateway.request(
          '/me/race-plans/$id',
          method: 'PUT',
          body: {'status': status, 'distanceId': ?plan['distanceId']},
        );
      }
      await load();
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

  /// Próximas primeiro (da mais perto para a mais longe); as que já passaram vão para o fim.
  List<Map<String, dynamic>> forStatus(String status) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final items = [
      for (final p in plans)
        if (p['status'] == status) p,
    ];
    String date(Map<String, dynamic> p) =>
        (p['edition'] as Map)['date'] as String;
    final upcoming = items.where((p) => date(p).compareTo(today) >= 0).toList()
      ..sort((a, b) => date(a).compareTo(date(b)));
    final past = items.where((p) => date(p).compareTo(today) < 0).toList()
      ..sort((a, b) => date(b).compareTo(date(a)));
    return [...upcoming, ...past];
  }

  Widget tile(Map<String, dynamic> plan, String status) {
    final edition = Map<String, dynamic>.from(plan['edition'] as Map);
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final passed = (edition['date'] as String).compareTo(today) < 0;
    final distances = [
      for (final d in (edition['distances'] as List? ?? const []))
        '${(d as Map)['kilometers']} km',
    ].join(' · ');
    return Card(
      key: Key('agenda-${plan['editionId']}'),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(
          status == 'wanted' ? Icons.favorite : Icons.how_to_reg_outlined,
          color: runPassOrange,
        ),
        title: Text(edition['name'] as String),
        subtitle: Text(
          '${displayDate(edition['date'] as String)} · ${edition['city']}/${edition['state']}\n'
          '$distances${passed ? '\nJá aconteceu' : ''}',
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          key: Key('agenda-menu-${plan['editionId']}'),
          tooltip: 'Opções',
          onSelected: (value) => change(plan, value == 'remove' ? null : value),
          itemBuilder: (_) => [
            if (status == 'wanted')
              const PopupMenuItem(
                value: 'registered',
                child: Text('Marcar como inscrito'),
              ),
            if (status == 'registered')
              const PopupMenuItem(
                value: 'wanted',
                child: Text('Voltar para desejadas'),
              ),
            const PopupMenuItem(
              value: 'remove',
              child: Text('Tirar da agenda'),
            ),
          ],
        ),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => EditionScreen(
                gateway: widget.gateway,
                editionId: plan['editionId'] as String,
              ),
            ),
          );
          load();
        },
      ),
    );
  }

  Widget tab(String status, String empty) {
    final items = forStatus(status);
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (error != null) ...[
            Text(error!, key: const Key('agenda-error')),
            TextButton(onPressed: load, child: const Text('Tentar novamente')),
          ],
          if (loading) const Center(child: CircularProgressIndicator()),
          if (!loading && error == null && items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                empty,
                textAlign: TextAlign.center,
                key: Key('agenda-empty-$status'),
              ),
            ),
          for (final plan in items) tile(plan, status),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Minha agenda'),
        bottom: const TabBar(
          labelColor: runPassOrange,
          indicatorColor: runPassOrange,
          labelStyle: TextStyle(fontWeight: FontWeight.w900),
          unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w800),
          tabs: [
            Tab(key: Key('agenda-tab-wanted'), text: 'Desejadas'),
            Tab(key: Key('agenda-tab-registered'), text: 'Inscritas'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          children: [
            tab(
              'wanted',
              'Você ainda não marcou nenhuma corrida como "Quero correr".\nToque no coração dentro da corrida para guardá-la aqui.',
            ),
            tab(
              'registered',
              'Você ainda não marcou nenhuma corrida como inscrito.\nDentro da corrida, toque em "Inscrito" para vê-la aqui.',
            ),
          ],
        ),
      ),
    ),
  );
}
