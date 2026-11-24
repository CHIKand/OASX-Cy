// 编排页：编排表、序列设置、控制按钮和运行面板，布局按规格 §8.1。
//
// 数据都在 OrchestraController（每个实例一个，以实例名作 tag），页面只负责显示，并把编辑交给它：
// - 页面显示时轮询，离开或换到别的实例时停止；控制器留着，回到本页时未保存的修改还在。
// - 没有未保存的修改时，editor、draft 随每次轮询整个换掉，所以构建和回调都从控制器现取，不留引用。
// - 改完草稿调 edited()，它每次都换一份新的 errors。dirty 只在第一次编辑时通知，
//   所以页面靠 bundle（每次轮询换新）和 errors 重建。
// - 实例进程在不在运行另取自总览用的 ScriptService：序列在跑时进度由实例写，实例停了进度就停住。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:styled_widget/styled_widget.dart';

import 'package:oasx/controller/orchestra/orchestra_controller.dart';
import 'package:oasx/model/orchestra_model.dart';
import 'package:oasx/model/script_model.dart';
import 'package:oasx/service/script_service.dart';

/// 取实例进程的状态（总览里的运行、停止），null 表示不知道。
typedef InstanceStateFn = ScriptState? Function(String script);

/// 留空的格子：子项、次数、分钟沿用任务自己的设置，休息取默认休息。
const _defaultLabel = '(默认)';

/// 表格最窄的宽度，窗口再窄就横向滚动，免得下拉框被挤没。
const _tableMinWidth = 840.0;

/// 表格里有对应格子的字段，同后端的行字段名；其余字段的错误放在任务格下。
const _cellFields = {
  'task',
  'sub1',
  'sub2',
  'max_count',
  'max_minutes',
  'rest_minutes',
};

/// 序列设置的显示名，用于后端报的设置项错误（行号 -1）。
const _settingLabels = {
  'after_finish': '跑完后',
  'total_minutes_cap': '总时长上限',
  'default_rest_minutes': '默认休息',
  'rest_jitter': '休息随机浮动',
  'resume_policy': '中断后',
  'cut_in_tasks': '允许插队',
  'rows': '编排表',
};

class OrchestraView extends StatelessWidget {
  const OrchestraView({super.key, required this.script, this.instanceState});

  final String script; // 实例名

  /// 实例进程的状态，测试时换成假的；不给时取总览用的 ScriptService。
  final InstanceStateFn? instanceState;

  // 内页以实例名作 key：换实例时旧页销毁、停止轮询，新页重新开始
  @override
  Widget build(BuildContext context) => _OrchestraPage(
      key: ValueKey(script),
      script: script,
      instanceState: instanceState ?? _serviceInstanceState);
}

class _OrchestraPage extends StatefulWidget {
  const _OrchestraPage(
      {super.key, required this.script, required this.instanceState});

  final String script;
  final InstanceStateFn instanceState;

  @override
  State<_OrchestraPage> createState() => _OrchestraPageState();
}

class _OrchestraPageState extends State<_OrchestraPage> {
  /// 每个控制器上挂着几个编排页。窗口宽度跨过桌面与窄屏布局的分界时，页面换到别的父节点下重建：
  /// 同一帧里同一实例的新页先建（开始轮询时定时器还在，什么也不做），旧页后销毁。
  /// 所以只在最后一个页面销毁时停止轮询，否则看得见的页面再也收不到数据。
  static final _pages = Expando<int>();

  late final OrchestraController c;
  bool _saving = false; // 保存请求未回
  bool? _saved; // 最近一次保存的结果，下次编辑时清除
  bool _sending = false; // 控制命令未回
  String _commandNotice = ''; // 命令没被接受时的提示

  @override
  void initState() {
    super.initState();
    final tag = widget.script;
    c = Get.isRegistered<OrchestraController>(tag: tag)
        ? Get.find<OrchestraController>(tag: tag)
        : Get.put(OrchestraController(tag), tag: tag);
    _pages[c] = (_pages[c] ?? 0) + 1;
    c.startPolling();
  }

