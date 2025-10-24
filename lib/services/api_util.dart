Uri baseUriFrom(String apiEndpoint) {
  final uri = Uri.parse(apiEndpoint);
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
}

/// يحوّل أي مسار يبدأ بـ media/customer_<id>/filename
/// إلى: {baseOrigin}/storage/media/customer_<id>/filename
String resolveCustomerMediaUrl({
  required String baseOrigin, // مثال: http://192.168.1.134:8000
  required String url,        // مثال: media/customer_4/xxx.png أو مطلق
}) {
  // لو أصلاً مطلق، ارجعه كما هو
  if (url.startsWith('http://') || url.startsWith('https://')) return url;

  // التوافق مع النمط المطلوب
  final reg = RegExp(r'^/?media/customer_(\d+)\/(.+)$');
  final m = reg.firstMatch(url);
  if (m != null) {
    final customerId = m.group(1)!;
    final tail = m.group(2)!;
    return '$baseOrigin/storage/media/customer_$customerId/$tail';
  }

  // fallback عام
  if (url.startsWith('/')) {
    return '$baseOrigin$url';
  } else {
    return '$baseOrigin/$url';
  }
}
