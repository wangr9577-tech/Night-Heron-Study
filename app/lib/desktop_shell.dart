import 'package:flutter/material.dart';

import 'ai_settings.dart';
import 'focus_page.dart';
import 'local_growth_page.dart';
import 'local_home.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  int selected = 0;
  static const destinations = [
    ('本机课程', Icons.menu_book_outlined),
    ('专注与统计', Icons.timer_outlined),
    ('宠物', Icons.pets_outlined),
    ('AI 模型设置', Icons.settings_outlined),
    ('AI 问答', Icons.chat_bubble_outline),
  ];
  Widget get page => switch (selected) {
    1 => const FocusPage(),
    2 => const LocalGrowthPage(),
    3 => const AiSettingsPage(),
    4 => const LocalAsk(),
    _ => const LocalHome(),
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      if (size.maxWidth < 840) return const LocalHome();
      return Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 216,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: 26,
                        horizontal: 12,
                      ),
                      child: Text(
                        '啄知 AI\n桌面学习空间',
                        style: TextStyle(
                          fontSize: 21,
                          height: 1.6,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (var i = 0; i < destinations.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          selected: selected == i,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          selectedTileColor: Theme.of(context)
                              .colorScheme
                              .secondaryContainer,
                          leading: Icon(destinations[i].$2),
                          title: Text(destinations[i].$1),
                          onTap: () => setState(() => selected = i),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '资料与学习记录存于本机。AI 按你配置的服务调用。',
                        style: TextStyle(height: 1.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: page,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