  @override
  void dispose() {
    final left = (_pages[c] ?? 1) - 1;
    _pages[c] = left > 0 ? left : null;
    if (left <= 0) c.stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final bundle = c.bundle.value;
      final readFailing = c.readFailing.value;
      final dirty = c.dirty.value;
      final errors = Map.of(c.errors);
      // 实例确知没在运行：总览里停了，或出错退出（warning）；刚连上、还不知道（updating）的不算。
      // 在 Obx 里读，实例启停时页面跟着刷新
      final instance = widget.instanceState(widget.script);
      final instanceStopped =
          instance == ScriptState.inactive || instance == ScriptState.warning;
      final message =
          _blockingMessage(bundle, readFailing, c.backendMissing.value);
      final List<Widget> sections;
      if (message != null || bundle == null) {
        sections = [
          _header(context, null, instanceStopped),
          _note(context, message ?? ''),
        ];
      } else {
        sections = [
          _header(context, bundle, instanceStopped),
          _tableCard(context, bundle, errors),
          _settingsCard(context, bundle, errors[-1] ?? const {}, dirty),
          _controlCard(context, bundle, dirty, instanceStopped),
          _panelCard(context, bundle, readFailing,
              _frozenByInstance(bundle, instanceStopped)),
        ];
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: sections
            .toColumn(crossAxisAlignment: CrossAxisAlignment.stretch)
            .constrained(maxWidth: 1100),
      ).alignment(Alignment.topCenter);
    });
  }

  // ---------------------------------------------------------------- 页面各块

  Widget _header(
      BuildContext context, OrchestraBundle? bundle, bool instanceStopped) {
    final style = Theme.of(context).textTheme.titleMedium;
    // 状态行带上实例未运行的说明后较长：同一行放不下就换到下一行，不溢出
    return <Widget>[
      Text('编排 · ${widget.script}',
          style: style, overflow: TextOverflow.ellipsis),
      if (bundle != null)
        Text('状态：${_statusText(bundle, instanceStopped)}', style: style),
    ]
        .toWrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16)
        .padding(horizontal: 4, vertical: 10);
  }

  Widget _note(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.bodyLarge)
          .padding(all: 20)
          .card(margin: const EdgeInsets.only(bottom: 10));

  Widget _tableCard(BuildContext context, OrchestraBundle bundle,
      Map<int, Map<String, String>> errors) {
    final theme = Theme.of(context);
    final head = theme.textTheme.titleSmall;
    final rows = c.editor.rows;
    final table = Table(
      columnWidths: const {
        0: FixedColumnWidth(44),
        1: FlexColumnWidth(3),
        2: FlexColumnWidth(4),
        3: FixedColumnWidth(96),
        4: FixedColumnWidth(96),
        5: FixedColumnWidth(96),
        6: FixedColumnWidth(160),
      },
      border:
          TableBorder(horizontalInside: BorderSide(color: theme.dividerColor)),
      children: [
        TableRow(children: [
          for (final title in ['序号', '任务', '子项', '次数', '分钟', '之后休息', ''])
            Text(title, style: head).padding(horizontal: 4, vertical: 8),
        ]),
        for (var i = 0; i < rows.length; i++)
          _tableRow(context, bundle, i, rows.length, rows[i], errors[i] ?? {}),
      ],
    );
    return <Widget>[
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? math.max(constraints.maxWidth, _tableMinWidth)
            : _tableMinWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: width, child: table),
        );
      }),
      if (rows.isEmpty)
        Text('编排表还没有行', style: TextStyle(color: theme.disabledColor))
            .padding(all: 8),
      TextButton.icon(
        onPressed: bundle.catalog.isEmpty ? null : _addRow,
        icon: const Icon(Icons.add),
        label: const Text('新增行'),
      ).alignment(Alignment.centerLeft),
    ]
        .toColumn(crossAxisAlignment: CrossAxisAlignment.stretch)
        .padding(all: 8)
        .card(margin: const EdgeInsets.only(bottom: 10));
  }

  TableRow _tableRow(BuildContext context, OrchestraBundle bundle, int i,
      int count, OrchestraRow row, Map<String, String> rowErrors) {
    final spec = c.specOf(row.task);
    final others = [
      for (final e in rowErrors.entries)
        if (!_cellFields.contains(e.key)) '${e.key}：${e.value}'
    ];
    return TableRow(children: [
      _cell(context, Text('${i + 1}')),
      _cell(context, _taskDropdown(i, row, spec, bundle.catalog),
          [rowErrors['task'], ...others]),
      _cell(context, _subsCell(context, i, row, spec),
          [rowErrors['sub1'], rowErrors['sub2']]),
      _cell(
          context,
          spec != null && spec.hasCount
              ? _IntField(
                  key: ValueKey('row$i.max_count'),
                  value: row.maxCount,
                  onChanged: (v) => _editRow(i, (r) => r.maxCount = v))
              : _na(context, 'row$i.max_count'),
          [rowErrors['max_count']]),
      _cell(
          context,
          spec != null && spec.hasTime
              ? _IntField(
                  key: ValueKey('row$i.max_minutes'),
                  value: row.maxMinutes,
                  onChanged: (v) => _editRow(i, (r) => r.maxMinutes = v))
              : _na(context, 'row$i.max_minutes'),
          [rowErrors['max_minutes']]),
      _cell(
          context,
          _IntField(
              key: ValueKey('row$i.rest_minutes'),
              value: row.restMinutes,
              onChanged: (v) => _editRow(i, (r) => r.restMinutes = v)),
          [rowErrors['rest_minutes']]),
      _cell(context, _rowActions(i, count)),
    ]);
  }

  /// 一个格子：控件占固定高度，各行对齐；错误文案红字列在下方。
  Widget _cell(BuildContext context, Widget control,
      [List<String?> errors = const []]) {
    return <Widget>[
      SizedBox(height: 48, child: control.alignment(Alignment.centerLeft)),
      for (final error in errors)
        if (error != null) _errorText(context, error),
    ]
        .toColumn(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch)
        .padding(horizontal: 4, bottom: 4);
  }

  Widget _taskDropdown(int i, OrchestraRow row, TaskCatalogEntry? spec,
      List<TaskCatalogEntry> catalog) {
    return DropdownButton<String>(
      key: ValueKey('row$i.task'),
      isExpanded: true,
      // 任务不在目录里（映射改过后读回的旧行）时按未选处理，提示文字显示原任务名
      value: spec == null ? null : row.task,
      hint: Text(row.task, overflow: TextOverflow.ellipsis),
      items: [
        for (final entry in catalog)
          DropdownMenuItem(
              value: entry.command,
              child: Text(entry.title, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (task) => _changeTask(i, task),
    );
  }

  /// 子项格：任务有几个子项就放几个下拉框，没有子项置灰。
  Widget _subsCell(
      BuildContext context, int i, OrchestraRow row, TaskCatalogEntry? spec) {
    if (spec == null || spec.subs.isEmpty) return _na(context, 'row$i.sub1');
    final values = [row.sub1, row.sub2];
    return <Widget>[
      for (var p = 0; p < spec.subs.length && p < values.length; p++)
        _subDropdown(i, p, spec.subs[p], values[p]).expanded(),
    ].toRow(separator: const SizedBox(width: 8));
  }

  Widget _subDropdown(int i, int position, SubSpec sub, String? value) {
    return DropdownButton<String?>(
      key: ValueKey('row$i.sub${position + 1}'),
      isExpanded: true,
      // 存着的值不在可选范围内时按未选处理：DropdownButton 遇到选项里没有的值会断言失败。
      // 草稿里的值不动，红字提示由校验给出
      value: sub.options.contains(value) ? value : null,
      items: [
        const DropdownMenuItem<String?>(
            value: null, child: Text(_defaultLabel)),
        for (var k = 0; k < sub.options.length; k++)
          DropdownMenuItem<String?>(
              value: sub.options[k],
              child: Text(
                  k < sub.labels.length ? sub.labels[k] : sub.options[k],
                  overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => _editRow(i, (r) {
        if (position == 0) {
          r.sub1 = v;
        } else {
          r.sub2 = v;
        }
      }),
    );
  }

  Widget _rowActions(int i, int count) => <Widget>[
        IconButton(
          tooltip: '上移',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.arrow_upward),
          onPressed: i > 0 ? () => _editRows((e) => e.moveUp(i)) : null,
        ),
        IconButton(
          tooltip: '下移',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.arrow_downward),
          onPressed:
              i < count - 1 ? () => _editRows((e) => e.moveDown(i)) : null,
        ),
        TextButton(
          onPressed: () => _editRows((e) => e.remove(i)),
          child: const Text('删除'),
        ),
      ].toRow(mainAxisSize: MainAxisSize.min);

  Widget _settingsCard(BuildContext context, OrchestraBundle bundle,
      Map<String, String> settingErrors, bool dirty) {
    final d = c.draft;
    // 不在目录里的插队任务（如手改配置加的真蛇）也列出来，按命令名显示，好取消。
    // 服务端那份也算上：取消后、保存前仍能勾回
    final known = {for (final entry in bundle.catalog) entry.command};
    final extra = <String>[];
    for (final command in [...bundle.settings.cutInTasks, ...d.cutInTasks]) {
      if (!known.contains(command) && !extra.contains(command)) {
        extra.add(command);
      }
    }
    return <Widget>[
      Text('序列设置', style: Theme.of(context).textTheme.titleMedium),
      <Widget>[
        _group('跑完后', [
          _radio('停止', 'stop', d.afterFinish,
              (v) => _editDraft((s) => s.afterFinish = v)),
          _radio('从第 1 行循环', 'loop', d.afterFinish,
              (v) => _editDraft((s) => s.afterFinish = v)),
        ]),
        _group('总时长上限', [
          _IntField(
                  key: const ValueKey('total_minutes_cap'),
                  value: d.totalMinutesCap,
                  hint: '不限',
                  onChanged: (v) => _editDraft((s) => s.totalMinutesCap = v))
              .width(72),
          const Text(' 分'),
        ]),
        _group('默认休息', [
          // 必填项：留空不改，提示文字显示当前值
          _IntField(
              key: const ValueKey('default_rest_minutes'),
              value: d.defaultRestMinutes,
              hint: '${d.defaultRestMinutes}',
              onChanged: (v) {
                if (v != null) _editDraft((s) => s.defaultRestMinutes = v);
              }).width(72),
          const Text(' 分'),
        ]),
      ].toWrap(spacing: 24, crossAxisAlignment: WrapCrossAlignment.center),
      <Widget>[
        _group('休息随机浮动', [
          _check('开', d.restJitter, (v) => _editDraft((s) => s.restJitter = v)),
        ]),
        _group('中断后', [
          _radio('补完剩余', 'remaining', d.resumePolicy,
              (v) => _editDraft((s) => s.resumePolicy = v)),
          _radio('整行重跑', 'rerun', d.resumePolicy,
              (v) => _editDraft((s) => s.resumePolicy = v)),
        ]),
      ].toWrap(spacing: 24, crossAxisAlignment: WrapCrossAlignment.center),
      <Widget>[
        const Text('允许插队：').padding(top: 12),
        <Widget>[
          for (final entry in bundle.catalog)
            _check(entry.title, d.cutInTasks.contains(entry.command),
                (on) => _toggleCutIn(entry.command, on)),
          for (final command in extra)
            _check(command, d.cutInTasks.contains(command),
                (on) => _toggleCutIn(command, on)),
        ].toWrap().expanded(),
      ].toRow(crossAxisAlignment: CrossAxisAlignment.start),
      for (final e in settingErrors.entries)
        _errorText(context, _settingError(e.key, e.value)),
      <Widget>[
        FilledButton(
          onPressed: dirty && !_saving ? _save : null,
          child: const Text('保存'),
        ),
        Text(_saveStatus(dirty),
                style: _saved == false
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null)
            .flexible(),
      ].toRow(separator: const SizedBox(width: 12)).padding(top: 8),
    ]
        .toColumn(crossAxisAlignment: CrossAxisAlignment.start)
        .padding(all: 12)
        .card(margin: const EdgeInsets.only(bottom: 10));
  }

  Widget _controlCard(BuildContext context, OrchestraBundle bundle, bool dirty,
      bool instanceStopped) {
    final state = bundle.settings.state;
    // 已按开始、实例还没响应时，进度可能还是已跑完：同样算在进行，再按会把正在启动的实例又重启一次
    final active = _startPending(bundle) ||
        ((state == 'running' || state == 'paused') &&
            bundle.progress.phase != 'done');
    Widget button(String action, String label, bool enabled) => OutlinedButton(
          onPressed:
              enabled && !_sending ? () => _command(action, label) : null,
          child: Text(label),
        );
    return <Widget>[
      <Widget>[
        // 开始从第 1 行重来，序列在跑或暂停时先停止，免得误点丢掉进度；
        // 开始按已保存的表运行，有未保存的修改时先保存
        button('start', '开始', !dirty && !active),
        button('pause', '暂停', state == 'running'),
        // 继续会启动实例：暂停时可用；序列在跑而实例确知没在运行时也可用，启动实例接着跑
        button('resume', '继续',
            state == 'paused' || (state == 'running' && instanceStopped)),
        button('stop', '停止', state == 'running' || state == 'paused'),
        button('skip_rest', '跳过休息', bundle.progress.phase == 'resting'),
      ].toWrap(spacing: 8, runSpacing: 8),
      if (_commandNotice.isNotEmpty)
        _errorText(context, _commandNotice).padding(top: 8),
    ]
        .toColumn(crossAxisAlignment: CrossAxisAlignment.start)
        .padding(all: 12)
        .card(margin: const EdgeInsets.only(bottom: 10));
  }

  Widget _panelCard(
      BuildContext context, OrchestraBundle bundle, bool stale, bool frozen) {
    return <Widget>[
      Text('运行面板', style: Theme.of(context).textTheme.titleMedium),
      if (stale) _errorText(context, '数据可能已过时（连不上 OAS）'),
      if (frozen) _errorText(context, '实例未运行，进度停在实例停止时'),
      Text('当前：${_currentText(bundle)}'),
      Text('下一行：${_nextText(bundle)}'),
      Text('全程：${_totalText(bundle)}'),
      Text('提示：${_hintText(bundle)}'),
    ]
        .toColumn(
            crossAxisAlignment: CrossAxisAlignment.start,
            separator: const SizedBox(height: 4))
        .padding(all: 12)
        .card(margin: const EdgeInsets.only(bottom: 10));
  }

  // ---------------------------------------------------------------- 小部件

  Widget _errorText(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error));
  }

  /// 任务没有这一格：置灰显示 —。
  Widget _na(BuildContext context, String key) => Text('—',
      key: ValueKey(key),
      style: TextStyle(color: Theme.of(context).disabledColor));

  Widget _group(String label, List<Widget> children) => <Widget>[
        Text('$label：'),
        ...children
      ].toRow(mainAxisSize: MainAxisSize.min);

  Widget _radio(String label, String value, String group,
      ValueChanged<String> onChanged) {
    return InkWell(
      onTap: () => onChanged(value),
      child: <Widget>[
        Radio<String>(
            value: value,
            groupValue: group,
            onChanged: (_) => onChanged(value)),
        Text(label),
      ].toRow(mainAxisSize: MainAxisSize.min).padding(right: 8),
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: <Widget>[
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        Text(label),
      ].toRow(mainAxisSize: MainAxisSize.min).padding(right: 8),
    );
  }

  // ---------------------------------------------------------------- 编辑

  /// 编辑之后：清掉上一次保存的结果，交给控制器标记未保存并重新校验。
  void _edited() {
    if (_saved != null) setState(() => _saved = null);
    c.edited();
  }

  /// 改第 i 行。回调时从控制器现取：构建之后轮询可能已换掉草稿。
  void _editRow(int i, void Function(OrchestraRow row) change) {
    final rows = c.editor.rows;
    if (i < 0 || i >= rows.length) return;
    change(rows[i]);
    _edited();
  }

  void _editRows(void Function(RowsEditor editor) change) {
    change(c.editor);
    _edited();
  }

  void _editDraft(void Function(OrchestraSettings draft) change) {
    change(c.draft);
    _edited();
  }

  void _changeTask(int i, String? task) {
    final spec = task == null ? null : c.specOf(task);
    if (spec == null) return;
    _editRows((e) => e.changeTask(i, spec.command, spec));
  }

  /// 新增一行：任务沿用上一行；表是空的或上一行的任务不在目录里，取目录第一项。
  void _addRow() {
    final rows = c.editor.rows;
    final catalog = c.bundle.value?.catalog ?? const <TaskCatalogEntry>[];
    final last = rows.isEmpty ? null : c.specOf(rows.last.task);
    final task =
        last?.command ?? (catalog.isEmpty ? null : catalog.first.command);
    if (task == null) return;
    _editRows((e) => e.add(task));
  }

  /// 勾选或取消一项插队任务，其余各项原样保留。
  void _toggleCutIn(String command, bool on) => _editDraft((d) {
        if (!on) {
          d.cutInTasks.removeWhere((t) => t == command);
        } else if (!d.cutInTasks.contains(command)) {
          d.cutInTasks.add(command);
        }
      });

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = null;
    });
    var ok = false;
    try {
      ok = await c.save();
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _saved = ok;
        });
      }
    }
  }

  Future<void> _command(String action, String label) async {
    setState(() {
      _sending = true;
      _commandNotice = '';
    });
    var ok = false;
    try {
      ok = await c.command(action);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          // 后端不接受时也回 HTTP 200，请求层不会提示，这里要说。
          // 开始、暂停、继续、停止先停实例再写配置，没做成时实例可能已经停下，不能说未执行
          if (!ok) {
            _commandNotice = action == 'skip_rest'
                ? 'OAS 未执行「$label」：只在休息中可用'
                : 'OAS 没能完成「$label」，实例可能已停下，请到总览查看';
          }
        });
      }
    }
  }

  // ---------------------------------------------------------------- 文案

  String _saveStatus(bool dirty) {
    if (_saving) return '正在保存…';
    if (_saved == false) return '未保存，请按红字修改';
    if (dirty) return '有未保存的修改，保存后生效';
    return _saved == true ? '已保存' : '';
  }

  /// 状态行。instanceStopped：实例确知没在运行，进度不会再动。
  /// 暂停、停止会立即停下实例，正在打的行随之中断，所以状态行只按配置里的运行状态显示。
  String _statusText(OrchestraBundle b, bool instanceStopped) {
    final text = _sequenceStateText(b);
    return _frozenByInstance(b, instanceStopped)
        ? '$text · 实例未运行，按继续接着跑'
        : text;
  }

  /// 配置里的运行状态，加上进度阶段。
  String _sequenceStateText(OrchestraBundle b) {
    final p = b.progress;
    final row = '第 ${p.rowIndex + 1} 行';
    switch (b.settings.state) {
      case 'paused':
        return '已暂停';
      case 'running':
        // 已按开始、实例还没响应：进度还是开始前的（如已跑完），不按它的阶段说
        if (_startPending(b)) return '已开始，等待实例响应';
        return switch (p.phase) {
          'row_running' => '运行中（$row）',
          'ready' => '运行中（等待$row）',
          'resting' => '运行中（休息）',
          'interrupted' => '运行中（$row中断）',
          'done' => '已跑完',
          _ => '已开始，等待实例响应',
        };
      default:
        return p.phase == 'done' ? '已跑完' : '未运行';
    }
  }

  /// 行的显示名：任务名加子项，如 御魂·八岐大蛇·悲鸣。
  String _rowLabel(OrchestraRow row) {
    final spec = c.specOf(row.task);
    final parts = [spec?.title ?? row.task];
    final values = [row.sub1, row.sub2];
    for (var p = 0; p < values.length; p++) {
      final value = values[p];
      if (value == null) continue;
      final sub = spec != null && p < spec.subs.length ? spec.subs[p] : null;
      final k = sub == null ? -1 : sub.options.indexOf(value);
      parts.add(k >= 0 && k < sub!.labels.length ? sub.labels[k] : value);
    }
    return parts.join('·');
  }

  /// 第 i 行（从 0 起）的序号与显示名；运行中改过表、行号超出时只给序号。
  String _rowAt(OrchestraBundle b, int i) {
    final rows = b.settings.rows;
    return i >= 0 && i < rows.length
        ? '第 ${i + 1} 行 ${_rowLabel(rows[i])}'
        : '第 ${i + 1} 行';
  }

  /// 从 start 起第一个能运行的行，同后端 next_row_index：校验不过的行跳过。
  int? _nextRunnable(List<OrchestraRow> rows, int start) {
    for (var i = math.max(start, 0); i < rows.length; i++) {
      if (validateRow(rows[i], c.specOf(rows[i].task)).isEmpty) return i;
    }
    return null;
  }

  // 运行面板用服务端的表和设置：引擎跑的是已保存的那份，不是草稿

  String _currentText(OrchestraBundle b) {
    final p = b.progress;
    if (p.phase != 'row_running') return '—';
    final rows = b.settings.rows;
    final i = p.rowIndex;
    OrchestraRow? row = i >= 0 && i < rows.length ? rows[i] : null;
    var label = _rowAt(b, i);
    // 运行中改过表，这个位置已换了任务（如在它上面插行、删行）：跑的仍是改表前那一行，
    // 上限是它开始时写进任务的。名称按进度里的任务给，上限不拿新表的数
    final task = p.rowTask;
    if (task != null && task != row?.task) {
      label = '第 ${i + 1} 行 ${c.specOf(task)?.title ?? task}（表已改）';
      row = null;
    }
    final parts = [label];
    if (p.doneCount != null || row?.maxCount != null) {
      parts.add('已打 ${p.doneCount ?? '—'} 次 / ${row?.maxCount ?? '—'}');
    }
    final elapsed = p.rowElapsedSeconds;
    if (elapsed != null) {
      final cap = row?.maxMinutes;
      parts.add(
          '已用 ${_clock(elapsed.floor())} / ${cap == null ? '—' : '$cap:00'}');
    }
    return parts.join('   ');
  }

  String _nextText(OrchestraBundle b) {
    final p = b.progress;
    final s = b.settings;
    switch (p.phase) {
      case 'row_running':
        var next = _nextRunnable(s.rows, p.rowIndex + 1);
        if (next == null && s.afterFinish == 'loop') {
          next = _nextRunnable(s.rows, 0);
        }
        if (next == null) return '—';
        final i = p.rowIndex;
        final rest =
            (i >= 0 && i < s.rows.length ? s.rows[i].restMinutes : null) ??
                s.defaultRestMinutes;
        final restText =
            rest <= 0 ? '不休息' : '休息${s.restJitter ? '约' : ''} $rest 分';
        return '${_rowAt(b, next)}（$restText）';
      case 'ready':
      case 'resting':
      case 'interrupted':
        // 这几个阶段 row_index 指的就是接下来要跑的行
        final next = _nextRunnable(s.rows, p.rowIndex);
        return next == null ? '—' : _rowAt(b, next);
      default:
        return '—';
    }
  }

  String _totalText(OrchestraBundle b) {
    final p = b.progress;
    // total_elapsed 只在一行跑完时累加，正在跑的这一行另算
    final minutes =
        ((p.totalElapsed + (p.rowElapsedSeconds ?? 0)) / 60).floor();
    final cap = b.settings.totalMinutesCap;
    final text = '已用 $minutes 分 / 上限 ${cap == null ? '—' : '$cap 分'}';
    return p.phase == 'idle' ? text : '$text    第 ${p.loopCount + 1} 遍';
  }

  /// 提示：按进度阶段生成，后端给了 status_note 就接在后面。
  String _hintText(OrchestraBundle b) {
    // 已按开始、实例还没响应：进度还是开始前的（如已跑完），同刚开始的序列，没有提示
    if (_startPending(b)) return '—';
    final p = b.progress;
    final state = b.settings.state;
    final resume = b.settings.resumePolicy == 'rerun' ? '整行重跑' : '补完剩余';
    // 序列已停止：停止会丢掉续跑，不说中断的行怎么续
    final idle = state != 'running' && state != 'paused';
    final base = switch (p.phase) {
      // 暂停立即停下实例，正在打的行就此中断；进度里可能还记着行运行中
      'row_running' ||
      'interrupted' when state == 'paused' =>
        '第 ${p.rowIndex + 1} 行已中断，继续后将$resume',
      'resting' => '休息中，还剩 ${_mmss((p.restRemainingSeconds ?? 0).ceil())}',
      'interrupted' when idle => '第 ${p.rowIndex + 1} 行中断',
      'interrupted' => '第 ${p.rowIndex + 1} 行中断，将$resume',
      'done' => '已跑完',
      _ => '',
    };
    final note = p.statusNote;
    if (base.isEmpty) return note.isEmpty ? '—' : note;
    return note.isEmpty ? base : '$base；$note';
  }
}

