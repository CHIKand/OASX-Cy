// 工具页的素材维护入口：在浏览器里打开 OAS 的素材维护页（/tool/assets-check）。

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:styled_widget/styled_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:oasx/api/api_client.dart';

/// 素材维护页的地址。登录后 address 带 http://，登录前是不带协议的默认值，没有协议时补上。
String assetsCheckUrl(String address) {
  final base = address.contains('://') ? address : 'http://$address';
  return '${base.replaceAll(RegExp(r'/+$'), '')}/tool/assets-check';
}

class AssetsCheckEntry extends StatelessWidget {
  const AssetsCheckEntry({super.key});

  Future<void> _open() async {
    final url = assetsCheckUrl(ApiClient().address);
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url));
    } catch (_) {
      // 系统打不开链接时按未打开处理，下面提示手动访问
    }
    if (!opened) Get.snackbar('未能打开浏览器', '请手动访问 $url');
  }

  @override
  Widget build(BuildContext context) {
    return <Widget>[
      Text('素材维护',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text('在浏览器中打开 OAS 的素材维护页：查看缺图、替换素材。',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      MaterialButton(
        color: Theme.of(context).canvasColor,
        onPressed: _open,
        child: const Text('打开素材维护页'),
      ).constrained(width: 300),
    ]
        .toColumn(crossAxisAlignment: CrossAxisAlignment.start)
        .padding(all: 10)
        .card(margin: const EdgeInsets.all(10))
        .constrained(maxWidth: 300, width: 300);
  }
}
