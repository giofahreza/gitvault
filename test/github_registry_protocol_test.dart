import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/utils/constants.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

GitHubService service(Future<http.Response> Function(http.Request) handler) =>
    GitHubService(
      accessToken: 'secret-test-token',
      repoOwner: 'owner',
      repoName: 'repo',
      client: MockClient(handler),
    );

http.Response fileResponse({
  String content = 'AQID',
  String sha = 'blob-sha',
}) =>
    http.Response(
      jsonEncode({'content': content, 'sha': sha, 'encoding': 'base64'}),
      200,
      headers: {'date': 'Sun, 22 Nov 2026 12:00:00 GMT'},
    );

void main() {
  test('GitHub 403 rate limits remain distinguishable from permissions',
      () async {
    final github = service(
      (_) async => http.Response(
        '{}',
        403,
        headers: {'x-ratelimit-remaining': '0'},
      ),
    );
    addTearDown(github.dispose);
    await expectLater(
      github.readFileSnapshot(Constants.trustedDevicesFile),
      throwsA(
          isA<GitHubException>().having((e) => e.kind, 'kind', 'rate_limit')),
    );
  });
  test('snapshot couples bytes, SHA and server time in one GET', () async {
    var calls = 0;
    final github = service((request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.url.queryParameters['ref'], Constants.dataBranch);
      return fileResponse(content: 'AQ\nID');
    });
    addTearDown(github.dispose);
    final snapshot =
        await github.readFileSnapshot(Constants.trustedDevicesFile);
    expect(snapshot.bytes, [1, 2, 3]);
    expect(snapshot.sha, 'blob-sha');
    expect(snapshot.serverTime, DateTime.utc(2026, 11, 22, 12));
    expect(calls, 1);
  });

  test('PUT sends exact expected SHA without rereading', () async {
    var calls = 0;
    final github = service((request) async {
      calls++;
      expect(request.method, 'PUT');
      final body = jsonDecode(request.body) as Map;
      expect(body['sha'], 'the-read-sha');
      expect(body['content'], 'AQID');
      expect(body['branch'], Constants.dataBranch);
      return http.Response('{"content":{"sha":"committed-blob"}}', 200);
    });
    addTearDown(github.dispose);
    expect(
      await github.writeFileSnapshot(
        path: Constants.trustedDevicesFile,
        content: Uint8List.fromList([1, 2, 3]),
        expectedSha: 'the-read-sha',
        commitMessage: 'Approve device recovery request',
      ),
      'committed-blob',
    );
    expect(calls, 1);
  });

  for (final status in [401, 403, 409, 429, 500, 502, 503]) {
    for (final write in [false, true]) {
      test(
          '${write ? 'write' : 'read'} HTTP $status fails with sanitized typed status',
          () async {
        var calls = 0;
        final github = service((_) async {
          calls++;
          return http.Response(
            '{"message":"secret-test-token root-key decrypted-data"}',
            status,
          );
        });
        addTearDown(github.dispose);
        final operation = write
            ? github.writeFileSnapshot(
                path: Constants.trustedDevicesFile,
                content: Uint8List(1),
                expectedSha: 'old',
                commitMessage: 'test',
              )
            : github.readFileSnapshot(Constants.trustedDevicesFile);
        await expectLater(
          operation,
          throwsA(
            isA<GitHubException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.toString(),
                  'safe error',
                  isNot(contains('secret-test-token')),
                ),
          ),
        );
        expect(calls, 1);
      });
    }
  }

  for (final branchExists in [true, false]) {
    test(
        '404 distinguishes ${branchExists ? 'missing file' : 'missing branch'}',
        () async {
      final github = service(
        (request) async => request.url.path.contains('/branches/')
            ? http.Response('{}', branchExists ? 200 : 404)
            : http.Response('{}', 404),
      );
      addTearDown(github.dispose);
      if (branchExists) {
        expect(
          (await github.readFileSnapshot(Constants.trustedDevicesFile)).exists,
          false,
        );
      } else {
        await expectLater(
          github.readFileSnapshot(Constants.trustedDevicesFile),
          throwsA(
            isA<GitHubException>()
                .having((e) => e.kind, 'kind', 'missing_branch'),
          ),
        );
      }
    });
  }

  for (final response in [
    fileResponse(content: ''),
    fileResponse(content: '!!!'),
    fileResponse(sha: ''),
    http.Response('not json', 200),
    http.Response('{"sha":"x","content":12}', 200),
  ]) {
    test('malformed or empty existing content fails closed ${response.body}',
        () async {
      final github = service((_) async => response);
      addTearDown(github.dispose);
      await expectLater(
        github.readFileSnapshot(Constants.trustedDevicesFile),
        throwsA(
          isA<GitHubException>().having((e) => e.kind, 'kind', 'invalid_data'),
        ),
      );
    });
  }

  test('concurrent create 422 is a conflict only if a file now exists',
      () async {
    final github = service(
      (request) async =>
          request.method == 'PUT' ? http.Response('{}', 422) : fileResponse(),
    );
    addTearDown(github.dispose);
    await expectLater(
      github.writeFileSnapshot(
        path: Constants.trustedDevicesFile,
        content: Uint8List(1),
        expectedSha: null,
        commitMessage: 'test',
      ),
      throwsA(
        isA<GitHubException>().having((e) => e.isConflict, 'conflict', true),
      ),
    );
  });

  test('422 validation failure does not initialize branches or retry',
      () async {
    var calls = 0;
    final github = service((_) async {
      calls++;
      return http.Response('{}', 422);
    });
    addTearDown(github.dispose);
    await expectLater(
      github.writeFileSnapshot(
        path: Constants.trustedDevicesFile,
        content: Uint8List(1),
        expectedSha: 'old',
        commitMessage: 'test',
      ),
      throwsA(
        isA<GitHubException>().having((e) => e.statusCode, 'status', 422),
      ),
    );
    expect(calls, 1);
  });

  test('network and timeout failures are sanitized', () async {
    for (final error in [
      http.ClientException('secret-test-token'),
      TimeoutException('secret-test-token'),
    ]) {
      final github = service((_) async => throw error);
      try {
        await expectLater(
          github.readFileSnapshot(Constants.trustedDevicesFile),
          throwsA(
            isA<GitHubException>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains('secret-test-token')),
            ),
          ),
        );
      } finally {
        github.dispose();
      }
    }
  });

  test('generic upload refuses registry writes', () async {
    final github = service((_) async => throw StateError('must not request'));
    addTearDown(github.dispose);
    await expectLater(
      github.uploadFile(
        path: Constants.trustedDevicesFile,
        content: Uint8List(1),
      ),
      throwsStateError,
    );
  });
}