/// 序列在跑，实例却确知没在运行：进度停在实例停下时，实例再启动（如按继续）才接着跑。
/// 这几个阶段等着实例接着跑；已跑完、没开始的不算。
/// 暂停会停下实例，暂停时实例不在运行是常态，不算。
bool _frozenByInstance(OrchestraBundle b, bool instanceStopped) =>
    instanceStopped &&
    b.settings.state == 'running' &&
    const {'row_running', 'ready', 'resting', 'interrupted'}
        .contains(b.progress.phase);

/// 已按开始，实例还没处理这条开始命令：后端只写配置、重启实例，进度要等新实例第一次选任务才重置，
/// 在那之前还是开始前的样子（如已跑完）。同后端 _start_pending，另要求序列在跑：暂停、停止后写进度失败，
/// 或进度文件丢了，停着的序列会留着一条没处理的开始，实例不会因此开跑，不算。
bool _startPending(OrchestraBundle b) =>
    b.settings.state == 'running' &&
    b.settings.command == 'start' &&
    b.settings.commandSeq > b.progress.lastCommandSeq;

/// 实例进程的状态，与总览同源：ScriptService 随 websocket 推送更新，在 Obx 里读会跟着刷新。
/// 服务还没登记（启动时异步登记）或其中没有这个实例时为 null。
ScriptState? _serviceInstanceState(String script) =>
    Get.isRegistered<ScriptService>()
        ? Get.find<ScriptService>().findScriptModel(script)?.state.value
        : null;

