import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:github/github.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../../utils/constants.dart';

/// Service for interacting with GitHub as encrypted storage backend
class GitHubService {
  final GitHub _github;
  final String _repoOwner;
  final String _repoName;
  final String _branch;

  GitHubService({
    required String accessToken,
    required String repoOwner,
    required String repoName,
    String branch = Constants.dataBranch,
    http.Client? client,
  })  : _github = GitHub(
          auth: Authentication.bearerToken(accessToken),
          client: client,
        ),
        _repoOwner = repoOwner,
        _repoName = repoName,
        _branch = branch;

  RepositorySlug get _slug => RepositorySlug(_repoOwner, _repoName);

  String get registryScope =>
      '${'$_repoOwner/$_repoName'.toLowerCase()}@$_branch';

  Future<http.Response> _snapshotRequest(
    String method,
    String path, {
    String? body,
  }) async {
    try {
      return await _github
          .request(method, path, body: body)
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw GitHubException(
        'GitHub request timed out. Please retry.',
        kind: 'timeout',
      );
    } catch (_) {
      throw GitHubException(
        'GitHub is unavailable. Please retry.',
        kind: 'network',
      );
    }
  }

  /// Reads content and its update precondition in the same response.
  Future<RemoteFileSnapshot> readFileSnapshot(String path) async {
    final response = await _snapshotRequest(
      'GET',
      '/repos/$_repoOwner/$_repoName/contents/$path?ref=${Uri.encodeQueryComponent(_branch)}',
    );
    if (response.statusCode == 404) {
      final branch = await _snapshotRequest(
        'GET',
        '/repos/$_repoOwner/$_repoName/branches/${Uri.encodeComponent(_branch)}',
      );
      if (branch.statusCode == 404) {
        throw GitHubException(
          'Registry branch is unavailable',
          statusCode: 404,
          kind: 'missing_branch',
        );
      }
      _checkResponse(branch, 'Check registry branch');
      return const RemoteFileSnapshot.missing();
    }
    _checkResponse(response, 'Read file');
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final sha = json['sha'] as String;
      final encoded = json['content'] as String;
      if (sha.isEmpty || encoded.isEmpty || json['encoding'] != 'base64') {
        throw const FormatException();
      }
      final date = response.headers['date'];
      final serverTime = date == null
          ? null
          : DateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", 'en_US')
              .parseUtc(date);
      return RemoteFileSnapshot(
        serverTime: serverTime,
        bytes: base64Decode(encoded.replaceAll(RegExp(r'\s'), '')),
        sha: sha,
      );
    } catch (_) {
      throw GitHubException(
        'Invalid remote file response',
        kind: 'invalid_data',
      );
    }
  }

  /// A single compare-and-swap attempt. The caller must rebase on conflict.
  Future<String> writeFileSnapshot({
    required String path,
    required Uint8List content,
    required String? expectedSha,
    required String commitMessage,
  }) async {
    final response = await _snapshotRequest(
      'PUT',
      '/repos/$_repoOwner/$_repoName/contents/$path',
      body: jsonEncode({
        'message': commitMessage,
        'content': base64Encode(content),
        'branch': _branch,
        if (expectedSha != null) 'sha': expectedSha,
      }),
    );
    // GitHub may report a concurrent create as 422 (missing required SHA).
    if (response.statusCode == 422 && expectedSha == null) {
      final latest = await readFileSnapshot(path);
      if (latest.exists) {
        throw GitHubException('Concurrent file creation', statusCode: 409);
      }
    }
    _checkResponse(response, 'Write file');
    try {
      final sha = (jsonDecode(response.body)['content']['sha']) as String;
      if (sha.isEmpty) throw const FormatException();
      return sha;
    } catch (_) {
      throw GitHubException('Invalid write response', kind: 'invalid_data');
    }
  }

  /// Checks if the response is successful (2xx), throws if not
  void _checkResponse(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw GitHubException(
      '$action failed (HTTP ${response.statusCode})',
      statusCode: response.statusCode,
      kind: response.statusCode == 429 ||
              (response.statusCode == 403 &&
                  (response.headers['x-ratelimit-remaining'] == '0' ||
                      response.headers.containsKey('retry-after')))
          ? 'rate_limit'
          : 'http',
    );
  }

  /// Uploads or updates a file in the repository on the data branch
  /// Returns the commit SHA
  Future<String> uploadFile({
    required String path,
    required Uint8List content,
    String commitMessage = 'Update entry',
    bool isRetry = false,
  }) async {
    if (path == Constants.trustedDevicesFile) {
      throw StateError('Registry writes require an explicit snapshot SHA');
    }
    try {
      // Check if file exists to get its SHA for updates
      String? existingSha;
      try {
        final response = await _github.request(
          'GET',
          '/repos/$_repoOwner/$_repoName/contents/$path?ref=$_branch',
        );
        if (response.statusCode == 200) {
          final responseJson =
              jsonDecode(response.body) as Map<String, dynamic>;
          existingSha = responseJson['sha'] as String?;
        }
      } catch (e) {
        // File doesn't exist yet, that's fine
        existingSha = null;
      }

      // Encode content as base64
      final base64Content = base64Encode(content);

      // Use raw API to create/update on the data branch
      final body = <String, dynamic>{
        'message': commitMessage,
        'content': base64Content,
        'branch': _branch,
      };
      if (existingSha != null) {
        body['sha'] = existingSha;
      }

      final response = await _github.request(
        'PUT',
        '/repos/$_repoOwner/$_repoName/contents/$path',
        body: jsonEncode(body),
      );

      _checkResponse(response, 'Upload file "$path"');

      final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
      final commit = responseJson['commit'] as Map<String, dynamic>?;
      return commit?['sha'] as String? ?? '';
    } catch (e) {
      if (e is GitHubException) {
        // Check if error is due to branch not existing (only retry once)
        final errorStr = e.toString().toLowerCase();
        if (!isRetry &&
            (errorStr.contains('not found') ||
                errorStr.contains('empty') ||
                errorStr.contains('git repository is empty') ||
                errorStr.contains('409') ||
                errorStr.contains('404') ||
                errorStr.contains('422') ||
                errorStr.contains('no commit found') ||
                errorStr.contains('branch'))) {
          // Ensure data branch exists and retry
          await _ensureDataBranch();

          // Retry the upload (with isRetry flag to prevent infinite recursion)
          return await uploadFile(
            path: path,
            content: content,
            commitMessage: commitMessage,
            isRetry: true,
          );
        }
      }
      throw e is GitHubException
          ? e
          : GitHubException('Failed to upload file: $e');
    }
  }

  /// Downloads a file from the repository on the data branch
  /// Returns the file content as bytes, or null if file not found
  Future<Uint8List?> downloadFile(String path) async {
    return (await readFileSnapshot(path)).bytes;
  }

  /// Lists all files in a directory on the data branch
  Future<List<String>> listFiles(String path) async {
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/contents/$path?ref=$_branch',
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        _checkResponse(response, 'List files "$path"');
      }
      if (response.statusCode != 200) return [];

      final items = jsonDecode(response.body) as List<dynamic>;
      return items
          .where((item) => (item as Map<String, dynamic>)['type'] == 'file')
          .map((item) => (item as Map<String, dynamic>)['name'] as String)
          .toList();
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return [];
      }
      throw e is GitHubException
          ? e
          : GitHubException('Failed to list files: $e');
    }
  }

  /// Deletes a file from the repository on the data branch
  Future<void> deleteFile({
    required String path,
    String commitMessage = 'Delete entry',
  }) async {
    try {
      // Get file SHA from the data branch
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/contents/$path?ref=$_branch',
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        _checkResponse(response, 'Get file SHA "$path"');
      }
      if (response.statusCode != 200) return;

      final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
      final sha = responseJson['sha'] as String?;

      if (sha == null) return;

      // Delete file on the data branch
      final deleteResponse = await _github.request(
        'DELETE',
        '/repos/$_repoOwner/$_repoName/contents/$path',
        body: jsonEncode({
          'message': commitMessage,
          'sha': sha,
          'branch': _branch,
        }),
      );
      _checkResponse(deleteResponse, 'Delete file "$path"');
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return; // File already gone
      }
      throw e is GitHubException
          ? e
          : GitHubException('Failed to delete file: $e');
    }
  }

  /// Checks if the repository exists and is accessible
  /// Throws GitHubException with details on failure
  Future<bool> verifyRepository() async {
    try {
      final repo = await _github.repositories.getRepository(_slug);

      // If repository is empty, initialize it
      if (repo.size == 0) {
        await _initializeRepository();
      } else {
        // Check if data branch exists, create it if not
        await _ensureDataBranch();
      }

      return true;
    } catch (e) {
      final errorStr = e.toString();

      if (e is GitHubException) rethrow;

      if (errorStr.contains('404')) {
        throw GitHubException(
          'Repository not found. Check owner/repo name, or verify token has repository access.',
        );
      } else if (errorStr.contains('401')) {
        throw GitHubException(
          'Invalid token. Generate a new token at github.com/settings/tokens',
        );
      } else if (errorStr.contains('403')) {
        throw GitHubException(
          'Insufficient permissions. Token needs Metadata and Contents permissions.',
        );
      } else {
        throw GitHubException('Failed to verify repository: $e');
      }
    }
  }

  /// Initializes the repository: README on main, then creates data branch
  Future<void> _initializeRepository() async {
    // First, create README on the default branch
    const readmeContent = '''# GitVault Encrypted Storage

This repository contains encrypted vault data from GitVault password manager.

**DO NOT DELETE OR MODIFY FILES MANUALLY**

All data is end-to-end encrypted on your device. Even if this repository is compromised,
your passwords remain secure as only you have the encryption key.

Vault data is stored on the `data` branch.

---
Generated by [GitVault](https://github.com/giofahreza/gitvault)
''';

    final base64Content = base64Encode(utf8.encode(readmeContent));

    // Check if README exists on default branch
    String? readmeSha;
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/contents/README.md',
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        readmeSha = json['sha'] as String?;
      }
    } catch (_) {}

    final readmeBody = <String, dynamic>{
      'message': 'Initialize GitVault storage',
      'content': base64Content,
    };
    if (readmeSha != null) {
      readmeBody['sha'] = readmeSha;
    }

    final readmeResponse = await _github.request(
      'PUT',
      '/repos/$_repoOwner/$_repoName/contents/README.md',
      body: jsonEncode(readmeBody),
    );
    _checkResponse(readmeResponse, 'Create README');

    // Now create the data branch
    await _ensureDataBranch();
  }

  /// Ensures the data branch exists, creates it from default branch if not
  Future<void> _ensureDataBranch() async {
    // Check if data branch exists
    bool branchExists = false;
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/branches/$_branch',
      );
      if (response.statusCode == 200) {
        branchExists = true;
      }
    } catch (e) {
      // Branch likely doesn't exist
      branchExists = false;
    }

    if (branchExists) return;

    // Branch doesn't exist, create it
    // Get the SHA of the default branch's latest commit
    final repo = await _github.repositories.getRepository(_slug);
    final defaultBranch = repo.defaultBranch;

    final refResponse = await _github.request(
      'GET',
      '/repos/$_repoOwner/$_repoName/git/ref/heads/$defaultBranch',
    );
    _checkResponse(refResponse, 'Get default branch ref');

    final refJson = jsonDecode(refResponse.body) as Map<String, dynamic>;
    final sha = (refJson['object'] as Map<String, dynamic>)['sha'] as String;

    // Create the data branch
    final createResponse = await _github.request(
      'POST',
      '/repos/$_repoOwner/$_repoName/git/refs',
      body: jsonEncode({
        'ref': 'refs/heads/$_branch',
        'sha': sha,
      }),
    );
    _checkResponse(createResponse, 'Create data branch');
  }

  /// Gets the latest commit SHA on the data branch
  Future<String?> getLatestCommitSha() async {
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/commits?sha=$_branch&per_page=1',
      );
      if (response.statusCode != 200) return null;
      final commits = jsonDecode(response.body) as List<dynamic>;
      if (commits.isNotEmpty) {
        return (commits[0] as Map<String, dynamic>)['sha'] as String?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Disposes of the GitHub client
  void dispose() {
    _github.dispose();
  }
}

/// Custom exception for GitHub errors
class GitHubException implements Exception {
  final String message;
  final int? statusCode;
  final String? kind;
  bool get isConflict => statusCode == 409;
  GitHubException(this.message, {this.statusCode, this.kind});

  @override
  String toString() => 'GitHubException: $message';
}

class RemoteFileSnapshot {
  final Uint8List? bytes;
  final String? sha;
  final DateTime? serverTime;
  bool get exists => sha != null;
  const RemoteFileSnapshot({
    required this.bytes,
    required this.sha,
    this.serverTime,
  });
  const RemoteFileSnapshot.missing()
      : bytes = null,
        sha = null,
        serverTime = null;
}
