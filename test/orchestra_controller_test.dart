import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/controller/orchestra/orchestra_controller.dart';
import 'package:oasx/model/orchestra_model.dart';

// 各测试都注入假的接口函数，不连网。
// 假目录：八岐大蛇有次数和时长、次数不设上限；个人突破次数 1–30、没有时长。
const _catalog = [
  {
    'command': 'Orochi',
    'title': '御魂·八岐大蛇',
    'count_max': null,
    'has_count': true,
    'has_time': true,
    'subs': [],
  },
  {
    'command': 'RealmRaid',
    'title': '个人突破',
    'count_max': 30,
    'has_count': true,
    'has_time': false,
    'subs': [],
  },
];

/// 服务端返回的数据：tasks 依次是编排表各行的任务，每行次数 10。
OrchestraBundle _server(List<String> tasks, {String phase = 'idle'}) =>
    OrchestraBundle.fromJson({
      'settings': {
        'rows': [
          for (final task in tasks) {'task': task, 'max_count': 10}
        ],
      },
      'progress': {'phase': phase},
      'catalog': _catalog,
    });

List<String> _tasks(List<OrchestraRow> rows) => [for (final r in rows) r.task];

void main() {
  // Get.put 会登记 onReady 的帧回调，要先有 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  test('test_controller_single_timer_per_tag', () async {
    // 只记下周期定时器，照常交给外层去建
    final timers = <Timer>[];
    final periods = <Duration>[];
    final counting = ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        periods.add(period);
        final timer = parent.createPeriodicTimer(zone, period, callback);
        timers.add(timer);
        return timer;
      },
    );
    int active() => timers.where((t) => t.isActive).length;

    var fetches = 0;
    Get.put(
      OrchestraController('oas1', getOrchestra: (_) async {
        fetches++;
        return _server(['Orochi']);
      }),
      tag: 'oas1',
    );
    runZoned(() {
      Get.find<OrchestraController>(tag: 'oas1').startPolling();
      // 切到别的实例再切回来，页面又调一次
      Get.find<OrchestraController>(tag: 'oas1').startPolling();
    }, zoneSpecification: counting);
    expect(timers, hasLength(1));
    expect(active(), 1);
    expect(periods, [const Duration(seconds: 2)]);
    expect(fetches, 1); // 第二次什么也没做，也没有多读一次

    // 页面隐藏后再显示：先停后开，仍只有一个在走
    final c = Get.find<OrchestraController>(tag: 'oas1');
    c.stopPolling();
    expect(active(), 0);
    runZoned(c.startPolling, zoneSpecification: counting);
    expect(active(), 1);

    // 控制器删除时定时器一并停掉
    Get.delete<OrchestraController>(tag: 'oas1');
    expect(active(), 0);
    await pumpEventQueue();
  });

  test('test_dirty_blocks_overwrite', () async {
    var server = _server(['Orochi']);
    final c = OrchestraController('oas1', getOrchestra: (_) async => server);

    // 没有未保存的修改：草稿按服务端数据建
    await c.refreshProgress();
    expect(_tasks(c.editor.rows), ['Orochi']);
    expect(c.dirty.value, isFalse);

    // 改一格、加一行、改一项序列设置
    c.editor.rows.first.maxCount = 20;
    c.editor.add('RealmRaid');
    c.draft.afterFinish = 'loop';
    c.edited();
    expect(c.dirty.value, isTrue);
    // 草稿是复制出来的，服务端数据不跟着变
    expect(c.bundle.value!.settings.rows.first.maxCount, 10);

    // 服务端换了表，进入休息
    server = _server(['RealmRaid', 'RealmRaid'], phase: 'resting');
    await c.refreshProgress();

    // 服务端数据照常换新，状态行和运行面板用得上
    expect(c.bundle.value!.progress.phase, 'resting');
    expect(_tasks(c.bundle.value!.settings.rows), ['RealmRaid', 'RealmRaid']);
    // 草稿保持用户改过的样子
    expect(_tasks(c.editor.rows), ['Orochi', 'RealmRaid']);
    expect(c.editor.rows.first.maxCount, 20);
    expect(c.draft.afterFinish, 'loop');
  });

  test('test_fetch_failures_keep_last_bundle', () async {
    OrchestraBundle? reply = _server(['Orochi']);
    var fail = false;
    final c = OrchestraController('oas1', getOrchestra: (_) async {
      if (fail) throw Exception('503');
      return reply;
    });
    await c.refreshProgress();
    final first = c.bundle.value;

    // 503、连不上等：不抛出，保留上一次的数据
    fail = true;
    await c.refreshProgress();
    expect(c.bundle.value, same(first));
    expect(c.backendMissing.value, isFalse);

    // 404：后端没有编排接口
    fail = false;
    reply = null;
    await c.refreshProgress();
    expect(c.backendMissing.value, isTrue);

    // 后端更新后恢复
    reply = _server(['RealmRaid']);
    await c.refreshProgress();
    expect(c.backendMissing.value, isFalse);
    expect(_tasks(c.editor.rows), ['RealmRaid']);
  });

  test('test_save_blocks_local_errors_and_maps_server_errors', () async {
    var server = _server(['Orochi']);
    final sent = <List<String>>[];
    var reply = <Map<String, dynamic>>[];
    final c = OrchestraController(
      'oas1',
      getOrchestra: (_) async => server,
      putOrchestra: (_, settings) async {
        sent.add(_tasks(settings.rows));
        if (reply.isEmpty) {
          // 假服务端存下这一版，之后读回的就是它
          server = OrchestraBundle(
            settings: OrchestraSettings.fromJson(settings.toJson()),
            progress: server.progress,
            catalog: server.catalog,
          );
        }
        return reply;
      },
    );
    await c.refreshProgress();

    // 本地校验不过：不发请求，红字留着
    c.editor.add('RealmRaid');
    c.editor.rows[1].maxCount = 31;
    c.edited();
    expect(await c.save(), isFalse);
    expect(sent, isEmpty);
    expect(c.errors, {
      1: {'max_count': '次数需在 1–30 之间'}
    });

    // 后端报错：按行号放进 errors，设置项的错误放在 -1
    c.editor.rows[1].maxCount = 30;
    c.edited();
    reply = [
      {'index': -1, 'field': 'cut_in_tasks', 'message': '取值不合法'},
      {'index': 0, 'field': 'max_minutes', 'message': '分钟需在 1–1439 之间'},
    ];
    expect(await c.save(), isFalse);
    expect(sent, [
      ['Orochi', 'RealmRaid']
    ]); // 发出的是 editor 里的行
    expect(c.errors, {
      -1: {'cut_in_tasks': '取值不合法'},
      0: {'max_minutes': '分钟需在 1–1439 之间'},
    });
    expect(c.dirty.value, isTrue);

    // 保存成功：清除未保存标记和错误，读回的就是刚存的表
    reply = [];
    expect(await c.save(), isTrue);
    expect(c.dirty.value, isFalse);
    expect(c.errors, isEmpty);
    expect(_tasks(c.editor.rows), ['Orochi', 'RealmRaid']);
  });

  test('test_command_refreshes_when_accepted', () async {
    var fetches = 0;
    var accepted = false;
    final actions = <String>[];
    final c = OrchestraController(
      'oas1',
      getOrchestra: (_) async {
        fetches++;
        return _server(['Orochi'], phase: 'row_running');
      },
      orchestraCommand: (_, action) async {
        actions.add(action);
        return accepted;
      },
    );

    // 后端不接受（如不在休息中时跳过休息）：不重读
    expect(await c.command('skip_rest'), isFalse);
    expect(fetches, 0);

    // 接受：立即重读，不等下一轮
    accepted = true;
    expect(await c.command('start'), isTrue);
    expect(fetches, 1);
    expect(c.bundle.value!.progress.phase, 'row_running');
    expect(actions, ['skip_rest', 'start']);
  });

  test('test_fetch_started_before_save_is_dropped', () async {
    final pending = <Completer<OrchestraBundle?>>[];
    final c = OrchestraController(
      'oas1',
      getOrchestra: (_) {
        final reply = Completer<OrchestraBundle?>();
        pending.add(reply);
        return reply.future;
      },
      putOrchestra: (_, __) async => [],
    );
    final load = c.refreshProgress();
    pending.single.complete(_server(['Orochi']));
    await load;
    c.editor.add('RealmRaid');
    c.edited();

    // 保存前发出一次轮询，服务端那时还是旧表
    final stale = c.refreshProgress();
    final saving = c.save();
    await pumpEventQueue(); // 保存已成功，读回的请求已发出
    expect(pending, hasLength(3));

    // 旧的轮询这时才回来：不再用它重建草稿
    pending[1].complete(_server(['Orochi']));
    await stale;
    expect(_tasks(c.editor.rows), ['Orochi', 'RealmRaid']);

    // 读回的是刚存的表
    pending[2].complete(_server(['Orochi', 'RealmRaid']));
    expect(await saving, isTrue);
    expect(_tasks(c.editor.rows), ['Orochi', 'RealmRaid']);
    expect(c.editor.rows[1].maxCount, 10); // 取自服务端，不是草稿里的空值
  });

  test('test_edit_during_save_stays_dirty', () async {
    final put = Completer<List<Map<String, dynamic>>>();
    final c = OrchestraController(
      'oas1',
      getOrchestra: (_) async => _server(['Orochi']),
      putOrchestra: (_, __) => put.future,
    );
    await c.refreshProgress();
    c.editor.add('RealmRaid');
    c.edited();

    final saving = c.save();
    // 请求还没回来，用户又改了一处
    c.editor.rows.first.maxCount = 20;
    c.edited();
    put.complete([]);
    expect(await saving, isTrue); // 发出的那一版已存下

    // 之后的修改还没保存：保持未保存，轮询不覆盖
    expect(c.dirty.value, isTrue);
    await c.refreshProgress();
    expect(c.editor.rows.first.maxCount, 20);
    expect(_tasks(c.editor.rows), ['Orochi', 'RealmRaid']);
  });
}