/// 没有数据可编辑时显示的文字；返回 null 表示照常显示编排表。
/// 读取失败比 404 新，两者都在时按读取失败处理；已有数据时读取失败只标过时，数据照常显示。
String? _blockingMessage(
    OrchestraBundle? bundle, bool readFailing, bool backendMissing) {
  if (readFailing) return bundle == null ? '暂时连不上 OAS，正在重试' : null;
  if (backendMissing) return '后端未提供编排接口，请先更新 OAS';
  return bundle == null ? '正在读取编排…' : null;
}

/// 后端报的设置项错误：认得的字段前面加设置名；字段为空串（如保存失败）或实例名的只显示文案。
String _settingError(String field, String message) {
  if (field.isEmpty || field == 'script_name') return message;
  return '${_settingLabels[field] ?? field}：$message';
}

/// 秒数显示成 分:秒，分钟不补零，如 6:10。
String _clock(int seconds) {
  final s = math.max(seconds, 0);
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 秒数显示成 mm:ss，如 04:06。
String _mmss(int seconds) {
  final s = math.max(seconds, 0);
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 整数输入框：只能输入数字，留空为 null。
///
/// 文字由输入框自己持有。值从外部变了（草稿随服务端数据重建、行上下移动）才改文字；
/// 用户输入引起的值变化与文字一致，不动文字，光标不跳。
class _IntField extends StatefulWidget {
  const _IntField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint = _defaultLabel,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final String hint;

  @override
  State<_IntField> createState() => _IntFieldState();
}

class _IntFieldState extends State<_IntField> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.value?.toString() ?? '');
  }

  @override
  void didUpdateWidget(_IntField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value &&
        widget.value != int.tryParse(_text.text)) {
      _text.text = widget.value?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(5),
      ],
      decoration: InputDecoration(isDense: true, hintText: widget.hint),
      onChanged: (text) => widget.onChanged(int.tryParse(text)),
    );
  }
}
