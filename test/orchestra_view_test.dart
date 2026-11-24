import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/controller/orchestra/orchestra_controller.dart';
import 'package:oasx/model/orchestra_model.dart';
import 'package:oasx/model/script_model.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/views/home/assets_check_entry.dart';
import 'package:oasx/views/orchestra/orchestra_view.dart';

// 编排页的页面测试：控制器注入假的接口函数，不连网；实例进程的状态也可换成假的。
// 假目录：
// - 八岐大蛇：一个子项（十层、悲鸣），次数不设上限，有时长；
// - 个人突破：次数 1–30，没有子项和时长；
// - 寻找协作：没有子项、次数和时长；
// - 爬塔：类型子项（门票、体力），有次数和时长。
const _catalog = [
  {
    'command': 'Orochi',
    'title': '御魂·八岐大蛇',
    'count_max': null,
    'has_count': true,
    'has_time': true,
    'subs': [
      {
        'options': ['十层', '悲鸣'],
        'labels': ['十层', '悲鸣'],
      }
    ],
  },
  {
    'command': 'RealmRaid',
    'title': '个人突破',
    'count_max': 30,
    'has_count': true,
    'has_time': false,
    'subs': [],
  },
  {
    'command': 'FindJade',
    'title': '肝帝·寻找协作',
    'count_max': null,
    'has_count': false,
    'has_time': false,
    'subs': [],
  },
  {
    'command': 'ActivityShikigami',
    'title': '限时·爬塔',
    'count_max': null,
    'has_count': true,
    'has_time': true,
    'subs': [
      {
        'options': ['pass', 'ap'],
        'labels': ['门票', '体力'],
      }
    ],
  },
];

/// 服务端返回的数据。
OrchestraBundle _bundle(
  List<Map<String, dynamic>> rows, {
  Map<String, dynamic> settings = const {},
  Map<String, dynamic> progress = const {},
}) =>
    OrchestraBundle.fromJson({
      'settings': {'rows': rows, ...settings},
      'progress': progress,
      'catalog': _catalog,
    });

Widget _app(String? script, {InstanceStateFn? instance}) => MaterialApp(
      home: Scaffold(
        body: script == null
            ? const SizedBox()
            : OrchestraView(script: script, instanceState: instance),
      ),
    );

/// 登记用假接口的控制器，显示 oas1 的编排页，并画出第一次读取的结果。
/// 不给 instance 时，实例状态照常取 ScriptService（测试里没有登记，即不知道）。
Future<OrchestraController> _show(
  WidgetTester tester,
  GetOrchestraFn get, {
  PutOrchestraFn? put,
  OrchestraCommandFn? command,
  InstanceStateFn? instance,
}) async {
  // 画布放大到整页可见，点按钮不必先滚动
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = Get.put(
    OrchestraController(
      'oas1',
      getOrchestra: get,
      putOrchestra: put ?? (_, __) async => [],
      orchestraCommand: command ?? (_, __) async => true,
    ),
    tag: 'oas1',
  );
  await tester.pumpWidget(_app('oas1', instance: instance));
  await _frames(tester);
  return c;
}

/// 先让异步结果落地，再画一帧。
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// 等到下一次轮询，并画出它的结果。
Future<void> _nextPoll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
}

/// 只有 findScriptModel 的 ScriptService：真的那个构造和初始化时要连 OAS、读本地存储。
class _FakeScriptService extends GetxService implements ScriptService {
  final models = <String, ScriptModel>{};

  // ScriptService 的生命周期方法返回 Future，签名要与它一致
  @override
  Future<void> onInit() async => super.onInit();

  @override
  Future<void> onClose() async => super.onClose();

  @override
  ScriptModel? findScriptModel(String name) => models[name];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)), matching: find.byType(TextField));

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(_field(key)).controller!.text;

DropdownButton<String> _taskDropdown(WidgetTester tester, int row) =>
    tester.widget<DropdownButton<String>>(find.byKey(ValueKey('row$row.task')));

DropdownButton<String?> _subDropdown(WidgetTester tester, String key) =>
    tester.widget<DropdownButton<String?>>(find.byKey(ValueKey(key)));

