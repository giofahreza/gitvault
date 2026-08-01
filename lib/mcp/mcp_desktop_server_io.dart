import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../core/session/vault_session_controller.dart';
import 'mcp_approval_controller.dart';
import 'mcp_client_registry.dart';
import 'mcp_desktop_server_state.dart';
import 'mcp_models.dart';
import 'mcp_paths_io.dart';
import 'mcp_server_factory.dart';

class McpDesktopServer extends ChangeNotifier {
  static const String endpointPath = '/mcp';
  static const int maximumRequestBytes = 1024 * 1024;
  static const int requestsPerMinute = 120;

  final McpClientRegistry _registry;
  final McpApprovalController _approvalController;
  final GitVaultMcpServerFactory _serverFactory;
  final VaultSessionState Function() _readSession;
  final Map<String, _McpSession> _sessions = {};
  final Map<String, List<DateTime>> _requestTimes = {};

  HttpServer? _httpServer;
  Future<void>? _lifecycleOperation;
  bool _initialized = false;
  bool _disposed = false;
  McpDesktopServerState _state = const McpDesktopServerState(
    status: McpDesktopServerStatus.stopped,
  );

  McpDesktopServer({
    required McpClientRegistry registry,
    required McpApprovalController approvalController,
    required GitVaultMcpServerFactory serverFactory,
    required VaultSessionState Function() readSession,
  })  : _registry = registry,
        _approvalController = approvalController,
        _serverFactory = serverFactory,
        _readSession = readSession;

  bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  McpDesktopServerState get state => _state;

  Future<void> initialize() async {
    if (_initialized || !isSupported) return;
    silenceMcpLogs();
    await _registry.initialize();
    await McpLocalPaths.ensureDirectories();
    _registry.addListener(_handleRegistryChanged);
    _initialized = true;
    await refresh();
  }

