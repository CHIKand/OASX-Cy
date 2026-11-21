// 编排页的数据模型：与 OAS 编排接口（/custom/orchestra）的 JSON 互转、
// 行编辑、就地校验。
//
// JSON 键与后端一致，用下划线命名。缺键、值为 null 或类型不对时取后端的默认值，
// 解析不抛异常。
// 校验规则与文案同后端 validate_rows（oas module/orchestra/model.py）。

/// 编排表的一行，即一轮。task 之外的字段为 null 表示未填。
class OrchestraRow {
  String task;
  String? sub1;
  String? sub2;
  int? maxCount;
  int? maxMinutes;
  int? restMinutes;

  OrchestraRow({
    required this.task,
    this.sub1,
    this.sub2,
    this.maxCount,
    this.maxMinutes,
    this.restMinutes,
  });

  factory OrchestraRow.fromJson(Map<String, dynamic> json) => OrchestraRow(
        task: _string(json['task']) ?? '',
        sub1: _string(json['sub1']),
        sub2: _string(json['sub2']),
        maxCount: _int(json['max_count']),
        maxMinutes: _int(json['max_minutes']),
        restMinutes: _int(json['rest_minutes']),
      );

  Map<String, dynamic> toJson() => {
        'task': task,
        'sub1': sub1,
        'sub2': sub2,
        'max_count': maxCount,
        'max_minutes': maxMinutes,
        'rest_minutes': restMinutes,
      };
}

/// 子项，即界面上的一个下拉框：options 是取值，labels 是一一对应的显示文案。
/// 目录的 required 不读：必选的只有爬塔类型，validateRow 同后端按任务名判断。
class SubSpec {
  final List<String> options;
  final List<String> labels;

  SubSpec({required this.options, required this.labels});

  factory SubSpec.fromJson(Map<String, dynamic> json) => SubSpec(
        options: _strings(json['options']) ?? [],
        labels: _strings(json['labels']) ?? [],
      );

  Map<String, dynamic> toJson() => {'options': options, 'labels': labels};
}

/// 任务目录的一项：一个支持编排的任务，以及它有哪些格可填。
class TaskCatalogEntry {
  final String command;
  final String title;
  final int? countMax; // 次数上限，null 表示没有上限
  final bool hasCount;
  final bool hasTime;
  final List<SubSpec> subs; // 依次对应 sub1、sub2

  TaskCatalogEntry({
    required this.command,
    required this.title,
    this.countMax,
    required this.hasCount,
    required this.hasTime,
    required this.subs,
  });

  factory TaskCatalogEntry.fromJson(Map<String, dynamic> json) =>
      TaskCatalogEntry(
        command: _string(json['command']) ?? '',
        title: _string(json['title']) ?? '',
        countMax: _int(json['count_max']),
        hasCount: _bool(json['has_count']) ?? false,
        hasTime: _bool(json['has_time']) ?? false,
        subs: [for (final sub in _maps(json['subs'])) SubSpec.fromJson(sub)],
      );

  Map<String, dynamic> toJson() => {
        'command': command,
        'title': title,
        'count_max': countMax,
        'has_count': hasCount,
        'has_time': hasTime,
        'subs': [for (final sub in subs) sub.toJson()],
      };
}

/// 一个实例的编排配置，对应后端的 Orchestra。构造参数为 null 时取后端的默认值。
/// state、command、command_seq 是运行控制字段，只由命令接口和引擎写入，
/// 保存时后端不读。
class OrchestraSettings {
  List<OrchestraRow> rows;
  String afterFinish; // stop / loop
  int? totalMinutesCap; // null 表示不限
  int defaultRestMinutes;
  bool restJitter;
  String resumePolicy; // remaining / rerun
  List<String> cutInTasks;
  String state; // idle / running / paused
  String command;
  int commandSeq;

  OrchestraSettings({
    List<OrchestraRow>? rows,
    String? afterFinish,
    this.totalMinutesCap,
    int? defaultRestMinutes,
    bool? restJitter,
    String? resumePolicy,
    List<String>? cutInTasks,
    String? state,
    String? command,
    int? commandSeq,
  })  : rows = rows ?? [],
        afterFinish = afterFinish ?? 'stop',
        defaultRestMinutes = defaultRestMinutes ?? 5,
        restJitter = restJitter ?? false,
        resumePolicy = resumePolicy ?? 'remaining',
        cutInTasks = cutInTasks ?? ['MetaDemon', 'ActivityShikigami'],
        state = state ?? 'idle',
        command = command ?? '',
        commandSeq = commandSeq ?? 0;

