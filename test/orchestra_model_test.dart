import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/model/orchestra_model.dart';

// GET /custom/orchestra/{实例} 的样例，只含模型保留的键；
// 目录各项取自 OAS 映射表（module/orchestra/mapping.py）。
// 每个键都有非默认值，漏读哪个键往返结果都会不同，所以运行面板的两个秒数同时给了值。
const _sample = r'''
{
  "settings": {
    "rows": [
      {"task": "Orochi", "sub1": "悲鸣", "sub2": null, "max_count": 50, "max_minutes": 60, "rest_minutes": 10},
      {"task": "EvoZone", "sub1": "火麒麟", "sub2": "拾层", "max_count": null, "max_minutes": 30, "rest_minutes": null},
      {"task": "RealmRaid", "sub1": null, "sub2": null, "max_count": 30, "max_minutes": null, "rest_minutes": 0}
    ],
    "after_finish": "loop",
    "total_minutes_cap": 300,
    "default_rest_minutes": 8,
    "rest_jitter": true,
    "resume_policy": "rerun",
    "cut_in_tasks": ["MetaDemon"],
    "state": "running",
    "command": "start",
    "command_seq": 3
  },
  "progress": {
    "phase": "row_running",
    "row_index": 1,
    "row_task": "EvoZone",
    "loop_count": 2,
    "done_count": 7,
    "row_elapsed_seconds": 12.5,
    "rest_remaining_seconds": 287.5,
    "total_elapsed": 1830.25,
    "history": [
      {"row_index": 0, "task": "Orochi", "started_at": "2026-11-21T08:00:00",
       "ended_at": "2026-11-21T08:30:12.500000", "done_count": 50, "loop_count": 2}
    ],
    "status_note": "防封禁休眠中，08:00 继续"
  },
  "catalog": [
    {"command": "Orochi", "title": "御魂·八岐大蛇", "count_max": null, "has_count": true, "has_time": true,
     "subs": [{"options": ["壹层", "贰层", "叁层", "肆层", "伍层", "陆层", "柒层", "捌层", "玖层", "拾层", "悲鸣", "神罚", "虚无"],
               "labels": ["壹层", "贰层", "叁层", "肆层", "伍层", "陆层", "柒层", "捌层", "玖层", "拾层", "悲鸣", "神罚", "虚无"]}]},
    {"command": "EternitySea", "title": "御魂·永生之海", "count_max": null, "has_count": true, "has_time": true,
     "subs": [{"options": ["壹层", "贰层", "叁层", "肆层"], "labels": ["壹层", "贰层", "叁层", "肆层"]}]},
    {"command": "EvoZone", "title": "肝帝·觉醒副本", "count_max": null, "has_count": true, "has_time": true,
     "subs": [{"options": ["火麒麟", "风麒麟", "水麒麟", "雷麒麟"], "labels": ["火麒麟", "风麒麟", "水麒麟", "雷麒麟"]},
              {"options": ["壹层", "贰层", "叁层", "肆层", "伍层", "陆层", "柒层", "捌层", "玖层", "拾层"],
               "labels": ["壹层", "贰层", "叁层", "肆层", "伍层", "陆层", "柒层", "捌层", "玖层", "拾层"]}]},
    {"command": "FindJade", "title": "肝帝·寻找协作", "count_max": null, "has_count": false, "has_time": false, "subs": []},
    {"command": "RealmRaid", "title": "个人突破", "count_max": 30, "has_count": true, "has_time": false, "subs": []},
    {"command": "ActivityShikigami", "title": "限时·爬塔", "count_max": null, "has_count": true, "has_time": true,
     "subs": [{"options": ["pass", "ap", "boss", "ap100"], "labels": ["门票", "体力", "Boss", "100体"]}]}
  ]
}
''';

