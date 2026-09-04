function handler(event) {
    var request = event.request;
    var uri = request.uri;

    if (request.method !== 'GET' && request.method !== 'HEAD') {
        return request;
    }

    // These namespaces are not frontend navigation, even without an extension.
    if (uri === '/api' || uri.indexOf('/api/') === 0 ||
        uri === '/assets' || uri.indexOf('/assets/') === 0) {
        return request;
    }

    // Preserve file requests instead of turning missing assets into HTML 200s.
    if (uri.indexOf('.') !== -1) {
        return request;
    }

    request.uri = '/index.html';
    // CloudFront querystring is separate from uri; leave it and all headers intact.
    return request;
}