  factory OrchestraSettings.fromJson(Map<String, dynamic> json) =>
      OrchestraSettings(
        rows: [
          for (final row in _maps(json['rows'])) OrchestraRow.fromJson(row)
        ],
        afterFinish: _string(json['after_finish']),
        totalMinutesCap: _int(json['total_minutes_cap']),
        defaultRestMinutes: _int(json['default_rest_minutes']),
        restJitter: _bool(json['rest_jitter']),
        resumePolicy: _string(json['resume_policy']),
        cutInTasks: _strings(json['cut_in_tasks']),
        state: _string(json['state']),
        command: _string(json['command']),
        commandSeq: _int(json['command_seq']),
      );

  Map<String, dynamic> toJson() => {
        'rows': [for (final row in rows) row.toJson()],
        'after_finish': afterFinish,
        'total_minutes_cap': totalMinutesCap,
        'default_rest_minutes': defaultRestMinutes,
        'rest_jitter': restJitter,
        'resume_policy': resumePolicy,
        'cut_in_tasks': cutInTasks,
        'state': state,
        'command': command,
        'command_seq': commandSeq,
      };
}

/// 运行进度，给运行面板用，只取面板用到的键。构造参数为 null 时取后端的默认值。
/// 后端多给的键不读，如 row_task、paused、saved_params 和各时间戳。
class OrchestraProgress {
  // idle / ready / row_running / resting / interrupted / done
  final String phase;
  final int rowIndex;
  final int loopCount;
  final int? doneCount; // 本行已完成的次数，未知为 null
  final double? rowElapsedSeconds; // 本行已跑的秒数，只在 row_running 阶段有值
  final double? restRemainingSeconds; // 剩余休息秒数，只在休息中（含休息时暂停）有值
  final double totalElapsed; // 秒
  final List<Map<String, dynamic>> history;
  final String statusNote; // 如 防封禁休眠中，08:00 继续

  OrchestraProgress({
    String? phase,
    int? rowIndex,
    int? loopCount,
    this.doneCount,
    this.rowElapsedSeconds,
    this.restRemainingSeconds,
    double? totalElapsed,
    List<Map<String, dynamic>>? history,
    String? statusNote,
  })  : phase = phase ?? 'idle',
        rowIndex = rowIndex ?? 0,
        loopCount = loopCount ?? 0,
        totalElapsed = totalElapsed ?? 0.0,
        history = history ?? [],
        statusNote = statusNote ?? '';

  factory OrchestraProgress.fromJson(Map<String, dynamic> json) =>
      OrchestraProgress(
        phase: _string(json['phase']),
        rowIndex: _int(json['row_index']),
        loopCount: _int(json['loop_count']),
        doneCount: _int(json['done_count']),
        rowElapsedSeconds: _double(json['row_elapsed_seconds']),
        restRemainingSeconds: _double(json['rest_remaining_seconds']),
        totalElapsed: _double(json['total_elapsed']),
        history: _maps(json['history']),
        statusNote: _string(json['status_note']),
      );

  Map<String, dynamic> toJson() => {
        'phase': phase,
        'row_index': rowIndex,
        'loop_count': loopCount,
        'done_count': doneCount,
        'row_elapsed_seconds': rowElapsedSeconds,
        'rest_remaining_seconds': restRemainingSeconds,
        'total_elapsed': totalElapsed,
        'history': history,
        'status_note': statusNote,
      };
}

/// GET /custom/orchestra/{实例} 的返回：编排设置、运行进度、任务目录。
class OrchestraBundle {
  OrchestraSettings settings;
  OrchestraProgress progress;
  List<TaskCatalogEntry> catalog;

  OrchestraBundle({
    required this.settings,
    required this.progress,
    required this.catalog,
  });

  factory OrchestraBundle.fromJson(Map<String, dynamic> json) =>
      OrchestraBundle(
        settings: OrchestraSettings.fromJson(_map(json['settings'])),
        progress: OrchestraProgress.fromJson(_map(json['progress'])),
        catalog: [
          for (final entry in _maps(json['catalog']))
            TaskCatalogEntry.fromJson(entry)
        ],
      );

  Map<String, dynamic> toJson() => {
        'settings': settings.toJson(),
        'progress': progress.toJson(),
        'catalog': [for (final entry in catalog) entry.toJson()],
      };
}

