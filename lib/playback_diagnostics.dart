import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diary_service.dart';

// Never expose session paths, signed URLs, or raw playlist/key contents.
String safePlaybackMessage(String text) => text
    .replaceAll(RegExp(r'https?://[^\s\]\)<>"\x27]+'), '[URL已隐藏]')
    .replaceAll(RegExp(r'[a-fA-F0-9]{32,}'), '[凭证已隐藏]');

List<Uri> playlistResources(String body, Uri base) {
  final result = <Uri>[];
  for (final line in const LineSplitter().convert(body)) {
    final text = line.trim();
    if (text.startsWith('#EXT-X-KEY:')) {
      final match = RegExp('URI="([^"]+)"').firstMatch(text);
      if (match != null) result.add(base.resolve(match.group(1)!));
    } else if (text.isNotEmpty && !text.startsWith('#')) {
      result.add(base.resolve(text));
    }
  }
  return result;
}

bool isLocalPlaybackUri(Uri uri, Uri root) =>
    uri.scheme == 'http' &&
    uri.host == '127.0.0.1' &&
    uri.port == root.port &&
    uri.userInfo.isEmpty;

Future<void> probePlayback(String address, int attempt) async {
  final root = Uri.tryParse(address);
  if (root == null || !isLocalPlaybackUri(root, root)) return;
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 4);
  final deadline = Timer(const Duration(seconds: 12), () {
    client.close(force: true);
  });
  final visited = <Uri>{};
  var requests = 0;
  Future<void> inspect(Uri uri, String kind, int depth) async {
    if (requests >= 5 || depth > 2 || !isLocalPlaybackUri(uri, root)) return;
    if (!visited.add(uri)) return;
    requests++;
    final watch = Stopwatch()..start();
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-16383');
    final response = await request.close();
    final bytes = <int>[];
    // Cancel after a bounded prefix, never download an entire episode.
    await for (final chunk in response.timeout(const Duration(seconds: 3))) {
      bytes.addAll(chunk.take(16384 - bytes.length));
      if (bytes.length >= 16384) break;
    }
    final type = response.headers.contentType?.mimeType ?? 'unknown';
    DiaryService.add('[Probe#$attempt] $kind HTTP=${response.statusCode} '
        'type=$type prefix=${bytes.length}B elapsed=${watch.elapsedMilliseconds}ms');
    final body = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (body.startsWith('#EXTM3U')) {
      final resources = playlistResources(body, uri);
      DiaryService.add('[Probe#$attempt] M3U8 valid=true '
          'encrypted=${body.contains('#EXT-X-KEY:')} '
          'master=${body.contains('#EXT-X-STREAM-INF:')} resources=${resources.length}');
      // Key and the first media/child-playlist request only.
      final keyLines = body.split('\n').where((l) => l.startsWith('#EXT-X-KEY:'));
      final key = keyLines.isEmpty ? null : RegExp('URI="([^"]+)"').firstMatch(keyLines.first);
      if (key != null) await inspect(uri.resolve(key.group(1)!), 'key', depth + 1);
      final media = body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#'));
      if (media.isNotEmpty) await inspect(uri.resolve(media.first), 'media', depth + 1);
    } else if (kind == 'playlist') {
      DiaryService.add('[Probe#$attempt] M3U8 valid=false');
    }
  }
  try {
    await inspect(root, root.path.endsWith('.m3u8') ? 'playlist' : 'media', 0);
  } catch (error) {
    DiaryService.add('[Probe#$attempt] failure=${safePlaybackMessage(error.toString())}');
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}