  Future<void> refresh() async {
    if (!isSupported || _disposed) return;
    await _registry.initialize();
    if (_registry.enabled) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> start() {
    final active = _lifecycleOperation;
    if (active != null) return active;
    if (_httpServer != null || !isSupported || !_registry.enabled) {
      _updateState();
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation = _start().whenComplete(() {
      if (identical(_lifecycleOperation, operation)) {
        _lifecycleOperation = null;
      }
    });
    _lifecycleOperation = operation;
    return operation;
  }

  Future<void> _start() async {
    _setState(
      const McpDesktopServerState(
        status: McpDesktopServerStatus.starting,
      ),
    );
    try {
      HttpServer server;
      try {
        server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          _registry.port,
          shared: false,
        );
      } on SocketException {
        server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
          shared: false,
        );
      }
      _httpServer = server;
      server.idleTimeout = const Duration(seconds: 75);
      server.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[MCP] HTTP server error: $error');
          _setState(
            McpDesktopServerState(
              status: McpDesktopServerStatus.error,
              error: 'The local MCP server stopped unexpectedly.',
              endpoint: _endpoint,
            ),
          );
        },
        cancelOnError: false,
      );
      await _writeDiscovery();
      _updateState();
    } catch (error, stackTrace) {
      debugPrint('[MCP] Start failed: $error\n$stackTrace');
      _httpServer = null;
      _setState(
        McpDesktopServerState(
          status: McpDesktopServerStatus.error,
          error: 'Could not start the local MCP server: $error',
        ),
      );
    }
  }

  Future<void> stop() {
    final active = _lifecycleOperation;
    if (active != null) {
      return active.then((_) => stop());
    }
    if (_httpServer == null && _sessions.isEmpty) {
      _setState(
        const McpDesktopServerState(
          status: McpDesktopServerStatus.stopped,
        ),
      );
      return _removeDiscovery();
    }
    late final Future<void> operation;
    operation = _stop().whenComplete(() {
      if (identical(_lifecycleOperation, operation)) {
        _lifecycleOperation = null;
      }
    });
    _lifecycleOperation = operation;
    return operation;
  }

  Future<void> _stop() async {
    _approvalController.cancelAll();
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      await session.close();
    }
    await _httpServer?.close(force: true);
    _httpServer = null;
    _requestTimes.clear();
    await _removeDiscovery();
    _setState(
      const McpDesktopServerState(
        status: McpDesktopServerStatus.stopped,
      ),
    );
  }

  void handleSessionChanged(VaultSessionState session) {
    if (!session.canAccessVault) {
      _approvalController.cancelAll();
    }
    if (session.status == VaultSessionStatus.duress ||
        session.status == VaultSessionStatus.revoked) {
      for (final clientId
          in _sessions.values.map((value) => value.clientId).toSet()) {
        unawaited(_closeClientSessions(clientId));
      }
    }
    _updateState();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!_validHost(request)) {
      await _plainResponse(request, HttpStatus.forbidden, 'Forbidden');
      return;
    }
    if (request.headers.value('origin') != null) {
      await _plainResponse(
        request,
        HttpStatus.forbidden,
        'Browser origins are not allowed.',
      );
      return;
    }
    if (request.uri.path != endpointPath) {
      await _plainResponse(request, HttpStatus.notFound, 'Not Found');
      return;
    }
    if (request.method == 'OPTIONS') {
      await _plainResponse(request, HttpStatus.noContent, '');
      return;
    }

    final bearer = _bearerToken(request);
    if (bearer == null) {
      await _unauthorized(request);
      return;
    }
    final client = await _registry.authenticateBearer(bearer);
    if (client == null) {
      await _unauthorized(request);
      return;
    }
    if (!_allowRequest(client.id)) {
      await _plainResponse(
        request,
        HttpStatus.tooManyRequests,
        'Too Many Requests',
      );
      return;
    }

    try {
      switch (request.method) {
        case 'POST':
          await _handlePost(request, client);
          break;
        case 'GET':
        case 'DELETE':
          await _handleSessionRequest(request, client);
          break;
        default:
          request.response.headers.set(
            HttpHeaders.allowHeader,
            'GET, POST, DELETE, OPTIONS',
          );
          await _plainResponse(
            request,
            HttpStatus.methodNotAllowed,
            'Method Not Allowed',
          );
      }
    } on McpOperationException catch (error) {
      await _jsonRpcError(
        request,
        null,
        -32001,
        error.message,
        data: error.toJson(),
      );
    } catch (error, stackTrace) {
      debugPrint('[MCP] Request failed: $error\n$stackTrace');
      try {
        await _jsonRpcError(
          request,
          null,
          -32603,
          'Internal error',
        );
      } catch (_) {
        // The transport may already have completed the response.
      }
    }
  }

  Future<void> _handlePost(
    HttpRequest request,
    McpClientRegistration client,
  ) async {
    final bytes = await _readBoundedBody(request);
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      await _jsonRpcError(request, null, -32700, 'Parse error');
      return;
    }

    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId != null) {
      final session = _sessions[sessionId];
      if (session == null ||
          session.clientId != client.id ||
          session.authorizationFingerprint !=
              _authorizationFingerprint(client)) {
        await _plainResponse(request, HttpStatus.notFound, 'Session not found');
        return;
      }
      await session.transport.handleRequest(request, body);
      return;
    }

    final protocolVersion =
        request.headers.value('mcp-protocol-version')?.trim();
    if (protocolVersion != null &&
        isStatelessProtocolVersion(protocolVersion)) {
      await _handleStateless(request, body, client.id);
      return;
    }

    if (!_isInitialize(body)) {
      await _jsonRpcError(
        request,
        _requestId(body),
        -32000,
        'A new MCP session must start with initialize.',
      );
      return;
    }

    late final StreamableHTTPServerTransport transport;
    late final McpServer mcpServer;
    transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: generateUUID,
        allowedHosts: const {'localhost', '127.0.0.1'},
        allowedOrigins: const {},
        enableDnsRebindingProtection: true,
        strictProtocolVersionHeaderValidation: true,
        rejectBatchJsonRpcPayloads: true,
        onsessioninitialized: (id) {
          _sessions[id] = _McpSession(
            id: id,
            clientId: client.id,
            authorizationFingerprint: _authorizationFingerprint(client),
            transport: transport,
            server: mcpServer,
          );
          _updateState();
        },
      ),
    );
    mcpServer = _serverFactory.createForClient(client.id);
    await mcpServer.connect(transport);
    mcpServer.server.onclose = () {
      final id = transport.sessionId;
      if (id != null) {
        _sessions.remove(id);
        _updateState();
      }
    };
    await transport.handleRequest(request, body);
  }

  Future<void> _handleStateless(
    HttpRequest request,
    dynamic body,
    String clientId,
  ) async {
    final transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: _nullSessionId,
        allowedHosts: {'localhost', '127.0.0.1'},
        allowedOrigins: {},
        enableDnsRebindingProtection: true,
        strictProtocolVersionHeaderValidation: true,
        rejectBatchJsonRpcPayloads: true,
        enableJsonResponse: true,
      ),
    );
    final server = _serverFactory.createForClient(clientId);
    await server.connect(transport);
    try {
      await transport.handleRequest(request, body);
    } finally {
      await transport.close();
      await server.close();
    }
  }

  Future<void> _handleSessionRequest(
    HttpRequest request,
    McpClientRegistration client,
  ) async {
    final sessionId = request.headers.value('mcp-session-id');
    final session = sessionId == null ? null : _sessions[sessionId];
    if (session == null ||
        session.clientId != client.id ||
        session.authorizationFingerprint != _authorizationFingerprint(client)) {
      await _plainResponse(
        request,
        sessionId == null ? HttpStatus.badRequest : HttpStatus.notFound,
        sessionId == null ? 'Missing session ID' : 'Session not found',
      );
      return;
    }
    await session.transport.handleRequest(request);
    if (request.method == 'DELETE') {
      _sessions.remove(session.id);
      await session.close();
      _updateState();
    }
  }

  bool _validHost(HttpRequest request) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host == null) return false;
    final normalized = host.toLowerCase();
    final port = _httpServer?.port;
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == 'localhost:$port' ||
        normalized == '127.0.0.1:$port';
  }

  String? _bearerToken(HttpRequest request) {
    final value = request.headers.value(HttpHeaders.authorizationHeader);
    if (value == null || !value.startsWith('Bearer ')) return null;
    final token = value.substring(7).trim();
    return token.isEmpty ? null : token;
  }

  bool _allowRequest(String clientId) {
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(const Duration(minutes: 1));
    final times = _requestTimes.putIfAbsent(clientId, () => [])
      ..removeWhere((time) => time.isBefore(cutoff));
    if (times.length >= requestsPerMinute) return false;
    times.add(now);
    return true;
  }

  Future<List<int>> _readBoundedBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maximumRequestBytes) {
        throw const McpOperationException(
          'invalid_input',
          'MCP request body exceeds the 1 MiB limit.',
        );
      }
    }
    return bytes;
  }

  bool _isInitialize(dynamic body) =>
      body is Map<String, dynamic> && body['method'] == Method.initialize;

  Object? _requestId(dynamic body) =>
      body is Map<String, dynamic> ? body['id'] : null;

  Future<void> writeStdioProfile({
    required String clientId,
    required String token,
  }) async {
    if (!isSupported) return;
    final client = _registry.getClient(clientId);
    if (client == null || client.transport != McpClientTransport.stdio) {
      throw const McpOperationException(
        'invalid_input',
        'A valid stdio AI app connection is required.',
      );
    }
    await McpLocalPaths.ensureDirectories();
    final file = McpLocalPaths.profileFile(clientId);
    await file.writeAsString(
      jsonEncode({
        'client_id': clientId,
        'token': token,
      }),
      flush: true,
    );
    await McpLocalPaths.restrictFile(file);
  }

  Future<void> removeStdioProfile(String clientId) async {
    if (!isSupported) return;
    final file = McpLocalPaths.profileFile(clientId);
    if (await file.exists()) await file.delete();
  }

  String stdioConfig(String clientId) {
    final executable = _bridgeExecutable();
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'gitvault': {
          'command': executable.command,
          'args': [...executable.prefixArgs, '--profile', clientId],
        },
      },
    });
  }

  String httpConfig(String token) {
    final endpoint = _endpoint;
    if (endpoint == null) return '';
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'gitvault': {
          'url': endpoint.toString(),
          'headers': {'Authorization': 'Bearer $token'},
        },
      },
    });
  }

  _BridgeCommand _bridgeExecutable() {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final executableName =
        Platform.isWindows ? 'gitvault_mcp.exe' : 'gitvault_mcp';
    final bundled = File(
      '${executableDirectory.path}${Platform.pathSeparator}$executableName',
    );
    if (bundled.existsSync()) {
      return _BridgeCommand(bundled.path, const []);
    }
    return const _BridgeCommand(
      'dart',
      ['run', 'bin/gitvault_mcp.dart'],
    );
  }

  Future<void> _writeDiscovery() async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    await McpLocalPaths.ensureDirectories();
    final file = McpLocalPaths.discoveryFile();
    await file.writeAsString(
      jsonEncode({
        'endpoint': endpoint.toString(),
        'pid': pid,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await McpLocalPaths.restrictFile(file);
  }

  Future<void> _removeDiscovery() async {
    if (!isSupported) return;
    try {
      final file = McpLocalPaths.discoveryFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stale discovery file is validated by the bridge before use.
    }
  }

  Uri? get _endpoint {
    final server = _httpServer;
    if (server == null) return null;
    return Uri.parse('http://127.0.0.1:${server.port}$endpointPath');
  }

  void _handleRegistryChanged() {
    if (_disposed) return;
    unawaited(refresh());
    final changedClientIds = _sessions.values
        .where((session) {
          final client = _registry.getClient(session.clientId);
          return client == null ||
              !client.isActive ||
              session.authorizationFingerprint !=
                  _authorizationFingerprint(client);
        })
        .map((session) => session.clientId)
        .toSet();
    for (final clientId in changedClientIds) {
      _approvalController.cancelForClient(clientId);
      unawaited(_closeClientSessions(clientId));
    }
  }

  String _authorizationFingerprint(McpClientRegistration client) {
    final permissions = client.permissions.map((value) => value.name).toList()
      ..sort();
    return jsonEncode({
      'token': client.tokenVerifier,
      'permissions': permissions,
    });
  }

  Future<void> _closeClientSessions(String clientId) async {
    final sessions = _sessions.values
        .where((session) => session.clientId == clientId)
        .toList();
    for (final session in sessions) {
      _sessions.remove(session.id);
      await session.close();
    }
    _updateState();
  }

  void _updateState() {
    final endpoint = _endpoint;
    if (endpoint == null) {
      _setState(
        const McpDesktopServerState(
          status: McpDesktopServerStatus.stopped,
        ),
      );
      return;
    }
    _setState(
      McpDesktopServerState(
        status: _readSession().canAccessVault
            ? McpDesktopServerStatus.ready
            : McpDesktopServerStatus.locked,
        endpoint: endpoint,
        activeSessions: _sessions.length,
      ),
    );
  }

  void _setState(McpDesktopServerState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> _unauthorized(HttpRequest request) async {
    request.response.headers.set(
      HttpHeaders.wwwAuthenticateHeader,
      'Bearer realm="GitVault MCP"',
    );
    await _plainResponse(request, HttpStatus.unauthorized, 'Unauthorized');
  }

  Future<void> _plainResponse(
    HttpRequest request,
    int status,
    String message,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..write(message);
    await request.response.close();
  }

  Future<void> _jsonRpcError(
    HttpRequest request,
    Object? id,
    int code,
    String message, {
    Map<String, dynamic>? data,
  }) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': code,
            'message': message,
            if (data != null) 'data': data,
          },
        }),
      );
    await request.response.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _registry.removeListener(_handleRegistryChanged);
    unawaited(stop());
    super.dispose();
  }
}

String? _nullSessionId() => null;

class _McpSession {
  final String id;
  final String clientId;
  final String authorizationFingerprint;
  final StreamableHTTPServerTransport transport;
  final McpServer server;

  const _McpSession({
    required this.id,
    required this.clientId,
    required this.authorizationFingerprint,
    required this.transport,
    required this.server,
  });

  Future<void> close() async {
    try {
      await transport.close();
    } finally {
      await server.close();
    }
  }
}

class _BridgeCommand {
  final String command;
  final List<String> prefixArgs;

  const _BridgeCommand(this.command, this.prefixArgs);
}
