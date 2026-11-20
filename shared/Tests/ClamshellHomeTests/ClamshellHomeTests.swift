import Foundation
import Testing
@testable import ClamshellHome

// Vectors: AES from `openssl enc -aes-128-cbc -K <hex "1234567890123456"> -iv <hex "6543210987654321"> -base64`,
// MD5 from Python's hashlib, RSA from Python's `pow(m, 65537, n)` over 64-byte zero-padded chunks.
private let modulus = "c3d2a1f0e9b8a7968574635241302f1e0d1c2b3a49586776859a0b1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f7"
private let key = "1234567890123456", iv = "6543210987654321"

private func encryptor() throws -> TPLinkEncryptor {
    let rsa = try #require(RawRSA(modulusHex: modulus, exponentHex: "010001"))
    return TPLinkEncryptor(key: key, iv: iv, password: "hunter2", rsa: rsa)
}

@Test func md5OfUserAndPassword() throws {
    #expect(try encryptor().hash == "b7e0c81efd24af5fd698e10fe115c291")
}

@Test func aesMatchesOpenSSL() throws {
    let e = try encryptor()
    let sealed = try #require(e.seal("admin\nhunter2", seq: 0, login: true))
    #expect(sealed.data == "MamTgckOyOW78EnNIYlFEw==")
    #expect(e.open(sealed.data) == "admin\nhunter2")
    #expect(e.open("not base64!") == nil)
}

@Test func rsaOneChunk() throws {
    let sign = try encryptor().sign("key=1234567890123456&iv=6543210987654321&h=abcdef&s=12345")
    #expect(sign == "4bd4639e5b080c8b4e04e2dc39e22e548d38ef43df9ea77c1e9d1833e0b1bdfc1b01b29a6ca58565abdcd3be74ca82257df1fb0d88674eca639731c7ae77bdea")
}

/// The login signature: two chunks, `s` = seq + length of the base64 data, and a leading zero kept.
@Test func loginSignature() throws {
    let sealed = try #require(encryptor().seal("admin\nhunter2", seq: 987_654_364, login: true))
    #expect(sealed.sign == "02b3509364f9de9b8fd461626da130d4a0e4f1e2f80c68f2a35b70a051c9c339f9f9e827c9b57d8bdd92d9313e73a138a673349856770adecfc2095edc90c7ba67d3fba34f5005e1a1a95a1e0933b48f10ea51ce94bcde7978348bcec56d0f67017d707c9d0504a8977d3d2cc7d26a315f5ef1c94ee1dca16def43a6017ca0d8")
}

@Test func randomKeysAreDigits() {
    let k = TPLinkEncryptor.randomDigits(16)
    #expect(k.count == 16 && k.allSatisfy(\.isNumber))
    #expect(k != TPLinkEncryptor.randomDigits(16))
}

@Test func rsaRejectsBadKeys() {
    #expect(RawRSA(modulusHex: "zz", exponentHex: "010001") == nil)
    #expect(RawRSA(modulusHex: "0f", exponentHex: "010001") == nil)
    #expect(RawRSA(modulusHex: modulus, exponentHex: "00") == nil)
}

@Test func parsesRouterScripts() throws {
    let parm = try #require(TPLinkMessages.parameters("var ee=\"010001\";\nvar nn=\"\(modulus)\";\nvar seq=\"470953416\";\n$.ret=0;\n"))
    #expect(parm.seq == 470_953_416)
    #expect(parm.rsa.blockSize == 64)
    #expect(TPLinkMessages.parameters("var ee=\"010001\";") == nil)
    #expect(TPLinkMessages.someoneSignedIn("var isLogined=0;\nvar isBusy=0;\n") == false)
    #expect(TPLinkMessages.someoneSignedIn("var isLogined=1;var isBusy=0;") == true)
    #expect(TPLinkMessages.loginResult("$.ret=0;") == 0)
    #expect(TPLinkMessages.loginResult("var currAuthTimes=1;\nvar currForbidTime=0;\n$.ret=71233;\n") == 71233)
    #expect(TPLinkMessages.token(inPage: "<script type=\"text/javascript\">var token=\"8b1d9a6c0e\";</script>") == "8b1d9a6c0e")
    #expect(TPLinkMessages.token(inPage: "var token = 'abc';") == "abc")
    #expect(TPLinkMessages.token(inPage: "<html></html>") == nil)
}

@Test func buildsTheWANRequest() {
    #expect(TPLinkMessages.wanRequest ==
        "5&5\r\n[WAN_PPP_CONN#0,0,0,0,0,0#0,0,0,0,0,0]0,4\r\nenable\r\nname\r\nconnectionStatus\r\nexternalIPAddress\r\n"
        + "[WAN_IP_CONN#0,0,0,0,0,0#0,0,0,0,0,0]1,4\r\nenable\r\nname\r\nconnectionStatus\r\nexternalIPAddress\r\n")
    #expect(TPLinkMessages.logoutRequest == "8\r\n[/cgi/logout#0,0,0,0,0,0#0,0,0,0,0,0]0,0\r\n")
}

