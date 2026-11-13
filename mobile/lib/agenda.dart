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

const monthNamesPt = [
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
const weekdayLettersPt = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Dias do mês de `month` na grade de um calendário que começa no domingo: `null` nas células em branco.
List<DateTime?> monthCells(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  final days = DateTime(month.year, month.month + 1, 0).day;
  return [
    for (var i = 0; i < first.weekday % 7; i++) null,
    for (var d = 1; d <= days; d++) DateTime(month.year, month.month, d),
  ];
}

class _AgendaScreenState extends State<AgendaScreen> {
  List<Map<String, dynamic>> plans = [];

  /// Mês mostrado em cada aba (primeiro dia) e dia escolhido (AAAA-MM-DD). Sem escolha, o mês é o da próxima corrida.
  final Map<String, DateTime> months = {};
  final Map<String, String?> selectedDay = {};
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

  String dateOf(Map<String, dynamic> p) =>
      (p['edition'] as Map)['date'] as String;

  /// Mês inicial: o da próxima corrida; sem nenhuma por vir, o da mais recente; sem corrida, o de hoje.
  DateTime monthFor(String status) {
    final shown = months[status];
    if (shown != null) return shown;
    final items = forStatus(status);
    final today = DateTime.now();
    final date = items.isEmpty ? _iso(today) : dateOf(items.first);
    return DateTime(
      int.parse(date.substring(0, 4)),
      int.parse(date.substring(5, 7)),
    );
  }

  void moveMonth(String status, int delta) {
    final m = monthFor(status);
    setState(() {
      months[status] = DateTime(m.year, m.month + delta);
      selectedDay[status] = null;
    });
  }

  void pickDay(String status, String iso) => setState(() {
    selectedDay[status] = selectedDay[status] == iso ? null : iso;
  });

  Widget calendar(String status, List<Map<String, dynamic>> items) {
    final month = monthFor(status);
    final today = _iso(DateTime.now());
    final perDay = <String, int>{};
    for (final p in items) {
      perDay[dateOf(p)] = (perDay[dateOf(p)] ?? 0) + 1;
    }
    final cells = monthCells(month);
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final chosen = selectedDay[status];
    Widget cell(DateTime? day) {
      if (day == null) return const SizedBox(height: 44);
      final iso = _iso(day);
      final count = perDay[iso] ?? 0;
      final isToday = iso == today;
      final isChosen = iso == chosen;
      return Semantics(
        label: count == 0
            ? '${day.day} de ${monthNamesPt[day.month - 1]}'
            : '${day.day} de ${monthNamesPt[day.month - 1]}, $count corrida${count > 1 ? 's' : ''}',
        button: count > 0,
        child: InkWell(
          key: Key('agenda-day-$status-$iso'),
          borderRadius: BorderRadius.circular(10),
          onTap: count == 0 ? null : () => pickDay(status, iso),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: isChosen ? runPassOrange : null,
              borderRadius: BorderRadius.circular(10),
              border: isToday && !isChosen
                  ? Border.all(color: runPassOrange, width: 1.5)
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontWeight: count > 0 ? FontWeight.w900 : FontWeight.w500,
                    color: isChosen ? Colors.white : null,
                  ),
                ),
                const SizedBox(height: 2),
                if (count > 0)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < (count > 3 ? 3 : count); i++)
                        Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isChosen ? Colors.white : runPassOrange,
                          ),
                        ),
                    ],
                  )
                else
                  const SizedBox(height: 5),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      key: Key('agenda-calendar-$status'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  key: Key('agenda-prev-$status'),
                  tooltip: 'Mês anterior',
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: () => moveMonth(status, -1),
                ),
                Expanded(
                  child: Text(
                    '${monthNamesPt[month.month - 1]} de ${month.year}',
                    key: Key('agenda-month-$status'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  key: Key('agenda-next-$status'),
                  tooltip: 'Próximo mês',
                  icon: const Icon(Icons.chevron_right_rounded),
                  onPressed: () => moveMonth(status, 1),
                ),
              ],
            ),
            Row(
              children: [
                for (final letter in weekdayLettersPt)
                  Expanded(
                    child: Center(
                      child: Text(
                        letter,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var row = 0; row < cells.length ~/ 7; row++)
              Row(
                children: [
                  for (final day in cells.sublist(row * 7, row * 7 + 7))
                    Expanded(child: cell(day)),
                ],
              ),
          ],
        ),
      ),
    );
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
    final all = forStatus(status);
    final chosen = selectedDay[status];
    final items = chosen == null
        ? all
        : [
            for (final p in all)
              if (dateOf(p) == chosen) p,
          ];
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
          if (!loading) calendar(status, all),
          if (!loading && chosen != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Corridas em ${displayDate(chosen)}',
                      key: Key('agenda-day-title-$status'),
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  TextButton(
                    key: Key('agenda-clear-day-$status'),
                    onPressed: () => setState(() => selectedDay[status] = null),
                    child: const Text('Ver todas'),
                  ),
                ],
              ),
            ),
          if (!loading && error == null && all.isEmpty)
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
