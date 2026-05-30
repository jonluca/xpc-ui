import Foundation

@objc protocol CaptureHelperProtocol {
    func snapshot(pid: Int32, withReply reply: @escaping (Data?, String?) -> Void)
    func kernelTracingStatus(withReply reply: @escaping (String) -> Void)
    func startKernelTrace(
        script: String,
        receiverEndpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (String?) -> Void
    )
    func stopKernelTrace(withReply reply: @escaping () -> Void)
}

@objc protocol CaptureHelperKernelTraceReceiver {
    func receiveKernelTraceLine(_ line: String)
    func kernelTraceDidTerminate(status: Int32)
}
