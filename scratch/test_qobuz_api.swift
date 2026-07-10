import Foundation

func run() async {
    let cookie = UserDefaults.standard.string(forKey: "squid.captcha_cookie") ?? "1779989090966"
    print("[*] Stored Cookie: \(cookie)")
    
    let trackId = "31964075" // Drake - Hotline Bling
    let quality = "5" // MP3 320
    let urlString = "https://qobuz.squid.wtf/api/download-music?track_id=\(trackId)&quality=\(quality)"
    
    guard let url = URL(string: urlString) else {
        print("[-] Invalid URL")
        return
    }
    
    var req = URLRequest(url: url)
    req.addValue("download_captcha_verified_at=\(cookie); captcha_verified_at=\(cookie)", forHTTPHeaderField: "Cookie")
    req.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
    
    print("[*] Sending request to: \(url.absoluteString)")
    print("[*] Headers: \(req.allHTTPHeaderFields ?? [:])")
    
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        let httpRes = response as! HTTPURLResponse
        print("[+] HTTP Status: \(httpRes.statusCode)")
        
        let body = String(data: data, encoding: .utf8) ?? "binary data"
        print("[+] Response Body: \(body)")
    } catch {
        print("[-] Request failed: \(error)")
    }
}

let sem = DispatchSemaphore(value: 0)
Task {
    await run()
    sem.signal()
}
sem.wait()
