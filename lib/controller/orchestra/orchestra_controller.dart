// 编排页的控制器，每个实例一个，以实例名作 tag。
//
// bundle 是最近一次读到的服务端数据（设置含 state、进度、目录），每次读到都换新，状态行和运行面板用它。
// 用户的草稿另放：editor 是表格各行，draft 是序列设置。只在没有未保存的修改时按服务端数据重建草稿；
// 重建是新建 RowsEditor（构造时复制各行），不给 editor.rows 赋值，草稿与服务端数据不共用行对象。
// 轮询每 2 秒读一次，由页面在可见时开始、隐藏时停止。

import 'dart:async';

import 'package:get/get.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/api/orchestra_api.dart';
import 'package:oasx/model/orchestra_model.dart';

typedef GetOrchestraFn = Future<OrchestraBundle?> Function(String script);
typedef PutOrchestraFn = Future<List<Map<String, dynamic>>> Function(
    String script, OrchestraSettings settings);
typedef OrchestraCommandFn = Future<bool> Function(
    String script, String action);

const _pollInterval = Duration(seconds: 2);

class OrchestraController extends GetxController {
  /// 接口函数默认走 ApiClient，测试时换成假的。
  OrchestraController(
    this.script, {
    GetOrchestraFn getOrchestra = _apiGet,
    PutOrchestraFn putOrchestra = _apiPut,
    OrchestraCommandFn orchestraCommand = _apiCommand,
  })  : _getOrchestra = getOrchestra,
        _putOrchestra = putOrchestra,
        _orchestraCommand = orchestraCommand;

  final String script; // 实例名
  final GetOrchestraFn _getOrchestra;
  final PutOrchestraFn _putOrchestra;
  final OrchestraCommandFn _orchestraCommand;

  /// 最近一次读到的服务端数据，还没读到时为 null。
  final bundle = Rx<OrchestraBundle?>(null);

  /// 表格草稿。没有未保存的修改时随服务端数据整个换掉，视图每次都从控制器取，不要自己留着。
  RowsEditor editor = RowsEditor();

  /// 序列设置草稿。rows 与 editor.rows 是同一个列表；state 等运行控制字段看 bundle。
  OrchestraSettings draft = OrchestraSettings();

  /// 草稿有未保存的修改。
  final dirty = false.obs;

  /// 行号 → 字段名 → 文案；-1 是序列设置的错误，字段名可能为空串。
  final errors = <int, Map<String, String>>{}.obs;

  /// 后端没有编排接口（GET 返回 404）。
  final backendMissing = false.obs;

  /// 最近一次读取失败（404 以外：连不上、503 等），bundle 是旧数据或仍为 null。
  /// 读到结果（含 404）即清除。只记状态，不弹提示。
  final readFailing = false.obs;

  Timer? _timer;
  int _requested = 0; // 已发出的读取次数，即最近一次读取的序号
  int _acceptFrom = 1; // 序号小于它的读取结果不再采用
  int _edits = 0; // edited() 的调用次数

  @override
  void onClose() {
    stopPolling();
    super.onClose();
  }

