import 'dart:convert';
import 'dart:typed_data';
import 'package:github/github.dart';

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
  })  : _github = GitHub(auth: Authentication.bearerToken(accessToken)),
        _repoOwner = repoOwner,
        _repoName = repoName,
        _branch = branch;

  RepositorySlug get _slug => RepositorySlug(_repoOwner, _repoName);

  /// Uploads or updates a file in the repository on the data branch
  /// Returns the commit SHA
  Future<String> uploadFile({
    required String path,
    required Uint8List content,
    String commitMessage = 'Update entry',
  }) async {
    try {
      // Check if file exists to get its SHA for updates
      String? existingSha;
      try {
        final response = await _github.request(
          'GET',
          '/repos/$_repoOwner/$_repoName/contents/$path?ref=$_branch',
        );
        final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
        existingSha = responseJson['sha'] as String?;
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

      final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
      final commit = responseJson['commit'] as Map<String, dynamic>?;
      return commit?['sha'] as String? ?? '';
    } catch (e) {
      // Check if error is due to branch not existing
      if (e.toString().contains('not found') ||
          e.toString().contains('empty') ||
          e.toString().contains('Git Repository is empty') ||
          e.toString().contains('409')) {
        // Initialize the repository and retry
        await _initializeRepository();

        // Retry the upload
        return await uploadFile(
          path: path,
          content: content,
          commitMessage: commitMessage,
        );
      }
      throw GitHubException('Failed to upload file: $e');
    }
  }

  /// Downloads a file from the repository on the data branch
  /// Returns the file content as bytes
  Future<Uint8List?> downloadFile(String path) async {
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/contents/$path?ref=$_branch',
      );

      final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
      final base64Content = (responseJson['content'] as String?)?.replaceAll('\n', '') ?? '';
      if (base64Content.isEmpty) return null;

      return base64Decode(base64Content);
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return null; // File not found
      }
      throw GitHubException('Failed to download file: $e');
    }
  }

  /// Lists all files in a directory on the data branch
  Future<List<String>> listFiles(String path) async {
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/contents/$path?ref=$_branch',
      );

      final items = jsonDecode(response.body) as List<dynamic>;
      return items
          .where((item) => (item as Map<String, dynamic>)['type'] == 'file')
          .map((item) => (item as Map<String, dynamic>)['name'] as String)
          .toList();
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return []; // Directory doesn't exist yet
      }
      throw GitHubException('Failed to list files: $e');
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

      final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
      final sha = responseJson['sha'] as String?;

      if (sha == null) return;

      // Delete file on the data branch
      await _github.request(
        'DELETE',
        '/repos/$_repoOwner/$_repoName/contents/$path',
        body: jsonEncode({
          'message': commitMessage,
          'sha': sha,
          'branch': _branch,
        }),
      );
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return; // File already gone
      }
      throw GitHubException('Failed to delete file: $e');
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

      if (errorStr.contains('404')) {
        throw GitHubException('Repository not found. Check owner/repo name, or verify token has repository access.');
      } else if (errorStr.contains('401')) {
        throw GitHubException('Invalid token. Generate a new token at github.com/settings/tokens');
      } else if (errorStr.contains('403')) {
        throw GitHubException('Insufficient permissions. Token needs Metadata and Contents permissions.');
      } else {
        throw GitHubException('Failed to verify repository: $e');
      }
    }
  }

  /// Initializes the repository: README on main, then creates data branch
  Future<void> _initializeRepository() async {
    try {
      // First, create README on the default branch
      final readmeContent = '''# GitVault Encrypted Storage

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
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        readmeSha = json['sha'] as String?;
      } catch (_) {}

      final readmeBody = <String, dynamic>{
        'message': 'Initialize GitVault storage',
        'content': base64Content,
      };
      if (readmeSha != null) {
        readmeBody['sha'] = readmeSha;
      }

      await _github.request(
        'PUT',
        '/repos/$_repoOwner/$_repoName/contents/README.md',
        body: jsonEncode(readmeBody),
      );

      // Now create the data branch
      await _ensureDataBranch();
    } catch (e) {
      // Not critical, continue
    }
  }

  /// Ensures the data branch exists, creates it from default branch if not
  Future<void> _ensureDataBranch() async {
    try {
      // Check if data branch exists
      await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/branches/$_branch',
      );
      // Branch exists
    } catch (e) {
      // Branch doesn't exist, create it
      try {
        // Get the SHA of the default branch's latest commit
        final repo = await _github.repositories.getRepository(_slug);
        final defaultBranch = repo.defaultBranch ?? 'main';

        final refResponse = await _github.request(
          'GET',
          '/repos/$_repoOwner/$_repoName/git/ref/heads/$defaultBranch',
        );
        final refJson = jsonDecode(refResponse.body) as Map<String, dynamic>;
        final sha = (refJson['object'] as Map<String, dynamic>)['sha'] as String;

        // Create the data branch
        await _github.request(
          'POST',
          '/repos/$_repoOwner/$_repoName/git/refs',
          body: jsonEncode({
            'ref': 'refs/heads/$_branch',
            'sha': sha,
          }),
        );
      } catch (createError) {
        throw GitHubException('Failed to create data branch: $createError');
      }
    }
  }

  /// Gets the latest commit SHA on the data branch
  Future<String?> getLatestCommitSha() async {
    try {
      final response = await _github.request(
        'GET',
        '/repos/$_repoOwner/$_repoName/commits?sha=$_branch&per_page=1',
      );
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
  GitHubException(this.message);

  @override
  String toString() => 'GitHubException: $message';
}
