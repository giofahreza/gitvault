import 'dart:convert';
import 'dart:typed_data';
import 'package:github/github.dart';

/// Service for interacting with GitHub as encrypted storage backend
class GitHubService {
  final GitHub _github;
  final String _repoOwner;
  final String _repoName;

  GitHubService({
    required String accessToken,
    required String repoOwner,
    required String repoName,
  })  : _github = GitHub(auth: Authentication.bearerToken(accessToken)),
        _repoOwner = repoOwner,
        _repoName = repoName;

  RepositorySlug get _slug => RepositorySlug(_repoOwner, _repoName);

  /// Uploads or updates a file in the repository
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
        final existingFile = await _github.repositories.getContents(
          _slug,
          path,
        );

        if (existingFile.file != null) {
          existingSha = existingFile.file!.sha;
        }
      } catch (e) {
        // File doesn't exist yet, that's fine
        existingSha = null;
      }

      // Encode content as base64
      final base64Content = base64Encode(content);

      // Use raw API to create/update (supports sha parameter for updates)
      final body = <String, dynamic>{
        'message': commitMessage,
        'content': base64Content,
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
      // Check if error is due to empty repository
      if (e.toString().contains('empty') || e.toString().contains('Git Repository is empty')) {
        // Initialize the repository and retry
        await _initializeEmptyRepository();

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

  /// Downloads a file from the repository
  /// Returns the file content as bytes
  Future<Uint8List?> downloadFile(String path) async {
    try {
      final contents = await _github.repositories.getContents(
        _slug,
        path,
      );

      if (contents.file == null) {
        return null;
      }

      // Decode from base64
      final base64Content = contents.file!.content?.replaceAll('\n', '') ?? '';
      return base64Decode(base64Content);
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return null; // File not found
      }
      throw GitHubException('Failed to download file: $e');
    }
  }

  /// Lists all files in a directory
  Future<List<String>> listFiles(String path) async {
    try {
      final contents = await _github.repositories.getContents(
        _slug,
        path,
      );

      return contents.tree
              ?.where((item) => item.type == 'file')
              .map((item) => item.name ?? '')
              .where((name) => name.isNotEmpty)
              .toList() ??
          [];
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('404') || errorStr.contains('not found')) {
        return []; // Directory doesn't exist yet
      }
      throw GitHubException('Failed to list files: $e');
    }
  }

  /// Deletes a file from the repository
  Future<void> deleteFile({
    required String path,
    String commitMessage = 'Delete entry',
  }) async {
    try {
      // Get file SHA (required for deletion)
      final contents = await _github.repositories.getContents(
        _slug,
        path,
      );

      if (contents.file == null) {
        return; // File doesn't exist
      }

      final sha = contents.file!.sha!;

      // Use the GitHub API directly to delete the file
      await _github.request(
        'DELETE',
        '/repos/$_repoOwner/$_repoName/contents/$path',
        body: jsonEncode({
          'message': commitMessage,
          'sha': sha,
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
      // Use getRepository instead of getContents to handle empty repos
      final repo = await _github.repositories.getRepository(_slug);

      // If repository is empty, initialize it with a README
      if (repo.size == 0) {
        await _initializeEmptyRepository();
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

  /// Initializes an empty repository with a README file
  Future<void> _initializeEmptyRepository() async {
    try {
      final readmeContent = '''# GitVault Encrypted Storage

This repository contains encrypted vault data from GitVault password manager.

**DO NOT DELETE OR MODIFY FILES MANUALLY**

All data is end-to-end encrypted on your device. Even if this repository is compromised,
your passwords remain secure as only you have the encryption key.

---
Generated by [GitVault](https://github.com/giofahreza/gitvault)
''';

      final content = utf8.encode(readmeContent);

      await uploadFile(
        path: 'README.md',
        content: Uint8List.fromList(content),
        commitMessage: 'Initialize GitVault storage',
      );
    } catch (e) {
      // If initialization fails, it's not critical - the repo might already be initialized
      // Just log and continue
    }
  }

  /// Gets the latest commit SHA
  Future<String?> getLatestCommitSha() async {
    try {
      final commits = _github.repositories.listCommits(_slug);

      await for (final commit in commits) {
        return commit.sha;
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
