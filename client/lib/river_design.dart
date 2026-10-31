import 'package:flutter/material.dart';

const riverAccent = Color(0xff4059c9);
const riverInk = Color(0xff202735);
const riverMuted = Color(0xff6b7280);
const riverBorder = Color(0xffe4e7ee);
const riverCanvas = Color(0xfff8f9fc);

ThemeData riverTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: riverAccent,
    primary: riverAccent,
    surface: Colors.white,
    onSurface: riverInk,
    onSurfaceVariant: riverMuted,
    outlineVariant: riverBorder,
  ),
  scaffoldBackgroundColor: riverCanvas,
  textTheme: const TextTheme(
    headlineMedium: TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w700,
      letterSpacing: -.8,
      color: riverInk,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -.4,
      color: riverInk,
    ),
    titleMedium: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: riverInk,
    ),
    bodyMedium: TextStyle(fontSize: 14, color: riverInk),
    bodySmall: TextStyle(fontSize: 12, color: riverMuted),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    scrolledUnderElevation: 0,
    titleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: riverInk,
    ),
  ),
  dividerTheme: const DividerThemeData(
    color: riverBorder,
    thickness: 1,
    space: 1,
  ),
  cardTheme: CardThemeData(
    elevation: 0,
    color: Colors.white,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: riverBorder),
    ),
  ),
  listTileTheme: const ListTileThemeData(
    dense: true,
    minTileHeight: 48,
    horizontalTitleGap: 10,
    minLeadingWidth: 24,
    selectedTileColor: Color(0xffe9edfc),
    selectedColor: riverAccent,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: const BorderSide(color: riverBorder),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: riverCanvas,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: riverBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: riverBorder),
    ),
  ),
);

const riverDestinations = [
  (
    name: 'Chats',
    icon: Icons.chat_bubble_outline_rounded,
    description: 'Friends & calls',
  ),
  (
    name: 'Communities',
    icon: Icons.workspaces_outline,
    description: 'Rooms & people',
  ),
  (name: 'Forums', icon: Icons.forum_outlined, description: 'Topics & replies'),
  (name: 'Posts', icon: Icons.article_outlined, description: 'Read & publish'),
  (name: 'Matrix', icon: Icons.hub_outlined, description: 'Beyond River'),
];

class RiverAvatar extends StatelessWidget {
  const RiverAvatar({super.key, required this.name, this.icon, this.size = 34});
  final String name;
  final IconData? icon;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0xffe9edfc),
      borderRadius: BorderRadius.circular(size * .28),
    ),
    alignment: Alignment.center,
    child: icon != null
        ? Icon(icon, size: size * .5, color: riverAccent)
        : Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: TextStyle(
              fontSize: size * .4,
              fontWeight: FontWeight.w700,
              color: riverAccent,
            ),
          ),
  );
}

class RiverEmptyState extends StatelessWidget {
  const RiverEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RiverAvatar(name: '', icon: icon, size: 48),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(color: riverMuted, height: 1.5),
        ),
      ],
    ),
  );
}
