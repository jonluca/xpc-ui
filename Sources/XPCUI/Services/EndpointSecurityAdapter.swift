import Foundation

enum EndpointSecurityAdapter {
    static let requiredEntitlement = "com.apple.developer.endpoint-security.client"

    static let plannedSubscriptions = [
        "ES_EVENT_TYPE_NOTIFY_EXEC",
        "ES_EVENT_TYPE_NOTIFY_EXIT",
        "ES_EVENT_TYPE_NOTIFY_OPEN",
        "ES_EVENT_TYPE_NOTIFY_CLOSE",
        "ES_EVENT_TYPE_NOTIFY_UIPC_CONNECT",
        "ES_EVENT_TYPE_NOTIFY_XPC_CONNECT",
    ]

    static let activationNote =
        "Endpoint Security activation remains gated until the restricted Apple entitlement is provisioned."
}
