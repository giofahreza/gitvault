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
  })  : _github = GitHub(auth: Authentication.withToken(accessToken)),
        _repoOwner = repoOwner,
        _repoName = repoName;

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
          RepositorySlug(_repoOwner, _repoName),
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

      // Create or update file
      final result = await _github.repositories.createFile(
        RepositorySlug(_repoOwner, _repoName),
        CreateFile(
          path: path,
          message: commitMessage,
          content: base64Content,
        ),
      );

      return result.commit?.sha ?? '';
    } catch (e) {
      throw GitHubException('Failed to upload file: $e');
    }
  }

  /// Downloads a file from the repository
  /// Returns the file content as bytes
  Future<Uint8List?> downloadFile(String path) async {
    try {
      final contents = await _github.repositories.getContents(
        RepositorySlug(_repoOwner, _repoName),
        path,
      );

      if (contents.file == null) {
        return null;
      }

      // Decode from base64
      final base64Content = contents.file!.content?.replaceAll('\n', '') ?? '';
      return base64Decode(base64Content);
    } catch (e) {
      if (e.toString().contains('404')) {
        return null; // File not found
      }
      throw GitHubException('Failed to download file: $e');
    }
  }

  /// Lists all files in a directory
  Future<List<String>> listFiles(String path) async {
    try {
      final contents = await _github.repositories.getContents(
        RepositorySlug(_repoOwner, _repoName),
        path,
      );

      return contents.tree
              ?.where((item) => item.type == 'file')
              .map((item) => item.name ?? '')
              .where((name) => name.isNotEmpty)
              .toList() ??
          [];
    } catch (e) {
      if (e.toString().contains('404')) {
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
        RepositorySlug(_repoOwner, _repoName),
        path,
      );

      if (contents.file == null) {
        return; // File doesn't exist
      }

      // Note: GitHub API v3 delete requires different approach
      // For now, this is a placeholder
      // await _github.repositories.deleteFile(...);
      throw UnimplementedError('File deletion not yet implemented');
    } catch (e) {
      throw GitHubException('Failed to delete file: $e');
    }
  }

  /// Checks if the repository exists and is accessible
  Future<bool> verifyRepository() async {
    try {
      await _github.repositories.getRepository(
        RepositorySlug(_repoOwner, _repoName),
      );
      return true; // If we can access it, it exists
    } catch (e) {
      return false;
    }
  }

  /// Gets the latest commit SHA
  Future<String?> getLatestCommitSha() async {
    try {
      final commits = _github.repositories.listCommits(
        RepositorySlug(_repoOwner, _repoName),
      );

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
