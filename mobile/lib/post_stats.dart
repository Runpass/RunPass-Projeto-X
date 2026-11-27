import 'package:flutter/material.dart';

/// Ícones dos números da corrida. Os mesmos no feed, na prévia e na imagem de compartilhar.
const IconData statDistanceIcon = Icons.directions_run;
const IconData statTimeIcon = Icons.timer_outlined;
const IconData statPaceIcon = Icons.speed;
const IconData statPlacementIcon = Icons.emoji_events_outlined;

/// O que aparece no lugar de um número que a pessoa não informou.
const String statEmpty = '--';

/// Distância, tempo e pace: os três ícones aparecem sempre, com "--" quando falta o dado, para a
/// publicação manter sempre o mesmo padrão. A colocação só aparece quando existe.
class PostStats extends StatelessWidget {
  final String? distance, time, pace, placement;
  const PostStats({
    super.key,
    this.distance,
    this.time,
    this.pace,
    this.placement,
  });

  Widget _item(
    BuildContext context,
    Key key,
    IconData icon,
    String? value,
    String label,
  ) => Expanded(
    key: key,
    child: Row(
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value ?? statEmpty,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _item(
        context,
        const Key('post-stat-distance'),
        statDistanceIcon,
        distance,
        'Distância',
      ),
      _item(context, const Key('post-stat-time'), statTimeIcon, time, 'Tempo'),
      _item(context, const Key('post-stat-pace'), statPaceIcon, pace, 'Pace'),
      if (placement != null)
        _item(
          context,
          const Key('post-stat-placement'),
          statPlacementIcon,
          placement,
          'Colocação',
        ),
    ],
  );
}