Map<String, dynamic> _decode(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

// 样例目录里某个任务的条目
TaskCatalogEntry _spec(String command) =>
    OrchestraBundle.fromJson(_decode(_sample))
        .catalog
        .firstWhere((e) => e.command == command);

void main() {
  test('test_bundle_parse_roundtrip', () {
    final sample = _decode(_sample);
    expect(OrchestraBundle.fromJson(sample).toJson(), sample);

    // 后端实际返回的进度还有别的键，目录的子项还带 required：
    // 都不保留，也不影响其余各项
    final withExtras = _decode(_sample);
    (withExtras['progress'] as Map<String, dynamic>).addAll({
      'sequence_started_at': '2026-11-21T08:00:00',
      'row_started_at': '2026-11-21T08:30:13',
      'heartbeat_at': '2026-11-21T08:30:25',
      'row_elapsed_before': 0.0,
      'rest_until': null,
      'rest_remaining': null,
      'saved_params': {'evo_zone.evo_zone_config.layer': '壹层'},
      'last_command_seq': 3,
      'paused': false,
    });
    for (final entry in withExtras['catalog'] as List) {
      for (final sub in entry['subs'] as List) {
        sub['required'] = entry['command'] == 'ActivityShikigami';
      }
    }
    expect(OrchestraBundle.fromJson(withExtras).toJson(), sample);

    // 秒数在 JSON 里通常带小数，写成整数时也按 double 读
    final resting = OrchestraProgress.fromJson(_decode(
        '{"phase": "resting", "rest_remaining_seconds": 300, "total_elapsed": 60}'));
    expect(resting.restRemainingSeconds, 300.0);
    expect(resting.totalElapsed, 60.0);
  });

  test('test_bundle_parse_handles_missing_fields', () {
    // 后端未升级时可能缺键或给 null：一律取后端的默认值，不抛异常。
    // 默认值即后端 Orchestra()、Progress() 的序列化结果
    const defaultSettings = {
      'rows': [],
      'after_finish': 'stop',
      'total_minutes_cap': null,
      'default_rest_minutes': 5,
      'rest_jitter': false,
      'resume_policy': 'remaining',
      'cut_in_tasks': ['MetaDemon', 'ActivityShikigami'],
      'state': 'idle',
      'command': '',
      'command_seq': 0,
    };
    const defaultProgress = {
      'phase': 'idle',
      'row_index': 0,
      'row_task': null,
      'loop_count': 0,
      'done_count': null,
      'row_elapsed_seconds': null,
      'rest_remaining_seconds': null,
      'total_elapsed': 0.0,
      'history': [],
      'status_note': '',
    };
    final allNull = <Map<String, dynamic>>[
      {},
      {'settings': null, 'progress': null, 'catalog': null},
      {
        'settings': {for (final key in defaultSettings.keys) key: null},
        'progress': {for (final key in defaultProgress.keys) key: null},
        'catalog': [],
      },
    ];
    for (final json in allNull) {
      final bundle = OrchestraBundle.fromJson(json);
      expect(bundle.settings.toJson(), defaultSettings);
      expect(bundle.progress.toJson(), defaultProgress);
      expect(bundle.catalog, isEmpty);
    }

    // 行与目录项缺键时同样取默认值
    final partial = OrchestraBundle.fromJson({
      'settings': {
        'rows': [
          {'task': 'Orochi'},
          {},
        ],
      },
      'catalog': [
        {
          'command': 'FindJade',
          'subs': [{}],
        },
      ],
    });
    expect(partial.settings.rows.map((r) => r.toJson()).toList(), [
      {
        'task': 'Orochi',
        'sub1': null,
        'sub2': null,
        'max_count': null,
        'max_minutes': null,
        'rest_minutes': null
      },
      {
        'task': '',
        'sub1': null,
        'sub2': null,
        'max_count': null,
        'max_minutes': null,
        'rest_minutes': null
      },
    ]);
    expect(partial.catalog.single.toJson(), {
      'command': 'FindJade',
      'title': '',
      'count_max': null,
      'has_count': false,
      'has_time': false,
      'subs': [
        {'options': [], 'labels': []},
      ],
    });
  });

  test('test_validate_realm_raid_over_30', () {
    final raid = _spec('RealmRaid');
    expect(validateRow(OrchestraRow(task: 'RealmRaid', maxCount: 31), raid),
        {'max_count': '次数需在 1–30 之间'});
    expect(validateRow(OrchestraRow(task: 'RealmRaid', maxCount: 0), raid),
        {'max_count': '次数需在 1–30 之间'});
    expect(
        validateRow(
            OrchestraRow(task: 'RealmRaid', maxCount: 30, restMinutes: 0),
            raid),
        isEmpty);
  });

  test('test_validate_activity_requires_type', () {
    final activity = _spec('ActivityShikigami');
    expect(
        validateRow(
            OrchestraRow(task: 'ActivityShikigami', maxCount: 10), activity),
        {'sub1': '请选择爬塔类型'});
    expect(
        validateRow(
            OrchestraRow(task: 'ActivityShikigami', sub1: 'pass', maxCount: 10),
            activity),
        isEmpty);
    // 其他任务不选子项即沿用任务自己的设置，不报错
    expect(validateRow(OrchestraRow(task: 'Orochi'), _spec('Orochi')), isEmpty);
  });

  // 计划用例之外的补充：表中其余文案，以及后端 validate_rows 的另外几条规则
  test('test_validate_other_rules_match_backend', () {
    final orochi = _spec('Orochi');
    expect(validateRow(OrchestraRow(task: 'Orochi', maxCount: 0), orochi),
        {'max_count': '次数需不小于 1'});
    expect(
        validateRow(
            OrchestraRow(task: 'Orochi', maxMinutes: 0, restMinutes: -1),
            orochi),
        {'max_minutes': '分钟需在 1–1439 之间', 'rest_minutes': '休息需在 0–1439 之间'});
    expect(
        validateRow(
            OrchestraRow(task: 'Orochi', maxMinutes: 1440, restMinutes: 1440),
            orochi),
        {'max_minutes': '分钟需在 1–1439 之间', 'rest_minutes': '休息需在 0–1439 之间'});
    expect(
        validateRow(
            OrchestraRow(
                task: 'Orochi',
                maxCount: 9999,
                maxMinutes: 1439,
                restMinutes: 1439),
            orochi),
        isEmpty);
    // 任务不在目录里只报这一条
    expect(validateRow(OrchestraRow(task: 'KekkaiUtilize', maxCount: 0), null),
        {'task': '不支持编排的任务'});
    // 任务没有的字段、不在可选范围内的子项，例如上游改了枚举后读回的旧行
    expect(
        validateRow(OrchestraRow(task: 'FindJade', maxCount: 5, maxMinutes: 5),
            _spec('FindJade')),
        {'max_count': '该任务没有次数上限', 'max_minutes': '该任务没有时长上限'});
    expect(
        validateRow(
            OrchestraRow(task: 'Orochi', sub1: '火麒麟', sub2: '壹层'), orochi),
        {'sub1': '子项不在可选范围内', 'sub2': '子项不在可选范围内'});
  });

  test('test_editor_move_bounds', () {
    final editor = RowsEditor([
      OrchestraRow(task: 'Orochi'),
      OrchestraRow(task: 'EvoZone'),
      OrchestraRow(task: 'RealmRaid')
    ]);
    final before = List.of(editor.rows);
    editor
      ..moveUp(0)
      ..moveDown(2)
      ..moveUp(-1)
      ..moveUp(3)
      ..moveDown(-1)
      ..moveDown(3);
    expect(editor.rows, orderedEquals(before));

    // 界内移动与相邻行交换
    editor.moveUp(1);
    expect(editor.rows.map((r) => r.task).toList(),
        ['EvoZone', 'Orochi', 'RealmRaid']);
    editor.moveDown(1);
    expect(editor.rows.map((r) => r.task).toList(),
        ['EvoZone', 'RealmRaid', 'Orochi']);
  });

  test('test_editor_remove_last_row', () {
    final source = [OrchestraRow(task: 'Orochi')];
    final editor = RowsEditor(source)..remove(0);
    expect(editor.rows, isEmpty);
    editor.remove(0); // 越界下标什么也不做
    expect(editor.rows, isEmpty);
    // 空表照常保存成空列表
    expect(OrchestraSettings(rows: editor.rows).toJson()['rows'], isEmpty);
    // 编辑器改的是副本，传入的列表不变
    expect(source, hasLength(1));

    editor.add('RealmRaid');
    expect(editor.rows.single.toJson(), {
      'task': 'RealmRaid',
      'sub1': null,
      'sub2': null,
      'max_count': null,
      'max_minutes': null,
      'rest_minutes': null
    });
  });

  test('test_editor_change_task_clears_invalid_fields', () {
    final source = OrchestraRow(
        task: 'Orochi',
        sub1: '悲鸣',
        maxCount: 50,
        maxMinutes: 60,
        restMinutes: 10);
    final editor = RowsEditor([source])
      ..changeTask(0, 'FindJade', _spec('FindJade'));
    final row = editor.rows.single;
    expect(row.task, 'FindJade');
    expect(row.maxMinutes, isNull);
    expect(row.sub1, isNull);
    expect(row.maxCount, isNull); // 寻找协作也没有次数
    expect(row.restMinutes, 10); // 休息与任务无关，保留
    expect(validateRow(row, _spec('FindJade')), isEmpty);
    expect(source.task, 'Orochi'); // 改的是编辑器里的副本
    editor.changeTask(1, 'Orochi', _spec('Orochi')); // 越界下标什么也不做
    expect(editor.rows.single.task, 'FindJade');

    // 仍然适用的数值保留，越界也不清，由校验标红
    final toRaid = RowsEditor([
      OrchestraRow(
          task: 'Orochi',
          sub1: '悲鸣',
          maxCount: 50,
          maxMinutes: 60,
          restMinutes: 10)
    ])
      ..changeTask(0, 'RealmRaid', _spec('RealmRaid'));
    expect(toRaid.rows.single.toJson(), {
      'task': 'RealmRaid',
      'sub1': null,
      'sub2': null,
      'max_count': 50,
      'max_minutes': null,
      'rest_minutes': 10
    });
    expect(validateRow(toRaid.rows.single, _spec('RealmRaid')),
        {'max_count': '次数需在 1–30 之间'});

    // 子项在新任务的可选范围内就保留，不在或新任务没有这一格就清空
    final toSea = RowsEditor([OrchestraRow(task: 'Orochi', sub1: '壹层')])
      ..changeTask(0, 'EternitySea', _spec('EternitySea'));
    expect(toSea.rows.single.sub1, '壹层');
    final toOrochi = RowsEditor([
      OrchestraRow(task: 'EvoZone', sub1: '火麒麟', sub2: '壹层', maxMinutes: 30)
    ])
      ..changeTask(0, 'Orochi', _spec('Orochi'));
    expect(toOrochi.rows.single.toJson(), {
      'task': 'Orochi',
      'sub1': null,
      'sub2': null,
      'max_count': null,
      'max_minutes': 30,
      'rest_minutes': null
    });
  });
}
