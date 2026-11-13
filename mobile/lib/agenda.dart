import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'catalog_views.dart';
import 'edition_cards.dart';
import 'grid_columns.dart';
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

  /// Visualização das corridas (lista ou grade) e colunas da grade; ficam neste aparelho.
  static const _modeKey = 'agenda-view-mode';
  static const _columnsKey = 'agenda-grid-columns';
  CatalogViewMode viewMode = CatalogViewMode.list;
  int gridColumns = 2;

  @override
  void initState() {
    super.initState();
    load();
    loadViewPreferences();
  }

  Future<void> loadViewPreferences() async {
    final mode = await CatalogViewMode.read(_modeKey);
    final columns = await GridColumns.read(_columnsKey, fallback: 2);
    if (mounted) {
      setState(() {
        viewMode = mode;
        gridColumns = columns;
      });
    }
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

  /// Primeira corrida que ainda vai acontecer (hoje ou depois) nesta aba; nulo se não houver.
  String? nextRaceDate(String status) {
    final today = _iso(DateTime.now());
    for (final p in forStatus(status)) {
      if (dateOf(p).compareTo(today) >= 0) return dateOf(p);
    }
    return null;
  }

  /// Leva o calendário ao próximo mês que tem corrida (depois do que está na tela); no último, volta
  /// para a primeira que ainda vai acontecer.
  void goToNextRace(String status) {
    final first = nextRaceDate(status);
    if (first == null) return;
    final shown = monthFor(status);
    final today = _iso(DateTime.now());
    final shownKey = shown.year * 12 + shown.month;
    final upcoming = [
      for (final p in forStatus(status))
        if (dateOf(p).compareTo(today) >= 0) dateOf(p),
    ]..sort();
    final target = upcoming.firstWhere(
      (d) =>
          int.parse(d.substring(0, 4)) * 12 + int.parse(d.substring(5, 7)) >
          shownKey,
      orElse: () => first,
    );
    setState(() {
      months[status] = DateTime(
        int.parse(target.substring(0, 4)),
        int.parse(target.substring(5, 7)),
      );
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
      final registered = status == 'registered';
      // Círculo em volta do número: cheio = inscrita, só o contorno = desejada.
      final BoxDecoration circle = count > 0
          ? BoxDecoration(
              shape: BoxShape.circle,
              color: registered ? runPassOrange : null,
              border: registered
                  ? null
                  : Border.all(color: runPassOrange, width: 2.2),
            )
          : BoxDecoration(
              shape: BoxShape.circle,
              border: isToday
                  ? Border.all(color: context.muted, width: 1.2)
                  : null,
            );
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
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isChosen ? context.softFill : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: circle,
              child: Text(
                '${day.day}',
                style: TextStyle(
                  fontWeight: count > 0 ? FontWeight.w900 : FontWeight.w400,
                  color: count > 0 && registered
                      ? Colors.white
                      : (count == 0 ? context.muted : null),
                ),
              ),
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
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  key: Key('agenda-legend-$status'),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: status == 'registered' ? runPassOrange : null,
                    border: status == 'registered'
                        ? null
                        : Border.all(color: runPassOrange, width: 1.5),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    status == 'registered'
                        ? 'Inscrita (círculo cheio)'
                        : 'Desejada (círculo vazado)',
                    style: TextStyle(fontSize: 12, color: context.muted),
                  ),
                ),
                TextButton.icon(
                  key: Key('agenda-next-race-$status'),
                  onPressed: nextRaceDate(status) == null
                      ? null
                      : () => goToNextRace(status),
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  label: const Text('Próxima corrida'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> openPlan(Map<String, dynamic> plan) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditionScreen(
          gateway: widget.gateway,
          editionId: plan['editionId'] as String,
        ),
      ),
    );
    load();
  }

  /// Menu da corrida (inscrito/desejada/tirar), sobre a capa do cartão.
  Widget planMenu(Map<String, dynamic> plan, String status) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    child: PopupMenuButton<String>(
      key: Key('agenda-menu-${plan['editionId']}'),
      tooltip: 'Opções',
      iconSize: 20,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
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
        const PopupMenuItem(value: 'remove', child: Text('Tirar da agenda')),
      ],
    ),
  );

  /// Mesmo cartão da tela Corridas: em lista (largura toda) ou em grade.
  Widget tile(Map<String, dynamic> plan, String status) {
    final edition = {
      ...Map<String, dynamic>.from(plan['edition'] as Map),
      'id': plan['editionId'],
    };
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final date = edition['date'] as String;
    final passed = date.compareTo(today) < 0;
    final distances = [
      for (final d in (edition['distances'] as List? ?? const []))
        '${(d as Map)['kilometers']} km',
    ].join(' · ');
    final key = Key('agenda-${plan['editionId']}');
    if (viewMode == CatalogViewMode.grid) {
      return EditionGridCard(
        key: key,
        gateway: widget.gateway,
        edition: edition,
        columns: gridColumns,
        subtitle:
            '${displayDate(date)} · ${edition['city']}/${edition['state']}',
        shortDate: displayDate(date).substring(0, 5),
        onTap: () => openPlan(plan),
        overlay: planMenu(plan, status),
      );
    }
    return EditionListCard(
      key: key,
      gateway: widget.gateway,
      edition: edition,
      lines: [
        '${displayDate(date)} · ${edition['city']}/${edition['state']}',
        if (distances.isNotEmpty) distances,
        if (passed) 'Já aconteceu',
      ],
      onTap: () => openPlan(plan),
      overlay: planMenu(plan, status),
    );
  }

  Widget tab(String status, String empty) {
    final all = forStatus(status);
    final chosen = selectedDay[status];
    final month = monthFor(status);
    final monthPrefix =
        '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}';
    // Embaixo do calendário ficam só as corridas da agenda: as do dia escolhido ou, sem dia, as do mês.
    final items = [
      for (final p in all)
        if (chosen == null
            ? dateOf(p).startsWith(monthPrefix)
            : dateOf(p) == chosen)
          p,
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
          if (!loading && all.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      chosen != null
                          ? 'Corridas em ${displayDate(chosen)}'
                          : 'Da sua agenda em ${monthNamesPt[month.month - 1]} de ${month.year}',
                      key: Key('agenda-day-title-$status'),
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  if (chosen != null)
                    TextButton(
                      key: Key('agenda-clear-day-$status'),
                      onPressed: () =>
                          setState(() => selectedDay[status] = null),
                      child: const Text('Ver o mês'),
                    ),
                  CatalogViewMenu(
                    value: viewMode,
                    columns: gridColumns,
                    onChanged: (mode) {
                      setState(() => viewMode = mode);
                      mode.write(_modeKey);
                    },
                    onColumnsChanged: (n) {
                      setState(() => gridColumns = n);
                      GridColumns.write(_columnsKey, n);
                    },
                  ),
                ],
              ),
            ),
          if (!loading && error == null && all.isNotEmpty && items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Nenhuma corrida da sua agenda neste mês. Use as setas ou "Próxima corrida".',
                key: Key('agenda-month-empty-$status'),
                style: TextStyle(color: context.muted),
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
          if (viewMode == CatalogViewMode.grid && items.isNotEmpty)
            GridView.count(
              key: Key('agenda-grid-$status'),
              crossAxisCount: gridColumns,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: gridCardAspectRatio(gridColumns),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [for (final plan in items) tile(plan, status)],
            )
          else
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
            Tab(key: Key('agenda-tab-registered'), text: 'Inscritas'),
            Tab(key: Key('agenda-tab-wanted'), text: 'Desejadas'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          children: [
            tab(
              'registered',
              'Você ainda não marcou nenhuma corrida como inscrito.\nDentro da corrida, toque em "Inscrito" para vê-la aqui.',
            ),
            tab(
              'wanted',
              'Você ainda não marcou nenhuma corrida como "Quero correr".\nToque no coração dentro da corrida para guardá-la aqui.',
            ),
          ],
        ),
      ),
    ),
  );
}
