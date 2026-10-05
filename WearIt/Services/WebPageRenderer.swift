//
//  WebPageRenderer.swift
//  WearIt
//
//  Last-resort page reader: loads a product link in an off-screen WKWebView
//  (a real Safari engine that runs the shop's JavaScript and passes simple
//  bot checks), waits until product metadata appears, and returns the HTML.
//  No cookies are kept between loads.
//

import Foundation
import WebKit

@MainActor
final class WebPageRenderer: NSObject, WKNavigationDelegate {
    private static let timeout: Duration = .seconds(15)
    private static let readyCheck = """
    document.querySelector('script[type="application/ld+json"], meta[property="og:title"], meta[property="og:image"]') !== null
    """

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var isPolling = false

    static func html(for url: URL) async -> String? {
        await WebPageRenderer().load(url)
    }

    private func load(_ url: URL) async -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.customUserAgent = ShopFetch.safariUserAgent
        webView.navigationDelegate = self
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 15))
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                await self?.finish()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isPolling else { return }
        isPolling = true
        // Pages often fill product data after load (or after a bot check reloads them).
        Task { [weak self] in
            for _ in 0..<16 {
                guard let self, self.continuation != nil else { return }
                if (try? await webView.evaluateJavaScript(Self.readyCheck)) as? Bool == true {
                    await self.finish()
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
            await self?.finish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { await finish(failed: true) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { await finish(failed: true) }
    }

    private func finish(failed: Bool = false) async {
        guard let continuation else { return }
        self.continuation = nil
        var html: String?
        if !failed {
            html = (try? await webView?.evaluateJavaScript("document.documentElement.outerHTML")) as? String
        }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(returning: html)
    }
}
