import 'package:flutter/material.dart';

import 'focus_store.dart';
import 'pet_avatar.dart';

class LocalGrowthPage extends StatefulWidget {
  const LocalGrowthPage({super.key});
  @override
  State<LocalGrowthPage> createState() => _LocalGrowthPageState();
}

class _LocalGrowthPageState extends State<LocalGrowthPage> {
  FocusStore? store;
  Map<String, int>? data;
  Map<String, Object?>? pet;
  final petName = TextEditingController();
  String avatarKey = 'bird_1';
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final opened = await FocusStore.open();
      if (!mounted) {
        await opened.close();
        return;
      }
      store = opened;
      final active = await opened.active();
      if (active != null) await opened.complete(active['id'] as int);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => error = '无法读取成长记录：$e');
    }
  }

  Future<void> _refresh() async {
    final value = await store!.growth();
    final currentPet = await store!.pet();
    if (mounted)
      setState(() {
        data = value;
        pet = currentPet;
        petName.text = currentPet['name'] as String;
        avatarKey = currentPet['avatar_key'] as String;
      });
  }

  Future<void> _action(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      await _refresh();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    store?.close();
    petName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('宠物')),
    body: data == null
        ? Center(child: Text(error ?? '正在读取成长记录…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(child: MiniPetAvatar(avatarKey: avatarKey)),
              Center(
                child: Text(
                  pet?['name'] as String? ?? '小啄',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Center(
                child: Text(
                  '等级 ${1 + data!['exp']! ~/ 100} · 经验 ${data!['exp']}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: petName,
                maxLength: 20,
                decoration: const InputDecoration(labelText: '宠物名称'),
              ),
              Wrap(
                spacing: 8,
                children:
                    const [
                          ('bird_1', '暖黄'),
                          ('bird_mint', '薄荷'),
                          ('bird_blue', '晴蓝'),
                          ('bird_rose', '樱粉'),
                        ]
                        .map(
                          (pair) => ChoiceChip(
                            label: Text(pair.$2),
                            selected: avatarKey == pair.$1,
                            onSelected: busy
                                ? null
                                : (_) => setState(() => avatarKey = pair.$1),
                          ),
                        )
                        .toList(),
              ),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _action(
                        () => store!.customizePet(petName.text, avatarKey),
                      ),
                child: const Text('保存名字与配色'),
              ),
              Text('本机积分：${data!['balance']}'),
              const Text('完成专注，每分钟获得 1 积分。积分与成长仅保存在此设备。'),
              ListTile(
                title: const Text('谷粒'),
                subtitle: Text('5 积分 · 背包 ${data!['seed']}'),
                trailing: FilledButton(
                  onPressed: busy || data!['balance']! < 5
                      ? null
                      : () => _action(store!.buySeed),
                  child: const Text('兑换'),
                ),
              ),
              FilledButton.tonal(
                onPressed: busy || data!['seed']! == 0
                    ? null
                    : () => _action(store!.feedSeed),
                child: const Text('投喂谷粒 · 经验 +5'),
              ),
            ],
          ),
  );
}
