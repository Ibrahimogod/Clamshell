import Foundation
import Testing
@testable import ClamshellHome

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
