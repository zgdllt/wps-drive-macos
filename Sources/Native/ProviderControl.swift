import Foundation

enum ProviderControlService {
    static let name = "io.github.zgdllt.WPSDrive.control"
}

@objc(WPSDriveProviderControl)
protocol ProviderControl {
    func configure(_ data: Data, reply: @escaping (NSError?) -> Void)
    func setPinned(_ identifiers: [String], value: Bool, reply: @escaping (NSError?) -> Void)
    func release(_ identifiers: [String], reply: @escaping (NSError?) -> Void)
}
