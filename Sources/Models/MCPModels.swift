import Foundation

struct MCPServer: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var token: String = ""
    var isEnabled: Bool = true
    var tools: [MCPTool] = []
    var lastChecked: Date?
    var statusMessage: String = ""
}

struct MCPTool: Identifiable, Codable, Equatable, Hashable {
    var id: String { name }
    var name: String
    var rawName: String
    var description: String
    var inputSchemaJSON: String = "{}"
    var isEnabled: Bool = true
}