@Test func picksTheConnectedPPPAddress() throws {
    let answer = """
    [1,1,0,0,0,0]0\r
    enable=1\r
    name=pppoe_ptm_0_1_d\r
    connectionStatus=Connected\r
    externalIPAddress=41.234.10.7\r
    [2,1,0,0,0,0]0\r
    enable=1\r
    name=pppoe_atm\r
    connectionStatus=Disconnected\r
    externalIPAddress=0.0.0.0\r
    [3,1,1,0,0,0]1\r
    enable=1\r
    name=ipoe_iptv\r
    connectionStatus=Connected\r
    externalIPAddress=10.20.30.40\r
    [error]0\r

    """
    let parsed = try #require(TPLinkMessages.response(answer))
    #expect(parsed.error == 0 && parsed.instances.count == 3)
    let reading = try TPLinkRouter.pick(parsed.instances)
    #expect(reading.address.description == "41.234.10.7")
    #expect(reading.connection == "pppoe_ptm_0_1_d")

    let down = try #require(TPLinkMessages.response("[1,1,0,0,0,0]0\nconnectionStatus=Connecting\nexternalIPAddress=0.0.0.0\n[error]0\n"))
    #expect(throws: RouterError.notConnected) { try TPLinkRouter.pick(down.instances) }
    #expect(TPLinkMessages.response("<html>login</html>") == nil)
    #expect(TPLinkMessages.response("[error]71017")?.error == 71017)
}

@Test func ipv4Ranges() throws {
    #expect(try #require(IPv4("41.234.10.7")).isPublic)
    #expect(try #require(IPv4("100.70.1.2")).isCarrierNAT)
    #expect(try #require(IPv4("100.128.0.1")).isPublic)
    for p in ["10.0.0.1", "192.168.1.1", "172.20.0.1", "169.254.1.1", "127.0.0.1", "0.0.0.0", "100.64.0.1"] {
        #expect(try #require(IPv4(p)).isPublic == false, "\(p)")
    }
    for bad in ["1.2.3", "1.2.3.4.5", "256.1.1.1", "a.b.c.d", "1..2.3", "", " 1.2.3.4 x"] {
        #expect(IPv4(bad) == nil, "\(bad)")
    }
}

@Test func uriComponentMatchesJavaScript() {
    #expect(TPLinkRouter.uriComponent("ab+/c=") == "ab%2B%2Fc%3D")
    #expect(TPLinkRouter.uriComponent("a-_.!~*'()") == "a-_.!~*'()")
}

@Test func duckDNSRequest() throws {
    let ip = try #require(IPv4("41.234.10.7"))
    let req = try #require(DynamicDNS.request(hostname: " MyHome.DuckDNS.org ", address: ip, token: "t0ken"))
    #expect(req.url?.absoluteString == "https://www.duckdns.org/update?domains=myhome&token=t0ken&ip=41.234.10.7&verbose=true")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(DynamicDNS.normalize("myhome") == "myhome.duckdns.org")
    #expect(DynamicDNS.provider(for: "myhome") == .duckDNS)
    #expect(DynamicDNS.request(hostname: "a.b.duckdns.org", address: ip, token: "t") == nil)
    #expect(DynamicDNS.request(hostname: "myhome", address: ip, token: " ") == nil)
}

@Test func deSECRequest() throws {
    let ip = try #require(IPv4("41.234.10.7"))
    let req = try #require(DynamicDNS.request(hostname: "home.example.org", address: ip, token: "t0ken"))
    #expect(DynamicDNS.provider(for: "home.example.org") == .deSEC)
    #expect(req.url?.absoluteString == "https://update.dedyn.io/?hostname=home.example.org&myipv4=41.234.10.7&myipv6=")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Token t0ken")
    #expect(DynamicDNS.isHostname("a-b.dedyn.io"))
    #expect(!DynamicDNS.isHostname("-a.dedyn.io"))
    #expect(!DynamicDNS.isHostname("41.234.10.7"))
}

