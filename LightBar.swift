import Foundation
import CommonCrypto
import Darwin

enum LampError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct LampConfig: Codable {
    var host: String
    let did: String
    let token: String
    let model: String
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LightBarDirect")
    static let url = directory.appendingPathComponent("device.json")
    static func load() throws -> LampConfig {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard config.model == "xiaomi.light.bar2", UInt64(config.did) != nil,
              let token = Data(hex: config.token), token.count == 16 else {
            throw LampError.message("Configuración de la lámpara inválida.")
        }
        return config
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        self.init(bytes)
    }
    func integer(_ range: Range<Int>) -> UInt64 {
        self[range].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func appendInteger(_ value: UInt64, bytes: Int) {
        for shift in (0..<bytes).reversed() { append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
}

enum Crypto {
    static func md5(_ data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &result) }
        return Data(result)
    }
    static func aes(_ data: Data, key: Data, iv: Data, decrypt: Bool) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw LampError.message("No se pudo validar el mensaje cifrado de la lámpara.") }
        output.count = moved
        return output
    }
}

struct LampState: Codable, Equatable {
    let on: Bool
    let brightness: Int
    let temperature: Int
}

// All calls are serialized by the caller. Only UDP to the local lamp is used.
final class LampClient {
    let config: LampConfig
    private(set) var host: String
    private let token: Data
    private let key: Data
    private let iv: Data
    private let did: UInt64
    private var socketFD: Int32 = -1
    private var deviceTime: UInt64 = 0
    private var handshakeAt: TimeInterval = 0
    private var sequence = Int.random(in: 10000...500000)

    init(config: LampConfig) throws {
        guard let token = Data(hex: config.token), token.count == 16, let did = UInt64(config.did) else {
            throw LampError.message("Credencial local inválida.")
        }
        self.config = config; self.host = config.host; self.token = token; self.did = did
        self.key = Crypto.md5(token); self.iv = Crypto.md5(self.key + token)
    }
    deinit { if socketFD >= 0 { Darwin.close(socketFD) } }