/// 一行的就地校验，规则与文案同后端 validate_rows。
/// 返回 字段名 → 文案，字段名用后端的下划线命名；空 Map 表示通过。
///
/// spec 为 null 表示任务不在目录里，只报这一条，不再查其他项。
/// 任务没有的字段有值、子项不在可选范围内，在表格里编辑时不会出现，
/// 但映射表或上游枚举改动后读回的旧行可能这样，所以同样照后端报出。
Map<String, String> validateRow(OrchestraRow row, TaskCatalogEntry? spec) {
  if (spec == null) return {'task': '不支持编排的任务'};
  final errors = <String, String>{};

  final sub1 = row.sub1;
  if (sub1 == null) {
    // 爬塔的次数按类型分开存放，不选类型就没有落点；后端同样按任务名判断
    if (row.task == 'ActivityShikigami') errors['sub1'] = '请选择爬塔类型';
  } else if (!_subInOptions(spec, 0, sub1)) {
    errors['sub1'] = '子项不在可选范围内';
  }
  final sub2 = row.sub2;
  if (sub2 != null && !_subInOptions(spec, 1, sub2)) {
    errors['sub2'] = '子项不在可选范围内';
  }

  final count = row.maxCount;
  if (count != null) {
    final countMax = spec.countMax;
    if (!spec.hasCount) {
      errors['max_count'] = '该任务没有次数上限';
    } else if (countMax != null) {
      if (count < 1 || count > countMax) {
        errors['max_count'] = '次数需在 1–$countMax 之间';
      }
    } else if (count < 1) {
      errors['max_count'] = '次数需不小于 1';
    }
  }

  final minutes = row.maxMinutes;
  if (minutes != null) {
    if (!spec.hasTime) {
      errors['max_minutes'] = '该任务没有时长上限';
    } else if (minutes < 1 || minutes > 1439) {
      errors['max_minutes'] = '分钟需在 1–1439 之间';
    }
  }

  final rest = row.restMinutes;
  if (rest != null && (rest < 0 || rest > 1439)) {
    errors['rest_minutes'] = '休息需在 0–1439 之间';
  }
  return errors;
}

/// 编排表的行编辑。构造时复制传入的各行，编辑不会改到调用方手里的行。
/// 下标越界的操作什么也不做，不抛异常。
class RowsEditor {
  List<OrchestraRow> rows;

  RowsEditor([List<OrchestraRow> rows = const []])
      : rows = [for (final row in rows) OrchestraRow.fromJson(row.toJson())];

  /// 在表尾加一行，任务之外都未填。
  void add(String task) => rows.add(OrchestraRow(task: task));

  void remove(int i) {
    if (_has(i)) rows.removeAt(i);
  }

  /// 第一行上移什么也不做。
  void moveUp(int i) {
    if (_has(i) && i > 0) _swap(i - 1, i);
  }

  /// 最后一行下移什么也不做。
  void moveDown(int i) {
    if (_has(i) && i < rows.length - 1) _swap(i, i + 1);
  }

  /// 换任务，只清掉新任务用不上的值：
  /// - 新任务没有次数或时长，清空对应格；
  /// - 子项在新任务里没有这一格，或旧值不在可选范围内，清空。
  ///
  /// 仍然适用的数值即使越界也保留，由 validateRow 标红；休息与任务无关，保留。
  void changeTask(int i, String task, TaskCatalogEntry spec) {
    if (!_has(i)) return;
    final row = rows[i]..task = task;
    if (!spec.hasCount) row.maxCount = null;
    if (!spec.hasTime) row.maxMinutes = null;
    if (!_subInOptions(spec, 0, row.sub1)) row.sub1 = null;
    if (!_subInOptions(spec, 1, row.sub2)) row.sub2 = null;
  }

  bool _has(int i) => i >= 0 && i < rows.length;

  void _swap(int a, int b) {
    final row = rows[a];
    rows[a] = rows[b];
    rows[b] = row;
  }
}

/// 子项取值是否在任务第 position 个下拉框的可选范围内；没有这一格时为 false。
bool _subInOptions(TaskCatalogEntry spec, int position, String? value) =>
    value != null &&
    position < spec.subs.length &&
    spec.subs[position].options.contains(value);

// JSON 取值：类型不对按缺失处理，返回 null，由调用方取默认值。

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is num ? value.toInt() : null;

// 秒数一般带小数（如 12.5），也可能是整数，按 num 读再转 double
double? _double(Object? value) => value is num ? value.toDouble() : null;

bool? _bool(Object? value) => value is bool ? value : null;

List<String>? _strings(Object? value) => value is List
    ? [
        for (final e in value)
          if (e is String) e
      ]
    : null;

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? [
        for (final e in value)
          if (e is Map) Map<String, dynamic>.from(e)
      ]
    : [];