void main() {
  tearDown(() => Get.deleteAll(force: true));

  testWidgets('test_view_backend_missing_text', (tester) async {
    var fail = false;
    await _show(tester, (_) async {
      if (fail) throw Exception('connection refused');
      return null; // 404
    });
    expect(find.text('后端未提供编排接口，请先更新 OAS'), findsOneWidget);
    expect(find.text('保存'), findsNothing);

    // 之后读取失败：两个状态同时成立，按较新的读取失败显示
    fail = true;
    await _nextPoll(tester);
    expect(find.text('暂时连不上 OAS，正在重试'), findsOneWidget);
    expect(find.text('后端未提供编排接口，请先更新 OAS'), findsNothing);
  });

  testWidgets('test_view_read_failing_text_before_first_read', (tester) async {
    await _show(tester, (_) async => throw Exception('connection refused'));
    expect(find.text('暂时连不上 OAS，正在重试'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
    expect(find.text('新增行'), findsNothing);
  });

  testWidgets('test_view_backend_missing_with_old_bundle_then_stale',
      (tester) async {
    OrchestraBundle? reply = _bundle([
      {'task': 'Orochi'}
    ]);
    var fail = false;
    await _show(tester, (_) async {
      if (fail) throw Exception('connection refused');
      return reply;
    });
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('数据可能已过时（连不上 OAS）'), findsNothing);

    // 404：旧数据还在，也显示后端缺接口，不给编辑
    reply = null;
    await _nextPoll(tester);
    expect(find.text('后端未提供编排接口，请先更新 OAS'), findsOneWidget);
    expect(find.text('保存'), findsNothing);

    // 再读取失败：读取失败较新，照常显示旧数据，运行面板标为过时
    fail = true;
    await _nextPoll(tester);
    expect(find.text('后端未提供编排接口，请先更新 OAS'), findsNothing);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('数据可能已过时（连不上 OAS）'), findsOneWidget);
  });

  testWidgets('test_view_no_save_button_before_first_bundle', (tester) async {
    final reply = Completer<OrchestraBundle?>();
    await _show(tester, (_) => reply.future);
    expect(find.text('正在读取编排…'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
    expect(find.text('新增行'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    reply.complete(_bundle([
      {'task': 'Orochi'}
    ]));
    await _frames(tester);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('新增行'), findsOneWidget);
  });

  testWidgets('test_view_renders_rows', (tester) async {
    await _show(
      tester,
      (_) async => _bundle([
        {
          'task': 'Orochi',
          'sub1': '悲鸣',
          'max_count': 30,
          'max_minutes': 20,
          'rest_minutes': 5,
        },
        {'task': 'RealmRaid', 'max_count': 20},
        {'task': 'FindJade'},
        {'task': 'ActivityShikigami', 'sub1': 'pass', 'max_count': 50},
      ]),
    );
    expect(tester.takeException(), isNull);
    for (var n = 1; n <= 4; n++) {
      expect(find.text('$n'), findsOneWidget); // 序号
    }
    expect([for (var i = 0; i < 4; i++) _taskDropdown(tester, i).value],
        ['Orochi', 'RealmRaid', 'FindJade', 'ActivityShikigami']);
    expect(_subDropdown(tester, 'row0.sub1').value, '悲鸣');
    expect(_subDropdown(tester, 'row3.sub1').value, 'pass');
    expect(_fieldText(tester, 'row0.max_count'), '30');
    expect(_fieldText(tester, 'row0.max_minutes'), '20');
    expect(_fieldText(tester, 'row0.rest_minutes'), '5');
    expect(_fieldText(tester, 'row1.max_count'), '20');
    expect(_fieldText(tester, 'row1.rest_minutes'), '');
    expect(_fieldText(tester, 'row3.max_count'), '50');

    // 任务没有的格子：置灰，显示 —
    for (final key in [
      'row1.sub1',
      'row1.max_minutes',
      'row2.sub1',
      'row2.max_count',
      'row2.max_minutes',
    ]) {
      final dash = find.byKey(ValueKey(key));
      expect(tester.widget<Text>(dash).data, '—', reason: key);
      expect(tester.widget<Text>(dash).style?.color,
          Theme.of(tester.element(dash)).disabledColor,
          reason: key);
    }
    expect(find.text('次数需在 1–30 之间'), findsNothing);
  });

  testWidgets('test_view_stale_sub_reaches_dropdown_as_null', (tester) async {
    final c = await _show(
      tester,
      (_) async => _bundle([
        {'task': 'Orochi', 'sub1': '旧层数'}
      ]),
    );
    expect(tester.takeException(), isNull);
    expect(_subDropdown(tester, 'row0.sub1').value, isNull);
    expect(find.text('子项不在可选范围内'), findsOneWidget);
    // 页面只是不选中，草稿里的值原样保留，由用户决定怎么改
    expect(c.editor.rows.single.sub1, '旧层数');
  });

  testWidgets('test_view_red_text_for_realm_raid_count_31', (tester) async {
    final c = await _show(
      tester,
      (_) async => _bundle([
        {'task': 'RealmRaid', 'max_count': 20}
      ]),
    );
    expect(find.text('次数需在 1–30 之间'), findsNothing);

    // 先改一个合法的值：第一次编辑把 dirty 置上
    await tester.enterText(_field('row0.max_count'), '25');
    await _frames(tester);
    expect(c.dirty.value, isTrue);
    expect(find.text('次数需在 1–30 之间'), findsNothing);

    // 再改成越界的值：dirty 不再通知，红字靠新的 errors 带出来
    await tester.enterText(_field('row0.max_count'), '31');
    await _frames(tester);
    final red = find.text('次数需在 1–30 之间');
    expect(red, findsOneWidget);
    expect(tester.widget<Text>(red).style?.color,
        Theme.of(tester.element(red)).colorScheme.error);
    // 红字就在次数格下方，不弹层
    final field = find.byKey(const ValueKey('row0.max_count'));
    expect(tester.getTopLeft(red).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(field).dy));
    expect(tester.getTopLeft(red).dx, closeTo(tester.getTopLeft(field).dx, 1));
    expect(find.byType(Dialog), findsNothing);
    expect(c.editor.rows.single.maxCount, 31);
    expect(c.dirty.value, isTrue);
  });

  testWidgets('test_view_save_in_flight_and_settings_errors', (tester) async {
    final put = Completer<List<Map<String, dynamic>>>();
    final c = await _show(
      tester,
      (_) async => _bundle([
        {'task': 'Orochi'}
      ]),
      put: (_, __) => put.future,
    );
    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    OutlinedButton start() => tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '开始'));
    expect(save().onPressed, isNull); // 没有修改
    expect(start().onPressed, isNotNull);

    await tester.enterText(_field('row0.max_count'), '25');
    await _frames(tester);
    expect(save().onPressed, isNotNull);
    expect(start().onPressed, isNull); // 开始按已保存的表运行，先保存
    expect(find.text('有未保存的修改，保存后生效'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await _frames(tester);
    expect(find.text('正在保存…'), findsOneWidget);
    expect(save().onPressed, isNull); // 请求未回，不能再点

    // 设置项的错误（行号 -1，含字段为空串的）显示在序列设置下
    put.complete([
      {'index': -1, 'field': '', 'message': '保存失败，请检查与 OAS 的连接'},
      {'index': -1, 'field': 'total_minutes_cap', 'message': '取值不合法'},
    ]);
    await _frames(tester);
    expect(find.text('保存失败，请检查与 OAS 的连接'), findsOneWidget);
    expect(find.text('总时长上限：取值不合法'), findsOneWidget);
    expect(find.text('未保存，请按红字修改'), findsOneWidget);
    expect(save().onPressed, isNotNull); // 可以重试
    expect(c.dirty.value, isTrue);
  });

  testWidgets('test_view_rejected_command_tells_user', (tester) async {
    final actions = <String>[];
    await _show(
      tester,
      (_) async => _bundle(
        [
          {'task': 'Orochi'},
          {'task': 'RealmRaid'},
        ],
        settings: {'state': 'running'},
        progress: {
          'phase': 'resting',
          'row_index': 1,
          'rest_remaining_seconds': 60,
        },
      ),
      command: (_, action) async {
        actions.add(action);
        return false; // 后端不接受，HTTP 照样 200
      },
    );
    VoidCallback? pressed(String label) => tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
        .onPressed;
    // 序列在跑：不能再点开始（会从第 1 行重来），可以暂停、停止、跳过休息
    expect(pressed('开始'), isNull);
    expect(pressed('继续'), isNull);
    expect(pressed('暂停'), isNotNull);
    expect(pressed('停止'), isNotNull);
    expect(pressed('跳过休息'), isNotNull);

    // 暂停、停止先停实例再写配置：没做成时实例可能已经停下，不能说未执行
    for (final label in ['暂停', '停止']) {
      await tester.tap(find.widgetWithText(OutlinedButton, label));
      await _frames(tester);
      expect(find.text('OAS 没能完成「$label」，实例可能已停下，请到总览查看'), findsOneWidget,
          reason: label);
      expect(find.textContaining('OAS 未执行'), findsNothing, reason: label);
    }

    // 跳过休息不启停实例，后端不在休息中时直接拒绝：照旧说未执行
    await tester.tap(find.text('跳过休息'));
    await _frames(tester);
    expect(actions, ['pause', 'stop', 'skip_rest']);
    expect(find.text('OAS 未执行「跳过休息」：只在休息中可用'), findsOneWidget);
    expect(find.textContaining('没能完成'), findsNothing);
  });

  testWidgets('test_view_run_panel_by_phase', (tester) async {
    final rows = [
      {
        'task': 'Orochi',
        'sub1': '悲鸣',
        'max_count': 30,
        'max_minutes': 20,
        'rest_minutes': 10,
      },
      {'task': 'RealmRaid', 'max_count': 20},
    ];
    var server = _bundle(
      rows,
      settings: {'state': 'running'},
      progress: {
        'phase': 'row_running',
        'row_index': 0,
        'done_count': 12,
        'row_elapsed_seconds': 370.4,
        'total_elapsed': 600,
      },
    );
    await _show(tester, (_) async => server);
    expect(find.text('状态：运行中（第 1 行）'), findsOneWidget);
    expect(find.text('当前：第 1 行 御魂·八岐大蛇·悲鸣   已打 12 次 / 30   已用 6:10 / 20:00'),
        findsOneWidget);
    expect(find.text('下一行：第 2 行 个人突破（休息 10 分）'), findsOneWidget);
    expect(find.text('全程：已用 16 分 / 上限 —    第 1 遍'), findsOneWidget);
    expect(find.text('提示：—'), findsOneWidget);

    server = _bundle(
      rows,
      settings: {'state': 'running'},
      progress: {
        'phase': 'resting',
        'row_index': 1,
        'rest_remaining_seconds': 245.2,
      },
    );
    await _nextPoll(tester);
    expect(find.text('提示：休息中，还剩 04:06'), findsOneWidget);
    expect(find.text('下一行：第 2 行 个人突破'), findsOneWidget);

    server = _bundle(
      rows,
      settings: {'state': 'running', 'resume_policy': 'rerun'},
      progress: {
        'phase': 'interrupted',
        'row_index': 1,
        'status_note': '防封禁休眠中，08:00 继续',
      },
    );
    await _nextPoll(tester);
    expect(find.text('提示：第 2 行中断，将整行重跑；防封禁休眠中，08:00 继续'), findsOneWidget);

    server = _bundle(rows, progress: {'phase': 'done'});
    await _nextPoll(tester);
    expect(find.text('提示：已跑完'), findsOneWidget);
    expect(find.text('状态：已跑完'), findsOneWidget);
  });

  testWidgets('test_start_pending_from_done', (tester) async {
    // 从已跑完按开始：后端只写配置、重启实例，进度要等新实例第一次选任务才重置。
    // 在那之前进度还是已跑完：状态、提示同刚开始的序列，开始不可再按（再按会把正在启动的实例又重启一次）
    final rows = [
      {'task': 'Orochi'},
      {'task': 'RealmRaid'},
    ];
    OrchestraBundle done(String state, int lastCommandSeq) => _bundle(rows,
        settings: {'state': state, 'command': 'start', 'command_seq': 4},
        progress: {
          'phase': 'done',
          'row_index': 1,
          'last_command_seq': lastCommandSeq,
        });
    var server = done('running', 3);
    await _show(tester, (_) async => server);
    VoidCallback? pressed(String label) => tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
        .onPressed;
    expect(find.text('状态：已开始，等待实例响应'), findsOneWidget);
    expect(find.text('提示：—'), findsOneWidget);
    expect(find.textContaining('已跑完'), findsNothing);
    expect(pressed('开始'), isNull);
    expect(pressed('继续'), isNull); // 继续的可用性不变

    // 实例已处理这条开始（序号对齐）：照旧是已跑完，开始可用
    server = done('running', 4);
    await _nextPoll(tester);
    expect(find.text('状态：已跑完'), findsOneWidget);
    expect(find.text('提示：已跑完'), findsOneWidget);
    expect(pressed('开始'), isNotNull);

    // 序列停着却留着没处理的开始（暂停、停止后写进度失败，或进度文件丢了）：实例不会因此开跑，
    // 不算等待响应，开始照常可用
    server = done('idle', 3);
    await _nextPoll(tester);
    expect(find.text('状态：已跑完'), findsOneWidget);
    expect(find.text('提示：已跑完'), findsOneWidget);
    expect(pressed('开始'), isNotNull);
  });

  testWidgets('test_view_current_row_after_mid_run_table_edit', (tester) async {
    // 运行中在正跑的行上面插了一行并保存：跑的仍是原来那行的爬塔，新表的第 2 行是个人突破
    final rows = [
      {'task': 'FindJade'},
      {'task': 'RealmRaid', 'max_count': 20},
    ];
    OrchestraBundle running(int index, String task) => _bundle(
          rows,
          settings: {'state': 'running'},
          progress: {
            'phase': 'row_running',
            'row_index': index,
            'row_task': task,
            'done_count': 12,
            'row_elapsed_seconds': 370.4,
          },
        );
    var server = running(1, 'ActivityShikigami');
    await _show(tester, (_) async => server);
    // 名称取进度里的任务；上限是那一行开始时写进任务的，新表里的数不算
    expect(find.text('当前：第 2 行 限时·爬塔（表已改）   已打 12 次 / —   已用 6:10 / —'),
        findsOneWidget);

    // 任务不在目录里：显示命令名
    server = running(1, 'KekkaiUtilize');
    await _nextPoll(tester);
    expect(find.text('当前：第 2 行 KekkaiUtilize（表已改）   已打 12 次 / —   已用 6:10 / —'),
        findsOneWidget);

    // 删过行，行号已超出新表
    server = running(5, 'Orochi');
    await _nextPoll(tester);
    expect(find.text('当前：第 6 行 御魂·八岐大蛇（表已改）   已打 12 次 / —   已用 6:10 / —'),
        findsOneWidget);

    // 任务对得上：照常按表里这一行显示
    server = running(1, 'RealmRaid');
    await _nextPoll(tester);
    expect(find.text('当前：第 2 行 个人突破   已打 12 次 / 20   已用 6:10 / —'),
        findsOneWidget);
  });

  testWidgets('test_running_instance_stopped_qualifier', (tester) async {
    // 序列在跑，实例却在总览里停了（或出错退出），进度还停在它停下时：
    // 状态行说明实例未运行、按继续接着跑，运行面板像数据过时那样标出来
    final instance = Rx<ScriptState?>(ScriptState.inactive);
    final rows = [
      {'task': 'Orochi', 'max_count': 30},
      {'task': 'RealmRaid'},
    ];
    var server = _bundle(
      rows,
      settings: {'state': 'running'},
      progress: {'phase': 'row_running', 'row_index': 0, 'done_count': 12},
    );
    await _show(tester, (_) async => server, instance: (_) => instance.value);
    const qualifier = ' · 实例未运行，按继续接着跑';
    final mark = find.text('实例未运行，进度停在实例停止时');
    expect(find.text('状态：运行中（第 1 行）$qualifier'), findsOneWidget);
    expect(mark, findsOneWidget);
    expect(tester.widget<Text>(mark).style?.color,
        Theme.of(tester.element(mark)).colorScheme.error);

    // 实例在跑，或还不知道（刚连上为 updating，总览里没有这个实例为 null）：不加
    for (final state in [ScriptState.running, ScriptState.updating, null]) {
      instance.value = state;
      await tester.pump();
      expect(find.text('状态：运行中（第 1 行）'), findsOneWidget, reason: '$state');
      expect(mark, findsNothing, reason: '$state');
    }

    // 出错退出同样算没在跑；序列的其余几个阶段也加
    instance.value = ScriptState.warning;
    for (final (phase, text) in [
      ('ready', '运行中（等待第 2 行）'),
      ('resting', '运行中（休息）'),
      ('interrupted', '运行中（第 2 行中断）'),
    ]) {
      server = _bundle(rows,
          settings: {'state': 'running'},
          progress: {'phase': phase, 'row_index': 1});
      await _nextPoll(tester);
      expect(find.text('状态：$text$qualifier'), findsOneWidget, reason: phase);
      expect(mark, findsOneWidget, reason: phase);
    }

    // 暂停会停下实例，暂停时实例不在运行是常态；序列已停止或已跑完，启动实例也不会接着跑：都不加
    for (final (state, phase, text) in [
      ('paused', 'resting', '已暂停'),
      ('idle', 'interrupted', '未运行'),
      ('running', 'done', '已跑完'),
    ]) {
      server = _bundle(rows,
          settings: {'state': state},
          progress: {'phase': phase, 'row_index': 1});
      await _nextPoll(tester);
      expect(find.text('状态：$text'), findsOneWidget, reason: '$state $phase');
      expect(mark, findsNothing, reason: '$state $phase');
    }
  });

  testWidgets('test_view_reads_instance_state_from_script_service',
      (tester) async {
    // 不注入时取总览用的 ScriptService；实例启停随 websocket 推送，页面不等下一次轮询就刷新
    final model = ScriptModel('oas1')..state.value = ScriptState.inactive;
    Get.put<ScriptService>(_FakeScriptService()..models['oas1'] = model);
    await _show(
      tester,
      (_) async => _bundle(
        [
          {'task': 'Orochi'}
        ],
        settings: {'state': 'running'},
        progress: {
          'phase': 'resting',
          'row_index': 0,
          'rest_remaining_seconds': 60,
        },
      ),
    );
    expect(find.text('状态：运行中（休息） · 实例未运行，按继续接着跑'), findsOneWidget);

    model.state.value = ScriptState.running;
    await tester.pump();
    expect(find.text('状态：运行中（休息）'), findsOneWidget);
  });

  testWidgets('test_paused_status_plain', (tester) async {
    // 暂停会立即停下实例，正在打的行算中断：状态行只说已暂停，不说本行打完后，
    // 也不加实例未运行的说明，运行面板不标；实例在不在跑、知不知道都一样
    final instance = Rx<ScriptState?>(ScriptState.inactive);
    await _show(
      tester,
      (_) async => _bundle(
        [
          {'task': 'Orochi'},
        ],
        settings: {'state': 'paused'},
        progress: {'phase': 'row_running', 'row_index': 0},
      ),
      instance: (_) => instance.value,
    );
    for (final state in [
      ScriptState.inactive,
      ScriptState.warning,
      ScriptState.running,
      ScriptState.updating,
      null,
    ]) {
      instance.value = state;
      await tester.pump();
      expect(find.text('状态：已暂停'), findsOneWidget, reason: '$state');
      expect(find.textContaining('本行打完后'), findsNothing, reason: '$state');
      expect(find.textContaining('实例未运行'), findsNothing, reason: '$state');
    }
  });

  testWidgets('test_paused_interrupted_hint', (tester) async {
    // 暂停时正在打的行已中断（进度里可能还记着行运行中）：提示按「中断后」的设置说继续后怎么续
    final instance = Rx<ScriptState?>(ScriptState.inactive);
    final rows = [
      {'task': 'Orochi'},
      {'task': 'RealmRaid'},
    ];
    var server = _bundle(rows,
        settings: {'state': 'paused'},
        progress: {'phase': 'row_running', 'row_index': 0});
    await _show(tester, (_) async => server, instance: (_) => instance.value);
    expect(find.text('提示：第 1 行已中断，继续后将补完剩余'), findsOneWidget);
    expect(find.text('状态：已暂停'), findsOneWidget);

    server = _bundle(rows,
        settings: {'state': 'paused', 'resume_policy': 'rerun'},
        progress: {'phase': 'row_running', 'row_index': 0});
    await _nextPoll(tester);
    expect(find.text('提示：第 1 行已中断，继续后将整行重跑'), findsOneWidget);

    // 已记为中断的行同样这样说
    for (final (policy, text) in [
      ('remaining', '补完剩余'),
      ('rerun', '整行重跑'),
    ]) {
      server = _bundle(rows,
          settings: {'state': 'paused', 'resume_policy': policy},
          progress: {'phase': 'interrupted', 'row_index': 1});
      await _nextPoll(tester);
      expect(find.text('提示：第 2 行已中断，继续后将$text'), findsOneWidget,
          reason: policy);
    }

    // 暂停后在总览里启动了实例也一样：序列要按继续才接着跑
    instance.value = ScriptState.running;
    await tester.pump();
    expect(find.text('提示：第 2 行已中断，继续后将整行重跑'), findsOneWidget);

    // 休息中暂停，没有行被打断：照常显示剩余休息
    server = _bundle(
      rows,
      settings: {'state': 'paused'},
      progress: {
        'phase': 'resting',
        'row_index': 1,
        'rest_remaining_seconds': 245.2,
      },
    );
    await _nextPoll(tester);
    expect(find.text('提示：休息中，还剩 04:06'), findsOneWidget);
  });

  testWidgets('test_resume_enabled_when_instance_stopped', (tester) async {
    // 序列在跑，实例却确知没在运行：继续可用，后端会启动实例接着跑；其余按钮的可用性不因此改变
    final actions = <String>[];
    final instance = Rx<ScriptState?>(ScriptState.inactive);
    final rows = [
      {'task': 'Orochi'},
      {'task': 'RealmRaid'},
    ];
    var server = _bundle(rows,
        settings: {'state': 'running'},
        progress: {'phase': 'row_running', 'row_index': 0});
    await _show(
      tester,
      (_) async => server,
      command: (_, action) async {
        actions.add(action);
        return true;
      },
      instance: (_) => instance.value,
    );
    VoidCallback? pressed(String label) => tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
        .onPressed;
    expect(pressed('继续'), isNotNull);
    expect(pressed('开始'), isNull);
    expect(pressed('暂停'), isNotNull);
    expect(pressed('停止'), isNotNull);
    expect(pressed('跳过休息'), isNull);

    await tester.tap(find.text('继续'));
    await _frames(tester);
    expect(actions, ['resume']);
    expect(find.textContaining('「继续」'), findsNothing); // 没有失败提示

    // 出错退出同样算没在跑
    instance.value = ScriptState.warning;
    await tester.pump();
    expect(pressed('继续'), isNotNull);

    // 实例在跑，或还不知道（刚连上为 updating，总览里没有这个实例为 null）：不可用
    for (final state in [ScriptState.running, ScriptState.updating, null]) {
      instance.value = state;
      await tester.pump();
      expect(pressed('继续'), isNull, reason: '$state');
      expect(pressed('开始'), isNull, reason: '$state');
      expect(pressed('暂停'), isNotNull, reason: '$state');
      expect(pressed('停止'), isNotNull, reason: '$state');
    }

    // 暂停时照旧可用，不论实例在不在跑
    server = _bundle(rows,
        settings: {'state': 'paused'},
        progress: {'phase': 'row_running', 'row_index': 0});
    await _nextPoll(tester);
    for (final state in [ScriptState.running, ScriptState.inactive, null]) {
      instance.value = state;
      await tester.pump();
      expect(pressed('继续'), isNotNull, reason: '$state');
      expect(pressed('开始'), isNull, reason: '$state');
    }

    // 序列已停止：实例没在运行也不可用，开始照常可用
    instance.value = ScriptState.inactive;
    server = _bundle(rows);
    await _nextPoll(tester);
    expect(pressed('继续'), isNull);
    expect(pressed('开始'), isNotNull);
  });

  testWidgets('test_view_stop_mid_row_no_row_end_wording', (tester) async {
    // 停止立即停下实例、进度清零，不再等本行打完。进度没清零时（如写进度失败）也只说未运行，
    // 实例在跑、还不知道时都一样
    final instance = Rx<ScriptState?>(ScriptState.running);
    final rows = [
      {'task': 'Orochi'},
      {'task': 'RealmRaid'},
    ];
    var server = _bundle(rows,
        settings: {'state': 'idle'},
        progress: {'phase': 'row_running', 'row_index': 0});
    await _show(tester, (_) async => server, instance: (_) => instance.value);
    for (final state in [ScriptState.running, null]) {
      instance.value = state;
      await tester.pump();
      expect(find.text('状态：未运行'), findsOneWidget, reason: '$state');
      expect(find.textContaining('本行打完后'), findsNothing, reason: '$state');
    }

    // 停止会丢掉续跑：中断的那一行不再补完或重跑，提示不这样说
    server = _bundle(rows,
        settings: {'state': 'idle'},
        progress: {'phase': 'interrupted', 'row_index': 1});
    await _nextPoll(tester);
    expect(find.text('状态：未运行'), findsOneWidget);
    expect(find.text('提示：第 2 行中断'), findsOneWidget);
  });

  testWidgets('test_view_long_status_wraps_in_narrow_window', (tester) async {
    await _show(
      tester,
      (_) async => _bundle(
        [
          {'task': 'Orochi'}
        ],
        settings: {'state': 'running'},
        progress: {'phase': 'ready', 'row_index': 0},
      ),
      instance: (_) => ScriptState.inactive,
    );
    // 状态行加了实例未运行的说明，窄窗口里一行放不下：换行显示，不溢出
    tester.view.physicalSize = const Size(480, 2400);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('状态：运行中（等待第 1 行） · 实例未运行，按继续接着跑'), findsOneWidget);
  });

  testWidgets('test_view_row_buttons', (tester) async {
    final c = await _show(
      tester,
      (_) async => _bundle([
        {'task': 'Orochi'},
        {'task': 'RealmRaid'},
      ]),
    );
    List<String> tasks() => [for (final row in c.editor.rows) row.task];

    // 新增行沿用上一行的任务
    await tester.tap(find.text('新增行'));
    await _frames(tester);
    expect(tasks(), ['Orochi', 'RealmRaid', 'RealmRaid']);

    // 第一行不能上移，最后一行不能下移
    IconButton button(String tooltip, int row) => tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, _icons[tooltip]!).at(row));
    expect(button('上移', 0).onPressed, isNull);
    expect(button('下移', 2).onPressed, isNull);

    await tester.tap(find.byTooltip('上移').at(1));
    await _frames(tester);
    expect(tasks(), ['RealmRaid', 'Orochi', 'RealmRaid']);
    expect(_taskDropdown(tester, 0).value, 'RealmRaid');

    await tester.tap(find.text('删除').first);
    await _frames(tester);
    expect(tasks(), ['Orochi', 'RealmRaid']);
    expect(_taskDropdown(tester, 0).value, 'Orochi');
    expect(c.dirty.value, isTrue);
  });

  testWidgets('test_view_polls_only_while_visible', (tester) async {
    final reads = {'oas1': 0, 'oas2': 0};
    for (final name in reads.keys.toList()) {
      Get.put(
        OrchestraController(name, getOrchestra: (_) async {
          reads[name] = reads[name]! + 1;
          return _bundle([]);
        }),
        tag: name,
      );
    }
    await tester.pumpWidget(_app('oas1'));
    expect(reads, {'oas1': 1, 'oas2': 0});
    await tester.pump(const Duration(seconds: 2));
    expect(reads, {'oas1': 2, 'oas2': 0});

    // 换到 oas2：oas1 停止轮询，oas2 开始
    await tester.pumpWidget(_app('oas2'));
    await tester.pump(const Duration(seconds: 4));
    expect(reads, {'oas1': 2, 'oas2': 3});

    // 离开编排页：都停
    await tester.pumpWidget(_app(null));
    await tester.pump(const Duration(seconds: 4));
    expect(reads, {'oas1': 2, 'oas2': 3});
  });

  testWidgets('test_view_relayout_keeps_polling', (tester) async {
    var reads = 0;
    Get.put(
      OrchestraController('oas1', getOrchestra: (_) async {
        reads++;
        return _bundle([]);
      }),
      tag: 'oas1',
    );
    // 窗口宽度跨过桌面与窄屏布局的分界时，页面换到别的父节点下重建：
    // 同一帧里同一实例的新页先建、旧页后销毁
    Widget layout({required bool wide}) => MaterialApp(
          home: Scaffold(
            body: wide
                ? const Row(children: [
                    SizedBox(width: 10),
                    Expanded(child: OrchestraView(script: 'oas1')),
                  ])
                : const Center(child: OrchestraView(script: 'oas1')),
          ),
        );
    await tester.pumpWidget(layout(wide: true));
    expect(reads, 1);

    // 换布局后照常每 2 秒读一次
    await tester.pumpWidget(layout(wide: false));
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 3);
    await tester.pumpWidget(layout(wide: true));
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 5);

    // 最后一个页面没了才停
    await tester.pumpWidget(_app(null));
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 5);
  });

  test('test_assets_check_url_adds_scheme_only_when_missing', () {
    expect(assetsCheckUrl('127.0.0.1:22288'),
        'http://127.0.0.1:22288/tool/assets-check');
    expect(assetsCheckUrl('http://127.0.0.1:22288'),
        'http://127.0.0.1:22288/tool/assets-check');
    expect(assetsCheckUrl('https://oas.local:8443/'),
        'https://oas.local:8443/tool/assets-check');
  });
}

const _icons = {'上移': Icons.arrow_upward, '下移': Icons.arrow_downward};