    private func address(_ ip: String) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(54321).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { throw LampError.message("Dirección local inválida.") }
        return addr
    }
    private func openSocket() throws {
        if socketFD >= 0 { Darwin.close(socketFD) }
        socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw LampError.message("No se pudo abrir la conexión local.") }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    private func send(_ data: Data, to ip: String) throws {
        var addr = try address(ip)
        let n = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard n == data.count else { throw LampError.message("No se pudo enviar la orden por Wi-Fi.") }
    }
    private func receive() throws -> (Data, String) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var addr = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(socketFD, &buffer, buffer.count, 0, $0, &size)
            }
        }
        guard n >= 0 else { throw LampError.message("La lámpara no responde. Comprueba que esté encendida y en la misma red Wi-Fi.") }
        guard addr.sin_port == UInt16(54321).bigEndian else { throw LampError.message("Respuesta desde un puerto inesperado.") }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        return (Data(buffer.prefix(n)), String(cString: ip))
    }
    private func handshake() throws {
        try openSocket()
        let hello = Data([0x21,0x31,0,0x20] + [UInt8](repeating: 0xff, count: 28))
        // UDP can drop the hello, and macOS may refuse the first send after launch or the
        // limited broadcast; a failed send must not abort the remaining attempts.
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            for destination in [host, "255.255.255.255"] {
                guard (try? send(hello, to: destination)) != nil else { continue }
                let until = Date().timeIntervalSince1970 + 3
                while Date().timeIntervalSince1970 < until {
                    guard let (packet, ip) = try? receive() else { break }
                    guard packet.count == 32, packet.integer(0..<2) == 0x2131,
                          packet.integer(2..<4) == 32, packet.integer(4..<12) == did else { continue }
                    host = ip; deviceTime = packet.integer(12..<16)
                    handshakeAt = ProcessInfo.processInfo.systemUptime
                    return
                }
            }
        }
        throw LampError.message("No encuentro tu barra en la red local. Revisa su alimentación y el Wi-Fi de la Mac.")
    }
    func call(_ method: String, params: [[String: Any]]) throws -> [String: Any] {
        // A fresh hello also recovers from sleep, reboots and DHCP address changes.
        try handshake()
        sequence += 1
        let id = sequence
        let clear = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let encrypted = try Crypto.aes(clear, key: key, iv: iv, decrypt: false)
        var header = Data()
        header.appendInteger(0x2131, bytes: 2)
        header.appendInteger(UInt64(encrypted.count + 32), bytes: 2)
        header.appendInteger(did, bytes: 8)
        header.appendInteger(deviceTime + UInt64(ProcessInfo.processInfo.systemUptime - handshakeAt), bytes: 4)
        let digest = Crypto.md5(header + token + encrypted)
        try send(header + digest + encrypted, to: host)
        let until = Date().timeIntervalSince1970 + 4
        while Date().timeIntervalSince1970 < until {
            let (packet, ip) = try receive()
            guard ip == host, packet.count > 32, packet.integer(0..<2) == 0x2131,
                  packet.integer(2..<4) == UInt64(packet.count), packet.integer(4..<12) == did else { continue }
            let body = Data(packet.dropFirst(32))
            let expected = Crypto.md5(Data(packet.prefix(16)) + token + body)
            guard expected == Data(packet[16..<32]) else { throw LampError.message("La lámpara rechazó la credencial local. Vuelve a importarla después de un restablecimiento.") }
            var decrypted = try Crypto.aes(body, key: key, iv: iv, decrypt: true)
            while decrypted.last == 0 { decrypted.removeLast() }
            guard let reply = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any], reply["id"] as? Int == id else { continue }
            if let error = reply["error"] as? [String: Any] {
                throw LampError.message("La lámpara devolvió el error \(error["code"] ?? "desconocido").")
            }
            return reply
        }
        throw LampError.message("No llegó una respuesta válida de la lámpara.")
    }
    private func parameters(_ values: [(Int, Any?)]) -> [[String: Any]] {
        values.map { piid, value in
            var p: [String: Any] = ["did": config.did, "siid": 2, "piid": piid]
            if let value = value { p["value"] = value }
            return p
        }
    }
    func state() throws -> LampState {
        let reply = try call("get_properties", params: parameters([(1,nil),(2,nil),(3,nil)]))
        guard let rows = reply["result"] as? [[String: Any]], rows.count == 3,
              rows.allSatisfy({ $0["code"] as? Int == 0 }) else { throw LampError.message("La lámpara no permitió leer su estado.") }
        func value(_ id: Int) -> Any? { rows.first { $0["piid"] as? Int == id }?["value"] }
        guard let on = value(1) as? Bool, let brightness = value(2) as? Int, let temperature = value(3) as? Int else {
            throw LampError.message("Estado de la lámpara incompleto.")
        }
        return LampState(on: on, brightness: brightness, temperature: temperature)
    }
    func set(on: Bool? = nil, brightness: Int? = nil, temperature: Int? = nil) throws -> LampState {
        if let n = brightness, !(1...100).contains(n) { throw LampError.message("El brillo debe estar entre 1 y 100%.") }
        if let n = temperature, !(2700...6500).contains(n) { throw LampError.message("La temperatura debe estar entre 2700 y 6500 K.") }
        var values: [(Int, Any?)] = []
        if let v = on { values.append((1,v)) }
        if let v = brightness { values.append((2,v)) }
        if let v = temperature { values.append((3,v)) }
        guard !values.isEmpty else { return try state() }
        let reply = try call("set_properties", params: parameters(values))
        guard let rows = reply["result"] as? [[String: Any]], rows.count == values.count,
              rows.allSatisfy({ $0["code"] as? Int == 0 }) else { throw LampError.message("La lámpara no aceptó el ajuste.") }
        // Read-back verifies the device state, not just an optimistic UI update.
        for attempt in 0..<8 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            let actual = try state()
            if (on == nil || on == actual.on) && (brightness == nil || brightness == actual.brightness)
                && (temperature == nil || temperature == actual.temperature) { return actual }
        }
        throw LampError.message("La lámpara aceptó la orden, pero aún no confirmó el valor. Pulsa Actualizar.")
    }
}
