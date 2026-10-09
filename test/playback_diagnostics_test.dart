import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/playback_diagnostics.dart';
import 'package:duanju_app/diary_service.dart';

void main() {
  test('diagnostic redacts URLs and key material', () {
    final result = safePlaybackMessage('failed http://127.0.0.1:8/secret/master.m3u8?token=abc key=0123456789abcdef0123456789abcdef');
    expect(result, isNot(contains('secret')));
    expect(result, isNot(contains('token=abc')));
    expect(result, isNot(contains('0123456789abcdef')));
  });
  test('playlist resolves key, child and segment paths', () {
    final base = Uri.parse('http://127.0.0.1:123/token/master.m3u8');
    final resources = playlistResources('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.key"\n#EXTINF:1,\nseg.ts\n', base);
    expect(resources.map((u) => u.path), ['/token/key.key', '/token/seg.ts']);
    expect(isLocalPlaybackUri(Uri.parse('https://remote.test/a'), base), false);
    expect(isLocalPlaybackUri(Uri.parse('http://127.0.0.1:124/a'), base), false);
    expect(isLocalPlaybackUri(resources.first, base), true);
  });
  test('probe reads local playlist, key and bounded media with no secret output', () async {
    DiaryService.clear();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    server.listen((request) async {
      seen.add(request.uri.path);
      if (request.uri.path.endsWith('index.m3u8')) {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.key"\n#EXTINF:1,\nseg.ts\n');
      } else if (request.uri.path.endsWith('key.key')) {
        request.response.add(List.filled(16, 7));
      } else {
        request.response.statusCode = 206;
        request.response.add(List.filled(16384, 0x47));
      }
      await request.response.close();
    });
    try {
      await probePlayback('http://127.0.0.1:${server.port}/private-token/index.m3u8', 1);
      expect(seen.length, 3);
      expect(DiaryService.fullText, contains('M3U8 valid=true'));
      expect(DiaryService.fullText, contains('key HTTP=200'));
      expect(DiaryService.fullText, contains('media HTTP=206'));
      expect(DiaryService.fullText, isNot(contains('private-token')));
    } finally {
      await server.close(force: true);
    }
  });
}
