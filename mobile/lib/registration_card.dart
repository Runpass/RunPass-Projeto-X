import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'runpass_theme.dart';

/// Letra do genero para a ficha ('F'/'M'); 'undisclosed' e sem genero nao aparecem.
String? genderLetter(String? gender) => switch (gender) {
  'female' => 'F',
  'male' => 'M',
  _ => null,
};

/// Faixa etaria em intervalos de 5 anos (mesma regra do protótipo), cobrindo todas as idades.
String? ageBucket(DateTime? birthDate) {
  if (birthDate == null) return null;
  final now = DateTime.now();
  var age = now.year - birthDate.year;
  if (now.month < birthDate.month ||
      (now.month == birthDate.month && now.day < birthDate.day)) {
    age -= 1;
  }
  if (age < 18) return 'Menor de 18';
  if (age < 80) {
    final start = (age ~/ 5) * 5;
    return '$start-${start + 4}';
  }
  return '80+';
}

String _pad2(int n) => n.toString().padLeft(2, '0');

String formatBirthLabel(DateTime? birthDate) {
  if (birthDate == null) return '';
  return '${_pad2(birthDate.day)}/${_pad2(birthDate.month)}/${birthDate.year}';
}

/// Barra de progresso de 4 segmentos do cadastro (passo atual em laranja).
class RegistrationProgress extends StatelessWidget {
  final int step;
  const RegistrationProgress({super.key, required this.step});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 1; i <= 4; i++) ...[
        if (i > 1) const SizedBox(width: 7),
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 6,
            decoration: BoxDecoration(
              color: i <= step ? runPassOrange : context.track,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ],
    ],
  );
}

/// Ficha de inscrição do corredor: se preenche conforme os dados chegam, nos passos do
/// cadastro, e aparece completa na celebração final.
class RegistrationCard extends StatelessWidget {
  final String? displayName;
  final String? username;
  final String? cityLabel;
  final DateTime? birthDate;
  final String? gender;
  final String? registrationCode;
  final Uint8List? photo;
  final DateTime inscriptionDate;
  const RegistrationCard({
    super.key,
    this.displayName,
    this.username,
    this.cityLabel,
    this.birthDate,
    this.gender,
    this.registrationCode,
    this.photo,
    required this.inscriptionDate,
  });

  static const _monthAbbr = [
    'JAN',
    'FEV',
    'MAR',
    'ABR',
    'MAI',
    'JUN',
    'JUL',
    'AGO',
    'SET',
    'OUT',
    'NOV',
    'DEZ',
  ];

  @override
  Widget build(BuildContext context) {
    final name = displayName?.trim();
    final hasName = name != null && name.isNotEmpty;
    final letter = genderLetter(gender);
    final bucket = ageBucket(birthDate);
    final category = [?letter, ?bucket].join(' - ');
    final initials = hasName
        ? name
              .split(RegExp(r'\s+'))
              .take(2)
              .map((w) => w[0].toUpperCase())
              .join()
        : '';
    final dateText =
        '${inscriptionDate.day.toString().padLeft(2, '0')} '
        '${_monthAbbr[inscriptionDate.month - 1]} ${inscriptionDate.year}';

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .1),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 110,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [runPassOrange, runPassGold],
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.white.withValues(alpha: .2),
                    backgroundImage: photo == null ? null : MemoryImage(photo!),
                    child: photo != null
                        ? null
                        : (initials.isNotEmpty
                              ? Text(
                                  initials,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 20,
                                  ),
                                )
                              : const Icon(
                                  Icons.person_outline,
                                  color: Colors.white,
                                )),
                  ),
                  Column(
                    children: [
                      const Text(
                        'Nº INSCRIÇÃO',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        registrationCode ?? '•••••',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Opacity(
                          opacity: .5,
                          child: Image.asset(
                            context.isDark
                                ? 'assets/brand/logo-dark.png'
                                : 'assets/brand/logo-light.png',
                            height: 16,
                            fit: BoxFit.contain,
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              dateText,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: context.muted,
                              ),
                            ),
                            Text(
                              (cityLabel ?? '— cidade').toUpperCase(),
                              style: const TextStyle(
                                fontSize: 7,
                                fontWeight: FontWeight.w800,
                                letterSpacing: .3,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      hasName ? name : 'Seu nome aqui',
                      maxLines: 2,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: hasName ? null : context.muted,
                      ),
                    ),
                    Text(
                      username != null && username!.isNotEmpty
                          ? '@$username'
                          : '@usuario',
                      style: TextStyle(fontSize: 12.5, color: context.muted),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'NASCIMENTO',
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  color: context.archivedText,
                                ),
                              ),
                              Text(
                                birthDate == null
                                    ? '—'
                                    : formatBirthLabel(birthDate),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          category.isEmpty ? '—' : category,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
