import Darwin
import SwiftUI
import XPC

@main
struct XPCFixtureApp: App {
    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1_500)) {
            FixtureTraffic.send()
        }
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 44))
                Text("XPC Fixture")
                    .font(.title)
                Text("Use XPC UI to launch this app and exercise deterministic traffic.")
                    .foregroundStyle(.secondary)
                Button("Send fixture traffic") {
                    FixtureTraffic.send()
                }
            }
            .padding(32)
            .frame(minWidth: 420, minHeight: 240)
        }
    }
}

private enum FixtureTraffic {
    static func send() {
        let connection = xpc_connection_create("com.jonluca.xpcui.fixture.service", nil)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        usleep(20_000)

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "kind", "async")
        xpc_dictionary_set_string(message, "message", "hello from XPC Fixture")
        let nested = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(nested, "answer", 42)
        xpc_dictionary_set_bool(nested, "enabled", true)
        xpc_dictionary_set_value(message, "nested", nested)
        let bytes: [UInt8] = Array(0 ..< 32)
        bytes.withUnsafeBytes { buffer in
            xpc_dictionary_set_data(message, "blob", buffer.baseAddress, buffer.count)
        }
        xpc_connection_send_message_with_reply(connection, message, nil) { _ in }
        usleep(20_000)

        let syncMessage = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(syncMessage, "kind", "sync")
        xpc_dictionary_set_string(syncMessage, "message", "synchronous round trip")
        _ = xpc_connection_send_message_with_reply_sync(connection, syncMessage)
        usleep(20_000)

        let errorMessage = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(errorMessage, "kind", "error")
        xpc_connection_send_message(connection, errorMessage)

        xpcui_fixture_send_session_traffic()
    }
}
