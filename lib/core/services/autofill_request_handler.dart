/// Simple singleton to hold pending autofill requests
class AutofillRequestHandler {
  static final AutofillRequestHandler instance = AutofillRequestHandler._();
  AutofillRequestHandler._();

  String? pendingPackageName;
  String? pendingDomain;
  bool hasPendingRequest = false;

  void setPendingRequest({String? packageName, String? domain}) {
    pendingPackageName = packageName;
    pendingDomain = domain;
    hasPendingRequest = true;
  }

  Map<String, String?>? consumePendingRequest() {
    if (!hasPendingRequest) return null;

    final data = {
      'packageName': pendingPackageName,
      'domain': pendingDomain,
    };

    // Clear pending request
    pendingPackageName = null;
    pendingDomain = null;
    hasPendingRequest = false;

    return data;
  }
}
