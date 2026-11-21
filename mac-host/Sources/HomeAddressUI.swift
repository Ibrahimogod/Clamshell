import AppKit
import ClamshellHome
import SwiftUI

/// Home address… (menu): a DuckDNS name, so phones keep finding the Mac after the home's address changes,
/// and the router's port forwards over UPnP (ADR-0005). The public address itself comes from the router over
/// UPnP. The token goes to the Keychain; nothing here is sent anywhere but the router and the DNS service.
struct HomeAddressView: View {
    let monitor: PublicAddressMonitor
    let forwarder: PortForwarder
    @State private var name = ""
    @State private var token = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A free name from duckdns.org that always points at the home's address. Sign in there, add a domain (e.g. myhome), then paste the name and the account's token here. DuckDNS only learns the address. (A domain of your own hosted at deSEC works too.)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("name, e.g. myhome.duckdns.org", text: $name).textFieldStyle(.roundedBorder)
                    SecureField(monitor.hasDNSToken ? "token saved (type to replace)" : "DuckDNS token", text: $token)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") {
                            monitor.saveDNS(name: name, token: token.isEmpty ? nil : token)
                            token = ""
                        }
                        .disabled(!(name.isEmpty || DynamicDNS.isHostname(DynamicDNS.normalize(name))) || (DynamicDNS.normalize(name) == monitor.dnsName && token.isEmpty))
                        if monitor.hasDNSToken || !monitor.dnsName.isEmpty {
                            Button("Remove") { monitor.saveDNS(name: "", token: ""); name = "" }
                        }
                    }
                    if !name.isEmpty, !DynamicDNS.isHostname(DynamicDNS.normalize(name)) {
                        Text("That isn't a DNS name.").font(.caption).foregroundStyle(.red)
                    }
                    if !monitor.dnsStatus.isEmpty {
                        Text(monitor.dnsStatus).font(.caption).textSelection(.enabled)
                    }
                }.padding(4)
            } label: { Text("Name for the phone (DuckDNS)").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The router has to pass Clamshell's ports (UDP and TCP) to this Mac. With UPnP on in the router, the Mac asks for that itself, renews it every 30 minutes, and follows its own address when that changes. Delete forwards for the same ports made by hand in the router (Virtual Servers): they take priority and stay on the old address.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Open the ports on the router automatically (UPnP)", isOn: Bindable(forwarder).enabled)
                    if !forwarder.status.isEmpty {
                        Text(forwarder.status).font(.caption)
                            .foregroundStyle(forwarder.problem.isEmpty ? Color.primary : Color.orange).textSelection(.enabled)
                    }
                }.padding(4)
            } label: { Text("Port forwarding").font(.headline) }

            VStack(alignment: .leading, spacing: 4) {
                if !monitor.routerStatus.isEmpty {
                    Text(monitor.routerStatus).font(.caption)
                        .foregroundStyle(monitor.problem.isEmpty ? Color.primary : Color.orange).textSelection(.enabled)
                }
                Text("Phones are given: \(monitor.effective ?? "nothing yet")").font(.callout).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = monitor.dnsName
        }
    }
}

@MainActor
final class HomeAddressWindowController {
    private var window: NSWindow?

    func show(_ view: some View) {
        let w = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Home address"
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
