import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agenda.dart';
import 'runpass_theme.dart';

/// Como a lista de corridas é mostrada: cartões em lista, grade ou calendário.
enum CatalogViewMode {
  list('Lista', Icons.view_agenda_outlined),
  grid('Grade', Icons.grid_view_rounded),
  calendar('Calendário', Icons.calendar_month_rounded);

  final String label;
  final IconData icon;
  const CatalogViewMode(this.label, this.icon);

  static const storageKey = 'catalog-view-mode';

  static Future<CatalogViewMode> read() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        storageKey,
      );
      return values.firstWhere((m) => m.name == saved, orElse: () => list);
    } on Object {
      return list;
    }
  }

  Future<void> write() async {
    try {
      await (await SharedPreferences.getInstance()).setString(storageKey, name);
    } on Object {
      // Sem armazenamento: vale até fechar a tela.
    }
  }
}

/// Menu para escolher a visualização (lista, grade ou calendário).
class CatalogViewMenu extends StatelessWidget {
  final CatalogViewMode value;
  final ValueChanged<CatalogViewMode> onChanged;
  const CatalogViewMenu({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<CatalogViewMode>(
    key: const Key('catalog-view-mode'),
    tooltip: 'Modo de visualização',
    icon: Icon(value.icon),
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final mode in CatalogViewMode.values)
        CheckedPopupMenuItem<CatalogViewMode>(
          key: Key('catalog-view-${mode.name}'),
          value: mode,
          checked: mode == value,
          child: Row(
            children: [
              Icon(mode.icon, size: 20),
              const SizedBox(width: 10),
              Text(mode.label),
            ],
          ),
        ),
    ],
  );
}

/// Data AAAA-MM-DD de uma corrida; nulo se a data não for uma data de calendário válida
/// (essa corrida simplesmente não aparece no calendário, nunca em outro dia).
DateTime? editionDay(Map<String, dynamic> edition) {
  final value = edition['date'];
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.toIso8601String().substring(0, 10) == value
      ? DateTime(parsed.year, parsed.month, parsed.day)
      : null;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Calendário mensal: cada corrida aparece só no dia da sua data. Tocar em um dia mostra as
/// corridas dele; sem dia escolhido, mostra as do mês.
class CatalogCalendar extends StatefulWidget {
  final List<Map<String, dynamic>> editions;
  final Widget Function(Map<String, dynamic> edition) cardBuilder;
  const CatalogCalendar({
    super.key,
    required this.editions,
    required this.cardBuilder,
  });

  @override
  State<CatalogCalendar> createState() => _CatalogCalendarState();
}

class _CatalogCalendarState extends State<CatalogCalendar> {
  DateTime? month;
  String? chosen;

  /// Mês inicial: o de hoje se tiver corrida; senão o da corrida mais próxima de hoje.
  DateTime initialMonth() {
    final now = DateTime.now();
    final days = [
      for (final e in widget.editions)
        if (editionDay(e) != null) editionDay(e)!,
    ];
    if (days.isEmpty) return DateTime(now.year, now.month);
    if (days.any((d) => d.year == now.year && d.month == now.month)) {
      return DateTime(now.year, now.month);
    }
    days.sort(
      (a, b) => a
          .difference(now)
          .inDays
          .abs()
          .compareTo(b.difference(now).inDays.abs()),
    );
    return DateTime(days.first.year, days.first.month);
  }

  void move(int delta) {
    final m = month ?? initialMonth();
    setState(() {
      month = DateTime(m.year, m.month + delta);
      chosen = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = month ?? initialMonth();
    final today = _iso(DateTime.now());
    final byDay = <String, List<Map<String, dynamic>>>{};
    for (final e in widget.editions) {
      final day = editionDay(e);
      if (day != null) (byDay[_iso(day)] ??= []).add(e);
    }
    final cells = monthCells(shown);
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final monthPrefix =
        '${shown.year.toString().padLeft(4, '0')}-${shown.month.toString().padLeft(2, '0')}';
    final listed = chosen != null
        ? (byDay[chosen] ?? const <Map<String, dynamic>>[])
        : [
            for (final entry
                in (byDay.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              if (entry.key.startsWith(monthPrefix)) ...entry.value,
          ];

    Widget cell(DateTime? day) {
      if (day == null) return const SizedBox(height: 46);
      final iso = _iso(day);
      final count = byDay[iso]?.length ?? 0;
      final isChosen = iso == chosen;
      final isToday = iso == today;
      return Semantics(
        button: count > 0,
        label:
            '${day.day} de ${monthNamesPt[day.month - 1]}${count > 0 ? ', $count corrida${count > 1 ? 's' : ''}' : ''}',
        child: InkWell(
          key: Key('catalog-day-$iso'),
          borderRadius: BorderRadius.circular(10),
          onTap: count == 0
              ? null
              : () => setState(() => chosen = isChosen ? null : iso),
          child: Container(
            height: 46,
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
                    fontWeight: count > 0 ? FontWeight.w900 : FontWeight.w400,
                    color: isChosen
                        ? Colors.white
                        : (count == 0 ? context.muted : null),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          key: const Key('catalog-calendar'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const Key('catalog-cal-prev'),
                      tooltip: 'Mês anterior',
                      icon: const Icon(Icons.chevron_left_rounded),
                      onPressed: () => move(-1),
                    ),
                    Expanded(
                      child: Text(
                        '${monthNamesPt[shown.month - 1]} de ${shown.year}',
                        key: const Key('catalog-cal-month'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('catalog-cal-next'),
                      tooltip: 'Próximo mês',
                      icon: const Icon(Icons.chevron_right_rounded),
                      onPressed: () => move(1),
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
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: context.muted,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                for (var row = 0; row < cells.length; row += 7)
                  Row(
                    children: [
                      for (final day in cells.sublist(row, row + 7))
                        Expanded(child: cell(day)),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          chosen != null
              ? '${int.parse(chosen!.substring(8))} de ${monthNamesPt[int.parse(chosen!.substring(5, 7)) - 1]}'
              : 'Corridas de ${monthNamesPt[shown.month - 1]}',
          key: const Key('catalog-cal-heading'),
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const SizedBox(height: 8),
        if (listed.isEmpty)
          Text(
            'Nenhuma corrida neste mês.',
            key: const Key('catalog-cal-empty'),
            style: TextStyle(color: context.muted),
          )
        else
          for (final e in listed) widget.cardBuilder(e),
      ],
    );
  }
}
