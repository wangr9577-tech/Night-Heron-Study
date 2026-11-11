part of 'main.dart';

class AdvancedGraphPage extends StatefulWidget {
  final String courseId;
  const AdvancedGraphPage({super.key, required this.courseId});
  @override
  State<AdvancedGraphPage> createState() => _AdvancedGraphState();
}

class _AdvancedGraphState extends State<AdvancedGraphPage> {
  String get prefix => '/courses/${widget.courseId}';

  Future<void> remove(String path, String label, VoidCallback reload) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除$label？'),
        content: Text(
          label == '知识点' ? '删除知识点会同时删除与它关联的关系；已有业务引用的知识点不可删除。' : '确认删除这条关系？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await api.request('DELETE', '$prefix/knowledge/$path');
      reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> editNode(dynamic node, VoidCallback reload) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => GraphNodeDialog(courseId: widget.courseId, node: node),
    );
    if (data == null || !mounted) return;
    try {
      if (node == null) {
        await api.post('$prefix/knowledge/concepts', data);
      } else {
        await api.request(
          'PATCH',
          '$prefix/knowledge/concepts/${val(node['id'])}',
          data,
        );
      }
      reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> editEdge(
    List<dynamic> nodes,
    dynamic edge,
    VoidCallback reload,
  ) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => GraphEdgeDialog(nodes: nodes, edge: edge),
    );
    if (data == null || !mounted) return;
    if (edge != null &&
        data['from_id'] == edge['from_id'] &&
        data['to_id'] == edge['to_id'] &&
        data['type'] == edge['type'])
      return;
    try {
      if (edge == null) {
        await api.post('$prefix/knowledge/edges', data);
      } else {
        await api.request(
          'PATCH',
          '$prefix/knowledge/edges/${val(edge['id'])}',
          data,
        );
      }
      reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('知识图谱')),
    body: RemoteView(
      load: () async => Future.wait([
        api.get('$prefix/knowledge'),
        api.get('$prefix/mastery'),
      ]),
      builder: (data, reload) {
        final nodes = items(data[0], 'nodes'), edges = items(data[0], 'edges');
        final mastery = items(data[1]);
        String title(dynamic id) => val(
          nodes.firstWhere(
            (n) => n['id'] == id,
            orElse: () => {'title': id},
          )['title'],
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('关系来自课程资料或人工添加；这里展示你的课程知识图谱。'),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => editNode(null, reload),
                  icon: const Icon(Icons.add),
                  label: const Text('添加知识点'),
                ),
                FilledButton.tonalIcon(
                  onPressed: nodes.length < 2
                      ? null
                      : () => editEdge(nodes, null, reload),
                  icon: const Icon(Icons.add_link),
                  label: const Text('添加关系'),
                ),
              ],
            ),
            Text(
              '知识点（${nodes.length}）',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (nodes.isEmpty) const Text('暂无知识点，可导入资料后提取或手动添加。'),
            ...nodes.map(
              (n) => Card(
                child: ExpansionTile(
                  title: Text(val(n['title'])),
                  subtitle: Text(
                    [
                      val(n['description']),
                      mastery.any((m) => m['concept_id'] == n['id'])
                          ? '掌握度 ${(100 * ((mastery.firstWhere((m) => m['concept_id'] == n['id'])['mastery'] as num?)?.toDouble() ?? 0)).round()}%'
                          : '暂无作答证据',
                    ].where((text) => text.isNotEmpty).join(' · '),
                  ),
                  children: [
                    for (final ref in items(n, 'source_refs'))
                      ListTile(
                        title: Text('第 ${val(ref['page'])} 页 · 来源'),
                        subtitle: ReadingText(
                          val(ref['quote']),
                          selectable: true,
                        ),
                      ),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => editNode(n, reload),
                          child: const Text('编辑知识点'),
                        ),
                        TextButton(
                          onPressed: () =>
                              remove('concepts/${val(n['id'])}', '知识点', reload),
                          child: const Text('删除知识点'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '知识关系（${edges.length}）',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (edges.isEmpty) const Text('暂无关系；不会自动推断不存在的关联。'),
            ...edges.map(
              (edge) => Card(
                child: ListTile(
                  title: Text(
                    '${title(edge['from_id'])} ${edge['type'] == 'prerequisite' ? '→' : '↔'} ${title(edge['to_id'])}',
                  ),
                  subtitle: Text(
                    edge['type'] == 'prerequisite' ? '前置 → 后续' : '相关',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'edit'
                        ? editEdge(nodes, edge, reload)
                        : remove('edges/${val(edge['id'])}', '关系', reload),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑关系')),
                      PopupMenuItem(value: 'delete', child: Text('删除关系')),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class GraphNodeDialog extends StatefulWidget {
  final String courseId;
  final dynamic node;
  const GraphNodeDialog({super.key, required this.courseId, this.node});
  @override
  State<GraphNodeDialog> createState() => _GraphNodeDialogState();
}

class _GraphNodeDialogState extends State<GraphNodeDialog> {
  late final title = TextEditingController(text: val(widget.node?['title']));
  late final description = TextEditingController(
    text: val(widget.node?['description']),
  );
  List<dynamic>? materials, chunks;
  String? materialId, chunkId, error;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    if (widget.node == null) loadMaterials();
  }

  Future<void> loadMaterials() async {
    try {
      final data = await api.get('/courses/${widget.courseId}/materials');
      if (mounted)
        setState(
          () =>
              materials = items(data)
                  .where((m) => m['status'] == 'ready')
                  .toList(),
        );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> loadChunks(String value) async {
    setState(() {
      materialId = value;
      chunks = null;
      chunkId = null;
      loading = true;
      error = null;
    });
    try {
      final data = await api.get(
        '/courses/${widget.courseId}/materials/$value',
      );
      if (mounted && materialId == value)
        setState(() {
          chunks = items(data, 'chunks');
          loading = false;
        });
    } catch (e) {
      if (mounted && materialId == value)
        setState(() {
          error = e.toString();
          loading = false;
        });
    }
  }

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  void submit() {
    if (title.text.trim().isEmpty) {
      showError(context, '请填写知识点名称');
      return;
    }
    final data = <String, dynamic>{
      'title': title.text.trim(),
      'description': description.text.trim(),
    };
    if (widget.node == null) {
      if (materialId == null || chunkId == null) {
        showError(context, '请选择已解析资料中的来源文字');
        return;
      }
      final chunk = chunks!.firstWhere((c) => c['chunk_id'] == chunkId);
      data['source_refs'] = [
        {
          'material_id': materialId,
          'chunk_id': chunkId,
          'page': chunk['page'],
          'quote': chunk['text'],
          'start': chunk['start'],
          'end': chunk['end'],
        },
      ];
    }
    Navigator.pop(context, data);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.node == null ? '添加知识点' : '编辑知识点'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          TextField(
            controller: description,
            maxLines: 3,
            maxLength: 5000,
            decoration: const InputDecoration(labelText: '描述'),
          ),
          if (widget.node == null) ...[
            const Text('请选择真实资料片段作为来源；请先完成资料校对。'),
            if (error != null) Text(error!),
            if (materials == null && error == null)
              const CircularProgressIndicator(),
            if (materials?.isEmpty == true) const Text('没有已解析资料，请先导入资料。'),
            if (materials?.isNotEmpty == true)
              DropdownButtonFormField<String>(
                initialValue: materialId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '资料'),
                items: materials!
                    .map(
                      (m) => DropdownMenuItem<String>(
                        value: val(m['id']),
                        child: Text(
                          val(m['filename']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) loadChunks(v);
                },
              ),
            if (loading) const CircularProgressIndicator(),
            if (chunks?.isEmpty == true) const Text('此资料没有可用文字。'),
            if (chunks?.isNotEmpty == true)
              DropdownButtonFormField<String>(
                key: ValueKey(materialId),
                initialValue: chunkId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '来源片段'),
                items: chunks!
                    .map(
                      (c) => DropdownMenuItem<String>(
                        value: val(c['chunk_id']),
                        child: Text(
                          '第 ${val(c['page'])} 页 · ${val(c['text'])}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => chunkId = v),
              ),
          ] else
            const Text('保留已有来源引用。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('保存')),
    ],
  );
}

class GraphEdgeDialog extends StatefulWidget {
  final List<dynamic> nodes;
  final dynamic edge;
  const GraphEdgeDialog({super.key, required this.nodes, this.edge});
  @override
  State<GraphEdgeDialog> createState() => _GraphEdgeDialogState();
}

class _GraphEdgeDialogState extends State<GraphEdgeDialog> {
  late String from = val(
    widget.edge?['from_id'],
    val(widget.nodes.first['id']),
  );
  late String to = val(widget.edge?['to_id'], val(widget.nodes[1]['id']));
  late String kind = val(widget.edge?['type'], 'prerequisite');
  @override
  Widget build(BuildContext context) {
    List<DropdownMenuItem<String>> choices() => widget.nodes
        .map(
          (n) => DropdownMenuItem<String>(
            value: val(n['id']),
            child: Text(val(n['title']), overflow: TextOverflow.ellipsis),
          ),
        )
        .toList();
    return AlertDialog(
      title: Text(widget.edge == null ? '添加关系' : '编辑关系'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: from,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '起点（前置知识）'),
              items: choices(),
              onChanged: (v) => setState(() => from = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: const InputDecoration(labelText: '关系类型'),
              items: const [
                DropdownMenuItem(value: 'prerequisite', child: Text('前置关系')),
                DropdownMenuItem(value: 'related', child: Text('相关关系')),
              ],
              onChanged: (v) => setState(() => kind = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: to,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '终点（后续知识）'),
              items: choices(),
              onChanged: (v) => setState(() => to = v!),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (from == to) {
              showError(context, '不能关联同一个知识点');
              return;
            }
            Navigator.pop(context, {
              'from_id': from,
              'to_id': to,
              'type': kind,
            });
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