@Test func dnsOutcomes() {
    #expect(DynamicDNS.outcome(.duckDNS, status: 200, body: "OK\n41.234.10.7\n\nUPDATED", retryAfter: nil) == .updated)
    #expect(DynamicDNS.outcome(.duckDNS, status: 200, body: "KO", retryAfter: nil) == .badAuth)
    #expect(DynamicDNS.outcome(.deSEC, status: 200, body: "good\n", retryAfter: nil) == .updated)
    #expect(DynamicDNS.outcome(.deSEC, status: 401, body: "badauth", retryAfter: nil) == .badAuth)
    #expect(DynamicDNS.outcome(.deSEC, status: 429, body: "", retryAfter: "120") == .throttled(retryAfter: 120))
    #expect(DynamicDNS.outcome(.duckDNS, status: 500, body: "oops", retryAfter: nil) == .failed("HTTP 500 oops"))
}

// UPnP fixtures: trimmed from the Archer VR400's real answers.
@Test func ssdpLocation() {
    let answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=300\r\nEXT:\r\nLOCATION: http://192.168.1.1:1900/gatedesc.xml\r\n"
        + "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
    #expect(UPnPMessages.location(answer)?.absoluteString == "http://192.168.1.1:1900/gatedesc.xml")
    #expect(UPnPMessages.location("HTTP/1.1 200 OK\r\nlocation:http://10.0.0.1:5000/rootDesc.xml\r\n")?.port == 5000)
    #expect(UPnPMessages.location("HTTP/1.1 200 OK\r\nST: x\r\n") == nil)
    #expect(UPnPMessages.search("urn:x").hasSuffix("ST: urn:x\r\n\r\n"))
}

@Test func upnpDescription() throws {
    let xml = """
    <root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/upnp/control/dummy</controlURL></service>
    </serviceList><deviceList><device><deviceList><device><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/upnp/control/WANPPPConn1</controlURL></service>
    <service>
      <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
      <controlURL>/upnp/control/WANIPConn1</controlURL>
    </service>
    </serviceList></device></deviceList></device></deviceList></device></root>
    """
    let s = try #require(UPnPMessages.connectionService(xml, location: URL(string: "http://192.168.1.1:1900/gatedesc.xml")!))
    #expect(s.type == "urn:schemas-upnp-org:service:WANIPConnection:1")
    #expect(s.control.absoluteString == "http://192.168.1.1:1900/upnp/control/WANIPConn1")
    let based = "<root><URLBase>http://10.0.0.1:49000/</URLBase><service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>ctl/ppp</controlURL></service></root>"
    #expect(UPnPMessages.connectionService(based, location: URL(string: "http://10.0.0.1:1900/d.xml")!)?.control.absoluteString
        == "http://10.0.0.1:49000/ctl/ppp")
    #expect(UPnPMessages.connectionService("<root></root>", location: URL(string: "http://h/")!) == nil)
}

@Test func upnpSOAP() {
    let env = UPnPMessages.envelope("DeletePortMapping", service: "urn:schemas-upnp-org:service:WANIPConnection:1",
                                    ["NewRemoteHost": "", "NewExternalPort": "443", "NewProtocol": "TCP"])
    #expect(env.contains("<u:DeletePortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\"><NewRemoteHost></NewRemoteHost><NewExternalPort>443</NewExternalPort><NewProtocol>TCP</NewProtocol></u:DeletePortMapping>"))
    #expect(UPnPMessages.envelope("A", service: "s", ["NewPortMappingDescription": "Mac & <phone>"]).contains("Mac &amp; &lt;phone&gt;"))

    let ok = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
    <u:GetSpecificPortMappingEntryResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewInternalPort>51999</NewInternalPort><NewInternalClient>192.168.1.116</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>Clamshell &amp; co</NewPortMappingDescription><NewLeaseDuration>120</NewLeaseDuration></u:GetSpecificPortMappingEntryResponse>
    </s:Body> </s:Envelope>
    """
    #expect(UPnPMessages.answer(ok) == .ok(["NewInternalPort": "51999", "NewInternalClient": "192.168.1.116", "NewEnabled": "1",
                                            "NewPortMappingDescription": "Clamshell & co", "NewLeaseDuration": "120"]))
    #expect(UPnPMessages.answer("<u:AddPortMappingResponse xmlns:u=\"x\"></u:AddPortMappingResponse>") == .ok([:]))
    let fault = """
    <s:Envelope><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>
    <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>714</errorCode><errorDescription>NoSuchEntryInArray</errorDescription></UPnPError>
    </detail></s:Fault></s:Body></s:Envelope>
    """
    #expect(UPnPMessages.answer(fault) == .fault(code: 714, text: "NoSuchEntryInArray"))
    #expect(UPnPMessages.answer("<html>404</html>") == nil)
}

@Test func localAddressTowardGateway() {
    // Any IPv4 the kernel can route to gives a local address; a bad host gives nil.
    #expect(UPnPGateway.localAddress(toward: "not an address") == nil)
    if let a = UPnPGateway.localAddress(toward: "127.0.0.1") { #expect(a == "127.0.0.1") }
}
