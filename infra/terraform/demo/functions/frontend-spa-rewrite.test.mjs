import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('./frontend-spa-rewrite.js', import.meta.url), 'utf8');
const handler = runInNewContext(`${source}\nhandler;`);

const cases = [
    ['/', '/index.html'],
    ['/login', '/index.html'],
    ['/products/4', '/index.html'],
    ['/products/4/', '/index.html'],
    ['/orders/3', '/index.html'],
    ['/categories/new', '/index.html'],
    ['/admin', '/index.html'],
    ['/admin/products/4/', '/index.html'],
    ['/future-route/anything', '/index.html'],
    ['/assets/app.js', '/assets/app.js'],
    ['/assets/chunk-without-extension', '/assets/chunk-without-extension'],
    ['/assets/', '/assets/'],
    ['/assets', '/assets'],
    ['/favicon.ico', '/favicon.ico'],
    ['/index.html', '/index.html'],
    ['/downloads/manual.pdf', '/downloads/manual.pdf'],
    ['/manifest.webmanifest', '/manifest.webmanifest'],
    ['/images/photo.PNG', '/images/photo.PNG'],
    ['/api/test', '/api/test'],
    ['/api', '/api'],
    ['/api/', '/api/'],
    ['/api/public/products', '/api/public/products'],
    ['/apiary', '/index.html'],
    ['/assets-gallery', '/index.html'],
];

for (const method of ['GET', 'HEAD']) {
    for (const [uri, expected] of cases) {
        test(`${method} ${uri} -> ${expected}`, () => {
            const request = { method, uri, querystring: {}, headers: {} };
            const result = handler({ request });
            assert.equal(result, request);
            assert.equal(result.uri, expected);
            assert.equal(result.method, method);
        });
    }
}

for (const method of ['OPTIONS', 'POST', 'PUT', 'PATCH', 'DELETE']) {
    test(`${method} navigation is never rewritten`, () => {
        const request = { method, uri: '/products/4', querystring: {}, headers: {} };
        const before = structuredClone(request);
        assert.deepEqual(handler({ request }), before);
    });
}

for (const uri of ['/products/4/', '/api/test', '/assets/app.js']) {
    test(`${uri} preserves query strings, duplicate values, cookies, and headers`, () => {
        const request = {
            method: 'GET',
            uri,
            querystring: {
                page: { value: '2' },
                returnTo: { value: '%2Forders%2F3%3Fview%3Dfull' },
                tag: { value: 'one', multiValue: [{ value: 'one' }, { value: 'two' }] },
                empty: { value: '' },
            },
            headers: { accept: { value: 'text/html' } },
            cookies: { preference: { value: 'compact' } },
        };
        const before = structuredClone(request);
        const result = handler({ request });
        assert.equal(result.querystring, request.querystring);
        assert.deepEqual(result.querystring, before.querystring);
        assert.deepEqual(result.headers, before.headers);
        assert.deepEqual(result.cookies, before.cookies);
        assert.equal(result.uri, uri === '/products/4/' ? '/index.html' : uri);
    });
}
