// 编排接口（OAS /custom/orchestra，见 oas module/server/orchestra_router.py）。
//
// 读取供编排页每 2 秒轮询，不经 ApiClient.request：request 每次失败都弹提示，
// 后端没有这个接口或进度文件一时读不了时，会每 2 秒弹一次。
// 保存和命令由用户点按钮触发，照常经 request。

import 'package:flutter_nb_net/flutter_net.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/model/orchestra_model.dart';

extension OrchestraApi on ApiClient {
  /// 读取编排设置、运行进度与任务目录。
  ///
  /// 404 返回 null：后端没有这个接口（OAS 未更新），或实例不存在。
  /// 其他失败（连不上、503 进度文件暂时读不了等）抛 NetException，不弹提示。
  Future<OrchestraBundle?> getOrchestra(String script) async {
    final Result<dynamic> res = await get(_orchestraPath(script));
    return res.when<OrchestraBundle?>(
      success: (data) => data is Map
          ? OrchestraBundle.fromJson(Map<String, dynamic>.from(data))
          : throw NetException('编排接口返回的数据无法识别'),
      failure: (msg, code) =>
          code == 404 ? null : throw NetException(msg, code),
    );
  }

  /// 保存编排表与序列设置。返回后端报的错误 {index, field, message}，空列表表示已保存。
  ///
  /// 后端不读 state、command、command_seq。没拿到后端的结论（请求失败、返回无法识别）时，
  /// 返回一条行号 -1 的错误，保存失败不会被当成成功。
  Future<List<Map<String, dynamic>>> putOrchestra(
      String script, OrchestraSettings s) async {
    final res =
        await request(() => put(_orchestraPath(script), data: s.toJson()));
    final data = res.data;
    if (data is Map && data['ok'] == true) return [];
    final errors = data is Map ? data['errors'] : null;
    final list = [
      if (errors is List)
        for (final e in errors)
          if (e is Map) Map<String, dynamic>.from(e)
    ];
    if (list.isNotEmpty) return list;
    return [
      {'index': -1, 'field': '', 'message': '保存失败，请检查与 OAS 的连接'}
    ];
  }

  /// 控制命令：start / pause / resume / stop / skip_rest。
  /// 后端接受返回 true；不接受（如不在休息中时跳过休息）或请求失败返回 false。
  Future<bool> orchestraCommand(String script, String action) async {
    final res = await request(() =>
        post('${_orchestraPath(script)}/command', data: {'action': action}));
    final data = res.data;
    return data is Map && data['ok'] == true;
  }
}

/// 实例名编码成一个路径段，名字里有空格、斜杠等字符也不会拆成多段。
String _orchestraPath(String script) =>
    '/custom/orchestra/${Uri.encodeComponent(script)}';