  /// 开始每 2 秒读一次，并立即读一次。已在轮询时什么也不做，每个实例始终只有一个定时器。
  void startPolling() {
    if (_timer?.isActive ?? false) return;
    _timer = Timer.periodic(_pollInterval, (_) => refreshProgress());
    unawaited(refreshProgress());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// 读一次服务端数据。bundle 总是换成读到的；没有未保存的修改时，草稿也按它重建。
  /// 404 置 backendMissing；其他失败保留上一次的数据，置 readFailing，下一轮再读。
  Future<void> refreshProgress() async {
    final seq = ++_requested;
    final OrchestraBundle? fresh;
    try {
      fresh = await _getOrchestra(script);
    } catch (e) {
      // 不弹提示，免得每 2 秒弹一次；只记状态和调试日志。
      // 失败与结果按同一序号规则取舍：序号已作废的失败不算，旧的失败不把新数据标成过时
      printError(info: '[$script] 编排读取失败：$e');
      if (!isClosed && seq >= _acceptFrom) readFailing.value = true;
      return;
    }
    // 结果回来的先后不一定同发出的先后：比已采用的更早发出的作废，旧数据不盖新数据
    if (isClosed || seq < _acceptFrom) return;
    _acceptFrom = seq + 1;
    readFailing.value = false;
    if (fresh == null) {
      backendMissing.value = true;
      return;
    }
    backendMissing.value = false;
    bundle.value = fresh;
    if (dirty.value) return;
    editor = RowsEditor(fresh.settings.rows);
    draft = OrchestraSettings.fromJson(fresh.settings.toJson())
      ..rows = editor.rows;
    errors.assignAll(_validate());
  }

  /// 视图改过 editor 或 draft 之后调用：标记未保存，并按当前目录重新校验每一行。
  void edited() {
    _edits++;
    dirty.value = true;
    errors.assignAll(_validate());
  }

  /// 保存草稿，返回是否已存下。
  ///
  /// 本地校验不过不发请求，红字留在 errors；后端报错按行号填入 errors；
  /// 保存成功清除未保存标记和错误，并立即重读。
  /// 还没读到过服务端数据时什么也不做，免得用空表盖掉已有的编排。
  Future<bool> save() async {
    if (bundle.value == null) return false;
    draft.rows = editor.rows;
    final local = _validate();
    errors.assignAll(local);
    if (local.isNotEmpty) return false;

    final edits = _edits;
    final serverErrors = await _putOrchestra(script, draft);
    // 保存途中又改过：结果对应的是发出时的草稿，保持未保存，红字以本地校验为准
    if (edits != _edits) return serverErrors.isEmpty;
    if (serverErrors.isNotEmpty) {
      errors.assignAll(_byIndex(serverErrors));
      return false;
    }
    dirty.value = false;
    errors.clear();
    // 保存前发出的读取可能带着旧表，结果作废，再立即读回
    _acceptFrom = _requested + 1;
    await refreshProgress();
    return true;
  }

  /// 发送控制命令，返回后端是否接受。接受后立即重读，运行面板不必等下一轮。
  Future<bool> command(String action) async {
    final ok = await _orchestraCommand(script, action);
    if (ok) await refreshProgress();
    return ok;
  }

  /// 任务在目录里的条目；不在目录里或还没读到目录时为 null。
  TaskCatalogEntry? specOf(String task) {
    for (final entry in bundle.value?.catalog ?? const <TaskCatalogEntry>[]) {
      if (entry.command == task) return entry;
    }
    return null;
  }

  /// 按目录校验 editor 的每一行，只收有错的行。
  Map<int, Map<String, String>> _validate() {
    final result = <int, Map<String, String>>{};
    for (var i = 0; i < editor.rows.length; i++) {
      final row = editor.rows[i];
      final rowErrors = validateRow(row, specOf(row.task));
      if (rowErrors.isNotEmpty) result[i] = rowErrors;
    }
    return result;
  }
}

/// 后端的错误列表按行号归组；行号缺失或不是整数的归到序列设置（-1）。
Map<int, Map<String, String>> _byIndex(List<Map<String, dynamic>> list) {
  final result = <int, Map<String, String>>{};
  for (final e in list) {
    final index = e['index'];
    final row = result.putIfAbsent(index is int ? index : -1, () => {});
    row['${e['field'] ?? ''}'] = '${e['message'] ?? ''}';
  }
  return result;
}

// 默认的接口函数。ApiClient 构造时要找 SettingsController，所以用到时才取单例。

Future<OrchestraBundle?> _apiGet(String script) =>
    ApiClient().getOrchestra(script);

Future<List<Map<String, dynamic>>> _apiPut(
        String script, OrchestraSettings settings) =>
    ApiClient().putOrchestra(script, settings);

Future<bool> _apiCommand(String script, String action) =>
    ApiClient().orchestraCommand(script, action);
