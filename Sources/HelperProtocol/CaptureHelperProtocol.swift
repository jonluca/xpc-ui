import Foundation

@objc protocol CaptureHelperProtocol {
    func snapshot(pid: Int32, withReply reply: @escaping (Data?, String?) -> Void)
    func kernelTracingStatus(withReply reply: @escaping (String) -> Void)
}
