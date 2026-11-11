part of 'main.dart';

class PetCustomizationPage extends StatefulWidget {
  final dynamic pet;
  const PetCustomizationPage({super.key, required this.pet});
  @override
  State<PetCustomizationPage> createState() => _PetCustomizationState();
}

class _PetCustomizationState extends State<PetCustomizationPage> {
  late final TextEditingController name;
  late String avatarKey;
  Uint8List? sprite;
  bool busy = false, generationConfigured = false;
  String? notice;
  String get id => val(widget.pet['pet_id']);
  String get path => '/companion/pets/$id/sprite';

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: val(widget.pet['name']));
    avatarKey = val(widget.pet['avatar_key'], 'bird_1');
    load();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<bool> load() async {
    var loaded = false;
    try {
      final response = await api.client
          .get(api.uri(path), headers: {'Authorization': 'Bearer ${api.token}'})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        loaded = true;
        if (mounted) setState(() => sprite = response.bodyBytes);
      } else if (response.statusCode == 404) {
        if (mounted) setState(() => sprite = null);
      } else {
        if (mounted) setState(() => notice = '自定义形象暂时无法读取，请稍后重试。');
      }
    } catch (_) {
      if (mounted) setState(() => notice = '自定义形象暂时无法读取，已显示内置形象。');
    }
    try {
      final value = await api.get('/companion/sprite-capabilities');
      if (mounted)
        setState(
          () => generationConfigured = value['generation_configured'] == true,
        );
    } catch (_) {
      if (mounted) setState(() => generationConfigured = false);
    }
    return loaded;
  }

  Future<void> work(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(() => notice = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) throw Exception('请填写宠物名称');
    await api.request('PATCH', '/companion/pets/$id', {
      'name': name.text.trim(),
      'avatar_key': avatarKey,
    });
    if (mounted) setState(() => notice = '名字和内置配色已保存。');
  }

  Future<void> upload() async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'webp'],
      withData: true,
    );
    if (selection == null) return;
    final file = selection.files.single;
    if (file.bytes == null || file.size > 8 * 1024 * 1024)
      throw Exception('请选择不超过 8 MB 的 PNG 或 WebP 图集。');
    final request = http.MultipartRequest('PUT', api.uri(path));
    request.headers['Authorization'] = 'Bearer ${api.token}';
    request.files.add(
      http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name),
    );
    final response = await http.Response.fromStream(
      await api.client.send(request).timeout(const Duration(seconds: 45)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {}
      throw Exception(data is Map ? (data['detail'] ?? '图集上传失败') : '图集上传失败');
    }
    if (!await load()) throw Exception('图集已保存，但暂时无法重新读取；请稍后重试。');
    if (mounted) setState(() => notice = '图集已保存。');
  }

  Future<void> generate() async {
    final description = await inputDialog(context, '描述你的宠物', '例如：戴蓝围巾的夜鹭');
    if (description == null || description.trim().isEmpty) return;
    final response = await api.client
        .post(
          api.uri('$path/generate'),
          headers: {
            'Authorization': 'Bearer ${api.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'description': description.trim()}),
        )
        .timeout(const Duration(seconds: 180));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {}
      throw Exception(data is Map ? (data['detail'] ?? '生成失败') : '生成失败');
    }
    if (!await load()) throw Exception('生成已提交，但暂时无法读取结果；请稍后重试。');
    if (mounted) setState(() => notice = '新形象已生成并保存。');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('自定义宠物')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: MiniPetAvatar(
            avatarKey: avatarKey,
            spriteBytes: sprite,
            size: 160,
          ),
        ),
        TextField(
          controller: name,
          maxLength: 50,
          decoration: const InputDecoration(labelText: '宠物名称'),
        ),
        const SizedBox(height: 12),
        const Text('内置配色'),
        Wrap(
          spacing: 8,
          children: [
            for (final pair in const [
              ('bird_1', '暖黄'),
              ('bird_mint', '薄荷'),
              ('bird_blue', '晴蓝'),
              ('bird_rose', '樱粉'),
            ])
              ChoiceChip(
                label: Text(pair.$2),
                selected: avatarKey == pair.$1,
                onSelected: busy
                    ? null
                    : (_) => setState(() => avatarKey = pair.$1),
              ),
          ],
        ),
        if (sprite != null) const Text('当前使用自定义图集；移除图集后显示所选内置配色。'),
        FilledButton(
          onPressed: busy ? null : () => work(save),
          child: const Text('保存名字与配色'),
        ),
        const Divider(height: 32),
        const Text('自定义动态形象', style: TextStyle(fontWeight: FontWeight.bold)),
        const ReadingText(
          '可上传透明 PNG 或 WebP 帧图集：8 列，每格 192 × 208 像素，共 9 或 11 行，文件不超过 8 MB。',
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : () => work(upload),
          icon: const Icon(Icons.upload_file),
          label: const Text('上传宠物图集'),
        ),
        if (sprite != null)
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('移除自定义图集？'),
                        content: const Text('服务器上的图集会被删除，请先保存需要保留的原文件。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('移除'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true)
                      await work(() async {
                        await api.request('DELETE', path);
                        await load();
                        if (mounted) setState(() => notice = '已移除图集，恢复内置形象。');
                      });
                  },
            child: const Text('移除自定义图集'),
          ),
        OutlinedButton.icon(
          onPressed: busy || !generationConfigured
              ? null
              : () => work(generate),
          icon: const Icon(Icons.auto_awesome),
          label: const Text('用 AI 生成图集'),
        ),
        Text(
          generationConfigured
              ? '服务已配置；生成可能需要一些时间。'
              : '图集生成服务尚未配置，可先使用内置形象或上传图集。',
        ),
        if (busy) const Center(child: CircularProgressIndicator()),
        if (notice != null) ReadingText(notice!),
      ],
    ),
  );
}
